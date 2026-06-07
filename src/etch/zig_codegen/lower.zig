//! AST → Zig source lowering for the S5 Etch codegen.
//!
//! The lowering pass consumes an `AstArena` that has already passed the S3
//! two-pass type-checker and emits a single human-readable Zig source file
//! per Etch program. Output layout (per `briefs/S5-etch-codegen-zig.md`
//! Scope — "Generated file layout — readable, not minified"):
//!
//!     // Auto-generated from <source>.etch — DO NOT EDIT
//!     const std = @import("std");
//!     const weld_core = @import("weld_core");
//!     ...
//!     pub const <Comp> = extern struct { ... };   // 1 per Etch component
//!     pub const <Res>  = extern struct { ... };   // 1 per Etch resource
//!     pub fn register(world, gpa) !void { ... }   // RTTI + resource init
//!     pub fn rule_<name>(world: *World) void { .. } // 1 per Etch rule
//!     pub fn tick(world: *World) void { ... }     // calls each rule in
//!                                                  // source order
//!
//! Implementation choices (cf. brief Notes):
//! - `extern struct` types match Etch component names verbatim (no prefix).
//! - `int` → `i64`, `float` → `f64`, `bool` → `bool`; user types map to the
//!   matching generated struct.
//! - Rules walk `world.archetypes` (dynamic side) and `@ptrCast` the SoA
//!   slot pointer to `[*]<Comp>`. The component layout computed by the
//!   runtime registry matches the Zig `extern struct` layout exactly
//!   (same `@offsetOf` semantics on both sides) so the cast is well-formed.
//! - Rules are emitted in source declaration order; `tick(world)` invokes
//!   them sequentially, matching the S4 interpreter's scheduler so
//!   differential corpus parity holds.

const std = @import("std");
const ast_mod = @import("../ast.zig");
const types_mod = @import("../types.zig");
const emit_mod = @import("emit.zig");
const type_map = @import("type_map.zig");
const errors_mod = @import("errors.zig");

const CodegenError = errors_mod.CodegenError;
const Writer = emit_mod.Writer;
const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;
const StringId = ast_mod.StringId;

// ─── Public surface ─────────────────────────────────────────────────────────

/// Stats reported back to the caller. Used by the bench to count
/// distinct archetype signatures and rule monomorphisations.
pub const GenerateStats = struct {
    components: u32 = 0,
    resources: u32 = 0,
    rules: u32 = 0,
    /// Distinct `(component_name, ...)` tuples reached by rule when-clauses.
    /// Reported in the bench for the monomorphisation gate.
    distinct_signatures: u32 = 0,
};

/// Emit the entire program. `source_path` is recorded in the file header.
/// The caller owns `buffer` — its capacity may grow during emission.
pub fn generateFile(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    source_path: []const u8,
    buffer: *std.ArrayListUnmanaged(u8),
) CodegenError!GenerateStats {
    var w = Writer.init(gpa, buffer);

    try emitHeader(&w, source_path);
    try emitImports(&w);

    var stats: GenerateStats = .{};

    // Pass A — declare every component and resource as an `extern struct`.
    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        const kind = ast.items.items(.kind)[i];
        const data = ast.items.items(.data)[i];
        switch (kind) {
            .component_decl => {
                try emitComponentLikeStruct(&w, ast, data, .component);
                stats.components += 1;
            },
            .resource_decl => {
                try emitComponentLikeStruct(&w, ast, data, .resource);
                stats.resources += 1;
            },
            else => {},
        }
    }

    // Pass B — `register` function. Walk items again to keep registration
    // order matching source order.
    try emitRegister(&w, ast);

    // Pass C — emit one Zig function per Etch rule.
    var rule_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rule_names.deinit(gpa);

    var sig_set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = sig_set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        sig_set.deinit(gpa);
    }

    i = 0;
    while (i < ast.items.len) : (i += 1) {
        const kind = ast.items.items(.kind)[i];
        const data = ast.items.items(.data)[i];
        if (kind != .rule_decl) continue;
        const rule = ast.rule_decls.items[data];
        const name_slice = ast.strings.slice(rule.name);
        try rule_names.append(gpa, name_slice);

        try emitRule(&w, ast, rule);
        stats.rules += 1;

        // Track the rule's archetype signature (the sorted set of component
        // names referenced by its when clause).
        try collectSignature(gpa, ast, rule, &sig_set);
    }

    try emitTick(&w, rule_names.items);

    stats.distinct_signatures = @intCast(sig_set.count());
    return stats;
}

// ─── Header / imports ───────────────────────────────────────────────────────

fn emitHeader(w: *Writer, source_path: []const u8) CodegenError!void {
    try w.printLine("// Auto-generated from {s} — DO NOT EDIT", .{source_path});
    try w.line("// Produced by src/etch/zig_codegen/ on the S5 Etch codegen pipeline.");
    try w.blankLine();
}

fn emitImports(w: *Writer) CodegenError!void {
    try w.line("const std = @import(\"std\");");
    try w.line("const weld_core = @import(\"weld_core\");");
    try w.line("const World = weld_core.ecs.world.World;");
    try w.line("const ComponentId = weld_core.ecs.registry.ComponentId;");
    try w.line("const FieldDesc = weld_core.ecs.registry.FieldDesc;");
    try w.line("const FieldKind = weld_core.ecs.registry.FieldKind;");
    try w.line("const DynamicArchetype = weld_core.ecs.archetype_dynamic.DynamicArchetype;");
    try w.line("const Chunk = weld_core.ecs.archetype_dynamic.Chunk;");
    try w.line("const comptime_query = weld_core.ecs.comptime_query;");
    try w.blankLine();
}

// ─── Component / resource as extern struct ─────────────────────────────────

const DeclKind = enum { component, resource };

fn emitComponentLikeStruct(w: *Writer, ast: *const AstArena, data: u32, kind: DeclKind) CodegenError!void {
    // Both ComponentDecl and ResourceDecl share the same layout for our
    // purposes — we only care about (name, fields_start, fields_len).
    const name: []const u8 = switch (kind) {
        .component => ast.strings.slice(ast.component_decls.items[data].name),
        .resource => ast.strings.slice(ast.resource_decls.items[data].name),
    };
    const fields_start: u32 = switch (kind) {
        .component => ast.component_decls.items[data].fields_start,
        .resource => ast.resource_decls.items[data].fields_start,
    };
    const fields_len: u32 = switch (kind) {
        .component => ast.component_decls.items[data].fields_len,
        .resource => ast.resource_decls.items[data].fields_len,
    };

    try w.printLine("pub const {s} = extern struct {{", .{name});
    w.indentBy(1);
    var f_i: u32 = 0;
    while (f_i < fields_len) : (f_i += 1) {
        const f = ast.fields.items[fields_start + f_i];
        const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
        // Resolve through any `type` alias chain (M0.8): `x: Meters` where
        // `type Meters = float` emits as `x: f64`, identical to the layout
        // the interpreter computes, keeping the differential byte-exact.
        const etch_type = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
        const zig_type = type_map.mapBuiltin(etch_type) orelse return CodegenError.NonPodComponent;
        const fname = ast.strings.slice(f.name);
        if (f.default_value.isNone()) {
            try w.writeIndent();
            try w.ident(fname);
            try w.print(": {s} = {s},\n", .{ zig_type, zeroDefault(zig_type) });
        } else {
            // Emit the default expression. The S3 type-checker has already
            // verified it is const-evaluable on the field type.
            try w.writeIndent();
            try w.ident(fname);
            try w.print(": {s} = ", .{zig_type});
            try emitConstExpr(w, ast, f.default_value, zig_type);
            try w.write(",\n");
        }
    }
    w.indentBy(-1);
    try w.line("};");
    try w.blankLine();
}

fn zeroDefault(zig_type: []const u8) []const u8 {
    if (type_map.isFloatLikeZigType(zig_type)) return "0.0";
    if (std.mem.eql(u8, zig_type, "bool")) return "false";
    return "0";
}

// ─── `register` function ────────────────────────────────────────────────────

