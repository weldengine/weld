//! S4 tree-walking interpreter for Etch.
//!
//! Walks the tabular AST produced by S3 (`etch/ast.zig`), compiles each
//! component / resource / rule into runtime descriptors (registry ids,
//! include/exclude sets, field filters), and executes the rule bodies
//! one tick at a time over the dynamic side of the world.
//!
//! Boundaries (cf. `briefs/S4-etch-tree-walking-interpreter.md` Out-of-scope):
//! - No HIR — walks the AST directly.
//! - No bytecode VM.
//! - No structural mutation (`spawn`, `despawn`, `add(T)`, `remove(T)`).
//! - No job system use; rules run sequentially on the calling thread.
//! - `ExprKind.path` and `ExprKind.tag_path` produce `RuntimeError.UnsupportedExpr`.

const std = @import("std");
const ast_mod = @import("ast.zig");
const types_mod = @import("types.zig");
const parser_mod = @import("parser.zig");
const diag_mod = @import("diagnostics.zig");
const value_mod = @import("value.zig");
const bridge_mod = @import("ecs_bridge.zig");
const tags_mod = @import("tags.zig");

const weld_core = @import("weld_core");
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;
const FieldDesc = weld_core.ecs.registry.FieldDesc;
const FieldKind = weld_core.ecs.registry.FieldKind;
const DynamicArchetype = weld_core.ecs.archetype_dynamic.DynamicArchetype;
const Chunk = weld_core.ecs.archetype_dynamic.Chunk;
const World = weld_core.ecs.world.World;
const CoreEntityId = weld_core.ecs.entity.EntityId;
const Tick = weld_core.ecs.tick.Tick;
const initial_tick = weld_core.ecs.tick.initial_tick;

const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;
const StringId = ast_mod.StringId;
const Diagnostic = diag_mod.Diagnostic;
const Value = value_mod.Value;
const EntityId = value_mod.EntityId;
const Bridge = bridge_mod.Bridge;

/// Counters surfaced by `Interpreter.run` per tick — informational
/// only, used by tests + bench harnesses to assert hot-path coverage.
pub const RuntimeReport = struct {
    entities_iterated: u64 = 0,
    rules_evaluated: u64 = 0,
    rules_matched: u64 = 0,
    runtime_errors: u64 = 0,
};

const ResourceDep = struct {
    resource_id: ComponentId,
    must_be_changed: bool,
};

const FieldFilter = struct {
    component_id: ComponentId,
    field_offset: u16,
    field_kind: FieldKind,
    expected_value: Value,
};

/// A per-entity tag query predicate compiled from a `.tag_filter` when-node
/// (M0.8 E3). `bits` is the resolved leaf-bit set of the operand(s) — a single
/// bit for `has_tag`/`has_no_tag`, the union of operand bits (leaves + expanded
/// category masks) for the multi operators. Evaluated against the entity's
/// `TagSet` at iteration time (an entity without `TagSet` reads as all-zero).
const TagPredicate = struct {
    op: ast_mod.TagOp,
    bits: []u32,

    fn deinit(self: *TagPredicate, gpa: std.mem.Allocator) void {
        gpa.free(self.bits);
    }
};

/// A deferred tag mutation (M0.8 E3, `etch-grammar.md` §4.4). Enqueued by
/// `add_tag`/`remove_tag` during a tick, applied at the tick boundary (after
/// every rule has run) — never mid-archetype-walk. Applying may add the
/// `TagSet` component to an entity that lacks one (an archetype transition),
/// which is precisely why tag mutations are deferred structural changes.
const PendingTag = struct {
    entity: EntityId,
    bit_index: u32,
    set: bool,
};

/// Resolved view of a `when` clause node. The interpreter walks
/// `predicate_pool` at iteration time to filter archetypes.
const PredicateNodeKind = enum {
    and_,
    or_,
    not_,
    has,
};

const PredicateNode = struct {
    kind: PredicateNodeKind,
    /// Indices into the rule's `predicate_pool`. `no_child` if absent.
    lhs: u32 = no_child,
    rhs: u32 = no_child,
    /// Resolved component id for `has` nodes.
    component_id: ComponentId = 0,

    pub const no_child: u32 = std.math.maxInt(u32);
};

const RuleDesc = struct {
    rule_idx: u32,
    name: StringId,
    /// Pool of resolved predicate nodes. `predicate_root` indexes into it.
    /// Empty when the rule has no component-side `when` clause (resource-
    /// only or no when).
    predicate_pool: []PredicateNode,
    predicate_root: ?u32,
    resource_deps: []ResourceDep,
    field_filter: ?FieldFilter,
    /// Per-entity tag query predicates (M0.8 E3) — applied after `field_filter`
    /// at iteration time, ANDed with the rest (same flat model as
    /// `field_filter`; an `or`/`not` over a tag filter is the same documented
    /// S4-debt imprecision the field filter carries — the differential uses
    /// AND only).
    tag_predicates: []TagPredicate,
    entity_param_name: ?StringId,
    /// True iff the rule iterates entities (predicate references at least
    /// one component and a parameter of type Entity is present). False if
    /// the rule runs once per tick (resource-only or no-when).
    is_entity_bound: bool,
    /// `@on_event(T)` observer (M0.8 E3): the event type name `T`, or null for
    /// a non-observer rule. When set, the rule fires once per event of type `T`
    /// in the per-tick `EventStore`, with the implicit `event` binding injected
    /// self-style (resolver-types §12). Takes precedence over entity/global
    /// dispatch in `runRule`.
    event_type: ?StringId,
    /// `entity has T changed` change-detection filters (M0.8 E3): component ids
    /// that must have changed since `last_run_tick` for the entity to match.
    /// Per-entity, ANDed after the field filter and tag predicates (same flat
    /// model). Empty for a rule with no `changed` filter.
    changed_filters: []ComponentId,
    /// The `current_tick` at which this rule last ran (`engine-ecs-internals.md`
    /// §5). A `changed` filter matches a slot iff `changedTick(slot) >
    /// last_run_tick`. Updated after each evaluation in `stepOnce`. Starts at
    /// `initial_tick` (0).
    last_run_tick: Tick,
    /// `async rule` (M0.8 E3 sub-slice B): the rule suspends at `await` and
    /// resumes a later tick via its `AsyncSlot`, instead of running to
    /// completion every tick. Dispatched by `runAsyncRule` in `stepOnce`.
    is_async: bool,

    fn deinit(self: *RuleDesc, gpa: std.mem.Allocator) void {
        gpa.free(self.predicate_pool);
        gpa.free(self.resource_deps);
        for (self.tag_predicates) |*tp| tp.deinit(gpa);
        gpa.free(self.tag_predicates);
        gpa.free(self.changed_filters);
    }
};

const Local = struct {
    value: Value,
    is_mut: bool,
};

