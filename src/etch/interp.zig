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

const weld_core = @import("weld_core");
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;
const FieldDesc = weld_core.ecs.registry.FieldDesc;
const FieldKind = weld_core.ecs.registry.FieldKind;
const DynamicArchetype = weld_core.ecs.archetype_dynamic.DynamicArchetype;
const Chunk = weld_core.ecs.archetype_dynamic.Chunk;
const World = weld_core.ecs.world.World;

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
    entity_param_name: ?StringId,
    /// True iff the rule iterates entities (predicate references at least
    /// one component and a parameter of type Entity is present). False if
    /// the rule runs once per tick (resource-only or no-when).
    is_entity_bound: bool,

    fn deinit(self: *RuleDesc, gpa: std.mem.Allocator) void {
        gpa.free(self.predicate_pool);
        gpa.free(self.resource_deps);
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
    /// Heap store backing collection values created in rule bodies (M0.8).
    collections: CollectionStore = .{},
    /// Store backing closure values created in rule bodies (M0.8 closures).
    closures: ClosureStore = .{},
    /// Store backing struct values created in rule / fn / method bodies (M0.8
    /// E2 block 3).
    structs: StructStore = .{},
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

    pub fn deinit(self: *Interpreter) void {
        for (self.rule_descs) |*r| r.deinit(self.gpa);
        self.gpa.free(self.rule_descs);
        self.bridge.deinit(self.gpa);
        self.collections.deinit(self.gpa);
        self.closures.deinit(self.gpa);
        self.structs.deinit(self.gpa);
        self.fns.deinit(self.gpa);
        self.methods.deinit(self.gpa);
        self.struct_decls.deinit(self.gpa);
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
            const desc = try compileRule(gpa, ast, &bridge, &world.registry, data);
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
        i = 0;
        while (i < ast.items.len) : (i += 1) {
            const kind = ast.items.items(.kind)[i];
            const data = ast.items.items(.data)[i];
            switch (kind) {
                .impl_decl => {
                    const impl = ast.impl_decls.items[data];
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
                else => {},
            }
        }

        const slice = try rule_descs.toOwnedSlice(gpa);
        return .{
            .gpa = gpa,
            .ast = ast,
            .bridge = bridge,
            .rule_descs = slice,
            .fns = fns,
            .methods = methods,
            .struct_decls = struct_decls,
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
        for (self.rule_descs) |*rd| {
            report.rules_evaluated += 1;
            if (!resourceDepsSatisfied(world, rd.*)) continue;
            try self.runRule(world, rd.*, report);
        }
    }

    fn runRule(self: *Interpreter, world: *World, rd: RuleDesc, report: *RuntimeReport) !void {
        if (!rd.is_entity_bound) {
            try self.execBody(world, rd, null, report);
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
                    report.entities_iterated += 1;
                    rule_matched = true;
                    // The chunk array stores the core `EntityId` packed
                    // struct; Etch's local `EntityId` is the raw u64 wire
                    // form that lives inside `Value.entity_id`. The two
                    // share the same 8-byte layout — `@bitCast` does the
                    // conversion without touching bits.
                    const entity_id: EntityId = @bitCast(ids[slot]);
                    try self.execBody(world, rd, entity_id, report);
                }
            }
        }
        if (rule_matched) report.rules_matched += 1;
    }

    fn execBody(self: *Interpreter, world: *World, rd: RuleDesc, entity_id: ?EntityId, report: *RuntimeReport) !void {
        const rule = self.ast.rule_decls.items[rd.rule_idx];

        var locals: Locals = .{};
        defer locals.deinit(self.gpa);
        // Collections, closures, and structs created in this body live in the
        // rule arena: free them at the body boundary so handles never outlive
        // their invocation.
        defer self.collections.reset(self.gpa);
        defer self.closures.reset(self.gpa);
        defer self.structs.reset(self.gpa);
        try bindParams(self.gpa, self.ast, rule, entity_id, &locals);
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
                const wh = self.ast.while_stmts.items[data];
                while_loop: while (true) {
                    const cond = try self.evalExpr(world, locals, wh.cond);
                    if (cond != .bool_) return error.RuntimeFailure;
                    if (!cond.bool_) break :while_loop;
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
            .ident => {
                const name_id: StringId = data;
                if (locals.get(name_id)) |v| return v;
                return error.RuntimeFailure;
            },
            .field_access => {
                const fa = self.ast.field_accesses.items[data];
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
                const lhs = try self.evalExpr(world, locals, b.lhs);
                const rhs = try self.evalExpr(world, locals, b.rhs);
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
                // store (M0.8 collections). Duplicate keys are last-write-wins.
                // The interpreter is the reference execution; map codegen is
                // deferred (heap / arena model).
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
                // `recv.method(args)` / `Type.assoc(args)` — inherent dispatch
                // (M0.8 E2 block 3, §5.1; the block-2 fail-loud is wired here).
                // Associated fn: a bare type-path receiver, no self. Instance
                // method: a struct-valued receiver, self bound to it (a `mut
                // self` method mutates it in place — the store handle is shared).
                const mc = self.ast.method_calls.items[data];
                if (self.ast.exprKind(mc.receiver) == .path) {
                    const type_name = self.ast.exprData(mc.receiver);
                    const method = self.methods.get(methodKey(type_name, mc.method_name)) orelse return error.RuntimeFailure;
                    return try self.callMethod(world, locals, method, mc, null);
                }
                const recv = try self.evalExpr(world, locals, mc.receiver);
                // Block-3 instance methods dispatch on struct receivers; methods
                // on component / resource values are deferred (the interpreter
                // cannot recover the type name from a bare ref) — fail loud.
                if (recv != .struct_ref) return error.RuntimeFailure;
                const type_name = self.structs.list.items[recv.struct_ref].type_name;
                const method = self.methods.get(methodKey(type_name, mc.method_name)) orelse return error.RuntimeFailure;
                return try self.callMethod(world, locals, method, mc, recv);
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
                // `if cond { then } [else if ...] [else { else }]` (M0.8 control
                // flow). Evaluate the condition; run the matching branch (a
                // block expression, or a nested `if` for `else if`). An `if`
                // with no `else` and a false condition yields `unit`. Branch
                // evaluation propagates any control / throw signal raised in it.
                const ife = self.ast.if_exprs.items[data];
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
    rule_data: u32,
) !RuleDesc {
    const rule = ast.rule_decls.items[rule_data];

    var pool: std.ArrayListUnmanaged(PredicateNode) = .empty;
    errdefer pool.deinit(gpa);
    var res_deps: std.ArrayListUnmanaged(ResourceDep) = .empty;
    errdefer res_deps.deinit(gpa);
    var field_filter: ?FieldFilter = null;
    var predicate_root: ?u32 = null;
    var has_component_ref: bool = false;

    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        const r = try lowerWhen(ast, bridge, registry, &pool, &res_deps, &field_filter, gpa, rule.when_root, &has_component_ref);
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

    return .{
        .rule_idx = rule_data,
        .name = rule.name,
        .predicate_pool = try pool.toOwnedSlice(gpa),
        .predicate_root = predicate_root,
        .resource_deps = try res_deps.toOwnedSlice(gpa),
        .field_filter = field_filter,
        .entity_param_name = entity_param_name,
        .is_entity_bound = is_entity_bound,
    };
}

/// Recursively lower a `when` tree into a flat `PredicateNode` pool plus
/// a list of resource deps and at most one field filter. Returns the
/// pool-index of the lowered node, or `PredicateNode.no_child` when the
/// when subtree contributes only resource deps (and thus no archetype-
/// side predicate).
fn lowerWhen(
    ast: *const AstArena,
    bridge: *Bridge,
    registry: *const Registry,
    pool: *std.ArrayListUnmanaged(PredicateNode),
    res_deps: *std.ArrayListUnmanaged(ResourceDep),
    filter: *?FieldFilter,
    gpa: std.mem.Allocator,
    when_idx: u32,
    has_component_ref: *bool,
) error{ OutOfMemory, InvalidProgram }!u32 {
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and, .logical_or => {
            const lhs_idx = try lowerWhen(ast, bridge, registry, pool, res_deps, filter, gpa, node.lhs, has_component_ref);
            const rhs_idx = try lowerWhen(ast, bridge, registry, pool, res_deps, filter, gpa, node.rhs, has_component_ref);
            // If a branch contributed only resource deps, propagate the
            // other branch's predicate unchanged.
            if (lhs_idx == PredicateNode.no_child) return rhs_idx;
            if (rhs_idx == PredicateNode.no_child) return lhs_idx;
            const kind: PredicateNodeKind = if (node.kind == .logical_and) .and_ else .or_;
            const idx: u32 = @intCast(pool.items.len);
            try pool.append(gpa, .{ .kind = kind, .lhs = lhs_idx, .rhs = rhs_idx });
            return idx;
        },
        .logical_not => {
            const child = try lowerWhen(ast, bridge, registry, pool, res_deps, filter, gpa, node.lhs, has_component_ref);
            if (child == PredicateNode.no_child) return PredicateNode.no_child;
            const idx: u32 = @intCast(pool.items.len);
            try pool.append(gpa, .{ .kind = .not_, .lhs = child });
            return idx;
        },
        .has => {
            const tname = ast.strings.slice(node.type_name);
            const id = bridge.componentIdOf(tname) orelse return error.InvalidProgram;
            const idx: u32 = @intCast(pool.items.len);
            try pool.append(gpa, .{ .kind = .has, .component_id = id });
            has_component_ref.* = true;
            return idx;
        },
        .has_with_filter => {
            const tname = ast.strings.slice(node.type_name);
            const id = bridge.componentIdOf(tname) orelse return error.InvalidProgram;
            const fname = ast.strings.slice(node.field_name);
            const fd = registry.findField(id, fname) orelse return error.InvalidProgram;
            const v = evalConst(ast, node.filter_value) catch return error.InvalidProgram;
            filter.* = .{
                .component_id = id,
                .field_offset = fd.offset,
                .field_kind = fd.kind,
                .expected_value = v,
            };
            const idx: u32 = @intCast(pool.items.len);
            try pool.append(gpa, .{ .kind = .has, .component_id = id });
            has_component_ref.* = true;
            return idx;
        },
        .resource => {
            const tname = ast.strings.slice(node.type_name);
            const rid = bridge.resourceIdOf(tname) orelse return error.InvalidProgram;
            try res_deps.append(gpa, .{ .resource_id = rid, .must_be_changed = false });
            return PredicateNode.no_child;
        },
        .resource_changed => {
            const tname = ast.strings.slice(node.type_name);
            const rid = bridge.resourceIdOf(tname) orelse return error.InvalidProgram;
            try res_deps.append(gpa, .{ .resource_id = rid, .must_be_changed = true });
            return PredicateNode.no_child;
        },
    }
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

    // A `T[]`-annotated dynamic array — the interpreter is its reference
    // execution (codegen for dynamic arrays is deferred, heap/arena model).
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
    // interpreter is the reference execution (map codegen is deferred). The
    // sum (10 + 20 + 30 = 60) is order-invariant, matching the unordered-map
    // contract.
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

    // The throw aborts the rest of the try body (x stays 1) and is caught,
    // binding the thrown value into `err`; x ends at 99. The interpreter is the
    // reference execution (try/catch codegen is deferred).
    const source =
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut x = 1
        \\  try {
        \\    x = 2
        \\    throw 99
        \\    x = 3
        \\  } catch err {
        \\    x = err
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
    try std.testing.expectEqual(@as(i64, 99), out);
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
        \\  throw 7
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