fn emitRegister(w: *Writer, ast: *const AstArena) CodegenError!void {
    try w.line("/// Register every component and resource declared in the source");
    try w.line("/// program with the world's RTTI and seed the resource store.");
    try w.line("/// Must be called once at program start, before `tick`.");
    try w.line("///");
    try w.line("/// Uses `registerComponentRaw` with the explicit Etch type name so");
    try w.line("/// `world.registry.idOf(\"Counter\")` works regardless of the file's");
    try w.line("/// package path (the comptime helper `registerComponent` would key");
    try w.line("/// by `@typeName(T)`, which carries the module path on top-level");
    try w.line("/// generated files and breaks name-based lookup).");
    try w.line("pub fn register(world: *World, gpa: std.mem.Allocator) !void {");
    w.indentBy(1);

    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        const kind = ast.items.items(.kind)[i];
        const data = ast.items.items(.data)[i];
        switch (kind) {
            .component_decl => {
                const decl = ast.component_decls.items[data];
                try emitRegisterCall(w, ast, ast.strings.slice(decl.name), decl.fields_start, decl.fields_len, false);
            },
            .resource_decl => {
                const decl = ast.resource_decls.items[data];
                try emitRegisterCall(w, ast, ast.strings.slice(decl.name), decl.fields_start, decl.fields_len, true);
            },
            else => {},
        }
    }

    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

fn emitRegisterCall(
    w: *Writer,
    ast: *const AstArena,
    name: []const u8,
    fields_start: u32,
    fields_len: u32,
    is_resource: bool,
) CodegenError!void {
    // Emit a scoped block per type so the local `default`, `fields` and the
    // computed `id` do not collide across registrations.
    try w.line("{");
    w.indentBy(1);
    try w.printLine("var default: {s} = .{{}};", .{name});
    try w.printLine("var fields = [_]FieldDesc{{", .{});
    w.indentBy(1);
    var f_i: u32 = 0;
    while (f_i < fields_len) : (f_i += 1) {
        const f = ast.fields.items[fields_start + f_i];
        const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
        // Resolve through any `type` alias chain (M0.8), matching the struct
        // emission and the interpreter's FieldKind resolution.
        const etch_t = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
        const zig_t = type_map.mapBuiltin(etch_t) orelse return CodegenError.NonPodComponent;
        const fname = ast.strings.slice(f.name);
        const fkind = fieldKindLiteral(zig_t);
        try w.printLine(".{{ .name = \"{s}\", .offset = @offsetOf({s}, \"{s}\"), .kind = {s} }},", .{ fname, name, fname, fkind });
    }
    w.indentBy(-1);
    try w.line("};");
    try w.printLine("const {s}_id = try world.registry.registerComponentRaw(gpa, .{{", .{name});
    w.indentBy(1);
    try w.printLine(".name = \"{s}\",", .{name});
    try w.printLine(".size = @sizeOf({s}),", .{name});
    try w.printLine(".alignment = @alignOf({s}),", .{name});
    try w.printLine(".default_bytes = std.mem.asBytes(&default),", .{});
    try w.printLine(".fields = &fields,", .{});
    w.indentBy(-1);
    try w.line("});");
    // Register the Zig type-name as an alias for the same id so the
    // comptime `world.query(.{T})` (keyed on `@typeName(T)`) resolves to
    // the same `ComponentId` as `world.registry.idOf("EtchName")`.
    // `registerAlias` consumes the id, so no extra discard is needed.
    try w.printLine("try world.registry.registerAlias(gpa, @typeName({s}), {s}_id);", .{ name, name });
    if (is_resource) {
        try w.printLine("try world.addResource(gpa, {s}_id, std.mem.asBytes(&default));", .{name});
    }
    w.indentBy(-1);
    try w.line("}");
}

fn fieldKindLiteral(zig_type: []const u8) []const u8 {
    if (std.mem.eql(u8, zig_type, "i64")) return "FieldKind.int_";
    if (std.mem.eql(u8, zig_type, "f64")) return "FieldKind.float_";
    if (std.mem.eql(u8, zig_type, "bool")) return "FieldKind.bool_";
    if (std.mem.eql(u8, zig_type, "i32")) return "FieldKind.i32_";
    if (std.mem.eql(u8, zig_type, "u32")) return "FieldKind.u32_";
    if (std.mem.eql(u8, zig_type, "f32")) return "FieldKind.f32_";
    if (std.mem.eql(u8, zig_type, "f64")) return "FieldKind.f64_";
    // Unreachable per the S3 type-checker — kept defensive.
    return "FieldKind.int_";
}

// ─── Rules ──────────────────────────────────────────────────────────────────

/// Information collected from a rule's when clause that the body emitter
/// needs: the resource gates, the field filter (if any), the components
/// referenced (sorted by interned StringId for stable iteration), the
/// rule's entity-param name (if any).
const WhenInfo = struct {
    /// Names of components reached by `has` / `has_with_filter` nodes,
    /// deduplicated.
    components: [][]const u8,
    /// Resource dependencies — name + must-be-changed flag.
    resource_deps: []ResourceDep,
    /// Up to one field filter (S3 limitation per S4 brief debt).
    field_filter: ?FieldFilter,
    /// True iff the when clause contains at least one component-side
    /// predicate (i.e. the rule iterates entities).
    has_component_ref: bool,
    /// True iff the when clause contains `or` or `not` — the codegen
    /// falls back to the manual archetype walk in that case. Pure AND
    /// conjunctions use the comptime `world.query(.{...})` path, which
    /// is what gates the monomorphisation count (Gate 4).
    has_or_or_not: bool,
};

const ResourceDep = struct {
    name: []const u8,
    must_be_changed: bool,
};

const FieldFilter = struct {
    component_name: []const u8,
    field_name: []const u8,
    /// The filter value expression (kept as a NodeId so the body emitter
    /// can use the same `emitConstExpr` path as field defaults).
    value: NodeId,
    /// Inferred from the filter operand kind so the generated comparison
    /// emits the right literal style (`== true`, `== 5.0`, etc.).
    value_zig_type: []const u8,
};

fn emitRule(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl) CodegenError!void {
    const name = ast.strings.slice(rule.name);
    try w.printLine("pub fn rule_{s}(world: *World) void {{", .{name});
    w.indentBy(1);

    // Collect what the when clause needs.
    var info = try collectWhenInfo(w.gpa, ast, rule);
    defer freeWhenInfo(w.gpa, &info);

    // Resource-id locals + gating early-returns.
    for (info.resource_deps) |dep| {
        try w.printLine("const {s}_id = world.registry.idOf(\"{s}\") orelse return;", .{ dep.name, dep.name });
        if (dep.must_be_changed) {
            try w.printLine("if (!world.resources.isDirty({s}_id)) return;", .{dep.name});
        } else {
            try w.printLine("if (!world.resources.contains({s}_id)) return;", .{dep.name});
        }
    }

    if (!info.has_component_ref) {
        // Resource-only or no-when rule: body runs at most once per tick.
        try emitRuleBodyOnce(w, ast, rule);
        w.indentBy(-1);
        try w.line("}");
        try w.blankLine();
        return;
    }

    // Determine the body's component access set so we can size the query
    // tuple to exactly what the body reads/writes (the same `body_used`
    // dance the archetype-walk path needed). The field-filter component
    // is accessed implicitly at the slot level — fold it in.
    var body_used: std.StringHashMapUnmanaged(void) = .empty;
    defer body_used.deinit(w.gpa);
    try collectBodyComponents(w.gpa, ast, rule, &body_used);
    if (info.field_filter) |ff| {
        _ = try body_used.getOrPut(w.gpa, ff.component_name);
    }

    if (info.has_or_or_not) {
        // Path 2 — manual archetype walk. Reserved for the S4 inherited
        // debt cases (`not has X`, `entity has A or entity has B`) that
        // do not collapse to a single AND-conjunction tuple. The current
        // S3 corpus exercises this in 2/20 differential programs; the
        // synth bench corpus never hits this branch (gate 4's
        // monomorphisation count therefore reflects only the AND path).
        try emitRuleAsArchWalk(w, ast, rule, info, &body_used);
    } else {
        // Path 1 — comptime query. The cooked code emits one
        // `comptime_query.query(world, .{T1, T2, ...})` invocation per
        // rule signature; Zig comptime monomorphises one iterator type
        // per distinct tuple.
        try emitRuleAsComptimeQuery(w, ast, rule, info, &body_used);
    }

    w.indentBy(-1);
    try w.line("}"); // fn
    try w.blankLine();
}

