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
//! - Structural mutation (`spawn`, `despawn`, `add(T)`, `remove(T)`) is a
//!   DEFERRED change (M1.0.10): a rule / observer / hook body enqueues a Tier-0
//!   `CommandBuffer` command onto `world.observer_registry.deferred`; it applies
//!   at the tick boundary via `applyWithObservers` (firing observers per op),
//!   never mid-`iterateArchetype`.
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
const descriptor_mod = @import("descriptor.zig");

const weld_core = @import("weld_core");
// M1.0.5 — persistent heap moved to Tier 0 (`src/core/memory`); reach it via weld_core.
const persistent = weld_core.memory.persistent;
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;
const FieldDesc = weld_core.ecs.registry.FieldDesc;
const FieldKind = weld_core.ecs.registry.FieldKind;
const DynamicArchetype = weld_core.ecs.archetype_dynamic.DynamicArchetype;
const Chunk = weld_core.ecs.archetype_dynamic.Chunk;
const World = weld_core.ecs.world.World;
const DynamicQuery = weld_core.ecs.world.DynamicQuery;
const CoreEntityId = weld_core.ecs.entity.EntityId;
const Tick = weld_core.ecs.tick.Tick;
const initial_tick = weld_core.ecs.tick.initial_tick;
// M1.0.9 — the Tier-0 scene loader (extension activate/deactivate runtime
// entries + the `ExtensionResolver` type). `weld_etch` depends on `weld_core`,
// so this is the legal direction (core never imports etch).
const scene_loader = weld_core.scene.loader;

const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;
const StringId = ast_mod.StringId;
const Diagnostic = diag_mod.Diagnostic;
const Value = value_mod.Value;
const EntityId = value_mod.EntityId;
const RuntimeError = value_mod.RuntimeError;
const RuntimeErrorKind = value_mod.RuntimeErrorKind;
const SourceSpan = @import("token.zig").SourceSpan;
const Bridge = bridge_mod.Bridge;
const command_buffer_mod = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer_mod.CommandBuffer;
const observers_mod = weld_core.ecs.observers;