const Locals = struct {
    map: std.AutoHashMapUnmanaged(StringId, Local) = .empty,

    pub fn deinit(self: *Locals, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    pub fn put(self: *Locals, gpa: std.mem.Allocator, name: StringId, v: Value, is_mut: bool) !void {
        try self.map.put(gpa, name, .{ .value = v, .is_mut = is_mut });
    }

    pub fn get(self: *const Locals, name: StringId) ?Value {
        if (self.map.get(name)) |l| return l.value;
        return null;
    }

    pub fn getPtr(self: *Locals, name: StringId) ?*Value {
        if (self.map.getPtr(name)) |l| return &l.value;
        return null;
    }
};

/// One `key: value` entry of a runtime map (M0.8 collections).
const MapPair = struct { key: Value, value: Value };

/// Per-rule-body heap store for Etch collection values (M0.8 collections).
/// Arrays are `ArrayListUnmanaged(Value)` addressed by the `u32` handle carried
/// in `Value.array_ref`; maps are `ArrayListUnmanaged(MapPair)` (insertion
/// order, keys unique) addressed by `Value.map_ref`. Reset at each rule-body
/// boundary so collections created inside a body do not leak across
/// invocations (rule-arena semantics, surface view of `etch-memory-model.md`
/// §6). Sets have no E1 literal / constructor (their `Set.from` needs the call
/// mechanism), so they are not stored yet.
const CollectionStore = struct {
    arrays: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    maps: std.ArrayListUnmanaged(std.ArrayListUnmanaged(MapPair)) = .empty,

    fn deinit(self: *CollectionStore, gpa: std.mem.Allocator) void {
        for (self.arrays.items) |*a| a.deinit(gpa);
        self.arrays.deinit(gpa);
        for (self.maps.items) |*m| m.deinit(gpa);
        self.maps.deinit(gpa);
    }

    /// Free every per-body collection, keeping the outer vectors' capacity.
    fn reset(self: *CollectionStore, gpa: std.mem.Allocator) void {
        for (self.arrays.items) |*a| a.deinit(gpa);
        self.arrays.clearRetainingCapacity();
        for (self.maps.items) |*m| m.deinit(gpa);
        self.maps.clearRetainingCapacity();
    }

    /// Allocate a fresh empty array, returning its handle.
    fn newArray(self: *CollectionStore, gpa: std.mem.Allocator) !u32 {
        const idx: u32 = @intCast(self.arrays.items.len);
        try self.arrays.append(gpa, .empty);
        return idx;
    }

    /// Allocate a fresh empty map, returning its handle.
    fn newMap(self: *CollectionStore, gpa: std.mem.Allocator) !u32 {
        const idx: u32 = @intCast(self.maps.items.len);
        try self.maps.append(gpa, .empty);
        return idx;
    }
};

/// A runtime closure value (M0.8 closures): the closure-expression node plus a
/// by-value snapshot of the environment captured at the definition site
/// (§5.6 — value types copied). E1 closures are short-lived (invoked in the
/// same rule body), so capturing component refs is sound; long-lived closures
/// (event handlers) are E3+.
const ClosureVal = struct {
    node: NodeId,
    captured: std.AutoHashMapUnmanaged(StringId, Value),
};

/// Per-rule-body store for closure values, addressed by `Value.closure`. Reset
/// at the body boundary like the collection store (rule-arena semantics).
const ClosureStore = struct {
    list: std.ArrayListUnmanaged(ClosureVal) = .empty,

    fn deinit(self: *ClosureStore, gpa: std.mem.Allocator) void {
        for (self.list.items) |*c| c.captured.deinit(gpa);
        self.list.deinit(gpa);
    }

    fn reset(self: *ClosureStore, gpa: std.mem.Allocator) void {
        for (self.list.items) |*c| c.captured.deinit(gpa);
        self.list.clearRetainingCapacity();
    }

    /// Store a closure (taking ownership of `captured`), returning its handle.
    fn newClosure(self: *ClosureStore, gpa: std.mem.Allocator, node: NodeId, captured: std.AutoHashMapUnmanaged(StringId, Value)) !u32 {
        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(gpa, .{ .node = node, .captured = captured });
        return idx;
    }
};

/// One field of a runtime `struct` value (M0.8 E2 block 3).
const StructField = struct { name: StringId, value: Value };

/// A runtime `struct` value: its type name plus an ordered set of field values
/// (declaration order). Addressed by `Value.struct_ref`.
const StructVal = struct {
    type_name: StringId,
    fields: std.ArrayListUnmanaged(StructField) = .empty,
};

/// Per-rule-body store for struct values (M0.8 E2 block 3), addressed by
/// `Value.struct_ref`. Reset at the body boundary like the collection / closure
/// stores (rule-arena semantics). A struct is a by-value type; in the
/// interpreter the handle is shared (reference-like), which is sound for the
/// block-3 surface — `self` mutation through a `mut self` method must propagate
/// to the receiver, and no differential aliases two struct locals.
const StructStore = struct {
    list: std.ArrayListUnmanaged(StructVal) = .empty,

    fn deinit(self: *StructStore, gpa: std.mem.Allocator) void {
        for (self.list.items) |*s| s.fields.deinit(gpa);
        self.list.deinit(gpa);
    }

    fn reset(self: *StructStore, gpa: std.mem.Allocator) void {
        for (self.list.items) |*s| s.fields.deinit(gpa);
        self.list.clearRetainingCapacity();
    }

    /// Allocate a fresh struct value, returning its handle.
    fn newStruct(self: *StructStore, gpa: std.mem.Allocator, type_name: StringId) !u32 {
        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(gpa, .{ .type_name = type_name });
        return idx;
    }
};

/// One emitted event instance in the interpreter's dynamic event store (M0.8
/// E3). Reuses `StructField` for its `(name, value)` payload — an event is a
/// POD struct of fields (ABI §3.1); field values are POD scalars (the resolver
/// enforces POD event fields), so they are stored by value.
const EventVal = struct {
    type_name: StringId,
    fields: std.ArrayListUnmanaged(StructField) = .empty,
};

/// Dynamic per-tick event queue for the interpreter (M0.8 E3). The
/// comptime-typed `World.event_bus` (`register`/`emit` are `comptime T: type`)
/// cannot be driven by the dynamic tree-walker, so `emit` accumulates events
/// here, each tagged by its type name; `@on_event` observers drain them. The
/// observer/drain side is the E3 observer tranche (resolver-types §12,
/// deferred). Cleared at the start of each tick (`stepOnce`), matching the
/// `Lifetime.tick` drain cadence (`src/core/events/lifetime.zig`).
const EventStore = struct {
    list: std.ArrayListUnmanaged(EventVal) = .empty,

    fn deinit(self: *EventStore, gpa: std.mem.Allocator) void {
        for (self.list.items) |*e| e.fields.deinit(gpa);
        self.list.deinit(gpa);
    }

    fn clear(self: *EventStore, gpa: std.mem.Allocator) void {
        for (self.list.items) |*e| e.fields.deinit(gpa);
        self.list.clearRetainingCapacity();
    }

    /// Enqueue an event of `type_name`, taking ownership of `fields`.
    fn enqueue(self: *EventStore, gpa: std.mem.Allocator, type_name: StringId, fields: std.ArrayListUnmanaged(StructField)) !void {
        try self.list.append(gpa, .{ .type_name = type_name, .fields = fields });
    }

    /// Number of queued events of `type_name` (test / inspection helper).
    fn count(self: *const EventStore, type_name: StringId) usize {
        var n: usize = 0;
        for (self.list.items) |e| {
            if (e.type_name == type_name) n += 1;
        }
        return n;
    }
};

/// Compose the inherent-method map key from a type name and a method name (M0.8
/// E2 block 3) — same packing as `types.methodKey`.
fn methodKey(type_name: StringId, method_name: StringId) u64 {
    return (@as(u64, type_name) << 32) | @as(u64, method_name);
}

const StmtError = error{ OutOfMemory, RuntimeFailure };

/// Control-flow signal raised by `break` / `continue` (M0.8 loop/break).
/// Carried on the interpreter (not as a return value) so it can cross
/// expression↔statement boundaries — e.g. a `break` inside a `match` arm block
/// nested in a loop body. The enclosing loop consumes it; `none` is the
/// ordinary fall-through.
const Control = enum { none, break_, continue_ };

/// What an enclosing loop should do once a control signal has surfaced.
const LoopAction = enum { again, stop, propagate };

/// The condition that resumes a suspended `async rule` (M0.8 E3 sub-slice B).
/// The tree-walker is its own runtime (`etch-reference-part1.md §9`): an
/// `await` suspends the rule as a task-record, polled each tick in `stepOnce`.
const WakeCond = union(enum) {
    /// Resume once `async_tick` reaches this value. `await wait(N)` reached at
    /// tick T sets it to T + N — M0.8 counts `wait` in TICKS (no wall-clock;
    /// `wait_unscaled` / duration waits fail loud, out of E3 — Guy's ruling).
    wait_until: u64,
    /// Resume once an event of this type is present in the per-tick EventStore
    /// (M0.8 E3 sub-slice B — `await global_event(T)`). The producer must run
    /// before the awaiter in the rule order, same as the observer drain.
    global_event: StringId,
};

/// Per-`async rule` suspend/resume state (M0.8 E3 sub-slice B — the Option-A
/// task-record, validated by Guy). Held in a slice parallel to `rule_descs`;
/// only `is_async` rules use their slot. This is the interpreter-level analogue
/// of the async state struct (`etch-memory-model.md §5.7`) — at the tree-walk
/// level, no compiled state machine (that is Phase-2 codegen).
const AsyncSlot = struct {
    state: enum { unspawned, suspended, done } = .unspawned,
    /// Next top-level body-statement index to run on resume. `await` is bounded
    /// to a top-level statement (the M0.8 cursor model); nested/value await
    /// fails loud (the Phase-2 state machine covers the general case).
    cursor: u32 = 0,
    wake: WakeCond = .{ .wait_until = 0 },
    /// The task's locals, retained across suspension. POD-only in M0.8 (heap
    /// locals surviving a suspend are out of scope — flagged for Review E3).
    locals: Locals = .{},

    fn deinit(self: *AsyncSlot, gpa: std.mem.Allocator) void {
        self.locals.deinit(gpa);
    }
};

/// S4 tree-walking interpreter — owns the bridge state, evaluates
/// the type-checked AST against a `World` once per tick.
pub const Interpreter = struct {
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    bridge: Bridge,
    rule_descs: []RuleDesc,
    /// Top-level `fn` declarations keyed by name (M0.8 E2 call mechanism), for
    /// resolving a free-function call `f(args)` whose callee names a `fn`.
    fns: std.AutoHashMapUnmanaged(StringId, ast_mod.FnDecl) = .empty,
    /// Inherent `impl` methods keyed by `methodKey(type_name, method_name)`
    /// (M0.8 E2 block 3), for `recv.method()` / `Type.assoc()` dispatch.
    methods: std.AutoHashMapUnmanaged(u64, ast_mod.FnDecl) = .empty,
    /// `struct` declarations keyed by name (M0.8 E2 block 3), for materializing
    /// a struct literal (field order + declared defaults for omitted fields).
    struct_decls: std.AutoHashMapUnmanaged(StringId, ast_mod.StructDecl) = .empty,
    /// `enum` declarations keyed by name (M0.8 E2 block 3 tranche B), for
    /// resolving enum values + match-arm variant indices.
    enum_decls: std.AutoHashMapUnmanaged(StringId, ast_mod.EnumDecl) = .empty,
    /// Trait-impl methods keyed by `methodKey(type_name, method_name)` (M0.8 E2
    /// block 3 tranche C), each resolved to the impl-provided method or the
    /// trait's default. Consulted AFTER `methods` (inherent) per §5.5.
    trait_methods: std.AutoHashMapUnmanaged(u64, ast_mod.FnDecl) = .empty,
    /// Heap store backing collection values created in rule bodies (M0.8).
    collections: CollectionStore = .{},
    /// Store backing closure values created in rule bodies (M0.8 closures).
    closures: ClosureStore = .{},
    /// Store backing struct values created in rule / fn / method bodies (M0.8
    /// E2 block 3).
    structs: StructStore = .{},
    /// Dynamic per-tick event queue (M0.8 E3). `emit` enqueues here; `@on_event`
    /// observers drain it (observer side deferred to resolver-types §12). Cleared
    /// at the start of each tick. NOT a rule-body store — events outlive the body
    /// (they cross to observers), so it is not reset at the body boundary.
    events: EventStore = .{},
    /// Store backing optional values created in rule bodies (M0.8 E2 block 5).
    /// Each entry is `?Value` — `null` = `none`, else the `some` payload.
    /// Reset at the rule-body boundary (rule-arena semantics).
    optionals: std.ArrayListUnmanaged(?Value) = .empty,
    /// Store backing runtime-produced strings (M0.8 sub-slice C tranche 1b):
    /// concat (and, 1c, interpolation) results, addressed by `Value
    /// .string_run`. Each entry is gpa-owned bytes. Reset at the rule-body
    /// boundary like `collections` (rule-arena semantics — the codegen
    /// counterpart is the per-tick frame arena, observably identical since
    /// strings never enter the POD world state).
    run_strings: std.ArrayListUnmanaged([]u8) = .empty,
    /// Active control-flow signal (M0.8 loop/break). Set by `break`/`continue`,
    /// consumed by the enclosing loop.
    control: Control = .none,
    /// The value carried by the active `break` (`unit` for valueless breaks).
    break_value: Value = .{ .unit = {} },
    /// The label targeted by the active `break`/`continue` (`0` = unlabeled).
    control_label: StringId = 0,
    /// Whether a `throw` is in flight, awaiting a `catch` (M0.8 error handling).
    thrown: bool = false,
    /// The value carried by the in-flight `throw`.
    thrown_value: Value = .{ .unit = {} },
    /// Whether a `return` is unwinding to the enclosing `fn` boundary (M0.8 E2).
    /// Mirrors `thrown`: every statement-run / loop / block site that stops on a
    /// throw also stops on a return; the fn-call boundary consumes it.
    returning: bool = false,
    /// The value carried by the in-flight `return` (`unit` for a bare return).
    return_value: Value = .{ .unit = {} },
    /// Merged global tag table (M0.8 E3) — built identically to the resolver's
    /// (`tags.zig` is the shared algorithm). Consulted at exec time to resolve
    /// a `tag_mutation_stmt` path to its leaf bit.
    tag_table: tags_mod.TagTable,
    /// Registry id of the builtin `TagSet` component, or `null` when the
    /// program declares no tags. `TagSet` is `[words]u64` of bits.
    tagset_id: ?ComponentId = null,
    /// Deferred tag mutations queued during a tick, flushed at the tick boundary
    /// (M0.8 E3) — never applied mid-archetype-walk.
    pending_tags: std.ArrayListUnmanaged(PendingTag) = .empty,
    /// True iff any rule carries a `changed` filter (M0.8 E3). Gates the whole
    /// tick-based change-detection path: only then does `runFor` advance
    /// `current_tick` (`beginFrame`) and a component write `markChanged`s — so
    /// a `changed`-free program is byte-identical to the pre-E3 runtime (no
    /// tick churn, no marking overhead).
    has_changed: bool = false,
    /// True iff any rule is `async` (M0.8 E3 sub-slice B). Gates the async tick
    /// counter + the task-record dispatch in `stepOnce`; a sync-only program is
    /// byte-identical to the pre-B runtime (no `async_tick` churn, no slots).
    has_async: bool = false,
    /// Logical async clock — incremented once per `stepOnce` when `has_async`.
    /// `await wait(N)` resolves against it (N is a tick count, not seconds).
    async_tick: u64 = 0,
    /// Suspend/resume state, one slot per rule (parallel to `rule_descs`). Empty
    /// when `!has_async`; a non-async rule never touches its slot.
    async_slots: []AsyncSlot = &.{},

    pub fn deinit(self: *Interpreter) void {
        for (self.rule_descs) |*r| r.deinit(self.gpa);
        self.gpa.free(self.rule_descs);
        self.bridge.deinit(self.gpa);
        self.collections.deinit(self.gpa);
        self.closures.deinit(self.gpa);
        self.structs.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.optionals.deinit(self.gpa);
        for (self.run_strings.items) |s| self.gpa.free(s);
        self.run_strings.deinit(self.gpa);
        self.fns.deinit(self.gpa);
        self.methods.deinit(self.gpa);
        self.struct_decls.deinit(self.gpa);
        self.enum_decls.deinit(self.gpa);
        self.trait_methods.deinit(self.gpa);
        self.tag_table.deinit(self.gpa);
        self.pending_tags.deinit(self.gpa);
        for (self.async_slots) |*slot| slot.deinit(self.gpa);
        self.gpa.free(self.async_slots);
        self.* = undefined;
    }

    /// Parse + type-check + compile + run for `ticks` ticks. Diagnostics
    /// from parser or type-checker turn into `error.DiagnosticsPresent`.
    pub fn runProgram(
        gpa: std.mem.Allocator,
        source: []const u8,
        world: *World,
        ticks: u32,
    ) !RuntimeReport {
        var pr = try parser_mod.parse(gpa, source);
        defer pr.deinit(gpa);
        if (pr.diagnostics.len > 0) return error.DiagnosticsPresent;

        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
        if (diags.items.len > 0) return error.DiagnosticsPresent;

        return try run(gpa, &pr.ast, world, ticks);
    }

    pub fn run(
        gpa: std.mem.Allocator,
        ast: *const AstArena,
        world: *World,
        ticks: u32,
    ) !RuntimeReport {
        var interp = try compile(gpa, ast, world);
        defer interp.deinit();
        return try interp.runFor(world, ticks);
    }

    pub fn compile(gpa: std.mem.Allocator, ast: *const AstArena, world: *World) !Interpreter {
        var bridge = Bridge.init();
        errdefer bridge.deinit(gpa);

        // Build the merged global tag table (M0.8 E3) — same algorithm as the
        // resolver / codegen (`tags.zig`). The program is already type-checked,
        // so `build` reports no new diagnostics; collect them into a throwaway
        // list and drop it.
        var tag_diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (tag_diags.items) |*d| d.deinit(gpa);
            tag_diags.deinit(gpa);
        }
        var tag_table = try tags_mod.TagTable.build(gpa, ast, &tag_diags, tags_mod.default_max_tags);
        errdefer tag_table.deinit(gpa);

        // Pass A — register components and resources with the world.
        var i: u28 = 0;
        while (i < ast.items.len) : (i += 1) {
            const kind = ast.items.items(.kind)[i];
            const data = ast.items.items(.data)[i];
            switch (kind) {
                .component_decl => try compileComponent(gpa, ast, world, &bridge, ast.component_decls.items[data]),
                .resource_decl => try compileResource(gpa, ast, world, &bridge, ast.resource_decls.items[data]),
                else => {},
            }
        }

        // Register the builtin `TagSet` component (M0.8 E3) when the program
        // declares any tag — a fixed `[words]u64` bitfield, one slot per entity
        // carrying tags. It has no named scalar fields; the runtime reads/writes
        // its raw bytes as bits.
        var tagset_id: ?ComponentId = null;
        if (tag_table.leaf_count > 0) {
            const size: u16 = @intCast(tag_table.words() * 8);
            const zeroed = try gpa.alloc(u8, size);
            defer gpa.free(zeroed);
            @memset(zeroed, 0);
            const id = try world.registry.registerComponentRaw(gpa, .{
                .name = "TagSet",
                .size = size,
                .alignment = 8,
                .default_bytes = zeroed,
                .fields = &.{},
            });
            try bridge.mapComponent(gpa, "TagSet", id);
            tagset_id = id;
        }

        // Pass B — compile rules. Need the registry to resolve field
        // filter offsets/kinds.
        var rule_descs: std.ArrayListUnmanaged(RuleDesc) = .empty;
        errdefer {
            for (rule_descs.items) |*r| r.deinit(gpa);
            rule_descs.deinit(gpa);
        }
        i = 0;
        while (i < ast.items.len) : (i += 1) {
            const kind = ast.items.items(.kind)[i];
            const data = ast.items.items(.data)[i];
            if (kind != .rule_decl) continue;
            const desc = try compileRule(gpa, ast, &bridge, &world.registry, &tag_table, tagset_id, data);
            try rule_descs.append(gpa, desc);
        }

        // Pass C — index top-level `fn` declarations by name for free-call
        // resolution (M0.8 E2 call mechanism).
        var fns: std.AutoHashMapUnmanaged(StringId, ast_mod.FnDecl) = .empty;
        errdefer fns.deinit(gpa);
        i = 0;
        while (i < ast.items.len) : (i += 1) {
            const kind = ast.items.items(.kind)[i];
            const data = ast.items.items(.data)[i];
            if (kind != .fn_decl) continue;
            const decl = ast.fn_decls.items[data];
            try fns.put(gpa, decl.name, decl);
        }

        // Pass D — index inherent `impl` methods by `(type_name, method_name)`
        // for `recv.method()` / `Type.assoc()` dispatch, plus `struct`
        // declarations by name for struct-literal materialization (M0.8 E2
        // block 3).
        var methods: std.AutoHashMapUnmanaged(u64, ast_mod.FnDecl) = .empty;
        errdefer methods.deinit(gpa);
        var struct_decls: std.AutoHashMapUnmanaged(StringId, ast_mod.StructDecl) = .empty;
        errdefer struct_decls.deinit(gpa);
        var enum_decls: std.AutoHashMapUnmanaged(StringId, ast_mod.EnumDecl) = .empty;
        errdefer enum_decls.deinit(gpa);
        var trait_methods: std.AutoHashMapUnmanaged(u64, ast_mod.FnDecl) = .empty;
        errdefer trait_methods.deinit(gpa);
        // Trait declarations by name (M0.8 E2 block 3 tranche C) — a local index
        // used to resolve a trait impl's defaults; not stored on the interpreter.
        var trait_decls: std.AutoHashMapUnmanaged(StringId, ast_mod.TraitDecl) = .empty;
        defer trait_decls.deinit(gpa);
        i = 0;
        while (i < ast.items.len) : (i += 1) {
            const kind = ast.items.items(.kind)[i];
            const data = ast.items.items(.data)[i];
            switch (kind) {
                .impl_decl => {
                    // Inherent impl → `methods`; trait impl handled in pass D2
                    // (needs the trait decls, whose source order is arbitrary).
                    const impl = ast.impl_decls.items[data];
                    if (impl.trait_name != 0) continue;
                    var m: u32 = 0;
                    while (m < impl.methods_len) : (m += 1) {
                        const method = ast.impl_methods.items[impl.methods_start + m];
                        try methods.put(gpa, methodKey(impl.type_name, method.name), method);
                    }
                },
                .struct_decl => {
                    const decl = ast.struct_decls.items[data];
                    try struct_decls.put(gpa, decl.name, decl);
                },
                .enum_decl => {
                    const decl = ast.enum_decls.items[data];
                    try enum_decls.put(gpa, decl.name, decl);
                },
                .trait_decl => {
                    const decl = ast.trait_decls.items[data];
                    try trait_decls.put(gpa, decl.name, decl);
                },
                else => {},
            }
        }

        // Pass D2 — trait impls: key each (type, method) to the impl-provided
        // method, or the trait's default when the impl does not override it
        // (M0.8 E2 block 3 tranche C). Inherent (`methods`) wins at dispatch.
        i = 0;
        while (i < ast.items.len) : (i += 1) {
            if (ast.items.items(.kind)[i] != .impl_decl) continue;
            const impl = ast.impl_decls.items[ast.items.items(.data)[i]];
            if (impl.trait_name == 0) continue;
            // Impl-provided methods.
            var m: u32 = 0;
            while (m < impl.methods_len) : (m += 1) {
                const method = ast.impl_methods.items[impl.methods_start + m];
                try trait_methods.put(gpa, methodKey(impl.type_name, method.name), method);
            }
            // Trait defaults the impl does not provide.
            if (trait_decls.get(impl.trait_name)) |tdecl| {
                var t: u32 = 0;
                while (t < tdecl.methods_len) : (t += 1) {
                    const tm = ast.impl_methods.items[tdecl.methods_start + t];
                    if (!tm.has_body) continue; // abstract → the impl provides it
                    const key = methodKey(impl.type_name, tm.name);
                    if (!trait_methods.contains(key)) try trait_methods.put(gpa, key, tm);
                }
            }
        }

        const slice = try rule_descs.toOwnedSlice(gpa);
        // Enable the tick-based change-detection path iff some rule filters by
        // `changed` (M0.8 E3) — keeps `changed`-free programs free of tick churn.
        var any_changed = false;
        for (slice) |rd| {
            if (rd.changed_filters.len > 0) {
                any_changed = true;
                break;
            }
        }
        // Allocate one suspend/resume slot per rule iff any rule is `async`
        // (M0.8 E3 sub-slice B). A sync-only program keeps an empty slice and
        // never advances `async_tick` — byte-identical to the pre-B runtime.
        var any_async = false;
        for (slice) |rd| {
            if (rd.is_async) {
                any_async = true;
                break;
            }
        }
        const async_slots: []AsyncSlot = if (any_async) blk: {
            const slots = try gpa.alloc(AsyncSlot, slice.len);
            for (slots) |*slot| slot.* = .{};
            break :blk slots;
        } else &.{};
        return .{
            .gpa = gpa,
            .ast = ast,
            .bridge = bridge,
            .rule_descs = slice,
            .fns = fns,
            .methods = methods,
            .struct_decls = struct_decls,
            .enum_decls = enum_decls,
            .trait_methods = trait_methods,
            .tag_table = tag_table,
            .tagset_id = tagset_id,
            .has_changed = any_changed,
            .has_async = any_async,
            .async_slots = async_slots,
        };
    }

    pub fn runFor(self: *Interpreter, world: *World, ticks: u32) !RuntimeReport {
        var report: RuntimeReport = .{};
        var t: u32 = 0;
        while (t < ticks) : (t += 1) {
            try self.stepOnce(world, &report);
            world.tickBoundary();
        }
        return report;
    }

    pub fn stepOnce(self: *Interpreter, world: *World, report: *RuntimeReport) !void {
        // Advance `current_tick` (and clear the dirty bitsets) at the start of
        // the tick when change detection is live, so a write this tick stamps
        // `changedTick = current_tick > last_run_tick` and a `changed` filter
        // fires for it (`engine-ecs-internals.md` §5). Lives in `stepOnce` (not
        // `runFor`) so every per-tick driver — `runFor` AND the differential
        // harness's `step` — advances the tick identically; the codegen `tick`
        // calls `beginFrame` at the same point. A `changed`-free program never
        // advances the tick (byte-identical to the pre-E3 runtime).
        if (self.has_changed) world.beginFrame();
        // Advance the logical async clock once per tick when async rules are
        // present (M0.8 E3 sub-slice B). `await wait(N)` resolves against it.
        if (self.has_async) self.async_tick += 1;
        // Events have a per-tick lifetime (`Lifetime.tick`): clear the previous
        // tick's queue before running this tick's rules (M0.8 E3).
        self.events.clear(self.gpa);
        for (self.rule_descs, 0..) |*rd, i| {
            report.rules_evaluated += 1;
            // `async rule` (M0.8 E3 sub-slice B): drive its suspend/resume task
            // at this position in the rule order, so events it emits/consumes
            // interleave with the other rules exactly like the observer drain
            // (the producer-before-consumer ordering — Guy's ruling).
            if (rd.is_async) {
                try self.runAsyncRule(world, i, report);
                continue;
            }
            if (!resourceDepsSatisfied(world, rd.*)) continue;
            try self.runRule(world, rd.*, report);
            // Record the tick at which this rule ran — the baseline its next
            // `changed` filter compares against (M0.8 E3). `runRule` was passed
            // the pre-update value, so the filter saw the correct baseline.
            if (self.has_changed) rd.last_run_tick = world.current_tick;
        }
        // Apply deferred tag mutations at the tick boundary — after every rule
        // has run, never mid-archetype-walk (M0.8 E3, `etch-grammar.md` §4.4).
        try self.flushPendingTags(world);
    }

    fn runRule(self: *Interpreter, world: *World, rd: RuleDesc, report: *RuntimeReport) !void {
        // `@on_event(T)` observer (M0.8 E3): fire once per event of type `T` in
        // the per-tick `EventStore`, in emit order, with the implicit `event`
        // binding injected. Takes precedence over entity/global dispatch.
        if (rd.event_type) |event_type| {
            try self.runObserver(world, rd, event_type, report);
            return;
        }
        if (!rd.is_entity_bound) {
            try self.execBody(world, rd, null, null, report);
            report.rules_matched += 1;
            return;
        }
        var rule_matched = false;
        for (world.archetypes.items) |arch| {
            if (rd.predicate_root) |root| {
                if (!evalPredicate(rd.predicate_pool, root, arch)) continue;
            }
            for (arch.chunks.items) |chunk| {
                const ids = arch.entityIdsConst(chunk);
                const count = chunk.header().entity_count;
                var slot: u32 = 0;
                while (slot < count) : (slot += 1) {
                    if (rd.field_filter) |ff| {
                        if (!filterPasses(arch, chunk, ff, slot)) continue;
                    }
                    // The chunk array stores the core `EntityId` packed
                    // struct; Etch's local `EntityId` is the raw u64 wire
                    // form that lives inside `Value.entity_id`. The two
                    // share the same 8-byte layout — `@bitCast` does the
                    // conversion without touching bits.
                    const entity_id: EntityId = @bitCast(ids[slot]);
                    // Per-entity tag predicates (M0.8 E3) — applied after the
                    // archetype-level predicate, like the field filter.
                    if (rd.tag_predicates.len > 0 and !self.tagPredicatesPass(world, entity_id, rd.tag_predicates)) continue;
                    // Per-entity `changed` filters (M0.8 E3) — the slot's
                    // `changedTick(T)` must exceed the rule's `last_run_tick`.
                    if (rd.changed_filters.len > 0 and !changedFiltersPass(arch, chunk, slot, rd.changed_filters, rd.last_run_tick)) continue;
                    report.entities_iterated += 1;
                    rule_matched = true;
                    try self.execBody(world, rd, entity_id, null, report);
                }
            }
        }
        if (rule_matched) report.rules_matched += 1;
    }

    /// Run an `@on_event(T)` observer (M0.8 E3): fire the body once per event of
    /// type `event_type` currently in the per-tick `EventStore`, in emit order.
    /// The list length is re-checked each iteration so an event the body itself
    /// emits (of the same type) is also delivered — byte-exact with the codegen
    /// bus drain (`subscribe` at head=0, `while (poll) |event|`), which likewise
    /// reads up to the live head. A non-observer never reaches this path.
    fn runObserver(self: *Interpreter, world: *World, rd: RuleDesc, event_type: StringId, report: *RuntimeReport) !void {
        var matched = false;
        var i: usize = 0;
        while (i < self.events.list.items.len) : (i += 1) {
            if (self.events.list.items[i].type_name != event_type) continue;
            matched = true;
            try self.execBody(world, rd, null, i, report);
        }
        if (matched) report.rules_matched += 1;
    }

    /// Drive an `async rule`'s suspend/resume task at its position in the rule
    /// order (M0.8 E3 sub-slice B, Option-A task-record). Spawns the task on
    /// first reach, resumes a suspended one whose wake has fired, skips one
    /// still waiting, and never re-runs a completed one.
    fn runAsyncRule(self: *Interpreter, world: *World, idx: usize, report: *RuntimeReport) !void {
        const rd = self.rule_descs[idx];
        const slot = &self.async_slots[idx];
        switch (slot.state) {
            .done => return,
            .suspended => {
                if (!self.asyncWakeFired(slot.wake)) return;
                // wake fired → resume from `slot.cursor` below
            },
            .unspawned => {
                // M0.8 bounds async rules to the §9.2 shape: a single
                // (non-entity-bound) task, parameterless. A resource-only
                // `when` is fine; an entity-bound async rule (entity param +
                // component `when`) would need one task per matching entity —
                // deferred, fail-loud, flagged for Review E3.
                const rule = self.ast.rule_decls.items[rd.rule_idx];
                if (rule.params_len > 0 or rd.is_entity_bound) {
                    report.runtime_errors += 1;
                    slot.state = .done;
                    return;
                }
                slot.locals = .{};
                slot.cursor = 0;
                // run from the start below
            },
        }
        report.rules_matched += 1;
        try self.driveAsyncBody(world, rd, slot, report);
    }

    /// Run an async rule body from `slot.cursor`, suspending at the next
    /// top-level `await` statement (recording its wake + the resume cursor) or
    /// running to completion. `await` is bounded to a bare top-level statement
    /// (the M0.8 cursor model); a nested / value `await` reaches `evalExpr`'s
    /// `await_expr` arm and fails loud.
    fn driveAsyncBody(self: *Interpreter, world: *World, rd: RuleDesc, slot: *AsyncSlot, report: *RuntimeReport) !void {
        const rule = self.ast.rule_decls.items[rd.rule_idx];
        self.control = .none;
        self.thrown = false;
        self.returning = false;
        var s: u32 = slot.cursor;
        while (s < rule.body_len) : (s += 1) {
            const stmt_id: NodeId = @bitCast(self.ast.extra.items[rule.body_start + s]);
            if (self.bareAwaitExpr(stmt_id)) |aw_id| {
                const wake = self.evalAwaitTarget(world, &slot.locals, aw_id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.RuntimeFailure => return self.finishAsync(slot, report, true),
                };
                slot.cursor = s + 1;
                slot.wake = wake;
                slot.state = .suspended;
                return;
            }
            self.execStmt(world, &slot.locals, stmt_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RuntimeFailure => return self.finishAsync(slot, report, true),
            };
            if (self.thrown) {
                self.thrown = false;
                return self.finishAsync(slot, report, true);
            }
            // A `break`/`continue`/`return` reaching the async rule top level
            // ends the task (rules have no return value), like `execBody`.
            if (self.control != .none) {
                self.control = .none;
                self.control_label = 0;
                break;
            }
            if (self.returning) {
                self.returning = false;
                self.return_value = .{ .unit = {} };
                break;
            }
        }
        self.finishAsync(slot, report, false);
    }

    /// Complete a task (success or fail-loud), freeing its retained locals so
    /// the final slot deinit is a no-op.
    fn finishAsync(self: *Interpreter, slot: *AsyncSlot, report: *RuntimeReport, failed: bool) void {
        if (failed) report.runtime_errors += 1;
        slot.state = .done;
        slot.locals.deinit(self.gpa);
        slot.locals = .{};
    }

    /// The `await_expr` of a bare top-level `await <target>` statement (an
    /// expr-stmt wrapping an `.await_expr`), or null. Only a bare top-level
    /// await is a suspension point — the cursor-based resume re-enters at the
    /// statement after it.
    fn bareAwaitExpr(self: *const Interpreter, stmt_id: NodeId) ?NodeId {
        if (self.ast.stmtKind(stmt_id) != .expr_stmt) return null;
        const e: NodeId = @bitCast(self.ast.stmtData(stmt_id));
        if (self.ast.exprKind(e) != .await_expr) return null;
        return e;
    }

    /// Resolve an `await` target to a `WakeCond` (M0.8 E3 sub-slice B). `wait(N)`
    /// counts N TICKS from now; `global_event(T)` waits for an event of type T.
    /// `wait_unscaled` (needs a real clock), `entity_event` (no entity-
    /// association in the global EventStore), and `future` (T2) fail loud —
    /// deferred, flagged for Review E3. The interpreter is the reference.
    fn evalAwaitTarget(self: *Interpreter, world: *World, locals: *Locals, await_id: NodeId) StmtError!WakeCond {
        const aw = self.ast.awaitExpr(await_id);
        switch (aw.target_kind) {
            .wait => {
                const v = try self.evalExpr(world, locals, aw.arg_expr);
                const n: i64 = switch (v) {
                    .int_ => |x| x,
                    else => return error.RuntimeFailure,
                };
                if (n < 0) return error.RuntimeFailure;
                return .{ .wait_until = self.async_tick + @as(u64, @intCast(n)) };
            },
            .global_event => return .{ .global_event = aw.event_type },
            .wait_unscaled, .entity_event, .future => return error.RuntimeFailure,
        }
    }

    /// True iff a suspended task's wake condition is satisfied this tick.
    fn asyncWakeFired(self: *const Interpreter, wake: WakeCond) bool {
        return switch (wake) {
            .wait_until => |t| self.async_tick >= t,
            .global_event => |type_name| self.events.count(type_name) > 0,
        };
    }

    /// Evaluate a rule's per-entity tag predicates against `entity`'s `TagSet`
    /// (M0.8 E3). An entity without a `TagSet` component reads as all-zero, so
    /// `has_no_tag`/`has_no_tags` pass and the positive operators fail.
    fn tagPredicatesPass(self: *Interpreter, world: *World, entity: EntityId, preds: []const TagPredicate) bool {
        const tid = self.tagset_id orelse return false;
        for (preds) |tp| {
            switch (tp.op) {
                .has_tag, .has_all_tags => for (tp.bits) |b| {
                    if (!entityTagBitSet(world, tid, entity, b)) return false;
                },
                .has_no_tag, .has_no_tags => for (tp.bits) |b| {
                    if (entityTagBitSet(world, tid, entity, b)) return false;
                },
                .has_any_tag => {
                    var any = false;
                    for (tp.bits) |b| {
                        if (entityTagBitSet(world, tid, entity, b)) {
                            any = true;
                            break;
                        }
                    }
                    if (!any) return false;
                },
            }
        }
        return true;
    }

    /// Apply every queued `add_tag`/`remove_tag` (M0.8 E3, `etch-grammar.md`
    /// §4.4). A `set` on an entity that already has `TagSet` flips the bit in
    /// place; on one that lacks it, `TagSet` is added (archetype transition)
    /// with the bit set. Clearing a bit on an entity without `TagSet` is a
    /// no-op. The location is looked up fresh per mutation so a transition from
    /// an earlier mutation on the same entity is observed.
    fn flushPendingTags(self: *Interpreter, world: *World) !void {
        if (self.pending_tags.items.len == 0) return;
        const tid = self.tagset_id orelse {
            self.pending_tags.clearRetainingCapacity();
            return;
        };
        // Each mutation routes through the shared Tier-0 apply primitive
        // (`World.applyTagMutation`) — the same code the codegen command buffer
        // runs, so interpreter ↔ codegen stay byte-exact by construction. The
        // location is looked up fresh per mutation (inside the primitive), so a
        // transition from an earlier mutation on the same entity is observed.
        for (self.pending_tags.items) |pt| {
            const core_id: CoreEntityId = @bitCast(pt.entity);
            try world.applyTagMutation(self.gpa, core_id, tid, pt.bit_index, pt.set);
        }
        self.pending_tags.clearRetainingCapacity();
    }

    /// Resolve a `tag_path` operand node to its leaf bit via the global table,
    /// or `null` if unknown / a namespace (the resolver rejects those — a
    /// `null` here means an inconsistent program and the caller fails loud).
    fn tagPathLeafBit(self: *Interpreter, path_node: NodeId) ?u32 {
        const tp = self.ast.tag_paths.items[self.ast.exprData(path_node)];
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        var i: u32 = 0;
        while (i < tp.segs_len) : (i += 1) {
            const seg = self.ast.strings.slice(self.ast.tag_path_segs.items[tp.segs_start + i]);
            const need = seg.len + @as(usize, if (i > 0) 1 else 0);
            if (len + need > buf.len) return null;
            if (i > 0) {
                buf[len] = '.';
                len += 1;
            }
            @memcpy(buf[len .. len + seg.len], seg);
            len += seg.len;
        }
        return self.tag_table.leafBit(buf[0..len]);
    }

    fn execBody(self: *Interpreter, world: *World, rd: RuleDesc, entity_id: ?EntityId, event_idx: ?usize, report: *RuntimeReport) !void {
        const rule = self.ast.rule_decls.items[rd.rule_idx];

        var locals: Locals = .{};
        defer locals.deinit(self.gpa);
        // Collections, closures, and structs created in this body live in the
        // rule arena: free them at the body boundary so handles never outlive
        // their invocation.
        defer self.collections.reset(self.gpa);
        defer self.closures.reset(self.gpa);
        defer self.structs.reset(self.gpa);
        defer self.optionals.clearRetainingCapacity();
        defer self.resetRunStrings();
        try bindParams(self.gpa, self.ast, rule, entity_id, &locals);
        // `@on_event(T)` observer (M0.8 E3): inject the implicit `event` payload
        // self-style (like `self` in `callMethod`). The event is materialised as
        // a struct value from the per-tick store — `EventVal` and `StructVal`
        // share the `(type_name, fields)` shape, so the existing struct-ref
        // field-access path serves `event.field`. Fields are copied by value
        // (POD scalars) before the body runs, so a body `emit` that reallocates
        // the event store cannot invalidate the binding.
        if (event_idx) |ei| {
            if (self.ast.strings.find("event")) |event_id| {
                const ev = self.events.list.items[ei];
                const handle = try self.structs.newStruct(self.gpa, ev.type_name);
                for (ev.fields.items) |f| {
                    try self.structs.list.items[handle].fields.append(self.gpa, f);
                }
                try locals.put(self.gpa, event_id, .{ .struct_ref = handle }, false);
            }
        }
        self.control = .none; // defensive: each body starts with no pending signal
        self.thrown = false;
        self.returning = false;

        var s: u32 = 0;
        while (s < rule.body_len) : (s += 1) {
            const stmt_raw = self.ast.extra.items[rule.body_start + s];
            const stmt_id: NodeId = @bitCast(stmt_raw);
            self.execStmt(world, &locals, stmt_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RuntimeFailure => {
                    report.runtime_errors += 1;
                    return;
                },
            };
            // A `throw` reaching the rule top level was never caught — count it
            // as a runtime error (the dev-build surfacing of an unhandled throw).
            if (self.thrown) {
                self.thrown = false;
                report.runtime_errors += 1;
                return;
            }
            // A `break`/`continue` reaching the rule top level (outside any loop)
            // has nowhere to go — consume it and end the body.
            if (self.control != .none) {
                self.control = .none;
                self.control_label = 0;
                break;
            }
            // A `return` at the rule top level (rules have no return value) is an
            // early exit — consume the signal and end the body.
            if (self.returning) {
                self.returning = false;
                self.return_value = .{ .unit = {} };
                break;
            }
        }
    }

    /// Run a contiguous statement run, stopping early if a control signal
    /// fires (left set on `self` for the enclosing loop to interpret).
    fn execStmtRun(self: *Interpreter, world: *World, locals: *Locals, start: u32, len: u32) StmtError!void {
        var s: u32 = 0;
        while (s < len) : (s += 1) {
            try self.execStmt(world, locals, @bitCast(self.ast.extra.items[start + s]));
            // Stop early on a control signal (break/continue), an in-flight
            // throw, or a `return` — all unwind out of the run (to the enclosing
            // loop / try, or the fn boundary for a return).
            if (self.control != .none or self.thrown or self.returning) return;
        }
    }

    /// Decide what a loop labeled `my_label` does with the active control
    /// signal: consume it (again / stop) or let it propagate to an outer loop.
    fn handleLoopControl(self: *Interpreter, my_label: StringId) LoopAction {
        switch (self.control) {
            .none => return .again,
            .break_ => {
                if (self.control_label == 0 or self.control_label == my_label) {
                    self.control = .none;
                    self.control_label = 0;
                    return .stop;
                }
                return .propagate;
            },
            .continue_ => {
                if (self.control_label == 0 or self.control_label == my_label) {
                    self.control = .none;
                    self.control_label = 0;
                    return .again;
                }
                return .propagate;
            },
        }
    }

    fn execStmt(self: *Interpreter, world: *World, locals: *Locals, stmt_id: NodeId) StmtError!void {
        const kind = self.ast.stmtKind(stmt_id);
        const data = self.ast.stmtData(stmt_id);
        switch (kind) {
            .let_stmt => {
                const let = self.ast.let_stmts.items[data];
                const v = try self.evalExpr(world, locals, let.value);
                try locals.put(self.gpa, let.name, v, let.is_mut or self.ast.exprKind(let.value) == .method_get_mut);
            },
            .assign_stmt => {
                const assign = self.ast.assign_stmts.items[data];
                try self.execAssign(world, locals, assign);
            },
            .expr_stmt => {
                const eid: NodeId = @bitCast(data);
                _ = try self.evalExpr(world, locals, eid);
            },
            .assert_stmt => {
                // `assert(cond)` — a false condition is a runtime failure (the
                // dev-build panic of `etch-reference-part1.md` §10.3, surfaced
                // here as a counted RuntimeReport error).
                const a = self.ast.assert_stmts.items[data];
                const v = try self.evalExpr(world, locals, a.cond);
                if (v != .bool_ or !v.bool_) return error.RuntimeFailure;
            },
            .for_stmt => {
                // `for v in range/array/map { body }` (M0.8). The loop variable
                // is rebound each iteration; `break`/`continue` (unlabeled, or a
                // label that escapes — `for` carries no label in E1) is handled
                // via `handleLoopControl(0)`.
                const f = self.ast.for_stmts.items[data];
                const iter = try self.evalExpr(world, locals, f.iterable);
                switch (iter) {
                    .range => |r| {
                        var i: i64 = r.start;
                        range_loop: while (if (r.inclusive) i <= r.end else i < r.end) : (i += 1) {
                            try locals.put(self.gpa, f.var_name, Value{ .int_ = i }, false);
                            try self.execStmtRun(world, locals, f.body_start, f.body_len);
                            if (self.thrown or self.returning) return; // throw / return unwinds out of the loop
                            switch (self.handleLoopControl(0)) {
                                .again => {},
                                .stop => break :range_loop,
                                .propagate => return,
                            }
                        }
                    },
                    .array_ref => |handle| {
                        // Snapshot the length once; re-index each iteration so a
                        // collection created in the body (which may grow the
                        // outer store vector) never leaves a stale pointer.
                        const len = self.collections.arrays.items[handle].items.len;
                        var k: usize = 0;
                        arr_loop: while (k < len) : (k += 1) {
                            const elem = self.collections.arrays.items[handle].items[k];
                            try locals.put(self.gpa, f.var_name, elem, false);
                            try self.execStmtRun(world, locals, f.body_start, f.body_len);
                            if (self.thrown or self.returning) return; // throw / return unwinds out of the loop
                            switch (self.handleLoopControl(0)) {
                                .again => {},
                                .stop => break :arr_loop,
                                .propagate => return,
                            }
                        }
                    },
                    .map_ref => |handle| {
                        // `for k, v in m` — bind key then value per entry (M0.8
                        // collections). Iteration order is insertion order in
                        // the interpreter (maps are unordered by contract, so a
                        // differential reads it only through an order-invariant
                        // reduction such as a sum).
                        const len = self.collections.maps.items[handle].items.len;
                        var k: usize = 0;
                        map_loop: while (k < len) : (k += 1) {
                            const pair = self.collections.maps.items[handle].items[k];
                            try locals.put(self.gpa, f.var_name, pair.key, false);
                            if (f.index_name != 0) try locals.put(self.gpa, f.index_name, pair.value, false);
                            try self.execStmtRun(world, locals, f.body_start, f.body_len);
                            if (self.thrown or self.returning) return; // throw / return unwinds out of the loop
                            switch (self.handleLoopControl(0)) {
                                .again => {},
                                .stop => break :map_loop,
                                .propagate => return,
                            }
                        }
                    },
                    else => return error.RuntimeFailure,
                }
            },
            .while_stmt => {
                // `while cond { body }` (M0.8 control flow). Re-evaluate the
                // condition each iteration; run the body run; an unlabeled
                // `break`/`continue` is consumed via `handleLoopControl(0)`; a
                // labeled signal for an outer loop, or a `throw`, propagates.
                // `while let x = <optional> { body }` (M0.8 E2 block 5): the
                // optional is re-evaluated each iteration; `some` binds `x` and
                // runs the body, `none` stops the loop.
                const wh = self.ast.while_stmts.items[data];
                while_loop: while (true) {
                    if (wh.let_binding != 0) {
                        const opt = try self.evalExpr(world, locals, wh.cond);
                        if (opt != .optional) return error.RuntimeFailure;
                        const payload = self.optionals.items[opt.optional] orelse break :while_loop;
                        try locals.put(self.gpa, wh.let_binding, payload, false);
                    } else {
                        const cond = try self.evalExpr(world, locals, wh.cond);
                        if (cond != .bool_) return error.RuntimeFailure;
                        if (!cond.bool_) break :while_loop;
                    }
                    try self.execStmtRun(world, locals, wh.body_start, wh.body_len);
                    if (self.thrown or self.returning) return; // throw / return unwinds out of the loop
                    switch (self.handleLoopControl(0)) {
                        .again => {},
                        .stop => break :while_loop,
                        .propagate => return,
                    }
                }
            },
            .break_stmt => {
                // `break [label] [value]` (M0.8 loop/break) — raise the signal
                // for the enclosing loop to consume.
                const b = self.ast.break_stmts.items[data];
                self.break_value = if (b.value.isNone()) Value{ .unit = {} } else try self.evalExpr(world, locals, b.value);
                self.control_label = b.label;
                self.control = .break_;
            },
            .continue_stmt => {
                // `continue [label]` — the label id is stored directly in `data`.
                self.control_label = data;
                self.control = .continue_;
            },
            .throw_stmt => {
                // `throw expression` (M0.8 error handling) — raise the throw
                // signal carrying the evaluated value, to unwind to a `catch`.
                const t = self.ast.throw_stmts.items[data];
                self.thrown_value = try self.evalExpr(world, locals, t.value);
                self.thrown = true;
            },
            .try_catch_stmt => {
                // `try { ... } catch err { ... }` — run the try body; if it
                // threw, clear the signal, bind the caught value, run the catch
                // body (which may itself throw → re-propagates).
                const tc = self.ast.try_catch_stmts.items[data];
                try self.execStmtRun(world, locals, tc.try_start, tc.try_len);
                if (self.thrown) {
                    self.thrown = false;
                    try locals.put(self.gpa, tc.catch_name, self.thrown_value, false);
                    try self.execStmtRun(world, locals, tc.catch_start, tc.catch_len);
                }
            },
            .return_stmt => {
                // `return [expr]` (M0.8 E2 call mechanism) — evaluate the value
                // (or `unit` for a bare return) and raise the `returning` signal
                // to unwind to the enclosing fn-call boundary (mirrors `throw`).
                const value: NodeId = @bitCast(data);
                self.return_value = if (value.isNone()) Value{ .unit = {} } else try self.evalExpr(world, locals, value);
                self.returning = true;
            },
            .emit_stmt => {
                // `emit EventType { field: value, … }` (M0.8 E3). Evaluate the
                // field initializers and enqueue the event in the dynamic event
                // store. The comptime-typed `World.event_bus` is unusable by the
                // tree-walker; `@on_event` observers drain this store (deferred
                // to the E3 observer tranche, resolver-types §12).
                const em = self.ast.emit_stmts.items[data];
                var fields: std.ArrayListUnmanaged(StructField) = .empty;
                errdefer fields.deinit(self.gpa);
                var i: u32 = 0;
                while (i < em.fields_len) : (i += 1) {
                    const flit = self.ast.struct_lit_fields.items[em.fields_start + i];
                    const v = try self.evalExpr(world, locals, flit.value);
                    try fields.append(self.gpa, .{ .name = flit.name, .value = v });
                }
                try self.events.enqueue(self.gpa, em.event_type, fields);
            },
            .tag_mutation_stmt => {
                // `entity.add_tag(.path)` / `entity.remove_tag(.path)` (M0.8 E3,
                // `etch-grammar.md` §4.4) — a deferred structural change. Resolve
                // the receiver to an entity + the path to its leaf bit, then
                // queue the mutation; the flush at the tick boundary applies it
                // (adding `TagSet` if absent), never mid-archetype-walk.
                const tm = self.ast.tag_mutation_stmts.items[data];
                const recv = try self.evalExpr(world, locals, tm.receiver);
                const entity = switch (recv) {
                    .entity_id => |e| e,
                    else => return error.RuntimeFailure,
                };
                const bit = self.tagPathLeafBit(tm.path) orelse return error.RuntimeFailure;
                try self.pending_tags.append(self.gpa, .{
                    .entity = entity,
                    .bit_index = bit,
                    .set = tm.kind == .add,
                });
            },
            else => return error.RuntimeFailure,
        }
    }

    fn execAssign(self: *Interpreter, world: *World, locals: *Locals, assign: ast_mod.AssignStmt) StmtError!void {
        const target_kind = self.ast.exprKind(assign.target);
        if (target_kind == .ident) {
            const name_id: StringId = self.ast.exprData(assign.target);
            const cur = locals.get(name_id) orelse return error.RuntimeFailure;
            const rhs = try self.evalExpr(world, locals, assign.value);
            const new_v = applyAssignOp(cur, assign.op, rhs) catch return error.RuntimeFailure;
            const ptr = locals.getPtr(name_id) orelse return error.RuntimeFailure;
            ptr.* = new_v;
            return;
        }
        if (target_kind == .field_access) {
            const fa = self.ast.field_accesses.items[self.ast.exprData(assign.target)];
            const recv = try self.evalExpr(world, locals, fa.receiver);
            const field_name = self.ast.strings.slice(fa.field_name);
            switch (recv) {
                .component_ref => |cref| {
                    if (!cref.mutable) return error.RuntimeFailure;
                    const cur = Bridge.readComponentField(&world.registry, cref, world, field_name) catch return error.RuntimeFailure;
                    const rhs = try self.evalExpr(world, locals, assign.value);
                    const new_v = applyAssignOp(cur, assign.op, rhs) catch return error.RuntimeFailure;
                    Bridge.writeComponentField(&world.registry, cref, world, field_name, new_v) catch return error.RuntimeFailure;
                    // Change detection (M0.8 E3): stamp `changed_tick = current_tick`
                    // so an `entity has T changed` rule sees this write. Gated on
                    // `has_changed` — a `changed`-free program never marks. Same
                    // logical point as the codegen's post-write `markChanged`.
                    if (self.has_changed) Bridge.markComponentChanged(world, cref, world.current_tick);
                    return;
                },
                .resource_ref => |rref| {
                    if (!rref.mutable) return error.RuntimeFailure;
                    const cur = Bridge.readResourceField(&world.registry, &world.resources, rref.resource_id, field_name) catch return error.RuntimeFailure;
                    const rhs = try self.evalExpr(world, locals, assign.value);
                    const new_v = applyAssignOp(cur, assign.op, rhs) catch return error.RuntimeFailure;
                    Bridge.writeResourceField(&world.registry, &world.resources, rref.resource_id, field_name, new_v) catch return error.RuntimeFailure;
                    return;
                },
                // Struct field write (M0.8 E2 block 3) — `self.x = …` in a `mut
                // self` method, or `v.x = …` on a `let mut v`. The field index
                // is resolved before evaluating the rhs, then written back by
                // index (the rhs eval may move the outer store, never the
                // field's backing buffer).
                .struct_ref => |handle| {
                    var fi: ?usize = null;
                    for (self.structs.list.items[handle].fields.items, 0..) |f, k| {
                        if (f.name == fa.field_name) {
                            fi = k;
                            break;
                        }
                    }
                    const k = fi orelse return error.RuntimeFailure;
                    const cur = self.structs.list.items[handle].fields.items[k].value;
                    const rhs = try self.evalExpr(world, locals, assign.value);
                    const new_v = applyAssignOp(cur, assign.op, rhs) catch return error.RuntimeFailure;
                    self.structs.list.items[handle].fields.items[k].value = new_v;
                    return;
                },
                else => return error.RuntimeFailure,
            }
        }
        return error.RuntimeFailure;
    }

    /// Invoke a top-level `fn` (free call, M0.8 E2 call mechanism). Args are
    /// evaluated in the caller's scope, then bound into a fresh frame; the body
    /// run executes there. A `return` inside the body raises `self.returning`,
    /// consumed at this boundary; with no explicit return the trailing block
    /// value is the implicit return. `async fn` interpretation is E3 (fail loud).
    fn callFn(self: *Interpreter, world: *World, caller_locals: *Locals, fndecl: ast_mod.FnDecl, call: ast_mod.CallExpr) StmtError!Value {
        if (fndecl.is_async) return error.RuntimeFailure; // async interp lands in E3
        if (fndecl.params_len != call.args_len) return error.RuntimeFailure;
        var frame: Locals = .{};
        defer frame.deinit(self.gpa);
        var i: u32 = 0;
        while (i < fndecl.params_len) : (i += 1) {
            const p = self.ast.fn_params.items[fndecl.params_start + i];
            const arg: NodeId = @bitCast(self.ast.extra.items[call.args_start + i]);
            const av = try self.evalExpr(world, caller_locals, arg);
            try frame.put(self.gpa, p.name, av, false);
        }
        try self.execStmtRun(world, &frame, fndecl.body_start, fndecl.body_len);
        if (self.returning) {
            self.returning = false;
            const rv = self.return_value;
            self.return_value = .{ .unit = {} };
            return rv;
        }
        // A throw / break / continue escaping a fn body is malformed in block 2
        // (no enclosing try / loop around the call): leave the signal set and
        // yield unit.
        if (self.thrown or self.control != .none) return Value{ .unit = {} };
        // No explicit return → the trailing block value is the implicit return.
        if (fndecl.value.isNone()) return Value{ .unit = {} };
        return try self.evalExpr(world, &frame, fndecl.value);
    }

    /// Invoke an inherent `impl` method or associated fn (M0.8 E2 block 3).
    /// Mirrors `callFn` but, for an instance method, binds `self` to the
    /// receiver value first (`mut self` shares the struct handle, so mutation
    /// propagates back). `self_value == null` is an associated fn (no receiver).
    /// A `return` inside the body unwinds to *this* boundary (the method's own
    /// frame), never the caller's — `returning` is consumed here.
    /// Declaration-order index of `variant` within `edecl`, or `null` if the
    /// enum has no such variant (M0.8 E2 block 3 tranche B).
    fn enumVariantIndexOf(self: *Interpreter, edecl: ast_mod.EnumDecl, variant: StringId) ?u32 {
        var i: u32 = 0;
        while (i < edecl.variants_len) : (i += 1) {
            if (self.ast.enum_variants.items[edecl.variants_start + i].name == variant) return i;
        }
        return null;
    }

    /// Dispatch an instance method call on an already-evaluated receiver
    /// value — §5.5 order: inherent / trait on user types, then the builtin
    /// string / collection subsets. Split from the `.method_call` arm so the
    /// optional chain `recv?.method()` dispatches the same way on the
    /// unwrapped payload (M0.8 E3-C tranche 4) — same logical point as the
    /// resolver's `dispatchMethodOnType` split.
    fn dispatchMethodOnValue(self: *Interpreter, world: *World, locals: *Locals, mc: ast_mod.MethodCall, recv: Value) StmtError!Value {
        switch (recv) {
            .struct_ref => |handle| {
                const type_name = self.structs.list.items[handle].type_name;
                const key = methodKey(type_name, mc.method_name);
                const method = self.methods.get(key) orelse self.trait_methods.get(key) orelse return error.RuntimeFailure;
                return try self.callMethod(world, locals, method, mc, recv);
            },
            .entity_id => {
                // Trait method on an Entity (`impl Trait for Entity`). The
                // type key is the interned `Entity`; self is the handle.
                const entity_name = self.ast.strings.find("Entity") orelse return error.RuntimeFailure;
                const method = self.trait_methods.get(methodKey(entity_name, mc.method_name)) orelse return error.RuntimeFailure;
                return try self.callMethod(world, locals, method, mc, recv);
            },
            .string_id, .string_run => {
                // Builtin string methods (M0.8 sub-slice C tranche 1 —
                // minimal faithful subset). `len` → byte length, on a
                // literal (`string_id`) or a runtime-produced string
                // (`string_run`, tranche 1b); any other §12 method is
                // stdlib Phase 1+ → fail loud.
                const mname = self.ast.strings.slice(mc.method_name);
                if (std.mem.eql(u8, mname, "len")) {
                    const bytes = self.stringBytes(recv) orelse return error.RuntimeFailure;
                    return Value{ .int_ = @intCast(bytes.len) };
                }
                return error.RuntimeFailure;
            },
            .array_ref => |handle| {
                // Builtin dynamic-array methods (M0.8 E3-C tranches 3-4 —
                // minimal faithful subset of stdlib §13.2). `push` appends
                // (mut receiver enforced by the resolver), `len` is the
                // element count, `pop` removes and returns the last element
                // as `T?` (tranche 4, unlocked by the Optional ops); any
                // other §13 method is stdlib Phase 1+ → fail loud.
                const mname = self.ast.strings.slice(mc.method_name);
                if (std.mem.eql(u8, mname, "push")) {
                    if (mc.args_len != 1) return error.RuntimeFailure;
                    const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
                    const v = try self.evalExpr(world, locals, arg);
                    // Re-index after the arg eval (a nested collection
                    // could have grown the outer store vector).
                    try self.collections.arrays.items[handle].append(self.gpa, v);
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "len")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    return Value{ .int_ = @intCast(self.collections.arrays.items[handle].items.len) };
                }
                if (std.mem.eql(u8, mname, "pop")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    const popped: ?Value = self.collections.arrays.items[handle].pop();
                    const oh: u32 = @intCast(self.optionals.items.len);
                    try self.optionals.append(self.gpa, popped);
                    return Value{ .optional = oh };
                }
                return error.RuntimeFailure;
            },
            .map_ref => |handle| {
                // Builtin map methods (M0.8 E3-C tranche 3 — minimal
                // faithful subset of stdlib §14.2). `insert` is
                // last-write-wins through the same scan-replace-or-
                // append as the map literal (its `V?` return is out of
                // the subset — statement use only, the value here is
                // unit); `len` is the entry count; any other §14
                // method is stdlib Phase 1+ → fail loud.
                const mname = self.ast.strings.slice(mc.method_name);
                if (std.mem.eql(u8, mname, "insert")) {
                    if (mc.args_len != 2) return error.RuntimeFailure;
                    const karg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
                    const varg: NodeId = @bitCast(self.ast.extra.items[mc.args_start + 1]);
                    const k = try self.evalExpr(world, locals, karg);
                    const v = try self.evalExpr(world, locals, varg);
                    // Re-index after the arg evals (a nested collection
                    // could have grown the outer store vector).
                    var replaced = false;
                    for (self.collections.maps.items[handle].items) |*pair| {
                        if (pair.key.eql(k)) {
                            pair.value = v;
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) try self.collections.maps.items[handle].append(self.gpa, .{ .key = k, .value = v });
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "len")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    return Value{ .int_ = @intCast(self.collections.maps.items[handle].items.len) };
                }
                return error.RuntimeFailure;
            },
            // Methods on a component / resource ref are deferred (the
            // interpreter cannot recover the type name from a bare ref).
            else => return error.RuntimeFailure,
        }
    }

    fn callMethod(self: *Interpreter, world: *World, caller_locals: *Locals, method: ast_mod.FnDecl, mc: ast_mod.MethodCall, self_value: ?Value) StmtError!Value {
        if (method.is_async) return error.RuntimeFailure; // async interp lands in E3
        if (method.params_len != mc.args_len) return error.RuntimeFailure;
        var frame: Locals = .{};
        defer frame.deinit(self.gpa);
        if (self_value) |sv| {
            if (self.ast.strings.find("self")) |self_id| {
                try frame.put(self.gpa, self_id, sv, method.self_kind == .by_mut);
            }
        }
        var i: u32 = 0;
        while (i < method.params_len) : (i += 1) {
            const p = self.ast.fn_params.items[method.params_start + i];
            const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start + i]);
            const av = try self.evalExpr(world, caller_locals, arg);
            try frame.put(self.gpa, p.name, av, false);
        }
        try self.execStmtRun(world, &frame, method.body_start, method.body_len);
        if (self.returning) {
            self.returning = false;
            const rv = self.return_value;
            self.return_value = .{ .unit = {} };
            return rv;
        }
        if (self.thrown or self.control != .none) return Value{ .unit = {} };
        if (method.value.isNone()) return Value{ .unit = {} };
        return try self.evalExpr(world, &frame, method.value);
    }

    /// Free every per-body runtime string, keeping the list's capacity
    /// (rule-arena semantics, M0.8 sub-slice C tranche 1b).
    fn resetRunStrings(self: *Interpreter) void {
        for (self.run_strings.items) |s| self.gpa.free(s);
        self.run_strings.clearRetainingCapacity();
    }

    /// The bytes of a string value — an AST-table literal (`string_id`) or a
    /// runtime-produced string (`string_run`). Null for any non-string value.
    fn stringBytes(self: *const Interpreter, v: Value) ?[]const u8 {
        return switch (v) {
            .string_id => |sid| self.ast.strings.slice(sid),
            .string_run => |handle| self.run_strings.items[handle],
            else => null,
        };
    }

    /// Take ownership of `bytes` into the per-body runtime-string store,
    /// returning its `string_run` handle value.
    fn newRunString(self: *Interpreter, bytes: []u8) !Value {
        const handle: u32 = @intCast(self.run_strings.items.len);
        try self.run_strings.append(self.gpa, bytes);
        return Value{ .string_run = handle };
    }

    fn evalExpr(self: *Interpreter, world: *World, locals: *Locals, id: NodeId) StmtError!Value {
        const kind = self.ast.exprKind(id);
        const data = self.ast.exprData(id);
        switch (kind) {
            .int_lit => {
                const text = self.ast.strings.slice(data);
                const v = std.fmt.parseInt(i64, text, 10) catch return error.RuntimeFailure;
                return Value{ .int_ = v };
            },
            .float_lit => {
                const text = self.ast.strings.slice(data);
                const v = std.fmt.parseFloat(f64, text) catch return error.RuntimeFailure;
                return Value{ .float_ = v };
            },
            .bool_lit => {
                const text = self.ast.strings.slice(data);
                return Value{ .bool_ = std.mem.eql(u8, text, "true") };
            },
            .string_lit => return Value{ .string_id = data },
            .string_interp => {
                // Interpolation (M0.8 E3-C tranche 1c, stdlib §12.5:
                // compile-time lowering to segment ++ Display(expr) concat).
                // Pieces are formatted with the SAME `std.fmt` specs the
                // codegen's `allocPrint` uses (`{d}` for ints and floats,
                // literal true/false for bools, raw bytes for strings) —
                // identical formatting code in both backends → byte-exact.
                const si = self.ast.string_interps.items[data];
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(self.gpa);
                var k: u32 = 0;
                while (k < si.n_exprs) : (k += 1) {
                    const seg: u32 = self.ast.extra.items[si.segs_start + k];
                    try out.appendSlice(self.gpa, self.ast.strings.slice(seg));
                    const e: NodeId = @bitCast(self.ast.extra.items[si.exprs_start + k]);
                    const v = try self.evalExpr(world, locals, e);
                    switch (v) {
                        .int_ => |x| {
                            const piece = try std.fmt.allocPrint(self.gpa, "{d}", .{x});
                            defer self.gpa.free(piece);
                            try out.appendSlice(self.gpa, piece);
                        },
                        .float_ => |x| {
                            const piece = try std.fmt.allocPrint(self.gpa, "{d}", .{x});
                            defer self.gpa.free(piece);
                            try out.appendSlice(self.gpa, piece);
                        },
                        .bool_ => |x| try out.appendSlice(self.gpa, if (x) "true" else "false"),
                        .string_id, .string_run => try out.appendSlice(self.gpa, self.stringBytes(v).?),
                        // Any other type is resolver-gated (minimal Display
                        // subset) — fail loud if one slips through.
                        else => return error.RuntimeFailure,
                    }
                }
                const last_seg: u32 = self.ast.extra.items[si.segs_start + si.n_exprs];
                try out.appendSlice(self.gpa, self.ast.strings.slice(last_seg));
                return try self.newRunString(try out.toOwnedSlice(self.gpa));
            },
            // `none` / `some(x)` optional literals (M0.8 E2 block 5) →
            // materialise an entry in the optional store, return its handle.
            .none_lit => {
                const handle: u32 = @intCast(self.optionals.items.len);
                try self.optionals.append(self.gpa, null);
                return Value{ .optional = handle };
            },
            .some_lit => {
                const inner: NodeId = @bitCast(data);
                const payload = try self.evalExpr(world, locals, inner);
                const handle: u32 = @intCast(self.optionals.items.len);
                try self.optionals.append(self.gpa, payload);
                return Value{ .optional = handle };
            },
            .ident => {
                const name_id: StringId = data;
                if (locals.get(name_id)) |v| return v;
                return error.RuntimeFailure;
            },
            .field_access => {
                const fa = self.ast.field_accesses.items[data];
                // Enum value `Difficulty.hard` (M0.8 E2 block 3 tranche B): a
                // `.path` receiver naming a declared enum + a variant field.
                if (self.ast.exprKind(fa.receiver) == .path) {
                    const path_name = self.ast.exprData(fa.receiver);
                    if (self.enum_decls.get(path_name)) |edecl| {
                        if (self.enumVariantIndexOf(edecl, fa.field_name)) |vidx| {
                            return Value{ .enum_value = .{ .type_name = path_name, .variant = vidx } };
                        }
                        return error.RuntimeFailure;
                    }
                }
                const recv = try self.evalExpr(world, locals, fa.receiver);
                const field_name = self.ast.strings.slice(fa.field_name);
                switch (recv) {
                    .component_ref => |cref| return Bridge.readComponentField(&world.registry, cref, world, field_name) catch error.RuntimeFailure,
                    .resource_ref => |rref| return Bridge.readResourceField(&world.registry, &world.resources, rref.resource_id, field_name) catch error.RuntimeFailure,
                    // Struct field read (M0.8 E2 block 3) — `self.x` / `v.x`.
                    .struct_ref => |handle| {
                        for (self.structs.list.items[handle].fields.items) |f| {
                            if (f.name == fa.field_name) return f.value;
                        }
                        return error.RuntimeFailure;
                    },
                    else => return error.RuntimeFailure,
                }
            },
            .method_get, .method_get_mut => {
                const mg = self.ast.method_gets.items[data];
                const type_name = self.ast.strings.slice(mg.type_name);
                const mutable = (kind == .method_get_mut);
                // Receiver-less `get(T)` / `get_mut(T)` — resource access
                // (D-S3-resource-receiver). The type-checker has already
                // proven `T` is a resource present in the when clause.
                if (mg.receiver.isNone()) {
                    const rid = self.bridge.resourceIdOf(type_name) orelse return error.RuntimeFailure;
                    return Value{ .resource_ref = .{ .resource_id = rid, .mutable = mutable } };
                }
                const recv = try self.evalExpr(world, locals, mg.receiver);
                if (recv != .entity_id) return error.RuntimeFailure;
                const comp_id = self.bridge.componentIdOf(type_name) orelse return error.RuntimeFailure;
                const cref = Bridge.componentRefOf(world, recv.entity_id, comp_id, mutable) catch return error.RuntimeFailure;
                return Value{ .component_ref = cref };
            },
            .binary => {
                const b = self.ast.binary_exprs.items[data];
                // `expr ?? default` (M0.8 E3-C tranche 4, stdlib §16.2):
                // unwrap-or-default. The default is NOT evaluated when the
                // lhs is `some` — short-circuit, the same semantics as the
                // codegen's Zig `orelse` (byte-exact by construction).
                if (b.op == .coalesce) {
                    const lhs = try self.evalExpr(world, locals, b.lhs);
                    if (lhs != .optional) return error.RuntimeFailure;
                    if (self.optionals.items[lhs.optional]) |payload| return payload;
                    return try self.evalExpr(world, locals, b.rhs);
                }
                const lhs = try self.evalExpr(world, locals, b.lhs);
                const rhs = try self.evalExpr(world, locals, b.rhs);
                // `string + string` → concatenation into the per-body
                // runtime-string store (M0.8 sub-slice C tranche 1b, stdlib
                // §12.4). Same logical point as the codegen's frame-arena
                // `std.mem.concat` on the binary `.add` — byte-exact by
                // construction. A string mixed with a non-string operand is
                // resolver-rejected; fail loud if one slips through.
                if (b.op == .add) {
                    if (self.stringBytes(lhs)) |lb| {
                        const rb = self.stringBytes(rhs) orelse return error.RuntimeFailure;
                        const bytes = try std.mem.concat(self.gpa, u8, &.{ lb, rb });
                        return try self.newRunString(bytes);
                    }
                }
                return switch (b.op) {
                    .add, .sub, .mul, .div, .rem => binaryArith(b.op, lhs, rhs) catch return error.RuntimeFailure,
                    .eq, .neq, .lt, .gt, .le, .ge => binaryCompare(b.op, lhs, rhs) catch return error.RuntimeFailure,
                    .logical_and => {
                        if (lhs != .bool_ or rhs != .bool_) return error.RuntimeFailure;
                        return Value{ .bool_ = lhs.bool_ and rhs.bool_ };
                    },
                    .logical_or => {
                        if (lhs != .bool_ or rhs != .bool_) return error.RuntimeFailure;
                        return Value{ .bool_ = lhs.bool_ or rhs.bool_ };
                    },
                    .coalesce => unreachable, // handled (short-circuit) above
                };
            },
            .unary => {
                const u = self.ast.unary_exprs.items[data];
                const v = try self.evalExpr(world, locals, u.operand);
                return switch (u.op) {
                    .neg => switch (v) {
                        .int_ => |x| Value{ .int_ = -x },
                        .float_ => |x| Value{ .float_ = -x },
                        else => error.RuntimeFailure,
                    },
                    .logical_not => switch (v) {
                        .bool_ => |x| Value{ .bool_ = !x },
                        else => error.RuntimeFailure,
                    },
                    // `expr!` — force unwrap, panic on none (M0.8 E3-C
                    // tranche 4, stdlib §16.2). The interp's panic is
                    // RuntimeFailure, same observable as the codegen's `.?`
                    // null-unwrap panic.
                    .force_unwrap => {
                        if (v != .optional) return error.RuntimeFailure;
                        return self.optionals.items[v.optional] orelse error.RuntimeFailure;
                    },
                };
            },
            .range => {
                // `start..end` / `start..=end` → an integer range value
                // (M0.8 v0.6 foundations). Consumed by `for-in`.
                const r = self.ast.ranges.items[data];
                const start_v = try self.evalExpr(world, locals, r.start);
                const end_v = try self.evalExpr(world, locals, r.end);
                if (start_v != .int_ or end_v != .int_) return error.RuntimeFailure;
                return Value{ .range = .{ .start = start_v.int_, .end = end_v.int_, .inclusive = r.inclusive } };
            },
            .match_expr => {
                // First matching arm wins (M0.8 v0.6 foundations). Wildcard
                // and binding always match; a binding binds the scrutinee for
                // its arm body. The type-checker has proven exhaustiveness, so
                // a fall-through is a real runtime failure.
                const m = self.ast.match_exprs.items[data];
                const scrut = try self.evalExpr(world, locals, m.scrutinee);
                var i: u32 = 0;
                while (i < m.arms_len) : (i += 1) {
                    const arm = self.ast.match_arms.items[m.arms_start + i];
                    switch (arm.pattern_kind) {
                        .wildcard => return try self.evalExpr(world, locals, arm.body),
                        .binding => {
                            try locals.put(self.gpa, arm.pattern_payload, scrut, false);
                            return try self.evalExpr(world, locals, arm.body);
                        },
                        .literal => {
                            const lit: NodeId = @bitCast(arm.pattern_payload);
                            const lit_v = try self.evalExpr(world, locals, lit);
                            if (scrut.eql(lit_v)) return try self.evalExpr(world, locals, arm.body);
                        },
                        .enum_variant => {
                            // Compare the scrutinee's enum value against the
                            // pattern's variant (M0.8 E2 block 3 tranche B). The
                            // pattern carries the variant name; resolve it to the
                            // declaration-order index of the scrutinee's enum.
                            if (scrut != .enum_value) return error.RuntimeFailure;
                            const pat = self.ast.enum_pattern_payloads.items[arm.pattern_payload];
                            const edecl = self.enum_decls.get(scrut.enum_value.type_name) orelse return error.RuntimeFailure;
                            const vidx = self.enumVariantIndexOf(edecl, pat.variant) orelse return error.RuntimeFailure;
                            if (scrut.enum_value.variant == vidx) return try self.evalExpr(world, locals, arm.body);
                        },
                        // `some(v)` / `none` optional patterns (M0.8 E3-C
                        // tranche 4, part1 §7.6): `some` binds the payload
                        // for its arm body.
                        .optional_some => {
                            if (scrut != .optional) return error.RuntimeFailure;
                            if (self.optionals.items[scrut.optional]) |payload| {
                                try locals.put(self.gpa, arm.pattern_payload, payload, false);
                                return try self.evalExpr(world, locals, arm.body);
                            }
                        },
                        .optional_none => {
                            if (scrut != .optional) return error.RuntimeFailure;
                            if (self.optionals.items[scrut.optional] == null) {
                                return try self.evalExpr(world, locals, arm.body);
                            }
                        },
                    }
                }
                return error.RuntimeFailure;
            },
            .cast => {
                // `operand as Type` (M0.8 v0.6 foundations). Runtime values
                // carry int as i64 and float as f64; a cast only flips the
                // numeric domain (int↔float). Integer width narrowing is a
                // storage concern handled on write, not in the Value.
                const c = self.ast.casts.items[data];
                const v = try self.evalExpr(world, locals, c.operand);
                const named = self.ast.named_types.items[self.ast.typeNodeData(c.type_node)];
                const tname = self.ast.strings.slice(self.ast.resolveTypeAliasName(named.name));
                const to_float = std.mem.eql(u8, tname, "float") or std.mem.eql(u8, tname, "f32") or std.mem.eql(u8, tname, "f64");
                return switch (v) {
                    .int_ => |x| if (to_float) Value{ .float_ = @floatFromInt(x) } else Value{ .int_ = x },
                    .float_ => |x| if (to_float) Value{ .float_ = x } else Value{ .int_ = @intFromFloat(x) },
                    else => error.RuntimeFailure,
                };
            },
            .array_lit => {
                // `[a, b, c]` / `[v; n]` → materialize a fresh array in the
                // rule-body collection store, return its handle (M0.8
                // collections). E1 elements are builtin scalars (the
                // type-checker rejects non-builtin / nested-array elements).
                const al = self.ast.array_lits.items[data];
                const handle = try self.collections.newArray(self.gpa);
                if (al.is_fill) {
                    const elem_id: NodeId = @bitCast(self.ast.extra.items[al.elements_start]);
                    const elem_v = try self.evalExpr(world, locals, elem_id);
                    const count_v = try self.evalExpr(world, locals, al.fill_count);
                    if (count_v != .int_ or count_v.int_ < 0) return error.RuntimeFailure;
                    var k: i64 = 0;
                    while (k < count_v.int_) : (k += 1) {
                        try self.collections.arrays.items[handle].append(self.gpa, elem_v);
                    }
                } else {
                    var i: u32 = 0;
                    while (i < al.elements_len) : (i += 1) {
                        const e: NodeId = @bitCast(self.ast.extra.items[al.elements_start + i]);
                        const v = try self.evalExpr(world, locals, e);
                        // Re-index `arrays.items[handle]` after each element eval
                        // (a nested collection could have grown the outer vec).
                        try self.collections.arrays.items[handle].append(self.gpa, v);
                    }
                }
                return Value{ .array_ref = handle };
            },
            .map_lit => {
                // `[k: v, ...]` → materialize a fresh map in the rule-body
                // store (M0.8 collections). Duplicate keys are last-write-wins
                // — the same scan-replace-or-append the tranche-3 codegen
                // emits (`__etchMapInsert`), so the two backends agree on
                // iteration order by construction.
                const ml = self.ast.map_lits.items[data];
                const handle = try self.collections.newMap(self.gpa);
                var i: u32 = 0;
                while (i < ml.entries_len) : (i += 1) {
                    const entry = self.ast.map_entries.items[ml.entries_start + i];
                    const k = try self.evalExpr(world, locals, entry.key);
                    const v = try self.evalExpr(world, locals, entry.value);
                    var replaced = false;
                    for (self.collections.maps.items[handle].items) |*pair| {
                        if (pair.key.eql(k)) {
                            pair.value = v;
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) try self.collections.maps.items[handle].append(self.gpa, .{ .key = k, .value = v });
                }
                return Value{ .map_ref = handle };
            },
            .index => {
                // `receiver[index]` — slice if the index is a range, else a
                // single element (M0.8 collections). Out-of-bounds is a
                // runtime error (the debug panic of `etch-stdlib.md` §13.3).
                const ix = self.ast.index_exprs.items[data];
                const recv = try self.evalExpr(world, locals, ix.receiver);
                if (recv == .map_ref) {
                    // `m[k] -> V?` (stdlib §14.2, M0.8 E3-C tranche 4): scan
                    // the insertion-ordered pair list — found → some(value),
                    // absent → none. Same lookup the codegen's __etchMapGet
                    // helper performs, byte-exact by construction.
                    const key_v = try self.evalExpr(world, locals, ix.index);
                    var found: ?Value = null;
                    for (self.collections.maps.items[recv.map_ref].items) |pair| {
                        if (pair.key.eql(key_v)) {
                            found = pair.value;
                            break;
                        }
                    }
                    const oh: u32 = @intCast(self.optionals.items.len);
                    try self.optionals.append(self.gpa, found);
                    return Value{ .optional = oh };
                }
                if (recv != .array_ref) return error.RuntimeFailure;
                if (self.ast.exprKind(ix.index) == .range) {
                    const r = self.ast.ranges.items[self.ast.exprData(ix.index)];
                    const start_v = try self.evalExpr(world, locals, r.start);
                    const end_v = try self.evalExpr(world, locals, r.end);
                    if (start_v != .int_ or end_v != .int_) return error.RuntimeFailure;
                    const lo = std.math.cast(usize, start_v.int_) orelse return error.RuntimeFailure;
                    var hi = std.math.cast(usize, end_v.int_) orelse return error.RuntimeFailure;
                    if (r.inclusive) hi += 1;
                    const src_len = self.collections.arrays.items[recv.array_ref].items.len;
                    if (lo > hi or hi > src_len) return error.RuntimeFailure;
                    const handle = try self.collections.newArray(self.gpa);
                    // Re-fetch the source after newArray (it may have realloc'd
                    // the outer vector, invalidating an earlier pointer).
                    const src = self.collections.arrays.items[recv.array_ref];
                    try self.collections.arrays.items[handle].appendSlice(self.gpa, src.items[lo..hi]);
                    return Value{ .array_ref = handle };
                }
                const idx_v = try self.evalExpr(world, locals, ix.index);
                if (idx_v != .int_) return error.RuntimeFailure;
                const arr = self.collections.arrays.items[recv.array_ref];
                const i = std.math.cast(usize, idx_v.int_) orelse return error.RuntimeFailure;
                if (i >= arr.items.len) return error.RuntimeFailure;
                return arr.items[i];
            },
            .closure => {
                // `|a| body` → snapshot the locals as the captured env (value
                // capture, §5.6) and return a closure handle (M0.8 closures).
                var captured: std.AutoHashMapUnmanaged(StringId, Value) = .empty;
                errdefer captured.deinit(self.gpa);
                var it = locals.map.iterator();
                while (it.next()) |e| try captured.put(self.gpa, e.key_ptr.*, e.value_ptr.value);
                const handle = try self.closures.newClosure(self.gpa, id, captured);
                return Value{ .closure = handle };
            },
            .fn_call => {
                // `callee(args)` — two callee shapes: a top-level `fn` (free
                // call, M0.8 E2) when the callee is an ident naming a `fn` and
                // not a local binding; otherwise a closure-typed local (E1).
                const call = self.ast.call_exprs.items[data];
                if (self.ast.exprKind(call.callee) == .ident) {
                    const callee_name = self.ast.exprData(call.callee);
                    if (locals.get(callee_name) == null) {
                        if (self.fns.get(callee_name)) |fndecl| {
                            return try self.callFn(world, locals, fndecl, call);
                        }
                    }
                }
                // E1 closure invocation: build a call frame from the captured
                // env plus the parameters bound to the arguments (evaluated in
                // the caller's scope), then evaluate the body in that frame.
                const callee = try self.evalExpr(world, locals, call.callee);
                if (callee != .closure) return error.RuntimeFailure;
                const handle = callee.closure;
                const node = self.closures.list.items[handle].node;
                const ce = self.ast.closure_exprs.items[self.ast.exprData(node)];
                if (ce.params_len != call.args_len) return error.RuntimeFailure;
                var frame: Locals = .{};
                defer frame.deinit(self.gpa);
                // Copy the captured environment into the frame first (before any
                // arg eval can grow / realloc the closure store).
                var cap_it = self.closures.list.items[handle].captured.iterator();
                while (cap_it.next()) |e| try frame.put(self.gpa, e.key_ptr.*, e.value_ptr.*, false);
                var i: u32 = 0;
                while (i < ce.params_len) : (i += 1) {
                    const p = self.ast.closure_params.items[ce.params_start + i];
                    const arg: NodeId = @bitCast(self.ast.extra.items[call.args_start + i]);
                    const av = try self.evalExpr(world, locals, arg);
                    try frame.put(self.gpa, p.name, av, false);
                }
                return try self.evalExpr(world, &frame, ce.body);
            },
            .struct_lit => {
                // `T { f: v, … }` → materialize a fresh struct value in the
                // rule-body struct store (M0.8 E2 block 3). Every declared field
                // is filled in declaration order: the literal's value if given,
                // else the field's const default (matching the Zig codegen,
                // which relies on the `extern struct` default-fill). The handle
                // is re-fetched after each field eval (a nested struct literal
                // may have grown the outer store vector).
                const sl = self.ast.struct_lits.items[data];
                const decl = self.struct_decls.get(sl.type_name) orelse return error.RuntimeFailure;
                const handle = try self.structs.newStruct(self.gpa, sl.type_name);
                var fi: u32 = 0;
                while (fi < decl.fields_len) : (fi += 1) {
                    const f = self.ast.fields.items[decl.fields_start + fi];
                    var provided: ?Value = null;
                    var li: u32 = 0;
                    while (li < sl.fields_len) : (li += 1) {
                        const flit = self.ast.struct_lit_fields.items[sl.fields_start + li];
                        if (flit.name == f.name) {
                            provided = try self.evalExpr(world, locals, flit.value);
                            break;
                        }
                    }
                    const fval = provided orelse blk: {
                        if (f.default_value.isNone()) break :blk Value{ .int_ = 0 };
                        break :blk evalConst(self.ast, f.default_value) catch Value{ .int_ = 0 };
                    };
                    try self.structs.list.items[handle].fields.append(self.gpa, .{ .name = f.name, .value = fval });
                }
                return Value{ .struct_ref = handle };
            },
            .method_call => {
                // `recv.method(args)` / `Type.assoc(args)` — dispatch in the
                // §5.5 order (inherent → trait). Associated fn: a bare type-path
                // receiver, no self. Instance method: a struct receiver (self
                // bound to it — a `mut self` method mutates it in place via the
                // shared store handle) or an `Entity` receiver for a trait method
                // (`impl Trait for Entity`; mutation flows through `self.get_mut`).
                const mc = self.ast.method_calls.items[data];
                if (self.ast.exprKind(mc.receiver) == .path) {
                    const type_name = self.ast.exprData(mc.receiver);
                    const method = self.methods.get(methodKey(type_name, mc.method_name)) orelse return error.RuntimeFailure;
                    return try self.callMethod(world, locals, method, mc, null);
                }
                const recv = try self.evalExpr(world, locals, mc.receiver);
                // `recv?.method(args)` — optional chain (M0.8 E3-C tranche 4,
                // part1 §6.6): `none` short-circuits to a fresh `none` without
                // dispatching; `some(p)` dispatches on the payload and
                // re-wraps the result in an optional.
                if (mc.opt_chain) {
                    if (recv != .optional) return error.RuntimeFailure;
                    const payload = self.optionals.items[recv.optional] orelse {
                        const oh: u32 = @intCast(self.optionals.items.len);
                        try self.optionals.append(self.gpa, null);
                        return Value{ .optional = oh };
                    };
                    const res = try self.dispatchMethodOnValue(world, locals, mc, payload);
                    const oh: u32 = @intCast(self.optionals.items.len);
                    try self.optionals.append(self.gpa, res);
                    return Value{ .optional = oh };
                }
                return try self.dispatchMethodOnValue(world, locals, mc, recv);
            },
            .loop_expr => {
                // `loop { body }` — run the body repeatedly until a `break`
                // targeting this loop fires; the loop's value is that break's
                // value (M0.8 loop/break). A labeled break / continue for an
                // outer loop propagates (control left set, unit returned).
                const lp = self.ast.loop_exprs.items[data];
                while (true) {
                    try self.execStmtRun(world, locals, lp.body_start, lp.body_len);
                    if (self.thrown or self.returning) return Value{ .unit = {} }; // throw / return unwinds out
                    switch (self.control) {
                        .none => {}, // body completed → loop again (infinite)
                        .break_ => {
                            if (self.control_label == 0 or self.control_label == lp.label) {
                                self.control = .none;
                                self.control_label = 0;
                                return self.break_value;
                            }
                            return Value{ .unit = {} }; // propagate to outer loop
                        },
                        .continue_ => {
                            if (self.control_label == 0 or self.control_label == lp.label) {
                                self.control = .none;
                                self.control_label = 0; // continue → loop again
                            } else {
                                return Value{ .unit = {} }; // propagate
                            }
                        },
                    }
                }
            },
            .block_expr => {
                // `{ stmts; value }` — run the body statements, then evaluate
                // the trailing value (or `unit` when value-less). A control
                // signal (`break`/`continue`) or an in-flight `throw` raised in
                // the body unwinds out of the block: it is left set on `self`
                // for the enclosing loop / `try` to interpret, and the block
                // yields `unit` (M0.8 control flow).
                const blk = self.ast.block_exprs.items[data];
                try self.execStmtRun(world, locals, blk.body_start, blk.body_len);
                if (self.control != .none or self.thrown or self.returning) return Value{ .unit = {} };
                if (blk.value.isNone()) return Value{ .unit = {} };
                return try self.evalExpr(world, locals, blk.value);
            },
            .if_expr => {
                const ife = self.ast.if_exprs.items[data];
                // `if let x = <optional> { then } [else { else }]` (M0.8 E2 block
                // 5): unwrap the optional — `some` binds `x` to the payload and
                // runs the then-block; `none` runs the else (or yields unit).
                if (ife.let_binding != 0) {
                    const opt = try self.evalExpr(world, locals, ife.cond);
                    if (opt != .optional) return error.RuntimeFailure;
                    if (self.optionals.items[opt.optional]) |payload| {
                        try locals.put(self.gpa, ife.let_binding, payload, false);
                        return try self.evalExpr(world, locals, ife.then_block);
                    }
                    if (ife.else_branch.isNone()) return Value{ .unit = {} };
                    return try self.evalExpr(world, locals, ife.else_branch);
                }
                // `if cond { then } [else if ...] [else { else }]` (M0.8 control
                // flow). Evaluate the condition; run the matching branch (a
                // block expression, or a nested `if` for `else if`). An `if`
                // with no `else` and a false condition yields `unit`. Branch
                // evaluation propagates any control / throw signal raised in it.
                const cond = try self.evalExpr(world, locals, ife.cond);
                if (cond != .bool_) return error.RuntimeFailure;
                if (cond.bool_) return try self.evalExpr(world, locals, ife.then_block);
                if (ife.else_branch.isNone()) return Value{ .unit = {} };
                return try self.evalExpr(world, locals, ife.else_branch);
            },
            else => return error.RuntimeFailure, // path / tag_path / unsupported variants
        }
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────

fn resourceDepsSatisfied(world: *World, rd: RuleDesc) bool {
    for (rd.resource_deps) |dep| {
        if (!world.resources.contains(dep.resource_id)) return false;
        if (dep.must_be_changed and !world.resources.isDirty(dep.resource_id)) return false;
    }
    return true;
}

fn evalPredicate(pool: []const PredicateNode, root: u32, arch: *const DynamicArchetype) bool {
    const node = pool[root];
    return switch (node.kind) {
        .and_ => evalPredicate(pool, node.lhs, arch) and evalPredicate(pool, node.rhs, arch),
        .or_ => evalPredicate(pool, node.lhs, arch) or evalPredicate(pool, node.rhs, arch),
        .not_ => !evalPredicate(pool, node.lhs, arch),
        .has => arch.hasComponent(node.component_id),
    };
}

fn filterPasses(arch: *DynamicArchetype, chunk: *Chunk, ff: FieldFilter, slot: u32) bool {
    const idx = arch.componentIndex(ff.component_id) orelse return false;
    const slot_bytes = arch.componentSlot(chunk, idx, slot);
    const f_bytes = slot_bytes[ff.field_offset .. ff.field_offset + @as(u16, @intCast(ff.field_kind.sizeBytes()))];
    const v = bridge_mod.readBytesAsValue(ff.field_kind, f_bytes);
    return v.eql(ff.expected_value);
}

/// Whether every `changed` filter passes for `(chunk, slot)` (M0.8 E3): each
/// listed component's `changedTick` must exceed `last_run_tick`
/// (`engine-ecs-internals.md` §5). The `has T` archetype predicate guarantees
/// the component is present, so a missing column is an inconsistent program.
fn changedFiltersPass(arch: *DynamicArchetype, chunk: *Chunk, slot: u32, cids: []const ComponentId, last_run_tick: Tick) bool {
    for (cids) |cid| {
        const col = arch.componentIndex(cid) orelse return false;
        if (!(arch.changedTick(chunk, col, slot) > last_run_tick)) return false;
    }
    return true;
}

/// Whether bit `bit` of `entity`'s `TagSet` is set (M0.8 E3). An entity with no
/// `TagSet` component reads as all-zero.
fn entityTagBitSet(world: *World, tagset_id: ComponentId, entity: EntityId, bit: u32) bool {
    const core_id: CoreEntityId = @bitCast(entity);
    const loc = world.dynamicLocation(core_id) orelse return false;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const col = arch.componentIndex(tagset_id) orelse return false;
    const chunk = arch.chunks.items[loc.chunk_idx];
    const bytes = arch.componentSlot(chunk, col, loc.slot);
    const off: usize = @as(usize, bit / 64) * 8;
    var word: u64 = 0;
    @memcpy(std.mem.asBytes(&word), bytes[off .. off + 8]);
    return (word & (@as(u64, 1) << @intCast(bit % 64))) != 0;
}

fn bindParams(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    rule: ast_mod.RuleDecl,
    entity_id: ?EntityId,
    locals: *Locals,
) !void {
    var i: u32 = 0;
    while (i < rule.params_len) : (i += 1) {
        const p = ast.rule_params.items[rule.params_start + i];
        const v: Value = blk: {
            const tnode = ast.named_types.items[ast.typeNodeData(p.type_node)];
            const tname = ast.strings.slice(tnode.name);
            if (std.mem.eql(u8, tname, "Entity")) {
                if (entity_id) |id| break :blk Value{ .entity_id = id };
                break :blk Value{ .entity_id = value_mod.invalid_entity };
            }
            if (std.mem.eql(u8, tname, "int")) break :blk Value{ .int_ = 0 };
            if (std.mem.eql(u8, tname, "float")) break :blk Value{ .float_ = 0.0 };
            if (std.mem.eql(u8, tname, "bool")) break :blk Value{ .bool_ = false };
            if (std.mem.eql(u8, tname, "i32") or std.mem.eql(u8, tname, "u32")) break :blk Value{ .int_ = 0 };
            if (std.mem.eql(u8, tname, "f32") or std.mem.eql(u8, tname, "f64")) break :blk Value{ .float_ = 0.0 };
            break :blk Value{ .unit = {} };
        };
        try locals.put(gpa, p.name, v, false);
    }
}

fn applyAssignOp(cur: Value, op: ast_mod.AssignOp, rhs: Value) !Value {
    return switch (op) {
        .assign => rhs,
        .add_assign => try binaryArith(.add, cur, rhs),
        .sub_assign => try binaryArith(.sub, cur, rhs),
        .mul_assign => try binaryArith(.mul, cur, rhs),
        .div_assign => try binaryArith(.div, cur, rhs),
        .rem_assign => try binaryArith(.rem, cur, rhs),
    };
}

fn binaryArith(op: ast_mod.BinaryOp, a: Value, b: Value) !Value {
    if (a == .int_ and b == .int_) {
        return switch (op) {
            .add => Value{ .int_ = value_mod.intAddChecked(a.int_, b.int_) orelse return error.RuntimeFailure },
            .sub => Value{ .int_ = value_mod.intSubChecked(a.int_, b.int_) orelse return error.RuntimeFailure },
            .mul => Value{ .int_ = value_mod.intMulChecked(a.int_, b.int_) orelse return error.RuntimeFailure },
            .div => Value{ .int_ = value_mod.intDiv(a.int_, b.int_) orelse return error.RuntimeFailure },
            .rem => Value{ .int_ = value_mod.intRem(a.int_, b.int_) orelse return error.RuntimeFailure },
            else => unreachable,
        };
    }
    if (a == .float_ and b == .float_) {
        return switch (op) {
            .add => Value{ .float_ = a.float_ + b.float_ },
            .sub => Value{ .float_ = a.float_ - b.float_ },
            .mul => Value{ .float_ = a.float_ * b.float_ },
            .div => Value{ .float_ = a.float_ / b.float_ },
            .rem => Value{ .float_ = @rem(a.float_, b.float_) },
            else => unreachable,
        };
    }
    return error.RuntimeFailure;
}

fn binaryCompare(op: ast_mod.BinaryOp, a: Value, b: Value) !Value {
    if (a == .int_ and b == .int_) {
        const r = switch (op) {
            .eq => a.int_ == b.int_,
            .neq => a.int_ != b.int_,
            .lt => a.int_ < b.int_,
            .gt => a.int_ > b.int_,
            .le => a.int_ <= b.int_,
            .ge => a.int_ >= b.int_,
            else => unreachable,
        };
        return Value{ .bool_ = r };
    }
    if (a == .float_ and b == .float_) {
        const r = switch (op) {
            .eq => a.float_ == b.float_,
            .neq => a.float_ != b.float_,
            .lt => a.float_ < b.float_,
            .gt => a.float_ > b.float_,
            .le => a.float_ <= b.float_,
            .ge => a.float_ >= b.float_,
            else => unreachable,
        };
        return Value{ .bool_ = r };
    }
    if (a == .bool_ and b == .bool_) {
        const r = switch (op) {
            .eq => a.bool_ == b.bool_,
            .neq => a.bool_ != b.bool_,
            else => return error.RuntimeFailure,
        };
        return Value{ .bool_ = r };
    }
    return error.RuntimeFailure;
}

// ── Const evaluator ──

/// Pure constant-folding evaluator over an Etch AST subtree. Used
/// by the type-checker for `const` resolution and by `codegen` to
/// pre-evaluate literal expressions during lowering.
pub fn evalConst(ast: *const AstArena, node: NodeId) !Value {
    const kind = ast.exprKind(node);
    const data = ast.exprData(node);
    switch (kind) {
        .int_lit => return Value{ .int_ = try std.fmt.parseInt(i64, ast.strings.slice(data), 10) },
        .float_lit => return Value{ .float_ = try std.fmt.parseFloat(f64, ast.strings.slice(data)) },
        .bool_lit => return Value{ .bool_ = std.mem.eql(u8, ast.strings.slice(data), "true") },
        .binary => {
            const b = ast.binary_exprs.items[data];
            const a = try evalConst(ast, b.lhs);
            const c = try evalConst(ast, b.rhs);
            return switch (b.op) {
                .add, .sub, .mul, .div, .rem => binaryArith(b.op, a, c) catch return error.NotConstEvaluable,
                .eq, .neq, .lt, .gt, .le, .ge => binaryCompare(b.op, a, c) catch return error.NotConstEvaluable,
                else => return error.NotConstEvaluable,
            };
        },
        .unary => {
            const u = ast.unary_exprs.items[data];
            const v = try evalConst(ast, u.operand);
            return switch (u.op) {
                .neg => switch (v) {
                    .int_ => |x| Value{ .int_ = -x },
                    .float_ => |x| Value{ .float_ = -x },
                    else => return error.NotConstEvaluable,
                },
                .logical_not => switch (v) {
                    .bool_ => |x| Value{ .bool_ = !x },
                    else => return error.NotConstEvaluable,
                },
                // `expr!` needs the runtime optional store — never const.
                .force_unwrap => return error.NotConstEvaluable,
            };
        },
        else => return error.UnsupportedExpr,
    }
}

// ── Compilation passes ──

fn compileComponent(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    world: *World,
    bridge: *Bridge,
    decl: ast_mod.ComponentDecl,
) !void {
    const name = ast.strings.slice(decl.name);
    _ = try compileTypeDecl(gpa, ast, world, bridge, name, decl.fields_start, decl.fields_len, .component);
}

fn compileResource(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    world: *World,
    bridge: *Bridge,
    decl: ast_mod.ResourceDecl,
) !void {
    const name = ast.strings.slice(decl.name);
    const id = try compileTypeDecl(gpa, ast, world, bridge, name, decl.fields_start, decl.fields_len, .resource);
    const default_bytes = world.registry.componentDefaultBytes(id);
    try world.addResource(gpa, id, default_bytes);
}

const RegKind = enum { component, resource };

fn compileTypeDecl(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    world: *World,
    bridge: *Bridge,
    name: []const u8,
    fields_start: u32,
    fields_len: u32,
    reg_kind: RegKind,
) !ComponentId {
    var fields: std.ArrayListUnmanaged(FieldDesc) = .empty;
    defer fields.deinit(gpa);
    var size: usize = 0;
    var max_align: usize = 1;

    var f_i: u32 = 0;
    while (f_i < fields_len) : (f_i += 1) {
        const f = ast.fields.items[fields_start + f_i];
        const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
        // Resolve through any top-level `type` alias chain (M0.8 foundations).
        const tname = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
        const kind = fieldKindFromTypeName(tname) orelse return error.InvalidProgram;
        const align_b = kind.alignBytes();
        if (align_b > max_align) max_align = align_b;
        const off = std.mem.alignForward(usize, size, align_b);
        size = off + kind.sizeBytes();
        try fields.append(gpa, .{
            .name = ast.strings.slice(f.name),
            .offset = @intCast(off),
            .kind = kind,
        });
    }
    size = std.mem.alignForward(usize, size, max_align);

    var default_buf: []u8 = try gpa.alloc(u8, size);
    defer gpa.free(default_buf);
    @memset(default_buf, 0);
    f_i = 0;
    while (f_i < fields_len) : (f_i += 1) {
        const f = ast.fields.items[fields_start + f_i];
        if (f.default_value.isNone()) continue;
        const v = evalConst(ast, f.default_value) catch continue;
        const fd = fields.items[f_i];
        const slot = default_buf[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))];
        try bridge_mod.writeValueAsBytes(fd.kind, slot, v);
    }

    const id = try world.registry.registerComponentRaw(gpa, .{
        .name = name,
        .size = @intCast(size),
        .alignment = @intCast(max_align),
        .default_bytes = default_buf,
        .fields = fields.items,
    });
    switch (reg_kind) {
        .component => try bridge.mapComponent(gpa, name, id),
        .resource => try bridge.mapResource(gpa, name, id),
    }
    return id;
}

