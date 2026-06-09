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
//!     pub const TagSet = extern struct { bits: [N]u64 = ... }; // iff tags
//!     pub fn register(world, gpa) !void { ... }   // RTTI + resource init
//!     pub fn rule_<name>(world: *World) void { .. } // 1 per Etch rule
//!                                                  // (+ `, cmd: *CommandBuffer`
//!                                                  //  when the rule mutates tags)
//!     pub fn tick(world, gpa) void { ... }         // calls each rule in
//!                                                  // source order, flushes
//!                                                  // tag mutations
//!
//! Implementation choices (cf. brief Notes):
//! - `extern struct` types match Etch component names verbatim (no prefix).
//! - `int` → `i64`, `float` → `f64`, `bool` → `bool`; user types map to the
//!   matching generated struct.
//! - Rules walk `world.archetypes` (dynamic side) and `@ptrCast` the SoA
//!   slot pointer to `[*]<Comp>`. The component layout computed by the
//!   runtime registry matches the Zig `extern struct` layout exactly
//!   (same `@offsetOf` semantics on both sides) so the cast is well-formed.
//! - Rules are emitted in source declaration order; `tick(world, gpa)` invokes
//!   them sequentially, matching the S4 interpreter's scheduler so
//!   differential corpus parity holds.

const std = @import("std");
const ast_mod = @import("../ast.zig");
const types_mod = @import("../types.zig");
const tags_mod = @import("../tags.zig");
const diag_mod = @import("../diagnostics.zig");
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
    events: u32 = 0,
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

    // Build the global tag table (the shared `tags.zig` algorithm, same as
    // the resolver and the interpreter) so tag filters resolve to leaf bits
    // and `TagSet` is emitted + registered when the program declares any tag
    // (M0.8 E3). The program is already type-checked, so `build` reports no
    // new diagnostics here; the throwaway list is freed immediately.
    var tag_diags: std.ArrayListUnmanaged(diag_mod.Diagnostic) = .empty;
    defer {
        for (tag_diags.items) |*d| d.deinit(gpa);
        tag_diags.deinit(gpa);
    }
    var tag_table = try tags_mod.TagTable.build(gpa, ast, &tag_diags, tags_mod.default_max_tags);
    defer tag_table.deinit(gpa);

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
            // An `event` is a POD struct of fields (M0.8 E3, `etch-grammar.md`
            // §5.10; ABI §3.1) → an `extern struct`, like a component. It is
            // registered with the typed `world.event_bus` in the register pass,
            // not the component registry.
            .event_decl => {
                try emitComponentLikeStruct(&w, ast, data, .event);
                stats.events += 1;
            },
            // A `struct` is a by-value type (M0.8 E2 block 3): emit the
            // `extern struct` with its fields and its inherent `impl` methods
            // (as Zig `pub fn` members), but no RTTI registration.
            .struct_decl => try emitStructDecl(&w, ast, data),
            // A C-like `enum` (M0.8 E2 block 3 tranche B) → Zig `enum(i32)`
            // (`etch-abi-zig.md` §3.1). Data-carrying variants are deferred
            // (fail-loud) inside `emitEnumDecl`.
            .enum_decl => try emitEnumDecl(&w, ast, data),
            else => {},
        }
    }

    // The builtin `TagSet` component (M0.8 E3): a fixed `[words]u64` bitfield,
    // one slot per entity carrying tags. Emitted as an `extern struct` so its
    // layout matches the registry's raw `words*8`-byte / align-8 component
    // (`etch-abi-zig.md` §3) — byte-exact with the interpreter's `registerComponentRaw`.
    if (tag_table.leaf_count > 0) {
        try emitTagSetStruct(&w, tag_table.words());
    }

    // Pass B — `register` function. Walk items again to keep registration
    // order matching source order.
    try emitRegister(&w, ast, &tag_table);

    // Pass C — emit one Zig function per top-level Etch `fn` (M0.8 E2 call
    // mechanism). Emitted before the rules so the file reads top-down; Zig
    // resolves container-level references regardless of declaration order.
    i = 0;
    while (i < ast.items.len) : (i += 1) {
        const kind = ast.items.items(.kind)[i];
        const data = ast.items.items(.data)[i];
        if (kind != .fn_decl) continue;
        try emitFnDecl(&w, ast, ast.fn_decls.items[data]);
    }

    // Pass D — emit one Zig function per Etch rule.
    var rule_emits: std.ArrayListUnmanaged(RuleEmit) = .empty;
    defer rule_emits.deinit(gpa);

    var sig_set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = sig_set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        sig_set.deinit(gpa);
    }

    // Whether ANY rule filters by `changed` (M0.8 E3). When set, `tick` advances
    // `current_tick`, EVERY component rule routes through the arch walk, and
    // component writes `markChanged` — so a `changed`-free program keeps the
    // comptime-query fast path and emits no change-detection plumbing.
    const program_has_changed = programUsesChanged(ast);

    i = 0;
    while (i < ast.items.len) : (i += 1) {
        const kind = ast.items.items(.kind)[i];
        const data = ast.items.items(.data)[i];
        if (kind != .rule_decl) continue;
        const rule = ast.rule_decls.items[data];
        const name_slice = ast.strings.slice(rule.name);
        // An `@on_event(T)` observer (M0.8 E3) takes a `*EventCursor` param;
        // `tick` subscribes the cursor at head=0 (before any emit) and threads
        // it in. A tag-mutating rule takes a `*CommandBuffer`. The two are
        // mutually exclusive (an observer is global → no iterated entity → no
        // tag mutation).
        const on_event = ast.onEventAnnotation(rule);
        const event_type: ?[]const u8 = if (on_event) |a|
            (if (ast.onEventTypeName(a)) |t| ast.strings.slice(t) else null)
        else
            null;
        try rule_emits.append(gpa, .{
            .name = name_slice,
            .tag_mutating = ruleHasTagMutation(ast, rule),
            .event_type = event_type,
        });

        if (on_event != null) {
            try emitObserverRule(&w, ast, rule, &tag_table);
        } else {
            try emitRule(&w, ast, rule, &tag_table, program_has_changed);
        }
        stats.rules += 1;

        // Track the rule's archetype signature (the sorted set of component
        // names referenced by its when clause).
        try collectSignature(gpa, ast, rule, &sig_set);
    }

    try emitTick(&w, rule_emits.items, program_has_changed);

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
    // `CommandBuffer` is referenced only by `tick` when the program declares
    // tag mutations (`add_tag`/`remove_tag` → deferred `set_tag`/`clear_tag`);
    // an unused container-level import is permitted, so it is emitted
    // unconditionally for layout stability (M0.8 E3).
    try w.line("const CommandBuffer = weld_core.ecs.command_buffer.CommandBuffer;");
    // `EventCursor` is referenced only by `tick` + observer fns when the program
    // declares an `@on_event(T)` observer (M0.8 E3); an unused container-level
    // import is permitted, so it is emitted unconditionally for layout stability.
    try w.line("const EventCursor = weld_core.events.EventCursor;");
    try w.blankLine();
}

/// Emit the builtin `TagSet` component (M0.8 E3): `words` 64-bit words of
/// bits, zero-initialised. One slot per entity carrying tags; the per-slot
/// tag-filter guard reads `bits[w]` and a tag mutation flips a bit via the
/// command buffer. Layout matches the registry's raw component
/// (size `words*8`, align 8, no named fields).
fn emitTagSetStruct(w: *Writer, words: u32) CodegenError!void {
    try w.printLine("pub const TagSet = extern struct {{ bits: [{d}]u64 = [_]u64{{0}} ** {d} }};", .{ words, words });
    try w.blankLine();
}

// ─── Component / resource as extern struct ─────────────────────────────────

const DeclKind = enum { component, resource, event };