/// Counters surfaced by `Interpreter.run` per tick — informational
/// only, used by tests + bench harnesses to assert hot-path coverage.
pub const RuntimeReport = struct {
    entities_iterated: u64 = 0,
    rules_evaluated: u64 = 0,
    rules_matched: u64 = 0,
    runtime_errors: u64 = 0,
    /// Typed payload of the most recent runtime failure that carried one
    /// (M0.8 E3-D, D-S4-runtime-report). Null when no failure occurred, or
    /// when the failing site has no typed conversion yet — residual untyped
    /// sites still bump `runtime_errors` and leave the previous payload in
    /// place. Interp-only / informational, like the counters above: the
    /// codegen runtime has no report counterpart, so the field is never a
    /// differential-parity obligation.
    last_error: ?RuntimeError = null,
    /// Root predicate evaluations against archetypes during matching-set
    /// rescans (M1.0.0 — generalised from the M0.8 D-S4-or-archetype counter).
    /// The observable proving the cached selection: every entity-bound rule
    /// evaluates each archetype once (at rescan, when it first appears), not
    /// once per archetype per tick.
    predicate_archetype_evals: u64 = 0,
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

/// One field binding captured at lower time for a §6 general filter (M0.8
/// E4): name + layout, so the guard evaluator can bind the field's current
/// value into the filter expression's scope.
const BoundField = struct {
    name: StringId,
    offset: u16,
    kind: FieldKind,
};

/// One `has T { expression }` general filter (M0.8 E4 — item-4 ruling).
/// Flat-AND with the other per-entity guards, mirroring the documented S4
/// model the narrow field filters follow.
const ExprFilter = struct {
    component_id: ComponentId,
    expr: NodeId,
    fields: []BoundField,
};

/// One `resource T { expression }` filter (M0.8 E4) — gates the whole rule
/// evaluation, like the resource deps it rides with.
const ResourceExprFilter = struct {
    resource_id: ComponentId,
    expr: NodeId,
    fields: []BoundField,
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

/// A deferred extension activate/deactivate (M1.0.9 B1 round-trip). Enqueued by
/// the Etch `entity.activate_extension`/`deactivate_extension` methods during a
/// tick — the extension bytes are resolved AT THE CALL — and applied at the tick
/// boundary (after every rule has run, so never mid-`iterateArchetype`-walk;
/// applying adds/removes components, an archetype transition). The immediate
/// `runtimeActivate`/`runtimeDeactivate` loader entries stay for the load +
/// direct-programmatic paths, which run outside any query iteration.
const ExtOp = enum { activate, deactivate };

const PendingExtension = struct {
    entity: CoreEntityId,
    /// Owned copy of the extension name (the AST / run-string source may not
    /// outlive the flush); freed when the batch is drained.
    name: []u8,
    /// Borrowed cooked `.prefab.bin` bytes, resolved at the call site; the
    /// resolver's backing outlives the tick.
    bytes: []const u8,
    op: ExtOp,
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
    /// M1.0.0 — the rule's archetype selection: one Tier-0 `DynamicQuery`
    /// per conjunctive term of the `when` clause's DNF (`has T` → `with`,
    /// `not entity has T` → `without`). The rule's matched-archetype set is
    /// the UNION of the terms' results. A pure-`and` `when` yields one term;
    /// `or` yields one per disjunct. Empty for a non-entity-bound rule (the
    /// global / resource-only / event path never selects archetypes) and for
    /// an entity-bound rule whose every term is structurally unsatisfiable
    /// (`has T` ∧ `not has T` → matches nothing). Each query reuses
    /// `archetypeMatches` + the shared option-β lazy re-scan
    /// (`query.rescanNewArchetypes`) — the interpreter no longer carries its
    /// own archetype matcher or rescan loop (the M1.0.0 root-cause fix:
    /// `interp.zig` stops duplicating `query.zig`).
    selection: []DynamicQuery,
    resource_deps: []ResourceDep,
    /// Per-entity field filters, one per `has T { field == value }` clause
    /// (M0.8 E3-D, D-S4-multifilter — was a single overwrite-on-collision
    /// slot). Flat-AND model: every filter must pass, regardless of its
    /// position under `or`/`not` (the documented S4 imprecision, same as
    /// `tag_predicates`).
    field_filters: []FieldFilter,
    /// Per-entity tag query predicates (M0.8 E3) — applied after the field
    /// filters at iteration time, ANDed with the rest (same flat model as
    /// `field_filters`; an `or`/`not` over a tag filter is the same documented
    /// S4-debt imprecision the field filters carry — the differential uses
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
    /// `@on_added/removed/replaced/spawned/despawned` structural-observer routing
    /// (M1.0.2 E2): the lifecycle kind, or null for a non-observer rule. Recorded
    /// at descriptor build, mirroring `event_type`. The Tier-0 ObserverRegistry
    /// bridge + dispatch exclusion are E3 — in E2 the field is populated but not
    /// yet consumed by `runRule` / world bind.
    observer_kind: ?ast_mod.ObserverKind,
    /// The resolved target `ComponentId` of an `@on_added/removed/replaced(T)`
    /// observer (M1.0.2 E2), or null for `@on_spawned` / `@on_despawned` and for a
    /// non-observer rule. Resolved against the world registry at descriptor build.
    observer_component: ?ComponentId,
    /// `entity has T changed` change-detection filters (M0.8 E3): component ids
    /// that must have changed since `last_run_tick` for the entity to match.
    /// Per-entity, ANDed after the field filter and tag predicates (same flat
    /// model). Empty for a rule with no `changed` filter.
    changed_filters: []ComponentId,
    /// `has T { expression }` general filters (M0.8 E4 — §6, item-4 ruling).
    /// Per-entity, evaluated AFTER the changed filters (fixed order, mirrored
    /// by the codegen guards), fields-only scope. Flat-AND.
    expr_filters: []ExprFilter,
    /// Bare expression conditions (M0.8 E4 — the §6 last arm). Per-entity for
    /// an entity-bound rule (rule params in scope, entity bound); evaluated
    /// once per tick for a global rule. Flat-AND, after `expr_filters`.
    expr_conds: []NodeId,
    /// `resource T { expression }` filters (M0.8 E4) — gate the whole rule
    /// evaluation, alongside the resource deps.
    resource_expr_filters: []ResourceExprFilter,
    /// The `current_tick` at which this rule last ran (`engine-ecs-internals.md`
    /// §5). A `changed` filter matches a slot iff `changedTick(slot) >
    /// last_run_tick`. Updated after each evaluation in `stepOnce`. Starts at
    /// `initial_tick` (0).
    last_run_tick: Tick,
    /// `async rule` (M0.8 E3 sub-slice B): the rule suspends at `await` and
    /// resumes a later tick via its `AsyncSlot`, instead of running to
    /// completion every tick. Dispatched by `runAsyncRule` in `stepOnce`.
    is_async: bool,
    /// Entities this rule matched in the most recent tick it ran (M1.0.0
    /// observable). Reset at the top of `runRule`'s entity-bound path,
    /// incremented per matched entity in `iterateArchetype`.
    /// `RuntimeReport.entities_iterated` is the program-wide sum; this is the
    /// per-rule breakdown surfaced by `Interpreter.ruleMatchedEntities`.
    /// Interp-only / informational, never a differential-parity obligation.
    matched_entities: u64 = 0,

    fn deinit(self: *RuleDesc, gpa: std.mem.Allocator) void {
        freeSelection(gpa, self.selection);
        gpa.free(self.resource_deps);
        gpa.free(self.field_filters);
        for (self.tag_predicates) |*tp| tp.deinit(gpa);
        gpa.free(self.tag_predicates);
        gpa.free(self.changed_filters);
        for (self.expr_filters) |ef| gpa.free(ef.fields);
        gpa.free(self.expr_filters);
        gpa.free(self.expr_conds);
        for (self.resource_expr_filters) |rf| gpa.free(rf.fields);
        gpa.free(self.resource_expr_filters);
    }
};

/// Free a rule's archetype selection — every `DynamicQuery` plus the slice.
fn freeSelection(gpa: std.mem.Allocator, selection: []DynamicQuery) void {
    for (selection) |*q| q.deinit(gpa);
    gpa.free(selection);
}

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
/// order, keys unique) addressed by `Value.map_ref`; sets (M0.8 E3-C tranche
/// 3bis) are `ArrayListUnmanaged(Value)` (insertion order, elements unique)
/// addressed by `Value.set_ref` — the same insertion-ordered policy as maps,
/// so the codegen mirror is byte-exact by construction. Reset at each
/// rule-body boundary so collections created inside a body do not leak across
/// invocations (rule-arena semantics, surface view of `etch-memory-model.md`
/// §6).
const CollectionStore = struct {
    arrays: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    maps: std.ArrayListUnmanaged(std.ArrayListUnmanaged(MapPair)) = .empty,
    sets: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,

    fn deinit(self: *CollectionStore, gpa: std.mem.Allocator) void {
        for (self.arrays.items) |*a| a.deinit(gpa);
        self.arrays.deinit(gpa);
        for (self.maps.items) |*m| m.deinit(gpa);
        self.maps.deinit(gpa);
        for (self.sets.items) |*s| s.deinit(gpa);
        self.sets.deinit(gpa);
    }

    /// Free every per-body collection, keeping the outer vectors' capacity.
    fn reset(self: *CollectionStore, gpa: std.mem.Allocator) void {
        for (self.arrays.items) |*a| a.deinit(gpa);
        self.arrays.clearRetainingCapacity();
        for (self.maps.items) |*m| m.deinit(gpa);
        self.maps.clearRetainingCapacity();
        for (self.sets.items) |*s| s.deinit(gpa);
        self.sets.clearRetainingCapacity();
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

    /// Allocate a fresh empty set, returning its handle (M0.8 E3-C tranche
    /// 3bis).
    fn newSet(self: *CollectionStore, gpa: std.mem.Allocator) !u32 {
        const idx: u32 = @intCast(self.sets.items.len);
        try self.sets.append(gpa, .empty);
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

/// Upper bound on call-argument count for the stack-allocated source-order
/// evaluation buffer (M0.8 E4 named args). Far above any real signature;
/// exceeding it fails loud.
const max_call_args: usize = 64;

/// Control-flow signal raised by `break` / `continue` (M0.8 loop/break).
/// Carried on the interpreter (not as a return value) so it can cross
/// expression↔statement boundaries — e.g. a `break` inside a `match` arm block
/// nested in a loop body. The enclosing loop consumes it; `none` is the
/// ordinary fall-through.
const Control = enum { none, break_, continue_ };

/// What an enclosing loop should do once a control signal has surfaced.
const LoopAction = enum { again, stop, propagate };

/// Phase-1 fixed-timestep tick rate (`etch-reference-part1.md §9.12`): `await
/// wait(d)` converts a `Duration` to `async_tick` counts as `round(seconds *
/// 60)` — the 1/60 frame convention. M1.0.13 replaces this with scaled game time
/// WITHOUT changing the `wait` signature: at `time_scale = 1` and fixed `dt =
/// 1/60`, the behavior is identical.
const async_fixed_dt_hz: f64 = 60.0;

/// Parse the seconds of a `Duration` literal lexeme (`"1.5s"` → 1.5) — the
/// minimal Duration→seconds path `await wait` needs (M1.0.11 E3). `null` if the
/// lexeme is malformed. General `Duration` arithmetic stays out of scope.
fn durationLiteralSeconds(text: []const u8) ?f64 {
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    return std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch null;
}

// ─── Async suspension core (M1.0.11, `etch-reference-part1.md §9.12`) ─────────
//
// Phase 1 is the tree-walker; it reproduces the §9 observable async semantics
// WITHOUT the Phase-2 compiled state machine (`etch-bytecode.md §9`). A suspended
// task is a heap record — an `AsyncTask` in the `Interpreter.async_tasks` pool —
// carrying a RESUME FRAME-STACK: a stack of `AsyncFrame`s (innermost last), one
// per statement block on the call/control-flow path. `driveTask`/`driveLoop` is an
// ITERATIVE machine over that stack (no fibers, no per-task OS thread, §9.1):
//
//   - A statement-head `await` suspends the whole task at ANY depth: `driveLoop`
//     returns, the frame-stack persists, and resume re-enters the innermost frame
//     at its cursor — a prefix statement is NEVER re-run, so `emit` and structural
//     mutations don't double-fire. `wait(Duration)` resolves against `async_tick`
//     via the fixed 1/60 timestep (`async_fixed_dt_hz`); `global_event` against the
//     per-tick event store; the direct-call `future` (`await f()`) is frame
//     inlining (below).
//   - Frame kinds cover every EBNF v0.6 statement block (C1.6): `run` (rule/`fn`
//     body, `if` branch, `match` arm, plain block), `loop_`, `while_`, `for_`,
//     `try_` (a `throw` after a resume routes to the enclosing `try_` — the
//     handler is re-established across the suspension), and `call` (an inlined
//     `async fn`/`async method` body — `await f()` pushes `f`'s body + a heap-boxed
//     scope + a `RetTarget`; `f`'s own `await` suspends the whole task; `f`'s
//     `return` resolves at the caller's await site).
//   - Placement (Phase-1, type-checker `E0904`): `await` must be a statement's
//     full RHS on the frame-driven spine; a sub-expression `await`, or one in a
//     synchronously-evaluated VALUE block, is rejected. Coloring (§9.3, `E0901`):
//     an `await` / async call in a non-async `fn`/`rule` is rejected.
//   - A sync-only program allocates no task, keeps `async_tick` at 0, and is
//     byte-identical to the pre-async runtime (by construction).

/// The condition that resumes a suspended `async rule` (M0.8 E3 sub-slice B).
/// The tree-walker is its own runtime (`etch-reference-part1.md §9`): an
/// `await` suspends the rule as a task-record, polled each tick in `stepOnce`.
const WakeCond = union(enum) {
    /// Resume once `async_tick` reaches this value. `await wait(d)` reached at
    /// tick T sets it to T + `round(seconds(d) * 60)` — the Phase-1 fixed-timestep
    /// conversion (M1.0.11 E3, `async_fixed_dt_hz`). `wait_unscaled` (M1.0.13)
    /// stays fail-loud.
    wait_until: u64,
    /// Resume once an event of this type is present in the per-tick EventStore
    /// (M0.8 E3 sub-slice B — `await global_event(T)`). The producer must run
    /// before the awaiter in the rule order, same as the observer drain.
    global_event: StringId,
    /// A `race` parent (M1.0.12 E1): fires when at least one child in
    /// `task_children[start .. start+len]` is `.done` (a winner exists) — OR when
    /// no child remains `.suspended` (every branch failed/canceled: no winner,
    /// the race completes and the parent resumes after the statement, E4).
    /// A range into the shared `Interpreter.task_children` list, kept small.
    children_any: struct { start: u32, len: u32 },
    /// A `sync` parent (M1.0.12 E1): fires when no child in the range remains
    /// `.suspended` — failed (canceled) children do not block the join.
    children_all: struct { start: u32, len: u32 },
    /// A handle-await parent (M1.0.12 E1, `await h`): fires when the target task
    /// is no longer `.suspended`. The pool is monotonic (no slot reuse), so a
    /// bare pool index is a stable identity — no generation needed in Phase 1.
    task_done: u32,
};

/// One frame of an `AsyncTask`'s resume stack (M1.0.11 E1). The tree-walker is
/// its own runtime (`etch-reference-part1.md §9.12`): rather than a compiled
/// state machine (Phase-2 bytecode), a suspended task is a heap record holding a
/// STACK of frames — each a `(block, statement cursor)` position plus the control
/// shape needed to resume it. On `await` the whole stack is retained; `driveTask`
/// resumes by re-entering the innermost frame at its cursor and NEVER re-running
/// an already-executed statement (no double `emit`). The frame kinds mirror the
/// sync executor's control flow, ONE per statement block that can hold statements
/// — a linear `run` (rule body / `if` branch / `match` arm / plain `block` / — E2
/// — an inlined `async fn` body), a `loop`, a `while`, a `for`, and a `try`/`catch`
/// — so a statement-head `await` can suspend inside ANY of them. This generalizes
/// the M0.8 single-top-level-cursor `AsyncSlot` to nested blocks (the stack reaches
/// depth > 1). The frame set is COMPLETE for EBNF v0.6's statement blocks (C1.6):
/// no body kind falls through to a fail-loud await. `call` (M1.0.11 E2) is the
/// inlined body of an `async fn`/`async method` reached by a direct `await f()`; it
/// OWNS a heap-boxed scope (freed on pop — see `deinitFrame`), so teardown is not a
/// bare `frames.deinit`. The other frame kinds are pure indices.
const AsyncFrame = union(enum) {
    run: RunFrame,
    loop_: LoopFrame,
    while_: WhileFrame,
    for_: ForFrame,
    try_: TryFrame,
    call: CallFrame,
    single: SingleFrame,
};

/// A length-1 statement run (M1.0.12 E4): the root frame of a `race`/`sync`
/// child task whose branch is a single NON-block statement (`await wait(1.0s)`
/// or a guarded `if cond => stmt` — the branch statement is a bare `NodeId` in
/// `arena.concurrency_branches`, not an `arena.extra` run, so `RunFrame`'s
/// range encoding cannot address it). `cursor` 0 = not yet run, 1 = done →
/// pop. Transparent to `unwindControl` like a `run` frame.
const SingleFrame = struct {
    stmt: NodeId,
    cursor: u32 = 0,
};

/// A linear statement run: execute `block[cursor .. block_len]`, then (if any)
/// evaluate the trailing `block_expr` value for effect, then pop. Backs the rule
/// body, an `if` branch, a `match` arm block, and a plain `{ }` block.
const RunFrame = struct {
    block_start: u32,
    block_len: u32,
    cursor: u32 = 0,
    /// Trailing `block_expr` value expression, evaluated for effect on pop
    /// (`null` for a rule body or a value-less block). Statement-position blocks
    /// discard the value, but a side-effecting trailing expr must still run.
    value_expr: ?NodeId = null,
};

/// `loop { body }`: run the body, resetting the cursor to 0 at the end so it
/// repeats; a `break`/`continue` targeting `label` (or unlabeled) is consumed by
/// `unwindControl`.
const LoopFrame = struct {
    block_start: u32,
    block_len: u32,
    cursor: u32 = 0,
    label: StringId = 0,
};

/// `while [let x =] cond { body }`: at the top of each iteration (`in_iter =
/// false`) re-evaluate the condition; enter the body (`in_iter = true`) while it
/// holds, and drop back to the condition when the body run completes. `while`
/// carries no loop label (mirrors the sync executor's `handleLoopControl(0)`).
const WhileFrame = struct {
    while_id: NodeId,
    cursor: u32 = 0,
    in_iter: bool = false,
};

/// The iterator state of a `for` frame, persisted across a suspension. A `range`
/// is fully self-contained (no heap) → sound across any suspend. An `array`/`map`
/// holds a collection-store handle + the once-snapshotted length + the current
/// index; the referenced collection lives in the rule-arena store, so a heap
/// iterable surviving a suspend shares the M0.8 "POD-only across a suspend" caveat
/// (a store reset by an intervening rule frees it). `forAdvance` bounds-checks the
/// handle and fails loud (a typed `RuntimeFailure`, never an OOB crash) rather than
/// dereference a reset store. The common `for i in 0..N` (range) is unconditionally
/// sound.
const ForIter = union(enum) {
    range: struct { next: i64, end: i64, inclusive: bool },
    array: struct { handle: u32, len: usize, idx: usize },
    map: struct { handle: u32, len: usize, idx: usize },
};

/// `for v [, k] in iter { body }`: at the top of each iteration (`in_iter =
/// false`) advance the iterator and bind the loop variable(s); run the body while
/// elements remain, dropping back to the iterator when the body run completes. The
/// iterator position lives in `iter`, persisted across suspension so a body
/// `await` resumes at the same element. `for` carries no loop label (mirrors the
/// sync executor's `handleLoopControl(0)`).
const ForFrame = struct {
    for_id: NodeId,
    iter: ForIter,
    cursor: u32 = 0,
    in_iter: bool = false,
};

/// `try { body } catch e { handler }`: drives the `try` body (`in_catch = false`);
/// a `throw` reaching this frame (possibly after a suspension inside the body —
/// the handler is re-established across the suspend) switches it to the `catch`
/// body (`in_catch = true`, the caught value bound to `catch_name`). Mirrors the
/// sync `try_catch_stmt` arm of `execStmt`.
const TryFrame = struct {
    try_start: u32,
    try_len: u32,
    catch_start: u32,
    catch_len: u32,
    catch_name: StringId,
    cursor: u32 = 0,
    in_catch: bool = false,
};

/// Where an `await`'s resolved value is delivered at the caller's await site
/// (M1.0.11 E2). Set from the statement that carries the `await`: a bare
/// expr-statement discards it; a `let x = await …` binds a fresh local; an
/// `x = await …` assigns an existing local; a `return await …` returns it from
/// the enclosing `async fn` / rule.
const RetTarget = union(enum) {
    discard,
    bind: struct { name: StringId, is_mut: bool },
    assign_local: StringId,
    return_,
};

/// The inlined body of an `async fn` / `async method` reached by a direct
/// `await f()` (M1.0.11 E2, `etch-reference-part1.md §9.12`): `f`'s body runs as
/// frames on the CALLER's task, so `f`'s own `await` suspends the whole task and
/// `f`'s `return` resolves at the caller's await site. Owns a heap-boxed `scope`
/// (f's params/locals — freed when the frame pops); `value_expr` is f's trailing
/// block value (implicit return); `ret` is where f's return value is delivered.
const CallFrame = struct {
    block_start: u32,
    block_len: u32,
    cursor: u32 = 0,
    scope: *Locals,
    value_expr: ?NodeId = null,
    ret: RetTarget,
};

/// A suspendable task (M1.0.11 E1) — the dynamic-pool replacement for the M0.8
/// per-rule `AsyncSlot`. Holds the resume frame-stack (`frames`, innermost last),
/// the wake condition it is blocked on, and the locals retained across
/// suspension. Since M1.0.12 E1 each task is a HEAP record (`gpa.create`) in the
/// `Interpreter.async_tasks` pointer pool: `race`/`sync`/`branch`/`spawn` create
/// sibling tasks MID-DRIVE, so pool growth must not invalidate the live
/// `*AsyncTask` threaded through `driveTask`/`driveLoop`/`stepBodyStmt` (nor
/// `currentScope`'s `&task.locals`). The pool is MONOTONIC in Phase 1: no slot
/// reuse — a completed task parks as a small husk (frames + locals freed,
/// `result` retained), which makes `await` on an already-done handle trivially
/// correct without generations or refcounting. This is the tree-walk analogue of
/// the async state struct (`etch-memory-model.md §5.7`) — no compiled state
/// machine (that is Phase-2 codegen).
const AsyncTask = struct {
    /// `.suspended` = live (schedulable when `wake` fires); `.done` = completed
    /// normally (`result` parked); `.canceled` = terminated WITHOUT a result —
    /// explicitly canceled (`cancelTask`) or, from E4, failed loud (uncaught
    /// `throw` / runtime failure). A `.canceled` task is never a race winner,
    /// never blocks a `sync` join, and `await`ing it fails loud (§9.8 amended).
    state: enum { suspended, done, canceled } = .suspended,
    wake: WakeCond = .{ .wait_until = 0 },
    frames: std.ArrayListUnmanaged(AsyncFrame) = .empty,
    /// The task's ROOT locals (the rule body's scope), retained across suspension.
    /// An `async fn` call frame carries its OWN scope (`CallFrame.scope`); the
    /// active scope for a statement is `currentScope` (nearest enclosing call
    /// frame, else this). POD-only across a suspend (the M0.8 caveat).
    locals: Locals = .{},
    /// The delivery target for a wake-condition `await` used in a value position
    /// (`let x = await wait(…)`): the (unit) value is bound on resume (M1.0.11
    /// E2). `.discard` for a bare `await wait/global_event` (the common form).
    pending_bind: RetTarget = .discard,
    /// The async rule descriptor index that transitively created this task
    /// (M1.0.12 E1). Drive-by-origin schedules every task at ITS RULE's position
    /// in the rule order — events emitted by child tasks interleave there,
    /// deterministically, including for detached tasks outliving their parent.
    origin_rule: u32 = 0,
    /// Pool index of the task that created this one (M1.0.12 E1); `null` for
    /// rule roots — and for detached (`branch`/`spawn`) tasks after creation
    /// bookkeeping. Cancellation is NON-transitive (Phase 1): this link is
    /// lineage bookkeeping, not a cancellation channel.
    parent: ?u32 = null,
    /// Parked completion value (M1.0.12 E1): the husk keeps it after frames +
    /// locals are freed. For a `spawn` task it is the handle-await delivery
    /// value — always `.unit` in Phase 1 (`spawn` bodies are blocks — no value
    /// channel, brief Notes). For a `race` child it carries the branch's
    /// pending `return` value (with `returned` set, E4) — re-raised at the
    /// race site if this child wins; discarded otherwise.
    result: Value = .{ .unit = {} },
    /// True when the task completed via a task-level `return` (M1.0.12 E4):
    /// `result` then holds the returned value. Only a `race` branch may
    /// return (E0906), so this drives winner-return propagation (§9.5);
    /// meaningless-but-harmless on other tasks.
    returned: bool = false,

    fn deinit(self: *AsyncTask, gpa: std.mem.Allocator) void {
        for (self.frames.items) |*f| switch (f.*) {
            .call => |cf| {
                cf.scope.deinit(gpa);
                gpa.destroy(cf.scope);
            },
            else => {},
        };
        self.frames.deinit(gpa);
        self.locals.deinit(gpa);
    }
};

/// Outcome of one `driveTask` pass over a task's frame-stack (M1.0.11 E1).
const AsyncOutcome = enum { suspended, completed };

/// Result of stepping one body statement in `stepBodyStmt` (M1.0.11 E1).
const StepAction = enum {
    /// A plain statement ran and the cursor advanced.
    advanced,
    /// A child frame (nested block / loop / while) was pushed; the parent cursor
    /// was already advanced past the control-flow statement.
    pushed,
    /// A statement-head `await` suspended the task (stack retained).
    suspended,
    /// `break`/`continue`/`return`/`throw` fired — `unwindControl` handles it.
    signaled,
};

/// Per-observer-rule context handed to the Tier-0 `ObserverRegistry` as the
/// opaque `ctx` pointer (M1.0.2 E3). Points back at the interpreter + the
/// descriptor index so the trampoline can run the right rule body. Allocated
/// once per binding in `bindToWorld`, freed at `deinit` — the interpreter must
/// outlive any flush that fires its observers.
const ObserverCtx = struct {
    interp: *Interpreter,
    rule_desc_idx: usize,
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
    /// Level-B descriptors built at compile (M0.8 E4 — the interpreter's
    /// build-structure side of the serialized-IR differential). No runtime
    /// role: Level B never executes against the world (proof contract,
    /// brief journal 2026-06-10).
    descriptors: descriptor_mod.Descriptors = .{},
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
    /// Span of the in-flight `throw`'s value expression (M0.8 E3-D) —
    /// harvested into an `UncaughtThrow` report entry when the throw reaches
    /// the rule top level uncaught. Irrelevant once a `catch` consumes the
    /// throw.
    thrown_span: SourceSpan = .{ .byte_start = 0, .byte_end = 0 },
    /// In-flight typed runtime-error payload (M0.8 E3-D,
    /// D-S4-runtime-report). Zig errors carry no payload, so the typed
    /// `RuntimeError` rides on `self` — the same sideband pattern as
    /// `thrown_value` — set by `fail` at the raise site and harvested into
    /// `RuntimeReport.last_error` at the body choke points. Raise sites
    /// without a typed conversion leave it null (the report still counts).
    pending_error: ?RuntimeError = null,
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
    /// M1.0.9 B1 — deferred extension activate/deactivate, drained at the tick
    /// boundary (after iteration). Mirror of `pending_tags`.
    pending_extensions: std.ArrayListUnmanaged(PendingExtension) = .empty,
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
    /// `await wait(d)` resolves against it: a `Duration` is converted to a tick
    /// count via the fixed 1/60 timestep (`async_fixed_dt_hz`, M1.0.11 E3).
    async_tick: u64 = 0,
    /// Dynamic pool of suspendable tasks (M1.0.11 E1) — the growable replacement
    /// for the M0.8 per-rule `AsyncSlot` slice. POINTER-STABLE since M1.0.12 E1:
    /// each element is a heap record (`gpa.create`), because `race`/`sync`/
    /// `branch`/`spawn` create sibling tasks MID-DRIVE and an append must not
    /// invalidate the live `*AsyncTask` (or `&task.locals`) threaded through the
    /// drive path. MONOTONIC: no slot reuse — a finished task parks as a husk
    /// (state `.done`/`.canceled`) until `deinit`, so a pool index is a stable
    /// task identity (Phase-1 `TaskHandle`, no generations). Empty when
    /// `!has_async`.
    async_tasks: std.ArrayListUnmanaged(*AsyncTask) = .empty,
    /// Shared child-set storage (M1.0.12 E1): a `race`/`sync` parent appends its
    /// admitted children's pool indices here and suspends on a `WakeCond` range
    /// `{start, len}` into it — keeps `WakeCond` small. Append-only within a
    /// program run (ranges stay valid for the parent's whole suspension).
    task_children: std.ArrayListUnmanaged(u32) = .empty,
    /// Per-rule handle into `async_tasks` (parallel to `rule_descs`, allocated iff
    /// `has_async`): `null` until the async rule first spawns, then the pool index
    /// of its task. A non-async rule's entry stays `null`.
    rule_tasks: []?u32 = &.{},
    /// Reusable cursor buffer for the multi-term (`or`) archetype-union merge
    /// (M1.0.0). Resized to the term count of the rule being iterated; capacity
    /// is retained across rules/ticks so the union path allocates at most once.
    /// Untouched by single-term rules (the common case iterates directly).
    merge_cursors: std.ArrayListUnmanaged(usize) = .empty,
    /// Per-observer-rule contexts registered into the world's `ObserverRegistry`
    /// at `bindToWorld` (M1.0.2 E3). One entry per rule with `observer_kind`
    /// set; the registry holds `&observer_ctxs[k]` as its opaque `ctx`. Freed at
    /// `deinit` (the interpreter must outlive any observer-firing flush).
    observer_ctxs: []ObserverCtx = &.{},
    /// Set once observers have been registered (idempotent `bindToWorld`).
    observers_bound: bool = false,
    /// Non-null while an observer body runs (M1.0.2 E3): the registry's deferred
    /// command buffer. Structural mutations issued by the body (tag mutations)
    /// route here instead of `pending_tags`, so they apply at the NEXT flush —
    /// never re-entrantly during the current one (the no-recursion contract).
    observer_deferred: ?*CommandBuffer = null,
    /// The world this program was compiled against (`compile`), borrowed for the
    /// persistent-string teardown in `deinit` (M1.0.3 E2). The interpreter is
    /// already lifecycle-coupled to the world (its observer ctxs are registered
    /// into the world's `ObserverRegistry`), so storing it here is consistent;
    /// the world MUST outlive the interpreter (the existing contract — `deinit`
    /// before `world.deinit`). `null` only before `compile` returns.
    world: ?*World = null,
    /// Immortal persistent-heap blocks holding compile-time `string` field
    /// defaults (M1.0.3 E2). Allocated in `compileTypeDecl` via `allocImmortal`
    /// (sentinel refcount, so slot decref never frees them) and `destroy`'d here
    /// at `deinit` — they have no slot-owner to reclaim them, so the interpreter
    /// (their allocator) does. Freed AFTER the per-slot decref so an un-overwritten
    /// default (slot still points at its immortal block) is reclaimed exactly once.
    persistent_literals: std.ArrayListUnmanaged([*]u8) = .empty,

    pub fn deinit(self: *Interpreter) void {
        // M1.0.3 E2 — persistent-string teardown, BEFORE `bridge.deinit` (which
        // drops the resource-name → id map this enumeration needs) and while the
        // world's resource store is still alive (freed later by `world.deinit`).
        // Iterate every resource's `.string_` slots and `decref` uniformly: a
        // sentinel (immortal default) block no-ops, a refcounted user-written
        // block frees. Then `destroy` the immortal defaults via the literal
        // registry — no double-free: the slot decref left immortals alive.
        if (self.world) |w| {
            var it = self.bridge.resources.valueIterator();
            while (it.next()) |id_ptr| {
                const rid = id_ptr.*;
                const buf = w.resources.getResource(rid) orelse continue;
                for (w.registry.componentFields(rid)) |fd| {
                    if (fd.kind != .string_) continue;
                    var ss: persistent.StringSlot = undefined;
                    @memcpy(std.mem.asBytes(&ss), buf[fd.offset .. fd.offset + @sizeOf(persistent.StringSlot)]);
                    if (ss.ptr != 0) persistent.decref(self.gpa, @ptrFromInt(ss.ptr));
                }
            }
        }
        for (self.persistent_literals.items) |block| persistent.destroy(self.gpa, block);
        self.persistent_literals.deinit(self.gpa);
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
        for (self.pending_extensions.items) |pe| self.gpa.free(pe.name);
        self.pending_extensions.deinit(self.gpa);
        for (self.async_tasks.items) |task| {
            task.deinit(self.gpa);
            self.gpa.destroy(task);
        }
        self.async_tasks.deinit(self.gpa);
        self.task_children.deinit(self.gpa);
        self.gpa.free(self.rule_tasks);
        self.descriptors.deinit(self.gpa);
        self.merge_cursors.deinit(self.gpa);
        self.gpa.free(self.observer_ctxs);
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

        // Immortal blocks backing compile-time `string` field defaults (M1.0.3
        // E2). Filled by `compileTypeDecl`; moved into the returned interpreter,
        // which `destroy`s them at `deinit`. On a compile error path they are
        // reclaimed here so no default literal leaks.
        var persistent_literals: std.ArrayListUnmanaged([*]u8) = .empty;
        errdefer {
            for (persistent_literals.items) |block| persistent.destroy(gpa, block);
            persistent_literals.deinit(gpa);
        }

        // Pass A — register components and resources with the world.
        var i: u28 = 0;
        while (i < ast.items.len) : (i += 1) {
            const kind = ast.items.items(.kind)[i];
            const data = ast.items.items(.data)[i];
            switch (kind) {
                .component_decl => try compileComponent(gpa, ast, world, &bridge, ast.component_decls.items[data], &persistent_literals),
                .resource_decl => try compileResource(gpa, ast, world, &bridge, ast.resource_decls.items[data], &persistent_literals),
                else => {},
            }
        }

        // Register the builtin `TagSet` component (M0.8 E3) when the program
        // declares any tag — a fixed `[words]u64` bitfield, one slot per entity
        // carrying tags. It has no named scalar fields; the runtime reads/writes
        // its raw bytes as bits.
        var tagset_id: ?ComponentId = null;
        if (tag_table.leaf_count > 0) {
            // Idempotent on a hot-reload re-compile (M0.8 E7): reuse the
            // already-registered `TagSet` instead of erroring DuplicateComponent.
            if (world.registry.idOf("TagSet")) |existing| {
                try bridge.mapComponent(gpa, "TagSet", existing);
                tagset_id = existing;
            } else {
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
            const desc = try compileRule(gpa, ast, &bridge, world, &tag_table, tagset_id, data);
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
        // Allocate the per-rule task-handle map iff any rule is `async` (M1.0.11
        // E1). The task pool itself starts empty and grows on first spawn; a
        // sync-only program keeps an empty map + pool and never advances
        // `async_tick` — byte-identical to the pre-async runtime.
        var any_async = false;
        for (slice) |rd| {
            if (rd.is_async) {
                any_async = true;
                break;
            }
        }
        const rule_tasks: []?u32 = if (any_async) blk: {
            const map = try gpa.alloc(?u32, slice.len);
            @memset(map, null);
            break :blk map;
        } else &.{};

        // Pass E — build the Level-B descriptors (M0.8 E4, build-structure
        // side of the serialized-IR differential). Fail-loud on any
        // expression the canonical renderer does not support.
        var descriptors = try descriptor_mod.build(gpa, ast);
        errdefer descriptors.deinit(gpa);

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
            .rule_tasks = rule_tasks,
            .descriptors = descriptors,
            .world = world,
            .persistent_literals = persistent_literals,
        };
    }

    pub fn runFor(self: *Interpreter, world: *World, ticks: u32) !RuntimeReport {
        // Register this program's observer rules into the world's
        // `ObserverRegistry` (M1.0.2 E3) — lazily, once, now that `self` is at a
        // stable address (the caller holds the interpreter; `compile` returns by
        // value). A test that drives a Tier-0 flush directly calls `bindToWorld`
        // itself before flushing.
        try self.bindToWorld(world);
        var report: RuntimeReport = .{};
        var t: u32 = 0;
        while (t < ticks) : (t += 1) {
            try self.stepOnce(world, &report);
            world.tickBoundary();
        }
        return report;
    }

    /// M1.0.9 — give the interpreter a runtime extension resolver (name → cooked
    /// `.prefab.bin` bytes, the same interface the scene loader receives) so an
    /// Etch `entity.activate_extension("X")` / `deactivate_extension("X")`
    /// resolves the extension at runtime. Absent → those methods fail with
    /// `error.MissingExtensionResolver`.
    pub fn setExtensionResolver(self: *Interpreter, resolver: scene_loader.ExtensionResolver) void {
        self.bridge.ext_resolver = resolver;
    }

    /// Register this program's observer rules into `world`'s `ObserverRegistry`
    /// (M1.0.2 E3). Idempotent: the first call allocates one `ObserverCtx` per
    /// observer rule and registers a trampoline keyed on the rule's lifecycle
    /// kind + target component; later calls no-op. Called lazily by `runFor`, or
    /// explicitly by a test that drives a Tier-0 flush before any tick.
    pub fn bindToWorld(self: *Interpreter, world: *World) !void {
        if (self.observers_bound) return;
        self.observers_bound = true;

        // M1.0.9 — register the extension hook seams so the loader's
        // `dispatchOnAttach` / runtime `deactivate_extension` reach `execHookText`.
        // Registered unconditionally (before the observer-rule early-return): the
        // callbacks only fire when an extension actually activates / deactivates,
        // so a program with no observer rules still wires its hook execution.
        world.registerOnAttach(self, &extensionAttachTrampoline);
        world.registerOnDetach(self, &extensionDetachTrampoline);

        var n: usize = 0;
        for (self.rule_descs) |rd| {
            if (rd.observer_kind != null) n += 1;
        }
        if (n == 0) return;

        self.observer_ctxs = try self.gpa.alloc(ObserverCtx, n);
        var k: usize = 0;
        const reg = &world.observer_registry;
        for (self.rule_descs, 0..) |rd, idx| {
            const kind = rd.observer_kind orelse continue;
            self.observer_ctxs[k] = .{ .interp = self, .rule_desc_idx = idx };
            const ctx: *anyopaque = @ptrCast(&self.observer_ctxs[k]);
            k += 1;
            switch (kind) {
                .on_added => try reg.registerOnAdd(self.gpa, world, rd.observer_component.?, ctx, &observerTrampoline),
                .on_removed => try reg.registerOnRemove(self.gpa, world, rd.observer_component.?, ctx, &observerTrampoline),
                .on_replaced => try reg.registerOnReplaced(self.gpa, world, rd.observer_component.?, ctx, &observerTrampoline),
                .on_spawned => try reg.registerOnSpawned(self.gpa, world, ctx, &observerTrampoline),
                .on_despawned => try reg.registerOnDespawned(self.gpa, world, ctx, &observerTrampoline),
            }
        }
    }

    /// Top-level trampoline matching `observers.ObserverFn` (M1.0.2 E3): unpack
    /// the `ObserverCtx` and run the observer rule body with `entity` + the
    /// lifecycle value(s) bound.
    fn observerTrampoline(
        ctx_opaque: ?*anyopaque,
        world: *World,
        entity: CoreEntityId,
        component_id: ?ComponentId,
        old_value: ?*const anyopaque,
        new_value: ?*const anyopaque,
        deferred: *CommandBuffer,
    ) anyerror!void {
        _ = component_id;
        const ctx: *ObserverCtx = @ptrCast(@alignCast(ctx_opaque.?));
        try ctx.interp.runObserverBody(world, ctx.rule_desc_idx, entity, old_value, new_value, deferred);
    }

    /// Run an observer rule body (M1.0.2 E3): bind `entity` and the lifecycle
    /// value(s) on the rule's declared params, then execute the body. The value
    /// bindings (`value`/`old`/`new`) are materialised as struct values over the
    /// raw component bytes (`readBytesAsValue` per field) — the same shape as the
    /// `@on_event` payload binding, so the existing struct-field-access path
    /// serves `value.field` etc. Structural mutations issued by the body route to
    /// `deferred` (no re-entrant apply — see `observer_deferred`).
    fn runObserverBody(
        self: *Interpreter,
        world: *World,
        idx: usize,
        entity: CoreEntityId,
        old_value: ?*const anyopaque,
        new_value: ?*const anyopaque,
        deferred: *CommandBuffer,
    ) !void {
        const rd = self.rule_descs[idx];
        const rule = self.ast.rule_decls.items[rd.rule_idx];

        var locals: Locals = .{};
        defer locals.deinit(self.gpa);
        defer self.collections.reset(self.gpa);
        defer self.closures.reset(self.gpa);
        defer self.structs.reset(self.gpa);
        defer self.optionals.clearRetainingCapacity();
        defer self.resetRunStrings();

        // Bind the declared params by name (the names are validated in E2):
        // `entity` → the triggering entity; `value`/`new` → new_value bytes;
        // `old` → old_value bytes. A binding whose byte source is null (kind
        // mismatch) is skipped — the body cannot reference it.
        var p: u32 = 0;
        while (p < rule.params_len) : (p += 1) {
            const param = self.ast.rule_params.items[rule.params_start + p];
            const pname = self.ast.strings.slice(param.name);
            if (std.mem.eql(u8, pname, "entity")) {
                try locals.put(self.gpa, param.name, .{ .entity_id = @bitCast(entity) }, false);
            } else if (std.mem.eql(u8, pname, "old")) {
                if (old_value) |ov| try locals.put(self.gpa, param.name, try self.observerValueStruct(world, rd.observer_component.?, ov), false);
            } else { // "value" (on_added) or "new" (on_replaced)
                if (new_value) |nv| try locals.put(self.gpa, param.name, try self.observerValueStruct(world, rd.observer_component.?, nv), false);
            }
        }

        // Route the body's structural mutations to the registry's deferred buffer
        // for the duration of the body (no-recursion contract).
        const prev_deferred = self.observer_deferred;
        self.observer_deferred = deferred;
        defer self.observer_deferred = prev_deferred;

        self.control = .none;
        self.thrown = false;
        self.returning = false;
        self.pending_error = null;

        var s: u32 = 0;
        while (s < rule.body_len) : (s += 1) {
            const stmt_id: NodeId = @bitCast(self.ast.extra.items[rule.body_start + s]);
            self.execStmt(world, &locals, stmt_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A runtime failure in an observer body unwinds the body (the
                // Tier-0 flush has no `RuntimeReport` sideband to harvest into).
                error.RuntimeFailure => {
                    self.pending_error = null;
                    return;
                },
            };
            if (self.thrown) {
                self.thrown = false;
                self.pending_error = null;
                return;
            }
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
    }

    /// Execute a cooked extension hook body (M1.0.9 E2). `hook_text` is the
    /// canonical Etch statement run a `.prefab.bin` carries for an `on_attach` /
    /// `on_detach` hook (`descriptor.renderStmtRunAlloc`): statements joined by
    /// `"; "`, no braces. Parse it into a transient `AstArena`, rebind `self.ast`
    /// to it for the body's duration (the executor resolves identifiers via
    /// `self.ast.strings`, so the body MUST run with `ast` pointing at the hook
    /// arena), bind the implicit `entity`, run the body with the same
    /// `execStmtRun` that drives every rule, and route any deferred structural
    /// change into the world's shared observer-deferred buffer (drained by the
    /// loader before `on_spawned`). Mirrors `runObserverBody` — same fresh-scope
    /// + store-reset discipline. No re-entrancy: a hook runs at a load/flush
    /// boundary, never nested inside another running hook.
    fn execHookText(self: *Interpreter, world: *World, entity: CoreEntityId, hook_text: []const u8) !void {
        var block = parser_mod.parseStmtBlock(self.gpa, hook_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A cooked hook that fails to re-parse is a corrupt asset (the cook
            // validated it via `renderStmtRunAlloc` → `HookRenderFailed`), so this
            // should be unreachable in practice — surface it clearly regardless.
            else => return error.MalformedExtensionHook,
        };
        defer block.deinit(self.gpa);
        if (block.diagnostics.len > 0) return error.MalformedExtensionHook;

        // Rebind the program AST to the hook arena for the body's duration. Safe:
        // `ast` is a reassignable `*const AstArena` field; nothing on the executor
        // path dereferences a *program*-arena `NodeId` while rebound (component /
        // resource field access + enum shorthand resolve by NAME via the registry,
        // `emit` enqueues by event-name id, and hook-arena `StringId`s resolve
        // through `self.ast.strings`).
        const saved_ast = self.ast;
        self.ast = &block.ast;
        defer self.ast = saved_ast;

        var locals: Locals = .{};
        defer locals.deinit(self.gpa);
        defer self.collections.reset(self.gpa);
        defer self.closures.reset(self.gpa);
        defer self.structs.reset(self.gpa);
        defer self.optionals.clearRetainingCapacity();
        defer self.resetRunStrings();

        // Bind the implicit `entity` — only if the body references it (else the
        // name is not interned in the hook arena and no binding is needed).
        if (block.ast.strings.find("entity")) |eid| {
            try locals.put(self.gpa, eid, .{ .entity_id = @bitCast(entity) }, false);
        }

        // Route the body's deferred structural mutations to the world's shared
        // observer-deferred buffer (lazily created; freed by the registry). The
        // loader drains it before `on_spawned`, so a hook-issued structural change
        // is applied at the same flush boundary an observer's would be.
        if (world.observer_registry.deferred == null) {
            world.observer_registry.deferred = CommandBuffer.init(self.gpa, world);
        }
        const prev_deferred = self.observer_deferred;
        self.observer_deferred = &world.observer_registry.deferred.?;
        defer self.observer_deferred = prev_deferred;

        self.control = .none;
        self.thrown = false;
        self.returning = false;
        self.pending_error = null;

        self.execStmtRun(world, &locals, block.body_start, block.body_len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RuntimeFailure => {
                self.pending_error = null;
                self.thrown = false;
                self.returning = false;
                self.control = .none;
                return error.ExtensionHookFailed;
            },
        };
        // Leave the interpreter clean for the next body (a hook `return` / control
        // signal is not meaningful at a hook boundary — reset like an observer).
        self.thrown = false;
        self.returning = false;
        self.control = .none;
        self.pending_error = null;
    }

    /// Top-level trampoline matching `World.ExtensionAttachFn` (M1.0.9 E2):
    /// recover the `*Interpreter` from `ctx` and execute the cooked `on_attach`
    /// hook text. `null` text (an extension with no `on_attach`) is a no-op.
    fn extensionAttachTrampoline(ctx: ?*anyopaque, world: *World, entity: CoreEntityId, name: []const u8, text: ?[]const u8) anyerror!void {
        _ = name;
        const self: *Interpreter = @ptrCast(@alignCast(ctx.?));
        if (text) |t| try self.execHookText(world, entity, t);
    }

    /// Top-level trampoline matching `World.ExtensionDetachFn` (M1.0.9 E3): same
    /// shape as the attach trampoline, for the `on_detach` hook text.
    fn extensionDetachTrampoline(ctx: ?*anyopaque, world: *World, entity: CoreEntityId, name: []const u8, text: ?[]const u8) anyerror!void {
        _ = name;
        const self: *Interpreter = @ptrCast(@alignCast(ctx.?));
        if (text) |t| try self.execHookText(world, entity, t);
    }

    /// Materialise an observer value binding (`value`/`old`/`new`) as a struct
    /// value over the component's raw bytes (M1.0.2 E3). Mirrors the `@on_event`
    /// payload binding: one `StructField` per declared field that is referenced
    /// in the source (so its name is interned), read via `readBytesAsValue`.
    fn observerValueStruct(self: *Interpreter, world: *World, cid: ComponentId, bytes_ptr: *const anyopaque) !Value {
        const size = world.registry.componentSize(cid);
        const base: [*]const u8 = @ptrCast(bytes_ptr);
        const slice = base[0..size];
        const type_name_id: StringId = self.ast.strings.find(world.registry.componentName(cid)) orelse 0;
        const handle = try self.structs.newStruct(self.gpa, type_name_id);
        for (world.registry.componentFields(cid)) |f| {
            const fname_id = self.ast.strings.find(f.name) orelse continue;
            const fbytes = slice[f.offset .. f.offset + @as(usize, @intCast(f.kind.sizeBytes()))];
            const v = bridge_mod.readBytesAsValue(f.kind, fbytes);
            try self.structs.list.items[handle].fields.append(self.gpa, .{ .name = fname_id, .value = v });
        }
        return Value{ .struct_ref = handle };
    }

    /// Number of compiled rules in the program (M1.0.0 observable — pairs with
    /// `ruleName` / `ruleMatchedEntities` to log a per-rule matched-entity
    /// breakdown).
    pub fn ruleCount(self: *const Interpreter) usize {
        return self.rule_descs.len;
    }

    /// Source name of rule `idx` (M1.0.0 observable).
    pub fn ruleName(self: *const Interpreter, idx: usize) []const u8 {
        return self.ast.strings.slice(self.rule_descs[idx].name);
    }

    /// Entities matched by rule `idx` in the most recent tick it ran (M1.0.0
    /// observable). `RuntimeReport.entities_iterated` is the program-wide sum;
    /// this is the per-rule breakdown. Interp-only / informational.
    pub fn ruleMatchedEntities(self: *const Interpreter, idx: usize) u64 {
        return self.rule_descs[idx].matched_entities;
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
        // present (M0.8 E3 sub-slice B). `await wait(d)` resolves against it.
        if (self.has_async) self.async_tick += 1;
        // Events have a per-tick lifetime (`Lifetime.tick`): clear the previous
        // tick's queue before running this tick's rules (M0.8 E3).
        self.events.clear(self.gpa);
        for (self.rule_descs, 0..) |*rd, i| {
            // Observer rules (M1.0.2 E3) never run in the per-tick dispatch:
            // they fire at the Tier-0 command-buffer flush via the
            // `ObserverRegistry` (registered in `bindToWorld`), not here.
            if (rd.observer_kind != null) continue;
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
            try self.runRule(world, rd, report);
            // Record the tick at which this rule ran — the baseline its next
            // `changed` filter compares against (M0.8 E3). `runRule` was passed
            // the pre-update value, so the filter saw the correct baseline.
            if (self.has_changed) rd.last_run_tick = world.current_tick;
        }
        // Apply deferred tag mutations at the tick boundary — after every rule
        // has run, never mid-archetype-walk (M0.8 E3, `etch-grammar.md` §4.4).
        try self.flushPendingTags(world);
        // Apply deferred extension activate/deactivate at the same boundary
        // (M1.0.9 B1) — same never-mid-walk discipline.
        try self.flushPendingExtensions(world);
        // Apply deferred structural mutations (spawn/despawn/add/remove) last, so
        // any extension hook's structural change (enqueued just above) drains in
        // the same boundary, with observers firing per op (M1.0.10 E3).
        try self.flushStructural(world);
    }

    fn runRule(self: *Interpreter, world: *World, rd: *RuleDesc, report: *RuntimeReport) !void {
        // `resource T { expression }` gates (M0.8 E4 — §6, item-4 ruling):
        // checked once per rule evaluation, alongside the resource deps the
        // filters ride with (the codegen emits the same rule-top gate).
        if (rd.resource_expr_filters.len > 0 and !(try self.resourceExprFiltersPass(world, rd.*))) return;
        // `@on_event(T)` observer (M0.8 E3): fire once per event of type `T` in
        // the per-tick `EventStore`, in emit order, with the implicit `event`
        // binding injected. Takes precedence over entity/global dispatch.
        if (rd.event_type) |event_type| {
            try self.runObserver(world, rd.*, event_type, report);
            return;
        }
        if (!rd.is_entity_bound) {
            // Bare expression conditions on a GLOBAL rule (M0.8 E4): evaluated
            // once per tick, rule params in scope (no entity binding).
            if (rd.expr_conds.len > 0 and !(try self.exprGuardsPass(world, rd.*, null, null, null, 0))) return;
            try self.execBody(world, rd.*, null, null, report);
            report.rules_matched += 1;
            return;
        }
        var rule_matched = false;
        // Per-rule matched-entity count for this tick (M1.0.0 observable) — the
        // per-rule breakdown of `report.entities_iterated`. Reset before the
        // walk; incremented per matched entity in `iterateArchetype`.
        rd.matched_entities = 0;
        // M1.0.0 — entity selection is driven by the rule's DNF of dynamic
        // queries (one `DynamicQuery` per conjunctive term). Each query lazily
        // re-scans the `world.archetypes` tail through the SAME shared matcher
        // + rescan as the comptime `Query` (`query.archetypeMatches` +
        // `query.rescanNewArchetypes`, option-β `engine-ecs-internals.md §4`):
        // O(0) in the steady state, O(new archetypes) after a spawn into a new
        // shape. Sound because an archetype's component set is immutable after
        // creation (add/remove transitions the entity to a DIFFERENT archetype)
        // and `world.archetypes` is append-only with stable order — a cached
        // match never goes stale. A single term iterates its matches directly
        // (ascending archetype-creation order, preserving the historical
        // direct-walk order → interp↔codegen parity); `or` unions the terms.
        try self.iterateSelection(world, rd, &rule_matched, report);
        if (rule_matched) report.rules_matched += 1;
    }

    /// Iterate the archetypes a rule's `when` clause selects, dispatching the
    /// body on every matching entity (M1.0.0). The selection is the union of
    /// the rule's DNF terms (`rd.selection`, one `DynamicQuery` each):
    ///
    /// - 0 terms — a non-entity-bound rule reaches here only by mistake (the
    ///   global path returns earlier), or an entity-bound rule whose every
    ///   term is unsatisfiable: nothing to iterate.
    /// - 1 term — the common case (a pure-`and` `when`): iterate the term's
    ///   matches directly, no merge.
    /// - N terms (`or`) — rescan each term, then k-way merge their matching
    ///   lists by ascending `archetype_id`, dispatching each archetype once
    ///   (an archetype satisfying several disjuncts must not run the body
    ///   twice). The lists are ascending because every scan appends in
    ///   `world.archetypes` creation order.
    ///
    /// `query.maybeRescan` returns the archetypes it scanned this call (0 in
    /// the steady state); summing them into `predicate_archetype_evals` keeps
    /// the tail-only-rescan observable the cache test asserts.
    fn iterateSelection(self: *Interpreter, world: *World, rd: *RuleDesc, rule_matched: *bool, report: *RuntimeReport) !void {
        const sel = rd.selection;
        if (sel.len == 0) return;
        if (sel.len == 1) {
            report.predicate_archetype_evals += sel[0].maybeRescan();
            for (sel[0].matching.items) |arch| {
                try self.iterateArchetype(world, rd, arch, rule_matched, report);
            }
            return;
        }
        for (sel) |*q| report.predicate_archetype_evals += q.maybeRescan();
        try self.iterateUnion(world, rd, rule_matched, report);
    }

    /// k-way merge of a multi-term (`or`) selection's matching lists, ascending
    /// by `archetype_id`, each archetype dispatched exactly once (M1.0.0). Uses
    /// the reusable `merge_cursors` buffer — one cursor per term — so the union
    /// path allocates at most once over the interpreter's lifetime.
    fn iterateUnion(self: *Interpreter, world: *World, rd: *RuleDesc, rule_matched: *bool, report: *RuntimeReport) !void {
        const sel = rd.selection;
        self.merge_cursors.clearRetainingCapacity();
        try self.merge_cursors.appendNTimes(self.gpa, 0, sel.len);
        const cursors = self.merge_cursors.items;
        while (true) {
            // Smallest archetype_id at the head of any non-exhausted term.
            var min_id: ?u32 = null;
            for (sel, 0..) |q, qi| {
                if (cursors[qi] < q.matching.items.len) {
                    const aid = q.matching.items[cursors[qi]].archetype_id;
                    if (min_id == null or aid < min_id.?) min_id = aid;
                }
            }
            const target = min_id orelse break;
            // Advance every cursor sitting on `target` (dedup), keep one ref.
            var arch: *DynamicArchetype = undefined;
            for (sel, 0..) |q, qi| {
                if (cursors[qi] < q.matching.items.len and
                    q.matching.items[cursors[qi]].archetype_id == target)
                {
                    arch = q.matching.items[cursors[qi]];
                    cursors[qi] += 1;
                }
            }
            try self.iterateArchetype(world, rd, arch, rule_matched, report);
        }
    }

    /// Walk one archetype's chunks/slots for an entity-bound rule — the
    /// per-archetype body of the cached-matching-set selection (M1.0.0).
    fn iterateArchetype(self: *Interpreter, world: *World, rd: *RuleDesc, arch: *DynamicArchetype, rule_matched: *bool, report: *RuntimeReport) !void {
        for (arch.chunks.items) |chunk| {
            const ids = arch.entityIdsConst(chunk);
            const count = chunk.header().entity_count;
            var slot: u32 = 0;
            while (slot < count) : (slot += 1) {
                if (!allFiltersPass(arch, chunk, rd.field_filters, slot)) continue;
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
                // §6 general filters + bare conditions (M0.8 E4): evaluated
                // LAST in the per-entity guard order (fixed, mirrored by the
                // codegen guards).
                if ((rd.expr_filters.len > 0 or rd.expr_conds.len > 0) and
                    !(try self.exprGuardsPass(world, rd.*, entity_id, arch, chunk, slot))) continue;
                report.entities_iterated += 1;
                rd.matched_entities += 1;
                rule_matched.* = true;
                try self.execBody(world, rd.*, entity_id, null, report);
            }
        }
    }

    /// Evaluate the `resource T { expression }` gates of a rule (M0.8 E4):
    /// each filter binds its resource's fields by name and must evaluate to
    /// `true`. Rule-arena stores touched by the evaluation are reset before
    /// returning (guard values never outlive the guard).
    fn resourceExprFiltersPass(self: *Interpreter, world: *World, rd: RuleDesc) !bool {
        var pass = true;
        var locals: Locals = .{};
        defer locals.deinit(self.gpa);
        for (rd.resource_expr_filters) |rf| {
            locals.map.clearRetainingCapacity();
            const bytes = world.resources.getResource(rf.resource_id) orelse {
                pass = false;
                break;
            };
            for (rf.fields) |bf| {
                const v = bridge_mod.readBytesAsValue(bf.kind, bytes[bf.offset .. bf.offset + @as(u16, @intCast(bf.kind.sizeBytes()))]);
                try locals.put(self.gpa, bf.name, v, false);
            }
            if (!(try self.evalGuardExpr(world, &locals, rf.expr))) {
                pass = false;
                break;
            }
        }
        self.resetGuardStores();
        return pass;
    }

    /// Evaluate a rule's per-entity §6 guards (M0.8 E4): the general
    /// `has T { expression }` filters (fields-only scope) then the bare
    /// expression conditions (rule params in scope; `entity_id` bound for an
    /// entity-bound rule, absent for a global one). Flat-AND; fixed order.
    fn exprGuardsPass(self: *Interpreter, world: *World, rd: RuleDesc, entity_id: ?EntityId, arch: ?*DynamicArchetype, chunk: ?*Chunk, slot: u32) !bool {
        var pass = true;
        var locals: Locals = .{};
        defer locals.deinit(self.gpa);
        for (rd.expr_filters) |ef| {
            locals.map.clearRetainingCapacity();
            const a = arch.?;
            const col = a.componentIndex(ef.component_id) orelse {
                pass = false;
                break;
            };
            const slot_bytes = a.componentSlot(chunk.?, col, slot);
            for (ef.fields) |bf| {
                const v = bridge_mod.readBytesAsValue(bf.kind, slot_bytes[bf.offset .. bf.offset + @as(u16, @intCast(bf.kind.sizeBytes()))]);
                try locals.put(self.gpa, bf.name, v, false);
            }
            if (!(try self.evalGuardExpr(world, &locals, ef.expr))) {
                pass = false;
                break;
            }
        }
        if (pass) {
            const rule = self.ast.rule_decls.items[rd.rule_idx];
            for (rd.expr_conds) |expr| {
                locals.map.clearRetainingCapacity();
                try bindParams(self.gpa, self.ast, rule, entity_id, &locals);
                if (!(try self.evalGuardExpr(world, &locals, expr))) {
                    pass = false;
                    break;
                }
            }
        }
        self.resetGuardStores();
        return pass;
    }

    /// Evaluate one guard expression to a bool. The resolver guarantees the
    /// bool type; a runtime failure inside a guard (defensive) reads as
    /// no-match with the pending error dropped — guards are read-only.
    fn evalGuardExpr(self: *Interpreter, world: *World, locals: *Locals, expr: NodeId) error{OutOfMemory}!bool {
        const v = self.evalExpr(world, locals, expr) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RuntimeFailure => {
                self.pending_error = null;
                return false;
            },
        };
        return v == .bool_ and v.bool_;
    }

    /// Reset the rule-arena stores after a guard evaluation (M0.8 E4): guard
    /// expressions may allocate (strings, collections); nothing they create
    /// outlives the guard verdict, and the body starts from a clean arena
    /// (its own boundary resets are unchanged).
    fn resetGuardStores(self: *Interpreter) void {
        self.collections.reset(self.gpa);
        self.closures.reset(self.gpa);
        self.structs.reset(self.gpa);
        self.optionals.clearRetainingCapacity();
        self.resetRunStrings();
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

    /// Create a task record in the pool (M1.0.12 E1). Heap-allocated so live
    /// `*AsyncTask` pointers survive pool growth (children are created
    /// mid-drive); monotonic — the returned index is a stable task identity.
    fn newTask(self: *Interpreter, origin_rule: u32, parent: ?u32) !u32 {
        const task = try self.gpa.create(AsyncTask);
        errdefer self.gpa.destroy(task);
        task.* = .{ .origin_rule = origin_rule, .parent = parent };
        try self.async_tasks.append(self.gpa, task);
        return @intCast(self.async_tasks.items.len - 1);
    }

    /// Cancel a task (M1.0.12 E1): free its frames + locals — the same teardown
    /// as `finishTaskDone` — and park it `.canceled` so it is never scheduled
    /// again. Idempotent: a `.done`/`.canceled` task is left untouched (§9.8
    /// amended, `h.cancel()`). NON-transitive (Phase 1, `etch-bytecode.md §9.5`):
    /// tasks the canceled task had itself launched are independent pool entries
    /// and keep running.
    fn cancelTask(self: *Interpreter, ti: u32) void {
        const task = self.async_tasks.items[ti];
        if (task.state != .suspended) return;
        self.clearFrames(task);
        task.frames.clearAndFree(self.gpa);
        task.pending_bind = .discard;
        task.locals.deinit(self.gpa);
        task.locals = .{};
        task.state = .canceled;
    }

    /// Drive an `async rule`'s tasks at its position in the rule order. Spawns
    /// the rule-root task on first reach; then (M1.0.12 E1, drive-by-origin)
    /// drives, in task-CREATION order, every ready task in the pool whose
    /// `origin_rule` is this rule — not just the root. This preserves the M0.8
    /// producer-before-consumer ruling: events emitted by child tasks interleave
    /// at the origin rule's position, deterministically, including for detached
    /// tasks that outlive a parent iteration. The scan is index-based so a child
    /// created mid-drive (appended at the tail) is picked up by the SAME pass —
    /// a child that never suspends completes within the pass. A parent is always
    /// created before its children (lower index), so a suspended `race` parent
    /// resumes — and cancels its losers — before any loser could resume.
    ///
    /// One root task per async rule (the §9.2 parameterless, non-entity-bound
    /// shape); an entity-bound async rule (one task per matching entity) is
    /// deferred and fails loud (counted once, then parked `.done`).
    fn runAsyncRule(self: *Interpreter, world: *World, idx: usize, report: *RuntimeReport) !void {
        const rd = self.rule_descs[idx];
        if (self.rule_tasks[idx] == null) {
            // First reach → spawn the rule-root task in the pool.
            const rule = self.ast.rule_decls.items[rd.rule_idx];
            if (rule.params_len > 0 or rd.is_entity_bound) {
                report.runtime_errors += 1;
                const ti = try self.newTask(@intCast(idx), null);
                self.async_tasks.items[ti].state = .done;
                self.rule_tasks[idx] = ti;
                return;
            }
            const ti = try self.newTask(@intCast(idx), null);
            self.rule_tasks[idx] = ti;
            // The initial frame is the rule body as a linear run. The fresh
            // task's default wake (`wait_until = 0`) fires immediately, so the
            // drive-by-origin pass below runs it this tick.
            try self.async_tasks.items[ti].frames.append(self.gpa, .{ .run = .{
                .block_start = rule.body_start,
                .block_len = rule.body_len,
            } });
        }
        var drove_any = false;
        var ti: usize = 0;
        while (ti < self.async_tasks.items.len) : (ti += 1) {
            const task = self.async_tasks.items[ti];
            if (task.origin_rule != idx) continue;
            if (task.state != .suspended) continue;
            if (!self.asyncWakeFired(task.wake)) continue;
            drove_any = true;
            try self.driveTask(world, task, report);
        }
        if (drove_any) report.rules_matched += 1;
    }

    /// The active scope for the top frame (M1.0.11 E2): the nearest enclosing
    /// `async fn` call frame's own scope, or the task's root locals if none. The
    /// `&task.locals` fallback is stable across pool growth (M1.0.12 E1): the
    /// task is a heap record, so sibling tasks created MID-DRIVE never move it.
    fn currentScope(task: *AsyncTask) *Locals {
        var i = task.frames.items.len;
        while (i > 0) {
            i -= 1;
            switch (task.frames.items[i]) {
                .call => |*cf| return cf.scope,
                else => {},
            }
        }
        return &task.locals;
    }

    /// Free a frame's owned resources (M1.0.11 E2): only a `call` frame owns heap
    /// (its `async fn` scope). Called for every frame removal.
    fn deinitFrame(self: *Interpreter, frame: *AsyncFrame) void {
        switch (frame.*) {
            .call => |cf| {
                cf.scope.deinit(self.gpa);
                self.gpa.destroy(cf.scope);
            },
            else => {},
        }
    }

    /// Pop the top frame, freeing its owned resources (M1.0.11 E2).
    fn popFrame(self: *Interpreter, task: *AsyncTask) void {
        if (task.frames.pop()) |f| {
            var fr = f;
            self.deinitFrame(&fr);
        }
    }

    /// Pop every frame, freeing owned resources (M1.0.11 E2) — the task-teardown
    /// path (completion / fail-loud), replacing a bare `clearRetainingCapacity`.
    fn clearFrames(self: *Interpreter, task: *AsyncTask) void {
        while (task.frames.items.len > 0) self.popFrame(task);
    }

    /// Deliver a resolved `await` value to its site (M1.0.11 E2). `return_` is
    /// NOT handled here (it routes through the returning-unwind); this covers the
    /// value-delivering targets.
    fn deliverAwaitValue(self: *Interpreter, task: *AsyncTask, ret: RetTarget, v: Value) StmtError!void {
        switch (ret) {
            .discard, .return_ => {},
            .bind => |b| try currentScope(task).put(self.gpa, b.name, v, b.is_mut),
            .assign_local => |name| {
                const ptr = currentScope(task).getPtr(name) orelse return error.RuntimeFailure;
                ptr.* = v;
            },
        }
    }

    /// Classify a statement as a statement-head `await` and its delivery target
    /// (M1.0.11 E2): a bare expr-stmt (discard), a `let x = await …` (bind), a
    /// simple `x = await …` (assign a local), or a `return await …`. A destructuring
    /// `let`, a compound/complex-lvalue assignment, or any non-`await` RHS returns
    /// `null` (handled elsewhere / by the sync executor). Sub-expression `await`
    /// is not statement-head — it reaches `evalExpr` and fails loud (E0904, E3).
    const AwaitSite = struct { await_id: NodeId, ret: RetTarget };
    fn stmtHeadAwait(self: *Interpreter, stmt: NodeId) ?AwaitSite {
        switch (self.ast.stmtKind(stmt)) {
            .expr_stmt => {
                const e: NodeId = @bitCast(self.ast.stmtData(stmt));
                if (self.ast.exprKind(e) == .await_expr) return .{ .await_id = e, .ret = .discard };
            },
            .let_stmt => {
                const let = self.ast.let_stmts.items[self.ast.stmtData(stmt)];
                if (let.name != 0 and self.ast.exprKind(let.value) == .await_expr)
                    return .{ .await_id = let.value, .ret = .{ .bind = .{ .name = let.name, .is_mut = let.is_mut } } };
            },
            .assign_stmt => {
                const a = self.ast.assign_stmts.items[self.ast.stmtData(stmt)];
                if (a.op == .assign and self.ast.exprKind(a.value) == .await_expr and self.ast.exprKind(a.target) == .ident)
                    return .{ .await_id = a.value, .ret = .{ .assign_local = self.ast.exprData(a.target) } };
            },
            .return_stmt => {
                const operand: NodeId = @bitCast(self.ast.stmtData(stmt));
                if (!operand.isNone() and self.ast.exprKind(operand) == .await_expr)
                    return .{ .await_id = operand, .ret = .return_ };
            },
            else => {},
        }
        return null;
    }

    /// Evaluate a call's arguments in the caller's scope and bind them (parameter
    /// order, named-arg aware) into `dest` (M1.0.11 E2). Shared by the fn and
    /// method call-frame setup; mirrors the arg handling of `callFn`/`callMethod`.
    fn bindAsyncParams(self: *Interpreter, world: *World, caller: *Locals, dest: *Locals, fndecl: ast_mod.FnDecl, args_start: u32, args_len: u32, names_start: u32) StmtError!void {
        if (fndecl.params_len != args_len) return error.RuntimeFailure;
        if (args_len > max_call_args) return error.RuntimeFailure;
        var values: [max_call_args]Value = undefined;
        var j: u32 = 0;
        while (j < args_len) : (j += 1) {
            const arg: NodeId = @bitCast(self.ast.extra.items[args_start + j]);
            values[j] = try self.evalExpr(world, caller, arg);
        }
        var i: u32 = 0;
        while (i < fndecl.params_len) : (i += 1) {
            const p = self.ast.fn_params.items[fndecl.params_start + i];
            const idx = self.ast.callArgIndexForParam(args_start, args_len, names_start, i, p.name) orelse return error.RuntimeFailure;
            try dest.put(self.gpa, p.name, values[idx], false);
        }
    }

    /// Begin a direct `await f()` on an `async fn` / `async method` (M1.0.11 E2):
    /// resolve the callee, evaluate its args in the caller's scope, create a fresh
    /// heap-boxed scope (params + `self`), advance the caller cursor PAST the await,
    /// and push a `call` frame carrying `ret` (where `f`'s return value lands). `f`
    /// then runs as frames on this task; its own `await` suspends the whole task.
    /// A direct call to a SYNC fn/method, or an unresolved callee, fails loud.
    fn beginAsyncCall(self: *Interpreter, world: *World, task: *AsyncTask, scope: *Locals, cursor: *u32, call_expr: NodeId, ret: RetTarget) StmtError!StepAction {
        const new_scope = try self.gpa.create(Locals);
        new_scope.* = .{};
        errdefer {
            new_scope.deinit(self.gpa);
            self.gpa.destroy(new_scope);
        }
        var fndecl: ast_mod.FnDecl = undefined;
        switch (self.ast.exprKind(call_expr)) {
            .fn_call => {
                const call = self.ast.call_exprs.items[self.ast.exprData(call_expr)];
                if (self.ast.exprKind(call.callee) != .ident) return error.RuntimeFailure;
                const callee_name = self.ast.exprData(call.callee);
                if (scope.get(callee_name) != null) return error.RuntimeFailure; // a local (closure), not an async fn
                fndecl = self.fns.get(callee_name) orelse return error.RuntimeFailure;
                if (!fndecl.is_async) return error.RuntimeFailure;
                try self.bindAsyncParams(world, scope, new_scope, fndecl, call.args_start, call.args_len, call.names_start);
            },
            .method_call => {
                const mc = self.ast.method_calls.items[self.ast.exprData(call_expr)];
                var self_value: ?Value = null;
                if (self.ast.exprKind(mc.receiver) == .path) {
                    // `Type.assoc()` — associated fn (no `self`).
                    const type_name = self.ast.exprData(mc.receiver);
                    fndecl = self.methods.get(methodKey(type_name, mc.method_name)) orelse return error.RuntimeFailure;
                } else {
                    const recv = try self.evalExpr(world, scope, mc.receiver);
                    self_value = recv;
                    switch (recv) {
                        .struct_ref => |h| {
                            const tn = self.structs.list.items[h].type_name;
                            fndecl = self.methods.get(methodKey(tn, mc.method_name)) orelse
                                self.trait_methods.get(methodKey(tn, mc.method_name)) orelse
                                return error.RuntimeFailure;
                        },
                        .entity_id => {
                            const en = self.ast.strings.find("Entity") orelse return error.RuntimeFailure;
                            fndecl = self.trait_methods.get(methodKey(en, mc.method_name)) orelse return error.RuntimeFailure;
                        },
                        else => return error.RuntimeFailure,
                    }
                }
                if (!fndecl.is_async) return error.RuntimeFailure;
                if (self_value) |sv| {
                    if (self.ast.strings.find("self")) |sid| try new_scope.put(self.gpa, sid, sv, fndecl.self_kind == .by_mut);
                }
                try self.bindAsyncParams(world, scope, new_scope, fndecl, mc.args_start, mc.args_len, mc.names_start);
            },
            else => return error.RuntimeFailure,
        }
        cursor.* += 1; // advance the caller PAST the await before descending into `f`
        try task.frames.append(self.gpa, .{ .call = .{
            .block_start = fndecl.body_start,
            .block_len = fndecl.body_len,
            .scope = new_scope,
            .value_expr = if (fndecl.value.isNone()) null else fndecl.value,
            .ret = ret,
        } });
        return .pushed;
    }

    /// Drive `task` over its resume frame-stack until it suspends at the next
    /// `await` or runs to completion (M1.0.11 E1). Resets the per-body signal
    /// state, delivers a pending value-await binding on resume (E2), runs
    /// `driveLoop`, and routes a fail-loud into `finishTaskFailed`.
    fn driveTask(self: *Interpreter, world: *World, task: *AsyncTask, report: *RuntimeReport) !void {
        self.control = .none;
        self.control_label = 0;
        self.thrown = false;
        self.returning = false;
        self.pending_error = null;
        // A handle-await resume (M1.0.12 E5, §9.8 amended) first checks its
        // target: canceled WHILE awaited → fail-loud runtime error (no silent
        // unit); done → its parked result (unit in Phase 1) is the value
        // delivered at the await site below.
        var resume_value: Value = .{ .unit = {} };
        switch (task.wake) {
            .task_done => |ti| {
                const target = self.async_tasks.items[ti];
                if (target.state == .canceled) {
                    task.pending_bind = .discard;
                    self.finishTaskFailed(task, report);
                    return;
                }
                resume_value = target.result;
            },
            else => {},
        }
        // A wake-condition `await` used in a value position (`let x = await wait(…)`)
        // resolves to `unit` — or, for a handle-await, to the parked result;
        // deliver it into the resuming scope now (M1.0.11 E2). A `return await
        // <wake-target>` re-raises the RETURN at resume instead (M1.0.12 E5
        // fix-as-you-go: `deliverAwaitValue` no-ops on `.return_`, so M1.0.11
        // silently dropped the return and fell through past the statement).
        if (@as(std.meta.Tag(RetTarget), task.pending_bind) == .return_) {
            task.pending_bind = .discard;
            self.returning = true;
            self.return_value = resume_value;
            const cont = self.unwindControl(task) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RuntimeFailure => {
                    self.finishTaskFailed(task, report);
                    return;
                },
            };
            if (!cont) {
                self.finishTaskDone(task, report);
                return;
            }
        } else if (@as(std.meta.Tag(RetTarget), task.pending_bind) != .discard) {
            self.deliverAwaitValue(task, task.pending_bind, resume_value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RuntimeFailure => {
                    task.pending_bind = .discard;
                    self.finishTaskFailed(task, report);
                    return;
                },
            };
            task.pending_bind = .discard;
        }
        // A parent suspended on a race/sync child set resolves the construct
        // FIRST (M1.0.12 E4): winner selection + loser cancellation, and — on
        // a returning winner — the §9.5 winner-return re-raise at the race
        // site: the parent unwinds as if the race statement itself returned
        // the value (to the enclosing `async fn`'s await site via its call
        // frame, or ending the task at rule level).
        if (self.resolveChildWake(task)) |winner_return| {
            self.returning = true;
            self.return_value = winner_return;
            const cont = self.unwindControl(task) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RuntimeFailure => {
                    self.finishTaskFailed(task, report);
                    return;
                },
            };
            if (!cont) {
                self.finishTaskDone(task, report);
                return;
            }
        }
        const outcome = self.driveLoop(world, task) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RuntimeFailure => {
                self.finishTaskFailed(task, report);
                return;
            },
        };
        switch (outcome) {
            .suspended => task.state = .suspended,
            .completed => self.finishTaskDone(task, report),
        }
    }

    /// The iterative frame-stack machine (M1.0.11 E1, `etch-reference-part1.md
    /// §9.12`). Processes the innermost frame's next statement; a statement-head
    /// `await` suspends the whole task (stack retained, no re-run on resume); a
    /// nested `if`/`match`/`loop`/`while`/`block` pushes a child frame; everything
    /// else runs through the sync `execStmt`. Returns `.suspended` (stack persists
    /// for the next tick) or `.completed` (stack drained / a `return` / an
    /// uncaught `throw` / a top-level `break`).
    fn driveLoop(self: *Interpreter, world: *World, task: *AsyncTask) StmtError!AsyncOutcome {
        drive: while (task.frames.items.len > 0) {
            const ti = task.frames.items.len - 1;
            // The active scope is the nearest enclosing `async fn` call frame's
            // own scope (M1.0.11 E2), else the task root — recomputed each pass so
            // a pushed/popped call frame flips it for the next statement.
            const scope = currentScope(task);
            switch (task.frames.items[ti]) {
                .run => {
                    const rf = &task.frames.items[ti].run;
                    if (rf.cursor >= rf.block_len) {
                        const val = rf.value_expr;
                        self.popFrame(task);
                        // A block's trailing value runs for effect (rare at stmt
                        // position); it cannot suspend (an `await` there is a
                        // sub-expression, rejected E0904 / fails loud).
                        if (val) |v| _ = try self.evalExpr(world, scope, v);
                        continue :drive;
                    }
                    const stmt: NodeId = @bitCast(self.ast.extra.items[rf.block_start + rf.cursor]);
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].run.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
                .loop_ => {
                    const lf = &task.frames.items[ti].loop_;
                    if (lf.cursor >= lf.block_len) {
                        task.frames.items[ti].loop_.cursor = 0; // `loop` repeats
                        continue :drive;
                    }
                    const stmt: NodeId = @bitCast(self.ast.extra.items[lf.block_start + lf.cursor]);
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].loop_.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
                .while_ => {
                    const wid = task.frames.items[ti].while_.while_id;
                    const wh = self.ast.while_stmts.items[self.ast.stmtData(wid)];
                    if (!task.frames.items[ti].while_.in_iter) {
                        if (!(try self.whileCondEnter(world, scope, wid))) {
                            self.popFrame(task); // condition false → `while` ends
                            continue :drive;
                        }
                        task.frames.items[ti].while_.in_iter = true;
                        task.frames.items[ti].while_.cursor = 0;
                        continue :drive;
                    }
                    if (task.frames.items[ti].while_.cursor >= wh.body_len) {
                        task.frames.items[ti].while_.in_iter = false; // re-check cond
                        continue :drive;
                    }
                    const stmt: NodeId = @bitCast(self.ast.extra.items[wh.body_start + task.frames.items[ti].while_.cursor]);
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].while_.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
                .for_ => {
                    const f = self.ast.for_stmts.items[self.ast.stmtData(task.frames.items[ti].for_.for_id)];
                    if (!task.frames.items[ti].for_.in_iter) {
                        if (!(try self.forAdvance(&task.frames.items[ti].for_, scope))) {
                            self.popFrame(task); // iterator exhausted → `for` ends
                            continue :drive;
                        }
                        task.frames.items[ti].for_.in_iter = true;
                        task.frames.items[ti].for_.cursor = 0;
                        continue :drive;
                    }
                    if (task.frames.items[ti].for_.cursor >= f.body_len) {
                        task.frames.items[ti].for_.in_iter = false; // advance to next element
                        continue :drive;
                    }
                    const stmt: NodeId = @bitCast(self.ast.extra.items[f.body_start + task.frames.items[ti].for_.cursor]);
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].for_.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
                .try_ => {
                    const tf = &task.frames.items[ti].try_;
                    const start = if (tf.in_catch) tf.catch_start else tf.try_start;
                    const len = if (tf.in_catch) tf.catch_len else tf.try_len;
                    if (tf.cursor >= len) {
                        self.popFrame(task); // `try` (or `catch`) body done
                        continue :drive;
                    }
                    const stmt: NodeId = @bitCast(self.ast.extra.items[start + tf.cursor]);
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].try_.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
                .single => {
                    // Length-1 run (M1.0.12 E4) — a race/sync child whose
                    // branch is a single non-block statement.
                    if (task.frames.items[ti].single.cursor >= 1) {
                        self.popFrame(task);
                        continue :drive;
                    }
                    const stmt = task.frames.items[ti].single.stmt;
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].single.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
                .call => {
                    const cf = &task.frames.items[ti].call;
                    if (cf.cursor >= cf.block_len) {
                        // `f` fell off the end → implicit return (trailing block
                        // value, or unit). `scope` is f's own scope (the call frame
                        // is the top). Pop f (frees its scope), then resolve at the
                        // caller's await site.
                        const val = cf.value_expr;
                        const ret = cf.ret;
                        var rv: Value = .{ .unit = {} };
                        if (val) |v| rv = try self.evalExpr(world, scope, v);
                        self.popFrame(task);
                        switch (ret) {
                            .return_ => {
                                self.return_value = rv;
                                self.returning = true;
                                if (try self.unwindControl(task)) continue :drive else return .completed;
                            },
                            else => {
                                try self.deliverAwaitValue(task, ret, rv);
                                continue :drive;
                            },
                        }
                    }
                    const stmt: NodeId = @bitCast(self.ast.extra.items[cf.block_start + cf.cursor]);
                    switch (try self.stepBodyStmt(world, task, scope, &task.frames.items[ti].call.cursor, stmt)) {
                        .suspended => return .suspended,
                        .advanced, .pushed => continue :drive,
                        .signaled => if (try self.unwindControl(task)) continue :drive else return .completed,
                    }
                },
            }
        }
        return .completed;
    }

    /// Step one statement of the current frame's body (M1.0.11 E1). `cursor`
    /// points at the active frame's statement cursor; this advances it (for a
    /// plain run / a pushed child / a resumed-after `await`) BEFORE any frame push
    /// (a push reallocates `task.frames`, so the pointer is used first). Returns
    /// the action for `driveLoop` to route.
    fn stepBodyStmt(self: *Interpreter, world: *World, task: *AsyncTask, scope: *Locals, cursor: *u32, stmt: NodeId) StmtError!StepAction {
        // (1) statement-head `await` (M1.0.11 E1/E2) — in an expr-stmt (discard),
        // a `let` initializer (bind), an assignment RHS (assign), or a `return`
        // operand. A `future` (`await f()`) inlines `f`'s body as a call frame
        // (E2); a wake-condition target (`wait` / `global_event`) suspends the
        // task, delivering its (unit) value to the site on resume via `pending_bind`.
        if (self.stmtHeadAwait(stmt)) |site| {
            const aw = self.ast.awaitExpr(site.await_id);
            switch (aw.target_kind) {
                .future => {
                    // A direct call inlines the callee's body (M1.0.11 E2);
                    // any other expression is the HANDLE-AWAIT form (M1.0.12
                    // E5, §9.8): evaluate it to a `TaskHandle` and join.
                    const ak = self.ast.exprKind(aw.arg_expr);
                    if (ak == .fn_call or ak == .method_call) {
                        return try self.beginAsyncCall(world, task, scope, cursor, aw.arg_expr, site.ret);
                    }
                    const hv = try self.evalExpr(world, scope, aw.arg_expr);
                    if (hv != .task_handle) return error.RuntimeFailure;
                    const target = self.async_tasks.items[hv.task_handle];
                    switch (target.state) {
                        // Already done: resume IMMEDIATELY (no suspension),
                        // delivering the parked result (unit in Phase 1). A
                        // `return await h` raises the return signal instead
                        // (`deliverAwaitValue` no-ops on `.return_`).
                        .done => {
                            if (@as(std.meta.Tag(RetTarget), site.ret) == .return_) {
                                self.returning = true;
                                self.return_value = target.result;
                                return .signaled;
                            }
                            try self.deliverAwaitValue(task, site.ret, target.result);
                            cursor.* += 1;
                            return .advanced;
                        },
                        // Awaiting a canceled task is a fail-loud runtime
                        // error — no silent unit (§9.8 amended).
                        .canceled => return error.RuntimeFailure,
                        .suspended => {
                            cursor.* += 1;
                            task.pending_bind = site.ret;
                            task.wake = .{ .task_done = hv.task_handle };
                            return .suspended;
                        },
                    }
                },
                .wait, .global_event => {
                    task.wake = try self.evalAwaitTarget(site.await_id);
                    cursor.* += 1;
                    task.pending_bind = site.ret;
                    return .suspended;
                },
                .wait_unscaled, .entity_event => return error.RuntimeFailure,
            }
        }
        const sk = self.ast.stmtKind(stmt);
        // (1b) `race` / `sync` statement (M1.0.12 E4) → admit branches (guards
        // in the live parent scope), create one child task per admitted branch,
        // and suspend the parent on the child set.
        if (sk == .race_stmt or sk == .sync_stmt) {
            return try self.beginRaceSync(world, task, scope, cursor, stmt, sk == .race_stmt);
        }
        // (1c) `branch { }` / `[let h =] spawn { }` (M1.0.12 E5, §9.7-§9.8) →
        // create a DETACHED child task (snapshot scope, same origin_rule,
        // no parent link) and continue immediately — the parent never waits
        // on it. `spawn` additionally yields a `TaskHandle` (the child's pool
        // index — monotonic pool, no generation), bound in the PARENT scope
        // AFTER the snapshot (the handle does not exist inside the body).
        if (sk == .branch_stmt or sk == .spawn_stmt) {
            const data = self.ast.stmtData(stmt);
            const body: ast_mod.BranchStmt = if (sk == .branch_stmt)
                self.ast.branch_stmts.items[data]
            else blk: {
                const ss = self.ast.spawn_stmts.items[data];
                break :blk .{ .body_start = ss.body_start, .body_len = ss.body_len };
            };
            const ti = try self.newTask(task.origin_rule, null);
            const child = self.async_tasks.items[ti];
            try cloneLocalsInto(self.gpa, scope, &child.locals);
            try child.frames.append(self.gpa, .{ .run = .{
                .block_start = body.body_start,
                .block_len = body.body_len,
            } });
            if (sk == .spawn_stmt) {
                const ss = self.ast.spawn_stmts.items[data];
                if (ss.binding != 0) {
                    try scope.put(self.gpa, ss.binding, .{ .task_handle = ti }, false);
                }
            }
            cursor.* += 1;
            return .advanced;
        }
        // (2a) `while` statement → push a while frame (it re-checks its own cond).
        if (sk == .while_stmt) {
            cursor.* += 1;
            try task.frames.append(self.gpa, .{ .while_ = .{ .while_id = stmt } });
            return .pushed;
        }
        // (2b) `for` statement → evaluate the iterable ONCE (its side effects run
        // now, exactly like the sync `for`) and push a for frame carrying the
        // iterator state (so a body `await` resumes at the same element).
        if (sk == .for_stmt) {
            const f = self.ast.for_stmts.items[self.ast.stmtData(stmt)];
            const iter = try self.evalExpr(world, scope, f.iterable);
            const for_iter: ForIter = switch (iter) {
                .range => |r| .{ .range = .{ .next = r.start, .end = r.end, .inclusive = r.inclusive } },
                .array_ref => |h| .{ .array = .{ .handle = h, .len = self.collections.arrays.items[h].items.len, .idx = 0 } },
                .map_ref => |h| .{ .map = .{ .handle = h, .len = self.collections.maps.items[h].items.len, .idx = 0 } },
                else => return error.RuntimeFailure,
            };
            cursor.* += 1;
            try task.frames.append(self.gpa, .{ .for_ = .{ .for_id = stmt, .iter = for_iter } });
            return .pushed;
        }
        // (2c) `try { } catch e { }` → push a try frame driving the `try` body; a
        // `throw` (even after a suspension inside the body) routes to the `catch`
        // via `unwindControl`, re-establishing the handler across the suspend.
        if (sk == .try_catch_stmt) {
            const tc = self.ast.try_catch_stmts.items[self.ast.stmtData(stmt)];
            cursor.* += 1;
            try task.frames.append(self.gpa, .{ .try_ = .{
                .try_start = tc.try_start,
                .try_len = tc.try_len,
                .catch_start = tc.catch_start,
                .catch_len = tc.catch_len,
                .catch_name = tc.catch_name,
            } });
            return .pushed;
        }
        // (2d) `if` / `match` / `loop` / `block` expression-statements → push a
        // child frame so a body `await` can suspend.
        if (sk == .expr_stmt) {
            const e: NodeId = @bitCast(self.ast.stmtData(stmt));
            switch (self.ast.exprKind(e)) {
                .loop_expr => {
                    const lp = self.ast.loop_exprs.items[self.ast.exprData(e)];
                    cursor.* += 1;
                    try task.frames.append(self.gpa, .{ .loop_ = .{
                        .block_start = lp.body_start,
                        .block_len = lp.body_len,
                        .label = lp.label,
                    } });
                    return .pushed;
                },
                .block_expr => {
                    cursor.* += 1;
                    try self.pushBlockRun(task, e);
                    return .pushed;
                },
                .if_expr => {
                    // Select the branch synchronously (a condition cannot suspend);
                    // push its block as a run frame (or nothing if no branch taken).
                    const branch = try self.asyncIfBranch(world, scope, e);
                    cursor.* += 1;
                    if (branch) |b| try self.pushBlockRun(task, b);
                    return .pushed;
                },
                .match_expr => {
                    // Select the arm synchronously; a block arm becomes a run
                    // frame (so its body can suspend); a bare-expr arm runs for
                    // effect (a sub-expression `await` there fails loud).
                    const body = try self.matchArmBody(world, scope, e);
                    cursor.* += 1;
                    if (self.ast.exprKind(body) == .block_expr) {
                        try self.pushBlockRun(task, body);
                    } else {
                        _ = try self.evalExpr(world, scope, body);
                    }
                    return .pushed;
                },
                else => {},
            }
        }
        // (3) ordinary statement → the shared sync executor.
        try self.execStmt(world, scope, stmt);
        if (self.control != .none or self.thrown or self.returning) return .signaled;
        cursor.* += 1;
        return .advanced;
    }

    /// Enter a `race`/`sync` statement during a drive (M1.0.12 E4, §9.5-§9.6).
    /// Two passes: (1) evaluate every `if cond =>` guard SYNCHRONOUSLY in the
    /// parent's live current scope — guards decide admission, and evaluating
    /// them all before creating any child means a failing guard leaves no
    /// orphan child behind; (2) create one child task per admitted branch —
    /// `origin_rule` inherited (drive-by-origin schedules it at this rule's
    /// position), `parent` linked (lineage only, cancellation is
    /// non-transitive), root locals = a per-branch SNAPSHOT COPY of the
    /// parent's current scope (§9.8 normative: branch writes to inherited
    /// locals are invisible to the parent and to siblings; cross-branch
    /// communication goes through ECS state/events) — then suspend the parent
    /// on the child set (`children_any` for race, `children_all` for sync).
    /// A block branch frames its statement run; any other single statement
    /// frames a length-1 `single` run. ZERO admitted branches → no suspension,
    /// the parent continues immediately (E4). Resolution at the parent's
    /// resume is `resolveChildWake`.
    fn beginRaceSync(self: *Interpreter, world: *World, task: *AsyncTask, scope: *Locals, cursor: *u32, stmt: NodeId, is_race: bool) StmtError!StepAction {
        const data = self.ast.stmtData(stmt);
        const range: ast_mod.RaceStmt = if (is_race)
            self.ast.race_stmts.items[data]
        else blk: {
            const ss = self.ast.sync_stmts.items[data];
            break :blk .{ .branches_start = ss.branches_start, .branches_len = ss.branches_len };
        };
        // Pass 1 — guard admission, all guards before any child creation.
        var admitted_buf: std.ArrayListUnmanaged(u32) = .empty;
        defer admitted_buf.deinit(self.gpa);
        var i: u32 = 0;
        while (i < range.branches_len) : (i += 1) {
            const br = self.ast.concurrency_branches.items[range.branches_start + i];
            if (!br.cond.isNone()) {
                const cond = try self.evalExpr(world, scope, br.cond);
                if (cond != .bool_) return error.RuntimeFailure;
                if (!cond.bool_) continue;
            }
            try admitted_buf.append(self.gpa, range.branches_start + i);
        }
        cursor.* += 1; // the parent resumes AFTER the construct
        if (admitted_buf.items.len == 0) return .advanced;
        // Pass 2 — child creation, in declaration order (= creation order =
        // deterministic drive + winner tie-break order).
        const parent_idx: ?u32 = blk: {
            for (self.async_tasks.items, 0..) |t, pi| {
                if (t == task) break :blk @intCast(pi);
            }
            break :blk null;
        };
        const set_start: u32 = @intCast(self.task_children.items.len);
        for (admitted_buf.items) |bi| {
            const br = self.ast.concurrency_branches.items[bi];
            const ti = try self.newTask(task.origin_rule, parent_idx);
            const child = self.async_tasks.items[ti];
            try cloneLocalsInto(self.gpa, scope, &child.locals);
            var framed = false;
            if (self.ast.stmtKind(br.stmt) == .expr_stmt) {
                const e: NodeId = @bitCast(self.ast.stmtData(br.stmt));
                if (self.ast.exprKind(e) == .block_expr) {
                    try self.pushBlockRun(child, e);
                    framed = true;
                }
            }
            if (!framed) try child.frames.append(self.gpa, .{ .single = .{ .stmt = br.stmt } });
            try self.task_children.append(self.gpa, ti);
        }
        const len: u32 = @intCast(admitted_buf.items.len);
        task.pending_bind = .discard;
        task.wake = if (is_race)
            .{ .children_any = .{ .start = set_start, .len = len } }
        else
            .{ .children_all = .{ .start = set_start, .len = len } };
        return .suspended;
    }

    /// Resolve a parent's child-set wake at resume (M1.0.12 E4), BEFORE any
    /// statement steps. Race (`children_any`): scan the children in
    /// DECLARATION order — the first `.done` is the winner (deterministic
    /// tie-break when several complete in the same tick); cancel every other
    /// non-done child (non-transitive — tasks a loser launched keep running);
    /// return the winner's pending `return` value for re-raising at the race
    /// site (`null` when the winner did not return — or when EVERY branch
    /// failed: no winner, nothing to cancel that is not already terminal, the
    /// parent just resumes after the statement). Sync (`children_all`): the
    /// join is complete by wake construction (no child still `.suspended`;
    /// failed children never block it) — nothing to do. Any other wake: not a
    /// child set — no-op.
    fn resolveChildWake(self: *Interpreter, task: *AsyncTask) ?Value {
        switch (task.wake) {
            .children_any => |r| {
                var winner: ?u32 = null;
                for (self.task_children.items[r.start .. r.start + r.len]) |ci| {
                    if (self.async_tasks.items[ci].state == .done) {
                        winner = ci;
                        break;
                    }
                }
                for (self.task_children.items[r.start .. r.start + r.len]) |ci| {
                    if (winner != null and ci == winner.?) continue;
                    self.cancelTask(ci);
                }
                if (winner) |wi| {
                    const wtask = self.async_tasks.items[wi];
                    if (wtask.returned) return wtask.result;
                }
                return null;
            },
            .children_all => return null,
            else => return null,
        }
    }

    /// Snapshot-copy `src` locals into `dest` (M1.0.12 E4, §9.8 normative): a
    /// child task's root scope is a per-branch COPY of the parent's current
    /// scope, taken at construct entry after guard evaluation. Value-level
    /// copy: rebinding a local inside the branch is invisible outside; a
    /// heap-BACKED value (collection/struct handle) shares its rule-arena
    /// referent — the M0.8 POD-across-suspend caveat family.
    fn cloneLocalsInto(gpa: std.mem.Allocator, src: *const Locals, dest: *Locals) error{OutOfMemory}!void {
        var it = src.map.iterator();
        while (it.next()) |entry| {
            try dest.map.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Push a `block_expr`'s body as a `.run` frame (M1.0.11 E1), carrying its
    /// trailing value expression (evaluated for effect on pop).
    fn pushBlockRun(self: *Interpreter, task: *AsyncTask, block_expr_id: NodeId) StmtError!void {
        const blk = self.ast.block_exprs.items[self.ast.exprData(block_expr_id)];
        try task.frames.append(self.gpa, .{ .run = .{
            .block_start = blk.body_start,
            .block_len = blk.body_len,
            .value_expr = if (blk.value.isNone()) null else blk.value,
        } });
    }

    /// Unwind the frame-stack for a pending control signal (M1.0.11 E1). A
    /// `return` ends the task (`false`, stack cleared — rules have no return
    /// value). A `throw` routes to the nearest enclosing `try` still in its try
    /// phase — binding the caught value and switching that frame to its `catch`
    /// (`true`, keep driving) — or, with no such `try`, ends the task as an
    /// uncaught throw (`false`). A `break`/`continue` pops intervening block
    /// frames to the nearest matching `loop`/`while`/`for` and consumes it there
    /// (`true`); an unmatched signal at the task top ends the task (`false`).
    /// Mirrors the sync `loop_expr` / `handleLoopControl` / `try_catch_stmt`
    /// semantics — and re-establishes a `try`'s handler across a suspension.
    fn unwindControl(self: *Interpreter, task: *AsyncTask) StmtError!bool {
        if (self.returning) {
            // `return v` unwinds to the nearest enclosing `async fn` call frame,
            // which returns `v` to ITS await site (M1.0.11 E2). `return await g()`
            // chains: that call frame's own `ret` is `return_`, so we loop and the
            // enclosing fn returns `v` too. With no enclosing call frame, the
            // `return` is in the rule body — end the task (rules have no value).
            while (true) {
                find: while (task.frames.items.len > 0) {
                    switch (task.frames.items[task.frames.items.len - 1]) {
                        .call => break :find,
                        else => self.popFrame(task),
                    }
                }
                if (task.frames.items.len == 0) {
                    // Task-level `return` (M1.0.12 E4): park it in the husk —
                    // a race parent re-raises the WINNER's return at the race
                    // site (§9.5); unused for any other task (a rule has no
                    // return value; sync/branch/spawn bodies reject `return`,
                    // E0906). Heap-backed values share the rule-arena
                    // POD-across-suspend caveat.
                    task.returned = true;
                    task.result = self.return_value;
                    self.returning = false;
                    self.return_value = .{ .unit = {} };
                    return false;
                }
                const ret = task.frames.items[task.frames.items.len - 1].call.ret;
                const v = self.return_value;
                self.popFrame(task);
                switch (ret) {
                    .return_ => self.return_value = v, // enclosing fn returns `v` too → loop
                    else => {
                        self.returning = false;
                        self.return_value = .{ .unit = {} };
                        try self.deliverAwaitValue(task, ret, v);
                        return true;
                    },
                }
            }
        }
        if (self.thrown) {
            // Route the throw to the nearest `try` in its try phase (a `catch`'s
            // own throw re-propagates past it). Popping intervening loop/run/for/
            // call frames mirrors the sync unwinding of a throw out of nested
            // control flow (a call frame's scope is freed by `popFrame`). If none
            // catches it, the residual `self.thrown` is left set for
            // `finishTaskDone` to surface as an UncaughtThrow.
            while (task.frames.items.len > 0) {
                const ti = task.frames.items.len - 1;
                switch (task.frames.items[ti]) {
                    .try_ => |tfv| {
                        if (!tfv.in_catch) {
                            self.thrown = false;
                            try currentScope(task).put(self.gpa, tfv.catch_name, self.thrown_value, false);
                            task.frames.items[ti].try_.in_catch = true;
                            task.frames.items[ti].try_.cursor = 0;
                            return true;
                        }
                        self.popFrame(task); // throw inside this `catch` → propagate past it
                    },
                    else => self.popFrame(task),
                }
            }
            return false;
        }
        while (task.frames.items.len > 0) {
            const ti = task.frames.items.len - 1;
            switch (task.frames.items[ti]) {
                .run, .call, .try_, .single => {
                    // A block / call / try / single frame is transparent to
                    // `break`/`continue`: abandon it and keep unwinding.
                    self.popFrame(task);
                },
                .loop_ => {
                    const label = task.frames.items[ti].loop_.label;
                    if (self.control_label == 0 or self.control_label == label) {
                        const was_break = self.control == .break_;
                        self.control = .none;
                        self.control_label = 0;
                        if (was_break) {
                            self.popFrame(task); // the loop exits
                        } else {
                            task.frames.items[ti].loop_.cursor = 0; // continue → loop again
                        }
                        return true;
                    }
                    self.popFrame(task); // labeled signal for an outer loop → propagate
                },
                .while_ => {
                    // `while` carries no label → matches only an unlabeled signal.
                    if (self.control_label == 0) {
                        const was_break = self.control == .break_;
                        self.control = .none;
                        if (was_break) {
                            self.popFrame(task);
                        } else {
                            task.frames.items[ti].while_.in_iter = false; // continue → re-check cond
                        }
                        return true;
                    }
                    self.popFrame(task); // labeled → propagate (while has no label)
                },
                .for_ => {
                    // `for` carries no label → matches only an unlabeled signal.
                    if (self.control_label == 0) {
                        const was_break = self.control == .break_;
                        self.control = .none;
                        if (was_break) {
                            self.popFrame(task);
                        } else {
                            task.frames.items[ti].for_.in_iter = false; // continue → next element
                        }
                        return true;
                    }
                    self.popFrame(task); // labeled → propagate (for has no label)
                },
            }
        }
        // No enclosing loop matched: a `break`/`continue` at the task top has
        // nowhere to go — consume it and end the task (mirrors `execBody`).
        self.control = .none;
        self.control_label = 0;
        return false;
    }

    /// Complete a task normally (M1.0.11 E1): surface an uncaught `throw` as a
    /// counted runtime error, clear the residual signal state, free the frames +
    /// retained locals, and park the task — `.done` on a clean completion,
    /// `.canceled` when it ended on an uncaught `throw` (M1.0.12 E4: a FAILED
    /// task terminated without a result — never a race winner, never blocks a
    /// `sync` join, `await`ing it fails loud; §9.8 amended).
    fn finishTaskDone(self: *Interpreter, task: *AsyncTask, report: *RuntimeReport) void {
        var failed = false;
        if (self.thrown) {
            self.thrown = false;
            self.pending_error = .{ .kind = .UncaughtThrow, .span = self.thrown_span };
            self.harvestError(report);
            failed = true;
        }
        self.control = .none;
        self.control_label = 0;
        self.returning = false;
        self.return_value = .{ .unit = {} };
        self.clearFrames(task); // frees any residual call-frame scopes
        task.state = if (failed) .canceled else .done;
        task.frames.clearAndFree(self.gpa);
        task.pending_bind = .discard;
        task.locals.deinit(self.gpa);
        task.locals = .{};
    }

    /// Complete a fail-loud task (M1.0.11 E1): harvest the typed error into the
    /// report and park the task `.canceled` (M1.0.12 E4 — failed, no result;
    /// was `.done` before the child-task distinction became observable),
    /// freeing its frames + retained locals.
    fn finishTaskFailed(self: *Interpreter, task: *AsyncTask, report: *RuntimeReport) void {
        self.harvestError(report);
        self.control = .none;
        self.control_label = 0;
        self.thrown = false;
        self.returning = false;
        self.clearFrames(task); // frees any residual call-frame scopes
        task.state = .canceled;
        task.frames.clearAndFree(self.gpa);
        task.pending_bind = .discard;
        task.locals.deinit(self.gpa);
        task.locals = .{};
    }

    /// Resolve an `if`/`else if`/`else` chain to the `block_expr` of the taken
    /// branch (or `null` when none is), binding an `if let` payload (M1.0.11 E1).
    /// Conditions are evaluated synchronously — an `await` in a condition is a
    /// sub-expression and fails loud. Mirrors the sync `if_expr` arm of `evalExpr`.
    fn asyncIfBranch(self: *Interpreter, world: *World, locals: *Locals, ife_id: NodeId) StmtError!?NodeId {
        const ife = self.ast.if_exprs.items[self.ast.exprData(ife_id)];
        if (ife.let_binding != 0) {
            const opt = try self.evalExpr(world, locals, ife.cond);
            if (opt != .optional) return error.RuntimeFailure;
            if (self.optionals.items[opt.optional]) |payload| {
                try locals.put(self.gpa, ife.let_binding, payload, false);
                return ife.then_block;
            }
            if (ife.else_branch.isNone()) return null;
            if (self.ast.exprKind(ife.else_branch) == .if_expr) return try self.asyncIfBranch(world, locals, ife.else_branch);
            return ife.else_branch;
        }
        const cond = try self.evalExpr(world, locals, ife.cond);
        if (cond != .bool_) return error.RuntimeFailure;
        if (cond.bool_) return ife.then_block;
        if (ife.else_branch.isNone()) return null;
        if (self.ast.exprKind(ife.else_branch) == .if_expr) return try self.asyncIfBranch(world, locals, ife.else_branch);
        return ife.else_branch;
    }

    /// Select a `match`'s winning arm and return its body expression, binding a
    /// pattern capture (M1.0.11 E1). The scrutinee + patterns are evaluated
    /// synchronously. Mirrors the sync `match_expr` arm of `evalExpr`; a
    /// fall-through is a runtime failure (exhaustiveness proven at type-check).
    fn matchArmBody(self: *Interpreter, world: *World, locals: *Locals, m_id: NodeId) StmtError!NodeId {
        const m = self.ast.match_exprs.items[self.ast.exprData(m_id)];
        const scrut = try self.evalExpr(world, locals, m.scrutinee);
        var i: u32 = 0;
        while (i < m.arms_len) : (i += 1) {
            const arm = self.ast.match_arms.items[m.arms_start + i];
            switch (arm.pattern_kind) {
                .wildcard => return arm.body,
                .binding => {
                    try locals.put(self.gpa, arm.pattern_payload, scrut, false);
                    return arm.body;
                },
                .literal => {
                    const lit: NodeId = @bitCast(arm.pattern_payload);
                    const lit_v = try self.evalExpr(world, locals, lit);
                    if (scrut.eql(lit_v)) return arm.body;
                },
                .enum_variant => {
                    if (scrut != .enum_value) return error.RuntimeFailure;
                    const pat = self.ast.enum_pattern_payloads.items[arm.pattern_payload];
                    const edecl = self.enum_decls.get(scrut.enum_value.type_name) orelse return error.RuntimeFailure;
                    const vidx = self.enumVariantIndexOf(edecl, pat.variant) orelse return error.RuntimeFailure;
                    if (scrut.enum_value.variant == vidx) return arm.body;
                },
                .optional_some => {
                    if (scrut != .optional) return error.RuntimeFailure;
                    if (self.optionals.items[scrut.optional]) |payload| {
                        try locals.put(self.gpa, arm.pattern_payload, payload, false);
                        return arm.body;
                    }
                },
                .optional_none => {
                    if (scrut != .optional) return error.RuntimeFailure;
                    if (self.optionals.items[scrut.optional] == null) return arm.body;
                },
            }
        }
        return error.RuntimeFailure;
    }

    /// Evaluate a `while [let x =] cond` at the top of an iteration (M1.0.11 E1):
    /// `true` = enter the body, `false` = stop the loop. Mirrors the sync
    /// `while_stmt` arm of `execStmt`.
    fn whileCondEnter(self: *Interpreter, world: *World, locals: *Locals, wid: NodeId) StmtError!bool {
        const wh = self.ast.while_stmts.items[self.ast.stmtData(wid)];
        if (wh.let_binding != 0) {
            const opt = try self.evalExpr(world, locals, wh.cond);
            if (opt != .optional) return error.RuntimeFailure;
            const payload = self.optionals.items[opt.optional] orelse return false;
            try locals.put(self.gpa, wh.let_binding, payload, false);
            return true;
        }
        const cond = try self.evalExpr(world, locals, wh.cond);
        if (cond != .bool_) return error.RuntimeFailure;
        return cond.bool_;
    }

    /// Advance a `for` frame's iterator by one element, binding the loop
    /// variable(s) (M1.0.11 E1): `true` = a body iteration was entered, `false` =
    /// the iterator is exhausted (the `for` ends). Mirrors the sync `for_stmt`
    /// arms of `execStmt`. A `range` is self-contained; an `array`/`map` handle is
    /// bounds-checked against the (possibly reset) collection store and fails loud
    /// rather than dereference out of bounds (the heap-across-suspend caveat).
    fn forAdvance(self: *Interpreter, ff: *ForFrame, locals: *Locals) StmtError!bool {
        const f = self.ast.for_stmts.items[self.ast.stmtData(ff.for_id)];
        switch (ff.iter) {
            .range => {
                const r = &ff.iter.range;
                const more = if (r.inclusive) r.next <= r.end else r.next < r.end;
                if (!more) return false;
                try locals.put(self.gpa, f.var_name, .{ .int_ = r.next }, false);
                r.next += 1;
                return true;
            },
            .array => {
                const a = &ff.iter.array;
                if (a.idx >= a.len) return false;
                if (a.handle >= self.collections.arrays.items.len) return error.RuntimeFailure;
                const col = self.collections.arrays.items[a.handle];
                if (a.idx >= col.items.len) return error.RuntimeFailure;
                try locals.put(self.gpa, f.var_name, col.items[a.idx], false);
                a.idx += 1;
                return true;
            },
            .map => {
                const m = &ff.iter.map;
                if (m.idx >= m.len) return false;
                if (m.handle >= self.collections.maps.items.len) return error.RuntimeFailure;
                const col = self.collections.maps.items[m.handle];
                if (m.idx >= col.items.len) return error.RuntimeFailure;
                const pair = col.items[m.idx];
                try locals.put(self.gpa, f.var_name, pair.key, false);
                if (f.index_name != 0) try locals.put(self.gpa, f.index_name, pair.value, false);
                m.idx += 1;
                return true;
            },
        }
    }

    /// Resolve a wake-condition `await` target to a `WakeCond` (M1.0.11 E3). Only
    /// `wait` / `global_event` reach here (`future` is handled by `beginAsyncCall`
    /// upstream). `wait` takes a `Duration` (final API, §9.4): a Duration LITERAL
    /// → seconds → `async_tick` counts via the fixed 1/60 timestep
    /// (`async_fixed_dt_hz`). M1.0.13 swaps this for scaled game time WITHOUT
    /// changing the signature (at `time_scale = 1`, fixed `dt = 1/60`, identical).
    /// A non-literal Duration (const / arithmetic) is out of scope → fail loud.
    /// `global_event(T)` waits for an event of type `T`. `wait_unscaled` (M1.0.13)
    /// / `entity_event` (M1.0.14) fail loud (defensive; filtered upstream).
    fn evalAwaitTarget(self: *Interpreter, await_id: NodeId) StmtError!WakeCond {
        const aw = self.ast.awaitExpr(await_id);
        switch (aw.target_kind) {
            .wait => {
                if (self.ast.exprKind(aw.arg_expr) != .duration_lit) return error.RuntimeFailure;
                const secs = durationLiteralSeconds(self.ast.strings.slice(self.ast.exprData(aw.arg_expr))) orelse return error.RuntimeFailure;
                if (secs < 0) return error.RuntimeFailure;
                const ticks: u64 = @intFromFloat(@round(secs * async_fixed_dt_hz));
                return .{ .wait_until = self.async_tick + ticks };
            },
            .global_event => return .{ .global_event = aw.event_type },
            .wait_unscaled, .entity_event, .future => return error.RuntimeFailure,
        }
    }

    /// True iff a suspended task's wake condition is satisfied this tick. The
    /// child-set variants (M1.0.12 E1) POLL the pool states — no notification
    /// machinery; the pool is small and the poll runs at the rule's position.
    fn asyncWakeFired(self: *const Interpreter, wake: WakeCond) bool {
        return switch (wake) {
            .wait_until => |t| self.async_tick >= t,
            .global_event => |type_name| self.events.count(type_name) > 0,
            // Race parent: a winner exists (some child `.done`) — or no child
            // remains `.suspended` (every branch failed/canceled → no winner;
            // the race completes and the parent resumes after the statement, E4).
            .children_any => |r| blk: {
                var any_done = false;
                var any_suspended = false;
                for (self.task_children.items[r.start .. r.start + r.len]) |ci| {
                    switch (self.async_tasks.items[ci].state) {
                        .done => any_done = true,
                        .suspended => any_suspended = true,
                        .canceled => {},
                    }
                }
                break :blk any_done or !any_suspended;
            },
            // Sync parent: join when no child remains `.suspended` — failed
            // (canceled) children do not block the join (E4).
            .children_all => |r| blk: {
                for (self.task_children.items[r.start .. r.start + r.len]) |ci| {
                    if (self.async_tasks.items[ci].state == .suspended) break :blk false;
                }
                break :blk true;
            },
            // Handle-await: the target task reached a terminal state (`.done`
            // delivers its parked result; `.canceled` fails loud at resume, E5).
            .task_done => |ti| self.async_tasks.items[ti].state != .suspended,
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

    /// M1.0.9 B1 — drain the deferred extension activate/deactivate queue at the
    /// tick boundary (after every rule has run, so no live `iterateArchetype`
    /// walk is in flight — the immediate `add`/`removeComponentDynamic` an op
    /// performs is then safe). Each op applies its structural change + fires the
    /// Tier-0 `on_attach`/`on_detach` seam via the loader's bytes-taking
    /// `activateExtension` / `deactivateExtension`. The batch is snapshotted
    /// (`toOwnedSlice`) so a hook fired during apply that enqueues more ops does
    /// NOT drain recursively — new ops wait for the next flush.
    fn flushPendingExtensions(self: *Interpreter, world: *World) !void {
        if (self.pending_extensions.items.len == 0) return;
        const batch = try self.pending_extensions.toOwnedSlice(self.gpa);
        defer {
            for (batch) |pe| self.gpa.free(pe.name);
            self.gpa.free(batch);
        }
        for (batch) |pe| switch (pe.op) {
            .activate => try scene_loader.activateExtension(world, self.gpa, pe.entity, pe.name, pe.bytes),
            .deactivate => try scene_loader.deactivateExtension(world, self.gpa, pe.entity, pe.name, pe.bytes),
        };
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
        self.pending_error = null;

        var s: u32 = 0;
        while (s < rule.body_len) : (s += 1) {
            const stmt_raw = self.ast.extra.items[rule.body_start + s];
            const stmt_id: NodeId = @bitCast(stmt_raw);
            self.execStmt(world, &locals, stmt_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RuntimeFailure => {
                    self.harvestError(report);
                    return;
                },
            };
            // A `throw` reaching the rule top level was never caught — count it
            // as a runtime error (the dev-build surfacing of an unhandled throw).
            if (self.thrown) {
                self.thrown = false;
                self.pending_error = .{ .kind = .UncaughtThrow, .span = self.thrown_span };
                self.harvestError(report);
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

    /// Raise a typed runtime failure (M0.8 E3-D, D-S4-runtime-report): record
    /// the `(kind, span)` payload on the sideband and return the unwinding
    /// error. Usage: `return self.fail(.DivisionByZero, self.ast.exprSpan(id))`.
    fn fail(self: *Interpreter, kind: RuntimeErrorKind, span: SourceSpan) error{RuntimeFailure} {
        self.pending_error = .{ .kind = kind, .span = span };
        return error.RuntimeFailure;
    }

    /// Harvest a runtime failure into the report at a body choke point
    /// (M0.8 E3-D): bump the counter and surface the typed payload when the
    /// raise site recorded one. An untyped site leaves the previous
    /// `last_error` in place (the counter still moves).
    fn harvestError(self: *Interpreter, report: *RuntimeReport) void {
        report.runtime_errors += 1;
        if (self.pending_error) |pe| report.last_error = pe;
        self.pending_error = null;
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
                // Anonymous `.{ … }` initializer (M0.8 E3-C tranche 8): the
                // let annotation supplies the struct type — the same logical
                // point as the resolver's check mode and the codegen's
                // qualified emission. The resolver guarantees a named struct
                // annotation (E0210 otherwise); belt on the lookup.
                const v = blk: {
                    if (self.ast.exprKind(let.value) == .struct_lit) {
                        const sl = self.ast.struct_lits.items[self.ast.exprData(let.value)];
                        if (sl.type_name == 0) {
                            if (let.type_annotation.isNone() or self.ast.typeNodeKind(let.type_annotation) != .named) return error.RuntimeFailure;
                            const named = self.ast.named_types.items[self.ast.typeNodeData(let.type_annotation)];
                            break :blk try self.evalStructLitAs(world, locals, sl, self.ast.resolveTypeAliasName(named.name));
                        }
                    }
                    break :blk try self.evalExpr(world, locals, let.value);
                };
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
                // Recorded for the uncaught-throw report entry (M0.8 E3-D);
                // irrelevant when a `catch` consumes the throw.
                self.thrown_span = self.ast.exprSpan(t.value);
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
                const set = tm.kind == .add;
                if (self.observer_deferred) |dbuf| {
                    // Inside an observer body (M1.0.2 E3): route to the registry's
                    // deferred Tier-0 buffer so the mutation applies at the NEXT
                    // flush, never re-entrantly during the current one.
                    const tid = self.tagset_id orelse return error.RuntimeFailure;
                    const core_id: CoreEntityId = @bitCast(entity);
                    const cmd: command_buffer_mod.Command = if (set)
                        .{ .set_tag = .{ .entity = core_id, .tagset_id = tid, .bit_index = bit } }
                    else
                        .{ .clear_tag = .{ .entity = core_id, .tagset_id = tid, .bit_index = bit } };
                    try dbuf.commands.append(dbuf.gpa, cmd);
                } else {
                    try self.pending_tags.append(self.gpa, .{
                        .entity = entity,
                        .bit_index = bit,
                        .set = set,
                    });
                }
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
                    const cur = Bridge.readComponentField(&world.registry, cref, world, field_name) catch |e|
                        return self.fail(bridgeFailureKind(e), self.ast.exprSpan(assign.target));
                    const rhs = try self.evalExpr(world, locals, assign.value);
                    const new_v = applyAssignOp(cur, assign.op, rhs) catch return error.RuntimeFailure;
                    Bridge.writeComponentField(&world.registry, cref, world, field_name, new_v) catch |e|
                        return self.fail(bridgeFailureKind(e), self.ast.exprSpan(assign.target));
                    // Change detection (M0.8 E3): stamp `changed_tick = current_tick`
                    // so an `entity has T changed` rule sees this write. Gated on
                    // `has_changed` — a `changed`-free program never marks. Same
                    // logical point as the codegen's post-write `markChanged`.
                    if (self.has_changed) Bridge.markComponentChanged(world, cref, world.current_tick);
                    return;
                },
                .resource_ref => |rref| {
                    if (!rref.mutable) return error.RuntimeFailure;
                    // A `.string_` slot write is a persistent promotion (M1.0.3
                    // E2), not a byte-block overwrite. Resolve the incoming
                    // string's bytes (literal / rule-arena) here, then hand them
                    // to `promoteResourceString`, which allocs the fresh block,
                    // writes the new slot, and decrefs the previous value (order
                    // enforced there). Only plain `=` is in the M1.0.3 surface;
                    // a compound op on a string slot is a runtime failure.
                    if (world.registry.findField(rref.resource_id, field_name)) |field| {
                        if (field.kind == .string_) {
                            if (assign.op != .assign) return error.RuntimeFailure;
                            const rhs = try self.evalExpr(world, locals, assign.value);
                            const bytes = self.stringBytes(rhs) orelse return error.RuntimeFailure;
                            Bridge.promoteResourceString(self.gpa, &world.registry, &world.resources, rref.resource_id, field_name, bytes) catch |e|
                                return self.fail(bridgeFailureKind(e), self.ast.exprSpan(assign.target));
                            return;
                        }
                        if (field.kind == .enum_) {
                            // Enum slot write (M1.0.3 E3): resolve the RHS `.variant`
                            // shorthand against the field's declared enum type (the
                            // assignment position carries no expected-type context to
                            // `evalExpr`), then store its discriminant. Only `=`.
                            if (assign.op != .assign) return error.RuntimeFailure;
                            const ev = try self.evalEnumShorthandFor(world, locals, assign.value, field.enum_type_name_id);
                            Bridge.writeResourceField(&world.registry, &world.resources, rref.resource_id, field_name, ev) catch |e|
                                return self.fail(bridgeFailureKind(e), self.ast.exprSpan(assign.target));
                            return;
                        }
                    }
                    const cur = Bridge.readResourceField(&world.registry, &world.resources, rref.resource_id, field_name) catch |e|
                        return self.fail(bridgeFailureKind(e), self.ast.exprSpan(assign.target));
                    const rhs = try self.evalExpr(world, locals, assign.value);
                    const new_v = applyAssignOp(cur, assign.op, rhs) catch return error.RuntimeFailure;
                    Bridge.writeResourceField(&world.registry, &world.resources, rref.resource_id, field_name, new_v) catch |e|
                        return self.fail(bridgeFailureKind(e), self.ast.exprSpan(assign.target));
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
        // An `async fn` executes via the await call-frame path (`beginAsyncCall`),
        // not this synchronous path (M1.0.11 E2). Reaching here for an async fn is
        // a direct (non-`await`) call — a function-coloring violation the E4
        // type-checker rejects (E0901); until then it degrades to a fail-loud.
        if (fndecl.is_async) return error.RuntimeFailure;
        if (fndecl.params_len != call.args_len) return error.RuntimeFailure;
        var frame: Locals = .{};
        defer frame.deinit(self.gpa);
        // Evaluate arguments in SOURCE order, then bind in parameter order
        // (M0.8 E4 named arguments — the 2026-06-10 evaluation-order
        // ruling: written order keeps the call site self-contained; the
        // codegen emits the same source-order temporaries).
        var values: [max_call_args]Value = undefined;
        if (call.args_len > max_call_args) return error.RuntimeFailure;
        var j: u32 = 0;
        while (j < call.args_len) : (j += 1) {
            const arg: NodeId = @bitCast(self.ast.extra.items[call.args_start + j]);
            values[j] = try self.evalExpr(world, caller_locals, arg);
        }
        var i: u32 = 0;
        while (i < fndecl.params_len) : (i += 1) {
            const p = self.ast.fn_params.items[fndecl.params_start + i];
            const idx = self.ast.callArgIndexForParam(call.args_start, call.args_len, call.names_start, i, p.name) orelse return error.RuntimeFailure;
            try frame.put(self.gpa, p.name, values[idx], false);
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

    /// Resolve a bare `.variant` (1-segment `tag_path`) field value against
    /// a declared enum-typed struct field at struct-literal evaluation
    /// (M0.8 E3-C tranche 4, part1 §10.2) — the same declared-type lookup
    /// as the resolver's check mode and the codegen's qualified emission.
    /// `null` when the field is not enum-typed or the variant is unknown
    /// (the resolver has already rejected those programs).
    fn enumFieldShorthand(self: *Interpreter, f: ast_mod.Field, value: NodeId) ?Value {
        if (self.ast.typeNodeKind(f.type_node) != .named) return null;
        const named = self.ast.named_types.items[self.ast.typeNodeData(f.type_node)];
        const ename = self.ast.resolveTypeAliasName(named.name);
        const edecl = self.enum_decls.get(ename) orelse return null;
        // Expression-position `tag_path` data IS the variant ident (the
        // parser interns it directly; multi-segment is a parse error there).
        const variant: StringId = self.ast.exprData(value);
        const vidx = self.enumVariantIndexOf(edecl, variant) orelse return null;
        return Value{ .enum_value = .{ .type_name = ename, .variant = vidx } };
    }

    /// Resolve an enum assignment RHS against a known enum type id (M1.0.3 E3,
    /// resource enum write). A bare `.variant` shorthand resolves to a typed
    /// `enum_value` against `enum_type_name_id`; any other form (a variable, a
    /// qualified `Type.variant`) is evaluated normally — its tag already carries
    /// the type. The `type_name` id matches `enum_decls`'s keying, so the stored
    /// discriminant and any later read/compare agree.
    fn evalEnumShorthandFor(self: *Interpreter, world: *World, locals: *Locals, value: NodeId, enum_type_name_id: u32) StmtError!Value {
        if (self.ast.exprKind(value) == .tag_path) {
            const edecl = self.enum_decls.get(enum_type_name_id) orelse return error.RuntimeFailure;
            const variant: StringId = self.ast.exprData(value);
            const vidx = self.enumVariantIndexOf(edecl, variant) orelse return error.RuntimeFailure;
            return Value{ .enum_value = .{ .type_name = enum_type_name_id, .variant = vidx } };
        }
        return try self.evalExpr(world, locals, value);
    }

    /// The declared-struct name of a field's `.named` type node, or null when
    /// the field is not struct-typed (M0.8 E3-C tranche 8) — the same
    /// declared-type lookup as `enumFieldShorthand`, for the anonymous
    /// `.{ … }` field-value resolution.
    fn structFieldTypeName(self: *Interpreter, f: ast_mod.Field) ?StringId {
        if (self.ast.typeNodeKind(f.type_node) != .named) return null;
        const named = self.ast.named_types.items[self.ast.typeNodeData(f.type_node)];
        const sname = self.ast.resolveTypeAliasName(named.name);
        if (self.struct_decls.get(sname) == null) return null;
        return sname;
    }

    /// Materialize a struct literal as a fresh `type_name` value in the
    /// rule-body struct store (M0.8 E2 block 3; split out in E3-C tranche 8 so
    /// the anonymous `.{ … }` form evaluates through the same point with the
    /// name supplied by its context — let annotation or typed field value,
    /// the same logical point as the resolver's check mode and the codegen's
    /// qualified emission). Every declared field is filled in declaration
    /// order: the literal's value if given, else the field's const default
    /// (matching the Zig codegen, which relies on the `extern struct`
    /// default-fill). The handle is re-fetched after each field eval (a
    /// nested struct literal may have grown the outer store vector).
    fn evalStructLitAs(self: *Interpreter, world: *World, locals: *Locals, sl: ast_mod.StructLitExpr, type_name: StringId) StmtError!Value {
        const decl = self.struct_decls.get(type_name) orelse return error.RuntimeFailure;
        const handle = try self.structs.newStruct(self.gpa, type_name);
        var fi: u32 = 0;
        while (fi < decl.fields_len) : (fi += 1) {
            const f = self.ast.fields.items[decl.fields_start + fi];
            var provided: ?Value = null;
            var li: u32 = 0;
            while (li < sl.fields_len) : (li += 1) {
                const flit = self.ast.struct_lit_fields.items[sl.fields_start + li];
                if (flit.name == f.name) {
                    // Bare `.variant` in field-value position (M0.8
                    // E3-C tranche 4, part1 §10.2): resolved against
                    // the declared field type — the decl's field
                    // list is in hand at this site.
                    if (self.ast.exprKind(flit.value) == .tag_path) {
                        if (self.enumFieldShorthand(f, flit.value)) |ev| {
                            provided = ev;
                            break;
                        }
                    }
                    // Anonymous `.{ … }` in field-value position (M0.8
                    // E3-C tranche 8): resolved against the declared
                    // struct field type, recursively.
                    if (self.ast.exprKind(flit.value) == .struct_lit) {
                        const inner = self.ast.struct_lits.items[self.ast.exprData(flit.value)];
                        if (inner.type_name == 0) {
                            const sname = self.structFieldTypeName(f) orelse return error.RuntimeFailure;
                            provided = try self.evalStructLitAs(world, locals, inner, sname);
                            break;
                        }
                    }
                    provided = try self.evalExpr(world, locals, flit.value);
                    break;
                }
            }
            const fval = provided orelse blk: {
                // A struct-typed field has no agreed default (the resolver
                // requires literal provision, E0208) — belt against the
                // zero-fill below silently standing in for one.
                if (self.structFieldTypeName(f) != null) return error.RuntimeFailure;
                if (f.default_value.isNone()) break :blk Value{ .int_ = 0 };
                break :blk evalConst(self.ast, f.default_value) catch Value{ .int_ = 0 };
            };
            try self.structs.list.items[handle].fields.append(self.gpa, .{ .name = f.name, .value = fval });
        }
        return Value{ .struct_ref = handle };
    }

    /// M1.0.9 — extract the single string argument of an extension method
    /// (`activate_extension` / `deactivate_extension` / `has_extension`) as raw
    /// bytes. Borrowed from the current AST arena / run-string store — valid for
    /// the synchronous resolve / lookup that immediately follows.
    fn extensionNameArg(self: *Interpreter, world: *World, locals: *Locals, mc: ast_mod.MethodCall) StmtError![]const u8 {
        if (mc.args_len != 1) return error.RuntimeFailure;
        const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
        const v = try self.evalExpr(world, locals, arg);
        return self.stringBytes(v) orelse error.RuntimeFailure;
    }

    /// M1.0.9 B1 — resolve the extension bytes NOW and enqueue a deferred
    /// activate/deactivate, applied at the tick boundary (`flushPendingExtensions`)
    /// — NOT the immediate `runtimeActivate`/`runtimeDeactivate`, which would
    /// mutate an archetype mid-`iterateArchetype`. Missing resolver / unknown name
    /// surface as `RuntimeFailure` (the interp's failure channel). The name is
    /// dup'd (the AST / run-string source may not outlive the flush).
    fn enqueueExtension(self: *Interpreter, entity: CoreEntityId, name: []const u8, op: ExtOp) StmtError!void {
        const resolver = self.bridge.ext_resolver orelse return error.RuntimeFailure;
        const bytes = resolver.resolve(name) orelse return error.RuntimeFailure;
        const name_dup = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(name_dup);
        try self.pending_extensions.append(self.gpa, .{ .entity = entity, .name = name_dup, .bytes = bytes, .op = op });
    }

    /// M1.0.10 E3 — the Tier-0 `CommandBuffer` that a body's structural
    /// mutations (`spawn` / `despawn` / `add` / `remove`) enqueue onto. Inside an
    /// observer / hook body `observer_deferred` is already bound to it; in a
    /// plain rule body it is the world's shared observer-deferred buffer (lazily
    /// created, owned + freed by the `ObserverRegistry`). The four ops route here
    /// — NOT through a parallel `pending_*` queue (cf. `etch-grammar.md` §4.5) —
    /// and the tick-boundary `flushStructural` drains it via `applyWithObservers`.
    fn structuralDeferred(self: *Interpreter, world: *World) StmtError!*CommandBuffer {
        if (self.observer_deferred) |d| return d;
        if (world.observer_registry.deferred == null) {
            world.observer_registry.deferred = CommandBuffer.init(self.gpa, world);
        }
        return &world.observer_registry.deferred.?;
    }

    /// M1.0.10 E3 — resolve a component literal `T { f: v, … }` to its registry id
    /// + a freshly built payload (component defaults overwritten by the provided
    /// fields, evaluated EAGERLY now). Bytes are allocated in `alloc` (the
    /// deferred buffer's arena) so they survive until the tick-boundary drain.
    /// Components are POD-strict (no heap fields), so `writeValueAsBytes` covers
    /// every valid field kind. The type-checker (E2) has already validated the
    /// type is a declared component and the fields exist + type-match.
    fn buildComponentPayload(self: *Interpreter, world: *World, locals: *Locals, struct_lit_arg: NodeId, alloc: std.mem.Allocator) StmtError!struct { cid: ComponentId, bytes: []u8 } {
        if (self.ast.exprKind(struct_lit_arg) != .struct_lit) return error.RuntimeFailure;
        const sl = self.ast.struct_lits.items[self.ast.exprData(struct_lit_arg)];
        const name = self.ast.strings.slice(sl.type_name);
        const cid = world.registry.idOf(name) orelse return error.RuntimeFailure;
        const size = world.registry.componentSize(cid);
        const buf = try alloc.alloc(u8, size);
        @memcpy(buf, world.registry.componentDefaultBytes(cid));
        var i: u32 = 0;
        while (i < sl.fields_len) : (i += 1) {
            const flit = self.ast.struct_lit_fields.items[sl.fields_start + i];
            const fd = world.registry.findField(cid, self.ast.strings.slice(flit.name)) orelse return error.RuntimeFailure;
            const v = try self.evalExpr(world, locals, flit.value);
            const fsize: u16 = @intCast(fd.kind.sizeBytes());
            const field_bytes = buf[fd.offset .. fd.offset + fsize];
            bridge_mod.writeValueAsBytes(fd.kind, field_bytes, v) catch return error.RuntimeFailure;
        }
        return .{ .cid = cid, .bytes = buf };
    }

    /// M1.0.10 E3 — drain the deferred structural commands at the tick boundary,
    /// applying each via `applyWithObservers` so observers fire per op (spawn →
    /// `on_spawned` + `on_add`; despawn → `on_remove` + `on_despawned`;
    /// add-on-present → `on_replaced`; add → `on_add`; remove → `on_remove`).
    /// Drains until empty: an observer body may itself enqueue more structural
    /// commands (routed back to the same buffer), and those apply in a later
    /// round of this same boundary. Never runs mid-`iterateArchetype`.
    fn flushStructural(self: *Interpreter, world: *World) !void {
        const reg = &world.observer_registry;
        if (reg.deferred == null) return;
        while (reg.deferred.?.commands.items.len > 0) {
            const batch = try reg.deferred.?.commands.toOwnedSlice(reg.deferred.?.gpa);
            defer reg.deferred.?.gpa.free(batch);
            for (batch) |c| try observers_mod.applyWithObservers(c, reg, world, self.gpa);
        }
        // All commands applied — reclaim the payload arena.
        reg.deferred.?.reset();
    }

    /// Dispatch an instance method call on an already-evaluated receiver
    /// value — §5.5 order: inherent / trait on user types, then the builtin
    /// string / collection subsets. Split from the `.method_call` arm so the
    /// optional chain `recv?.method()` dispatches the same way on the
    /// unwrapped payload (M0.8 E3-C tranche 4) — same logical point as the
    /// resolver's `dispatchMethodOnType` split.
    fn dispatchMethodOnValue(self: *Interpreter, world: *World, locals: *Locals, mc: ast_mod.MethodCall, recv: Value) StmtError!Value {
        switch (recv) {
            .task_handle => |ti| {
                // M1.0.12 E5 — the TaskHandle's single method (§9.8):
                // `h.cancel()` is IDEMPOTENT — cancels a suspended task, a
                // no-op on `.done`/`.canceled` (`cancelTask` gates on state).
                // Non-transitive: tasks the target launched keep running.
                const mname = self.ast.strings.slice(mc.method_name);
                if (std.mem.eql(u8, mname, "cancel")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    self.cancelTask(ti);
                    return Value{ .unit = {} };
                }
                return error.RuntimeFailure;
            },
            .struct_ref => |handle| {
                const type_name = self.structs.list.items[handle].type_name;
                const key = methodKey(type_name, mc.method_name);
                const method = self.methods.get(key) orelse self.trait_methods.get(key) orelse return error.RuntimeFailure;
                return try self.callMethod(world, locals, method, mc, recv);
            },
            .entity_id => |eid| {
                const mname = self.ast.strings.slice(mc.method_name);
                // M1.0.9 — runtime extension API on an entity receiver. Checked
                // before the `impl Trait for Entity` lookup (these are builtin
                // methods, not user traits). activate/deactivate route through the
                // shared loader entries; a missing resolver / unknown extension /
                // component conflict surfaces as the interp's `RuntimeFailure`
                // (the loader path keeps the named `MissingExtensionResolver` etc.).
                if (std.mem.eql(u8, mname, "activate_extension")) {
                    // B1: ENQUEUE (deferred to the tick boundary) — never an
                    // immediate structural mutation here (we may be mid-iteration).
                    try self.enqueueExtension(@bitCast(eid), try self.extensionNameArg(world, locals, mc), .activate);
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "deactivate_extension")) {
                    try self.enqueueExtension(@bitCast(eid), try self.extensionNameArg(world, locals, mc), .deactivate);
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "has_extension")) {
                    const name = try self.extensionNameArg(world, locals, mc);
                    return Value{ .bool_ = world.hasEntityExtension(@bitCast(eid), name) };
                }
                if (std.mem.eql(u8, mname, "active_extensions")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    const handle = try self.collections.newArray(self.gpa);
                    for (world.entityExtensions(@bitCast(eid))) |n| {
                        // Wrap each owned name as a borrowed persistent-string view
                        // (the names outlive the call — owned by the side-table).
                        try self.collections.arrays.items[handle].append(self.gpa, Value{ .string_persistent = .{ .ptr = @intFromPtr(n.ptr), .len = @intCast(n.len) } });
                    }
                    return Value{ .array_ref = handle };
                }
                // M1.0.10 — structural mutation methods on an Entity receiver
                // (`etch-grammar.md` §4.5). Each ENQUEUES a Tier-0 `CommandBuffer`
                // command onto the deferred buffer (never an immediate mutation —
                // we may be mid-`iterateArchetype`); the tick-boundary
                // `flushStructural` applies it with observers. All return `unit`.
                if (std.mem.eql(u8, mname, "despawn")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    const dbuf = try self.structuralDeferred(world);
                    try dbuf.commands.append(dbuf.gpa, .{ .despawn = .{ .entity = @bitCast(eid) } });
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "add")) {
                    if (mc.args_len != 1) return error.RuntimeFailure;
                    const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
                    const dbuf = try self.structuralDeferred(world);
                    const payload = try self.buildComponentPayload(world, locals, arg, dbuf.arena.allocator());
                    try dbuf.commands.append(dbuf.gpa, .{ .add_component = .{
                        .entity = @bitCast(eid),
                        .component_id = payload.cid,
                        .bytes = payload.bytes,
                    } });
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "remove")) {
                    if (mc.args_len != 1) return error.RuntimeFailure;
                    // The argument is a bare component TYPE name (`.path`), not a
                    // value — resolve the id directly (do not `evalExpr` a path).
                    const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
                    if (self.ast.exprKind(arg) != .path) return error.RuntimeFailure;
                    const cname = self.ast.strings.slice(self.ast.exprData(arg));
                    const cid = world.registry.idOf(cname) orelse return error.RuntimeFailure;
                    const dbuf = try self.structuralDeferred(world);
                    try dbuf.commands.append(dbuf.gpa, .{ .remove_component = .{
                        .entity = @bitCast(eid),
                        .component_id = cid,
                    } });
                    return Value{ .unit = {} };
                }
                // Trait method on an Entity (`impl Trait for Entity`). The
                // type key is the interned `Entity`; self is the handle.
                const entity_name = self.ast.strings.find("Entity") orelse return error.RuntimeFailure;
                const method = self.trait_methods.get(methodKey(entity_name, mc.method_name)) orelse return error.RuntimeFailure;
                return try self.callMethod(world, locals, method, mc, recv);
            },
            .string_id, .string_run, .string_persistent => {
                // Builtin string methods (M0.8 sub-slice C tranche 1 —
                // minimal faithful subset). `len` → byte length, on a
                // literal (`string_id`), a runtime-produced string
                // (`string_run`, tranche 1b), or a borrowed resource-string
                // view (`string_persistent`, M1.0.3 E2); any other §12 method
                // is stdlib Phase 1+ → fail loud. `stringBytes` already covers
                // all three forms.
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
            .set_ref => |handle| {
                // Builtin set methods (M0.8 E3-C tranche 3bis — minimal
                // faithful subset of stdlib §15.2). `insert` is the same
                // scan-skip-or-append as the `Set.from` seeding (its `bool`
                // return is out of the subset — statement use only, the
                // value here is unit); `contains` scans with `Value.eql`;
                // `len` is the element count; any other §15 method is
                // stdlib Phase 1+ → fail loud.
                const mname = self.ast.strings.slice(mc.method_name);
                if (std.mem.eql(u8, mname, "insert")) {
                    if (mc.args_len != 1) return error.RuntimeFailure;
                    const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
                    const v = try self.evalExpr(world, locals, arg);
                    try self.setInsert(handle, v);
                    return Value{ .unit = {} };
                }
                if (std.mem.eql(u8, mname, "contains")) {
                    if (mc.args_len != 1) return error.RuntimeFailure;
                    const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
                    const v = try self.evalExpr(world, locals, arg);
                    for (self.collections.sets.items[handle].items) |existing| {
                        if (existing.eql(v)) return Value{ .bool_ = true };
                    }
                    return Value{ .bool_ = false };
                }
                if (std.mem.eql(u8, mname, "len")) {
                    if (mc.args_len != 0) return error.RuntimeFailure;
                    return Value{ .int_ = @intCast(self.collections.sets.items[handle].items.len) };
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

    /// Evaluate a `Set.assoc(...)` builtin associated call (M0.8 E3-C tranche
    /// 3bis, stdlib §15.1 — minimal faithful subset). `new` materializes an
    /// empty set in the store; `from` seeds one from an array argument element
    /// by element through the same scan-skip-or-append as `insert` (duplicates
    /// collapse), so the insertion order the codegen mirrors is fixed by
    /// construction. `with_capacity` (a generic call form) and anything else
    /// is stdlib Phase 1+ → fail loud.
    fn evalSetAssociated(self: *Interpreter, world: *World, locals: *Locals, mc: ast_mod.MethodCall) StmtError!Value {
        const mname = self.ast.strings.slice(mc.method_name);
        if (std.mem.eql(u8, mname, "new")) {
            if (mc.args_len != 0) return error.RuntimeFailure;
            const handle = try self.collections.newSet(self.gpa);
            return Value{ .set_ref = handle };
        }
        if (std.mem.eql(u8, mname, "from")) {
            if (mc.args_len != 1) return error.RuntimeFailure;
            const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start]);
            const av = try self.evalExpr(world, locals, arg);
            if (av != .array_ref) return error.RuntimeFailure;
            const handle = try self.collections.newSet(self.gpa);
            var i: usize = 0;
            while (i < self.collections.arrays.items[av.array_ref].items.len) : (i += 1) {
                // Re-index the source array on every step (the set append
                // cannot grow the arrays vector, but stay on the shared
                // re-index discipline of the collection stores).
                const v = self.collections.arrays.items[av.array_ref].items[i];
                try self.setInsert(handle, v);
            }
            return Value{ .set_ref = handle };
        }
        return error.RuntimeFailure;
    }

    /// Scan-skip-or-append insert into the set store (M0.8 E3-C tranche 3bis):
    /// the single mechanics shared by the `Set.from` seeding and `s.insert(x)`,
    /// mirrored by the codegen's `__etchSetInsert` helper — element order is
    /// byte-exact across the two backends by construction.
    fn setInsert(self: *Interpreter, handle: u32, item: Value) !void {
        for (self.collections.sets.items[handle].items) |existing| {
            if (existing.eql(item)) return;
        }
        try self.collections.sets.items[handle].append(self.gpa, item);
    }

    fn callMethod(self: *Interpreter, world: *World, caller_locals: *Locals, method: ast_mod.FnDecl, mc: ast_mod.MethodCall, self_value: ?Value) StmtError!Value {
        // As in `callFn`: an `async method` runs via the await call-frame path
        // (M1.0.11 E2); a direct sync call is a coloring violation (E0901, E4).
        if (method.is_async) return error.RuntimeFailure;
        if (method.params_len != mc.args_len) return error.RuntimeFailure;
        var frame: Locals = .{};
        defer frame.deinit(self.gpa);
        if (self_value) |sv| {
            if (self.ast.strings.find("self")) |self_id| {
                try frame.put(self.gpa, self_id, sv, method.self_kind == .by_mut);
            }
        }
        // Source-order evaluation, parameter-order binding — the same
        // contract as `callFn` (the 2026-06-10 evaluation-order ruling).
        // The receiver evaluated first (it is written first).
        var values: [max_call_args]Value = undefined;
        if (mc.args_len > max_call_args) return error.RuntimeFailure;
        var j: u32 = 0;
        while (j < mc.args_len) : (j += 1) {
            const arg: NodeId = @bitCast(self.ast.extra.items[mc.args_start + j]);
            values[j] = try self.evalExpr(world, caller_locals, arg);
        }
        var i: u32 = 0;
        while (i < method.params_len) : (i += 1) {
            const p = self.ast.fn_params.items[method.params_start + i];
            const idx = self.ast.callArgIndexForParam(mc.args_start, mc.args_len, mc.names_start, i, p.name) orelse return error.RuntimeFailure;
            try frame.put(self.gpa, p.name, values[idx], false);
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

    /// The bytes of a string value — an AST-table literal (`string_id`), a
    /// runtime-produced string (`string_run`), or a borrowed resource-string
    /// view (`string_persistent`, M1.0.3 E2). Null for any non-string value.
    fn stringBytes(self: *const Interpreter, v: Value) ?[]const u8 {
        return switch (v) {
            .string_id => |sid| self.ast.strings.slice(sid),
            .string_run => |handle| self.run_strings.items[handle],
            .string_persistent => |s| blk: {
                if (s.len == 0) break :blk &.{};
                const p: [*]const u8 = @ptrFromInt(s.ptr);
                break :blk p[0..s.len];
            },
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
                    .component_ref => |cref| return Bridge.readComponentField(&world.registry, cref, world, field_name) catch |e|
                        self.fail(bridgeFailureKind(e), self.ast.exprSpan(id)),
                    .resource_ref => |rref| return Bridge.readResourceField(&world.registry, &world.resources, rref.resource_id, field_name) catch |e|
                        self.fail(bridgeFailureKind(e), self.ast.exprSpan(id)),
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
                    .add, .sub, .mul, .div, .rem => binaryArith(b.op, lhs, rhs) catch
                        return self.fail(arithFailureKind(b.op, lhs, rhs), self.ast.exprSpan(id)),
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
                // Named args on a closure call are an M0.8 bound (item 16:
                // declared fns + methods only) — the resolver rejects them
                // (E0203); belt here.
                if (call.names_start != ast_mod.no_arg_names) return error.RuntimeFailure;
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
                // The closure call boundary consumes `returning` (E2 forward
                // note, executed at E3-C tranche 6): a `return` inside the
                // body exits the CLOSURE — it becomes the call's value — never
                // the enclosing fn. Same boundary-consume as `callFn` /
                // `callMethod`; `thrown` and `break`/`continue` keep
                // propagating (the enclosing try / loop interprets them) and
                // the call yields unit.
                const result = try self.evalExpr(world, &frame, ce.body);
                if (self.returning) {
                    self.returning = false;
                    const rv = self.return_value;
                    self.return_value = .{ .unit = {} };
                    return rv;
                }
                if (self.thrown or self.control != .none) return Value{ .unit = {} };
                return result;
            },
            .struct_lit => {
                const sl = self.ast.struct_lits.items[data];
                // Anonymous `.{ … }` (`type_name == 0`, M0.8 E3-C tranche 8)
                // only evaluates through a typed context (let annotation /
                // typed field value) which supplies the name — the resolver
                // rejects any other position (E0210); belt here.
                if (sl.type_name == 0) return error.RuntimeFailure;
                return try self.evalStructLitAs(world, locals, sl, sl.type_name);
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
                    // Builtin-type associated calls (M0.8 E3-C tranche 3bis):
                    // `Set.new()` / `Set.from([...])` route to the set store
                    // BEFORE the user `impl` lookup — `Set` is a builtin
                    // stdlib type and is not user-overridable (stdlib §2.6).
                    if (std.mem.eql(u8, self.ast.strings.slice(type_name), "Set")) {
                        return try self.evalSetAssociated(world, locals, mc);
                    }
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
            .spawn_struct => {
                // Structural `spawn(C1 {…}, …)` (M1.0.10, `etch-grammar.md` §3.2 /
                // §4.5) — a statement-position expression (the type-checker rejects
                // value use, E0304). Resolve each component literal's bytes EAGERLY
                // now, enqueue a single deferred `.spawn` command, and yield `unit`
                // (no body handle, v0.6). The prefab form is refused at type-check
                // (E0305) — never executed.
                const ss = self.ast.spawn_structs.items[data];
                if (ss.is_prefab) return error.RuntimeFailure;
                const dbuf = try self.structuralDeferred(world);
                const arena_alloc = dbuf.arena.allocator();
                const ids = try arena_alloc.alloc(ComponentId, ss.args_len);
                const payloads = try arena_alloc.alloc([]const u8, ss.args_len);
                var i: u32 = 0;
                while (i < ss.args_len) : (i += 1) {
                    const arg: NodeId = @bitCast(self.ast.extra.items[ss.args_start + i]);
                    const payload = try self.buildComponentPayload(world, locals, arg, arena_alloc);
                    ids[i] = payload.cid;
                    payloads[i] = payload.bytes;
                }
                try dbuf.commands.append(dbuf.gpa, .{ .spawn = .{ .component_ids = ids, .payloads = payloads } });
                return Value{ .unit = {} };
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

/// Whether every per-rule field filter passes for `(chunk, slot)` (M0.8 E3-D,
/// D-S4-multifilter): flat-AND over the rule's `field_filters`. Trivially
/// true for a filter-free rule.
fn allFiltersPass(arch: *DynamicArchetype, chunk: *Chunk, filters: []const FieldFilter, slot: u32) bool {
    for (filters) |ff| {
        if (!filterPasses(arch, chunk, ff, slot)) return false;
    }
    return true;
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

/// Map a bridge failure to a typed report kind (M0.8 E3-D): a bridge
/// `TypeMismatch` keeps its identity in the report (the D-S4-ecs-bridge-panic
/// letter — the bridge returns the error, the report carries the kind);
/// every other bridge cause stays the generic UnsupportedExpr. OOM keeps the
/// pre-existing collapse into the counted runtime failure (the bridge write
/// paths do not allocate).
fn bridgeFailureKind(err: anyerror) RuntimeErrorKind {
    return switch (err) {
        error.TypeMismatch => .TypeMismatch,
        else => .UnsupportedExpr,
    };
}

/// Classify a `binaryArith` failure into a typed report kind (M0.8 E3-D,
/// D-S4-runtime-report). Integer `/` and `%` fail on a zero divisor
/// (DivisionByZero) or on `i64.min / -1` (IntegerOverflow — the only other
/// null path of `intDiv`); checked `+`/`-`/`*` fail on overflow only. Any
/// operand-shape mismatch that slipped past the resolver stays the generic
/// UnsupportedExpr.
fn arithFailureKind(op: ast_mod.BinaryOp, a: Value, b: Value) RuntimeErrorKind {
    if (a == .int_ and b == .int_) {
        return switch (op) {
            .div, .rem => if (b.int_ == 0) .DivisionByZero else .IntegerOverflow,
            .add, .sub, .mul => .IntegerOverflow,
            else => .UnsupportedExpr,
        };
    }
    return .UnsupportedExpr;
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
    literals: *std.ArrayListUnmanaged([*]u8),
) !void {
    const name = ast.strings.slice(decl.name);
    _ = try compileTypeDecl(gpa, ast, &world.registry, bridge, name, decl.fields_start, decl.fields_len, .component, literals);
}

fn compileResource(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    world: *World,
    bridge: *Bridge,
    decl: ast_mod.ResourceDecl,
    literals: *std.ArrayListUnmanaged([*]u8),
) !void {
    const name = ast.strings.slice(decl.name);
    // On a hot-reload re-compile (M0.8 E7) the resource is already registered
    // AND already lives in the resource store with its current value — adding
    // it again would reset it to defaults. Seed the store only on first compile.
    const pre_existing = world.registry.idOf(name) != null;
    const id = try compileTypeDecl(gpa, ast, &world.registry, bridge, name, decl.fields_start, decl.fields_len, .resource, literals);
    if (!pre_existing) {
        const default_bytes = world.registry.componentDefaultBytes(id);
        try world.addResource(gpa, id, default_bytes);
    }
}

/// Registration origin threaded into `compileTypeDecl`: `.resource` unlocks the
/// resource-only `string`/`enum` field kinds (`.component` stays POD-strict).
/// `pub` so the scene cook can drive `compileTypeDecl` against its own registry.
pub const RegKind = enum { component, resource };

/// Register one Etch `component`/`resource` declaration into `registry`,
/// computing its byte layout (`FieldDesc` + size/alignment) and materializing
/// its compile-time default bytes (POD via `evalConst`, resource `string` via
/// an immortal persistent block, resource `enum` via the variant discriminant).
/// Returns the assigned `ComponentId` (or the existing one on a hot-reload
/// re-compile, idempotent). `bridge` records the name→id mapping.
///
/// Operates on a bare `*Registry` — World-free by construction (it never touches
/// archetypes/entities). The interpreter passes `&world.registry`; the M1.0.4
/// scene cook (`src/etch/scene_cook.zig`) reuses it verbatim against its own
/// standalone `Registry` so registration is shared, not duplicated.
pub fn compileTypeDecl(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    registry: *Registry,
    bridge: *Bridge,
    name: []const u8,
    fields_start: u32,
    fields_len: u32,
    reg_kind: RegKind,
    literals: *std.ArrayListUnmanaged([*]u8),
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
        const resolved_name_id = ast.resolveTypeAliasName(tnode.name);
        const tname = ast.strings.slice(resolved_name_id);
        var enum_type_id: u32 = 0;
        const kind = fieldKindFromTypeName(tname, reg_kind) orelse blk: {
            // Enum resource field (M1.0.3 E3): a declared enum type, resource-only
            // (mirrors the `string` gate; components reject enum at the validator).
            // `enum_decls` is not built yet in this pass, so match the AST enum
            // slab directly. The declared enum type's id rides on the FieldDesc.
            if (reg_kind == .resource and findEnumDecl(ast, resolved_name_id) != null) {
                enum_type_id = resolved_name_id;
                break :blk FieldKind.enum_;
            }
            return error.InvalidProgram;
        };
        const align_b = kind.alignBytes();
        if (align_b > max_align) max_align = align_b;
        const off = std.mem.alignForward(usize, size, align_b);
        size = off + kind.sizeBytes();
        try fields.append(gpa, .{
            .name = ast.strings.slice(f.name),
            .offset = @intCast(off),
            .kind = kind,
            .enum_type_name_id = enum_type_id,
        });
    }
    size = std.mem.alignForward(usize, size, max_align);

    var default_buf: []u8 = try gpa.alloc(u8, size);
    defer gpa.free(default_buf);
    @memset(default_buf, 0);
    f_i = 0;
    while (f_i < fields_len) : (f_i += 1) {
        const f = ast.fields.items[fields_start + f_i];
        const fd = fields.items[f_i];
        const slot = default_buf[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))];
        if (fd.kind == .string_) {
            // Resource `string` default = compile-time literal → an immortal
            // interned block (sentinel refcount): `addResource` copies only the
            // 16-byte `{ptr,len}` slot, no per-instance allocation. No default ⇒
            // slot stays `{ptr=0,len=0}` (the empty string; `default_buf` is
            // zeroed). The block is owned by `literals` and `destroy`'d at the
            // interpreter's `deinit`. Non-literal const string defaults are out
            // of the M1.0.3 surface; they leave the empty-string slot.
            if (!f.default_value.isNone() and ast.exprKind(f.default_value) == .string_lit) {
                const lit = ast.strings.slice(ast.exprData(f.default_value));
                const block = try persistent.allocImmortal(gpa, persistent.type_string, lit.len);
                literals.append(gpa, block) catch |e| {
                    persistent.destroy(gpa, block);
                    return e;
                };
                if (lit.len > 0) @memcpy(block[0..lit.len], lit);
                const ss = persistent.StringSlot{ .ptr = @intFromPtr(block), .len = @intCast(lit.len) };
                @memcpy(slot, std.mem.asBytes(&ss));
            }
            continue;
        }
        if (fd.kind == .enum_) {
            // Enum default = a bare `.variant` shorthand → its declaration-order
            // discriminant (consistent with `EnumValue.variant`). No default ⇒
            // discriminant 0, the first variant (`default_buf` is zeroed).
            if (!f.default_value.isNone() and ast.exprKind(f.default_value) == .tag_path) {
                const variant = ast.exprData(f.default_value);
                if (findEnumDecl(ast, fd.enum_type_name_id)) |edecl| {
                    if (enumVariantIndex(ast, edecl, variant)) |vidx| {
                        const disc: u32 = vidx;
                        @memcpy(slot[0..@sizeOf(u32)], std.mem.asBytes(&disc));
                    }
                }
            }
            continue;
        }
        if (fd.kind == .entity_) {
            // Unassigned `Entity` field = `EntityId.dead` (all-ones), NOT the
            // zeroed slot (which would decode as a live handle `{index:0, gen:0}`).
            // `Entity` fields take no literal default; an assignment in a scene is
            // an entity-name reference resolved at cook (the cross-reference pass),
            // never a value encoded here. Component-only (validator/gate), so this
            // is reached only for components.
            @memset(slot, 0xFF);
            continue;
        }
        if (f.default_value.isNone()) continue;
        const v = evalConst(ast, f.default_value) catch continue;
        try bridge_mod.writeValueAsBytes(fd.kind, slot, v);
    }

    // Idempotent re-registration (M0.8 E7 hot-reload). A second Interpreter
    // compiled on the SAME world — an AST swap, e.g. edit a rule body and
    // re-compile — re-visits the unchanged component/resource decls. Reuse the
    // existing id instead of erroring `DuplicateComponent`, so the live world
    // state (entities, component bytes, resource values) survives the swap.
    // The hot-reload contract is a rule-body edit with the declarations
    // UNCHANGED; a layout-changing reload (archetype migration) is Phase 2+.
    if (registry.idOf(name)) |existing_id| {
        switch (reg_kind) {
            .component => try bridge.mapComponent(gpa, name, existing_id),
            .resource => try bridge.mapResource(gpa, name, existing_id),
        }
        return existing_id;
    }

    const id = try registry.registerComponentRaw(gpa, .{
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

fn fieldKindFromTypeName(name: []const u8, reg_kind: RegKind) ?FieldKind {
    if (std.mem.eql(u8, name, "int")) return .int_;
    if (std.mem.eql(u8, name, "float")) return .float_;
    if (std.mem.eql(u8, name, "bool")) return .bool_;
    if (std.mem.eql(u8, name, "i32")) return .i32_;
    if (std.mem.eql(u8, name, "u32")) return .u32_;
    if (std.mem.eql(u8, name, "f32")) return .f32_;
    if (std.mem.eql(u8, name, "f64")) return .f64_;
    // `string` is resource-only (M1.0.3 E2): components are POD-strict (the
    // validator rejects `string` on them), so this kind is emitted only for the
    // `.resource` origin. Components reaching here with `string` fall to `null`
    // → `error.InvalidProgram` (a validator-passed program never does). Enum
    // field types are not builtin names, so they resolve in `compileTypeDecl`
    // against the AST enum slab (see `findEnumDecl`), not here.
    if (reg_kind == .resource and std.mem.eql(u8, name, "string")) return .string_;
    // `Entity` is component-only (M1.0.6 D-A): the exact mirror of the `string`
    // gate above, opposite origin. A `.entity_` field is a POD 8-byte slot; an
    // unassigned/dangling value is `EntityId.dead`, and an entity→entity reference
    // is resolved by the scene loader's cross-reference pass. Resource→entity refs
    // are a future additive milestone, so this is gated out of resources.
    if (reg_kind == .component and std.mem.eql(u8, name, "Entity")) return .entity_;
    return null;
}

/// The declared `enum` with the given (alias-resolved) interned name, or null
/// — scanned against the AST enum slab so it works in `compileTypeDecl` (pass A,
/// before `enum_decls` is indexed). Mirrors the type-checker's `declaredEnumName`.
fn findEnumDecl(ast: *const AstArena, name: StringId) ?ast_mod.EnumDecl {
    for (ast.enum_decls.items) |d| {
        if (d.name == name) return d;
    }
    return null;
}

/// Declaration-order index of `variant` within `edecl`, or null (free-fn twin
/// of `Interpreter.enumVariantIndexOf`, for the allocator-free compile pass).
fn enumVariantIndex(ast: *const AstArena, edecl: ast_mod.EnumDecl, variant: StringId) ?u32 {
    var i: u32 = 0;
    while (i < edecl.variants_len) : (i += 1) {
        if (ast.enum_variants.items[edecl.variants_start + i].name == variant) return i;
    }
    return null;
}

// ─── when → DNF of archetype-selection terms (M1.0.0) ──────────────────────
//
// `lowerWhen` lowers a `when` clause's structural skeleton to a boolean tree
// of `has` literals over `arch.hasComponent` (the `PredicateNode` pool). The
// archetype set it denotes IS that boolean function. Converting the tree to
// disjunctive normal form — an OR of conjunctive terms, each a set of positive
// literals (`with`) and negative literals (`without`) — maps each term onto
// one Tier-0 `DynamicQuery`, the rule's selection being the union of the
// terms. DNF ≡ the original formula, so the archetype set is provably
// identical to the pre-M1.0.0 `evalPredicate` walk: differential parity is
// preserved by construction.

/// One conjunctive term of a `when` DNF: components the archetype must contain
/// (`with`) and must not (`without`). Owns growable id sets during the build;
/// the final slices are dup'd into the `DynamicQuery`.
const DnfTerm = struct {
    with: std.ArrayListUnmanaged(ComponentId) = .empty,
    without: std.ArrayListUnmanaged(ComponentId) = .empty,

    fn deinit(self: *DnfTerm, gpa: std.mem.Allocator) void {
        self.with.deinit(gpa);
        self.without.deinit(gpa);
    }

    fn addUnique(list: *std.ArrayListUnmanaged(ComponentId), gpa: std.mem.Allocator, cid: ComponentId) !void {
        for (list.items) |existing| if (existing == cid) return;
        try list.append(gpa, cid);
    }

    fn clone(self: DnfTerm, gpa: std.mem.Allocator) !DnfTerm {
        var out: DnfTerm = .{};
        errdefer out.deinit(gpa);
        try out.with.appendSlice(gpa, self.with.items);
        try out.without.appendSlice(gpa, self.without.items);
        return out;
    }

    /// Fold `other` into `self` (set union of both id sets).
    fn mergeFrom(self: *DnfTerm, gpa: std.mem.Allocator, other: DnfTerm) !void {
        for (other.with.items) |cid| try addUnique(&self.with, gpa, cid);
        for (other.without.items) |cid| try addUnique(&self.without, gpa, cid);
    }

    /// A term requiring and forbidding the same component matches nothing.
    fn satisfiable(self: DnfTerm) bool {
        for (self.with.items) |w| {
            for (self.without.items) |wo| if (w == wo) return false;
        }
        return true;
    }
};

const Dnf = std.ArrayListUnmanaged(DnfTerm);

fn freeDnf(gpa: std.mem.Allocator, dnf: *Dnf) void {
    for (dnf.items) |*t| t.deinit(gpa);
    dnf.deinit(gpa);
}

/// Convert the `PredicateNode` subtree at `root` to DNF. `negated` threads
/// De Morgan through the recursion so `not` over `and`/`or`/`has` stays
/// correct even for the parenthesised shapes the parser accepts beyond the
/// flat EBNF grammar. `has` is the only literal — every structural leaf
/// (`has T`, field-filter, positive tag → `has TagSet`) lowers to a `has`
/// node; non-structural leaves contribute `no_child` and never reach here.
fn dnfFromPool(gpa: std.mem.Allocator, pool: []const PredicateNode, root: u32, negated: bool) error{OutOfMemory}!Dnf {
    const node = pool[root];
    switch (node.kind) {
        .has => {
            var term: DnfTerm = .{};
            errdefer term.deinit(gpa);
            if (negated) {
                try term.without.append(gpa, node.component_id);
            } else {
                try term.with.append(gpa, node.component_id);
            }
            var dnf: Dnf = .empty;
            errdefer freeDnf(gpa, &dnf);
            try dnf.append(gpa, term);
            return dnf;
        },
        .not_ => return try dnfFromPool(gpa, pool, node.lhs, !negated),
        .and_, .or_ => {
            // and → cross-product; or → concat. `not` swaps them (De Morgan:
            // ¬(a∧b)=¬a∨¬b, ¬(a∨b)=¬a∧¬b).
            const cross = (node.kind == .and_) != negated;
            var lhs = try dnfFromPool(gpa, pool, node.lhs, negated);
            defer freeDnf(gpa, &lhs);
            var rhs = try dnfFromPool(gpa, pool, node.rhs, negated);
            defer freeDnf(gpa, &rhs);
            if (cross) return try crossProduct(gpa, lhs, rhs);
            var out: Dnf = .empty;
            errdefer freeDnf(gpa, &out);
            for (lhs.items) |t| try out.append(gpa, try t.clone(gpa));
            for (rhs.items) |t| try out.append(gpa, try t.clone(gpa));
            return out;
        },
    }
}

/// Cartesian product of two DNFs: every `a`-term merged with every `b`-term.
fn crossProduct(gpa: std.mem.Allocator, lhs: Dnf, rhs: Dnf) !Dnf {
    var out: Dnf = .empty;
    errdefer freeDnf(gpa, &out);
    for (lhs.items) |a| {
        for (rhs.items) |b| {
            var merged = try a.clone(gpa);
            errdefer merged.deinit(gpa);
            try merged.mergeFrom(gpa, b);
            try out.append(gpa, merged);
        }
    }
    return out;
}

/// Build a rule's archetype selection: one `DynamicQuery` per satisfiable DNF
/// term of its `when` predicate (M1.0.0). `predicate_root == null` (no
/// structural predicate — a negative-tag-only / resource-only `when`) yields a
/// single empty term matching every archetype, with the per-entity filters
/// carrying the selection. Unsatisfiable terms (`has T` ∧ `not has T`) are
/// dropped — the rule never matches via that disjunct. Each query dup's its id
/// sets, so the DNF is freed here.
fn buildSelection(gpa: std.mem.Allocator, world: *World, pool: []const PredicateNode, predicate_root: ?u32) ![]DynamicQuery {
    var dnf: Dnf = .empty;
    defer freeDnf(gpa, &dnf);
    if (predicate_root) |root| {
        dnf = try dnfFromPool(gpa, pool, root, false);
    } else {
        try dnf.append(gpa, .{}); // single match-all term
    }

    var queries: std.ArrayListUnmanaged(DynamicQuery) = .empty;
    errdefer {
        for (queries.items) |*q| q.deinit(gpa);
        queries.deinit(gpa);
    }
    // Reserve up front so the append below cannot fail and leak a query.
    try queries.ensureTotalCapacity(gpa, dnf.items.len);
    for (dnf.items) |t| {
        if (!t.satisfiable()) continue;
        const q = try world.queryDynamic(gpa, t.with.items, t.without.items);
        queries.appendAssumeCapacity(q);
    }
    return try queries.toOwnedSlice(gpa);
}

fn compileRule(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    bridge: *Bridge,
    world: *World,
    tag_table: *const tags_mod.TagTable,
    tagset_id: ?ComponentId,
    rule_data: u32,
) !RuleDesc {
    const registry = &world.registry;
    const rule = ast.rule_decls.items[rule_data];

    var pool: std.ArrayListUnmanaged(PredicateNode) = .empty;
    defer pool.deinit(gpa);
    var res_deps: std.ArrayListUnmanaged(ResourceDep) = .empty;
    errdefer res_deps.deinit(gpa);
    var tag_preds: std.ArrayListUnmanaged(TagPredicate) = .empty;
    errdefer {
        for (tag_preds.items) |*tp| tp.deinit(gpa);
        tag_preds.deinit(gpa);
    }
    var changed_filters: std.ArrayListUnmanaged(ComponentId) = .empty;
    errdefer changed_filters.deinit(gpa);
    var field_filters: std.ArrayListUnmanaged(FieldFilter) = .empty;
    errdefer field_filters.deinit(gpa);
    var expr_filters: std.ArrayListUnmanaged(ExprFilter) = .empty;
    errdefer {
        for (expr_filters.items) |ef| gpa.free(ef.fields);
        expr_filters.deinit(gpa);
    }
    var expr_conds: std.ArrayListUnmanaged(NodeId) = .empty;
    errdefer expr_conds.deinit(gpa);
    var resource_expr_filters: std.ArrayListUnmanaged(ResourceExprFilter) = .empty;
    errdefer {
        for (resource_expr_filters.items) |rf| gpa.free(rf.fields);
        resource_expr_filters.deinit(gpa);
    }
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
        .filters = &field_filters,
        .tag_preds = &tag_preds,
        .changed_filters = &changed_filters,
        .expr_filters = &expr_filters,
        .expr_conds = &expr_conds,
        .resource_expr_filters = &resource_expr_filters,
        .gpa = gpa,
        .has_component_ref = &has_component_ref,
    };
    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        const r = try lowerWhen(&lw, rule.when_root);
        // `no_child` means the `when` contributed only non-structural leaves
        // (resource deps, negative tags, bare exprs) — no archetype predicate,
        // so the selection is a single match-all term carried per-entity.
        if (r != PredicateNode.no_child) predicate_root = r;
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

    // M1.0.2 E2 — structural-observer routing (mirrors `event_type` above): the
    // lifecycle kind + the resolved target ComponentId (null for spawn/despawn,
    // or when the component is unregistered — the resolver already reported the
    // malformed cases E12xx). Surface only here; the ObserverRegistry bridge,
    // the per-tick dispatch exclusion, and body execution are E3.
    var observer_kind: ?ast_mod.ObserverKind = null;
    var observer_component: ?ComponentId = null;
    if (ast.observerAnnotation(rule)) |annot| {
        observer_kind = annot.kind.toObserverKind();
        if (ast.observerComponentName(annot)) |comp_name| {
            observer_component = registry.idOf(ast.strings.slice(comp_name));
        }
    }

    // M1.0.0 — the rule's archetype selection (DNF → one DynamicQuery per
    // term). Built only for entity-bound rules; the global / resource-only /
    // event paths never select archetypes, so they keep an empty selection.
    const selection: []DynamicQuery = if (is_entity_bound)
        try buildSelection(gpa, world, pool.items, predicate_root)
    else
        &.{};
    errdefer freeSelection(gpa, selection);

    return .{
        .rule_idx = rule_data,
        .name = rule.name,
        .selection = selection,
        .resource_deps = try res_deps.toOwnedSlice(gpa),
        .field_filters = try field_filters.toOwnedSlice(gpa),
        .tag_predicates = try tag_preds.toOwnedSlice(gpa),
        .entity_param_name = entity_param_name,
        .is_entity_bound = is_entity_bound,
        .event_type = event_type,
        .observer_kind = observer_kind,
        .observer_component = observer_component,
        .changed_filters = try changed_filters.toOwnedSlice(gpa),
        .expr_filters = try expr_filters.toOwnedSlice(gpa),
        .expr_conds = try expr_conds.toOwnedSlice(gpa),
        .resource_expr_filters = try resource_expr_filters.toOwnedSlice(gpa),
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
    filters: *std.ArrayListUnmanaged(FieldFilter),
    tag_preds: *std.ArrayListUnmanaged(TagPredicate),
    changed_filters: *std.ArrayListUnmanaged(ComponentId),
    expr_filters: *std.ArrayListUnmanaged(ExprFilter),
    expr_conds: *std.ArrayListUnmanaged(NodeId),
    resource_expr_filters: *std.ArrayListUnmanaged(ResourceExprFilter),
    gpa: std.mem.Allocator,
    has_component_ref: *bool,
};

/// Capture the field bindings of a component/resource declaration for a §6
/// general filter (M0.8 E4): every declared field's `(name, offset, kind)`
/// resolved through the registry. The declaration is located by name in the
/// AST slab (`is_resource` picks the slab).
fn captureBoundFields(ctx: *LowerWhenCtx, type_name: StringId, id: ComponentId, is_resource: bool) error{ OutOfMemory, InvalidProgram }![]BoundField {
    const ast = ctx.ast;
    var fields_start: u32 = 0;
    var fields_len: u32 = 0;
    var found = false;
    if (is_resource) {
        for (ast.resource_decls.items) |decl| {
            if (decl.name == type_name) {
                fields_start = decl.fields_start;
                fields_len = decl.fields_len;
                found = true;
                break;
            }
        }
    } else {
        for (ast.component_decls.items) |decl| {
            if (decl.name == type_name) {
                fields_start = decl.fields_start;
                fields_len = decl.fields_len;
                found = true;
                break;
            }
        }
    }
    if (!found) return error.InvalidProgram;
    var out: std.ArrayListUnmanaged(BoundField) = .empty;
    errdefer out.deinit(ctx.gpa);
    var f: u32 = 0;
    while (f < fields_len) : (f += 1) {
        const field = ast.fields.items[fields_start + f];
        const fd = ctx.registry.findField(id, ast.strings.slice(field.name)) orelse return error.InvalidProgram;
        try out.append(ctx.gpa, .{ .name = field.name, .offset = fd.offset, .kind = fd.kind });
    }
    return try out.toOwnedSlice(ctx.gpa);
}

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
            // One filter per `has T { … }` clause (M0.8 E3-D,
            // D-S4-multifilter) — append, never overwrite.
            try ctx.filters.append(ctx.gpa, .{
                .component_id = id,
                .field_offset = fd.offset,
                .field_kind = fd.kind,
                .expected_value = v,
            });
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
        .has_expr_filter => {
            // `has T { expression }` (M0.8 E4 — §6 general filter): the same
            // `has T` archetype predicate as the narrow form, plus a
            // per-entity expression guard with T's fields bound (fields-only
            // scope, resolver-checked).
            const tname = ast.strings.slice(node.type_name);
            const id = ctx.bridge.componentIdOf(tname) orelse return error.InvalidProgram;
            const fields = try captureBoundFields(ctx, node.type_name, id, false);
            errdefer ctx.gpa.free(fields);
            try ctx.expr_filters.append(ctx.gpa, .{ .component_id = id, .expr = node.filter_value, .fields = fields });
            const idx: u32 = @intCast(ctx.pool.items.len);
            try ctx.pool.append(ctx.gpa, .{ .kind = .has, .component_id = id });
            ctx.has_component_ref.* = true;
            return idx;
        },
        .resource_filter => {
            // `resource T { expression }` (M0.8 E4 — §6): a resource dep plus
            // a rule-level expression gate with T's fields bound.
            const tname = ast.strings.slice(node.type_name);
            const rid = ctx.bridge.resourceIdOf(tname) orelse return error.InvalidProgram;
            try ctx.res_deps.append(ctx.gpa, .{ .resource_id = rid, .must_be_changed = false });
            const fields = try captureBoundFields(ctx, node.type_name, rid, true);
            errdefer ctx.gpa.free(fields);
            try ctx.resource_expr_filters.append(ctx.gpa, .{ .resource_id = rid, .expr = node.filter_value, .fields = fields });
            return PredicateNode.no_child;
        },
        .expr_cond => {
            // Bare expression condition (M0.8 E4 — the §6 last arm). No
            // archetype contribution; evaluated per entity (entity-bound
            // rule) or once per tick (global rule).
            try ctx.expr_conds.append(ctx.gpa, node.filter_value);
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

// ── M1.0.3 E2 — resource `string` fields ──────────────────────────────────

/// Read a resource `string` field through the bridge and assert its bytes.
/// `string_persistent` with `ptr == 0` is the empty string.
fn expectResourceStringField(
    world: *World,
    res_name: []const u8,
    field_name: []const u8,
    expected: []const u8,
) !void {
    const rid = world.registry.idOf(res_name).?;
    const v = try bridge_mod.Bridge.readResourceField(&world.registry, &world.resources, rid, field_name);
    const got: []const u8 = switch (v) {
        .string_persistent => |s| if (s.len == 0) "" else @as([*]const u8, @ptrFromInt(s.ptr))[0..s.len],
        else => return error.TestExpectedStringValue,
    };
    try std.testing.expectEqualStrings(expected, got);
}

test "resource string field compiles and reads its default (M1.0.3 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The string default `"intro"` materializes as an immortal interned block;
    // the rule reads it in-body (`get(S).name`) and stores its byte length, so a
    // wrong read would surface as a wrong `len`.
    const source =
        \\resource S {
        \\  name: string = "intro"
        \\  n: int = 0
        \\}
        \\rule touch()
        \\  when resource S
        \\{
        \\  let s = get(S).name
        \\  get_mut(S).n = s.len()
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
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // The default reads back as "intro", and the in-body read fed `n = 5`.
    try expectResourceStringField(&world, "S", "name", "intro");
    const rid = world.registry.idOf("S").?;
    const bytes = world.resources.getResource(rid).?;
    const n_field = world.registry.findField(rid, "n").?;
    var n: i64 = 0;
    @memcpy(std.mem.asBytes(&n), bytes[n_field.offset .. n_field.offset + @sizeOf(i64)]);
    try std.testing.expectEqual(@as(i64, 5), n);
}

test "resource string field with no default reads empty (M1.0.3 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // No default ⇒ the slot stays `{ptr=0,len=0}` — the empty string.
    var pr = try parser_mod.parse(gpa, "resource S { name: string }");
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

    try expectResourceStringField(&world, "S", "name", "");
}

test "resource string field is mutable and the previous value is released (M1.0.3 E2)" {
    // An allocation-tracking allocator (backed by the leak-detecting testing
    // allocator) confirms two things: (a) every overwrite releases the previous
    // non-immortal value — proven by a `free_count` increase across writes 2→3;
    // (b) no leak across multiple writes — proven by the backing allocator at
    // test end (an un-decref'd previous value would leak and fail the test).
    var counting = weld_core.testing.alloc_counting.CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    var world = World.init();
    defer world.deinit(gpa);

    // Each tick writes a fixed non-default value. Tick 1 overwrites the immortal
    // default (decref no-op); ticks 2..N overwrite the previous refcounted block
    // (decref → free). Re-reading returns the written value.
    const source =
        \\resource S { name: string = "intro" }
        \\rule advance()
        \\  when resource S
        \\{
        \\  get_mut(S).name = "boss_arena"
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

    // Tick 1: overwrite immortal default (no string free yet).
    _ = try interp.runFor(&world, 1);
    try expectResourceStringField(&world, "S", "name", "boss_arena");
    const after_first = counting.snapshot();

    // Tick 2: overwrite the refcounted value from tick 1 → its block is freed.
    _ = try interp.runFor(&world, 1);
    const after_second = counting.snapshot();
    try std.testing.expect(after_second.free_count > after_first.free_count);
    try expectResourceStringField(&world, "S", "name", "boss_arena");
}

// ── M1.0.3 E3 — resource enum fields ──────────────────────────────────────

/// Read a resource enum field's raw `u32` discriminant and assert its value.
fn expectResourceEnumDiscriminant(
    world: *World,
    res_name: []const u8,
    field_name: []const u8,
    expected: u32,
) !void {
    const rid = world.registry.idOf(res_name).?;
    const fd = world.registry.findField(rid, field_name).?;
    const bytes = world.resources.getResource(rid).?;
    var disc: u32 = 0;
    @memcpy(std.mem.asBytes(&disc), bytes[fd.offset .. fd.offset + @sizeOf(u32)]);
    try std.testing.expectEqual(expected, disc);
}

test "resource enum field compiles, reads its default, and is mutable (M1.0.3 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `.normal` is declaration-order index 1; `.hard` is 2.
    const source =
        \\enum Difficulty { easy, normal, hard }
        \\resource S { diff: Difficulty = .normal }
        \\rule advance()
        \\  when resource S
        \\{
        \\  let cur = get(S).diff
        \\  get_mut(S).diff = .hard
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

    // Default materialized as `.normal` (index 1) before any rule runs.
    try expectResourceEnumDiscriminant(&world, "S", "diff", 1);

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // The in-body read (`get(S).diff`) ran, then `.hard` (index 2) was written.
    try expectResourceEnumDiscriminant(&world, "S", "diff", 2);
}

test "resource enum field with no default reads the first variant (M1.0.3 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // No default ⇒ discriminant 0 ⇒ the first declared variant (`easy`).
    const source =
        \\enum Difficulty { easy, normal, hard }
        \\resource S { diff: Difficulty }
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

    try expectResourceEnumDiscriminant(&world, "S", "diff", 0);
}

test "GameState end-state program mutates string + enum + int end-to-end (M1.0.3)" {
    // The brief's flagship resource: `string` + enum + `int` fields mutated in
    // one rule body, leak-free. Runs under the leak-detecting allocator.
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\enum Difficulty { easy, normal, hard }
        \\@state
        \\resource GameState {
        \\  current_level: string = "intro"
        \\  difficulty: Difficulty = .normal
        \\  player_count: int = 0
        \\}
        \\rule advance(dt: float)
        \\  when resource GameState
        \\{
        \\  let mut gs = get_mut(GameState)
        \\  gs.current_level = "boss_arena"
        \\  gs.difficulty = .hard
        \\  gs.player_count += 1
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
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // current_level == "boss_arena", difficulty == .hard (2), player_count == 1.
    try expectResourceStringField(&world, "GameState", "current_level", "boss_arena");
    try expectResourceEnumDiscriminant(&world, "GameState", "difficulty", 2);
    const rid = world.registry.idOf("GameState").?;
    const bytes = world.resources.getResource(rid).?;
    const pc = world.registry.findField(rid, "player_count").?;
    var n: i64 = 0;
    @memcpy(std.mem.asBytes(&n), bytes[pc.offset .. pc.offset + @sizeOf(i64)]);
    try std.testing.expectEqual(@as(i64, 1), n);
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

test "runProgram return inside a closure exits the closure only (M0.8 closures)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `return` inside a closure block body exits the CLOSURE — it becomes
    // the call's value — and the enclosing rule body CONTINUES (the E2
    // forward note executed at E3-C tranche 6: the closure call boundary
    // consumes `returning`, mirroring `callFn`/`callMethod`). Before the
    // boundary-consume fix the signal leaked: `v` bound unit and the
    // post-call assignment never ran (out stayed 0).
    const source =
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let pick = |x: int| {
        \\    if x > 3 {
        \\      return 40
        \\    }
        \\    x
        \\  }
        \\  let v = pick(7)
        \\  entity.get_mut(Acc).out = v + 2
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
    // pick(7): the `return 40` exits the closure; the rule continues → 42.
    try std.testing.expectEqual(@as(i64, 42), out);
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
    // method on `Range<T>` dispatches + runs type-erased: `lower()` on
    // `Range { min: 2, max: 8 }` returns `self.min` → out = 2. Generic
    // codegen stays UnsupportedConstruct (so this is interp-reference, not a
    // codegen differential — consistent with block 4).
    //
    // (M1.0.1 wire-in: the method previously compared the generic `T`
    // (`v >= self.min`), which the M0.8 minimal subset rejects — comparison
    // requires matching primitive operands (`types.zig` §`.eq/.lt/...`), and an
    // unbounded `T` is not a primitive. Rewritten to a generic field accessor,
    // which is the delivered generic-dispatch capability this test exercises.)
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try parser_mod.parse(gpa,
        \\struct Range<T> { min: T  max: T }
        \\impl<T> Range<T> {
        \\  fn lower(self) -> T { self.min }
        \\}
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let rng = Range { min: 2, max: 8 }
        \\  entity.get_mut(C).out = rng.lower()
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

test "runProgram Set.new/Set.from + insert dedup, contains, len (M0.8 E3-C tranche 3bis)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The minimal §15 subset on a set: `Set.from([1, 2, 2, 3])` dedups to
    // {1, 2, 3}; `insert(4)` appends, `insert(2)` is a no-op (scan-skip-or-
    // append); `contains` hits on 2 and misses on 9; `len` counts 4 and the
    // annotated `Set.new()` counts 0. out = 4 * 1000 + 0 * 100 + 10 + 0.
    const source =
        \\component Acc { out: int = 0 }
        \\rule set_ops(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let e: Set<int> = Set.new()
        \\  let mut s = Set.from([1, 2, 2, 3])
        \\  s.insert(4)
        \\  s.insert(2)
        \\  let mut probe = 0
        \\  if s.contains(2) { probe += 10 }
        \\  if s.contains(9) { probe += 1 }
        \\  entity.get_mut(Acc).out = s.len() * 1000 + e.len() * 100 + probe
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
    try std.testing.expectEqual(@as(i64, 4010), total);
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
    // (M1.0.1 wire-in: the accessor was named `get`, a reserved ECS builtin
    // keyword — `fn get(...)` is a parse error. Renamed to `value`; the subject
    // under test is the `mut self` mutation, not the accessor's name.)
    const source =
        \\struct Counter { n: int = 0 }
        \\impl Counter {
        \\  fn bump(mut self, by: int) { self.n += by }
        \\  fn value(self) -> int { self.n }
        \\}
        \\component Acc { out: int = 0 }
        \\rule run(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut c = Counter { n: 10 }
        \\  c.bump(5)
        \\  entity.get_mut(Acc).out = c.value()
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

test "@on_event(T) fires exactly once per emit T in the tick (M1.0.2 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Three `emit Damage` in one producer tick → the `@on_event(Damage)`
    // observer body must run exactly three times that tick (once per event,
    // `runObserver` iterating the per-tick store), accumulating amount 1 each
    // → Tally.total == 3. Catches both under-firing (< 3) and over-firing
    // (> 3, e.g. a stale re-delivery).
    const source =
        \\event Damage { amount: i32 = 0 }
        \\resource Tally { total: i32 = 0 }
        \\rule deal() {
        \\  emit Damage { amount: 1 }
        \\  emit Damage { amount: 1 }
        \\  emit Damage { amount: 1 }
        \\}
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

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // Three events enqueued this tick, three observer fires → total == 3.
    const dmg_id = pr.ast.strings.find("Damage").?;
    try std.testing.expectEqual(@as(usize, 3), interp.events.count(dmg_id));
    const tally_id = world.registry.idOf("Tally").?;
    const bytes = world.resources.getResource(tally_id).?;
    var total: i32 = 0;
    @memcpy(std.mem.asBytes(&total), bytes[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 3), total);
}

test "@on_event discriminates event types (M1.0.2 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // One producer emits both Alpha and Beta in a tick. `@on_event(Alpha)` must
    // fire only on Alpha, `@on_event(Beta)` only on Beta — each counter lands at
    // exactly 1. If the type discrimination in `runObserver` were broken, a
    // counter would reach 2 (the observer firing on the other type too).
    const source =
        \\event Alpha { v: i32 = 0 }
        \\event Beta { v: i32 = 0 }
        \\resource CountA { n: i32 = 0 }
        \\resource CountB { n: i32 = 0 }
        \\rule emitAB() {
        \\  emit Alpha { v: 1 }
        \\  emit Beta { v: 1 }
        \\}
        \\@on_event(Alpha)
        \\rule onA() when resource CountA {
        \\  let c = get_mut(CountA)
        \\  c.n += 1
        \\}
        \\@on_event(Beta)
        \\rule onB() when resource CountB {
        \\  let c = get_mut(CountB)
        \\  c.n += 1
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
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // onA fired once (the single Alpha), onB once (the single Beta) — neither
    // crossed to the other type.
    var a: i32 = 0;
    var b: i32 = 0;
    @memcpy(std.mem.asBytes(&a), world.resources.getResource(world.registry.idOf("CountA").?).?[0..@sizeOf(i32)]);
    @memcpy(std.mem.asBytes(&b), world.resources.getResource(world.registry.idOf("CountB").?).?[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), a);
    try std.testing.expectEqual(@as(i32, 1), b);
}

test "event emitted earlier in the tick reaches a later-declared @on_event (M1.0.2 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The producer is declared (and so runs) before the `@on_event(Ping)`
    // consumer. The event it emits must reach the consumer the SAME tick — after
    // exactly one tick Seen.n == 7 (not 0, which a next-tick or no delivery would
    // leave). Proves same-tick, in-order delivery up to the live store head.
    const source =
        \\event Ping { v: i32 = 0 }
        \\resource Seen { n: i32 = 0 }
        \\rule producer() { emit Ping { v: 7 } }
        \\@on_event(Ping)
        \\rule consumer() when resource Seen {
        \\  let s = get_mut(Seen)
        \\  s.n += event.v
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
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    var seen: i32 = 0;
    @memcpy(std.mem.asBytes(&seen), world.resources.getResource(world.registry.idOf("Seen").?).?[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 7), seen);
}

test "event string payload survives to drain and not past tick boundary (M1.0.2 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // An `event` carries a non-POD `string` field (memory-model §6.7 — events
    // are frame-arena struct-messages, POD-strict is component-only; the
    // type-checker accepts this since the M1.0.2 event-field fix). The producer
    // sets the string in `emit`; the `@on_event(Note)` observer reads it in its
    // body the SAME tick via `event.msg.len()` (the supported string op) → the
    // 5-byte "ping!" accumulates 5 into Sink. The per-tick EventStore resets at
    // the tick boundary: a second tick re-delivers only the fresh event (Sink
    // 5 → 10, not 15), and the store holds exactly one Note each tick.
    const source =
        \\event Note { msg: string }
        \\resource Sink { n: int = 0 }
        \\rule announce() { emit Note { msg: "ping!" } }
        \\@on_event(Note)
        \\rule listen() when resource Sink {
        \\  let s = get_mut(Sink)
        \\  s.n += event.msg.len()
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
    // Key assertion for the M1.0.2 event-field fix: a `string` event field
    // type-checks clean (was rejected by the POD gate before the fix).
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const note_id = pr.ast.strings.find("Note").?;
    const msg_id = pr.ast.strings.find("msg").?;
    const sink_id = world.registry.idOf("Sink").?;

    // Tick 1: the string is readable in the observer body the same tick.
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    var n: i64 = 0;
    @memcpy(std.mem.asBytes(&n), world.resources.getResource(sink_id).?[0..@sizeOf(i64)]);
    try std.testing.expectEqual(@as(i64, 5), n); // "ping!".len() read in-body

    // The payload bytes survived to the drain intact (not just a non-null
    // length): inspect the single queued event's `msg` field directly.
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(note_id));
    var found_msg = false;
    for (interp.events.list.items) |ev| {
        if (ev.type_name != note_id) continue;
        for (ev.fields.items) |f| {
            if (f.name == msg_id) {
                found_msg = true;
                try std.testing.expectEqualStrings("ping!", interp.stringBytes(f.value).?);
            }
        }
    }
    try std.testing.expect(found_msg);

    // Tick 2: the EventStore reset at the boundary — only the fresh event is
    // delivered (no stale re-delivery of tick 1's Note), so Sink is 10 not 15,
    // and the store again holds exactly one Note.
    _ = try interp.runFor(&world, 1);
    @memcpy(std.mem.asBytes(&n), world.resources.getResource(sink_id).?[0..@sizeOf(i64)]);
    try std.testing.expectEqual(@as(i64, 10), n);
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(note_id));
}

// ── M1.0.2 E2 — observer-surface validation test helpers ──

/// Parse + type-check `source` and report whether any diagnostic carries
/// `code` (M1.0.2 E2 observer-surface validation tests). Asserts the parse is
/// clean — the observer programs under test are syntactically valid; their
/// errors are semantic (caught by the type-checker).
fn observerProgramHasCode(gpa: std.mem.Allocator, source: []const u8, code: anytype) !bool {
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    for (diags.items) |d| {
        if (d.code == code) return true;
    }
    return false;
}

/// Parse + type-check `source` and return the diagnostic count (M1.0.2 E2 —
/// positive control: a well-formed observer program reports zero).
fn observerProgramDiagCount(gpa: std.mem.Allocator, source: []const u8) !usize {
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    return diags.items.len;
}

test "observer annotation signature mismatch is rejected (M1.0.2 E2)" {
    const gpa = std.testing.allocator;
    // `@on_removed(Poisoned)` without the required `old: Poisoned` param — the
    // shape must be `(entity: Entity, old: Poisoned)`. → E1208.
    try std.testing.expect(try observerProgramHasCode(gpa,
        \\component Poisoned { elapsed: int = 0 }
        \\@on_removed(Poisoned)
        \\rule r(entity: Entity) {}
    , .observer_signature_mismatch));
    // `@on_spawned` with an extra param — the shape must be exactly
    // `(entity: Entity)`. → E1208.
    try std.testing.expect(try observerProgramHasCode(gpa,
        \\@on_spawned
        \\rule s(entity: Entity, extra: int) {}
    , .observer_signature_mismatch));
    // `@on_added(Health)` with `value` typed `int` instead of the component T —
    // the shape must be `(entity: Entity, value: Health)`. → E1208.
    try std.testing.expect(try observerProgramHasCode(gpa,
        \\component Health { current: int = 0 }
        \\@on_added(Health)
        \\rule a(entity: Entity, value: int) {}
    , .observer_signature_mismatch));
}

test "observer annotation requires a component type (M1.0.2 E2)" {
    const gpa = std.testing.allocator;
    // `Foo` is a declared struct, NOT a component → the lifecycle type T is
    // invalid. → E1209 (and no cascading E1208). Uses `@on_removed` (binding
    // name `old`) because `@on_added`'s frozen binding name `component` is a
    // reserved keyword — pending a Claude.ai ruling (see § Blockers).
    try std.testing.expect(try observerProgramHasCode(gpa,
        \\struct Foo { x: int = 0 }
        \\@on_removed(Foo)
        \\rule r(entity: Entity, old: Foo) {}
    , .observer_component_invalid));
}

test "observer rule rejects when clause and conflicting lifecycle annotations (M1.0.2 E2)" {
    const gpa = std.testing.allocator;
    // A `when` clause on an observer rule — the lifecycle component type is the
    // sole trigger; observers do not iterate entities. → E1215. (`@on_removed`
    // binding `old`; `@on_added`'s `component` binding is keyword-blocked.)
    try std.testing.expect(try observerProgramHasCode(gpa,
        \\component Health { current: int = 0 }
        \\@on_removed(Health)
        \\rule r(entity: Entity, old: Health) when entity has Health {}
    , .observer_rule_conflict));
    // Two lifecycle annotations on one rule. → E1215.
    try std.testing.expect(try observerProgramHasCode(gpa,
        \\component Health { current: int = 0 }
        \\@on_removed(Health)
        \\@on_replaced(Health)
        \\rule r(entity: Entity, old: Health) {}
    , .observer_rule_conflict));
}

test "well-formed observer rules of all five kinds type-check clean (M1.0.2 E2)" {
    const gpa = std.testing.allocator;
    // Positive control: each lifecycle kind with its exact required shape — no
    // observer diagnostic should fire (guards against over-rejection). `@on_added`
    // binds `value` (not `component`, a reserved keyword — M1.0.2 E2 ruling,
    // option a); the others bind `entity` / `old` / `new`.
    const n = try observerProgramDiagCount(gpa,
        \\component Health { current: int = 0 }
        \\@on_added(Health)
        \\rule added(entity: Entity, value: Health) {}
        \\@on_removed(Health)
        \\rule removed(entity: Entity, old: Health) {}
        \\@on_replaced(Health)
        \\rule replaced(entity: Entity, old: Health, new: Health) {}
        \\@on_spawned
        \\rule spawned(entity: Entity) {}
        \\@on_despawned
        \\rule despawned(entity: Entity) {}
    );
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "@on_added(T) fires at flush with entity + value bound (M1.0.2 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `@on_added(Health)` reads the bound `value.current` and emits it. The
    // observer fires at the Tier-0 command-buffer flush — not during any rule —
    // so the emitted event lands in the interp's event store, observable here.
    const source =
        \\component Marker { tag: i32 = 0 }
        \\component Health { current: i32 = 0 }
        \\event Fired { v: i32 = 0 }
        \\@on_added(Health)
        \\rule on_health_added(entity: Entity, value: Health) {
        \\  emit Fired { v: value.current }
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
    try interp.bindToWorld(&world);

    const marker = world.registry.idOf("Marker").?;
    const health = world.registry.idOf("Health").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{marker});

    // Add Health (current = 42) via a Tier-0 command + observer dispatch.
    var v42: i32 = 42;
    const c: command_buffer_mod.Command = .{ .add_component = .{ .entity = e, .component_id = health, .bytes = std.mem.asBytes(&v42) } };
    try observers_mod.applyWithObservers(c, &world.observer_registry, &world, gpa);

    // The observer fired once, reading value.current == 42 and emitting Fired.
    const fired_id = pr.ast.strings.find("Fired").?;
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(fired_id));
    const v_id = pr.ast.strings.find("v").?;
    var seen: i64 = -1;
    for (interp.events.list.items) |ev| {
        if (ev.type_name != fired_id) continue;
        for (ev.fields.items) |f| {
            if (f.name == v_id) seen = f.value.int_;
        }
    }
    try std.testing.expectEqual(@as(i64, 42), seen);
}

test "@on_removed(T) binds the correct old value (M1.0.2 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\component Keep { k: i32 = 0 }
        \\component Poison { dmg: i32 = 0 }
        \\event Cleared { d: i32 = 0 }
        \\@on_removed(Poison)
        \\rule on_poison_removed(entity: Entity, old: Poison) {
        \\  emit Cleared { d: old.dmg }
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
    try interp.bindToWorld(&world);

    const keep = world.registry.idOf("Keep").?;
    const poison = world.registry.idOf("Poison").?;
    var kv: i32 = 0;
    var dv: i32 = 13;
    const e = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{ keep, poison }, &[_][]const u8{ std.mem.asBytes(&kv), std.mem.asBytes(&dv) });

    // Remove Poison: the on_remove observer fires PRE-apply, `old` bound to the
    // live (pre-removal) value.
    const c: command_buffer_mod.Command = .{ .remove_component = .{ .entity = e, .component_id = poison } };
    try observers_mod.applyWithObservers(c, &world.observer_registry, &world, gpa);

    const cleared_id = pr.ast.strings.find("Cleared").?;
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(cleared_id));
    const d_id = pr.ast.strings.find("d").?;
    var seen: i64 = -1;
    for (interp.events.list.items) |ev| {
        if (ev.type_name != cleared_id) continue;
        for (ev.fields.items) |f| {
            if (f.name == d_id) seen = f.value.int_;
        }
    }
    try std.testing.expectEqual(@as(i64, 13), seen); // the pre-removal dmg
}

test "@on_spawned and @on_despawned fire on spawn/despawn (M1.0.2 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\component Health { current: i32 = 0 }
        \\event Spawned { tick: i32 = 0 }
        \\event Despawned { tick: i32 = 0 }
        \\@on_spawned
        \\rule on_spawn(entity: Entity) { emit Spawned { tick: 1 } }
        \\@on_despawned
        \\rule on_despawn(entity: Entity) { emit Despawned { tick: 1 } }
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
    try interp.bindToWorld(&world);

    const health = world.registry.idOf("Health").?;

    // Spawn (with Health) → on_spawned fires.
    var hv: i32 = 5;
    const spawn_cmd: command_buffer_mod.Command = .{ .spawn = .{ .component_ids = &[_]ComponentId{health}, .payloads = &[_][]const u8{std.mem.asBytes(&hv)} } };
    try observers_mod.applyWithObservers(spawn_cmd, &world.observer_registry, &world, gpa);

    // Despawn an existing entity → on_despawned fires (before destruction).
    const victim = try world.spawnDynamic(gpa, &[_]ComponentId{health});
    const despawn_cmd: command_buffer_mod.Command = .{ .despawn = .{ .entity = victim } };
    try observers_mod.applyWithObservers(despawn_cmd, &world.observer_registry, &world, gpa);

    try std.testing.expectEqual(@as(usize, 1), interp.events.count(pr.ast.strings.find("Spawned").?));
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(pr.ast.strings.find("Despawned").?));
}

test "observer body structural mutation is deferred — no recursion (M1.0.2 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The `@on_added(Health)` body issues a tag mutation. It must NOT apply
    // re-entrantly during the current flush — it routes to the registry's
    // deferred buffer and applies at the NEXT flush.
    const source =
        \\tags { fx { marked } }
        \\component Marker { m: i32 = 0 }
        \\component Health { current: i32 = 0 }
        \\@on_added(Health)
        \\rule on_health_added(entity: Entity, value: Health) {
        \\  entity.add_tag(.fx.marked)
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
    try interp.bindToWorld(&world);

    const marker = world.registry.idOf("Marker").?;
    const health = world.registry.idOf("Health").?;
    const tagset = world.registry.idOf("TagSet").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{marker});

    // Flush 1: add Health → on_added fires → body queues a tag mutation into the
    // deferred buffer. The tag is NOT applied this flush (no re-entrancy).
    var cmd = command_buffer_mod.CommandBuffer.init(gpa, &world);
    defer cmd.deinit();
    var hv: i32 = 7;
    try cmd.commands.append(gpa, .{ .add_component = .{ .entity = e, .component_id = health, .bytes = std.mem.asBytes(&hv) } });
    try observers_mod.flushWithObservers(&cmd, &world.observer_registry);

    try std.testing.expect(world.componentBytes(e, tagset) == null); // tag NOT applied yet
    try std.testing.expectEqual(@as(usize, 1), world.observer_registry.deferred.?.commands.items.len);

    // Flush 2 (empty): drains the previous flush's deferred tag mutation.
    try observers_mod.flushWithObservers(&cmd, &world.observer_registry);
    try std.testing.expect(world.componentBytes(e, tagset) != null); // tag applied at next flush
    try std.testing.expectEqual(@as(usize, 0), world.observer_registry.deferred.?.commands.items.len);
}

test "observable behaviour: all five observer kinds + emit/@on_event, deterministic ordered log (M1.0.2 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // One program wiring every reactive mechanism. Each structural observer
    // emits a coded `Log` (the value-bearing kinds encode their bound value so
    // the binding is checked); a normal producer + `@on_event(Ping)` drainer
    // show events coexist. The structural observers fire at the Tier-0 flush;
    // `@on_event` fires in the per-tick dispatch — two distinct contexts.
    const source =
        \\component Marker { m: i32 = 0 }
        \\component Health { current: int = 0 }
        \\event Log { code: int = 0 }
        \\event Ping { n: i32 = 0 }
        \\@on_spawned
        \\rule l_spawn(entity: Entity) { emit Log { code: 1 } }
        \\@on_added(Health)
        \\rule l_add(entity: Entity, value: Health) { emit Log { code: 100 + value.current } }
        \\@on_replaced(Health)
        \\rule l_replace(entity: Entity, old: Health, new: Health) { emit Log { code: 300 + old.current * 10 + new.current } }
        \\@on_removed(Health)
        \\rule l_remove(entity: Entity, old: Health) { emit Log { code: 400 + old.current } }
        \\@on_despawned
        \\rule l_despawn(entity: Entity) { emit Log { code: 5 } }
        \\rule produce_ping() { emit Ping { n: 1 } }
        \\@on_event(Ping)
        \\rule on_ping() { emit Log { code: 6 } }
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
    try interp.bindToWorld(&world);

    const log_id = pr.ast.strings.find("Log").?;
    const code_id = pr.ast.strings.find("code").?;
    const marker = world.registry.idOf("Marker").?;
    const health = world.registry.idOf("Health").?;

    const collectLog = struct {
        fn run(it: *Interpreter, lid: StringId, cid: StringId, buf: *std.ArrayListUnmanaged(i64), g: std.mem.Allocator) !void {
            for (it.events.list.items) |ev| {
                if (ev.type_name != lid) continue;
                for (ev.fields.items) |f| {
                    if (f.name == cid) try buf.append(g, f.value.int_);
                }
            }
        }
    }.run;

    // ── Phase 1: drive the structural lifecycle in order via Tier-0 flushes ──
    // spawn [Marker, Health(current=1)] → on_spawned (1), on_add[Health] (101).
    var mv: i32 = 0;
    var hv1: i64 = 1;
    try observers_mod.applyWithObservers(.{ .spawn = .{
        .component_ids = &[_]ComponentId{ marker, health },
        .payloads = &[_][]const u8{ std.mem.asBytes(&mv), std.mem.asBytes(&hv1) },
    } }, &world.observer_registry, &world, gpa);
    // The spawned entity is the only one holding Health — find it.
    const e = blk: {
        var qit = world.entity_locations.keyIterator();
        while (qit.next()) |k| {
            if (world.componentBytes(k.*, health) != null) break :blk k.*;
        }
        unreachable;
    };
    // replace Health (current=2) → on_replaced old.current=1, new.current=2 → 312.
    var hv2: i64 = 2;
    try observers_mod.applyWithObservers(.{ .add_component = .{ .entity = e, .component_id = health, .bytes = std.mem.asBytes(&hv2) } }, &world.observer_registry, &world, gpa);
    // remove Health → on_removed old.current=2 → 402.
    try observers_mod.applyWithObservers(.{ .remove_component = .{ .entity = e, .component_id = health } }, &world.observer_registry, &world, gpa);
    // despawn → on_despawned (5).
    try observers_mod.applyWithObservers(.{ .despawn = .{ .entity = e } }, &world.observer_registry, &world, gpa);

    var log: std.ArrayListUnmanaged(i64) = .empty;
    defer log.deinit(gpa);
    try collectLog(&interp, log_id, code_id, &log, gpa);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 101, 312, 402, 5 }, log.items);

    // ── Phase 2: a per-tick `@on_event` drain coexists in the same program ──
    // `stepOnce` clears the event store first; produce_ping emits Ping, on_ping
    // drains it same-tick → Log 6.
    var report: RuntimeReport = .{};
    try interp.stepOnce(&world, &report);
    log.clearRetainingCapacity();
    try collectLog(&interp, log_id, code_id, &log, gpa);
    try std.testing.expectEqualSlices(i64, &[_]i64{6}, log.items);
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

/// Write the first `int` (`i64`) field of `comp_id` on `entity` directly —
/// bypassing the interpreter and WITHOUT stamping `changed_tick` (test setup;
/// seeds a per-slot selector / field-filter input). The selector fields are
/// `int`, not `i32`: a `{ field == 1 }` field-filter compares against an `int`
/// literal, and the type-checker rejects an `i32` field as a mismatch (E1211,
/// no implicit coercion). Mirrors `readCounterValue`'s first-field convention.
fn writeI64Field(world: *World, comp_id: ComponentId, entity: CoreEntityId, value: i64) void {
    const loc = world.dynamicLocation(entity).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cidx = arch.componentIndex(comp_id).?;
    const cslot = arch.componentSlot(chunk, cidx, loc.slot);
    const v: i64 = value;
    @memcpy(cslot[0..@sizeOf(i64)], std.mem.asBytes(&v));
}

/// Read the `changed_tick` change-detection sidecar of `comp_id`'s slot on
/// `entity` (test helper) — the value a `changed` filter compares against
/// `last_run_tick` (`engine-ecs-internals.md` §5). Surfaces the spawn-tick
/// stamp and the migration-preserved tick directly, without going through a
/// rule.
fn readChangedTick(world: *World, comp_id: ComponentId, entity: CoreEntityId) Tick {
    const loc = world.dynamicLocation(entity).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cidx = arch.componentIndex(comp_id).?;
    return arch.changedTick(chunk, cidx, loc.slot);
}

test "runProgram changed fires per-slot intra-archetype (M1.0.1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The per-slot case the M0.8 E3 test does NOT cover: there, entity A carried
    // an extra `Marked` component so A and B sat in DIFFERENT archetypes (the
    // `changed` granularity proven was inter-archetype). Here both entities share
    // the SAME archetype {Health, Counter, Sel}; `damage` writes Health only for
    // the slot whose `Sel.on == 1` (a per-entity field-filter, not a structural
    // one), so only that slot's `changed_tick` advances this tick. `react`
    // (`has Health changed`) must fire for the modified slot ALONE.
    const source =
        \\component Health { current: i32 = 100 }
        \\component Counter { value: i32 = 0 }
        \\component Sel { on: int = 0 }
        \\rule damage(entity: Entity)
        \\  when entity has Health and entity has Sel { on == 1 }
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
    const sel_id = world.registry.idOf("Sel").?;
    // Both entities are spawned with the SAME component set → SAME archetype.
    const a = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, sel_id });
    const b = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, sel_id });
    writeI64Field(&world, sel_id, a, 1); // A is selected; B keeps Sel.on == 0.

    // Machine-check the intra-archetype premise: A and B share one archetype, so
    // the differentiation below can only be per-slot, never per-archetype.
    try std.testing.expectEqual(
        world.dynamicLocation(a).?.archetype_idx,
        world.dynamicLocation(b).?.archetype_idx,
    );

    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // A's Health changes every tick → react fires every tick → 3.
    // B's Health never changes (same archetype, untouched slot) → 0.
    try std.testing.expectEqual(@as(i32, 3), readCounterValue(&world, counter_id, a));
    try std.testing.expectEqual(@as(i32, 0), readCounterValue(&world, counter_id, b));
}

test "runProgram changed combined with a field-filter (M1.0.1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A rule carrying BOTH a `changed` filter (`Health changed`) and a value
    // field-filter (`Gate { open == 1 }`) fires only when BOTH hold. `damage`
    // changes Health only for `Active` carriers, so the `changed` half is
    // controllable per entity; the field-filter half gates on `Gate.open`.
    // Three entities isolate the conjunction:
    //   - both:     Active + Gate.open=1 → Health changes AND open==1 → fires.
    //   - nochange: Gate.open=1, no Active → open==1 but Health unchanged → no.
    //   - noopen:   Active + Gate.open=0 → Health changes but open==0 → no.
    const source =
        \\component Health { current: i32 = 100 }
        \\component Counter { value: i32 = 0 }
        \\component Gate { open: int = 0 }
        \\component Active { v: int = 0 }
        \\rule damage(entity: Entity)
        \\  when entity has Health and entity has Active
        \\{
        \\  entity.get_mut(Health).current -= 1
        \\}
        \\rule react(entity: Entity)
        \\  when entity has Counter and entity has Health changed and entity has Gate { open == 1 }
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

    const health_id = world.registry.idOf("Health").?;
    const counter_id = world.registry.idOf("Counter").?;
    const gate_id = world.registry.idOf("Gate").?;
    const active_id = world.registry.idOf("Active").?;
    const both = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, gate_id, active_id });
    const nochange = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, gate_id });
    const noopen = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, gate_id, active_id });
    writeI64Field(&world, gate_id, both, 1);
    writeI64Field(&world, gate_id, nochange, 1);
    // `noopen` keeps Gate.open == 0.

    const report = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    try std.testing.expectEqual(@as(i32, 3), readCounterValue(&world, counter_id, both));
    try std.testing.expectEqual(@as(i32, 0), readCounterValue(&world, counter_id, nochange));
    try std.testing.expectEqual(@as(i32, 0), readCounterValue(&world, counter_id, noopen));
}

test "runProgram changed_tick travels across archetype migration (M1.0.1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The change tick is set at tick 1, a quiet tick (2) follows with no write,
    // THEN the entity is migrated to another archetype. If migration reset the
    // surviving Health column's `changed_tick` to the migration's `current_tick`
    // (2), the assertion below would see 2; preservation keeps it at 1. `react`
    // also must not spuriously re-fire across the boundary.
    const source =
        \\component Health { current: i32 = 100 }
        \\component Counter { value: i32 = 0 }
        \\component Active { on: int = 0 }
        \\rule damage(entity: Entity)
        \\  when entity has Health and entity has Active { on == 1 }
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

    const health_id = world.registry.idOf("Health").?;
    const counter_id = world.registry.idOf("Counter").?;
    const active_id = world.registry.idOf("Active").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id, active_id });
    writeI64Field(&world, active_id, e, 1); // damage writes Health while on == 1.

    // Tick 1: damage writes Health → changed_tick = 1; react fires → Counter 1.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i32, 1), readCounterValue(&world, counter_id, e));
    try std.testing.expectEqual(@as(Tick, 1), readChangedTick(&world, health_id, e));

    // Quiet tick 2: disable damage (on = 0), so Health is NOT written this tick.
    // current_tick advances to 2 while Health.changed_tick stays 1.
    writeI64Field(&world, active_id, e, 0);
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i32, 1), readCounterValue(&world, counter_id, e));
    try std.testing.expectEqual(@as(Tick, 1), readChangedTick(&world, health_id, e));

    // Migrate: drop `Active` → archetype {Health, Counter}. The migration runs at
    // current_tick = 2, but the surviving Health column must keep changed_tick 1.
    try world.removeComponentDynamic(gpa, e, active_id);
    try std.testing.expectEqual(@as(Tick, 1), readChangedTick(&world, health_id, e));

    // Tick 3 after the migration: Health was not re-written, so the preserved
    // stale tick (1) does not satisfy `changed` (1 > last_run 2 is false) →
    // react does not spuriously fire. Counter stays 1.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i32, 1), readCounterValue(&world, counter_id, e));
    try std.testing.expectEqual(@as(Tick, 1), readChangedTick(&world, health_id, e));
}