fn fieldKindFromTypeName(name: []const u8) ?FieldKind {
    if (std.mem.eql(u8, name, "int")) return .int_;
    if (std.mem.eql(u8, name, "float")) return .float_;
    if (std.mem.eql(u8, name, "bool")) return .bool_;
    if (std.mem.eql(u8, name, "i32")) return .i32_;
    if (std.mem.eql(u8, name, "u32")) return .u32_;
    if (std.mem.eql(u8, name, "f32")) return .f32_;
    if (std.mem.eql(u8, name, "f64")) return .f64_;
    return null;
}

fn compileRule(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    bridge: *Bridge,
    registry: *const Registry,
    tag_table: *const tags_mod.TagTable,
    tagset_id: ?ComponentId,
    rule_data: u32,
) !RuleDesc {
    const rule = ast.rule_decls.items[rule_data];

    var pool: std.ArrayListUnmanaged(PredicateNode) = .empty;
    errdefer pool.deinit(gpa);
    var res_deps: std.ArrayListUnmanaged(ResourceDep) = .empty;
    errdefer res_deps.deinit(gpa);
    var tag_preds: std.ArrayListUnmanaged(TagPredicate) = .empty;
    errdefer {
        for (tag_preds.items) |*tp| tp.deinit(gpa);
        tag_preds.deinit(gpa);
    }
    var changed_filters: std.ArrayListUnmanaged(ComponentId) = .empty;
    errdefer changed_filters.deinit(gpa);
    var field_filter: ?FieldFilter = null;
    var predicate_root: ?u32 = null;
    var has_component_ref: bool = false;

    var lw: LowerWhenCtx = .{
        .ast = ast,
        .bridge = bridge,
        .registry = registry,
        .tag_table = tag_table,
        .tagset_id = tagset_id,
        .pool = &pool,
        .res_deps = &res_deps,
        .filter = &field_filter,
        .tag_preds = &tag_preds,
        .changed_filters = &changed_filters,
        .gpa = gpa,
        .has_component_ref = &has_component_ref,
    };
    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        const r = try lowerWhen(&lw, rule.when_root);
        predicate_root = r;
    }

    var entity_param_name: ?StringId = null;
    var p_i: u32 = 0;
    while (p_i < rule.params_len) : (p_i += 1) {
        const p = ast.rule_params.items[rule.params_start + p_i];
        const tnode = ast.named_types.items[ast.typeNodeData(p.type_node)];
        const tname = ast.strings.slice(tnode.name);
        if (std.mem.eql(u8, tname, "Entity")) {
            entity_param_name = p.name;
            break;
        }
    }
    const is_entity_bound = (entity_param_name != null) and has_component_ref;

    // `@on_event(T)` observer (M0.8 E3): the event type name, or null. A
    // malformed annotation (caught + reported E1203 by the resolver) yields
    // null here → the rule degrades to a global/entity rule, no observer drain.
    const event_type: ?StringId = if (ast.onEventAnnotation(rule)) |annot|
        ast.onEventTypeName(annot)
    else
        null;

    return .{
        .rule_idx = rule_data,
        .name = rule.name,
        .predicate_pool = try pool.toOwnedSlice(gpa),
        .predicate_root = predicate_root,
        .resource_deps = try res_deps.toOwnedSlice(gpa),
        .field_filter = field_filter,
        .tag_predicates = try tag_preds.toOwnedSlice(gpa),
        .entity_param_name = entity_param_name,
        .is_entity_bound = is_entity_bound,
        .event_type = event_type,
        .changed_filters = try changed_filters.toOwnedSlice(gpa),
        .last_run_tick = initial_tick,
        .is_async = rule.is_async,
    };
}

