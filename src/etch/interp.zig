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

const StmtError = error{ OutOfMemory, RuntimeFailure };

/// S4 tree-walking interpreter — owns the bridge state, evaluates
/// the type-checked AST against a `World` once per tick.
pub const Interpreter = struct {
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    bridge: Bridge,
    rule_descs: []RuleDesc,

    pub fn deinit(self: *Interpreter) void {
        for (self.rule_descs) |*r| r.deinit(self.gpa);
        self.gpa.free(self.rule_descs);
        self.bridge.deinit(self.gpa);
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

        const slice = try rule_descs.toOwnedSlice(gpa);
        return .{
            .gpa = gpa,
            .ast = ast,
            .bridge = bridge,
            .rule_descs = slice,
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
        try bindParams(self.gpa, self.ast, rule, entity_id, &locals);

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
                else => return error.RuntimeFailure,
            }
        }
        return error.RuntimeFailure;
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