fn emitComponentLikeStruct(w: *Writer, ast: *const AstArena, data: u32, kind: DeclKind) CodegenError!void {
    // ComponentDecl, ResourceDecl and EventDecl share the same layout for our
    // purposes — we only care about (name, fields_start, fields_len). An event
    // is a POD struct of fields (M0.8 E3, ABI §3.1).
    const name: []const u8 = switch (kind) {
        .component => ast.strings.slice(ast.component_decls.items[data].name),
        .resource => ast.strings.slice(ast.resource_decls.items[data].name),
        .event => ast.strings.slice(ast.event_decls.items[data].name),
    };
    const fields_start: u32 = switch (kind) {
        .component => ast.component_decls.items[data].fields_start,
        .resource => ast.resource_decls.items[data].fields_start,
        .event => ast.event_decls.items[data].fields_start,
    };
    const fields_len: u32 = switch (kind) {
        .component => ast.component_decls.items[data].fields_len,
        .resource => ast.resource_decls.items[data].fields_len,
        .event => ast.event_decls.items[data].fields_len,
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

// ─── struct (by-value type) ──────────────────────────────────────────────

/// Emit a `struct` declaration as a Zig `extern struct` with its fields plus
/// its inherent `impl` methods as `pub fn` members (M0.8 E2 block 3). Unlike a
/// component / resource, a struct is not RTTI-registered (it is a by-value
/// type, not an ECS type). Field layout mirrors `emitComponentLikeStruct` so
/// the runtime registry's `@offsetOf` semantics match if the struct is later
/// nested in a component (out of block-3 scope, but layout-compatible).
/// Emit a C-like `enum` as a Zig `enum(i32)` (M0.8 E2 block 3 tranche B,
/// `etch-abi-zig.md` §3.1 — `enum E { A, B }` → `enum(i32) { a, b }`). Variant
/// names are preserved verbatim (Etch variants are snake_case by convention).
/// A data-carrying variant (struct-like / tuple-like) is deferred: its
/// construction + destructuring are post-Phase-1, so the whole enum fails loud
/// (`UnsupportedConstruct`) and the interpreter is its reference.
fn emitEnumDecl(w: *Writer, ast: *const AstArena, data: u32) CodegenError!void {
    const decl = ast.enum_decls.items[data];
    if (decl.generics_len > 0) return CodegenError.UnsupportedConstruct; // generic monomorphisation → Phase 2
    var v_i: u32 = 0;
    while (v_i < decl.variants_len) : (v_i += 1) {
        if (ast.enum_variants.items[decl.variants_start + v_i].shape != .c_like) {
            return CodegenError.UnsupportedConstruct; // data-carrying variant → deferred
        }
    }
    try w.printLine("pub const {s} = enum(i32) {{", .{ast.strings.slice(decl.name)});
    w.indentBy(1);
    v_i = 0;
    while (v_i < decl.variants_len) : (v_i += 1) {
        const variant = ast.enum_variants.items[decl.variants_start + v_i];
        try w.writeIndent();
        try w.ident(ast.strings.slice(variant.name));
        try w.write(",\n");
    }
    w.indentBy(-1);
    try w.line("};");
    try w.blankLine();
}

fn emitStructDecl(w: *Writer, ast: *const AstArena, data: u32) CodegenError!void {
    const decl = ast.struct_decls.items[data];
    if (decl.generics_len > 0) return CodegenError.UnsupportedConstruct; // generic monomorphisation → Phase 2
    const name = ast.strings.slice(decl.name);
    try w.printLine("pub const {s} = extern struct {{", .{name});
    w.indentBy(1);
    var f_i: u32 = 0;
    while (f_i < decl.fields_len) : (f_i += 1) {
        const f = ast.fields.items[decl.fields_start + f_i];
        const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
        const etch_type = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
        const zig_type = type_map.mapBuiltin(etch_type) orelse return CodegenError.NonPodComponent;
        const fname = ast.strings.slice(f.name);
        try w.writeIndent();
        try w.ident(fname);
        if (f.default_value.isNone()) {
            try w.print(": {s} = {s},\n", .{ zig_type, zeroDefault(zig_type) });
        } else {
            try w.print(": {s} = ", .{zig_type});
            try emitConstExpr(w, ast, f.default_value, zig_type);
            try w.write(",\n");
        }
    }
    // Methods: walk every `impl … <this type> { … }` (inherent §5.1 and trait
    // §5.2) and emit its methods as `pub fn` members (declaration order across
    // impls). For a trait impl, also emit the trait's default-bodied methods the
    // impl does not override, so a call to a defaulted method compiles (M0.8 E2
    // block 3 tranche C).
    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .impl_decl) continue;
        const impl = ast.impl_decls.items[ast.items.items(.data)[i]];
        if (impl.type_name != decl.name) continue;
        var m: u32 = 0;
        while (m < impl.methods_len) : (m += 1) {
            try emitMethod(w, ast, name, ast.impl_methods.items[impl.methods_start + m]);
        }
        if (impl.trait_name != 0) {
            if (findTraitDecl(ast, impl.trait_name)) |tdecl| {
                var t: u32 = 0;
                while (t < tdecl.methods_len) : (t += 1) {
                    const tm = ast.impl_methods.items[tdecl.methods_start + t];
                    if (!tm.has_body) continue; // abstract → impl provided it above
                    if (implHasMethod(ast, impl, tm.name)) continue; // overridden
                    try emitMethod(w, ast, name, tm);
                }
            }
        }
    }
    w.indentBy(-1);
    try w.line("};");
    try w.blankLine();
}

/// The `TraitDecl` named `trait_name`, or `null` (M0.8 E2 block 3 tranche C).
fn findTraitDecl(ast: *const AstArena, trait_name: StringId) ?ast_mod.TraitDecl {
    var i: usize = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .trait_decl) continue;
        const tdecl = ast.trait_decls.items[ast.items.items(.data)[i]];
        if (tdecl.name == trait_name) return tdecl;
    }
    return null;
}

/// `true` if `impl` provides a method named `name` (M0.8 E2 block 3 tranche C).
fn implHasMethod(ast: *const AstArena, impl: ast_mod.ImplDecl, name: StringId) bool {
    var m: u32 = 0;
    while (m < impl.methods_len) : (m += 1) {
        if (ast.impl_methods.items[impl.methods_start + m].name == name) return true;
    }
    return false;
}

/// Emit one inherent `impl` method as a Zig `pub fn` member (M0.8 E2 block 3).
/// A `self` (by-value) receiver lowers to `self: T`; an associated fn (no self)
/// to a plain function. `mut self` needs a pointer receiver (`self: *T`) and an
/// addressable call site — deferred (the interpreter is its reference), as are
/// `async` / `throws` methods (E3). The body is a value-block (trailing
/// expression → implicit `return`), shared with `emitFnDecl`'s shape.
fn emitMethod(w: *Writer, ast: *const AstArena, struct_name: []const u8, method: ast_mod.FnDecl) CodegenError!void {
    if (method.generics_len > 0) return CodegenError.UnsupportedConstruct; // generic monomorphisation → Phase 2
    if (method.is_async) return CodegenError.UnsupportedConstruct; // async codegen → Phase 2
    if (method.throws) return CodegenError.UnsupportedConstruct; // throws codegen → E3 gate
    if (method.self_kind == .by_mut) return CodegenError.UnsupportedConstruct; // mut-self pointer receiver → deferred

    var ctx: LocalCtx = .{};
    defer ctx.deinit(w.gpa);

    try w.writeIndent();
    try w.write("pub fn ");
    try w.ident(ast.strings.slice(method.name));
    try w.write("(");
    var wrote_param = false;
    if (method.self_kind == .by_value) {
        try w.print("self: {s}", .{struct_name});
        wrote_param = true;
        if (ast.strings.find("self")) |sid| {
            try ctx.records.append(w.gpa, .{ .key = .{ .name = sid }, .info = .{ .kind = .value, .zig_type = struct_name, .is_mut = false } });
        }
    }
    var p_i: u32 = 0;
    while (p_i < method.params_len) : (p_i += 1) {
        if (wrote_param) try w.write(", ");
        const p = ast.fn_params.items[method.params_start + p_i];
        const zig_t = fnTypeZig(ast, p.type_node);
        try w.ident(ast.strings.slice(p.name));
        try w.print(": {s}", .{zig_t});
        wrote_param = true;
        try ctx.records.append(w.gpa, .{ .key = .{ .name = p.name }, .info = .{ .kind = .value, .zig_type = zig_t, .is_mut = false } });
    }
    try w.write(") ");
    try w.write(if (method.return_type.isNone()) "void" else fnTypeZig(ast, method.return_type));
    try w.write(" {\n");
    w.indentBy(1);
    var s: u32 = 0;
    while (s < method.body_len) : (s += 1) {
        try emitStmt(w, ast, &ctx, @bitCast(ast.extra.items[method.body_start + s]));
    }
    if (!method.value.isNone()) {
        try w.writeIndent();
        try w.write("return ");
        try emitExpr(w, ast, &ctx, method.value);
        try w.write(";\n");
    }
    w.indentBy(-1);
    try w.writeIndent();
    try w.write("}\n");
}

// ─── `register` function ────────────────────────────────────────────────────

fn emitRegister(w: *Writer, ast: *const AstArena, tag_table: *const tags_mod.TagTable) CodegenError!void {
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
            // An `event` registers a typed queue on `world.event_bus` (M0.8 E3).
            // `cap` is a power-of-two ring size (256, a per-tick default);
            // `.tick` lifetime drains it at the tick boundary
            // (`src/core/events/lifetime.zig`). `.tick` is an enum literal
            // inferred against the `Lifetime` parameter — no extra import.
            .event_decl => {
                const decl = ast.event_decls.items[data];
                // `EventBus.register(self, gpa, comptime T, cap, lifetime)` —
                // `gpa` is the FIRST runtime arg (the queue's ring buffer is
                // heap-allocated). The producer tranche emitted it without `gpa`
                // (never Sema-compiled — events had no codegen differential);
                // surfaced + fixed by the observer drain's `build-obj` check.
                try w.printLine("try world.event_bus.register(gpa, {s}, 256, .tick);", .{ast.strings.slice(decl.name)});
            },
            else => {},
        }
    }

    // Register the builtin `TagSet` component (M0.8 E3) when the program
    // declares any tag. The raw descriptor mirrors the interpreter's
    // `compileProgram` registration exactly (name "TagSet", size `@sizeOf`,
    // align `@alignOf`, zeroed default, no named fields) so the runtime
    // component id and layout are byte-identical across backends. The id is
    // discarded — the rules look it up by name via `idOf("TagSet")`.
    if (tag_table.leaf_count > 0) {
        try w.line("{");
        w.indentBy(1);
        try w.line("var __tagset_default: TagSet = .{};");
        try w.line("_ = try world.registry.registerComponentRaw(gpa, .{");
        w.indentBy(1);
        try w.line(".name = \"TagSet\",");
        try w.line(".size = @sizeOf(TagSet),");
        try w.line(".alignment = @alignOf(TagSet),");
        try w.line(".default_bytes = std.mem.asBytes(&__tagset_default),");
        try w.line(".fields = &.{},");
        w.indentBy(-1);
        try w.line("});");
        w.indentBy(-1);
        try w.line("}");
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
    /// Positive tag filters (`has_tag` / `has_any_tag` / `has_all_tags`) with
    /// their operand leaf bits resolved against the global tag table (M0.8
    /// E3). Each emits a per-slot bit-test `continue` guard in the archetype
    /// walk. Non-empty forces the arch-walk path. Negative tag ops fail loud
    /// upstream (deferred to the interpreter reference).
    tag_filters: []TagFilterInfo,
    /// Components named by `has T changed` filters (M0.8 E3). Each emits a
    /// per-slot `changedTick(T) > __last_run` continue guard in the arch walk.
    /// Non-empty forces the arch-walk path.
    changed_components: [][]const u8,
};