/// Shared state threaded through `lowerWhen`'s recursion. Carries the output
/// accumulators (predicate pool, resource deps, field filter, tag predicates)
/// plus the bridge / registry / tag table needed to resolve names.
const LowerWhenCtx = struct {
    ast: *const AstArena,
    bridge: *Bridge,
    registry: *const Registry,
    tag_table: *const tags_mod.TagTable,
    tagset_id: ?ComponentId,
    pool: *std.ArrayListUnmanaged(PredicateNode),
    res_deps: *std.ArrayListUnmanaged(ResourceDep),
    filter: *?FieldFilter,
    tag_preds: *std.ArrayListUnmanaged(TagPredicate),
    changed_filters: *std.ArrayListUnmanaged(ComponentId),
    gpa: std.mem.Allocator,
    has_component_ref: *bool,
};

/// Recursively lower a `when` tree into a flat `PredicateNode` pool plus
/// a list of resource deps, at most one field filter, and a list of tag
/// predicates. Returns the pool-index of the lowered node, or
/// `PredicateNode.no_child` when the subtree contributes only resource deps /
/// negative tag filters (and thus no archetype-side predicate).
fn lowerWhen(ctx: *LowerWhenCtx, when_idx: u32) error{ OutOfMemory, InvalidProgram }!u32 {
    const ast = ctx.ast;
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and, .logical_or => {
            const lhs_idx = try lowerWhen(ctx, node.lhs);
            const rhs_idx = try lowerWhen(ctx, node.rhs);
            // If a branch contributed only resource deps, propagate the
            // other branch's predicate unchanged.
            if (lhs_idx == PredicateNode.no_child) return rhs_idx;
            if (rhs_idx == PredicateNode.no_child) return lhs_idx;
            const kind: PredicateNodeKind = if (node.kind == .logical_and) .and_ else .or_;
            const idx: u32 = @intCast(ctx.pool.items.len);
            try ctx.pool.append(ctx.gpa, .{ .kind = kind, .lhs = lhs_idx, .rhs = rhs_idx });
            return idx;
        },
        .logical_not => {
            const child = try lowerWhen(ctx, node.lhs);
            if (child == PredicateNode.no_child) return PredicateNode.no_child;
            const idx: u32 = @intCast(ctx.pool.items.len);
            try ctx.pool.append(ctx.gpa, .{ .kind = .not_, .lhs = child });
            return idx;
        },
        .has => {
            const tname = ast.strings.slice(node.type_name);
            const id = ctx.bridge.componentIdOf(tname) orelse return error.InvalidProgram;
            const idx: u32 = @intCast(ctx.pool.items.len);
            try ctx.pool.append(ctx.gpa, .{ .kind = .has, .component_id = id });
            ctx.has_component_ref.* = true;
            return idx;
        },
        .has_with_filter => {
            const tname = ast.strings.slice(node.type_name);
            const id = ctx.bridge.componentIdOf(tname) orelse return error.InvalidProgram;
            const fname = ast.strings.slice(node.field_name);
            const fd = ctx.registry.findField(id, fname) orelse return error.InvalidProgram;
            const v = evalConst(ast, node.filter_value) catch return error.InvalidProgram;
            ctx.filter.* = .{
                .component_id = id,
                .field_offset = fd.offset,
                .field_kind = fd.kind,
                .expected_value = v,
            };
            const idx: u32 = @intCast(ctx.pool.items.len);
            try ctx.pool.append(ctx.gpa, .{ .kind = .has, .component_id = id });
            ctx.has_component_ref.* = true;
            return idx;
        },
        .has_changed => {
            // `entity has T changed` (M0.8 E3, `engine-ecs-internals.md` §5):
            // a `has T` archetype predicate (the entity must own T) PLUS a
            // per-entity change-detection filter — the slot's `changedTick(T)`
            // must exceed the rule's `last_run_tick`. The component id joins
            // `changed_filters`, checked per entity in `runRule` after the
            // field filter / tag predicates.
            const tname = ast.strings.slice(node.type_name);
            const id = ctx.bridge.componentIdOf(tname) orelse return error.InvalidProgram;
            try ctx.changed_filters.append(ctx.gpa, id);
            const idx: u32 = @intCast(ctx.pool.items.len);
            try ctx.pool.append(ctx.gpa, .{ .kind = .has, .component_id = id });
            ctx.has_component_ref.* = true;
            return idx;
        },
        .resource => {
            const tname = ast.strings.slice(node.type_name);
            const rid = ctx.bridge.resourceIdOf(tname) orelse return error.InvalidProgram;
            try ctx.res_deps.append(ctx.gpa, .{ .resource_id = rid, .must_be_changed = false });
            return PredicateNode.no_child;
        },
        .resource_changed => {
            const tname = ast.strings.slice(node.type_name);
            const rid = ctx.bridge.resourceIdOf(tname) orelse return error.InvalidProgram;
            try ctx.res_deps.append(ctx.gpa, .{ .resource_id = rid, .must_be_changed = true });
            return PredicateNode.no_child;
        },
        .tag_filter => {
            // `entity has_tag .path` (M0.8 E3). Resolve operand paths → leaf
            // bits (a leaf → its bit, a category namespace → its mask) into a
            // per-entity `TagPredicate`. A tag filter makes the rule
            // entity-bound; a positive op additionally requires the entity to
            // have `TagSet` (a `has TagSet` archetype predicate), while a
            // negative op (`has_no_tag`/`has_no_tags`) also matches entities
            // lacking `TagSet`, so it adds no archetype predicate.
            const tf = ast.tag_filters.items[node.aux];
            var bits: std.ArrayListUnmanaged(u32) = .empty;
            errdefer bits.deinit(ctx.gpa);
            var oi: u32 = 0;
            while (oi < tf.operand_len) : (oi += 1) {
                const path_node = ast.tag_operands.items[tf.operand_start + oi];
                try resolveTagOperandBits(ctx, path_node, &bits);
            }
            try ctx.tag_preds.append(ctx.gpa, .{ .op = tf.op, .bits = try bits.toOwnedSlice(ctx.gpa) });
            ctx.has_component_ref.* = true;
            const positive = switch (tf.op) {
                .has_tag, .has_any_tag, .has_all_tags => true,
                .has_no_tag, .has_no_tags => false,
            };
            if (positive) {
                if (ctx.tagset_id) |tid| {
                    const idx: u32 = @intCast(ctx.pool.items.len);
                    try ctx.pool.append(ctx.gpa, .{ .kind = .has, .component_id = tid });
                    return idx;
                }
            }
            return PredicateNode.no_child;
        },
    }
}