/// Emit the body of a rule using the comptime `world.query(.{...})` path.
/// `body_used` lists the component names the body actually reads/writes;
/// those become the query tuple (in source declaration order from
/// `info.components`). Components named in the when clause but not
/// reached by the body are still required for archetype matching — they
/// also appear in the tuple, otherwise the iterator would yield rows
/// from archetypes that satisfy a strictly weaker predicate than the
/// rule asked for.
fn emitRuleAsComptimeQuery(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, body_used: *const std.StringHashMapUnmanaged(void)) CodegenError!void {
    _ = body_used;

    // Query tuple = full set of `has`-conjunction components, ordered as
    // emitted by `collectWhenInfo` (source order). Including unused-by-
    // body components ensures the predicate stays correct — `has A and
    // has B { f == v }` requires both `A` and `B` in the archetype even
    // if only `B` is read.
    try w.writeIndent();
    try w.write("var __it = comptime_query.query(world, .{");
    for (info.components, 0..) |cname, i| {
        if (i > 0) try w.write(", ");
        try w.print("{s}", .{cname});
    }
    try w.write("});\n");

    try w.line("while (__it.next()) |__row| {");
    w.indentBy(1);

    // Field filter — emit as a continue guard, addressing the row by tuple
    // index for the filter's component.
    if (info.field_filter) |ff| {
        const idx = indexOfComponent(info.components, ff.component_name) orelse return CodegenError.InternalCodegenBug;
        try w.writeIndent();
        try w.print("if (__row[{d}].", .{idx});
        try w.ident(ff.field_name);
        try w.write(" != ");
        try emitConstExpr(w, ast, ff.value, ff.value_zig_type);
        try w.write(") continue;\n");
    }

    try emitRuleBodyQuery(w, ast, rule, info);

    w.indentBy(-1);
    try w.line("}"); // while it.next()
}

/// Emit the body of a rule using the manual archetype-walk fallback for
/// when clauses containing `or` / `not`. Same shape as the pre-rewrite
/// codegen — kept until the inherited S4 debts (`not` / `or` predicates)
/// are addressed in Phase 0.2.
fn emitRuleAsArchWalk(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, body_used: *const std.StringHashMapUnmanaged(void)) CodegenError!void {
    for (info.components) |cname| {
        try w.printLine("const {s}_id = world.registry.idOf(\"{s}\") orelse return;", .{ cname, cname });
    }

    try w.line("for (world.archetypes.items) |arch| {");
    w.indentBy(1);
    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        try w.writeIndent();
        try w.write("if (!(");
        try emitArchPredicate(w, ast, rule.when_root);
        try w.write(")) continue;\n");
    }
    for (info.components) |cname| {
        if (!body_used.contains(cname)) continue;
        try w.printLine("const {s}_idx = arch.componentIndex({s}_id).?;", .{ cname, cname });
        try w.printLine("const {s}_off = arch.layout.component_offsets[{s}_idx];", .{ cname, cname });
    }
    try w.line("for (arch.chunks.items) |chunk| {");
    w.indentBy(1);
    try w.line("const __count: u32 = chunk.header().entity_count;");
    for (info.components) |cname| {
        if (!body_used.contains(cname)) continue;
        try w.printLine("const {s}_arr: [*]{s} = @ptrCast(@alignCast(&chunk.bytes[{s}_off]));", .{ cname, cname, cname });
    }
    try w.line("var slot: u32 = 0;");
    try w.line("while (slot < __count) : (slot += 1) {");
    w.indentBy(1);
    if (info.field_filter) |ff| {
        try w.writeIndent();
        try w.print("if ({s}_arr[slot].", .{ff.component_name});
        try w.ident(ff.field_name);
        try w.write(" != ");
        try emitConstExpr(w, ast, ff.value, ff.value_zig_type);
        try w.write(") continue;\n");
    }
    try emitRuleBody(w, ast, rule, info);
    w.indentBy(-1);
    try w.line("}"); // while slot
    w.indentBy(-1);
    try w.line("}"); // for chunk
    w.indentBy(-1);
    try w.line("}"); // for arch
}

fn indexOfComponent(comps: []const []const u8, name: []const u8) ?usize {
    for (comps, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

/// Emit the source-level expression that names the current slot of
/// component `comp_name`. Inside a comptime-query iteration, that is
/// `__row[idx]` where `idx` is the component's position in the query
/// tuple; in the archetype-walk fallback, it is `<comp>_arr[slot]`.
fn emitComponentSlot(w: *Writer, ctx: *LocalCtx, comp_name: []const u8) CodegenError!void {
    if (ctx.query_components) |comps| {
        if (indexOfComponent(comps, comp_name)) |idx| {
            try w.print("__row[{d}]", .{idx});
            return;
        }
    }
    try w.print("{s}_arr[slot]", .{comp_name});
}

/// Walk every statement in the rule body and add the component name of
/// each `entity.get(T)` / `entity.get_mut(T)` accessor to `out`. Used by
/// the rule emitter to decide which components need a per-slot pointer
/// vs. only an id (the latter is enough for `arch.hasComponent` checks).
fn collectBodyComponents(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    rule: ast_mod.RuleDecl,
    out: *std.StringHashMapUnmanaged(void),
) !void {
    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        const stmt_raw = ast.extra.items[rule.body_start + s];
        const stmt_id: NodeId = @bitCast(stmt_raw);
        try walkStmtForComponents(gpa, ast, stmt_id, out);
    }
}

fn walkStmtForComponents(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    stmt_id: NodeId,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const kind = ast.stmtKind(stmt_id);
    const data = ast.stmtData(stmt_id);
    switch (kind) {
        .let_stmt => {
            const let = ast.let_stmts.items[data];
            try walkExprForComponents(gpa, ast, let.value, out);
        },
        .assign_stmt => {
            const assign = ast.assign_stmts.items[data];
            try walkExprForComponents(gpa, ast, assign.target, out);
            try walkExprForComponents(gpa, ast, assign.value, out);
        },
        .expr_stmt => {
            const eid: NodeId = @bitCast(data);
            try walkExprForComponents(gpa, ast, eid, out);
        },
        .assert_stmt => {
            const a = ast.assert_stmts.items[data];
            try walkExprForComponents(gpa, ast, a.cond, out);
        },
        .for_stmt => {
            const f = ast.for_stmts.items[data];
            try walkExprForComponents(gpa, ast, f.iterable, out);
            var s: u32 = 0;
            while (s < f.body_len) : (s += 1) {
                try walkStmtForComponents(gpa, ast, @bitCast(ast.extra.items[f.body_start + s]), out);
            }
        },
        .break_stmt => {
            const b = ast.break_stmts.items[data];
            if (!b.value.isNone()) try walkExprForComponents(gpa, ast, b.value, out);
        },
        else => {},
    }
}

fn walkExprForComponents(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    expr: NodeId,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    switch (kind) {
        .method_get, .method_get_mut => {
            const mg = ast.method_gets.items[data];
            // Receiver-less `get(R)` accesses a resource, not a component —
            // it must not enter the query tuple (D-S3-resource-receiver).
            if (mg.receiver.isNone()) return;
            const cname = ast.strings.slice(mg.type_name);
            _ = try out.getOrPut(gpa, cname);
        },
        .field_access => {
            const fa = ast.field_accesses.items[data];
            try walkExprForComponents(gpa, ast, fa.receiver, out);
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            try walkExprForComponents(gpa, ast, b.lhs, out);
            try walkExprForComponents(gpa, ast, b.rhs, out);
        },
        .unary => {
            const u = ast.unary_exprs.items[data];
            try walkExprForComponents(gpa, ast, u.operand, out);
        },
        .cast => {
            const c = ast.casts.items[data];
            try walkExprForComponents(gpa, ast, c.operand, out);
        },
        .range => {
            const r = ast.ranges.items[data];
            try walkExprForComponents(gpa, ast, r.start, out);
            try walkExprForComponents(gpa, ast, r.end, out);
        },
        .array_lit => {
            const al = ast.array_lits.items[data];
            var i: u32 = 0;
            while (i < al.elements_len) : (i += 1) {
                try walkExprForComponents(gpa, ast, @bitCast(ast.extra.items[al.elements_start + i]), out);
            }
            if (al.is_fill) try walkExprForComponents(gpa, ast, al.fill_count, out);
        },
        .index => {
            const ix = ast.index_exprs.items[data];
            try walkExprForComponents(gpa, ast, ix.receiver, out);
            try walkExprForComponents(gpa, ast, ix.index, out);
        },
        .closure => {
            try walkExprForComponents(gpa, ast, ast.closure_exprs.items[data].body, out);
        },
        .loop_expr => {
            const lp = ast.loop_exprs.items[data];
            var s: u32 = 0;
            while (s < lp.body_len) : (s += 1) {
                try walkStmtForComponents(gpa, ast, @bitCast(ast.extra.items[lp.body_start + s]), out);
            }
        },
        .fn_call => {
            const call = ast.call_exprs.items[data];
            try walkExprForComponents(gpa, ast, call.callee, out);
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                try walkExprForComponents(gpa, ast, @bitCast(ast.extra.items[call.args_start + i]), out);
            }
        },
        .match_expr => {
            const m = ast.match_exprs.items[data];
            try walkExprForComponents(gpa, ast, m.scrutinee, out);
            var i: u32 = 0;
            while (i < m.arms_len) : (i += 1) {
                try walkExprForComponents(gpa, ast, ast.match_arms.items[m.arms_start + i].body, out);
            }
        },
        .block_expr => {
            const blk = ast.block_exprs.items[data];
            var s: u32 = 0;
            while (s < blk.body_len) : (s += 1) {
                try walkStmtForComponents(gpa, ast, @bitCast(ast.extra.items[blk.body_start + s]), out);
            }
            if (!blk.value.isNone()) try walkExprForComponents(gpa, ast, blk.value, out);
        },
        else => {},
    }
}