test "runProgram changed on a freshly-spawned entity uses the spawn tick (M1.0.1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The spawn-tick stamp is applied at slot allocation from `World.current_tick`
    // (`engine-ecs-internals.md` §5). An entity spawned AFTER the world has begun
    // ticking is stamped with the live tick, not the initial tick — and because a
    // `changed` filter is strict (`changed_tick > last_run_tick`), a brand-new,
    // never-modified entity is NOT seen as changed on the next tick its rule runs.
    const source =
        \\component Health { current: i32 = 100 }
        \\component Counter { value: i32 = 0 }
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

    // Tick once with no entities so `current_tick` advances to 1 (react's
    // last_run_tick advances to 1 too).
    _ = try interp.runFor(&world, 1);

    // Spawn NOW, at current_tick == 1: the spawn-tick stamp is 1 (the live tick),
    // not the initial tick (0).
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, counter_id });
    try std.testing.expectEqual(@as(Tick, 1), readChangedTick(&world, health_id, e));

    // Tick 2: react evaluates the fresh entity with last_run_tick 1. Its Health
    // changed_tick is the spawn tick (1), and 1 > 1 is false → react does not
    // fire. A fresh spawn is not, by itself, a change.
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expectEqual(@as(i32, 0), readCounterValue(&world, counter_id, e));
    try std.testing.expectEqual(@as(Tick, 1), readChangedTick(&world, health_id, e));
}