/// Resolve one tag operand path to its leaf bit(s), appending to `out`: a leaf
/// path contributes its single bit; a namespace path expands to the bits of
/// every leaf under it (`collectUnder`). An unknown path / a leaf where a
/// namespace was expected fails loud (the resolver should have caught it).
fn resolveTagOperandBits(ctx: *LowerWhenCtx, path_node: NodeId, out: *std.ArrayListUnmanaged(u32)) error{ OutOfMemory, InvalidProgram }!void {
    const tp = ctx.ast.tag_paths.items[ctx.ast.exprData(path_node)];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    var i: u32 = 0;
    while (i < tp.segs_len) : (i += 1) {
        if (i > 0) try buf.append(ctx.gpa, '.');
        try buf.appendSlice(ctx.gpa, ctx.ast.strings.slice(ctx.ast.tag_path_segs.items[tp.segs_start + i]));
    }
    if (ctx.tag_table.leafBit(buf.items)) |bit| {
        try out.append(ctx.gpa, bit);
    } else if (ctx.tag_table.lookup(buf.items)) |entry| {
        if (entry.is_leaf) return error.InvalidProgram;
        try ctx.tag_table.collectUnder(ctx.gpa, buf.items, out);
    } else return error.InvalidProgram;
}

// ─── tests ────────────────────────────────────────────────────────────────