fn emitArchPredicate(w: *Writer, ast: *const AstArena, when_idx: u32) CodegenError!void {
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and => {
            try w.write("(");
            try emitArchPredicate(w, ast, node.lhs);
            try w.write(") and (");
            try emitArchPredicate(w, ast, node.rhs);
            try w.write(")");
        },
        .logical_or => {
            try w.write("(");
            try emitArchPredicate(w, ast, node.lhs);
            try w.write(") or (");
            try emitArchPredicate(w, ast, node.rhs);
            try w.write(")");
        },
        .logical_not => {
            try w.write("!(");
            try emitArchPredicate(w, ast, node.lhs);
            try w.write(")");
        },
        .has, .has_with_filter => {
            const cname = ast.strings.slice(node.type_name);
            try w.print("arch.hasComponent({s}_id)", .{cname});
        },
        .resource, .resource_changed => {
            // Resource gates are tested ahead of the archetype loop (in
            // `emitRule`); inside the archetype predicate they evaluate to
            // a constant `true`.
            try w.write("true");
        },
    }
}

/// Emit a rule body that does NOT iterate entities (resource-only rule).
fn emitRuleBodyOnce(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl) CodegenError!void {
    // No component_ref → still need a (degenerate) LocalCtx for any
    // non-component locals the body might declare.
    var ctx: LocalCtx = .{};
    defer ctx.deinit(w.gpa);
    try ctx.recordParams(w.gpa, ast, rule);
    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        const stmt_raw = ast.extra.items[rule.body_start + s];
        const stmt_id: NodeId = @bitCast(stmt_raw);
        try emitStmt(w, ast, &ctx, stmt_id);
    }
}

fn emitRuleBody(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo) CodegenError!void {
    var ctx: LocalCtx = .{};
    defer ctx.deinit(w.gpa);

    // Record component aliases so `entity.get(T)` / `entity.get_mut(T)`
    // expressions emit as `<T>_arr[slot]`.
    for (info.components) |cname| {
        try ctx.records.append(w.gpa, .{
            .key = .{ .component_alias = cname },
            .info = .{ .kind = .component_alias, .component_name = cname, .is_mut = true },
        });
    }
    try ctx.recordParams(w.gpa, ast, rule);

    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        const stmt_raw = ast.extra.items[rule.body_start + s];
        const stmt_id: NodeId = @bitCast(stmt_raw);
        try emitStmt(w, ast, &ctx, stmt_id);
    }
}

/// Variant of `emitRuleBody` used inside the comptime-query iteration.
/// Sets `ctx.query_components` so component accesses lower to
/// `__row[idx].field` instead of `<comp>_arr[slot].field`.
fn emitRuleBodyQuery(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo) CodegenError!void {
    var ctx: LocalCtx = .{
        .query_components = info.components,
    };
    defer ctx.deinit(w.gpa);
    for (info.components) |cname| {
        try ctx.records.append(w.gpa, .{
            .key = .{ .component_alias = cname },
            .info = .{ .kind = .component_alias, .component_name = cname, .is_mut = true },
        });
    }
    try ctx.recordParams(w.gpa, ast, rule);

    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        const stmt_raw = ast.extra.items[rule.body_start + s];
        const stmt_id: NodeId = @bitCast(stmt_raw);
        try emitStmt(w, ast, &ctx, stmt_id);
    }
}

// ─── Statement / expression emitters ────────────────────────────────────────

const LocalKind = enum {
    value,
    component_alias,
};

const LocalInfo = struct {
    kind: LocalKind,
    /// For `component_alias`, the component name. For `value`, the inferred
    /// Zig type emitted in the `var`/`const` declaration (so subsequent uses
    /// know how to format compound assignments).
    component_name: []const u8 = "",
    zig_type: []const u8 = "",
    is_mut: bool = false,
};

const LocalKey = union(enum) {
    /// Named local — addressed by ident.
    name: StringId,
    /// Component alias — addressed by the component name (for the implicit
    /// `entity.get(T)` machinery).
    component_alias: []const u8,
};

const LocalRecord = struct {
    key: LocalKey,
    info: LocalInfo,
};

const LocalCtx = struct {
    /// Stack of records; lookups walk from the top so the most recent
    /// declaration wins. S3 forbids shadowing within a single scope so the
    /// stack stays flat for compliant programs.
    records: std.ArrayListUnmanaged(LocalRecord) = .empty,
    /// When non-null, the body is emitted inside a `comptime_query.query`
    /// iteration — component accesses lower to `__row[idx].field` where
    /// `idx` is the component's index in this tuple. When null, the body
    /// is in the manual archetype-walk fallback and component accesses
    /// lower to `<comp>_arr[slot].field`.
    query_components: ?[]const []const u8 = null,

    pub fn deinit(self: *LocalCtx, gpa: std.mem.Allocator) void {
        self.records.deinit(gpa);
    }

    pub fn lookup(self: *const LocalCtx, name: StringId) ?LocalInfo {
        var i: usize = self.records.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.records.items[i];
            switch (r.key) {
                .name => |sid| if (sid == name) return r.info,
                .component_alias => {},
            }
        }
        return null;
    }

    pub fn componentAliasMatches(self: *const LocalCtx, name: []const u8) bool {
        for (self.records.items) |r| {
            switch (r.key) {
                .component_alias => |c| if (std.mem.eql(u8, c, name)) return true,
                .name => {},
            }
        }
        return false;
    }

    pub fn recordParams(self: *LocalCtx, gpa: std.mem.Allocator, ast: *const AstArena, rule: ast_mod.RuleDecl) !void {
        var p_i: u32 = 0;
        while (p_i < rule.params_len) : (p_i += 1) {
            const p = ast.rule_params.items[rule.params_start + p_i];
            const tnode = ast.named_types.items[ast.typeNodeData(p.type_node)];
            const tname = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
            if (std.mem.eql(u8, tname, "Entity")) {
                // Entity params are handled by the iteration machinery; the
                // ident never reaches `emitExpr` in compliant S3 programs.
                continue;
            }
            const zig_t = type_map.mapBuiltin(tname) orelse tname;
            try self.records.append(gpa, .{
                .key = .{ .name = p.name },
                .info = .{ .kind = .value, .zig_type = zig_t, .is_mut = false },
            });
        }
    }
};