test "async rule suspends at await wait(<d>s) and resumes at the equivalent tick (M1.0.11 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The §9.2 shape: a parameterless async rule sets a resource field, suspends
    // on a Duration `await wait(0.04s)` — 0.04 s × 60 = 2 ticks at the Phase-1
    // fixed 1/60 timestep — then sets it again. The tree-walker is its own
    // runtime; it suspends at the await and resumes on wake (codegen is Phase 2).
    const source =
        \\resource Out { n: int = 0 }
        \\async rule seq()
        \\  when resource Out
        \\{
        \\  let a = get_mut(Out)
        \\  a.n = 1
        \\  await wait(0.04s)
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

    // tick 1: spawn → n=1, suspend at `await wait(0.04s)` (wake at async_tick 3).
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

test "async rule suspends at a statement-head await inside an if body and resumes without re-running the prefix (M1.0.11 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The frame-stack substrate suspends at an `await` NESTED in an `if` body
    // (a depth-2 resume stack: rule body + if-branch) and resumes at the correct
    // cursor. The prefix `emit Beat` inside the if runs EXACTLY ONCE — an
    // `@on_event` observer counts it into `Log.n`; a double-fire on resume would
    // make it 2. `Out.n` traces the sequence 1 → (suspend) → 2 → 3.
    const source =
        \\event Beat { }
        \\resource Out { n: int = 0 }
        \\resource Log { n: int = 0 }
        \\async rule seq()
        \\  when resource Out
        \\{
        \\  let a = get_mut(Out)
        \\  a.n = 1
        \\  if a.n == 1 {
        \\    emit Beat { }
        \\    await wait(0.04s)
        \\    let b = get_mut(Out)
        \\    b.n = 2
        \\  }
        \\  let c = get_mut(Out)
        \\  c.n = 3
        \\}
        \\@on_event(Beat)
        \\rule count_beat()
        \\  when resource Log
        \\{
        \\  let l = get_mut(Log)
        \\  l.n += 1
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
    const log_id = world.registry.idOf("Log").?;

    // tick 1: n=1, enter the if, emit Beat (counted → Log.n=1), suspend at the
    // await (wake at async_tick 3).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, log_id));
    // tick 2: still suspended — no re-run, Log.n stays 1.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, log_id));
    // tick 3: wake fires → resume AFTER the await (b.n=2), leave the if, c.n=3.
    // The `emit Beat` prefix is NOT rerun (Log.n still 1) — no double emit.
    const r3 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r3.runtime_errors);
    try std.testing.expectEqual(@as(i64, 3), readResourceInt(&world, out_id));
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, log_id));
}