/// A positive tag-filter predicate lowered to its operand leaf bits — the
/// codegen analogue of the interpreter's `TagPredicate` (M0.8 E3). `bits` is
/// the resolved leaf-bit set (a single bit for `has_tag`, the operand union or
/// an expanded category mask for the multi operators).
const TagFilterInfo = struct {
    op: ast_mod.TagOp,
    bits: []u32,
};

/// A rule's emission descriptor consumed by `tick`: its Zig name and whether
/// its body issues a tag mutation (and therefore takes a `*CommandBuffer`).
const RuleEmit = struct {
    name: []const u8,
    tag_mutating: bool,
    /// `@on_event(T)` observer (M0.8 E3): the event type name, or null for a
    /// non-observer. When set, `tick` subscribes a `*EventCursor` at head=0 and
    /// threads it into the rule call.
    event_type: ?[]const u8 = null,
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

/// Emit one Zig `fn` for a top-level Etch `fn` (M0.8 E2 call mechanism). The
/// body is a value-block: the statement run is emitted, then the trailing
/// expression as `return <value>;` (the implicit return). Params + return type
/// map through `type_map`. `async` codegen is Phase 2 and a `throws` fn's
/// codegen folds into the E3 error-handling-codegen gate — both fail loud
/// (`UnsupportedConstruct`); the interpreter is the reference for them.
fn emitFnDecl(w: *Writer, ast: *const AstArena, decl: ast_mod.FnDecl) CodegenError!void {
    if (decl.generics_len > 0) return CodegenError.UnsupportedConstruct; // generic monomorphisation → Phase 2
    if (decl.is_async) return CodegenError.UnsupportedConstruct; // async codegen → Phase 2
    if (decl.throws) return CodegenError.UnsupportedConstruct; // throws codegen → E3 gate

    var ctx: LocalCtx = .{};
    defer ctx.deinit(w.gpa);

    try w.writeIndent();
    try w.write("fn ");
    try w.ident(ast.strings.slice(decl.name));
    try w.write("(");
    var p_i: u32 = 0;
    while (p_i < decl.params_len) : (p_i += 1) {
        if (p_i > 0) try w.write(", ");
        const p = ast.fn_params.items[decl.params_start + p_i];
        const zig_t = fnTypeZig(ast, p.type_node);
        try w.ident(ast.strings.slice(p.name));
        try w.print(": {s}", .{zig_t});
        try ctx.records.append(w.gpa, .{ .key = .{ .name = p.name }, .info = .{ .kind = .value, .zig_type = zig_t, .is_mut = false } });
    }
    try w.write(") ");
    try w.write(if (decl.return_type.isNone()) "void" else fnTypeZig(ast, decl.return_type));
    try w.write(" {\n");
    w.indentBy(1);

    var s: u32 = 0;
    while (s < decl.body_len) : (s += 1) {
        try emitStmt(w, ast, &ctx, @bitCast(ast.extra.items[decl.body_start + s]));
    }
    // Trailing block value = implicit return.
    if (!decl.value.isNone()) {
        try w.writeIndent();
        try w.write("return ");
        try emitExpr(w, ast, &ctx, decl.value);
        try w.write(";\n");
    }

    w.indentBy(-1);
    try w.writeIndent();
    try w.write("}\n\n");
}

/// Map a `fn` parameter / return type node to its Zig type name (M0.8 E2).
/// Block-2 fns use named scalar types (alias-resolved); a builtin maps through
/// `type_map`, a user type passes through 1:1 (same as rule params).
fn fnTypeZig(ast: *const AstArena, type_node: NodeId) []const u8 {
    const tnode = ast.named_types.items[ast.typeNodeData(type_node)];
    const tname = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
    return type_map.mapBuiltin(tname) orelse tname;
}

/// Whether a rule's body issues a tag mutation (`add_tag` / `remove_tag`),
/// scanned at the top level of the body (M0.8 E3). Tag mutations are rule
/// actions and appear as top-level statements in the delivered grammar; a
/// mutation nested in control flow would surface as a loud Zig compile error
/// (`cmd` out of scope), never a silent miss.
fn ruleHasTagMutation(ast: *const AstArena, rule: ast_mod.RuleDecl) bool {
    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        const stmt_id: NodeId = @bitCast(ast.extra.items[rule.body_start + s]);
        if (ast.stmtKind(stmt_id) == .tag_mutation_stmt) return true;
    }
    return false;
}

/// Whether the program contains any `entity has T changed` filter (M0.8 E3).
/// `when_nodes` is a flat slab over every rule's when clause, so a single scan
/// for a `has_changed` kind answers the program-level question.
fn programUsesChanged(ast: *const AstArena) bool {
    for (ast.when_nodes.items) |n| {
        if (n.kind == .has_changed) return true;
    }
    return false;
}

/// Emit an `@on_event(T)` observer rule (M0.8 E3): drain the world event bus
/// for type `T`, firing the body once per event with the implicit `event`
/// binding (a Zig local of type `T`, so `event.field` lowers to `event.field`).
///
/// The engraved drain contract (validated for the C-tranche byte-exact diff):
/// `tick` calls `world.event_bus.drainAtBoundary(.tick)` then `subscribe`s a
/// `*EventCursor` at head=0 — BEFORE any rule runs / emits — and threads it in;
/// the observer then `while (poll) |event|` reads every event emitted earlier
/// the same tick. This matches the interpreter's per-tick `EventStore` (cleared
/// at `stepOnce` start, drained in emit order), so the two backends agree.
///
/// Scope: the observer is pure event-based. A combined event+entity form (a
/// component `when` or tag filter on the observer) and the body's receiver-less
/// resource write (`get_mut(R)`, D-S3-resource-receiver) are deferred — the
/// former fails loud here, the latter in `emitStmt`; the interpreter is the
/// reference for both, and the full byte-exact event differential closes in the
/// sub-slice-C codegen tranche once resource-receiver codegen lands.
fn emitObserverRule(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable) CodegenError!void {
    const name = ast.strings.slice(rule.name);
    const annot = ast.onEventAnnotation(rule) orelse return CodegenError.UnsupportedConstruct;
    const event_type = ast.onEventTypeName(annot) orelse return CodegenError.UnsupportedConstruct;
    const etype_name = ast.strings.slice(event_type);

    var info = try collectWhenInfo(w.gpa, ast, rule, tag_table);
    defer freeWhenInfo(w.gpa, &info);
    // Combined event+entity (an observer that also iterates entities via a
    // component `when`, or a per-entity tag filter) is out of M0.8 scope.
    if (info.has_component_ref or info.tag_filters.len > 0) return CodegenError.UnsupportedConstruct;

    try w.printLine("pub fn rule_{s}(world: *World, ev_cursor: *EventCursor) void {{", .{name});
    w.indentBy(1);

    // Resource gates (`when resource R [changed]`) — checked once before the
    // drain, identical to the entity-rule path.
    for (info.resource_deps) |dep| {
        try w.printLine("const {s}_id = world.registry.idOf(\"{s}\") orelse return;", .{ dep.name, dep.name });
        if (dep.must_be_changed) {
            try w.printLine("if (!world.resources.isDirty({s}_id)) return;", .{dep.name});
        } else {
            try w.printLine("if (!world.resources.contains({s}_id)) return;", .{dep.name});
        }
    }

    // Drain: one body run per event of type `T`.
    try w.printLine("while (world.event_bus.poll({s}, ev_cursor) catch null) |event| {{", .{etype_name});
    w.indentBy(1);

    var ctx: LocalCtx = .{ .tag_table = tag_table };
    defer ctx.deinit(w.gpa);
    try ctx.recordParams(w.gpa, ast, rule);
    // Bind the implicit `event` payload as a value of type `T`. The body must
    // reference `event` (an observer that ignores its payload trips Zig's
    // unused-capture check — fail loud; a discard refinement is deferred).
    if (ast.strings.find("event")) |event_id| {
        try ctx.records.append(w.gpa, .{
            .key = .{ .name = event_id },
            .info = .{ .kind = .value, .zig_type = etype_name, .is_mut = false },
        });
    }
    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        try emitStmt(w, ast, &ctx, @bitCast(ast.extra.items[rule.body_start + s]));
    }

    w.indentBy(-1);
    try w.line("}"); // while drain
    w.indentBy(-1);
    try w.line("}"); // fn
    try w.blankLine();
}