fn emitStmt(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, stmt_id: NodeId) CodegenError!void {
    const kind = ast.stmtKind(stmt_id);
    const data = ast.stmtData(stmt_id);
    switch (kind) {
        .let_stmt => {
            const let = ast.let_stmts.items[data];
            try emitLet(w, ast, ctx, let);
        },
        .assign_stmt => {
            const assign = ast.assign_stmts.items[data];
            try emitAssign(w, ast, ctx, assign);
        },
        .expr_stmt => {
            const eid: NodeId = @bitCast(data);
            const ek = ast.exprKind(eid);
            // Control-flow expressions in statement position emit as Zig
            // statements (no `_ = ...;` discard): a bare `loop { ... }` (M0.8
            // loop/break) and a bare block `{ ... }` whose value is discarded.
            if (ek == .loop_expr) {
                try w.writeIndent();
                try emitExpr(w, ast, ctx, eid);
                try w.write("\n");
                return;
            }
            if (ek == .block_expr) {
                try emitBlockExprStmts(w, ast, ctx, ast.exprData(eid));
                return;
            }
            try w.writeIndent();
            // Side-effect-only expression statement: typically a bare
            // `entity.get_mut(T)` discard. Emit as `_ = <expr>;` so Zig
            // doesn't complain about unused values.
            try w.write("_ = ");
            try emitExpr(w, ast, ctx, eid);
            try w.write(";\n");
        },
        .assert_stmt => {
            // `assert(cond)` → a self-contained guard. `unreachable` panics in
            // Debug/ReleaseSafe (the §10.3 dev-build behaviour) and is elided
            // in ReleaseFast. The optional message is a dev diagnostic dropped
            // in codegen. No `std` dependency (etch_cook strips imports).
            const a = ast.assert_stmts.items[data];
            try w.writeIndent();
            try w.write("if (!(");
            try emitExpr(w, ast, ctx, a.cond);
            try w.write(")) unreachable;\n");
        },
        .for_stmt => {
            // `for v in start..end { body }` → a Zig `while` over an i64
            // counter (M0.8 v0.6 foundations). The range bounds are read
            // directly (a range has no standalone Zig value). The loop var is
            // recorded as a value local for the body's ident resolution.
            const f = ast.for_stmts.items[data];
            const vname = ast.strings.slice(f.var_name);
            if (ast.exprKind(f.iterable) == .range) {
                // `for v in start..end { body }` → a Zig `while` over an i64
                // counter (the range has no standalone Zig value). The loop var
                // is recorded as a value local for the body's ident resolution.
                const r = ast.ranges.items[ast.exprData(f.iterable)];
                try w.writeIndent();
                try w.write("{ var ");
                try w.ident(vname);
                try w.write(": i64 = ");
                try emitExpr(w, ast, ctx, r.start);
                try w.write("; while (");
                try w.ident(vname);
                try w.write(if (r.inclusive) " <= " else " < ");
                try emitExpr(w, ast, ctx, r.end);
                try w.write(") : (");
                try w.ident(vname);
                try w.write(" += 1) {\n");
                w.indentBy(1);
                const saved = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{ .key = .{ .name = f.var_name }, .info = .{ .kind = .value, .zig_type = "i64", .is_mut = false } });
                var s: u32 = 0;
                while (s < f.body_len) : (s += 1) {
                    try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[f.body_start + s]));
                }
                ctx.records.items.len = saved;
                w.indentBy(-1);
                try w.writeIndent();
                try w.write("} }\n");
            } else {
                // A two-binding for-in is a map iteration (`for k, v in m`) —
                // map codegen is deferred (heap / arena model), interpreter is
                // the reference. Single-binding only here.
                if (f.index_name != 0) return CodegenError.UnsupportedConstruct;
                // `for v in <array> { body }` → Zig `for (<array>) |v| { ... }`
                // (M0.8 collections). E1 codegen supports fixed-array iterables;
                // the loop variable binds each element by value. Zig infers the
                // element type, so the local is recorded with no zig_type.
                try w.writeIndent();
                try w.write("for (");
                try emitExpr(w, ast, ctx, f.iterable);
                try w.write(") |");
                try w.ident(vname);
                try w.write("| {\n");
                w.indentBy(1);
                const saved = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{ .key = .{ .name = f.var_name }, .info = .{ .kind = .value, .zig_type = "", .is_mut = false } });
                var s: u32 = 0;
                while (s < f.body_len) : (s += 1) {
                    try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[f.body_start + s]));
                }
                ctx.records.items.len = saved;
                w.indentBy(-1);
                try w.writeIndent();
                try w.write("}\n");
            }
        },
        .break_stmt => {
            // `break [:label] [value]` (M0.8 loop/break).
            const b = ast.break_stmts.items[data];
            try w.writeIndent();
            try w.write("break");
            if (b.label != 0) {
                try w.write(" :");
                try w.ident(ast.strings.slice(b.label));
            }
            if (!b.value.isNone()) {
                try w.write(" ");
                try emitExpr(w, ast, ctx, b.value);
            }
            try w.write(";\n");
        },
        .continue_stmt => {
            // `continue [:label]` — the label id is stored directly in `data`.
            try w.writeIndent();
            try w.write("continue");
            if (data != 0) {
                try w.write(" :");
                try w.ident(ast.strings.slice(data));
            }
            try w.write(";\n");
        },
        else => return CodegenError.UnsupportedConstruct,
    }
}

fn emitLet(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, let: ast_mod.LetStmt) CodegenError!void {
    const value_kind = ast.exprKind(let.value);
    if (value_kind == .method_get or value_kind == .method_get_mut) {
        // `let h = entity.get(T)` / `let h = entity.get_mut(T)` — bind the
        // ident to the component alias. The emitted code is a comment to
        // keep the file readable; subsequent uses of `h` resolve through
        // the local context.
        const mg = ast.method_gets.items[ast.exprData(let.value)];
        // `let h = get(R)` binds a resource — codegen emission deferred to
        // E3 (see emitExpr's method_get note, D-S3-resource-receiver).
        if (mg.receiver.isNone()) return CodegenError.UnsupportedConstruct;
        const cname = ast.strings.slice(mg.type_name);
        try ctx.records.append(w.gpa, .{
            .key = .{ .name = let.name },
            .info = .{
                .kind = .component_alias,
                .component_name = cname,
                .is_mut = let.is_mut or (value_kind == .method_get_mut),
            },
        });
        try w.printLine("// let {s} = entity.{s}({s})", .{
            ast.strings.slice(let.name),
            if (value_kind == .method_get_mut) "get_mut" else "get",
            cname,
        });
        return;
    }

    // Plain-value let. Try to infer the Zig type so the binding is annotated
    // when possible (helps Zig's int-literal coercion).
    const zig_t = inferZigType(ast, ctx, let.value, let.type_annotation);

    const keyword = if (let.is_mut) "var" else "const";
    try w.writeIndent();
    try w.print("{s} ", .{keyword});
    try w.ident(ast.strings.slice(let.name));
    // A collection binding (array literal / index / slice) has no scalar Zig
    // type to print — omit the `: T` annotation and let Zig infer it.
    if (zig_t.len > 0) {
        try w.print(": {s} = ", .{zig_t});
    } else {
        try w.write(" = ");
    }
    try emitExpr(w, ast, ctx, let.value);
    try w.write(";\n");

    try ctx.records.append(w.gpa, .{
        .key = .{ .name = let.name },
        .info = .{ .kind = .value, .zig_type = zig_t, .is_mut = let.is_mut },
    });
}

fn emitAssign(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, assign: ast_mod.AssignStmt) CodegenError!void {
    try w.writeIndent();
    try emitExpr(w, ast, ctx, assign.target);
    try w.write(" ");
    try w.write(assignOpText(assign.op));
    try w.write(" ");
    try emitExpr(w, ast, ctx, assign.value);
    try w.write(";\n");
}

fn assignOpText(op: ast_mod.AssignOp) []const u8 {
    return switch (op) {
        .assign => "=",
        .add_assign => "+=",
        .sub_assign => "-=",
        .mul_assign => "*=",
        .div_assign => "/=",
        .rem_assign => "%=",
    };
}