test "run on empty AST returns zero-rule report" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var ast = try AstArena.init(gpa);
    defer ast.deinit(gpa);

    const report = try Interpreter.run(gpa, &ast, &world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.rules_evaluated);
    try std.testing.expectEqual(@as(u64, 0), report.entities_iterated);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
}

test "evalConst on int literal returns Value.int" {
    const gpa = std.testing.allocator;
    var ast = try AstArena.init(gpa);
    defer ast.deinit(gpa);

    const lit_id = try ast.strings.intern(gpa, "42");
    const node = try ast.addExpr(gpa, .int_lit, lit_id, .{ .byte_start = 0, .byte_end = 2 });

    const v = try evalConst(&ast, node);
    try std.testing.expectEqual(@as(i64, 42), v.int_);
}

test "evalConst on arithmetic on literals folds correctly" {
    const gpa = std.testing.allocator;
    var ast = try AstArena.init(gpa);
    defer ast.deinit(gpa);

    const lit_a = try ast.strings.intern(gpa, "2");
    const a = try ast.addExpr(gpa, .int_lit, lit_a, .{ .byte_start = 0, .byte_end = 0 });
    const lit_b = try ast.strings.intern(gpa, "3");
    const b = try ast.addExpr(gpa, .int_lit, lit_b, .{ .byte_start = 0, .byte_end = 0 });
    const bin = try ast.addBinary(gpa, .add, a, b, .{ .byte_start = 0, .byte_end = 0 });

    const v = try evalConst(&ast, bin);
    try std.testing.expectEqual(@as(i64, 5), v.int_);
}