fn emitRule(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable, program_has_changed: bool) CodegenError!void {
    // `async rule` (M0.8 E3 sub-slice B) lowers to a suspend/resume state
    // machine — HIR-dependent, Phase 2. The interpreter is the reference; the
    // codegen rejects it loudly (consistent with `async fn` at l.689).
    if (rule.is_async) return CodegenError.UnsupportedConstruct;

    const name = ast.strings.slice(rule.name);

    // Collect what the when clause needs first (a negative tag op fails loud
    // here, before any output is emitted).
    var info = try collectWhenInfo(w.gpa, ast, rule, tag_table);
    defer freeWhenInfo(w.gpa, &info);

    // A tag-mutating rule takes a `*CommandBuffer` and is dispatched with
    // `&cmd` by `tick`. A mutation needs an iterated entity, so it must be
    // entity-bound — a resource-only / global rule with a tag mutation is
    // inconsistent and fails loud (the interpreter is the reference).
    const tag_mutating = ruleHasTagMutation(ast, rule);
    if (tag_mutating and !info.has_component_ref) return CodegenError.UnsupportedConstruct;

    // A rule with a `changed` filter (M0.8 E3) keeps its own module-level
    // `last_run_tick`: the baseline `changedTick(T) > __last_run_<name>` compares
    // against, updated at the end of the fn. Per-rule, byte-exact with the
    // interpreter's `RuleDesc.last_run_tick`.
    if (info.changed_components.len > 0) {
        try w.printLine("var __last_run_{s}: u32 = 0;", .{name});
    }

    if (tag_mutating) {
        try w.printLine("pub fn rule_{s}(world: *World, cmd: *CommandBuffer) void {{", .{name});
    } else {
        try w.printLine("pub fn rule_{s}(world: *World) void {{", .{name});
    }
    w.indentBy(1);

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
    // A positive tag filter reads `TagSet_arr[slot].bits[..]` per entity, so
    // `TagSet` needs a per-slot pointer emitted (M0.8 E3). `collectWhenInfo`
    // already added "TagSet" to `info.components` for the id + `has TagSet`
    // archetype predicate.
    if (info.tag_filters.len > 0) {
        _ = try body_used.getOrPut(w.gpa, "TagSet");
    }

    if (info.has_or_or_not or info.tag_filters.len > 0 or tag_mutating or program_has_changed) {
        // Path 2 — manual archetype walk. Reserved for the S4 inherited
        // debt cases (`not has X`, `entity has A or entity has B`), the M0.8 E3
        // tag cases (a positive tag filter / a tag mutation needs the entity id,
        // which the comptime-query `Row` does not expose), and — when the
        // program uses `changed` filters — EVERY component rule, so a writer's
        // `markChanged` and a `changed` filter's per-slot `changedTick` can
        // address `arch`/`chunk`/`slot`. The synth bench corpus never hits this
        // branch (gate 4's monomorphisation count reflects only the AND path).
        try emitRuleAsArchWalk(w, ast, rule, info, &body_used, tag_mutating, tag_table, program_has_changed);
    } else {
        // Path 1 — comptime query. The cooked code emits one
        // `comptime_query.query(world, .{T1, T2, ...})` invocation per
        // rule signature; Zig comptime monomorphises one iterator type
        // per distinct tuple.
        try emitRuleAsComptimeQuery(w, ast, rule, info, &body_used);
    }

    // Advance this rule's change-detection baseline to the current tick — the
    // value its next-tick `changed` guard compares against (M0.8 E3). Emitted
    // after the walk so the guard saw the pre-update baseline.
    if (info.changed_components.len > 0) {
        try w.printLine("__last_run_{s} = world.current_tick;", .{name});
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
fn emitRuleAsArchWalk(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, body_used: *const std.StringHashMapUnmanaged(void), tag_mutating: bool, tag_table: *const tags_mod.TagTable, program_has_changed: bool) CodegenError!void {
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
        // `<C>_idx` is needed by a body access (`<C>_off` → `<C>_arr`) OR by a
        // `changed` guard (`changedTick(<C>_idx, …)`). `<C>_off`/`<C>_arr` are
        // emitted only for body-accessed components (a `changed`-only component
        // needs the index, not the data pointer).
        const in_body = body_used.contains(cname);
        const in_changed = isChangedComponent(info, cname);
        if (!in_body and !in_changed) continue;
        try w.printLine("const {s}_idx = arch.componentIndex({s}_id).?;", .{ cname, cname });
        if (in_body) {
            try w.printLine("const {s}_off = arch.layout.component_offsets[{s}_idx];", .{ cname, cname });
        }
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
    // Materialise the entity id for any tag mutation in the body — the
    // command-buffer `setTag`/`clearTag` calls take it (M0.8 E3). The
    // comptime-query `Row` exposes no entity id, which is why a tag mutation
    // forces this arch-walk path.
    if (tag_mutating) {
        try w.line("const __entity = arch.entityIdsConst(chunk)[slot];");
    }
    if (info.field_filter) |ff| {
        try w.writeIndent();
        try w.print("if ({s}_arr[slot].", .{ff.component_name});
        try w.ident(ff.field_name);
        try w.write(" != ");
        try emitConstExpr(w, ast, ff.value, ff.value_zig_type);
        try w.write(") continue;\n");
    }
    // Per-slot tag-filter guards (positive ops): skip the entity unless its
    // `TagSet` satisfies the predicate, byte-exact with the interpreter's
    // `tagPredicatesPass` (M0.8 E3).
    for (info.tag_filters) |tf| {
        try emitTagFilterGuard(w, tf);
    }
    // Per-slot `changed` guards (M0.8 E3): skip the slot unless its
    // `changedTick(T)` exceeds the rule's `last_run_tick` — byte-exact with the
    // interpreter's `changedFiltersPass`.
    const rname = ast.strings.slice(rule.name);
    for (info.changed_components) |cname| {
        try w.printLine("if (!(arch.changedTick(chunk, {s}_idx, slot) > __last_run_{s})) continue;", .{ cname, rname });
    }
    try emitRuleBody(w, ast, rule, info, tag_table, program_has_changed);
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

/// Whether component `name` carries an `entity has T changed` filter in this
/// rule (M0.8 E3) — its slot needs a `changedTick(T) > __last_run` guard.
fn isChangedComponent(info: WhenInfo, name: []const u8) bool {
    for (info.changed_components) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
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
        .while_stmt => {
            const wh = ast.while_stmts.items[data];
            try walkExprForComponents(gpa, ast, wh.cond, out);
            var s: u32 = 0;
            while (s < wh.body_len) : (s += 1) {
                try walkStmtForComponents(gpa, ast, @bitCast(ast.extra.items[wh.body_start + s]), out);
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
        .method_call => {
            const mc = ast.method_calls.items[data];
            // The receiver of a `Type.assoc()` is a bare type path (no
            // component ref); a `recv.method()` receiver may carry one.
            if (ast.exprKind(mc.receiver) != .path) try walkExprForComponents(gpa, ast, mc.receiver, out);
            var i: u32 = 0;
            while (i < mc.args_len) : (i += 1) {
                try walkExprForComponents(gpa, ast, @bitCast(ast.extra.items[mc.args_start + i]), out);
            }
        },
        .struct_lit => {
            const sl = ast.struct_lits.items[data];
            var i: u32 = 0;
            while (i < sl.fields_len) : (i += 1) {
                try walkExprForComponents(gpa, ast, ast.struct_lit_fields.items[sl.fields_start + i].value, out);
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
        .if_expr => {
            const ife = ast.if_exprs.items[data];
            try walkExprForComponents(gpa, ast, ife.cond, out);
            try walkExprForComponents(gpa, ast, ife.then_block, out);
            if (!ife.else_branch.isNone()) try walkExprForComponents(gpa, ast, ife.else_branch, out);
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
        .has, .has_with_filter, .has_changed => {
            // `has T changed` shares the `has T` archetype predicate (the entity
            // must own T); the per-slot change check is emitted in the body walk.
            const cname = ast.strings.slice(node.type_name);
            try w.print("arch.hasComponent({s}_id)", .{cname});
        },
        .resource, .resource_changed => {
            // Resource gates are tested ahead of the archetype loop (in
            // `emitRule`); inside the archetype predicate they evaluate to
            // a constant `true`.
            try w.write("true");
        },
        // A positive tag filter requires the entity to carry `TagSet`; the
        // per-slot bit test is a separate guard (`emitTagFilterGuard`). A
        // negative tag op also matches entities lacking `TagSet`, so its
        // arch-walk slot access is undefined — deferred, fail loud (M0.8 E3,
        // the interpreter is the reference).
        .tag_filter => {
            const tf = ast.tag_filters.items[node.aux];
            switch (tf.op) {
                .has_tag, .has_any_tag, .has_all_tags => try w.write("arch.hasComponent(TagSet_id)"),
                .has_no_tag, .has_no_tags => return CodegenError.UnsupportedConstruct,
            }
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

fn emitRuleBody(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, tag_table: *const tags_mod.TagTable, mark_changed: bool) CodegenError!void {
    var ctx: LocalCtx = .{ .tag_table = tag_table, .mark_changed = mark_changed };
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
    /// The global tag table, set when emitting a body that may contain a tag
    /// mutation (the arch-walk path). Used to resolve an `add_tag`/`remove_tag`
    /// path to its leaf bit (M0.8 E3). Null on the comptime-query path, where
    /// tag mutations cannot appear.
    tag_table: ?*const tags_mod.TagTable = null,
    /// True when the program uses `changed` filters and this body is on the
    /// arch-walk path (M0.8 E3): a component-field write then emits a trailing
    /// `arch.markChanged(chunk, <C>_idx, slot, world.current_tick)`, co-located
    /// with the assignment so it marks exactly when the write executes — the
    /// same per-write point as the interpreter's `markComponentChanged`, hence
    /// the `changed` differential is byte-exact by construction.
    mark_changed: bool = false,

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
            if (ek == .if_expr) {
                try emitIfAsStmt(w, ast, ctx, ast.exprData(eid));
                return;
            }
            if (ek == .match_expr) {
                try emitMatchAsStmt(w, ast, ctx, ast.exprData(eid));
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
        .return_stmt => {
            // `return [expr]` (M0.8 E2 call mechanism) → Zig `return [<expr>];`.
            const value: NodeId = @bitCast(data);
            try w.writeIndent();
            if (value.isNone()) {
                try w.write("return;\n");
            } else {
                try w.write("return ");
                try emitExpr(w, ast, ctx, value);
                try w.write(";\n");
            }
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
        .while_stmt => {
            // `while cond { body }` → Zig `while (<cond>) { <body> }` (M0.8
            // control flow). `while let x = opt { body }` → `while (opt) |x| {
            // body }` (M0.8 E2 block 5). The body is a statement run; `break` /
            // `continue` inside lower through their own statement cases.
            const wh = ast.while_stmts.items[data];
            try w.writeIndent();
            try w.write("while (");
            try emitExpr(w, ast, ctx, wh.cond);
            try w.write(") ");
            const saved = ctx.records.items.len;
            if (wh.let_binding != 0) {
                try w.write("|");
                try w.ident(ast.strings.slice(wh.let_binding));
                try w.write("| ");
                try ctx.records.append(w.gpa, .{ .key = .{ .name = wh.let_binding }, .info = .{ .kind = .value, .zig_type = "", .is_mut = false } });
            }
            try w.write("{\n");
            w.indentBy(1);
            var s: u32 = 0;
            while (s < wh.body_len) : (s += 1) {
                try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[wh.body_start + s]));
            }
            ctx.records.items.len = saved;
            w.indentBy(-1);
            try w.writeIndent();
            try w.write("}\n");
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
        .emit_stmt => {
            // `emit EventType { field: value, … }` → a typed enqueue on the
            // world's event bus (M0.8 E3). An event is a POD struct (ABI §3.1);
            // the field initializers become a typed struct literal. Omitted
            // fields take the `extern struct`'s declared defaults. `emit` is
            // `comptime T` over the event type. (The `@on_event` observer that
            // polls the bus is the E3 observer tranche, resolver-types §12.)
            const em = ast.emit_stmts.items[data];
            const ename = ast.strings.slice(em.event_type);
            // `catch unreachable`, not `try`: a generated rule fn returns `void`
            // (rule error-propagation is the sub-slice-C error-handling codegen,
            // ABI §11). `emit` only errors on an unregistered event type, which
            // cannot happen — every declared event is registered at init
            // (`register`), and queue saturation drops internally (no error).
            try w.printLine("world.event_bus.emit({s}, {s}{{", .{ ename, ename });
            w.indentBy(1);
            var i: u32 = 0;
            while (i < em.fields_len) : (i += 1) {
                const flit = ast.struct_lit_fields.items[em.fields_start + i];
                try w.writeIndent();
                try w.write(".");
                try w.ident(ast.strings.slice(flit.name));
                try w.write(" = ");
                try emitExpr(w, ast, ctx, flit.value);
                try w.write(",\n");
            }
            w.indentBy(-1);
            try w.line("}) catch unreachable;");
        },
        // `entity.add_tag(.path)` / `entity.remove_tag(.path)` (M0.8 E3,
        // `etch-grammar.md` §4.4) → a deferred `set_tag`/`clear_tag` command,
        // applied at the tick boundary by `cmd.flush()`. `__entity` is the
        // arch-walk slot's entity id; the `TagSet` id is looked up by name.
        // The append only fails on OOM, which a `void` rule swallows
        // (best-effort, matching the codegen's void-rule error stance).
        .tag_mutation_stmt => {
            const tm = ast.tag_mutation_stmts.items[data];
            const table = ctx.tag_table orelse return CodegenError.UnsupportedConstruct;
            const bit = tagPathLeafBitCodegen(ast, table, tm.path) orelse return CodegenError.UnsupportedConstruct;
            const method = if (tm.kind == .add) "setTag" else "clearTag";
            try w.writeIndent();
            try w.print("cmd.{s}(__entity, world.registry.idOf(\"TagSet\").?, {d}) catch {{}};\n", .{ method, bit });
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
    // Change detection (M0.8 E3): right after a component-field write, stamp
    // the slot's `changed_tick` so an `entity has T changed` rule sees it. The
    // marking is co-located with the assignment (so it executes exactly when
    // the write does, even under a conditional) and at the same logical point
    // as the interpreter's `markComponentChanged` → byte-exact by construction.
    if (ctx.mark_changed) {
        if (assignTargetComponent(ast, ctx, assign.target)) |cname| {
            try w.printLine("arch.markChanged(chunk, {s}_idx, slot, world.current_tick);", .{cname});
        }
    }
}

/// The component name a write targets, when `assign.target` is a component-field
/// write (`entity.get_mut(C).field` or a `let h = get_mut(C)` alias) (M0.8 E3) —
/// or null for any other target (resource / struct / local). Drives the trailing
/// `markChanged`; a non-component write must not mark.
fn assignTargetComponent(ast: *const AstArena, ctx: *const LocalCtx, target: NodeId) ?[]const u8 {
    if (ast.exprKind(target) != .field_access) return null;
    const fa = ast.field_accesses.items[ast.exprData(target)];
    const recv = fa.receiver;
    switch (ast.exprKind(recv)) {
        .method_get_mut => {
            const mg = ast.method_gets.items[ast.exprData(recv)];
            if (mg.receiver.isNone()) return null; // receiver-less get → resource, not a component
            return ast.strings.slice(mg.type_name);
        },
        .ident => {
            if (ctx.lookup(ast.exprData(recv))) |local| {
                if (local.kind == .component_alias) return local.component_name;
            }
            return null;
        },
        else => return null,
    }
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
        // `none` / `some(x)` optional literals (M0.8 E2 block 5). `none` → Zig
        // `null` (its type comes from the binding annotation / context);
        // `some(x)` self-types as `@as(?<payload>, x)` for a scalar payload
        // (a non-scalar payload is deferred → fail loud).
        .none_lit => try w.write("null"),
        .some_lit => {
            const inner: NodeId = @bitCast(data);
            const payload_zig = inferExprZigType(ast, ctx, inner);
            const opt_zig = optionalOf(payload_zig) orelse return CodegenError.UnsupportedConstruct;
            try w.print("@as({s}, ", .{opt_zig});
            try emitExpr(w, ast, ctx, inner);
            try w.write(")");
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
            // Enum value `EnumName.variant` → Zig `EnumName.variant` (M0.8 E2
            // block 3 tranche B).
            if (enumValueName(ast, id)) |ename| {
                try w.print("{s}.", .{ename});
                try w.ident(ast.strings.slice(fa.field_name));
                return;
            }
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
            // Two callee shapes (M0.8 E2). A callee that is an ident not bound
            // to a local is a top-level `fn` → direct `name(args)`. Otherwise
            // it's a closure-typed local → `callee.call(args)` (E1 closures,
            // lowered to the anonymous struct above).
            const call = ast.call_exprs.items[data];
            const is_free_fn = ast.exprKind(call.callee) == .ident and ctx.lookup(ast.exprData(call.callee)) == null;
            if (is_free_fn) {
                try w.ident(ast.strings.slice(ast.exprData(call.callee)));
            } else {
                try emitExpr(w, ast, ctx, call.callee);
                try w.write(".call");
            }
            try w.write("(");
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (i > 0) try w.write(", ");
                const arg: NodeId = @bitCast(ast.extra.items[call.args_start + i]);
                try emitExpr(w, ast, ctx, arg);
            }
            try w.write(")");
        },
        .struct_lit => {
            // `T { f: v, … }` → Zig `T{ .f = v, … }` (M0.8 E2 block 3). The
            // anonymous `.{ … }` form (`type_name == 0`) is deferred. Omitted
            // fields fall back to the `extern struct` declared defaults.
            const sl = ast.struct_lits.items[data];
            if (sl.type_name == 0) return CodegenError.UnsupportedConstruct;
            try w.print("{s}{{", .{ast.strings.slice(sl.type_name)});
            var i: u32 = 0;
            while (i < sl.fields_len) : (i += 1) {
                const flit = ast.struct_lit_fields.items[sl.fields_start + i];
                if (i > 0) try w.write(",");
                try w.write(" .");
                try w.ident(ast.strings.slice(flit.name));
                try w.write(" = ");
                try emitExpr(w, ast, ctx, flit.value);
            }
            try w.write(" }");
        },
        .method_call => {
            // `recv.method(args)` / `Type.assoc(args)` → Zig method / associated
            // call (M0.8 E2 block 3, §5.1). Inherent methods are emitted inside
            // the struct, so Zig's `value.method(args)` / `Type.assoc(args)`
            // syntax resolves them directly.
            const mc = ast.method_calls.items[data];
            if (ast.exprKind(mc.receiver) == .path) {
                // Associated fn: the receiver is a bare type name.
                try w.write(ast.strings.slice(ast.exprData(mc.receiver)));
            } else {
                try emitExpr(w, ast, ctx, mc.receiver);
            }
            try w.write(".");
            try w.ident(ast.strings.slice(mc.method_name));
            try w.write("(");
            var i: u32 = 0;
            while (i < mc.args_len) : (i += 1) {
                if (i > 0) try w.write(", ");
                try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[mc.args_start + i]));
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
        .if_expr => {
            // `if cond { a } else { b }` in value position → Zig if-expression
            // `if (<cond>) <then-value> else <else-value>` (M0.8 control flow).
            // The branches are block expressions emitted as values; `else if`
            // recurses as a nested if-expression. An else-less `if` in value
            // position has no Zig value — the type-checker treats it as unit, so
            // a sound program never lands one here.
            const ife = ast.if_exprs.items[data];
            try w.write("if (");
            try emitExpr(w, ast, ctx, ife.cond);
            try w.write(") ");
            // `if let x = opt { … } else { … }` in value position → Zig
            // `if (opt) |x| <then> else <else>` (M0.8 E2 block 5). Zig infers
            // `x`'s type from the optional payload.
            const saved = ctx.records.items.len;
            if (ife.let_binding != 0) {
                try w.write("|");
                try w.ident(ast.strings.slice(ife.let_binding));
                try w.write("| ");
                try ctx.records.append(w.gpa, .{ .key = .{ .name = ife.let_binding }, .info = .{ .kind = .value, .zig_type = "", .is_mut = false } });
            }
            try emitExpr(w, ast, ctx, ife.then_block);
            ctx.records.items.len = saved;
            if (!ife.else_branch.isNone()) {
                try w.write(" else ");
                try emitExpr(w, ast, ctx, ife.else_branch);
            }
        },
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
            .enum_variant => {
                const pat = ast.enum_pattern_payloads.items[arm.pattern_payload];
                const ename = enumPatternTypeName(ast, ctx, pat, m.scrutinee) orelse return CodegenError.UnsupportedConstruct;
                try w.print("if (__m{d} == {s}.", .{ lbl, ename });
                try w.ident(ast.strings.slice(pat.variant));
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

/// Emit a `match` in statement position (M0.8 control flow): an if-else chain
/// over the scrutinee binding, each arm body run as statements with its value
/// discarded. Used when arms carry control flow (`_ => { break }`) or side
/// effects, where the value-block form (`emitMatch`) would be ill-typed
/// (value-less / divergent arms). `data` is the `match_exprs` slab index;
/// `__ms<n>` is unique per match. Well-formed matches place the catch-all
/// (wildcard / binding) arm last, so the `else` lands at the chain's tail.
fn emitMatchAsStmt(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    const m = ast.match_exprs.items[data];
    const lbl = data;
    try w.writeIndent();
    try w.print("{{ const __ms{d} = ", .{lbl});
    try emitExpr(w, ast, ctx, m.scrutinee);
    try w.write(";\n");
    w.indentBy(1);
    var i: u32 = 0;
    var chained = false;
    while (i < m.arms_len) : (i += 1) {
        const arm = ast.match_arms.items[m.arms_start + i];
        try w.writeIndent();
        if (chained) try w.write("else ");
        switch (arm.pattern_kind) {
            .literal => {
                const lit: NodeId = @bitCast(arm.pattern_payload);
                try w.print("if (__ms{d} == ", .{lbl});
                try emitExpr(w, ast, ctx, lit);
                try w.write(") ");
                try emitArmBodyAsStmts(w, ast, ctx, arm.body, lbl, null);
                chained = true;
            },
            .enum_variant => {
                const pat = ast.enum_pattern_payloads.items[arm.pattern_payload];
                const ename = enumPatternTypeName(ast, ctx, pat, m.scrutinee) orelse return CodegenError.UnsupportedConstruct;
                try w.print("if (__ms{d} == {s}.", .{ lbl, ename });
                try w.ident(ast.strings.slice(pat.variant));
                try w.write(") ");
                try emitArmBodyAsStmts(w, ast, ctx, arm.body, lbl, null);
                chained = true;
            },
            .wildcard => try emitArmBodyAsStmts(w, ast, ctx, arm.body, lbl, null),
            .binding => try emitArmBodyAsStmts(w, ast, ctx, arm.body, lbl, arm.pattern_payload),
        }
        try w.write("\n");
    }
    w.indentBy(-1);
    try w.writeIndent();
    try w.write("}\n");
}

/// Emit a match arm body as a braced Zig statement block with its value
/// discarded (M0.8 control flow). A `bind_name` (binding-pattern arm) declares
/// the bound name from the scrutinee snapshot `__ms<lbl>`. A `block_expr` body
/// inlines its statements + discarded trailing value; an expression body is
/// discarded with `_ = <expr>;`.
fn emitArmBodyAsStmts(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, body: NodeId, lbl: u32, bind_name: ?StringId) CodegenError!void {
    try w.write("{\n");
    w.indentBy(1);
    const saved = ctx.records.items.len;
    if (bind_name) |name| {
        try w.writeIndent();
        try w.write("const ");
        try w.ident(ast.strings.slice(name));
        try w.print(" = __ms{d};\n", .{lbl});
        try ctx.records.append(w.gpa, .{ .key = .{ .name = name }, .info = .{ .kind = .value, .zig_type = "", .is_mut = false } });
    }
    if (ast.exprKind(body) == .block_expr) {
        const blk = ast.block_exprs.items[ast.exprData(body)];
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
    } else {
        try w.writeIndent();
        try w.write("_ = ");
        try emitExpr(w, ast, ctx, body);
        try w.write(";\n");
    }
    ctx.records.items.len = saved;
    w.indentBy(-1);
    try w.writeIndent();
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

/// Emit a block expression's body as a braced Zig statement block
/// `{ <stmts> [_ = <value>;] }` — the body statements plus the trailing value
/// discarded — with no leading indent and no trailing newline. The caller
/// positions it (bare block statement, `if` / `while` branch bodies). `data` is
/// the `block_exprs` slab index.
fn emitBraceBlock(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    const blk = ast.block_exprs.items[data];
    const saved = ctx.records.items.len;
    try w.write("{\n");
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
    try w.writeIndent();
    try w.write("}");
    ctx.records.items.len = saved;
}

/// Emit a bare block expression in statement position (M0.8 control flow): the
/// braced block with its trailing value discarded.
fn emitBlockExprStmts(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    try w.writeIndent();
    try emitBraceBlock(w, ast, ctx, data);
    try w.write("\n");
}

/// Emit an `if` expression in statement position (M0.8 control flow): a Zig
/// `if (<cond>) { ... } [else if ...] [else { ... }]` statement whose branch
/// values are discarded. `data` is the `if_exprs` slab index.
fn emitIfAsStmt(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    try w.writeIndent();
    try emitIfChain(w, ast, ctx, data);
    try w.write("\n");
}

/// Emit the `if (...) { ... } else ...` chain (no leading indent / trailing
/// newline). The else-if branch recurses; a final `else` is a block.
fn emitIfChain(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, data: u32) CodegenError!void {
    const ife = ast.if_exprs.items[data];
    try w.write("if (");
    try emitExpr(w, ast, ctx, ife.cond);
    try w.write(") ");
    // `if let x = opt { … }` → `if (opt) |x| { … }` (M0.8 E2 block 5).
    const saved = ctx.records.items.len;
    if (ife.let_binding != 0) {
        try w.write("|");
        try w.ident(ast.strings.slice(ife.let_binding));
        try w.write("| ");
        try ctx.records.append(w.gpa, .{ .key = .{ .name = ife.let_binding }, .info = .{ .kind = .value, .zig_type = "", .is_mut = false } });
    }
    try emitBraceBlock(w, ast, ctx, ast.exprData(ife.then_block));
    ctx.records.items.len = saved;
    if (ife.else_branch.isNone()) return;
    try w.write(" else ");
    if (ast.exprKind(ife.else_branch) == .if_expr) {
        try emitIfChain(w, ast, ctx, ast.exprData(ife.else_branch));
    } else {
        try emitBraceBlock(w, ast, ctx, ast.exprData(ife.else_branch));
    }
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
    // `T?` optional annotation → `?<payload>` (M0.8 E2 block 5): used so `let o:
    // int? = none` emits `const o: ?i64 = null;`. A `some(...)` RHS self-types
    // via `@as`, so the annotation is redundant there but harmless.
    if (!annotation.isNone() and ast.typeNodeKind(annotation) == .optional) {
        if (optionalAnnotationZig(ast, annotation)) |z| return z;
    }
    return inferExprZigType(ast, ctx, expr);
}

/// The Zig type string for a `T?` optional type-node with a builtin-scalar
/// payload (M0.8 E2 block 5): `?i64` / `?f64` / `?bool` / … A non-scalar
/// payload (deferred) yields `null`.
fn optionalAnnotationZig(ast: *const AstArena, type_node: NodeId) ?[]const u8 {
    const payload_node: NodeId = @bitCast(ast.typeNodeData(type_node));
    if (ast.typeNodeKind(payload_node) != .named) return null;
    const tnode = ast.named_types.items[ast.typeNodeData(payload_node)];
    const tname = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
    return optionalOf(type_map.mapBuiltin(tname) orelse return null);
}

/// Map a builtin Zig scalar type to its `?`-prefixed optional literal (M0.8 E2
/// block 5). Returns `null` for any non-scalar payload.
fn optionalOf(zig_scalar: []const u8) ?[]const u8 {
    const pairs = .{
        .{ "i64", "?i64" },       .{ "f64", "?f64" }, .{ "bool", "?bool" },
        .{ "i32", "?i32" },       .{ "u32", "?u32" }, .{ "f32", "?f32" },
        .{ "Entity", "?Entity" },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, zig_scalar, p[0])) return p[1];
    }
    return null;
}

/// `true` if `name` is a declared `enum` (M0.8 E2 block 3 tranche B).
fn isEnumName(ast: *const AstArena, name: StringId) bool {
    var i: usize = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .enum_decl) continue;
        if (ast.enum_decls.items[ast.items.items(.data)[i]].name == name) return true;
    }
    return false;
}

/// The enum type name if `expr` is an enum value `EnumName.variant` — a `.path`
/// receiver naming a declared `enum` + a variant field (M0.8 E2 block 3 tranche
/// B). `null` otherwise.
fn enumValueName(ast: *const AstArena, expr: NodeId) ?[]const u8 {
    if (ast.exprKind(expr) != .field_access) return null;
    const fa = ast.field_accesses.items[ast.exprData(expr)];
    if (ast.exprKind(fa.receiver) != .path) return null;
    const path_name = ast.exprData(fa.receiver);
    if (!isEnumName(ast, path_name)) return null;
    return ast.strings.slice(path_name);
}

/// The enum type name an `.enum_variant` match pattern compares against (M0.8
/// E2 block 3 tranche B). Qualified `Type.v` uses its explicit type; shorthand
/// `.v` infers the enum from the scrutinee. Returns `null` when the shorthand's
/// scrutinee type is not a resolvable enum, so the caller fails loud rather than
/// emit `i64.v`.
fn enumPatternTypeName(ast: *const AstArena, ctx: *LocalCtx, pat: ast_mod.EnumPatternPayload, scrutinee: NodeId) ?[]const u8 {
    if (pat.type_name != 0) return ast.strings.slice(pat.type_name);
    const inferred = inferExprZigType(ast, ctx, scrutinee);
    if (ast.strings.find(inferred)) |sid| {
        if (isEnumName(ast, sid)) return inferred;
    }
    return null;
}

fn inferExprZigType(ast: *const AstArena, ctx: *LocalCtx, expr: NodeId) []const u8 {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    return switch (kind) {
        .int_lit => "i64",
        .float_lit => "f64",
        .bool_lit => "bool",
        // Optionals (M0.8 E2 block 5): `some(x)` self-types via `@as` in
        // `emitExpr`, so the binding needs no annotation ("" → Zig infers);
        // `none` relies on the binding annotation (handled in `inferZigType`).
        .some_lit, .none_lit => "",
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
            // Enum value `EnumName.variant` → the enum type name (M0.8 E2 block
            // 3 tranche B), so a `let d = Difficulty.hard` binds at that type.
            if (enumValueName(ast, expr)) |ename| break :blk ename;
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
        // Struct literals (struct type) and method-call results (the method's
        // return type) are left to Zig inference (M0.8 E2 block 3).
        .struct_lit => "",
        .method_call => "",
        // A loop expression's value type is inferred by Zig from its break.
        .loop_expr => "",
        // A block expression's value type is inferred by Zig from its trailing
        // value (left un-annotated so block-locals need not be in scope here).
        .block_expr => "",
        // An if-expression needs a concrete `let` annotation: a runtime
        // condition selecting bare comptime-int / -float literal branches is
        // rejected by Zig unless a result type is fixed. Infer it from the
        // then-branch's trailing value.
        .if_expr => blk: {
            const ife = ast.if_exprs.items[data];
            const tb = ast.block_exprs.items[ast.exprData(ife.then_block)];
            break :blk if (tb.value.isNone()) "i64" else inferExprZigType(ast, ctx, tb.value);
        },
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
            if (ctx.lookup(sid)) |local| {
                if (local.kind == .component_alias) break :blk local.component_name;
                // A struct-typed value local (M0.8 E2 block 3): its Zig type
                // name is the struct name (Etch ↔ Zig types map 1:1), so the
                // field's declared type resolves on that struct.
                if (local.kind == .value and local.zig_type.len > 0 and type_map.mapBuiltin(local.zig_type) == null) break :blk local.zig_type;
            }
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
        if (kind != .component_decl and kind != .resource_decl and kind != .struct_decl) continue;
        const data = ast.items.items(.data)[i];
        const decl_name: []const u8 = switch (kind) {
            .component_decl => ast.strings.slice(ast.component_decls.items[data].name),
            .resource_decl => ast.strings.slice(ast.resource_decls.items[data].name),
            .struct_decl => ast.strings.slice(ast.struct_decls.items[data].name),
            else => unreachable,
        };
        if (!std.mem.eql(u8, decl_name, comp_name)) continue;
        const fields_start: u32 = switch (kind) {
            .component_decl => ast.component_decls.items[data].fields_start,
            .resource_decl => ast.resource_decls.items[data].fields_start,
            .struct_decl => ast.struct_decls.items[data].fields_start,
            else => unreachable,
        };
        const fields_len: u32 = switch (kind) {
            .component_decl => ast.component_decls.items[data].fields_len,
            .resource_decl => ast.resource_decls.items[data].fields_len,
            .struct_decl => ast.struct_decls.items[data].fields_len,
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

fn emitTick(w: *Writer, rules: []const RuleEmit, program_has_changed: bool) CodegenError!void {
    var any_tag_mutation = false;
    var any_observer = false;
    for (rules) |r| {
        if (r.tag_mutating) any_tag_mutation = true;
        if (r.event_type != null) any_observer = true;
    }

    try w.line("/// Execute every rule once in source declaration order, apply any");
    try w.line("/// deferred tag mutations, then clear resource dirty bits —");
    try w.line("/// equivalent to a single tick of the S4 interpreter's `stepOnce`");
    try w.line("/// (rules + `flushPendingTags`) + `tickBoundary`. `gpa` is the");
    try w.line("/// uniform allocator-threading contract for the generated code");
    try w.line("/// (M0.8 E3); the tag command buffer is its first consumer.");
    if (any_observer) {
        try w.line("///");
        try w.line("/// `@on_event(T)` observers: the per-tick event queue is drained at the");
        try w.line("/// top (matching the interpreter's `events.clear()` at `stepOnce` start),");
        try w.line("/// then every observer cursor is subscribed at head=0 BEFORE any rule");
        try w.line("/// emits — so an observer reads every event emitted earlier the same tick.");
    }
    try w.line("pub fn tick(world: *World, gpa: std.mem.Allocator) void {");
    w.indentBy(1);

    if (program_has_changed) {
        // Open the tick before its rules run (change detection, M0.8 E3):
        // advance `current_tick` + clear the dirty bitsets, so a write this tick
        // stamps `changedTick = current_tick > __last_run` and a `changed` rule
        // fires for it — byte-exact with the interpreter's `runFor` `beginFrame`.
        try w.line("world.beginFrame();");
    }

    if (any_tag_mutation) {
        // A tick-scoped command buffer collects deferred tag mutations; it is
        // flushed (applied) after every rule has run, before the boundary —
        // never mid-archetype-walk. It owns and frees its arena each tick, so
        // a plain gpa is leak-free here.
        try w.line("var cmd = CommandBuffer.init(gpa, world);");
        try w.line("defer cmd.deinit();");
    } else {
        // No tag mutation → the threaded gpa is unused this tick (event
        // drain / subscribe / poll need no allocator).
        try w.line("_ = gpa;");
    }

    if (any_observer) {
        // Clear the previous tick's events (per-tick lifetime), then open every
        // observer cursor at the current head (0 after the drain) — before any
        // rule runs, so a cursor sees this tick's emissions from the start.
        try w.line("world.event_bus.drainAtBoundary(.tick);");
        for (rules, 0..) |r, i| {
            if (r.event_type) |etype| {
                try w.printLine("var __evcur_{d} = world.event_bus.subscribe({s}) catch unreachable;", .{ i, etype });
            }
        }
    }

    for (rules, 0..) |r, i| {
        if (r.tag_mutating) {
            try w.printLine("rule_{s}(world, &cmd);", .{r.name});
        } else if (r.event_type != null) {
            try w.printLine("rule_{s}(world, &__evcur_{d});", .{ r.name, i });
        } else {
            try w.printLine("rule_{s}(world);", .{r.name});
        }
    }

    if (any_tag_mutation) try w.line("cmd.flush() catch {};");
    try w.line("world.tickBoundary();");
    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

// ─── WhenInfo collection ────────────────────────────────────────────────────

fn collectWhenInfo(gpa: std.mem.Allocator, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable) CodegenError!WhenInfo {
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer components.deinit(gpa);
    var seen_components: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_components.deinit(gpa);
    var res_deps: std.ArrayListUnmanaged(ResourceDep) = .empty;
    errdefer res_deps.deinit(gpa);
    var tag_filters: std.ArrayListUnmanaged(TagFilterInfo) = .empty;
    errdefer {
        for (tag_filters.items) |*tf| gpa.free(tf.bits);
        tag_filters.deinit(gpa);
    }
    var field_filter: ?FieldFilter = null;
    var has_component_ref: bool = false;
    var has_or_or_not: bool = false;
    var changed_components: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer changed_components.deinit(gpa);

    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        // `walkWhen` populates components / resources / field filter and adds
        // "TagSet" to components for positive tag filters (fails loud on
        // negative tag ops). A second pass resolves the operand leaf bits for
        // the per-slot guards (M0.8 E3).
        try walkWhen(gpa, ast, rule.when_root, &components, &seen_components, &res_deps, &field_filter, &has_component_ref, &has_or_or_not, &changed_components);
        try collectTagFilters(gpa, ast, tag_table, rule.when_root, &tag_filters);
    }

    return .{
        .components = try components.toOwnedSlice(gpa),
        .resource_deps = try res_deps.toOwnedSlice(gpa),
        .field_filter = field_filter,
        .has_component_ref = has_component_ref,
        .has_or_or_not = has_or_or_not,
        .tag_filters = try tag_filters.toOwnedSlice(gpa),
        .changed_components = try changed_components.toOwnedSlice(gpa),
    };
}

fn freeWhenInfo(gpa: std.mem.Allocator, info: *WhenInfo) void {
    gpa.free(info.components);
    gpa.free(info.resource_deps);
    for (info.tag_filters) |*tf| gpa.free(tf.bits);
    gpa.free(info.tag_filters);
    gpa.free(info.changed_components);
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
    changed: *std.ArrayListUnmanaged([]const u8),
) !void {
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and => {
            try walkWhen(gpa, ast, node.lhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not, changed);
            try walkWhen(gpa, ast, node.rhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not, changed);
        },
        .logical_or => {
            has_or_or_not.* = true;
            try walkWhen(gpa, ast, node.lhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not, changed);
            try walkWhen(gpa, ast, node.rhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not, changed);
        },
        .logical_not => {
            has_or_or_not.* = true;
            try walkWhen(gpa, ast, node.lhs, components, seen, res_deps, filter, has_component_ref, has_or_or_not, changed);
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
        .has_changed => {
            // `entity has T changed` (M0.8 E3): the `has T` archetype predicate
            // (component present) + a per-slot `changedTick(T) > __last_run`
            // guard emitted in the arch walk. Forces the arch-walk path (it
            // needs `arch`/`chunk`/`slot` for `changedTick`).
            const cname = ast.strings.slice(node.type_name);
            const gop = try seen.getOrPut(gpa, cname);
            if (!gop.found_existing) try components.append(gpa, cname);
            has_component_ref.* = true;
            try changed.append(gpa, cname);
        },
        .resource => {
            const rname = ast.strings.slice(node.type_name);
            try res_deps.append(gpa, .{ .name = rname, .must_be_changed = false });
        },
        .resource_changed => {
            const rname = ast.strings.slice(node.type_name);
            try res_deps.append(gpa, .{ .name = rname, .must_be_changed = true });
        },
        // A positive tag filter makes the rule entity-bound and requires the
        // entity to carry `TagSet` — add it to the components so the id +
        // `arch.hasComponent(TagSet_id)` predicate + per-slot `_arr` are
        // emitted. A negative tag op (`has_no_tag`/`has_no_tags`) also matches
        // entities lacking `TagSet`, so its arch-walk codegen is deferred —
        // fail loud, the interpreter is the reference (M0.8 E3).
        .tag_filter => {
            const tf = ast.tag_filters.items[node.aux];
            switch (tf.op) {
                .has_tag, .has_any_tag, .has_all_tags => {
                    const gop = try seen.getOrPut(gpa, "TagSet");
                    if (!gop.found_existing) try components.append(gpa, "TagSet");
                    has_component_ref.* = true;
                },
                .has_no_tag, .has_no_tags => return CodegenError.UnsupportedConstruct,
            }
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
        .has, .has_with_filter, .has_changed => {
            const cname = ast.strings.slice(node.type_name);
            const gop = try seen.getOrPut(gpa, cname);
            if (!gop.found_existing) try components.append(gpa, cname);
        },
        .resource, .resource_changed => {},
        // A positive tag filter contributes `TagSet` to the archetype
        // signature (the rule matches archetypes carrying it); a negative tag
        // op's codegen is deferred and already failed loud upstream (M0.8 E3).
        .tag_filter => {
            const tf = ast.tag_filters.items[node.aux];
            switch (tf.op) {
                .has_tag, .has_any_tag, .has_all_tags => {
                    const gop = try seen.getOrPut(gpa, "TagSet");
                    if (!gop.found_existing) try components.append(gpa, "TagSet");
                },
                .has_no_tag, .has_no_tags => return CodegenError.UnsupportedConstruct,
            }
        },
    }
}

fn lexLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ─── Tag codegen helpers (M0.8 E3) ──────────────────────────────────────────

/// Resolve a `tag_path` mutation operand to its leaf bit via the global table
/// — the codegen analogue of the interpreter's `tagPathLeafBit`. Returns null
/// for an unknown path or a namespace (the resolver rejects those; a null here
/// is an inconsistent program → the caller fails loud).
fn tagPathLeafBitCodegen(ast: *const AstArena, tag_table: *const tags_mod.TagTable, path_node: NodeId) ?u32 {
    const tp = ast.tag_paths.items[ast.exprData(path_node)];
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var i: u32 = 0;
    while (i < tp.segs_len) : (i += 1) {
        const seg = ast.strings.slice(ast.tag_path_segs.items[tp.segs_start + i]);
        const need = seg.len + @as(usize, if (i > 0) 1 else 0);
        if (len + need > buf.len) return null;
        if (i > 0) {
            buf[len] = '.';
            len += 1;
        }
        @memcpy(buf[len .. len + seg.len], seg);
        len += seg.len;
    }
    return tag_table.leafBit(buf[0..len]);
}

/// Resolve one tag-filter operand path to its leaf bit(s), appending to `out`:
/// a leaf path contributes its single bit; a namespace path expands to the
/// bits of every leaf under it. Mirrors the interpreter's
/// `resolveTagOperandBits` (M0.8 E3).
fn resolveTagOperandBitsCodegen(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    tag_table: *const tags_mod.TagTable,
    path_node: NodeId,
    out: *std.ArrayListUnmanaged(u32),
) CodegenError!void {
    const tp = ast.tag_paths.items[ast.exprData(path_node)];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < tp.segs_len) : (i += 1) {
        if (i > 0) try buf.append(gpa, '.');
        try buf.appendSlice(gpa, ast.strings.slice(ast.tag_path_segs.items[tp.segs_start + i]));
    }
    if (tag_table.leafBit(buf.items)) |bit| {
        try out.append(gpa, bit);
    } else if (tag_table.lookup(buf.items)) |entry| {
        if (entry.is_leaf) return CodegenError.UnsupportedConstruct;
        try tag_table.collectUnder(gpa, buf.items, out);
    } else return CodegenError.UnsupportedConstruct;
}

/// Walk the when clause and resolve every positive tag filter's operand bits
/// into `out` (M0.8 E3). Negative tag ops already failed loud in `walkWhen`.
fn collectTagFilters(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    tag_table: *const tags_mod.TagTable,
    when_idx: u32,
    out: *std.ArrayListUnmanaged(TagFilterInfo),
) CodegenError!void {
    const node = ast.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and, .logical_or => {
            try collectTagFilters(gpa, ast, tag_table, node.lhs, out);
            try collectTagFilters(gpa, ast, tag_table, node.rhs, out);
        },
        .logical_not => try collectTagFilters(gpa, ast, tag_table, node.lhs, out),
        .tag_filter => {
            const tf = ast.tag_filters.items[node.aux];
            var bits: std.ArrayListUnmanaged(u32) = .empty;
            errdefer bits.deinit(gpa);
            var oi: u32 = 0;
            while (oi < tf.operand_len) : (oi += 1) {
                const path_node = ast.tag_operands.items[tf.operand_start + oi];
                try resolveTagOperandBitsCodegen(gpa, ast, tag_table, path_node, &bits);
            }
            try out.append(gpa, .{ .op = tf.op, .bits = try bits.toOwnedSlice(gpa) });
        },
        else => {},
    }
}

/// Emit a per-slot `continue` guard for a positive tag filter, byte-exact with
/// the interpreter's `tagPredicatesPass` (M0.8 E3): `has_tag`/`has_all_tags`
/// skip unless every operand bit is set; `has_any_tag` skips unless at least
/// one is set. Bits are grouped into per-word masks read from `TagSet_arr[slot]`.
fn emitTagFilterGuard(w: *Writer, tf: TagFilterInfo) CodegenError!void {
    const WordMask = struct { word: u32, mask: u64 };
    var entries: std.ArrayListUnmanaged(WordMask) = .empty;
    defer entries.deinit(w.gpa);
    for (tf.bits) |b| {
        const word = b / 64;
        const m = @as(u64, 1) << @intCast(b % 64);
        var found = false;
        for (entries.items) |*e| {
            if (e.word == word) {
                e.mask |= m;
                found = true;
                break;
            }
        }
        if (!found) try entries.append(w.gpa, .{ .word = word, .mask = m });
    }
    switch (tf.op) {
        .has_tag, .has_all_tags => {
            // Every listed bit must be set.
            for (entries.items) |e| {
                try w.printLine("if ((TagSet_arr[slot].bits[{d}] & 0x{x}) != 0x{x}) continue;", .{ e.word, e.mask, e.mask });
            }
        },
        .has_any_tag => {
            // At least one listed bit set → skip when none are set.
            try w.writeIndent();
            try w.write("if (");
            for (entries.items, 0..) |e, idx| {
                if (idx > 0) try w.write(" and ");
                try w.print("(TagSet_arr[slot].bits[{d}] & 0x{x}) == 0", .{ e.word, e.mask });
            }
            try w.write(") continue;\n");
        },
        .has_no_tag, .has_no_tags => return CodegenError.UnsupportedConstruct,
    }
}

// Dedicated lowering tests live under `src/etch/zig_codegen/tests/lower_test.zig`.
// They are pulled into the import graph by `zig_codegen/root.zig` and run as
// part of `zig build test`.