fn emitExpr(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, id: NodeId) CodegenError!void {
    const kind = ast.exprKind(id);
    const data = ast.exprData(id);
    switch (kind) {
        .int_lit => try w.write(ast.strings.slice(data)),
        .float_lit => try w.write(ast.strings.slice(data)),
        .bool_lit => try w.write(ast.strings.slice(data)),
        .string_lit => {
            // String literals in expression position are not exercised by
            // the S3 subset rule bodies, but emit them defensively as Zig
            // strings (they would only reach the codegen via a debug print
            // call that S3 doesn't support — flagged unsupported).
            return CodegenError.UnsupportedConstruct;
        },
        .ident => {
            const name_id: StringId = data;
            if (ctx.lookup(name_id)) |local| {
                switch (local.kind) {
                    .value => try w.ident(ast.strings.slice(name_id)),
                    .component_alias => try emitComponentSlot(w, ctx, local.component_name),
                }
            } else {
                // Unknown ident — type-checker should have caught this. Emit
                // the raw name and let `zig build` complain.
                try w.ident(ast.strings.slice(name_id));
            }
        },
        .field_access => {
            const fa = ast.field_accesses.items[data];
            try emitFieldAccessExpr(w, ast, ctx, fa);
        },
        .method_get, .method_get_mut => {
            const mg = ast.method_gets.items[data];
            // Receiver-less `get(R)` / `get_mut(R)` resource access is parsed,
            // type-checked, and executed by the interpreter (the S4 reference),
            // but codegen emission is deferred: the resource store buffer is
            // byte-aligned (`gpa.dupe(u8, …)`), so a typed `@as(*R,
            // @alignCast(…))` would be unsound in ReleaseSafe. It lands with
            // aligned resource storage at E3 (Level A complete in codegen).
            // See the M0.8 journal (D-S3-resource-receiver).
            if (mg.receiver.isNone()) return CodegenError.UnsupportedConstruct;
            try emitComponentSlot(w, ctx, ast.strings.slice(mg.type_name));
        },
        .match_expr => try emitMatch(w, ast, ctx, data),
        .array_lit => {
            // `[a, b, c]` → `[_]ELEM{ ... }`, `[v; n]` → `[_]ELEM{v} ** n`
            // (M0.8 collections). E1 codegen emits fixed (stack) arrays only —
            // the element type is inferred from the first element. Dynamic
            // `T[]` / map / set codegen is deferred (heap, needs the arena
            // model) and the interpreter is their reference execution.
            const al = ast.array_lits.items[data];
            if (al.elements_len == 0) return CodegenError.UnsupportedConstruct; // empty array → dynamic, deferred
            const first: NodeId = @bitCast(ast.extra.items[al.elements_start]);
            const elem_zig = inferExprZigType(ast, ctx, first);
            if (al.is_fill) {
                try w.print("[_]{s}{{", .{elem_zig});
                try emitExpr(w, ast, ctx, first);
                try w.write("} ** ");
                try emitExpr(w, ast, ctx, al.fill_count);
            } else {
                try w.print("[_]{s}{{ ", .{elem_zig});
                var i: u32 = 0;
                while (i < al.elements_len) : (i += 1) {
                    if (i > 0) try w.write(", ");
                    const e: NodeId = @bitCast(ast.extra.items[al.elements_start + i]);
                    try emitExpr(w, ast, ctx, e);
                }
                try w.write(" }");
            }
        },
        .index => {
            // `receiver[index]` → Zig index (`recv[@intCast(i)]`) or slice
            // (`recv[lo..hi]`) (M0.8 collections). A range index lowers to a
            // Zig slice; an inclusive range adds 1 to the exclusive Zig bound.
            const ix = ast.index_exprs.items[data];
            try emitExpr(w, ast, ctx, ix.receiver);
            if (ast.exprKind(ix.index) == .range) {
                const r = ast.ranges.items[ast.exprData(ix.index)];
                try w.write("[@as(usize, @intCast(");
                try emitExpr(w, ast, ctx, r.start);
                try w.write("))..@as(usize, @intCast(");
                try emitExpr(w, ast, ctx, r.end);
                try w.write(if (r.inclusive) " + 1))]" else "))]");
            } else {
                try w.write("[@as(usize, @intCast(");
                try emitExpr(w, ast, ctx, ix.index);
                try w.write("))]");
            }
        },
        .closure => {
            // `|a| body` → an anonymous `struct { fn call(params) ret { return
            // body; } }` (M0.8 closures). E1 codegen handles capture-free
            // closures; a capturing closure is deferred (struct-with-fields
            // lowering) and the interpreter is its reference execution.
            const ce = ast.closure_exprs.items[data];
            if (closureHasCaptures(ast, ce)) return CodegenError.UnsupportedConstruct;
            const saved = ctx.records.items.len;
            var i: u32 = 0;
            while (i < ce.params_len) : (i += 1) {
                const p = ast.closure_params.items[ce.params_start + i];
                try ctx.records.append(w.gpa, .{ .key = .{ .name = p.name }, .info = .{ .kind = .value, .zig_type = closureParamZigType(ast, p), .is_mut = false } });
            }
            const ret_zig = inferExprZigType(ast, ctx, ce.body);
            try w.write("struct { fn call(");
            i = 0;
            while (i < ce.params_len) : (i += 1) {
                if (i > 0) try w.write(", ");
                const p = ast.closure_params.items[ce.params_start + i];
                try w.ident(ast.strings.slice(p.name));
                try w.print(": {s}", .{closureParamZigType(ast, p)});
            }
            try w.print(") {s} {{ return ", .{ret_zig});
            try emitExpr(w, ast, ctx, ce.body);
            try w.write("; } }");
            ctx.records.items.len = saved;
        },
        .fn_call => {
            // `callee(args)` → `callee.call(args)` (M0.8 closures): the callee
            // is a closure-typed local, lowered to the anonymous struct above.
            const call = ast.call_exprs.items[data];
            try emitExpr(w, ast, ctx, call.callee);
            try w.write(".call(");
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (i > 0) try w.write(", ");
                const arg: NodeId = @bitCast(ast.extra.items[call.args_start + i]);
                try emitExpr(w, ast, ctx, arg);
            }
            try w.write(")");
        },
        .loop_expr => {
            // `[label:] loop { body }` → Zig `[label:] while (true) { ... }`
            // (M0.8 loop/break). As an expression its value is the operand of
            // the `break` that exits it (Zig `while (true)` is value-carrying).
            const lp = ast.loop_exprs.items[data];
            if (lp.label != 0) {
                try w.ident(ast.strings.slice(lp.label));
                try w.write(": ");
            }
            try w.write("while (true) {\n");
            w.indentBy(1);
            var s: u32 = 0;
            while (s < lp.body_len) : (s += 1) {
                try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[lp.body_start + s]));
            }
            w.indentBy(-1);
            try w.writeIndent();
            try w.write("}");
        },
        .block_expr => try emitBlockExprValue(w, ast, ctx, data),
        .range => return CodegenError.UnsupportedConstruct, // ranges appear only as for-in iterables in E1 (lowered by emitStmt .for_stmt)
        .cast => {
            // `operand as Type` → an explicit Zig numeric conversion wrapped
            // in `@as(T, …)` (M0.8 v0.6 foundations). The conversion builtin
            // is picked from the operand's inferred domain vs the target's.
            const c = ast.casts.items[data];
            const named = ast.named_types.items[ast.typeNodeData(c.type_node)];
            const zig_t = type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(named.name))) orelse return CodegenError.UnsupportedConstruct;
            const target_is_float = std.mem.eql(u8, zig_t, "f32") or std.mem.eql(u8, zig_t, "f64");
            const src_zig = inferExprZigType(ast, ctx, c.operand);
            const src_is_float = std.mem.eql(u8, src_zig, "f32") or std.mem.eql(u8, src_zig, "f64");
            const conv: []const u8 = if (target_is_float and !src_is_float)
                "@floatFromInt"
            else if (!target_is_float and src_is_float)
                "@intFromFloat"
            else if (target_is_float)
                "@floatCast"
            else
                "@intCast";
            try w.print("@as({s}, {s}(", .{ zig_t, conv });
            try emitExpr(w, ast, ctx, c.operand);
            try w.write("))");
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            try w.write("(");
            try emitExpr(w, ast, ctx, b.lhs);
            try w.print(" {s} ", .{binaryOpText(b.op)});
            try emitExpr(w, ast, ctx, b.rhs);
            try w.write(")");
        },
        .unary => {
            const u = ast.unary_exprs.items[data];
            switch (u.op) {
                .neg => {
                    try w.write("-(");
                    try emitExpr(w, ast, ctx, u.operand);
                    try w.write(")");
                },
                .logical_not => {
                    try w.write("!(");
                    try emitExpr(w, ast, ctx, u.operand);
                    try w.write(")");
                },
            }
        },
        else => return CodegenError.UnsupportedConstruct,
    }
}

fn binaryOpText(op: ast_mod.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "%",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .logical_and => "and",
        .logical_or => "or",
    };
}

fn emitFieldAccessExpr(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, fa: ast_mod.FieldAccessExpr) CodegenError!void {
    try emitExpr(w, ast, ctx, fa.receiver);
    try w.write(".");
    try w.ident(ast.strings.slice(fa.field_name));
}

/// Lower a `match` expression to a labeled Zig block that binds the
/// scrutinee once and yields the first matching arm's value (M0.8 v0.6
/// foundations). Literal arms compare with `==`; wildcard / binding arms are
/// unconditional. A binding arm declares `const <name> = __m<n>` in an inner
/// block statement so the arm body resolves the name. When no catch-all arm
/// exists (a bool match covering true+false), a trailing `unreachable`
/// satisfies Zig that the block always yields — exhaustiveness is already
/// proven by the type-checker. `data` (the match-expr slab index) is unique
/// per match in the file, so nested matches get distinct labels.
fn emitMatch(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    const m = ast.match_exprs.items[data];
    const lbl = data;
    try w.print("blk{d}: {{ const __m{d} = ", .{ lbl, lbl });
    try emitExpr(w, ast, ctx, m.scrutinee);
    try w.write("; ");

    var has_catch_all = false;
    var i: u32 = 0;
    while (i < m.arms_len) : (i += 1) {
        const arm = ast.match_arms.items[m.arms_start + i];
        switch (arm.pattern_kind) {
            .literal => {
                const lit: NodeId = @bitCast(arm.pattern_payload);
                try w.print("if (__m{d} == ", .{lbl});
                try emitExpr(w, ast, ctx, lit);
                try w.print(") break :blk{d} ", .{lbl});
                try emitExpr(w, ast, ctx, arm.body);
                try w.write("; ");
            },
            .wildcard => {
                has_catch_all = true;
                try w.print("break :blk{d} ", .{lbl});
                try emitExpr(w, ast, ctx, arm.body);
                try w.write("; ");
            },
            .binding => {
                has_catch_all = true;
                const name: StringId = arm.pattern_payload;
                try w.write("{ const ");
                try w.ident(ast.strings.slice(name));
                try w.print(" = __m{d}; break :blk{d} ", .{ lbl, lbl });
                const saved_len = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{
                    .key = .{ .name = name },
                    .info = .{ .kind = .value, .zig_type = "", .is_mut = false },
                });
                try emitExpr(w, ast, ctx, arm.body);
                ctx.records.items.len = saved_len;
                try w.write("; }");
            },
        }
    }
    // bool-exhaustive matches have no catch-all arm; the type-checker proved
    // every case is covered, so the fall-through is unreachable.
    if (!has_catch_all) try w.write("unreachable; ");
    try w.write("}");
}