test "async rule suspends at a statement-head await inside a loop body and resumes each iteration (M1.0.11 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `loop` body that awaits every iteration and breaks on the third: the
    // loop frame persists across suspension and resumes mid-iteration. `Out.n`
    // counts iterations (1, 2, 3) and settles at 3 after the break — proving the
    // loop frame repeats correctly and `break` unwinds the frame-stack.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule ticker()
        \\  when resource Out
        \\{
        \\  loop {
        \\    let o = get_mut(Out)
        \\    o.n += 1
        \\    if o.n == 3 {
        \\      break
        \\    }
        \\    await wait(0.02s)
        \\  }
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

    // tick 1: iteration 1 (n=1), suspend at await (wake at async_tick 2).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 2: resume → iteration 2 (n=2), suspend again (wake at async_tick 3).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, out_id));
    // tick 3: resume → iteration 3 (n=3), the if fires `break`, the loop exits,
    // the task completes.
    const r3 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r3.runtime_errors);
    try std.testing.expectEqual(@as(i64, 3), readResourceInt(&world, out_id));
    // tick 4: task done — n stays 3.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 3), readResourceInt(&world, out_id));
}

test "async rule suspends at a statement-head await inside a for body and resumes per iteration with iterator state preserved (M1.0.11 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `for i in 0..3` body that awaits every iteration: the for frame persists
    // its range iterator (`next`) across suspension and resumes at the correct
    // element. `Out.n` accumulates `i + 1` per iteration → 1, 3, 6 — the running
    // total proves `i` took 0, 1, 2 in order across the suspends.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule ranger()
        \\  when resource Out
        \\{
        \\  for i in 0..3 {
        \\    let o = get_mut(Out)
        \\    o.n += i + 1
        \\    await wait(0.02s)
        \\  }
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

    // tick 1: i=0 → n += 1 = 1, suspend (wake at async_tick 2).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 2: resume → i=1 → n += 2 = 3, suspend.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 3), readResourceInt(&world, out_id));
    // tick 3: resume → i=2 → n += 3 = 6, suspend.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 6), readResourceInt(&world, out_id));
    // tick 4: resume → iterator exhausted → the `for` ends, the task completes.
    const r4 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r4.runtime_errors);
    try std.testing.expectEqual(@as(i64, 6), readResourceInt(&world, out_id));
    // tick 5: task done — n stays 6.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 6), readResourceInt(&world, out_id));
}