test "evalConst on tag_path returns UnsupportedExpr" {
    const gpa = std.testing.allocator;
    var ast = try AstArena.init(gpa);
    defer ast.deinit(gpa);

    const lit_id = try ast.strings.intern(gpa, "update");
    const node = try ast.addExpr(gpa, .tag_path, lit_id, .{ .byte_start = 0, .byte_end = 0 });
    try std.testing.expectError(error.UnsupportedExpr, evalConst(&ast, node));
}

test "runProgram on minimal component + rule mutates entity" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\component Health { current: float = 100.0 }
        \\rule heal(entity: Entity)
        \\  when entity has Health
        \\{
        \\  entity.get_mut(Health).current += 1.0
        \\}
    ;

    // Compile manually, spawn one entity, then runFor.
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const comp_id = world.registry.idOf("Health").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{comp_id});

    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // Read the resulting current value back from the chunk.
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const idx = arch.componentIndex(comp_id).?;
    const slot = arch.componentSlot(chunk, idx, loc.slot);
    var current: f64 = 0;
    @memcpy(std.mem.asBytes(&current), slot[0..@sizeOf(f64)]);
    try std.testing.expectApproxEqAbs(@as(f64, 103.0), current, 0.0001);
}

test "runProgram resource get/get_mut without receiver reads and writes the resource (D-S3-resource-receiver)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `get(Score).base` is a receiver-less immutable resource read; the
    // `get_mut(Score)` binding then writes a field on the same resource.
    const source =
        \\resource Score {
        \\  points: i32 = 0
        \\  base: i32 = 5
        \\}
        \\rule bump()
        \\  when resource Score
        \\{
        \\  let b = get(Score).base
        \\  let s = get_mut(Score)
        \\  s.points += b
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // points starts at 0 and gains base (5) per tick: 3 ticks → 15.
    const score_id = world.registry.idOf("Score").?;
    const bytes = world.resources.getResource(score_id).?;
    var points: i32 = 0;
    @memcpy(std.mem.asBytes(&points), bytes[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 15), points);
}

test "runProgram type-alias field resolves to the underlying primitive (M0.8 type alias)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `Meters` aliases `float`: the interpreter must resolve it to f64 when
    // computing the field's FieldKind/layout, else compilation fails.
    const source =
        \\type Meters = float
        \\component Position { x: Meters = 0.0 }
        \\rule advance(entity: Entity)
        \\  when entity has Position
        \\{
        \\  entity.get_mut(Position).x += 2.5
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const comp_id = world.registry.idOf("Position").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{comp_id});

    const report = try interp.runFor(&world, 2);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const idx = arch.componentIndex(comp_id).?;
    const slot = arch.componentSlot(chunk, idx, loc.slot);
    var x: f64 = 0;
    @memcpy(std.mem.asBytes(&x), slot[0..@sizeOf(f64)]);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), x, 0.0001);
}

test "runProgram for-in over a range accumulates (M0.8 ranges + for-in)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\component Acc { total: int = 0 }
        \\rule sum(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut s = 0
        \\  for i in 0..5 {
        \\    s += i
        \\  }
        \\  entity.get_mut(Acc).total = s
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var total: i64 = 0;
    @memcpy(std.mem.asBytes(&total), slot[0..8]);
    // 0 + 1 + 2 + 3 + 4 = 10 (exclusive range).
    try std.testing.expectEqual(@as(i64, 10), total);
}

test "runProgram block expression yields its trailing value (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let x = {
        \\    let a = 10
        \\    let b = 20
        \\    a + b
        \\  }
        \\  entity.get_mut(Acc).out = x
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    // { let a = 10; let b = 20; a + b } = 30.
    try std.testing.expectEqual(@as(i64, 30), out);
}

test "runProgram while loop with a conditional break (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `while` + `if cond { break }` exercises the while control signal plus the
    // conditional loop exit (an `if`-guarded `break` inside the body), unblocked
    // by block-1's `if` + block expressions.
    const source =
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut i = 0
        \\  let mut s = 0
        \\  while i < 100 {
        \\    if i == 5 { break }
        \\    s += i
        \\    i += 1
        \\  }
        \\  entity.get_mut(Acc).out = s
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    // Breaks at i == 5: s = 0 + 1 + 2 + 3 + 4 = 10.
    try std.testing.expectEqual(@as(i64, 10), out);
}

test "runProgram closure with a block body (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `|x| { let y = x + 1; y * 2 }` — a closure whose body is a block
    // expression, unblocked by block-1 block expressions (the E1
    // closure-block-body deferral). The interpreter is the reference; a
    // block-body closure's codegen folds into the E3 "Level A complete in
    // codegen" gate (deferred there, as for capturing closures), so this has no
    // codegen differential.
    const source =
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let f = |x: int| {
        \\    let y = x + 1
        \\    y * 2
        \\  }
        \\  entity.get_mut(Acc).out = f(4)
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    // f(4): y = 5, y * 2 = 10.
    try std.testing.expectEqual(@as(i64, 10), out);
}

test "runProgram match dispatches on literal and binding arms (M0.8 match)" {
    const gpa = std.testing.allocator;

    // Literal dispatch: sel = 1 selects the `1 => 200` arm.
    {
        var world = World.init();
        defer world.deinit(gpa);
        var pr = try parser_mod.parse(gpa,
            \\component C { sel: int = 1, out: int = 0 }
            \\rule pick(entity: Entity)
            \\  when entity has C
            \\{
            \\  entity.get_mut(C).out = match entity.get(C).sel { 0 => 100, 1 => 200, _ => 999 }
            \\}
        );
        defer pr.deinit(gpa);
        try std.testing.expect(pr.diagnostics.len == 0);
        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
        var interp = try Interpreter.compile(gpa, &pr.ast, &world);
        defer interp.deinit();
        const cid = world.registry.idOf("C").?;
        const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
        _ = try interp.runFor(&world, 1);
        const loc = world.dynamicLocation(eid).?;
        const arch = world.dynamicArchetype(loc.archetype_idx);
        const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
        // out is the second field (offset 8: after sel i64).
        var out: i64 = 0;
        @memcpy(std.mem.asBytes(&out), slot[8..16]);
        try std.testing.expectEqual(@as(i64, 200), out);
    }

    // Binding arm: `n => n + 5` binds the scrutinee; sel = 3 → out = 8.
    {
        var world = World.init();
        defer world.deinit(gpa);
        var pr = try parser_mod.parse(gpa,
            \\component C { sel: int = 3, out: int = 0 }
            \\rule pick(entity: Entity)
            \\  when entity has C
            \\{
            \\  entity.get_mut(C).out = match entity.get(C).sel { n => n + 5 }
            \\}
        );
        defer pr.deinit(gpa);
        try std.testing.expect(pr.diagnostics.len == 0);
        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
        var interp = try Interpreter.compile(gpa, &pr.ast, &world);
        defer interp.deinit();
        const cid = world.registry.idOf("C").?;
        const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
        _ = try interp.runFor(&world, 1);
        const loc = world.dynamicLocation(eid).?;
        const arch = world.dynamicArchetype(loc.archetype_idx);
        const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
        var out: i64 = 0;
        @memcpy(std.mem.asBytes(&out), slot[8..16]);
        try std.testing.expectEqual(@as(i64, 8), out);
    }
}

test "runProgram enum value + match selects the right arm (M0.8 E2 block 3 tranche B)" {
    const gpa = std.testing.allocator;
    // `let d = Difficulty.normal` builds an enum value; the match selects the
    // `.normal => 2` arm (the middle of the if-else chain). out = 2.
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try parser_mod.parse(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\component C { out: int = 0 }
        \\rule pick(entity: Entity)
        \\  when entity has C
        \\{
        \\  let d = Difficulty.normal
        \\  entity.get_mut(C).out = match d { Difficulty.easy => 1, Difficulty.normal => 2, Difficulty.hard => 3 }
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("C").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(&world, 1);
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 2), out);
}

test "runProgram trait method on Entity mutates via get_mut (M0.8 E2 block 3 tranche C)" {
    const gpa = std.testing.allocator;
    // A conditional trait impl on Entity; the rule's `when` guarantees Health,
    // so the call type-checks and the interpreter dispatches it (Entity trait
    // dispatch). The body mutates through `self.get_mut(Health)`. current: 100
    // - 30 = 70.
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try parser_mod.parse(gpa,
        \\trait Damageable { fn take_damage(self, amount: int) }
        \\component Health { current: int = 100 }
        \\impl Damageable for Entity when self has Health {
        \\  fn take_damage(self, amount: int) { self.get_mut(Health).current -= amount }
        \\}
        \\rule hit(entity: Entity) when entity has Health {
        \\  entity.take_damage(30)
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Health").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(&world, 1);
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var current: i64 = 0;
    @memcpy(std.mem.asBytes(&current), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 70), current);
}

test "runProgram generic fn + generic struct run type-erased (M0.8 E2 block 4)" {
    const gpa = std.testing.allocator;
    // The tree-walker monomorphises trivially at runtime: a generic `fn` binds
    // its args by name (types erased) and a generic `struct` materialises like
    // any struct. `id(41) + 1 = 42`; `Box{value: 100}.value = 100`; out = 142.
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try parser_mod.parse(gpa,
        \\fn id<T>(x: T) -> T { x }
        \\struct Box<T> { value: T }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let b = Box { value: 100 }
        \\  entity.get_mut(C).out = id(41) + 1 + b.value
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("C").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(&world, 1);
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 142), out);
}

test "runProgram generic inherent impl (impl<T> Range<T>) resolves + interps (§891, M0.8 E2)" {
    const gpa = std.testing.allocator;
    // The §891-patched grammar accepts a generic-type inherent impl target. A
    // method on `Range<T>` dispatches + runs type-erased: `contains(5)` on
    // `Range { min: 2, max: 8 }` is 2 <= 5 <= 8 → true → out = 1. Generic
    // codegen stays UnsupportedConstruct (so this is interp-reference, not a
    // codegen differential — consistent with block 4).
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try parser_mod.parse(gpa,
        \\struct Range<T> { min: T  max: T }
        \\impl<T> Range<T> {
        \\  fn contains(self, v: T) -> bool { v >= self.min and v <= self.max }
        \\}
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let rng = Range { min: 2, max: 8 }
        \\  entity.get_mut(C).out = if rng.contains(5) { 1 } else { 0 }
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("C").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(&world, 1);
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 1), out);
}