/// Emit a block expression in value position (M0.8 control flow). A block with
/// statements lowers to a labeled Zig value-block
/// `__bex<n>: { <stmts> break :__bex<n> <value>; }`; an empty-body block to
/// `(<value>)`. The slab index `data` is unique per block in the file, so
/// nested blocks get distinct labels (and never collide with `emitMatch`'s
/// `blk<n>` — different prefix). A value-less block in value position is `unit`
/// and deferred (`UnsupportedConstruct`); the type-checker treats it as a
/// non-value so a sound program never lands one in a value slot.
fn emitBlockExprValue(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    const blk = ast.block_exprs.items[data];
    if (blk.value.isNone()) return CodegenError.UnsupportedConstruct;
    if (blk.body_len == 0) {
        try w.write("(");
        try emitExpr(w, ast, ctx, blk.value);
        try w.write(")");
        return;
    }
    const saved = ctx.records.items.len;
    try w.print("__bex{d}: {{\n", .{data});
    w.indentBy(1);
    var s: u32 = 0;
    while (s < blk.body_len) : (s += 1) {
        try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[blk.body_start + s]));
    }
    try w.writeIndent();
    try w.print("break :__bex{d} ", .{data});
    try emitExpr(w, ast, ctx, blk.value);
    try w.write(";\n");
    w.indentBy(-1);
    try w.writeIndent();
    try w.write("}");
    ctx.records.items.len = saved;
}

/// Emit a block expression in statement position (M0.8 control flow): a Zig
/// brace-block running the body statements, then the trailing value (if any)
/// as a discarded `_ = <value>;`. Used for a bare block statement and for
/// `if` / `while` branch bodies (the block value is discarded there).
fn emitBlockExprStmts(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    const blk = ast.block_exprs.items[data];
    const saved = ctx.records.items.len;
    try w.line("{");
    w.indentBy(1);
    var s: u32 = 0;
    while (s < blk.body_len) : (s += 1) {
        try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[blk.body_start + s]));
    }
    if (!blk.value.isNone()) {
        try w.writeIndent();
        try w.write("_ = ");
        try emitExpr(w, ast, ctx, blk.value);
        try w.write(";\n");
    }
    w.indentBy(-1);
    try w.line("}");
    ctx.records.items.len = saved;
}

/// The Zig type emitted for a closure parameter (M0.8 closures). E1 codegen
/// expects annotated scalar params; a missing / non-scalar annotation falls
/// back to `i64` (the interpreter is the reference for richer closures).
fn closureParamZigType(ast: *const AstArena, p: ast_mod.ClosureParam) []const u8 {
    if (p.type_node.isNone() or ast.typeNodeKind(p.type_node) != .named) return "i64";
    const tnode = ast.named_types.items[ast.typeNodeData(p.type_node)];
    return type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(tnode.name))) orelse "i64";
}

/// True if a closure body references any identifier that is not one of its
/// parameters — i.e. it captures an outer binding (M0.8 closures). E1 codegen
/// only handles capture-free closures; a capturing closure is deferred (the
/// struct-with-fields lowering) and runs through the interpreter instead.
fn closureHasCaptures(ast: *const AstArena, ce: ast_mod.ClosureExpr) bool {
    return exprReferencesNonParam(ast, ce.body, ce);
}

fn exprReferencesNonParam(ast: *const AstArena, expr: NodeId, ce: ast_mod.ClosureExpr) bool {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    switch (kind) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .tag_path => return false,
        .ident => {
            const name: StringId = data;
            var i: u32 = 0;
            while (i < ce.params_len) : (i += 1) {
                if (ast.closure_params.items[ce.params_start + i].name == name) return false;
            }
            return true;
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            return exprReferencesNonParam(ast, b.lhs, ce) or exprReferencesNonParam(ast, b.rhs, ce);
        },
        .unary => return exprReferencesNonParam(ast, ast.unary_exprs.items[data].operand, ce),
        .cast => return exprReferencesNonParam(ast, ast.casts.items[data].operand, ce),
        // Any other body shape (field access, calls, collections, …) is
        // conservatively treated as capturing → deferred codegen.
        else => return true,
    }
}

fn inferZigType(ast: *const AstArena, ctx: *LocalCtx, expr: NodeId, annotation: NodeId) []const u8 {
    // Only a named-type annotation maps to a scalar Zig type here; collection
    // annotations (`T[]`, `[K: V]`, `Set<T>`, `T[N]`) leave the binding
    // un-annotated so Zig infers the array / slice type (M0.8 collections).
    if (!annotation.isNone() and ast.typeNodeKind(annotation) == .named) {
        const tnode = ast.named_types.items[ast.typeNodeData(annotation)];
        const tname = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
        if (type_map.mapBuiltin(tname)) |z| return z;
    }
    return inferExprZigType(ast, ctx, expr);
}

fn inferExprZigType(ast: *const AstArena, ctx: *LocalCtx, expr: NodeId) []const u8 {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    return switch (kind) {
        .int_lit => "i64",
        .float_lit => "f64",
        .bool_lit => "bool",
        .ident => blk: {
            const sid: StringId = data;
            if (ctx.lookup(sid)) |local| break :blk if (local.zig_type.len > 0) local.zig_type else "i64";
            break :blk "i64";
        },
        .binary => blk: {
            const b = ast.binary_exprs.items[data];
            // Comparison and logical ops return bool. Arithmetic returns the
            // operand type (S3 forbids mixing) — recurse on lhs.
            break :blk switch (b.op) {
                .eq, .neq, .lt, .gt, .le, .ge, .logical_and, .logical_or => "bool",
                else => inferExprZigType(ast, ctx, b.lhs),
            };
        },
        .unary => blk: {
            const u = ast.unary_exprs.items[data];
            break :blk switch (u.op) {
                .logical_not => "bool",
                .neg => inferExprZigType(ast, ctx, u.operand),
            };
        },
        .field_access => blk: {
            const fa = ast.field_accesses.items[data];
            // Resolve the receiver to a component name, then look up the
            // field's declared type in the AST.
            const comp_name = receiverComponentName(ast, ctx, fa.receiver) orelse break :blk "i64";
            const fname = ast.strings.slice(fa.field_name);
            const z = fieldZigTypeOnComponent(ast, comp_name, fname) orelse break :blk "i64";
            break :blk z;
        },
        // Array literals and index/slice results are emitted without a `let`
        // type annotation — Zig infers the array / element / slice type
        // (M0.8 collections). Returning "" makes `emitLet` drop the `: T`.
        .array_lit => "",
        .index => "",
        // Closures (anonymous struct type) and call results are left to Zig
        // inference too (M0.8 closures).
        .closure => "",
        .fn_call => "",
        // A loop expression's value type is inferred by Zig from its break.
        .loop_expr => "",
        // A block expression's value type is inferred by Zig from its trailing
        // value (left un-annotated so block-locals need not be in scope here).
        .block_expr => "",
        .method_get, .method_get_mut => "struct", // not directly inferable; should not appear at let-rhs after method_get handling
        .cast => blk: {
            const c = ast.casts.items[data];
            const named = ast.named_types.items[ast.typeNodeData(c.type_node)];
            break :blk type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(named.name))) orelse "i64";
        },
        .match_expr => blk: {
            // The match result type is the (unified) type of its arm bodies;
            // infer it from the first arm.
            const m = ast.match_exprs.items[data];
            if (m.arms_len == 0) break :blk "i64";
            break :blk inferExprZigType(ast, ctx, ast.match_arms.items[m.arms_start].body);
        },
        else => "i64",
    };
}