test "async rule suspends inside a try body and a post-resume throw routes to the catch (M1.0.11 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The `try` frame carries its catch handler across a suspension: the body
    // awaits, and the `throw` runs only AFTER the resume — yet it still routes to
    // the `catch` (n goes 1 → 2, and the throw is CAUGHT so runtime_errors == 0).
    const source =
        \\resource Out { n: int = 0 }
        \\async rule guarded()
        \\  when resource Out
        \\{
        \\  try {
        \\    let o = get_mut(Out)
        \\    o.n = 1
        \\    await wait(0.02s)
        \\    throw Error { message: "boom", code: ErrorCode.io_fail }
        \\  } catch e {
        \\    let o2 = get_mut(Out)
        \\    o2.n = 2
        \\  }
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

    // tick 1: enter the try, o.n=1, suspend at the await (the try frame — with its
    // catch handler — persists across the suspend).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 2: resume → the throw fires and routes to the catch → o.n=2. The throw
    // was caught, so it is NOT counted as a runtime error.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.runtime_errors);
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, out_id));
    // tick 3: task done — n stays 2.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, out_id));
}

test "async fn called via await runs to completion across ticks and its return value flows into a let binding (M1.0.11 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `compute` is an `async fn` with an internal `await wait` and a return value.
    // The caller `let x = await compute()` inlines `compute`'s body onto the
    // caller's task (its await suspends the WHOLE task); `compute`'s `return`
    // resolves at the caller's await site, binding `x`. `n` goes 0 → 42.
    const source =
        \\resource Out { n: int = 0 }
        \\async fn compute() -> int {
        \\  await wait(0.02s)
        \\  return 42
        \\}
        \\async rule caller()
        \\  when resource Out
        \\{
        \\  let x = await compute()
        \\  let o = get_mut(Out)
        \\  o.n = x
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

    // tick 1: caller enters `compute`, which suspends at its `await wait(0.02s)`
    // (the whole task suspends; the caller has not bound x yet).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
    // tick 2: `compute` resumes, `return 42` resolves at the caller's await site
    // (x = 42), then `o.n = x` → n = 42.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.runtime_errors);
    try std.testing.expectEqual(@as(i64, 42), readResourceInt(&world, out_id));
    // tick 3: task done — n stays 42.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 42), readResourceInt(&world, out_id));
}