test "runProgram while let unwraps an optional each iteration (M0.8 E2 block 5)" {
    const gpa = std.testing.allocator;
    // `while let y = <optional>` re-evaluates the optional each iteration: a
    // counter yields `some(n)` while n > 0, then `none` to stop. sum = 3+2+1 = 6.
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try parser_mod.parse(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let mut n = 3
        \\  let mut sum = 0
        \\  while let y = (if n > 0 { some(n) } else { none }) {
        \\    sum += y
        \\    n -= 1
        \\  }
        \\  entity.get_mut(C).out = sum
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("C").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(&world, 1);
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 6), out);
}

test "runProgram assert passes on true, reports a runtime error on false (M0.8 assert)" {
    const gpa = std.testing.allocator;

    // assert(true-ish) → no runtime error.
    {
        var world = World.init();
        defer world.deinit(gpa);
        var pr = try parser_mod.parse(gpa,
            \\resource Tick { n: i32 = 0 }
            \\rule ok()
            \\  when resource Tick
            \\{
            \\  assert(1 < 2)
            \\}
        );
        defer pr.deinit(gpa);
        try std.testing.expect(pr.diagnostics.len == 0);
        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
        var interp = try Interpreter.compile(gpa, &pr.ast, &world);
        defer interp.deinit();
        const report = try interp.runFor(&world, 1);
        try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    }

    // assert(false-ish) → one runtime error.
    {
        var world = World.init();
        defer world.deinit(gpa);
        var pr = try parser_mod.parse(gpa,
            \\resource Tick { n: i32 = 0 }
            \\rule bad()
            \\  when resource Tick
            \\{
            \\  assert(2 < 1)
            \\}
        );
        defer pr.deinit(gpa);
        try std.testing.expect(pr.diagnostics.len == 0);
        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
        var interp = try Interpreter.compile(gpa, &pr.ast, &world);
        defer interp.deinit();
        const report = try interp.runFor(&world, 1);
        try std.testing.expect(report.runtime_errors > 0);
    }
}

test "runProgram numeric cast int-to-float (M0.8 cast foundation)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\component Health {
        \\  current: float = 0.0
        \\  level: i32 = 3
        \\}
        \\rule promote(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let lvl = entity.get(Health).level
        \\  entity.get_mut(Health).current = lvl as float
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const comp_id = world.registry.idOf("Health").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{comp_id});

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const idx = arch.componentIndex(comp_id).?;
    const slot = arch.componentSlot(chunk, idx, loc.slot);
    var current: f64 = 0;
    @memcpy(std.mem.asBytes(&current), slot[0..@sizeOf(f64)]);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), current, 0.0001);
}

test "runProgram for-in over a dynamic array iterates each element (M0.8 collections)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `T[]`-annotated dynamic array — the interpreter is the reference
    // execution the tranche-3 codegen matches byte-exactly (frame arena).
    // for-in over it sums 5 + 15 + 25 = 45.
    const source =
        \\component Acc { out: int = 0 }
        \\rule sum(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let xs: int[] = [5, 15, 25]
        \\  let mut s = 0
        \\  for x in xs { s += x }
        \\  entity.get_mut(Acc).out = s
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var total: i64 = 0;
    @memcpy(std.mem.asBytes(&total), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 45), total);
}

test "runProgram map literal + for-in sums values (M0.8 collections)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A map literal iterated with `for k, v in m`, summing the values. The
    // interpreter is the reference execution the tranche-3 codegen mirrors
    // (insertion-ordered pair list). The sum (10 + 20 + 30 = 60) is
    // order-invariant, matching the unordered-map contract.
    const source =
        \\component Acc { out: int = 0 }
        \\rule sum(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let m = [1: 10, 2: 20, 3: 30]
        \\  let mut s = 0
        \\  for k, v in m { s += v }
        \\  entity.get_mut(Acc).out = s
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var total: i64 = 0;
    @memcpy(std.mem.asBytes(&total), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 60), total);
}

test "runProgram dynamic array push and len (M0.8 E3-C tranche 3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The minimal §13.2 method subset on a dynamic array: two `push` calls
    // grow [1, 2] to [1, 2, 7, 9]; `len` and an index read flow back into
    // the component (out = 4 * 100 + xs[3] = 409).
    const source =
        \\component Acc { out: int = 0 }
        \\rule grow(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut xs: int[] = [1, 2]
        \\  xs.push(7)
        \\  xs.push(9)
        \\  entity.get_mut(Acc).out = xs.len() * 100 + xs[3]
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var total: i64 = 0;
    @memcpy(std.mem.asBytes(&total), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 409), total);
}

test "runProgram map insert replaces and appends, len counts (M0.8 E3-C tranche 3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The minimal §14.2 method subset on a map: `insert(3, 30)` appends,
    // `insert(2, 25)` replaces in place (last-write-wins — same scan as the
    // map literal). The value sum reads 10 + 25 + 30 = 65; with `len` the
    // component sees 3 * 1000 + 65 = 3065.
    const source =
        \\component Acc { out: int = 0 }
        \\rule upsert(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut m = [1: 10, 2: 20]
        \\  m.insert(3, 30)
        \\  m.insert(2, 25)
        \\  let mut s = 0
        \\  for k, v in m { s += v }
        \\  entity.get_mut(Acc).out = m.len() * 1000 + s
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var total: i64 = 0;
    @memcpy(std.mem.asBytes(&total), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 3065), total);
}

test "runProgram closure captures an outer local by value (M0.8 closures)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A closure capturing an outer local (`factor`) by value and invoked. The
    // interpreter is the reference execution; capturing-closure codegen is
    // deferred (struct-with-fields lowering). scale(5) = 5 * 3 = 15.
    const source =
        \\component Acc { out: int = 0 }
        \\rule apply(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let factor = 3
        \\  let scale = |x: int| x * factor
        \\  entity.get_mut(Acc).out = scale(5)
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 15), out);
}

test "runProgram free-function call returns the computed value (M0.8 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A top-level `fn` invoked as a free call: the interpreter binds the arg in
    // a fresh frame and yields the trailing block value (implicit return).
    // double(21) = 42.
    const source =
        \\component Acc { out: int = 0 }
        \\fn double(x: int) -> int { x * 2 }
        \\rule apply(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).out = double(21)
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "runProgram early return unwinds the fn body past later statements (M0.8 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `return` inside the `if` block must unwind out of the fn, skipping the
    // trailing `return 0`. classify(5) takes the early branch → 7.
    const source =
        \\component Acc { out: int = 0 }
        \\fn classify(n: int) -> int {
        \\  if n > 0 {
        \\    return 7
        \\  }
        \\  return 0
        \\}
        \\rule apply(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).out = classify(5)
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 7), out);
}

test "runProgram struct method dispatch: associated fn + instance method (M0.8 E2 block 3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `V2.make(3, 4)` (associated dispatch) builds the struct; `v.sum()`
    // (instance dispatch) reads it. out = 7. Mirrors differential 39 — kept
    // inline so the interpreter path is exercised directly.
    const source =
        \\struct V2 { x: int = 0, y: int = 0 }
        \\impl V2 {
        \\  fn sum(self) -> int { self.x + self.y }
        \\  fn make(a: int, b: int) -> V2 { V2 { x: a, y: b } }
        \\}
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let v = V2.make(3, 4)
        \\  entity.get_mut(Acc).out = v.sum()
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 7), out);
}

test "runProgram mut-self method mutates the receiver in place (M0.8 E2 block 3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `mut self` method mutates the receiver; the mutation is visible to the
    // caller (the struct handle is shared — reference semantics for `mut self`).
    // The interpreter is the reference for `mut self`; its codegen is deferred
    // (pointer receiver), so this has no differential. c.n: 10 → +5 → 15.
    const source =
        \\struct Counter { n: int = 0 }
        \\impl Counter {
        \\  fn bump(mut self, by: int) { self.n += by }
        \\  fn get(self) -> int { self.n }
        \\}
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut c = Counter { n: 10 }
        \\  c.bump(5)
        \\  entity.get_mut(Acc).out = c.get()
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 15), out);
}

test "runProgram try/catch catches a thrown value (M0.8 error handling)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The throw aborts the rest of the try body (x never reaches 3) and is
    // caught, binding the thrown `Error` into `err` (M0.8 E3-C tranche 2:
    // the thrown value is statically the builtin Error, part1 §10.2); x ends
    // at `"boom".len()` = 4.
    const source =
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut x = 1
        \\  try {
        \\    x = 2
        \\    throw Error { message: "boom", code: ErrorCode.io_fail }
        \\    x = 3
        \\  } catch err {
        \\    x = err.message.len()
        \\  }
        \\  entity.get_mut(Acc).out = x
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 4), out);
}

test "runProgram uncaught throw surfaces a runtime error (M0.8 error handling)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A throw with no enclosing try reaches the rule top level → runtime error.
    const source =
        \\resource Tick { n: i32 = 0 }
        \\rule bad()
        \\  when resource Tick
        \\{
        \\  throw Error { message: "boom", code: ErrorCode.io_fail }
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const report = try interp.runFor(&world, 1);
    try std.testing.expect(report.runtime_errors > 0);
}

test "runProgram emit enqueues an event into the dynamic event store (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A global rule (no when clause) emits once per tick.
    const source =
        \\event Damage { amount: int = 0, crit: bool = false }
        \\rule deal() { emit Damage { amount: 5, crit: true } }
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // One Damage event enqueued this tick, with amount == 5.
    const dmg_id = pr.ast.strings.find("Damage").?;
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(dmg_id));
    const amount_id = pr.ast.strings.find("amount").?;
    var amount: i64 = -1;
    for (interp.events.list.items[0].fields.items) |f| {
        if (f.name == amount_id) {
            try std.testing.expect(f.value == .int_);
            amount = f.value.int_;
        }
    }
    try std.testing.expectEqual(@as(i64, 5), amount);

    // Per-tick lifetime: a second tick clears the previous queue rather than
    // accumulating (the count stays 1, not 2).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(dmg_id));
}

test "runProgram @on_event observer drains the event store and writes a resource (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Global producer emits one Damage per tick; the `@on_event(Damage)`
    // observer (declared after) drains it same-tick and accumulates the amount
    // into a resource. The implicit `event` binding (self-style) carries the
    // payload — no declared `event:` param. Interpreter-reference: the
    // observer's resource write codegen is deferred (D-S3-resource-receiver,
    // E3 gate), so this lives only as an interpreter test, not a differential.
    const source =
        \\event Damage { amount: i32 = 0 }
        \\resource Tally { total: i32 = 0 }
        \\rule deal() { emit Damage { amount: 10 } }
        \\@on_event(Damage)
        \\rule absorb()
        \\  when resource Tally
        \\{
        \\  let t = get_mut(Tally)
        \\  t.total += event.amount
        \\}
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // 10 accumulated per tick (one Damage event each tick) → 30 after 3 ticks.
    const tally_id = world.registry.idOf("Tally").?;
    const bytes = world.resources.getResource(tally_id).?;
    var total: i32 = 0;
    @memcpy(std.mem.asBytes(&total), bytes[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 30), total);
}

test "runProgram add_tag is deferred to the tick boundary; has_tag query gates a counter (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\tags { unit { status { tagged } } }
        \\component Counter { value: int = 0 }
        \\rule mark(entity: Entity) when entity has Counter {
        \\  entity.add_tag(.unit.status.tagged)
        \\}
        \\rule count(entity: Entity) when entity has Counter and entity has_tag .unit.status.tagged {
        \\  entity.get_mut(Counter).value += 1
        \\}
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const counter_id = world.registry.idOf("Counter").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{counter_id});

    // Tick 1: `mark` queues the add (flushed at the tick boundary); `count`
    // sees no tag yet (the entity still lacks TagSet → its `has TagSet`
    // archetype predicate fails) → no increment. Ticks 2 + 3: the bit is set,
    // `count` matches → value = 2.
    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // The entity migrated to {Counter, TagSet}; read both back.
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cidx = arch.componentIndex(counter_id).?;
    const cslot = arch.componentSlot(chunk, cidx, loc.slot);
    var value: i64 = 0;
    @memcpy(std.mem.asBytes(&value), cslot[0..@sizeOf(i64)]);
    try std.testing.expectEqual(@as(i64, 2), value);

    // The TagSet bit for `.unit.status.tagged` (the only leaf → bit 0) is set.
    const tagset_id = interp.tagset_id.?;
    const tidx = arch.componentIndex(tagset_id).?;
    const tslot = arch.componentSlot(chunk, tidx, loc.slot);
    var word0: u64 = 0;
    @memcpy(std.mem.asBytes(&word0), tslot[0..8]);
    try std.testing.expectEqual(@as(u64, 1), word0 & 1);
}

test "runProgram `has T changed` gates a rule on per-tick change detection (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `damage` writes Health each tick ONLY for entities carrying `Marked`, so
    // their Health changes every tick. `react` (`has Health changed`) fires for
    // an entity iff its Health changed since react's last run. Entity A (Marked)
    // → Health written each tick → react fires each tick → Counter == 3. Entity
    // B (no Marked) → Health never written (changed_tick stays the spawn tick)
    // → react never fires → Counter == 0. This proves the filter gates, not
    // merely that it always passes.
    const source =
        \\component Health { current: i32 = 100 }
        \\component Counter { value: i32 = 0 }
        \\component Marked { v: i32 = 0 }
        \\rule damage(entity: Entity)
        \\  when entity has Health and entity has Marked
        \\{
        \\  entity.get_mut(Health).current -= 1
        \\}
        \\rule react(entity: Entity)
        \\  when entity has Counter and entity has Health changed
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try std.testing.expect(interp.has_changed);

    const health_id = world.registry.idOf("Health").?;
    const counter_id = world.registry.idOf("Counter").?;
    const marked_id = world.registry.idOf("Marked").?;
    const a = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, marked_id });
    const b = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id });

    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    try std.testing.expectEqual(@as(i32, 3), readCounterValue(&world, counter_id, a));
    try std.testing.expectEqual(@as(i32, 0), readCounterValue(&world, counter_id, b));
}

/// Read the first `i32` field of `counter_id` on `entity` (test helper).
fn readCounterValue(world: *World, counter_id: ComponentId, entity: CoreEntityId) i32 {
    const loc = world.dynamicLocation(entity).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cidx = arch.componentIndex(counter_id).?;
    const cslot = arch.componentSlot(chunk, cidx, loc.slot);
    var value: i32 = 0;
    @memcpy(std.mem.asBytes(&value), cslot[0..@sizeOf(i32)]);
    return value;
}

/// Read the first `int` (`i64`) field of resource `id` (test helper).
fn readResourceInt(world: *World, id: ComponentId) i64 {
    const bytes = world.resources.getResource(id).?;
    var value: i64 = 0;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(i64)]);
    return value;
}

test "async rule suspends at await wait(N) and resumes N ticks later (M0.8 E3 sub-slice B)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The §9.2 shape: a parameterless async rule sets a resource field, suspends
    // for 2 ticks (`await wait(2)`), then sets it again. The tree-walker is its
    // own runtime — it suspends at the await and resumes on wake, no state
    // machine (codegen is Phase 2). The interpreter is the reference.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule seq()
        \\  when resource Out
        \\{
        \\  let a = get_mut(Out)
        \\  a.n = 1
        \\  await wait(2)
        \\  let b = get_mut(Out)
        \\  b.n = 2
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const out_id = world.registry.idOf("Out").?;

    // tick 1: spawn → n=1, suspend at `await wait(2)` (wake at async_tick 3).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 2: still suspended (async_tick 2 < 3) — n unchanged.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 3: wake fires (3 >= 3) → resume, n=2, complete.
    const r3 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r3.runtime_errors);
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, out_id));
    // tick 4: task done — n stays 2 (the rule never re-runs).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, out_id));
}

test "async rule resumes on await global_event(T) (M0.8 E3 sub-slice B)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `pinger` (declared first) emits `Ping` every tick; `waiter` awaits it.
    // The producer runs before the awaiter in rule order — so the awaiter sees
    // the event the tick AFTER it suspends (it suspends at the await without
    // consuming the same-tick event present when it spawned). The wake check
    // reads the live per-tick EventStore, mirroring the observer drain.
    const source =
        \\event Ping { }
        \\resource Out { n: int = 0 }
        \\rule pinger()
        \\  when resource Out
        \\{
        \\  emit Ping { }
        \\}
        \\async rule waiter()
        \\  when resource Out
        \\{
        \\  await global_event(Ping)
        \\  let o = get_mut(Out)
        \\  o.n = 7
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const out_id = world.registry.idOf("Out").?;

    // tick 1: waiter spawns, suspends at the await (does not consume the Ping
    // present when it spawned) — n unchanged.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
    // tick 2: pinger (earlier in order) emits Ping; waiter's wake fires → n=7.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.runtime_errors);
    try std.testing.expectEqual(@as(i64, 7), readResourceInt(&world, out_id));
    // tick 3: waiter done — n stays 7.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 7), readResourceInt(&world, out_id));
}

test "runProgram Optional ops: ??, !, ?., patterns, pop, m[k] (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The tranche-4 op surface end-to-end in the reference backend:
    // pop → some(20) then `?? -1` = 20; second pop force-unwraps to 10;
    // third pop on the emptied array → none, `?? -1` = -1;
    // m[1] present → 100, m[9] absent → `?? 7` = 7;
    // s?.len() on some("hello") → some(5), `?? 0` = 5;
    // match m[2] = some(200) → 201.
    // Sum: 20 + 10 - 1 + 100 + 7 + 5 + 201 = 342.
    const source =
        \\component Acc { out: int = 0 }
        \\rule opts(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut xs: int[] = [10, 20]
        \\  let a = xs.pop() ?? -1
        \\  let b = xs.pop()!
        \\  let c = xs.pop() ?? -1
        \\  let mut m = [1: 100, 2: 200]
        \\  let d = m[1] ?? 0
        \\  let e = m[9] ?? 7
        \\  let s: string? = some("hello")
        \\  let f = s?.len() ?? 0
        \\  let g = match m[2] {
        \\    some(x) => x + 1,
        \\    none => 0,
        \\  }
        \\  entity.get_mut(Acc).out = a + b + c + d + e + f + g
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[0..8]);
    try std.testing.expectEqual(@as(i64, 342), out);
}

test "runProgram force unwrap of none is a runtime failure (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `none!` panics (stdlib §16.2) — surfaced as a counted runtime error,
    // the interp's panic observable.
    const source =
        \\component Acc { out: int = 0 }
        \\rule boom(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut xs: int[] = []
        \\  let v = xs.pop()!
        \\  entity.get_mut(Acc).out = v
        \\}
    ;

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Acc").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 1), report.runtime_errors);
}