fn receiverComponentName(ast: *const AstArena, ctx: *LocalCtx, expr: NodeId) ?[]const u8 {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    return switch (kind) {
        .method_get, .method_get_mut => blk: {
            const mg = ast.method_gets.items[data];
            break :blk ast.strings.slice(mg.type_name);
        },
        .ident => blk: {
            const sid: StringId = data;
            if (ctx.lookup(sid)) |local| if (local.kind == .component_alias) break :blk local.component_name;
            break :blk null;
        },
        .field_access => null, // chained field access not introspected — fall back to default type
        else => null,
    };
}

fn fieldZigTypeOnComponent(ast: *const AstArena, comp_name: []const u8, field_name: []const u8) ?[]const u8 {
    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        const kind = ast.items.items(.kind)[i];
        if (kind != .component_decl and kind != .resource_decl) continue;
        const data = ast.items.items(.data)[i];
        const decl_name: []const u8 = switch (kind) {
            .component_decl => ast.strings.slice(ast.component_decls.items[data].name),
            .resource_decl => ast.strings.slice(ast.resource_decls.items[data].name),
            else => unreachable,
        };
        if (!std.mem.eql(u8, decl_name, comp_name)) continue;
        const fields_start: u32 = switch (kind) {
            .component_decl => ast.component_decls.items[data].fields_start,
            .resource_decl => ast.resource_decls.items[data].fields_start,
            else => unreachable,
        };
        const fields_len: u32 = switch (kind) {
            .component_decl => ast.component_decls.items[data].fields_len,
            .resource_decl => ast.resource_decls.items[data].fields_len,
            else => unreachable,
        };
        var f_i: u32 = 0;
        while (f_i < fields_len) : (f_i += 1) {
            const f = ast.fields.items[fields_start + f_i];
            const fname = ast.strings.slice(f.name);
            if (std.mem.eql(u8, fname, field_name)) {
                const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
                const etch_t = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
                return type_map.mapBuiltin(etch_t);
            }
        }
    }
    return null;
}

// ─── Const expressions (field defaults / filter values) ─────────────────────

fn emitConstExpr(w: *Writer, ast: *const AstArena, expr: NodeId, target_zig_type: []const u8) CodegenError!void {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    switch (kind) {
        .int_lit => {
            const text = ast.strings.slice(data);
            // Coerce int literal to a float-typed slot by emitting
            // `<text>.0` so Zig is happy with the field type.
            if (type_map.isFloatLikeZigType(target_zig_type)) {
                try w.print("@as({s}, {s})", .{ target_zig_type, text });
            } else {
                try w.write(text);
            }
        },
        .float_lit => try w.write(ast.strings.slice(data)),
        .bool_lit => try w.write(ast.strings.slice(data)),
        .binary => {
            const b = ast.binary_exprs.items[data];
            try w.write("(");
            try emitConstExpr(w, ast, b.lhs, target_zig_type);
            try w.print(" {s} ", .{binaryOpText(b.op)});
            try emitConstExpr(w, ast, b.rhs, target_zig_type);
            try w.write(")");
        },
        .unary => {
            const u = ast.unary_exprs.items[data];
            switch (u.op) {
                .neg => {
                    try w.write("-(");
                    try emitConstExpr(w, ast, u.operand, target_zig_type);
                    try w.write(")");
                },
                .logical_not => {
                    try w.write("!(");
                    try emitConstExpr(w, ast, u.operand, target_zig_type);
                    try w.write(")");
                },
            }
        },
        else => return CodegenError.UnsupportedConstruct,
    }
}

// ─── `tick` ─────────────────────────────────────────────────────────────────

fn emitTick(w: *Writer, rule_names: []const []const u8) CodegenError!void {
    try w.line("/// Execute every rule once in source declaration order, then");
    try w.line("/// clear resource dirty bits — equivalent to a single tick of");
    try w.line("/// the S4 interpreter's `stepOnce` + `tickBoundary`.");
    try w.line("pub fn tick(world: *World) void {");
    w.indentBy(1);
    for (rule_names) |name| {
        try w.printLine("rule_{s}(world);", .{name});
    }
    try w.line("world.tickBoundary();");
    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

// ─── WhenInfo collection ────────────────────────────────────────────────────

fn collectWhenInfo(gpa: std.mem.Allocator, ast: *const AstArena, rule: ast_mod.RuleDecl) !WhenInfo {
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer components.deinit(gpa);
    var seen_components: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_components.deinit(gpa);
    var res_deps: std.ArrayListUnmanaged(ResourceDep) = .empty;
    errdefer res_deps.deinit(gpa);
    var field_filter: ?FieldFilter = null;
    var has_component_ref: bool = false;
    var has_or_or_not: bool = false;

    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        try walkWhen(gpa, ast, rule.when_root, &components, &seen_components, &res_deps, &field_filter, &has_component_ref, &has_or_or_not);
    }

    return .{
        .components = try components.toOwnedSlice(gpa),
        .resource_deps = try res_deps.toOwnedSlice(gpa),
        .field_filter = field_filter,
        .has_component_ref = has_component_ref,
        .has_or_or_not = has_or_or_not,
    };
}

fn freeWhenInfo(gpa: std.mem.Allocator, info: *WhenInfo) void {
    gpa.free(info.components);
    gpa.free(info.resource_deps);
}

fn walkWhen(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    when_idx: u32,
    components: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    res_deps: *std.ArrayListUnmanaged(ResourceDep),
    filter: *?FieldFilter,
    has_component_ref: *bool,
    has_or_or_not: *bool,
) !void {
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and => {
            try walkWhen(gpa, ast, node.lhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not);
            try walkWhen(gpa, ast, node.rhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not);
        },
        .logical_or => {
            has_or_or_not.* = true;
            try walkWhen(gpa, ast, node.lhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not);
            try walkWhen(gpa, ast, node.rhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not);
        },
        .logical_not => {
            has_or_or_not.* = true;
            try walkWhen(gpa, ast, node.lhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not);
        },
        .has => {
            const cname = ast.strings.slice(node.type_name);
            const gop = try seen.getOrPut(gpa, cname);
            if (!gop.found_existing) try components.append(gpa, cname);
            has_component_ref.* = true;
        },
        .has_with_filter => {
            const cname = ast.strings.slice(node.type_name);
            const gop = try seen.getOrPut(gpa, cname);
            if (!gop.found_existing) try components.append(gpa, cname);
            has_component_ref.* = true;
            const fname = ast.strings.slice(node.field_name);
            // Infer the filter value's Zig type from the component field
            // declaration so the comparison emits the right literal style.
            const zig_t = fieldZigTypeOnComponent(ast, cname, fname) orelse "i64";
            filter.* = .{
                .component_name = cname,
                .field_name = fname,
                .value = node.filter_value,
                .value_zig_type = zig_t,
            };
        },
        .resource => {
            const rname = ast.strings.slice(node.type_name);
            try res_deps.append(gpa, .{ .name = rname, .must_be_changed = false });
        },
        .resource_changed => {
            const rname = ast.strings.slice(node.type_name);
            try res_deps.append(gpa, .{ .name = rname, .must_be_changed = true });
        },
    }
}

fn collectSignature(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    rule: ast_mod.RuleDecl,
    out: *std.StringHashMapUnmanaged(void),
) !void {
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    defer components.deinit(gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        try collectComponents(gpa, ast, rule.when_root, &components, &seen);
    }
    std.mem.sort([]const u8, components.items, {}, lexLess);
    // Compose a stable string key by joining with `|`.
    var key_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer key_buf.deinit(gpa);
    for (components.items, 0..) |c, idx| {
        if (idx > 0) try key_buf.append(gpa, '|');
        try key_buf.appendSlice(gpa, c);
    }
    if (key_buf.items.len == 0) try key_buf.appendSlice(gpa, "<empty>");
    const key_owned = try gpa.dupe(u8, key_buf.items);
    const gop = try out.getOrPut(gpa, key_owned);
    if (gop.found_existing) {
        gpa.free(key_owned);
    }
}

fn collectComponents(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    when_idx: u32,
    components: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and, .logical_or => {
            try collectComponents(gpa, ast, node.lhs, components, seen);
            try collectComponents(gpa, ast, node.rhs, components, seen);
        },
        .logical_not => {
            try collectComponents(gpa, ast, node.lhs, components, seen);
        },
        .has, .has_with_filter => {
            const cname = ast.strings.slice(node.type_name);
            const gop = try seen.getOrPut(gpa, cname);
            if (!gop.found_existing) try components.append(gpa, cname);
        },
        .resource, .resource_changed => {},
    }
}

fn lexLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// Dedicated lowering tests live under `src/etch/zig_codegen/tests/lower_test.zig`.
// They are pulled into the import graph by `zig_codegen/root.zig` and run as
// part of `zig build test`.