test "async method called via await inlines with its own scope and locals survive the suspension (M1.0.11 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `bumped` is an `async method`: it reads `self.base` into a local, suspends
    // at `await wait(0.02s)`, and returns the local + 1 on resume. The call frame
    // carries `self` + the local in its OWN heap-boxed scope, retained across the
    // suspension (no collision with the caller's scope). `n` goes 0 → 11.
    const source =
        \\struct Counter { base: int = 0 }
        \\impl Counter {
        \\  async fn bumped(self) -> int {
        \\    let b = self.base
        \\    await wait(0.02s)
        \\    return b + 1
        \\  }
        \\}
        \\resource Out { n: int = 0 }
        \\async rule caller()
        \\  when resource Out
        \\{
        \\  let c = Counter { base: 10 }
        \\  let x = await c.bumped()
        \\  let o = get_mut(Out)
        \\  o.n = x
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

    // tick 1: caller builds `c`, enters `c.bumped()`, which reads self.base into a
    // local and suspends at its `await wait(0.02s)`.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
    // tick 2: `bumped` resumes (its local `b = 10` survived), returns 11, which
    // binds `x`; `o.n = x` → n = 11.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.runtime_errors);
    try std.testing.expectEqual(@as(i64, 11), readResourceInt(&world, out_id));
    // tick 3: task done — n stays 11.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 11), readResourceInt(&world, out_id));
}

test "await wait(1.0s) resumes at the fixed-timestep-equivalent tick count (60) (M1.0.11 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // 1.0 s at the Phase-1 fixed 1/60 timestep = 60 ticks. Spawned at async_tick
    // 1, the task wakes at tick 61 — not before. This pins the Duration→tick
    // conversion (M1.0.13 will swap the clock without changing the result at
    // time_scale = 1).
    const source =
        \\resource Out { n: int = 0 }
        \\async rule sec()
        \\  when resource Out
        \\{
        \\  let o = get_mut(Out)
        \\  o.n = 1
        \\  await wait(1.0s)
        \\  let o2 = get_mut(Out)
        \\  o2.n = 2
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

    // tick 1: n=1, suspend (wake at async_tick 61).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // through tick 60: still suspended (60 < 61).
    _ = try interp.runFor(&world, 59);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 61: wake fires (61 >= 61) → n=2.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, out_id));
}

/// Compile + run `source` for 2 ticks and return the runtime-error count, after
/// asserting it parses and type-checks clean (M1.0.11 E3 fail-loud partition
/// helper). The async targets NOT owned by this milestone must surface a typed
/// `RuntimeFailure` (counted), never crash or silently no-op.
fn asyncFailLoudCount(gpa: std.mem.Allocator, source: []const u8) !u64 {
    var world = World.init();
    defer world.deinit(gpa);
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
    const report = try interp.runFor(&world, 2);
    return report.runtime_errors;
}

test "await wait_unscaled / entity_event still fail loud (partition boundary intact, M1.0.11 E3)" {
    const gpa = std.testing.allocator;
    // `wait_unscaled` — needs the scaled/unscaled time subsystem (M1.0.13).
    try std.testing.expect((try asyncFailLoudCount(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  await wait_unscaled(1.0s)
        \\}
    )) >= 1);
    // `entity_event` — needs entity-scoped events (M1.0.14).
    try std.testing.expect((try asyncFailLoudCount(gpa,
        \\event Ev { }
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  await entity_event(get(Out), Ev)
        \\}
    )) >= 1);
    // The third M1.0.11 case — `await` on a stored non-TaskHandle value — is
    // rejected at TYPE-CHECK since M1.0.12 E3 (E0200, "await target must be a
    // direct async call or a TaskHandle"), so it never reaches the runtime:
    // covered by the types.zig E3 tests. Real handle-await execution is E5.
}

test "task pool is pointer-stable and cancelTask parks a suspended task for good (M1.0.12 E1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Substrate check for the multi-task scheduler (no construct surface yet):
    // the rule-root task is a heap record in the pointer pool, carries its
    // `origin_rule`, and `cancelTask` frees its frames + locals, parks it
    // `.canceled`, and the drive-by-origin pass never schedules it again —
    // `Out.n` stays at the pre-suspension value forever. Idempotent re-cancel.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule seq()
        \\  when resource Out
        \\{
        \\  let a = get_mut(Out)
        \\  a.n = 1
        \\  await wait(0.04s)
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

    // tick 1: spawn → n=1, suspend at `await wait(0.04s)`.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    const ti = interp.rule_tasks[0].?;
    const task = interp.async_tasks.items[ti];
    try std.testing.expectEqual(@as(u32, 0), task.origin_rule);
    try std.testing.expect(task.state == .suspended);
    try std.testing.expect(task.frames.items.len > 0);

    // Cancel: frames freed, parked `.canceled`; the heap record's address is
    // the pool entry itself (pointer-stable identity).
    interp.cancelTask(ti);
    try std.testing.expect(task.state == .canceled);
    try std.testing.expectEqual(@as(usize, 0), task.frames.items.len);
    interp.cancelTask(ti); // idempotent on a non-suspended task
    try std.testing.expect(task.state == .canceled);

    // ticks 2..5: the canceled task is never scheduled again — n stays 1 even
    // past the original wake tick (0.04s × 60 = tick 3).
    const r = try interp.runFor(&world, 4);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
}

test "race timeout pattern: winner return propagates, loser canceled (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The Sec. 9.5 canonical pattern: a slow fetch races a timeout. The timeout
    // branch (3 ticks) beats the slow branch (6 ticks); its `return 99`
    // propagates to the race site — `with_timeout` returns 99 at the caller's
    // await — and the loser is canceled: `slow`'s `return 1` never lands.
    const source =
        \\resource Out { n: int = 0 }
        \\async fn slow() -> int {
        \\  await wait(0.1s)
        \\  return 1
        \\}
        \\async fn with_timeout() -> int {
        \\  race {
        \\    return await slow()
        \\    { await wait(0.05s)
        \\      return 99 }
        \\  }
        \\  return 0
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let x = await with_timeout()
        \\  let o = get_mut(Out)
        \\  o.n = x
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

    // tick 1: spawn -> race entry -> 2 children (slow: wake 7; timeout: wake 4);
    // parent suspended on children_any. ticks 2-3: everyone waits.
    _ = try interp.runFor(&world, 4);
    // tick 4: the timeout child resumed, returned 99, parked done. The parent
    // (lower pool index, already visited this tick) resumes NEXT tick.
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
    // tick 5: parent resumes -> winner = timeout branch, `slow` canceled ->
    // 99 re-raised at the race site -> with_timeout returns 99 -> n = 99.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 99), readResourceInt(&world, out_id));
    // ticks 6-10: past the slow branch's original wake (7) — canceled, its
    // `return 1` never lands; n stays 99, no runtime errors.
    const tail = try interp.runFor(&world, 5);
    try std.testing.expectEqual(@as(u64, 0), tail.runtime_errors);
    try std.testing.expectEqual(@as(i64, 99), readResourceInt(&world, out_id));
}

test "race emit interleaving is deterministic; canceled loser never emits (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Emit ordering across parent/children over multiple ticks, encoded as
    // decimal digits into Out.n by an @on_event observer. Documented order:
    //   tick 1: parent emits 1, race entry (children suspend)      -> n = 1
    //   tick 3: fast child resumes, emits 2, completes             -> n = 12
    //   tick 4: parent resumes (winner = fast), cancels slow,
    //           emits 4                                            -> n = 124
    //   tick 7+ (slow child's original wake): canceled, never
    //           emits 3 — and the fast child never re-runs (no
    //           double emit)                                       -> n = 124
    const source =
        \\event Mark { k: int = 0 }
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  emit Mark { k: 1 }
        \\  race {
        \\    { await wait(0.04s)
        \\      emit Mark { k: 2 } }
        \\    { await wait(0.1s)
        \\      emit Mark { k: 3 } }
        \\  }
        \\  emit Mark { k: 4 }
        \\}
        \\@on_event(Mark)
        \\rule collect()
        \\  when resource Out
        \\{
        \\  let o = get_mut(Out)
        \\  o.n = o.n * 10 + event.k
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

    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    _ = try interp.runFor(&world, 2); // tick 3: fast child emits 2
    try std.testing.expectEqual(@as(i64, 12), readResourceInt(&world, out_id));
    _ = try interp.runFor(&world, 1); // tick 4: parent resumes, emits 4
    try std.testing.expectEqual(@as(i64, 124), readResourceInt(&world, out_id));
    const tail = try interp.runFor(&world, 6); // through tick 10: loser stays canceled
    try std.testing.expectEqual(@as(u64, 0), tail.runtime_errors);
    try std.testing.expectEqual(@as(i64, 124), readResourceInt(&world, out_id));
}

test "conditional admission + zero-admitted passthrough (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Guards are evaluated in the parent's LIVE scope at construct entry: the
    // false guard's branch is never admitted (its write never happens); the
    // true guard's branch runs. A construct whose every branch is refused
    // (and an empty one) does not suspend — the parent continues immediately.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let yes = true
        \\  let no = false
        \\  race {
        \\    if no => { let a = get_mut(Out)
        \\      a.n = 111 }
        \\    if yes => { let b = get_mut(Out)
        \\      b.n = 5 }
        \\  }
        \\  sync {
        \\    if no => await wait(0.04s)
        \\  }
        \\  race { }
        \\  let o = get_mut(Out)
        \\  o.n = o.n + 100
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

    // tick 1: race admits ONLY the `yes` branch (child completes in-pass,
    // n=5); the parent is suspended on it (resumes next tick).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 5), readResourceInt(&world, out_id));
    // tick 2: parent resumes; the zero-admitted `sync` and the empty `race`
    // pass through WITHOUT suspending -> +100 lands the same tick.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.runtime_errors);
    try std.testing.expectEqual(@as(i64, 105), readResourceInt(&world, out_id));
}

test "race tie-break: same-tick completions resolve in declaration order (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Both branches complete in the same tick (same wait): the winner is the
    // FIRST in declaration order -> pick() returns 10, never 20. The loser's
    // pending return is discarded.
    const source =
        \\resource Out { n: int = 0 }
        \\async fn pick() -> int {
        \\  race {
        \\    { await wait(0.04s)
        \\      return 10 }
        \\    { await wait(0.04s)
        \\      return 20 }
        \\  }
        \\  return 0
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let x = await pick()
        \\  let o = get_mut(Out)
        \\  o.n = x
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

    // tick 3: both children resume and complete; tick 4: the parent picks the
    // declaration-order winner.
    const r = try interp.runFor(&world, 4);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 10), readResourceInt(&world, out_id));
}

test "sync joins all branches; a failing branch does not block the join (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Three branches: two parallel awaited writes (2 and 5 ticks) and one that
    // throws uncaught (fails loud in-pass, harvested, parked canceled). The
    // join completes when the two live branches are done — the failed one
    // neither blocks nor re-reports.
    const source =
        \\resource A { n: int = 0 }
        \\resource B { n: int = 0 }
        \\async rule r()
        \\  when resource A and resource B
        \\{
        \\  sync {
        \\    { await wait(0.04s)
        \\      let a = get_mut(A)
        \\      a.n = 1 }
        \\    { await wait(0.08s)
        \\      let b = get_mut(B)
        \\      b.n = 2 }
        \\    { throw Error { message: "boom", code: .io_fail } }
        \\  }
        \\  let a2 = get_mut(A)
        \\  a2.n = a2.n + 10
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
    const a_id = world.registry.idOf("A").?;
    const b_id = world.registry.idOf("B").?;

    // tick 1: children created; the throwing branch fails loud in-pass
    // (1 runtime error), the two awaiters suspend (wakes 3 and 6).
    const r1 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 1), r1.runtime_errors);
    // tick 3: A=1. tick 6: B=2 (join condition now holds).
    _ = try interp.runFor(&world, 5);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, a_id));
    try std.testing.expectEqual(@as(i64, 2), readResourceInt(&world, b_id));
    // tick 7: the parent joins (failed branch did not block it) -> A=11.
    const r7 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r7.runtime_errors);
    try std.testing.expectEqual(@as(i64, 11), readResourceInt(&world, a_id));
}

test "race with every branch failing completes; parent resumes after it (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Both branches throw uncaught -> both park canceled (2 harvested errors),
    // no winner exists — the race still completes and the parent resumes at
    // the statement after it.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  race {
        \\    { throw Error { message: "a", code: .io_fail } }
        \\    { throw Error { message: "b", code: .io_fail } }
        \\  }
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

    // tick 1: both children fail loud in-pass (2 errors), parent suspended.
    const r1 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 2), r1.runtime_errors);
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
    // tick 2: children_any fires with NO winner (none done, none suspended)
    // -> the parent resumes after the race.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.runtime_errors);
    try std.testing.expectEqual(@as(i64, 7), readResourceInt(&world, out_id));
}

test "branch scope is a snapshot copy: writes are invisible to the parent (M1.0.12 E4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Sec. 9.8 normative: the child starts on a COPY of the parent's scope —
    // its rebinds of an inherited local (before and after its own suspension)
    // never reach the parent, whose `v` still reads 1 after the join.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let mut v = 1
        \\  sync {
        \\    { v = 99
        \\      await wait(0.04s)
        \\      v = 100 }
        \\  }
        \\  let o = get_mut(Out)
        \\  o.n = v
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

    // tick 1: entry (child rebinds ITS v to 99, suspends). tick 3: child
    // resumes (v -> 100), completes. tick 4: parent joins -> n = parent's v = 1.
    const r = try interp.runFor(&world, 4);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
}

test "branch is detached: parent continues same tick, task outlives it (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Sec. 9.7: fire-and-forget. The parent continues immediately (its write
    // lands tick 1) and COMPLETES; the detached child keeps running at the
    // origin rule's position and lands its write at its own wake, ticks after
    // the parent is gone.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  branch {
        \\    await wait(0.1s)
        \\    let b = get_mut(Out)
        \\    b.n = b.n + 50
        \\  }
        \\  let o = get_mut(Out)
        \\  o.n = 3
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

    // tick 1: child created (suspends, wake 7); parent continues -> n=3, done.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 3), readResourceInt(&world, out_id));
    // ticks 2-6: the detached child waits (its parent is long done).
    _ = try interp.runFor(&world, 5);
    try std.testing.expectEqual(@as(i64, 3), readResourceInt(&world, out_id));
    // tick 7: the detached child resumes at the origin rule's position -> +50.
    const r = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 53), readResourceInt(&world, out_id));
}

test "spawn handle: cancel() prevents the task from ever running (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `h.cancel()` on a just-spawned (suspended) task parks it canceled before
    // its first drive — its body never runs. Idempotence is the E1 primitive.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    await wait(0.04s)
        \\    let s = get_mut(Out)
        \\    s.n = 111
        \\  }
        \\  h.cancel()
        \\  let o = get_mut(Out)
        \\  o.n = 5
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

    const r = try interp.runFor(&world, 6);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 5), readResourceInt(&world, out_id));
}

test "await h joins a running task and resumes after its completion (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    await wait(0.04s)
        \\    let s = get_mut(Out)
        \\    s.n = 7
        \\  }
        \\  await h
        \\  let o = get_mut(Out)
        \\  o.n = o.n + 100
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

    // tick 3: the task resumes and completes (n=7); the awaiting parent
    // (lower index, already visited) joins the NEXT tick.
    _ = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(i64, 7), readResourceInt(&world, out_id));
    // tick 4: parent resumes after the join -> n=107.
    const r = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 107), readResourceInt(&world, out_id));
}

test "await on an already-done handle resumes immediately, same drive (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The monotonic-pool payoff: the husk keeps its state, so `await h` on a
    // task done ticks ago delivers the parked (unit) result WITHOUT
    // suspending — the +10 lands in the same drive as the resume from `wait`.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    let s = get_mut(Out)
        \\    s.n = 1
        \\  }
        \\  await wait(0.04s)
        \\  await h
        \\  let o = get_mut(Out)
        \\  o.n = o.n + 10
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

    // tick 1: spawn -> child completes in-pass (n=1); parent waits (wake 3).
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 3: parent resumes from wait; `await h` (done) does NOT suspend ->
    // +10 lands the same tick.
    const r = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 11), readResourceInt(&world, out_id));
}

test "await on a canceled handle fails loud, no silent unit (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Sec. 9.8 amended: awaiting a task canceled BEFORE the await is a
    // runtime error — the statements after the await never run.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    await wait(0.1s)
        \\  }
        \\  h.cancel()
        \\  await h
        \\  let o = get_mut(Out)
        \\  o.n = 9
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

    const r = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(u64, 1), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
}

test "a task canceled WHILE awaited fails the awaiter loud at resume (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The awaiter is suspended on task_done; the target is then canceled from
    // outside (harness-driven — the Phase-1 surface has no cross-task cancel
    // path other than a handle, but the runtime boundary must hold): the
    // awaiter fails loud at its resume, never reaching the next statement.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    await wait(0.1s)
        \\  }
        \\  await h
        \\  let o = get_mut(Out)
        \\  o.n = 9
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

    // tick 1: parent (pool 0) suspends on task_done(1); the spawned task
    // (pool 1) suspends on its wait.
    _ = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(usize, 2), interp.async_tasks.items.len);
    // Cancel the awaited task out from under the awaiter.
    interp.cancelTask(1);
    // tick 2: the awaiter's wake fires (target no longer suspended) -> its
    // resume sees `.canceled` -> fail-loud; n never becomes 9.
    const r = try interp.runFor(&world, 2);
    try std.testing.expectEqual(@as(u64, 1), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 0), readResourceInt(&world, out_id));
}

test "canceling the parent does not cancel its detached children (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The non-transitive boundary (Phase 1, etch-bytecode.md par. 9.5): the
    // parent is canceled while its spawned task still waits — the detached
    // task is an independent pool entry and completes on schedule; the
    // parent's own tail statement never runs.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    await wait(0.08s)
        \\    let s = get_mut(Out)
        \\    s.n = s.n + 7
        \\  }
        \\  await wait(0.2s)
        \\  let o = get_mut(Out)
        \\  o.n = 999
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

    // tick 1: parent (pool 0) suspends on its long wait; spawned task (pool 1)
    // suspends on its short one. Cancel the PARENT.
    _ = try interp.runFor(&world, 1);
    interp.cancelTask(interp.rule_tasks[0].?);
    // tick 6: the detached task still completes -> n = 7.
    _ = try interp.runFor(&world, 5);
    try std.testing.expectEqual(@as(i64, 7), readResourceInt(&world, out_id));
    // Through tick 14 (past the parent's original wake 13): the canceled
    // parent never resumes -> n stays 7, no errors.
    const r = try interp.runFor(&world, 8);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 7), readResourceInt(&world, out_id));
}

test "construct matrix: race nested in a spawn body, joined via handle (M1.0.12 E5)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // spawn { race { fast, slow } } + await h: the spawned task races its own
    // grandchildren (fast wins at tick 3, slow canceled at the spawn task's
    // resume, tick 4), completes, and the rule-root awaiter joins at tick 5.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    race {
        \\      { await wait(0.04s)
        \\        let a = get_mut(Out)
        \\        a.n = a.n + 1 }
        \\      { await wait(0.1s)
        \\        let b = get_mut(Out)
        \\        b.n = b.n + 500 }
        \\    }
        \\  }
        \\  await h
        \\  let o = get_mut(Out)
        \\  o.n = o.n + 20
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

    // tick 3: the fast grandchild lands +1.
    _ = try interp.runFor(&world, 3);
    try std.testing.expectEqual(@as(i64, 1), readResourceInt(&world, out_id));
    // tick 4: the spawn task resolves its race (slow canceled) and completes;
    // tick 5: the rule root joins -> +20.
    _ = try interp.runFor(&world, 2);
    try std.testing.expectEqual(@as(i64, 21), readResourceInt(&world, out_id));
    // Past the slow branch's original wake: canceled, +500 never lands.
    const r = try interp.runFor(&world, 5);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    try std.testing.expectEqual(@as(i64, 21), readResourceInt(&world, out_id));
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

test "runFor surfaces typed last_error with span on division by zero (D-S4-runtime-report)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // D-S4-runtime-report: the typed `RuntimeError` payload — kind plus the
    // failing expression's span — reaches the caller through
    // `RuntimeReport.last_error`, harvested by `execBody` (the sync choke
    // point). The span assertion pins resolution from the raising NodeId,
    // not a defaulted span.
    const source =
        \\component Acc { out: int = 0 }
        \\rule boom(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let d = 0
        \\  let x = 1 / d
        \\  entity.get_mut(Acc).out = x
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
    const le = report.last_error orelse return error.TestExpectedTypedError;
    try std.testing.expectEqual(RuntimeErrorKind.DivisionByZero, le.kind);
    try std.testing.expectEqualStrings("1 / d", source[le.span.byte_start..le.span.byte_end]);
}

test "runFor surfaces UncaughtThrow with the thrown-value span (D-S4-runtime-report)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // An Etch `throw` reaching the rule top level uncaught is a counted
    // runtime error (tranche 2); E3-D types it in the report. The span
    // covers the thrown value expression.
    const source =
        \\component Acc { out: int = 0 }
        \\rule boom(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  throw Error { message: "kaboom", code: ErrorCode.io_fail }
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
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 1), report.runtime_errors);
    const le = report.last_error orelse return error.TestExpectedTypedError;
    try std.testing.expectEqual(RuntimeErrorKind.UncaughtThrow, le.kind);
    const span_text = source[le.span.byte_start..le.span.byte_end];
    try std.testing.expect(std.mem.indexOf(u8, span_text, "kaboom") != null);
}

test "async runtime failure surfaces typed last_error (D-S4-runtime-report)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The async choke point (`driveTask` → `finishTaskFailed`) harvests the
    // same typed payload as `execBody` — the task fails before its first
    // suspension and the report carries the kind.
    const source =
        \\resource Out { n: int = 0 }
        \\async rule boom()
        \\  when resource Out
        \\{
        \\  let d = 0
        \\  let x = 1 / d
        \\  let r = get_mut(Out)
        \\  r.n = x
        \\  await wait(0.02s)
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
    try std.testing.expectEqual(@as(u64, 1), report.runtime_errors);
    const le = report.last_error orelse return error.TestExpectedTypedError;
    try std.testing.expectEqual(RuntimeErrorKind.DivisionByZero, le.kind);
}

const or_archetype_test_source =
    \\component Counter { value: int = 0 }
    \\component A { x: int = 0 }
    \\component B { x: int = 0 }
    \\component F0 { x: int = 0 }
    \\component F1 { x: int = 0 }
    \\component F2 { x: int = 0 }
    \\component F3 { x: int = 0 }
    \\component F4 { x: int = 0 }
    \\rule count(entity: Entity)
    \\  when entity has Counter and (entity has A or entity has B)
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

fn readCounterI64(world: *World, counter_id: ComponentId, eid: CoreEntityId) i64 {
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const idx = arch.componentIndex(counter_id).?;
    const slot = arch.componentSlot(chunk, idx, loc.slot);
    var v: i64 = 0;
    @memcpy(std.mem.asBytes(&v), slot[0..@sizeOf(i64)]);
    return v;
}

test "every entity-bound rule caches its matching-archetype set, rescanning only the tail (M1.0.0)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try parser_mod.parse(gpa, or_archetype_test_source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const counter_id = world.registry.idOf("Counter").?;
    const a_id = world.registry.idOf("A").?;
    const b_id = world.registry.idOf("B").?;

    // Materialise 8 distinct archetypes: the bare Counter, the two matching
    // shapes, and five fillers.
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{counter_id});
    const e_a = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, a_id });
    const e_b = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, b_id });
    for ([_][]const u8{ "F0", "F1", "F2", "F3", "F4" }) |fname| {
        const fid = world.registry.idOf(fname).?;
        _ = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, fid });
    }
    try std.testing.expectEqual(@as(usize, 8), world.archetypes.items.len);

    // Tick 1 — first entry: each DNF term scans every archetype once (the
    // initial full scan). The `when` is `Counter and (A or B)` → 2 conjunctive
    // terms ({Counter,A}, {Counter,B}), so 8 archetypes × 2 terms = 16
    // archetype-match evaluations. Then the cached union is iterated.
    const r1 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 16), r1.predicate_archetype_evals);
    try std.testing.expectEqual(@as(i64, 1), readCounterI64(&world, counter_id, e_a));
    try std.testing.expectEqual(@as(i64, 1), readCounterI64(&world, counter_id, e_b));

    // Tick 2 — steady state: no new archetypes, so neither term re-scans
    // anything (the cached matches), the matching entities still accumulate.
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.predicate_archetype_evals);
    try std.testing.expectEqual(@as(i64, 2), readCounterI64(&world, counter_id, e_a));

    // New archetype {Counter, A, B} — tick 3 rescans ONLY the tail (1 new
    // archetype × 2 terms = 2 evaluations). The new entity satisfies BOTH
    // disjuncts, but the union dedup dispatches the body once (counter = 1,
    // not 2) — the k-way merge collapses the duplicate.
    const e_ab = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, a_id, b_id });
    const r3 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 2), r3.predicate_archetype_evals);
    try std.testing.expectEqual(@as(i64, 1), readCounterI64(&world, counter_id, e_ab));
    try std.testing.expectEqual(@as(i64, 3), readCounterI64(&world, counter_id, e_a));
}

test "the cached matching set replaces the per-tick walk at any archetype count (M1.0.0)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try parser_mod.parse(gpa, or_archetype_test_source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const counter_id = world.registry.idOf("Counter").?;
    const a_id = world.registry.idOf("A").?;
    const b_id = world.registry.idOf("B").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{counter_id});
    const e_a = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, a_id });
    const e_b = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, b_id });
    try std.testing.expectEqual(@as(usize, 3), world.archetypes.items.len);

    // M1.0.0 — the dynamic-query selection is universal, at ANY archetype
    // count: tick 1 scans all 3 archetypes once per DNF term (`Counter and
    // (A or B)` → 2 terms → 6 evaluations), then steady-state ticks re-evaluate
    // nothing. (This small-world case re-walked the predicate every tick under
    // the M0.8 below-heuristic direct walk — the global linear scan removed by
    // this milestone.)
    const r1 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 6), r1.predicate_archetype_evals);
    const r2 = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), r2.predicate_archetype_evals);
    try std.testing.expectEqual(@as(i64, 2), readCounterI64(&world, counter_id, e_a));
    try std.testing.expectEqual(@as(i64, 2), readCounterI64(&world, counter_id, e_b));
}

test "runProgram anonymous struct literal via let annotation and field value (M0.8 E3-C tranche 8)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `.{ … }` end-to-end in the reference backend: the let annotation
    // types `q` (40 + 2), the declared field type of `Box.p` types the
    // nested literal (7 + 5 + 30). Sum: 84.
    const source =
        \\component Acc { out: int = 0 }
        \\struct Pt { x: int y: int }
        \\struct Box { p: Pt k: int }
        \\rule anon(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let q: Pt = .{ x: 40, y: 2 }
        \\  let b = Box { p: .{ x: 7, y: 5 }, k: 30 }
        \\  entity.get_mut(Acc).out = q.x + q.y + b.p.x + b.p.y + b.k
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
    try std.testing.expectEqual(@as(i64, 84), out);
}

// ─── M1.0.5 E3 — cross-module cook → load integration ──────────────────────
//
// Lives inline here (the brief permits it) so the assertion can read the
// interpreter's per-tick `EventStore` directly. End-to-end: compile an Etch
// program (2 components, a `string` resource, an `@on_spawned` rule that
// `emit`s) into a `World`, bind its observer rules to the Tier-0 registry, cook
// the same source's scene to `.scene.bin`, load it, and assert (a) every entity
// is instantiated, (b) the emitted-event count equals the entity count (the
// loader's two-phase `on_spawned` pass ran the rule once per entity — emits
// land in `events` and are NOT cleared, since the load drives no tick), and (c)
// the resource `string` round-trips through the Tier-0 persistent heap.
test "cooked Etch scene loads, on_spawned rules emit, resource string round-trips (M1.0.5 E3)" {
    const gpa = std.testing.allocator;
    const scene_cook = @import("scene_cook.zig");

    const source =
        \\component Position { x: f32 = 0.0, y: f32 = 0.0 }
        \\component Health { current: int = 100, max: int = 100 }
        \\resource Settings { title: string = "default" }
        \\event Spawned { n: int }
        \\
        \\@on_spawned
        \\rule on_spawn(entity: Entity) {
        \\  emit Spawned { n: 1 }
        \\}
        \\
        \\scene "IntegrationScene" {
        \\  version: 1
        \\  resources {
        \\    Settings { title: "level_42" }
        \\  }
        \\  entity "A" {
        \\    uuid: "00000000-0000-0000-0000-000000000001"
        \\    Position { x: 1.0, y: 2.0 }
        \\    Health { current: 50, max: 100 }
        \\  }
        \\  entity "B" {
        \\    uuid: "00000000-0000-0000-0000-000000000002"
        \\    Position { x: 3.0, y: 4.0 }
        \\  }
        \\  entity "C" {
        \\    uuid: "00000000-0000-0000-0000-000000000003"
        \\    Position { x: 5.0, y: 6.0 }
        \\    Health { current: 75, max: 100 }
        \\  }
        \\}
    ;

    var world = World.init();
    defer world.deinit(gpa);

    // Compile the program (registers Position/Health/Settings + the @on_spawned
    // rule). Bind observer rules to the registry NOW — the loader drives a Tier-0
    // flush, not an interpreter tick, so `runFor`'s lazy bind never happens.
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    // Cook the same source's scene block to `.scene.bin` (the cook ignores the
    // rule/event decls, uses the component/resource decls for type resolution).
    var cooked = try scene_cook.cook(gpa, source, null);
    defer cooked.deinit(gpa);
    const bytes = try weld_core.scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var result = try weld_core.scene.loader.loadFromBytes(&world, gpa, bytes, null);
    defer result.deinit(gpa);

    // (a) every entity instantiated.
    try std.testing.expectEqual(@as(usize, 3), result.spawned.len);
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());

    // (b) emitted-event count equals the entity count.
    const spawned_id = pr.ast.strings.find("Spawned").?;
    try std.testing.expectEqual(@as(usize, 3), interp.events.count(spawned_id));

    // (c) resource `string` round-trips through the Tier-0 persistent heap.
    const settings_cid = world.registry.idOf("Settings").?;
    const fd = world.registry.findField(settings_cid, "title").?;
    const res_bytes = world.resources.getResource(settings_cid).?;
    var ss: persistent.StringSlot = undefined;
    @memcpy(std.mem.asBytes(&ss), res_bytes[fd.offset..][0..@sizeOf(persistent.StringSlot)]);
    const title: [*]const u8 = @ptrFromInt(ss.ptr);
    try std.testing.expectEqualStrings("level_42", title[0..ss.len]);
}

test "execHookText mutates a component on the live world (M1.0.9 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const source =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\rule keep(entity: Entity) when entity has Health {}
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Health").?;
    var hv = [_]i32{ 100, 100 }; // current, max
    const eid = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{cid}, &[_][]const u8{std.mem.asBytes(&hv)});

    // The exact text a cooked `on_attach` carries (see CombatModule in the spec).
    try interp.execHookText(&world, eid, "entity.get_mut(Health).max += 50");

    const hb = world.componentBytes(eid, cid).?;
    try std.testing.expectEqual(@as(i32, 150), std.mem.readInt(i32, hb[4..8], .little)); // max @4
}

test "execHookText restores self.ast and the program still steps (M1.0.9 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const source =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\rule tick(entity: Entity) when entity has Health { entity.get_mut(Health).current += 1 }
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Health").?;
    var hv = [_]i32{ 100, 100 };
    const eid = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{cid}, &[_][]const u8{std.mem.asBytes(&hv)});

    const program_ast = interp.ast; // == &pr.ast
    try interp.execHookText(&world, eid, "entity.get_mut(Health).max += 50");
    // The hook ran against a transient arena; the program AST pointer is restored.
    try std.testing.expectEqual(program_ast, interp.ast);

    // The program still steps on the restored AST: the rule bumps current 100→101.
    _ = try interp.runFor(&world, 1);
    const hb = world.componentBytes(eid, cid).?;
    try std.testing.expectEqual(@as(i32, 101), std.mem.readInt(i32, hb[0..4], .little)); // current @0
    try std.testing.expectEqual(@as(i32, 150), std.mem.readInt(i32, hb[4..8], .little)); // max @4 (hook effect persisted)
}

test "execHookText emit enqueues into the dynamic event store (M1.0.9 E2)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const source =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\rule keep(entity: Entity) when entity has Health {}
    ;
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    const cid = world.registry.idOf("Health").?;
    var hv = [_]i32{ 100, 100 };
    const eid = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{cid}, &[_][]const u8{std.mem.asBytes(&hv)});

    try std.testing.expectEqual(@as(usize, 0), interp.events.list.items.len);
    try interp.execHookText(&world, eid, "emit ExtensionAttached {}");
    // The hook's `emit` landed in the per-tick dynamic event store.
    try std.testing.expectEqual(@as(usize, 1), interp.events.list.items.len);
}

// ── M1.0.10 E3 — structural mutation in bodies ────────────────────────────

/// E3 test helper — parse + type-check a program, asserting both clean, and
/// return the `ParseResult` (caller owns; `deinit` after the interp).
fn checkCleanProgram(gpa: std.mem.Allocator, source: []const u8) !parser_mod.ParseResult {
    var pr = try parser_mod.parse(gpa, source);
    errdefer pr.deinit(gpa);
    if (pr.diagnostics.len != 0) {
        std.debug.print("unexpected parse diag: {s}\n", .{pr.diagnostics[0].primary_message});
        return error.UnexpectedParseDiagnostic;
    }
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    if (diags.items.len != 0) {
        std.debug.print("unexpected typecheck diag: {s}\n", .{diags.items[0].primary_message});
        return error.UnexpectedTypecheckDiagnostic;
    }
    return pr;
}

/// Count live entities whose archetype carries `cid`.
fn countEntitiesWith(world: *World, cid: ComponentId) usize {
    var total: usize = 0;
    for (world.archetypes.items) |arch| {
        if (arch.componentIndex(cid) == null) continue;
        for (arch.chunks.items) |chunk| total += chunk.header().entity_count;
    }
    return total;
}

/// The first live entity carrying `cid`, or `null` if none.
fn firstEntityWith(world: *World, cid: ComponentId) ?CoreEntityId {
    for (world.archetypes.items) |arch| {
        if (arch.componentIndex(cid) == null) continue;
        for (arch.chunks.items) |chunk| {
            if (chunk.header().entity_count > 0) return arch.entityIdsConst(chunk)[0];
        }
    }
    return null;
}

fn readI32(world: *World, entity: CoreEntityId, cid: ComponentId, field: []const u8) ?i32 {
    const fd = world.registry.findField(cid, field) orelse return null;
    const bytes = world.componentBytes(entity, cid) orelse return null;
    var v: i32 = 0;
    @memcpy(std.mem.asBytes(&v), bytes[fd.offset .. fd.offset + @sizeOf(i32)]);
    return v;
}

test "spawn defers — entity materializes at flush with full payload (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Trigger { t: i32 = 0 }
        \\component Health { max: i32 = 0 }
        \\rule r(entity: Entity) when entity has Trigger {
        \\  spawn(Health { max: 10 })
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const trigger = world.registry.idOf("Trigger").?;
    const health = world.registry.idOf("Health").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{trigger});
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // Materialized at the flush: a new entity carries Health { max: 10 }.
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    try std.testing.expectEqual(@as(usize, 1), countEntitiesWith(&world, health));
    const spawned = firstEntityWith(&world, health).?;
    try std.testing.expectEqual(@as(i32, 10), readI32(&world, spawned, health, "max").?);
}

test "despawn defers — entity removed at flush (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Doomed { d: i32 = 0 }
        \\rule r(entity: Entity) when entity has Doomed {
        \\  entity.despawn()
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const doomed = world.registry.idOf("Doomed").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{doomed});
    try std.testing.expect(world.dynamicLocation(e) != null); // live before the tick

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expect(world.dynamicLocation(e) == null); // gone after the flush
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "add defers — component present at flush (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Marker { m: i32 = 0 }
        \\component Shield { amount: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Shield { amount: 7 })
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const marker = world.registry.idOf("Marker").?;
    const shield = world.registry.idOf("Shield").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{marker});
    try std.testing.expect(world.componentBytes(e, shield) == null); // absent before

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expect(world.componentBytes(e, shield) != null); // present after
    try std.testing.expectEqual(@as(i32, 7), readI32(&world, e, shield, "amount").?);
}

test "remove defers — component gone at flush (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Marker { m: i32 = 0 }
        \\component Poison { dmg: i32 = 0 }
        \\rule r(entity: Entity) when entity has Poison {
        \\  entity.remove(Poison)
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const marker = world.registry.idOf("Marker").?;
    const poison = world.registry.idOf("Poison").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{ marker, poison });
    try std.testing.expect(world.componentBytes(e, poison) != null); // present before

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expect(world.componentBytes(e, poison) == null); // gone after
    try std.testing.expect(world.componentBytes(e, marker) != null); // Marker kept
}

test "spawn fires on_spawned then on_add per component at flush (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Trigger { t: i32 = 0 }
        \\component Health { max: i32 = 0 }
        \\event Sp { x: i32 = 0 }
        \\event Ad { x: i32 = 0 }
        \\@on_spawned
        \\rule on_sp(entity: Entity) { emit Sp { x: 1 } }
        \\@on_added(Health)
        \\rule on_ad(entity: Entity, value: Health) { emit Ad { x: value.max } }
        \\rule spawner(entity: Entity) when entity has Trigger {
        \\  spawn(Health { max: 10 })
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const trigger = world.registry.idOf("Trigger").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{trigger});

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const sp_id = pr.ast.strings.find("Sp").?;
    const ad_id = pr.ast.strings.find("Ad").?;
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(sp_id));
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(ad_id));
    // Documented order: on_spawned BEFORE on_add (Tier-0 `applyWithObservers`).
    try std.testing.expectEqual(@as(usize, 2), interp.events.list.items.len);
    try std.testing.expectEqual(sp_id, interp.events.list.items[0].type_name);
    try std.testing.expectEqual(ad_id, interp.events.list.items[1].type_name);
}

test "despawn fires on_remove per component then on_despawned (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Health { current: i32 = 0 }
        \\event Rm { v: i32 = 0 }
        \\event Ds { v: i32 = 0 }
        \\@on_removed(Health)
        \\rule on_rm(entity: Entity, old: Health) { emit Rm { v: old.current } }
        \\@on_despawned
        \\rule on_ds(entity: Entity) { emit Ds { v: 1 } }
        \\rule killer(entity: Entity) when entity has Health {
        \\  entity.despawn()
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const health = world.registry.idOf("Health").?;
    var hv: i32 = 42;
    _ = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{health}, &[_][]const u8{std.mem.asBytes(&hv)});

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    const rm_id = pr.ast.strings.find("Rm").?;
    const ds_id = pr.ast.strings.find("Ds").?;
    try std.testing.expectEqual(@as(usize, 2), interp.events.list.items.len);
    // Documented order: on_remove (per component) BEFORE on_despawned.
    try std.testing.expectEqual(rm_id, interp.events.list.items[0].type_name);
    try std.testing.expectEqual(ds_id, interp.events.list.items[1].type_name);
    // The component is readable in on_remove, pre-destruction (current = 42).
    const v_id = pr.ast.strings.find("v").?;
    var seen: i64 = -1;
    for (interp.events.list.items[0].fields.items) |f| {
        if (f.name == v_id) seen = f.value.int_;
    }
    try std.testing.expectEqual(@as(i64, 42), seen);
}

test "add-on-present fires on_replaced not on_added (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Health { current: i32 = 0 }
        \\event Rp { o: i32 = 0, n: i32 = 0 }
        \\event Ad { x: i32 = 0 }
        \\@on_replaced(Health)
        \\rule on_rp(entity: Entity, old: Health, new: Health) { emit Rp { o: old.current, n: new.current } }
        \\@on_added(Health)
        \\rule on_ad(entity: Entity, value: Health) { emit Ad { x: 1 } }
        \\rule replacer(entity: Entity) when entity has Health {
        \\  entity.add(Health { current: 9 })
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const health = world.registry.idOf("Health").?;
    var hv: i32 = 5;
    _ = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{health}, &[_][]const u8{std.mem.asBytes(&hv)});

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // add-on-present is a replace: on_replaced fires (old=5, new=9), on_added does not.
    try std.testing.expectEqual(@as(usize, 1), interp.events.count(pr.ast.strings.find("Rp").?));
    try std.testing.expectEqual(@as(usize, 0), interp.events.count(pr.ast.strings.find("Ad").?));
    const o_id = pr.ast.strings.find("o").?;
    const n_id = pr.ast.strings.find("n").?;
    var o_seen: i64 = -1;
    var n_seen: i64 = -1;
    for (interp.events.list.items[0].fields.items) |f| {
        if (f.name == o_id) o_seen = f.value.int_;
        if (f.name == n_id) n_seen = f.value.int_;
    }
    try std.testing.expectEqual(@as(i64, 5), o_seen);
    try std.testing.expectEqual(@as(i64, 9), n_seen);
}

test "B1 — multi-entity rule structural mutation defers without corrupting iteration (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try checkCleanProgram(gpa,
        \\component Marker { m: i32 = 0 }
        \\component Shield { x: i32 = 0 }
        \\component Spawned { id: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Shield { x: 1 })
        \\  spawn(Spawned { id: 7 })
        \\  entity.despawn()
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const marker = world.registry.idOf("Marker").?;
    const spawned = world.registry.idOf("Spawned").?;
    const shield = world.registry.idOf("Shield").?;
    var i: usize = 0;
    while (i < 3) : (i += 1) _ = try world.spawnDynamic(gpa, &[_]ComponentId{marker});
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());

    // The full live archetype walk (3 entities) runs with no corruption; every
    // effect applies at the tick's flush.
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);

    // The 3 Marker entities were despawned (with Shield added first, then gone);
    // 3 new Spawned entities exist. Net entity count unchanged.
    try std.testing.expectEqual(@as(usize, 0), countEntitiesWith(&world, marker));
    try std.testing.expectEqual(@as(usize, 0), countEntitiesWith(&world, shield));
    try std.testing.expectEqual(@as(usize, 3), countEntitiesWith(&world, spawned));
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());
}

test "S4 structural-mutation boundary lifted — a body issuing all four ops runs (M1.0.10 E3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    // The S4 header no longer claims spawn/despawn/add/remove are unsupported;
    // a body issuing all four runs with zero runtime errors (no UnsupportedExpr).
    var pr = try checkCleanProgram(gpa,
        \\component Marker { m: i32 = 0 }
        \\component Poison { dmg: i32 = 0 }
        \\component Shield { x: i32 = 0 }
        \\component Spawned { id: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Shield { x: 1 })
        \\  entity.remove(Poison)
        \\  spawn(Spawned { id: 1 })
        \\  entity.despawn()
        \\}
    );
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const marker = world.registry.idOf("Marker").?;
    const poison = world.registry.idOf("Poison").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{ marker, poison });

    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expectEqual(@as(usize, 1), countEntitiesWith(&world, world.registry.idOf("Spawned").?));
}
