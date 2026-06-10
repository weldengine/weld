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
        // The synthetic builtin `Error` / `ErrorCode` items (M0.8 E3-C
        // tranche 2) are skipped — their string / enum / optional fields do
        // not fit the POD declaration emitters; the canonical prelude below
        // is their codegen image.
        if (i >= ast.builtin_items_from) continue;
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

    // Builtin `Error` / `ErrorCode` prelude (M0.8 E3-C tranche 2, part1
    // §10.2) — the codegen image of the synthetic declarations skipped in
    // pass A. Emitted only when the program touches error handling, so an
    // error-free program keeps byte-identical output. `Error` is a plain
    // (non-extern) struct: a `[]const u8` slice field is not extern-
    // compatible. The field defaults exist for Zig's literal completeness;
    // the resolver requires `message` + `code` on every `Error` literal, so
    // only `source = null` (the omittable chaining field) is observable.
    if (programUsesError(ast)) {
        try emitErrorPrelude(&w);
    }

    // Map-insert + map-get helpers (M0.8 E3-C tranches 3-4) — emitted iff the
    // program has a map literal (the only source of a map value in the M0.8
    // subset). An unused private fn is legal Zig, so over-emitting on a
    // program that only inserts (or only reads) is harmless; map-free
    // programs stay byte-identical.
    if (ast.map_lits.items.len > 0) {
        try emitMapInsertPrelude(&w);
        try emitMapGetPrelude(&w);
    }

    // Set-insert + set-contains helpers (M0.8 E3-C tranche 3bis) — emitted
    // iff the program makes a `Set.*` associated call (sets have NO literal,
    // part1 §3.3 — the constructors are the only source of a set value).
    // Same over-emission tolerance as the map helpers; set-free programs
    // stay byte-identical.
    if (programUsesSet(ast)) {
        try emitSetInsertPrelude(&w);
        try emitSetContainsPrelude(&w);
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
        // Emission first: the two-pass arena classification (M0.8 E3-C
        // tranche 1b) is a property of the emitted body, so the RuleEmit
        // entry consumed by `tick` is appended after it is known.
        const needs_arena = if (on_event != null)
            try emitObserverRule(&w, ast, rule, &tag_table)
        else
            try emitRule(&w, ast, rule, &tag_table, program_has_changed);
        try rule_emits.append(gpa, .{
            .name = name_slice,
            .tag_mutating = ruleHasTagMutation(ast, rule),
            .event_type = event_type,
            .needs_arena = needs_arena,
        });
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

// ─── Builtin Error / ErrorCode (M0.8 E3-C tranche 2) ─────────────────────

/// The canonical Zig shape of the builtin `Error` struct + `ErrorCode` enum
/// (part1 §10.2). `Error` is a plain struct (a `[]const u8` slice field is
/// not extern-compatible); `source` is `?*const Error` — a struct cannot
/// contain itself by value. Field defaults satisfy Zig literal completeness:
/// the resolver requires `message` + `code` on every `Error` literal, so only
/// `source = null` (the omittable chaining field, tranche 4) is observable.
fn emitErrorPrelude(w: *Writer) CodegenError!void {
    try w.line("pub const ErrorCode = enum(i32) {");
    w.indentBy(1);
    try w.line("io_fail,");
    try w.line("network_timeout,");
    try w.line("invalid_arg,");
    try w.line("permission_denied,");
    try w.line("out_of_memory,");
    w.indentBy(-1);
    try w.line("};");
    try w.blankLine();
    try w.line("pub const Error = struct {");
    w.indentBy(1);
    try w.line("message: []const u8 = \"\",");
    try w.line("code: ErrorCode = .io_fail,");
    try w.line("source: ?*const Error = null,");
    w.indentBy(-1);
    try w.line("};");
    try w.blankLine();
}

/// Emit the map-insert helper (M0.8 E3-C tranche 3, stdlib §14.2): one
/// duck-typed fn shared by `m.insert(k, v)`, the map-literal seeding, and
/// nothing else. Last-write-wins through the same scan-replace-or-append as
/// the interpreter's map store — byte-exact iteration order by construction.
/// `m` is a `*std.ArrayListUnmanaged(struct { key: K, value: V })`; `==` on
/// the key bounds K to the scalar key types the emitter's type table allows.
/// Gated on the program containing a map literal (the only way a map value
/// exists in the M0.8 subset), so map-free programs stay byte-identical.
fn emitMapInsertPrelude(w: *Writer) CodegenError!void {
    try w.line("fn __etchMapInsert(m: anytype, fa: std.mem.Allocator, k: anytype, v: anytype) void {");
    w.indentBy(1);
    try w.line("for (m.items) |*p| {");
    w.indentBy(1);
    try w.line("if (p.key == k) {");
    w.indentBy(1);
    try w.line("p.value = v;");
    try w.line("return;");
    w.indentBy(-1);
    try w.line("}");
    w.indentBy(-1);
    try w.line("}");
    try w.line("m.append(fa, .{ .key = k, .value = v }) catch unreachable;");
    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

/// Emit the map-get helper (M0.8 E3-C tranche 4, stdlib §14.2 `m[k] -> V?`):
/// the same insertion-ordered scan as `__etchMapInsert` (and the
/// interpreter's map store) returning the value or `null`. Same gate as the
/// insert helper (a map literal in the program).
fn emitMapGetPrelude(w: *Writer) CodegenError!void {
    try w.line("fn __etchMapGet(m: anytype, k: anytype) ?@FieldType(std.meta.Child(@TypeOf(m.items)), \"value\") {");
    w.indentBy(1);
    try w.line("for (m.items) |p| {");
    w.indentBy(1);
    try w.line("if (p.key == k) return p.value;");
    w.indentBy(-1);
    try w.line("}");
    try w.line("return null;");
    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

/// Emit the set-insert helper (M0.8 E3-C tranche 3bis, stdlib §15.2): one
/// duck-typed fn shared by `s.insert(item)` and the `Set.from` seeding —
/// scan-skip-or-append, the exact mechanics of the interpreter's set store,
/// so element order is byte-exact by construction. `s` is a
/// `*std.ArrayListUnmanaged(struct { item: T })`; `==` on the element bounds
/// T to the scalar types the emitter's set table allows. Gated on the
/// program containing a `Set.*` associated call (the only source of a set
/// value in the M0.8 subset — sets have no literal).
fn emitSetInsertPrelude(w: *Writer) CodegenError!void {
    try w.line("fn __etchSetInsert(s: anytype, fa: std.mem.Allocator, item: anytype) void {");
    w.indentBy(1);
    try w.line("for (s.items) |p| {");
    w.indentBy(1);
    try w.line("if (p.item == item) return;");
    w.indentBy(-1);
    try w.line("}");
    try w.line("s.append(fa, .{ .item = item }) catch unreachable;");
    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

/// Emit the set-contains helper (M0.8 E3-C tranche 3bis, stdlib §15.2): the
/// same insertion-ordered scan as `__etchSetInsert` (and the interpreter's
/// set store) returning whether the element is present. Same gate as the
/// insert helper.
fn emitSetContainsPrelude(w: *Writer) CodegenError!void {
    try w.line("fn __etchSetContains(s: anytype, item: anytype) bool {");
    w.indentBy(1);
    try w.line("for (s.items) |p| {");
    w.indentBy(1);
    try w.line("if (p.item == item) return true;");
    w.indentBy(-1);
    try w.line("}");
    try w.line("return false;");
    w.indentBy(-1);
    try w.line("}");
    try w.blankLine();
}

/// Whether the program references the builtin error machinery, so the
/// `Error`/`ErrorCode` prelude must be emitted (M0.8 E3-C tranche 2). Scans:
/// the throw / try-catch slabs, `throws` markers on fns and methods, `Error`
/// struct literals, qualified `Error`/`ErrorCode` paths (`ErrorCode.io_fail`),
/// and source-declared field / param type references. Synthetic entries
/// appended by `ensureErrorBuiltins` are excluded via the arena's
/// `builtin_fields_from` mark — they reference the types by construction.
/// A missed exotic reference fails loud in `zig build` (undeclared
/// identifier), never silently.
fn programUsesError(ast: *const AstArena) bool {
    if (ast.throw_stmts.items.len > 0 or ast.try_catch_stmts.items.len > 0) return true;
    for (ast.fn_decls.items) |d| {
        if (d.throws) return true;
    }
    for (ast.impl_methods.items) |m| {
        if (m.throws) return true;
    }
    const err_id = ast.strings.find("Error");
    const code_id = ast.strings.find("ErrorCode");
    if (err_id == null and code_id == null) return false;
    for (ast.struct_lits.items) |sl| {
        if (isErrorName(sl.type_name, err_id, code_id)) return true;
    }
    var e: usize = 0;
    while (e < ast.exprs.len) : (e += 1) {
        if (ast.exprs.items(.kind)[e] != .path) continue;
        if (isErrorName(ast.exprs.items(.data)[e], err_id, code_id)) return true;
    }
    const fields_end = @min(ast.fields.items.len, ast.builtin_fields_from);
    for (ast.fields.items[0..fields_end]) |f| {
        if (typeNodeNamesError(ast, f.type_node, err_id, code_id)) return true;
    }
    for (ast.fn_params.items) |p| {
        if (typeNodeNamesError(ast, p.type_node, err_id, code_id)) return true;
    }
    return false;
}

fn isErrorName(name: StringId, err_id: ?StringId, code_id: ?StringId) bool {
    if (err_id) |id| {
        if (name == id) return true;
    }
    if (code_id) |id| {
        if (name == id) return true;
    }
    return false;
}

/// `true` if a type node names `Error`/`ErrorCode` directly or as an
/// optional payload (`Error?`).
fn typeNodeNamesError(ast: *const AstArena, type_node: NodeId, err_id: ?StringId, code_id: ?StringId) bool {
    switch (ast.typeNodeKind(type_node)) {
        .named => {
            const named = ast.named_types.items[ast.typeNodeData(type_node)];
            return isErrorName(ast.resolveTypeAliasName(named.name), err_id, code_id);
        },
        .optional => {
            const payload: NodeId = @bitCast(ast.typeNodeData(type_node));
            return typeNodeNamesError(ast, payload, err_id, code_id);
        },
        else => return false,
    }
}

/// Whether the program creates any set value, so the `__etchSet*` prelude
/// helpers must be emitted (M0.8 E3-C tranche 3bis). Sets have NO literal
/// (part1 §3.3) — the only entry is a `Set.new`/`Set.from` associated call,
/// so the scan is over method calls with a `.path` receiver named `Set`.
fn programUsesSet(ast: *const AstArena) bool {
    const set_id = ast.strings.find("Set") orelse return false;
    for (ast.method_calls.items) |mc| {
        if (ast.exprKind(mc.receiver) == .path and ast.exprData(mc.receiver) == set_id) return true;
    }
    return false;
}

/// The `Set.new`/`Set.from` associated-call shape of an expression, or `null`
/// when it is not a `Set.*` call (M0.8 E3-C tranche 3bis). Drives the
/// set-local route of `emitLet`; an out-of-shape `Set.*` call
/// (`with_capacity`, wrong arity) was already resolver-rejected.
const SetCall = union(enum) { new, from: NodeId };

fn setCallOf(ast: *const AstArena, value: NodeId) ?SetCall {
    if (ast.exprKind(value) != .method_call) return null;
    const mc = ast.method_calls.items[ast.exprData(value)];
    if (ast.exprKind(mc.receiver) != .path) return null;
    if (!std.mem.eql(u8, ast.strings.slice(ast.exprData(mc.receiver)), "Set")) return null;
    const mname = ast.strings.slice(mc.method_name);
    if (std.mem.eql(u8, mname, "new") and mc.args_len == 0) return .new;
    if (std.mem.eql(u8, mname, "from") and mc.args_len == 1) return .{ .from = @bitCast(ast.extra.items[mc.args_start]) };
    return null;
}

/// The top-level `fn` declaration named `name`, or `null` (M0.8 E3-C
/// tranche 2 — `throws` call-site detection).
fn findFnDecl(ast: *const AstArena, name: StringId) ?ast_mod.FnDecl {
    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .fn_decl) continue;
        const d = ast.fn_decls.items[ast.items.items(.data)[i]];
        if (d.name == name) return d;
    }
    return null;
}

/// The `throws` callee declaration of a free-fn call, or `null` when the
/// callee is a local (closure) or a non-`throws` fn (M0.8 E3-C tranche 2).
fn throwsCalleeDecl(ast: *const AstArena, ctx: *const LocalCtx, call: ast_mod.CallExpr) ?ast_mod.FnDecl {
    if (ast.exprKind(call.callee) != .ident) return null;
    const name: StringId = ast.exprData(call.callee);
    if (ctx.lookup(name) != null) return null;
    const decl = findFnDecl(ast, name) orelse return null;
    return if (decl.throws) decl else null;
}

/// The closure expression of a call whose callee is a closure-typed local
/// with a THROWING body, or `null` (M0.8 E3-C tranche 6). The closure image
/// of `throwsCalleeDecl`: such a closure's `call` fn carries its own hidden
/// `__err` out-param, and the sanctioned call site re-raises at this level
/// — the boundary where the interpreter's `thrown` crosses the closure
/// call (`returning` does not; it is consumed inside the closure fn).
fn throwingClosureCallee(ast: *const AstArena, ctx: *const LocalCtx, call: ast_mod.CallExpr) ?ast_mod.ClosureExpr {
    if (ast.exprKind(call.callee) != .ident) return null;
    const local = ctx.lookup(ast.exprData(call.callee)) orelse return null;
    if (local.closure_node.isNone()) return null;
    const ce = ast.closure_exprs.items[ast.exprData(local.closure_node)];
    return if (exprCanThrow(ast, ce.body)) ce else null;
}

/// Whether a statement run can raise the throw signal at THIS level (M0.8
/// E3-C tranche 2): a reachable `throw`, or a call of a `throws` fn. Drives
/// (a) the try/catch plumbing elision — a throw-free try body emits inline,
/// since Zig rejects the never-mutated `var __thrown_N` and the catch body
/// is unreachable per the interpreter's semantics — and (b) the `_ = __err;`
/// discard in a `throws` fn that never throws (W0901-shaped). Throws inside
/// a NESTED try body are consumed by its own catch and do not count; its
/// catch body propagates outward, so it does. The scan over-approximates on
/// call positions the emitters reject (`UnsupportedConstruct`) — safe, the
/// program is rejected before Zig sees it; a missed exotic form surfaces as
/// a loud Zig compile error (undeclared label / never-mutated var), never a
/// silent divergence.
fn stmtRunCanThrow(ast: *const AstArena, start: u32, len: u32) bool {
    var s: u32 = 0;
    while (s < len) : (s += 1) {
        if (stmtCanThrow(ast, @bitCast(ast.extra.items[start + s]))) return true;
    }
    return false;
}

fn stmtCanThrow(ast: *const AstArena, stmt_id: NodeId) bool {
    const data = ast.stmtData(stmt_id);
    switch (ast.stmtKind(stmt_id)) {
        .throw_stmt => return true,
        .try_catch_stmt => {
            const tc = ast.try_catch_stmts.items[data];
            return stmtRunCanThrow(ast, tc.catch_start, tc.catch_len);
        },
        .let_stmt => return exprCanThrow(ast, ast.let_stmts.items[data].value),
        .assign_stmt => {
            const a = ast.assign_stmts.items[data];
            return exprCanThrow(ast, a.target) or exprCanThrow(ast, a.value);
        },
        .expr_stmt => return exprCanThrow(ast, @bitCast(data)),
        .assert_stmt => return exprCanThrow(ast, ast.assert_stmts.items[data].cond),
        .return_stmt => {
            const value: NodeId = @bitCast(data);
            return !value.isNone() and exprCanThrow(ast, value);
        },
        .for_stmt => {
            const f = ast.for_stmts.items[data];
            return exprCanThrow(ast, f.iterable) or stmtRunCanThrow(ast, f.body_start, f.body_len);
        },
        .while_stmt => {
            const wh = ast.while_stmts.items[data];
            return exprCanThrow(ast, wh.cond) or stmtRunCanThrow(ast, wh.body_start, wh.body_len);
        },
        .break_stmt => {
            const b = ast.break_stmts.items[data];
            return !b.value.isNone() and exprCanThrow(ast, b.value);
        },
        .emit_stmt => {
            const em = ast.emit_stmts.items[data];
            var i: u32 = 0;
            while (i < em.fields_len) : (i += 1) {
                if (exprCanThrow(ast, ast.struct_lit_fields.items[em.fields_start + i].value)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn exprCanThrow(ast: *const AstArena, expr: NodeId) bool {
    const data = ast.exprData(expr);
    switch (ast.exprKind(expr)) {
        .fn_call => {
            const call = ast.call_exprs.items[data];
            if (ast.exprKind(call.callee) == .ident) {
                // A local of the same name shadows the fn; the emitters
                // resolve that through `ctx`, the scan over-approximates
                // (a shadowed throws-fn name is exotic and fails loud).
                if (findFnDecl(ast, ast.exprData(call.callee))) |d| {
                    if (d.throws) return true;
                }
            }
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (exprCanThrow(ast, @bitCast(ast.extra.items[call.args_start + i]))) return true;
            }
            return false;
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            return exprCanThrow(ast, b.lhs) or exprCanThrow(ast, b.rhs);
        },
        .unary => return exprCanThrow(ast, ast.unary_exprs.items[data].operand),
        .cast => return exprCanThrow(ast, ast.casts.items[data].operand),
        .field_access => return exprCanThrow(ast, ast.field_accesses.items[data].receiver),
        .index => {
            const ix = ast.index_exprs.items[data];
            return exprCanThrow(ast, ix.receiver) or exprCanThrow(ast, ix.index);
        },
        .range => {
            const r = ast.ranges.items[data];
            return exprCanThrow(ast, r.start) or exprCanThrow(ast, r.end);
        },
        .method_call => {
            const mc = ast.method_calls.items[data];
            if (ast.exprKind(mc.receiver) != .path and exprCanThrow(ast, mc.receiver)) return true;
            var i: u32 = 0;
            while (i < mc.args_len) : (i += 1) {
                if (exprCanThrow(ast, @bitCast(ast.extra.items[mc.args_start + i]))) return true;
            }
            return false;
        },
        .struct_lit => {
            const sl = ast.struct_lits.items[data];
            var i: u32 = 0;
            while (i < sl.fields_len) : (i += 1) {
                if (exprCanThrow(ast, ast.struct_lit_fields.items[sl.fields_start + i].value)) return true;
            }
            return false;
        },
        .array_lit => {
            const al = ast.array_lits.items[data];
            var i: u32 = 0;
            while (i < al.elements_len) : (i += 1) {
                if (exprCanThrow(ast, @bitCast(ast.extra.items[al.elements_start + i]))) return true;
            }
            return al.is_fill and exprCanThrow(ast, al.fill_count);
        },
        .block_expr => {
            const blk = ast.block_exprs.items[data];
            if (stmtRunCanThrow(ast, blk.body_start, blk.body_len)) return true;
            return !blk.value.isNone() and exprCanThrow(ast, blk.value);
        },
        .if_expr => {
            const ife = ast.if_exprs.items[data];
            if (exprCanThrow(ast, ife.cond)) return true;
            if (exprCanThrow(ast, ife.then_block)) return true;
            return !ife.else_branch.isNone() and exprCanThrow(ast, ife.else_branch);
        },
        .match_expr => {
            const m = ast.match_exprs.items[data];
            if (exprCanThrow(ast, m.scrutinee)) return true;
            var i: u32 = 0;
            while (i < m.arms_len) : (i += 1) {
                if (exprCanThrow(ast, ast.match_arms.items[m.arms_start + i].body)) return true;
            }
            return false;
        },
        .loop_expr => {
            const lp = ast.loop_exprs.items[data];
            return stmtRunCanThrow(ast, lp.body_start, lp.body_len);
        },
        .closure => {
            // A throwing-body closure marks the run can-throw at CREATION
            // (M0.8 E3-C tranche 6) — over-approximate on purpose: creating
            // never throws, but the sanctioned call site (a let in the same
            // try body) re-raises into the enclosing try, so the plumbing is
            // genuinely mutated. A created-but-never-called throwing closure
            // is the documented exotic-miss family (loud `zig build` error,
            // never a silent divergence).
            const ce = ast.closure_exprs.items[data];
            return exprCanThrow(ast, ce.body);
        },
        .string_interp => {
            const si = ast.string_interps.items[data];
            var i: u32 = 0;
            while (i < si.n_exprs) : (i += 1) {
                if (exprCanThrow(ast, @bitCast(ast.extra.items[si.exprs_start + i]))) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Whether a statement run references identifier `name` (M0.8 E3-C tranche
/// 2) — drives the `_ = <name>;` discard for an unused catch binding (Zig
/// rejects unused captures). An inner rebinding of the same name counts as
/// a use (over-approximation): the discard is then skipped and Zig fails
/// loud on the unused outer capture — an exotic shadowing shape, never a
/// silent divergence.
fn stmtRunUsesIdent(ast: *const AstArena, name: StringId, start: u32, len: u32) bool {
    var s: u32 = 0;
    while (s < len) : (s += 1) {
        if (stmtUsesIdent(ast, name, @bitCast(ast.extra.items[start + s]))) return true;
    }
    return false;
}

fn stmtUsesIdent(ast: *const AstArena, name: StringId, stmt_id: NodeId) bool {
    const data = ast.stmtData(stmt_id);
    switch (ast.stmtKind(stmt_id)) {
        .throw_stmt => return exprUsesIdent(ast, name, ast.throw_stmts.items[data].value),
        .try_catch_stmt => {
            const tc = ast.try_catch_stmts.items[data];
            return stmtRunUsesIdent(ast, name, tc.try_start, tc.try_len) or
                stmtRunUsesIdent(ast, name, tc.catch_start, tc.catch_len);
        },
        .let_stmt => return exprUsesIdent(ast, name, ast.let_stmts.items[data].value),
        .assign_stmt => {
            const a = ast.assign_stmts.items[data];
            return exprUsesIdent(ast, name, a.target) or exprUsesIdent(ast, name, a.value);
        },
        .expr_stmt => return exprUsesIdent(ast, name, @bitCast(data)),
        .assert_stmt => return exprUsesIdent(ast, name, ast.assert_stmts.items[data].cond),
        .return_stmt => {
            const value: NodeId = @bitCast(data);
            return !value.isNone() and exprUsesIdent(ast, name, value);
        },
        .for_stmt => {
            const f = ast.for_stmts.items[data];
            return exprUsesIdent(ast, name, f.iterable) or stmtRunUsesIdent(ast, name, f.body_start, f.body_len);
        },
        .while_stmt => {
            const wh = ast.while_stmts.items[data];
            return exprUsesIdent(ast, name, wh.cond) or stmtRunUsesIdent(ast, name, wh.body_start, wh.body_len);
        },
        .break_stmt => {
            const b = ast.break_stmts.items[data];
            return !b.value.isNone() and exprUsesIdent(ast, name, b.value);
        },
        .emit_stmt => {
            const em = ast.emit_stmts.items[data];
            var i: u32 = 0;
            while (i < em.fields_len) : (i += 1) {
                if (exprUsesIdent(ast, name, ast.struct_lit_fields.items[em.fields_start + i].value)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn exprUsesIdent(ast: *const AstArena, name: StringId, expr: NodeId) bool {
    const data = ast.exprData(expr);
    switch (ast.exprKind(expr)) {
        .ident => return data == name,
        .fn_call => {
            const call = ast.call_exprs.items[data];
            if (exprUsesIdent(ast, name, call.callee)) return true;
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (exprUsesIdent(ast, name, @bitCast(ast.extra.items[call.args_start + i]))) return true;
            }
            return false;
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            return exprUsesIdent(ast, name, b.lhs) or exprUsesIdent(ast, name, b.rhs);
        },
        .unary => return exprUsesIdent(ast, name, ast.unary_exprs.items[data].operand),
        .cast => return exprUsesIdent(ast, name, ast.casts.items[data].operand),
        .field_access => return exprUsesIdent(ast, name, ast.field_accesses.items[data].receiver),
        .index => {
            const ix = ast.index_exprs.items[data];
            return exprUsesIdent(ast, name, ix.receiver) or exprUsesIdent(ast, name, ix.index);
        },
        .range => {
            const r = ast.ranges.items[data];
            return exprUsesIdent(ast, name, r.start) or exprUsesIdent(ast, name, r.end);
        },
        .method_call => {
            const mc = ast.method_calls.items[data];
            if (ast.exprKind(mc.receiver) != .path and exprUsesIdent(ast, name, mc.receiver)) return true;
            var i: u32 = 0;
            while (i < mc.args_len) : (i += 1) {
                if (exprUsesIdent(ast, name, @bitCast(ast.extra.items[mc.args_start + i]))) return true;
            }
            return false;
        },
        .struct_lit => {
            const sl = ast.struct_lits.items[data];
            var i: u32 = 0;
            while (i < sl.fields_len) : (i += 1) {
                if (exprUsesIdent(ast, name, ast.struct_lit_fields.items[sl.fields_start + i].value)) return true;
            }
            return false;
        },
        .array_lit => {
            const al = ast.array_lits.items[data];
            var i: u32 = 0;
            while (i < al.elements_len) : (i += 1) {
                if (exprUsesIdent(ast, name, @bitCast(ast.extra.items[al.elements_start + i]))) return true;
            }
            return al.is_fill and exprUsesIdent(ast, name, al.fill_count);
        },
        .block_expr => {
            const blk = ast.block_exprs.items[data];
            if (stmtRunUsesIdent(ast, name, blk.body_start, blk.body_len)) return true;
            return !blk.value.isNone() and exprUsesIdent(ast, name, blk.value);
        },
        .if_expr => {
            const ife = ast.if_exprs.items[data];
            if (exprUsesIdent(ast, name, ife.cond)) return true;
            if (exprUsesIdent(ast, name, ife.then_block)) return true;
            return !ife.else_branch.isNone() and exprUsesIdent(ast, name, ife.else_branch);
        },
        .match_expr => {
            const m = ast.match_exprs.items[data];
            if (exprUsesIdent(ast, name, m.scrutinee)) return true;
            var i: u32 = 0;
            while (i < m.arms_len) : (i += 1) {
                if (exprUsesIdent(ast, name, ast.match_arms.items[m.arms_start + i].body)) return true;
            }
            return false;
        },
        .loop_expr => {
            const lp = ast.loop_exprs.items[data];
            return stmtRunUsesIdent(ast, name, lp.body_start, lp.body_len);
        },
        .string_interp => {
            const si = ast.string_interps.items[data];
            var i: u32 = 0;
            while (i < si.n_exprs) : (i += 1) {
                if (exprUsesIdent(ast, name, @bitCast(ast.extra.items[si.exprs_start + i]))) return true;
            }
            return false;
        },
        .closure => return exprUsesIdent(ast, name, ast.closure_exprs.items[data].body),
        .method_get, .method_get_mut => {
            const mg = ast.method_gets.items[data];
            return !mg.receiver.isNone() and exprUsesIdent(ast, name, mg.receiver);
        },
        else => return false,
    }
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
    // A `string` field (unlocked with the Error layer, M0.8 E3-C tranche 2)
    // lowers to `[]const u8` — not extern-compatible, so such a struct is a
    // plain Zig struct. String-free structs keep the extern layout.
    var has_string = false;
    var f_i: u32 = 0;
    while (f_i < decl.fields_len) : (f_i += 1) {
        const f = ast.fields.items[decl.fields_start + f_i];
        if (ast.typeNodeKind(f.type_node) != .named) continue;
        const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
        if (std.mem.eql(u8, ast.strings.slice(ast.resolveTypeAliasName(tnode.name)), "string")) has_string = true;
    }
    try w.printLine("pub const {s} = {s}struct {{", .{ name, if (has_string) "" else "extern " });
    w.indentBy(1);
    f_i = 0;
    while (f_i < decl.fields_len) : (f_i += 1) {
        const f = ast.fields.items[decl.fields_start + f_i];
        // Optional fields (`Error?`) have no codegen lowering yet — deferred
        // to the Optional-ops tranche (interpreter reference). The guard also
        // protects the `named_types` index below.
        if (ast.typeNodeKind(f.type_node) != .named) return CodegenError.UnsupportedConstruct;
        const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
        const resolved = ast.resolveTypeAliasName(tnode.name);
        const etch_type = ast.strings.slice(resolved);
        const fname = ast.strings.slice(f.name);
        // `string` field (M0.8 E3-C tranche 2): `[]const u8`, empty default;
        // a declared default is deferred (the const-eval path has no string
        // emission — interpreter reference).
        if (std.mem.eql(u8, etch_type, "string")) {
            if (!f.default_value.isNone()) return CodegenError.UnsupportedConstruct;
            try w.writeIndent();
            try w.ident(fname);
            try w.write(": []const u8 = \"\",\n");
            continue;
        }
        // Enum-typed field (M0.8 E3-C tranche 2): the enum maps 1:1; with no
        // declared default, the first variant (ordinal 0) fills omissions —
        // matching the prelude `Error.code` shape. A declared enum default
        // is deferred (no const-eval enum path — interpreter reference).
        if (isEnumName(ast, resolved)) {
            if (!f.default_value.isNone()) return CodegenError.UnsupportedConstruct;
            try w.writeIndent();
            try w.ident(fname);
            try w.print(": {s} = @enumFromInt(0),\n", .{etch_type});
            continue;
        }
        // Struct-typed field (M0.8 E3-C tranche 8, unlocked by the anonymous
        // `.{ … }` field-value context — part1 §5.5 nested POD structs).
        // `.{}` is a valid Zig default (every emitted struct field carries
        // one) but is never observed: the resolver requires literal provision
        // (E0208). A declared default is deferred (no const-eval struct path
        // — interpreter reference). A nested string-carrying struct is not
        // extern-compatible and fails loud at `zig build` of the cooked file.
        if (isStructName(ast, resolved)) {
            if (!f.default_value.isNone()) return CodegenError.UnsupportedConstruct;
            try w.writeIndent();
            try w.ident(fname);
            try w.print(": {s} = .{{}},\n", .{etch_type});
            continue;
        }
        const zig_type = type_map.mapBuiltin(etch_type) orelse return CodegenError.NonPodComponent;
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
/// A `self` (by-value) receiver lowers to `self: T`; a `mut self` receiver to
/// a pointer receiver `self: *T` (M0.8 E3-C tranche 5) — Zig auto-references
/// the caller's `var` binding at the call site (the resolver's E0220 gate
/// guarantees a mutable receiver), so the in-place mutation is visible to the
/// caller at the same logical point as the interpreter's shared `struct_ref`
/// handle. An associated fn (no self) lowers to a plain function. `async` /
/// `throws` methods stay deferred (E3 gate). The body is a value-block
/// (trailing expression → implicit `return`), shared with `emitFnDecl`'s
/// shape. Bare `self` in value position (returned / passed on) would be a
/// `*T` where the by-value shape has `T` — no M0.8 differential uses it;
/// such a program fails loud at `zig build` of the cooked file.
fn emitMethod(w: *Writer, ast: *const AstArena, struct_name: []const u8, method: ast_mod.FnDecl) CodegenError!void {
    if (method.generics_len > 0) return CodegenError.UnsupportedConstruct; // generic monomorphisation → Phase 2
    if (method.is_async) return CodegenError.UnsupportedConstruct; // async codegen → Phase 2
    if (method.throws) return CodegenError.UnsupportedConstruct; // throws codegen → E3 gate

    var ctx: LocalCtx = .{};
    defer ctx.deinit(w.gpa);

    try w.writeIndent();
    try w.write("pub fn ");
    try w.ident(ast.strings.slice(method.name));
    try w.write("(");
    var wrote_param = false;
    if (method.self_kind != .none) {
        // The LocalCtx record keys the pointee type for both receiver kinds:
        // the method-call routing only needs to fall through to the user
        // dispatch, and Zig auto-derefs `self.field` / `self.method()`
        // through the pointer.
        try w.print("self: {s}{s}", .{ if (method.self_kind == .by_mut) "*" else "", struct_name });
        wrote_param = true;
        if (ast.strings.find("self")) |sid| {
            try ctx.records.append(w.gpa, .{ .key = .{ .name = sid }, .info = .{ .kind = .value, .zig_type = struct_name, .is_mut = method.self_kind == .by_mut } });
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
    /// The rule fn allocates from the frame arena (M0.8 E3-C tranche 1b:
    /// string concat) and takes the conditional trailing
    /// `fa: std.mem.Allocator` param; `tick` mounts `__frame` on the threaded
    /// `gpa` and dispatches `__frame.allocator()`. Reported by the emission
    /// two-pass (`emitRule`/`emitObserverRule` return value).
    needs_arena: bool = false,
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
/// map through `type_map`. `async` codegen is Phase 2 and fails loud
/// (`UnsupportedConstruct`); the interpreter is its reference. A `throws` fn
/// (M0.8 E3-C tranche 2) gains a hidden trailing `__err: *?Error` out-param —
/// the codegen image of the interpreter's `thrown` signal crossing the
/// `callFn` boundary; an in-body throw stores through it and returns the
/// never-read zero default of the return type.
fn emitFnDecl(w: *Writer, ast: *const AstArena, decl: ast_mod.FnDecl) CodegenError!void {
    if (decl.generics_len > 0) return CodegenError.UnsupportedConstruct; // generic monomorphisation → Phase 2
    if (decl.is_async) return CodegenError.UnsupportedConstruct; // async codegen → Phase 2

    const ret_zig: []const u8 = if (decl.return_type.isNone()) "" else fnTypeZig(ast, decl.return_type);
    if (decl.throws and !decl.return_type.isNone()) {
        // The throwing path returns `zeroDefault(ret)` — only meaningful for
        // builtin-mapped scalars (checked on the ETCH type name; `fnTypeZig`
        // passes user names through 1:1). A `throws` fn returning a user
        // type is deferred (interpreter reference).
        const tnode = ast.named_types.items[ast.typeNodeData(decl.return_type)];
        const tname = ast.strings.slice(ast.resolveTypeAliasName(tnode.name));
        if (type_map.mapBuiltin(tname) == null) return CodegenError.UnsupportedConstruct;
    }

    var ctx: LocalCtx = .{};
    defer ctx.deinit(w.gpa);
    ctx.throws_fn = decl.throws;
    ctx.fn_ret_zig = ret_zig;

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
    if (decl.throws) {
        if (decl.params_len > 0) try w.write(", ");
        try w.write("__err: *?Error");
    }
    try w.write(") ");
    try w.write(if (decl.return_type.isNone()) "void" else ret_zig);
    try w.write(" {\n");
    w.indentBy(1);

    // A `throws` fn whose body cannot throw (W0901-shaped) never touches
    // `__err`; Zig rejects the unused param, so discard it. When the body CAN
    // throw, the emission mirrors the same scan and a use follows — the
    // discard would then be the rejected "pointless discard".
    if (decl.throws and !fnBodyCanThrow(ast, decl)) {
        try w.line("_ = __err;");
    }

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

/// Whether a `fn` body (statement run + trailing value expression) can raise
/// the throw signal (M0.8 E3-C tranche 2) — drives the `_ = __err;` discard
/// for a `throws` fn that never throws.
fn fnBodyCanThrow(ast: *const AstArena, decl: ast_mod.FnDecl) bool {
    if (stmtRunCanThrow(ast, decl.body_start, decl.body_len)) return true;
    return !decl.value.isNone() and exprCanThrow(ast, decl.value);
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
/// component `when` or tag filter on the observer) is deferred and fails loud
/// here; the interpreter is its reference. The body's receiver-less resource
/// write is codegen-sound since M0.8 E3-C tranche 7 (D-S3-resource-receiver
/// closed) — the byte-exact emit → observer → resource-write differential is
/// `60_event_observer_resource`.
/// Observer variant of the `emitRule` two-pass frame-arena classification
/// (M0.8 E3-C tranche 1b) — returns whether the fn takes the conditional
/// `fa` param. See `emitRule` for why the classification must be exact.
fn emitObserverRule(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable) CodegenError!bool {
    var scratch_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch_buf.deinit(w.gpa);
    var scratch = Writer.init(w.gpa, &scratch_buf);
    try emitObserverRuleInner(&scratch, ast, rule, tag_table, true);
    if (scratch.arena_used) {
        try w.write(scratch_buf.items);
        return true;
    }
    try emitObserverRuleInner(w, ast, rule, tag_table, false);
    return false;
}

fn emitObserverRuleInner(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable, needs_arena: bool) CodegenError!void {
    const name = ast.strings.slice(rule.name);
    const annot = ast.onEventAnnotation(rule) orelse return CodegenError.UnsupportedConstruct;
    const event_type = ast.onEventTypeName(annot) orelse return CodegenError.UnsupportedConstruct;
    const etype_name = ast.strings.slice(event_type);

    var info = try collectWhenInfo(w.gpa, ast, rule, tag_table);
    defer freeWhenInfo(w.gpa, &info);
    // Combined event+entity (an observer that also iterates entities via a
    // component `when`, or a per-entity tag filter) is out of M0.8 scope.
    if (info.has_component_ref or info.tag_filters.len > 0) return CodegenError.UnsupportedConstruct;

    // The conditional frame-arena param (M0.8 E3-C tranche 1b), appended last.
    const fa_param: []const u8 = if (needs_arena) ", fa: std.mem.Allocator" else "";
    try w.printLine("pub fn rule_{s}(world: *World, ev_cursor: *EventCursor{s}) void {{", .{ name, fa_param });
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

    var ctx: LocalCtx = .{ .tag_table = tag_table, .arena_param = if (needs_arena) "fa" else null };
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

/// Emit one Zig `fn` for an Etch rule, returning whether the fn takes the
/// conditional frame-arena param `fa` (M0.8 E3-C tranche 1b). Exact two-pass
/// classification: the fn is first emitted into a scratch buffer with the
/// arena available; iff that emission allocated (`Writer.arena_used` — string
/// concat today), the scratch text (whose signature already has `fa`) is
/// spliced into the output. Otherwise the fn is re-emitted without the arena
/// — identical text minus the param. Exactness matters: Zig rejects an unused
/// fn param AND a pointless discard, so an over- or under-approximating
/// body-walk would break the generated code on any divergence from the
/// emitter's own string-typing; flag-on-emission cannot diverge.
fn emitRule(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable, program_has_changed: bool) CodegenError!bool {
    var scratch_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch_buf.deinit(w.gpa);
    var scratch = Writer.init(w.gpa, &scratch_buf);
    try emitRuleInner(&scratch, ast, rule, tag_table, program_has_changed, true);
    if (scratch.arena_used) {
        try w.write(scratch_buf.items);
        return true;
    }
    try emitRuleInner(w, ast, rule, tag_table, program_has_changed, false);
    return false;
}

fn emitRuleInner(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, tag_table: *const tags_mod.TagTable, program_has_changed: bool, needs_arena: bool) CodegenError!void {
    // `async rule` (M0.8 E3 sub-slice B) lowers to a suspend/resume state
    // machine — HIR-dependent, Phase 2. The interpreter is the reference; the
    // codegen rejects it loudly (consistent with `async fn` at l.689).
    if (rule.is_async) return CodegenError.UnsupportedConstruct;

    const name = ast.strings.slice(rule.name);
    // The conditional frame-arena param (M0.8 E3-C tranche 1b) — appended
    // last, after the `*CommandBuffer` / `*EventCursor` conditional params.
    const fa_param: []const u8 = if (needs_arena) ", fa: std.mem.Allocator" else "";
    const arena: ?[]const u8 = if (needs_arena) "fa" else null;

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
        try w.printLine("pub fn rule_{s}(world: *World, cmd: *CommandBuffer{s}) void {{", .{ name, fa_param });
    } else {
        try w.printLine("pub fn rule_{s}(world: *World{s}) void {{", .{ name, fa_param });
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
        try emitRuleBodyOnce(w, ast, rule, arena);
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
        try emitRuleAsArchWalk(w, ast, rule, info, &body_used, tag_mutating, tag_table, program_has_changed, arena);
    } else {
        // Path 1 — comptime query. The cooked code emits one
        // `comptime_query.query(world, .{T1, T2, ...})` invocation per
        // rule signature; Zig comptime monomorphises one iterator type
        // per distinct tuple.
        try emitRuleAsComptimeQuery(w, ast, rule, info, &body_used, arena);
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
fn emitRuleAsComptimeQuery(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, body_used: *const std.StringHashMapUnmanaged(void), arena: ?[]const u8) CodegenError!void {
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

    // A body that addresses no component slot (M0.8 E3-C tranche 7: an
    // entity-bound rule whose body only touches resources) emits no
    // `__row[...]` — discard the capture, Zig rejects an unused one. The
    // field filter addresses `__row` directly and is folded into
    // `body_used` by the caller.
    const row_capture: []const u8 = if (body_used.count() == 0 and info.field_filter == null) "_" else "__row";
    try w.printLine("while (__it.next()) |{s}| {{", .{row_capture});
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

    try emitRuleBodyQuery(w, ast, rule, info, arena);

    w.indentBy(-1);
    try w.line("}"); // while it.next()
}

/// Emit the body of a rule using the manual archetype-walk fallback for
/// when clauses containing `or` / `not`. Same shape as the pre-rewrite
/// codegen — kept until the inherited S4 debts (`not` / `or` predicates)
/// are addressed in Phase 0.2.
fn emitRuleAsArchWalk(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, body_used: *const std.StringHashMapUnmanaged(void), tag_mutating: bool, tag_table: *const tags_mod.TagTable, program_has_changed: bool, arena: ?[]const u8) CodegenError!void {
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
    try emitRuleBody(w, ast, rule, info, tag_table, program_has_changed, arena);
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

/// Emit the read-position lowering of a receiver-less resource access (M0.8
/// E3-C tranche 7): a `*const R` formed over the resource-store bytes through
/// `getResource` — no dirty, the interpreter's `readResourceField` route. The
/// buffer is chunk-aligned (Option A) so `@alignCast` is sound in ReleaseSafe;
/// `<R>_id` is the rule fn's resource-gate local.
fn emitResourceConstPtr(w: *Writer, rname: []const u8) CodegenError!void {
    try w.print("@as(*const {s}, @ptrCast(@alignCast(world.resources.getResource({s}_id).?.ptr)))", .{ rname, rname });
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
fn emitRuleBodyOnce(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, arena: ?[]const u8) CodegenError!void {
    // No component_ref → still need a (degenerate) LocalCtx for any
    // non-component locals the body might declare.
    var ctx: LocalCtx = .{ .arena_param = arena };
    defer ctx.deinit(w.gpa);
    try ctx.recordParams(w.gpa, ast, rule);
    var s: u32 = 0;
    while (s < rule.body_len) : (s += 1) {
        const stmt_raw = ast.extra.items[rule.body_start + s];
        const stmt_id: NodeId = @bitCast(stmt_raw);
        try emitStmt(w, ast, &ctx, stmt_id);
    }
}

fn emitRuleBody(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, tag_table: *const tags_mod.TagTable, mark_changed: bool, arena: ?[]const u8) CodegenError!void {
    var ctx: LocalCtx = .{ .tag_table = tag_table, .mark_changed = mark_changed, .arena_param = arena };
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
fn emitRuleBodyQuery(w: *Writer, ast: *const AstArena, rule: ast_mod.RuleDecl, info: WhenInfo, arena: ?[]const u8) CodegenError!void {
    var ctx: LocalCtx = .{
        .query_components = info.components,
        .arena_param = arena,
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
    /// A receiver-less `let s = get(R)` / `get_mut(R)` resource binding
    /// (M0.8 E3-C tranche 7, D-S3-resource-receiver). Uses lower per access,
    /// mirroring the interpreter's `Value.resource_ref`: a read forms a
    /// `*const R` through `getResource` (no dirty — a read through a mutable
    /// ref does not dirty), the write target forms a `*R` through
    /// `getMutResource` (dirty set co-located with the write, the
    /// interpreter's `writeResourceField` point).
    resource_alias,
    /// A closure capture (M0.8 E3-C tranche 6): an outer binding snapshotted
    /// into a field of the generated closure struct. Inside the closure's
    /// `call` fn body the ident emits as `__self.<name>`.
    capture,
};

const LocalInfo = struct {
    kind: LocalKind,
    /// For `component_alias`, the component name. For `value`, the inferred
    /// Zig type emitted in the `var`/`const` declaration (so subsequent uses
    /// know how to format compound assignments).
    component_name: []const u8 = "",
    zig_type: []const u8 = "",
    is_mut: bool = false,
    /// For a `value` bound to a closure literal, the closure expression
    /// node (M0.8 E3-C tranche 6) — lets the call site see the body (a
    /// throwing body rides the hidden `__err` out-param). `none` otherwise.
    closure_node: NodeId = NodeId.none,
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
    /// The in-scope frame-arena allocator parameter name (`"fa"`), or null
    /// when the emission context has no arena — top-level fns / methods,
    /// where a string concat fails loud (M0.8 E3-C tranche 1b; fn-body
    /// allocation = the §6.3 outparam-arena model, deferred). Set on
    /// rule-body contexts by the rule emitters.
    arena_param: ?[]const u8 = null,
    /// The innermost enclosing `try` block's label index (the try-catch slab
    /// index, unique per program), or null outside any `try` (M0.8 E3-C
    /// tranche 2). A `throw` / failed `throws`-fn call transfers control via
    /// `__thrown_<label> = <err>; break :__try_<label>;`. Saved/restored
    /// around try bodies; a catch body sees the OUTER label, so a rethrow
    /// propagates outward — same unwind shape as the interpreter's `thrown`.
    try_label: ?u32 = null,
    /// True while emitting the body of a `throws` fn (M0.8 E3-C tranche 2):
    /// an uncaught throw stores through the hidden `__err: *?Error` out-param
    /// and returns — the codegen image of the interpreter's signal crossing
    /// the `callFn` boundary.
    throws_fn: bool = false,
    /// The enclosing fn's Zig return type ("" = void) — the value a `throws`
    /// fn returns after storing the error (never read by the caller, which
    /// checks `__terr_*` before using the result).
    fn_ret_zig: []const u8 = "",

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
            // A bare `throwing_fn(args…)` statement (M0.8 E3-C tranche 2) —
            // the sanctioned statement-position `throws` call: per-call error
            // local, call with the hidden out-param, re-raise.
            if (ek == .fn_call) {
                const call_idx = ast.exprData(eid);
                const call = ast.call_exprs.items[call_idx];
                if (throwsCalleeDecl(ast, ctx, call) != null) {
                    try w.printLine("var __terr_{d}: ?Error = null;", .{call_idx});
                    try w.writeIndent();
                    try w.write("_ = ");
                    try emitThrowsCallExpr(w, ast, ctx, call, call_idx);
                    try w.write(";\n");
                    try emitThrowsCallCheck(w, ctx, call_idx);
                    return;
                }
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
            } else if (f.index_name != 0) {
                // `for k, v in m` — a two-binding for-in is a map iteration
                // (M0.8 E3-C tranche 3). The map local is an insertion-ordered
                // pair list (the interpreter's exact iteration order), so the
                // loop walks the items slice and binds key then value as
                // consts. An unused binding gets a `_ =` discard (the same
                // static-scan discipline as the tranche-2 catch binding). Any
                // non-map two-binding iterable already failed at the resolver;
                // fail loud here as the belt.
                const kv = mapKVZig(inferExprZigType(ast, ctx, f.iterable)) orelse return CodegenError.UnsupportedConstruct;
                try w.writeIndent();
                try w.write("for ((");
                try emitExpr(w, ast, ctx, f.iterable);
                try w.write(").items) |__kv| {\n");
                w.indentBy(1);
                try w.writeIndent();
                try w.write("const ");
                try w.ident(vname);
                try w.write(" = __kv.key;\n");
                if (!stmtRunUsesIdent(ast, f.var_name, f.body_start, f.body_len)) {
                    try w.writeIndent();
                    try w.write("_ = ");
                    try w.ident(vname);
                    try w.write(";\n");
                }
                try w.writeIndent();
                try w.write("const ");
                try w.ident(ast.strings.slice(f.index_name));
                try w.write(" = __kv.value;\n");
                if (!stmtRunUsesIdent(ast, f.index_name, f.body_start, f.body_len)) {
                    try w.writeIndent();
                    try w.write("_ = ");
                    try w.ident(ast.strings.slice(f.index_name));
                    try w.write(";\n");
                }
                const saved = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{ .key = .{ .name = f.var_name }, .info = .{ .kind = .value, .zig_type = kv.key, .is_mut = false } });
                try ctx.records.append(w.gpa, .{ .key = .{ .name = f.index_name }, .info = .{ .kind = .value, .zig_type = kv.value, .is_mut = false } });
                var s: u32 = 0;
                while (s < f.body_len) : (s += 1) {
                    try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[f.body_start + s]));
                }
                ctx.records.items.len = saved;
                w.indentBy(-1);
                try w.writeIndent();
                try w.write("}\n");
            } else {
                // `for v in <array> { body }` → Zig `for (<array>) |v| { ... }`
                // (M0.8 collections). Fixed arrays iterate directly; a dynamic
                // array (M0.8 E3-C tranche 3) iterates its backing items
                // slice, with the loop variable typed at the element type. Zig
                // infers the element type for fixed iterables, so that local
                // is recorded with no zig_type.
                const dyn_elem = dynArrayElemZig(inferExprZigType(ast, ctx, f.iterable));
                try w.writeIndent();
                try w.write("for (");
                if (dyn_elem != null) try w.write("(");
                try emitExpr(w, ast, ctx, f.iterable);
                if (dyn_elem != null) try w.write(").items");
                try w.write(") |");
                try w.ident(vname);
                try w.write("| {\n");
                w.indentBy(1);
                const saved = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{ .key = .{ .name = f.var_name }, .info = .{ .kind = .value, .zig_type = dyn_elem orelse "", .is_mut = false } });
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
        .throw_stmt => {
            // `throw expression` (M0.8 E3-C tranche 2) — the flag+branch
            // desugar, at the SAME logical point as the interpreter's
            // `thrown_value = eval(value); thrown = true`: evaluate the
            // operand, set the in-flight `Error`, transfer control. Inside a
            // `try`, the transfer is a labeled break to the try block's end;
            // inside a `throws` fn, it stores through the hidden `__err`
            // out-param and returns. A throw with neither home (an uncaught
            // rule-level throw — the interpreter counts a runtime error and
            // aborts the body) is deferred: fail loud, interpreter reference.
            const t = ast.throw_stmts.items[data];
            if (ctx.try_label) |lbl| {
                try w.writeIndent();
                try w.print("__thrown_{d} = ", .{lbl});
                try emitExpr(w, ast, ctx, t.value);
                try w.write(";\n");
                try w.writeIndent();
                try w.print("break :__try_{d};\n", .{lbl});
            } else if (ctx.throws_fn) {
                try w.writeIndent();
                try w.write("__err.* = ");
                try emitExpr(w, ast, ctx, t.value);
                try w.write(";\n");
                try emitThrowsFnAbort(w, ctx);
            } else {
                return CodegenError.UnsupportedConstruct;
            }
        },
        .try_catch_stmt => {
            // `try { … } catch err { … }` (M0.8 E3-C tranche 2) — flag+branch:
            //   var __thrown_N: ?Error = null;
            //   __try_N: { …try body… }      // throw → assign + break :__try_N
            //   if (__thrown_N) |err| { …catch body… }
            // N is the try-catch slab index — unique per program and stable
            // across the two-pass rule emission. A statically throw-free try
            // body emits inline without the plumbing: the catch body is
            // unreachable per the interpreter's semantics, and Zig rejects
            // the never-mutated `var`. The catch body sees the OUTER try
            // label, so a rethrow propagates outward — the interpreter's
            // re-raise from a catch body. An unused catch binding gets a
            // leading `_ = <name>;` (Zig rejects unused captures).
            const tc = ast.try_catch_stmts.items[data];
            var s: u32 = 0;
            if (!stmtRunCanThrow(ast, tc.try_start, tc.try_len)) {
                while (s < tc.try_len) : (s += 1) {
                    try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[tc.try_start + s]));
                }
                return;
            }
            try w.printLine("var __thrown_{d}: ?Error = null;", .{data});
            try w.printLine("__try_{d}: {{", .{data});
            w.indentBy(1);
            const saved_label = ctx.try_label;
            ctx.try_label = data;
            while (s < tc.try_len) : (s += 1) {
                try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[tc.try_start + s]));
            }
            ctx.try_label = saved_label;
            w.indentBy(-1);
            try w.line("}");
            try w.writeIndent();
            try w.print("if (__thrown_{d}) |", .{data});
            try w.ident(ast.strings.slice(tc.catch_name));
            try w.write("| {\n");
            w.indentBy(1);
            if (!stmtRunUsesIdent(ast, tc.catch_name, tc.catch_start, tc.catch_len)) {
                try w.writeIndent();
                try w.write("_ = ");
                try w.ident(ast.strings.slice(tc.catch_name));
                try w.write(";\n");
            }
            const saved_records = ctx.records.items.len;
            try ctx.records.append(w.gpa, .{ .key = .{ .name = tc.catch_name }, .info = .{ .kind = .value, .zig_type = "Error", .is_mut = false } });
            s = 0;
            while (s < tc.catch_len) : (s += 1) {
                try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[tc.catch_start + s]));
            }
            ctx.records.items.len = saved_records;
            w.indentBy(-1);
            try w.line("}");
        },
        else => return CodegenError.UnsupportedConstruct,
    }
}

/// `return <zero default>;` for the enclosing `throws` fn — the value a
/// throwing path returns after storing through `__err` (M0.8 E3-C tranche
/// 2). Never read: every sanctioned call site checks its `__terr_*` local
/// before using the result, mirroring the interpreter's `callFn` returning
/// unit with the signal set.
fn emitThrowsFnAbort(w: *Writer, ctx: *const LocalCtx) CodegenError!void {
    try w.writeIndent();
    if (ctx.fn_ret_zig.len == 0) {
        try w.write("return;\n");
    } else {
        try w.print("return {s};\n", .{zeroDefault(ctx.fn_ret_zig)});
    }
}

/// The post-call check of a sanctioned `throws`-fn call site (M0.8 E3-C
/// tranche 2): if the callee stored an error, re-raise it at THIS level —
/// into the enclosing try's flag, or through the enclosing `throws` fn's
/// own out-param. Same logical point as the interpreter's signal check on
/// `callFn` return. A call with neither home (an uncaught rule-level call)
/// is deferred: fail loud, interpreter reference.
fn emitThrowsCallCheck(w: *Writer, ctx: *const LocalCtx, call_idx: u32) CodegenError!void {
    try w.writeIndent();
    if (ctx.try_label) |lbl| {
        try w.print("if (__terr_{d}) |__e| {{ __thrown_{d} = __e; break :__try_{d}; }}\n", .{ call_idx, lbl, lbl });
    } else if (ctx.throws_fn) {
        if (ctx.fn_ret_zig.len == 0) {
            try w.print("if (__terr_{d}) |__e| {{ __err.* = __e; return; }}\n", .{call_idx});
        } else {
            try w.print("if (__terr_{d}) |__e| {{ __err.* = __e; return {s}; }}\n", .{ call_idx, zeroDefault(ctx.fn_ret_zig) });
        }
    } else {
        return CodegenError.UnsupportedConstruct;
    }
}

/// Emit a sanctioned `throws`-fn call: declare the per-call error local,
/// emit `name(args…, &__terr_K)`, where K is the call-expr slab index
/// (unique per program). The caller writes what receives the value (a
/// `const x: T =` head or a `_ =` discard) between `emitThrowsCallLocal`
/// and this call emission, then `emitThrowsCallCheck`.
fn emitThrowsCallExpr(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, call: ast_mod.CallExpr, call_idx: u32) CodegenError!void {
    try w.ident(ast.strings.slice(ast.exprData(call.callee)));
    try w.write("(");
    var i: u32 = 0;
    while (i < call.args_len) : (i += 1) {
        if (i > 0) try w.write(", ");
        try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[call.args_start + i]));
    }
    if (call.args_len > 0) try w.write(", ");
    try w.print("&__terr_{d})", .{call_idx});
}

fn emitLet(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, let: ast_mod.LetStmt) CodegenError!void {
    const value_kind = ast.exprKind(let.value);
    if (value_kind == .method_get or value_kind == .method_get_mut) {
        // `let h = entity.get(T)` / `let h = entity.get_mut(T)` — bind the
        // ident to the component alias. The emitted code is a comment to
        // keep the file readable; subsequent uses of `h` resolve through
        // the local context.
        const mg = ast.method_gets.items[ast.exprData(let.value)];
        // `let s = get(R)` / `get_mut(R)` binds a resource alias (M0.8 E3-C
        // tranche 7, D-S3-resource-receiver closed): like the component
        // alias, the emitted code is a comment and each use lowers at its
        // access site — reads through `getResource`, the write target
        // through `getMutResource` — mirroring the interpreter's
        // `Value.resource_ref { resource_id, mutable }`. The ref's
        // mutability comes from the accessor (not `let mut`), as in the
        // interpreter.
        if (mg.receiver.isNone()) {
            const rname = ast.strings.slice(mg.type_name);
            try ctx.records.append(w.gpa, .{
                .key = .{ .name = let.name },
                .info = .{
                    .kind = .resource_alias,
                    .component_name = rname,
                    .is_mut = value_kind == .method_get_mut,
                },
            });
            try w.printLine("// let {s} = {s}({s})", .{
                ast.strings.slice(let.name),
                if (value_kind == .method_get_mut) "get_mut" else "get",
                rname,
            });
            return;
        }
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

    // `let x = throwing_fn(args…)` (M0.8 E3-C tranche 2) — the sanctioned
    // let-position `throws` call: declare the per-call error local, call with
    // the hidden out-param, then re-raise. The binding takes the callee's
    // declared return type; on a throwing run it holds the never-read zero
    // default (the interpreter binds unit), and control transfers before any
    // use — observably identical.
    if (value_kind == .fn_call) {
        const call_idx = ast.exprData(let.value);
        const call = ast.call_exprs.items[call_idx];
        if (throwsCalleeDecl(ast, ctx, call)) |callee| {
            try w.printLine("var __terr_{d}: ?Error = null;", .{call_idx});
            try w.writeIndent();
            try w.print("{s} ", .{if (let.is_mut) "var" else "const"});
            try w.ident(ast.strings.slice(let.name));
            try w.write(" = ");
            try emitThrowsCallExpr(w, ast, ctx, call, call_idx);
            try w.write(";\n");
            const ret_zig = if (callee.return_type.isNone()) "" else fnTypeZig(ast, callee.return_type);
            try ctx.records.append(w.gpa, .{
                .key = .{ .name = let.name },
                .info = .{ .kind = .value, .zig_type = ret_zig, .is_mut = let.is_mut },
            });
            try emitThrowsCallCheck(w, ctx, call_idx);
            return;
        }
        if (throwingClosureCallee(ast, ctx, call) != null) {
            // `let x = throwing_closure(args…)` (M0.8 E3-C tranche 6) — the
            // closure image of the sanctioned let-position `throws` call:
            // same per-call error local, the hidden out-param rides the
            // `call` method, same re-raise at THIS level — the boundary
            // where the interpreter's `thrown` signal crosses the closure
            // call. On a throwing run the binding holds the never-read zero
            // default (the interpreter binds unit) and control transfers
            // before any use — observably identical.
            try w.printLine("var __terr_{d}: ?Error = null;", .{call_idx});
            try w.writeIndent();
            try w.print("{s} ", .{if (let.is_mut) "var" else "const"});
            try w.ident(ast.strings.slice(let.name));
            try w.write(" = ");
            try emitExpr(w, ast, ctx, call.callee);
            try w.write(".call(");
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (i > 0) try w.write(", ");
                try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[call.args_start + i]));
            }
            if (call.args_len > 0) try w.write(", ");
            try w.print("&__terr_{d});\n", .{call_idx});
            try ctx.records.append(w.gpa, .{
                .key = .{ .name = let.name },
                .info = .{ .kind = .value, .zig_type = "", .is_mut = let.is_mut },
            });
            try emitThrowsCallCheck(w, ctx, call_idx);
            return;
        }
    }

    // `let [mut] xs: T[] = <array literal>` (M0.8 E3-C tranche 3) — a dynamic
    // array local: a frame-arena-backed list, the codegen image of the
    // interpreter's per-body array store. Empty literal → `.empty` (no
    // allocation, no arena needed); a non-empty literal seeds via one
    // `appendSlice` on the frame arena. A fill literal / non-scalar element
    // is deferred — fail loud, interpreter reference.
    if (!let.type_annotation.isNone() and ast.typeNodeKind(let.type_annotation) == .slice) {
        const list_t = sliceAnnotationListType(ast, let.type_annotation) orelse return CodegenError.UnsupportedConstruct;
        if (ast.exprKind(let.value) != .array_lit) return CodegenError.UnsupportedConstruct;
        const al = ast.array_lits.items[ast.exprData(let.value)];
        if (al.is_fill) return CodegenError.UnsupportedConstruct;
        try w.writeIndent();
        try w.print("{s} ", .{if (let.is_mut) "var" else "const"});
        try w.ident(ast.strings.slice(let.name));
        try w.print(": {s} = .empty;\n", .{list_t});
        if (al.elements_len > 0) {
            const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
            w.arena_used = true;
            try w.writeIndent();
            try w.ident(ast.strings.slice(let.name));
            try w.print(".appendSlice({s}, &[_]{s}{{ ", .{ fa, dynArrayElemZig(list_t).? });
            var i: u32 = 0;
            while (i < al.elements_len) : (i += 1) {
                if (i > 0) try w.write(", ");
                try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[al.elements_start + i]));
            }
            try w.write(" }) catch unreachable;\n");
        }
        try ctx.records.append(w.gpa, .{
            .key = .{ .name = let.name },
            .info = .{ .kind = .value, .zig_type = list_t, .is_mut = let.is_mut },
        });
        return;
    }

    // `let [mut] m: [K: V] = <map literal>` / `let mut m = [k: v, ...]`
    // (M0.8 E3-C tranche 3) — a map local: an insertion-ordered pair list
    // seeded entry by entry through `__etchMapInsert`, the exact mechanics of
    // the interpreter's map-literal eval (last-write-wins on duplicate keys).
    // Without an annotation the key/value Zig types are inferred from the
    // first entry. A key/value pair outside the map table fails loud.
    const map_list_t: ?[]const u8 = blk: {
        if (!let.type_annotation.isNone() and ast.typeNodeKind(let.type_annotation) == .map_type) {
            break :blk mapAnnotationListType(ast, let.type_annotation) orelse return CodegenError.UnsupportedConstruct;
        }
        if (let.type_annotation.isNone() and ast.exprKind(let.value) == .map_lit) {
            const ml = ast.map_lits.items[ast.exprData(let.value)];
            if (ml.entries_len == 0) break :blk null; // un-annotated empty map → fail loud below
            const entry = ast.map_entries.items[ml.entries_start];
            break :blk mapZigType(inferExprZigType(ast, ctx, entry.key), inferExprZigType(ast, ctx, entry.value)) orelse return CodegenError.UnsupportedConstruct;
        }
        break :blk null;
    };
    if (map_list_t) |list_t| {
        if (ast.exprKind(let.value) != .map_lit) return CodegenError.UnsupportedConstruct;
        const ml = ast.map_lits.items[ast.exprData(let.value)];
        try w.writeIndent();
        try w.print("{s} ", .{if (let.is_mut) "var" else "const"});
        try w.ident(ast.strings.slice(let.name));
        try w.print(": {s} = .empty;\n", .{list_t});
        if (ml.entries_len > 0) {
            const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
            w.arena_used = true;
            var i: u32 = 0;
            while (i < ml.entries_len) : (i += 1) {
                const entry = ast.map_entries.items[ml.entries_start + i];
                try w.writeIndent();
                try w.write("__etchMapInsert(&");
                try w.ident(ast.strings.slice(let.name));
                try w.print(", {s}, ", .{fa});
                try emitExpr(w, ast, ctx, entry.key);
                try w.write(", ");
                try emitExpr(w, ast, ctx, entry.value);
                try w.write(");\n");
            }
        }
        try ctx.records.append(w.gpa, .{
            .key = .{ .name = let.name },
            .info = .{ .kind = .value, .zig_type = list_t, .is_mut = let.is_mut },
        });
        return;
    }

    // `let [mut] s: Set<T> = Set.new() / Set.from([...])` (M0.8 E3-C tranche
    // 3bis) — a set local: an insertion-ordered element list seeded through
    // `__etchSetInsert` (scan-skip-or-append — duplicates collapse), the
    // exact mechanics of the interpreter's set store. Sets have NO literal:
    // the `Set.new`/`Set.from` associated calls routed here are the only
    // supported initializers — any other set-valued initializer fails loud.
    // Without an annotation the element Zig type is inferred from the first
    // `Set.from` element (an un-annotated `Set.new()` has no element type).
    const set_list_t: ?[]const u8 = blk: {
        if (!let.type_annotation.isNone() and ast.typeNodeKind(let.type_annotation) == .set_type) {
            break :blk setAnnotationListType(ast, let.type_annotation) orelse return CodegenError.UnsupportedConstruct;
        }
        if (let.type_annotation.isNone()) {
            if (setCallOf(ast, let.value)) |call| {
                if (call == .from and ast.exprKind(call.from) == .array_lit) {
                    const al = ast.array_lits.items[ast.exprData(call.from)];
                    if (!al.is_fill and al.elements_len > 0) {
                        const first: NodeId = @bitCast(ast.extra.items[al.elements_start]);
                        break :blk setZigType(inferExprZigType(ast, ctx, first)) orelse return CodegenError.UnsupportedConstruct;
                    }
                }
                return CodegenError.UnsupportedConstruct;
            }
        }
        break :blk null;
    };
    if (set_list_t) |list_t| {
        const call = setCallOf(ast, let.value) orelse return CodegenError.UnsupportedConstruct;
        try w.writeIndent();
        try w.print("{s} ", .{if (let.is_mut) "var" else "const"});
        try w.ident(ast.strings.slice(let.name));
        try w.print(": {s} = .empty;\n", .{list_t});
        if (call == .from) {
            if (ast.exprKind(call.from) != .array_lit) return CodegenError.UnsupportedConstruct;
            const al = ast.array_lits.items[ast.exprData(call.from)];
            if (al.is_fill) return CodegenError.UnsupportedConstruct;
            if (al.elements_len > 0) {
                const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
                w.arena_used = true;
                var i: u32 = 0;
                while (i < al.elements_len) : (i += 1) {
                    try w.writeIndent();
                    try w.write("__etchSetInsert(&");
                    try w.ident(ast.strings.slice(let.name));
                    try w.print(", {s}, ", .{fa});
                    try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[al.elements_start + i]));
                    try w.write(");\n");
                }
            }
        }
        try ctx.records.append(w.gpa, .{
            .key = .{ .name = let.name },
            .info = .{ .kind = .value, .zig_type = list_t, .is_mut = let.is_mut },
        });
        return;
    }

    // Anonymous `.{ … }` initializer (M0.8 E3-C tranche 8): the let
    // annotation supplies the struct type — emitted as the qualified
    // `TypeName{ … }`, byte-identical to the explicit form's emission (the
    // binding stays un-annotated, like every struct-literal let). The
    // resolver guarantees a named struct annotation (E0210 otherwise).
    if (ast.exprKind(let.value) == .struct_lit) {
        const sl = ast.struct_lits.items[ast.exprData(let.value)];
        if (sl.type_name == 0) {
            if (let.type_annotation.isNone() or ast.typeNodeKind(let.type_annotation) != .named) return CodegenError.UnsupportedConstruct;
            const named = ast.named_types.items[ast.typeNodeData(let.type_annotation)];
            const sname = ast.resolveTypeAliasName(named.name);
            if (!isStructName(ast, sname)) return CodegenError.UnsupportedConstruct;
            try w.writeIndent();
            try w.print("{s} ", .{if (let.is_mut) "var" else "const"});
            try w.ident(ast.strings.slice(let.name));
            try w.write(" = ");
            try emitStructLitAs(w, ast, ctx, sl, sname);
            try w.write(";\n");
            try ctx.records.append(w.gpa, .{
                .key = .{ .name = let.name },
                .info = .{ .kind = .value, .zig_type = "", .is_mut = let.is_mut },
            });
            return;
        }
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
        .info = .{
            .kind = .value,
            .zig_type = zig_t,
            .is_mut = let.is_mut,
            .closure_node = if (value_kind == .closure) let.value else NodeId.none,
        },
    });
}

fn emitAssign(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, assign: ast_mod.AssignStmt) CodegenError!void {
    // Resource-field write (M0.8 E3-C tranche 7) — `get_mut(R).f = …` direct
    // or through a mutable `let s = get_mut(R)` alias: the write target is a
    // `*R` formed through `getMutResource`, which sets the dirty bit
    // co-located with the write — the same logical point as the
    // interpreter's `writeResourceField` (a pure read never dirties), so
    // `when resource R changed` gating is byte-exact by construction.
    if (assignTargetResource(ast, ctx, assign.target)) |rname| {
        const fa = ast.field_accesses.items[ast.exprData(assign.target)];
        try w.writeIndent();
        try w.print("@as(*{s}, @ptrCast(@alignCast(world.resources.getMutResource({s}_id).?.ptr))).", .{ rname, rname });
        try w.ident(ast.strings.slice(fa.field_name));
        try w.write(" ");
        try w.write(assignOpText(assign.op));
        try w.write(" ");
        try emitExpr(w, ast, ctx, assign.value);
        try w.write(";\n");
        return;
    }
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

/// The resource name a write targets, when `assign.target` is a resource-field
/// write — receiver-less `get_mut(R).f` or a mutable `let s = get_mut(R)`
/// alias (M0.8 E3-C tranche 7) — or null otherwise. A write through an
/// immutable resource ref falls to the generic path, where the const-pointer
/// read emission fails the Zig compile loudly (the interpreter likewise fails
/// at runtime on `mutable == false` — never silently wrong).
fn assignTargetResource(ast: *const AstArena, ctx: *const LocalCtx, target: NodeId) ?[]const u8 {
    if (ast.exprKind(target) != .field_access) return null;
    const fa = ast.field_accesses.items[ast.exprData(target)];
    const recv = fa.receiver;
    switch (ast.exprKind(recv)) {
        .method_get_mut => {
            const mg = ast.method_gets.items[ast.exprData(recv)];
            if (!mg.receiver.isNone()) return null; // entity receiver → component write
            return ast.strings.slice(mg.type_name);
        },
        .ident => {
            if (ctx.lookup(ast.exprData(recv))) |local| {
                if (local.kind == .resource_alias and local.is_mut) return local.component_name;
            }
            return null;
        },
        else => return null,
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
            // String literal (M0.8 sub-slice C tranche 1) → a Zig `[]const u8`
            // slice so `.len` and (tranche 1b) concat compose uniformly. The
            // Etch literal's bytes are re-emitted as an escaped Zig string
            // literal.
            try w.write("@as([]const u8, ");
            try emitZigStringLiteral(w, ast.strings.slice(data));
            try w.write(")");
        },
        .string_interp => {
            // Interpolated string (M0.8 E3-C tranche 1c, stdlib §12.5) →
            // ONE `std.fmt.allocPrint(fa, "<segments+specs>", .{args})` in
            // the tick's frame arena. Per-arg specs mirror the interpreter's
            // piece formatting exactly: `{d}` for ints and floats (f64 args
            // are `@as(f64, …)`-pinned so a comptime_float literal formats
            // through the same runtime f64 path), bools lower to a
            // `{s}`-fed true/false selection, strings are `{s}`. Identical
            // `std.fmt` specs on identically-typed values → byte-exact with
            // the interp. No arena in scope (fn/method body) → fail loud.
            const si = ast.string_interps.items[data];
            const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
            w.arena_used = true;
            try w.print("(std.fmt.allocPrint({s}, \"", .{fa});
            var k: u32 = 0;
            while (k < si.n_exprs) : (k += 1) {
                try emitFmtSegment(w, ast.strings.slice(ast.extra.items[si.segs_start + k]));
                const e: NodeId = @bitCast(ast.extra.items[si.exprs_start + k]);
                const zig_t = inferExprZigType(ast, ctx, e);
                if (std.mem.eql(u8, zig_t, "[]const u8") or std.mem.eql(u8, zig_t, "bool")) {
                    try w.write("{s}");
                } else {
                    try w.write("{d}");
                }
            }
            try emitFmtSegment(w, ast.strings.slice(ast.extra.items[si.segs_start + si.n_exprs]));
            try w.write("\", .{ ");
            k = 0;
            while (k < si.n_exprs) : (k += 1) {
                if (k > 0) try w.write(", ");
                const e: NodeId = @bitCast(ast.extra.items[si.exprs_start + k]);
                const zig_t = inferExprZigType(ast, ctx, e);
                if (std.mem.eql(u8, zig_t, "bool")) {
                    // Literal true/false text, exactly the interp's pieces —
                    // sidesteps any fmt-spec semantics on bool.
                    try w.write("@as([]const u8, if (");
                    try emitExpr(w, ast, ctx, e);
                    try w.write(") \"true\" else \"false\")");
                } else if (std.mem.eql(u8, zig_t, "f64")) {
                    try w.write("@as(f64, ");
                    try emitExpr(w, ast, ctx, e);
                    try w.write(")");
                } else {
                    try emitExpr(w, ast, ctx, e);
                }
            }
            try w.write(" }) catch unreachable)");
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
                    .capture => {
                        // A captured outer binding reads through the closure
                        // struct's receiver (M0.8 E3-C tranche 6) — the value
                        // snapshotted at creation, not the live outer local.
                        try w.write("__self.");
                        try w.ident(ast.strings.slice(name_id));
                    },
                    .component_alias => try emitComponentSlot(w, ctx, local.component_name),
                    // Read through a resource alias (M0.8 E3-C tranche 7) —
                    // the write target never reaches here (`emitAssign`).
                    .resource_alias => try emitResourceConstPtr(w, local.component_name),
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
            // Receiver-less `get(R)` / `get_mut(R)` in value (read) position
            // (M0.8 E3-C tranche 7, D-S3-resource-receiver closed): a typed
            // const pointer over the resource-store buffer via `getResource`
            // — no dirty, exactly the interpreter's `readResourceField`
            // route (a read through a mutable ref does not dirty; the write
            // target is handled in `emitAssign`). The store buffer is
            // chunk-aligned (Option A, `resources.zig`) so the `@alignCast`
            // is sound in ReleaseSafe — ABI pointer identity, `etch-abi-zig.md`
            // §3.1. `<R>_id` is in scope from the rule's resource gate (the
            // resolver requires `resource R` in the when clause, E1213).
            if (mg.receiver.isNone()) {
                try emitResourceConstPtr(w, ast.strings.slice(mg.type_name));
                return;
            }
            try emitComponentSlot(w, ctx, ast.strings.slice(mg.type_name));
        },
        .match_expr => try emitMatch(w, ast, ctx, data),
        .array_lit => {
            // `[a, b, c]` → `[_]ELEM{ ... }`, `[v; n]` → `[_]ELEM{v} ** n`
            // (M0.8 collections): the fixed (stack) array form — the element
            // type is inferred from the first element. Dynamic `T[]` literals
            // never reach this arm: they are routed at the `let` (the only
            // place a slice annotation types them, M0.8 E3-C tranche 3). An
            // empty literal outside that route has no type — fail loud. Set
            // codegen is deferred with its interp runtime (no Set store yet).
            const al = ast.array_lits.items[data];
            if (al.elements_len == 0) return CodegenError.UnsupportedConstruct;
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
            // `m[k] -> V?` (stdlib §14.2, M0.8 E3-C tranche 4): a map
            // receiver routes through the __etchMapGet prelude helper — the
            // same insertion-ordered scan as the interpreter's map store,
            // byte-exact by construction.
            if (mapKVZig(inferExprZigType(ast, ctx, ix.receiver)) != null) {
                if (ast.exprKind(ix.index) == .range) return CodegenError.UnsupportedConstruct;
                try w.write("__etchMapGet(");
                try emitExpr(w, ast, ctx, ix.receiver);
                try w.write(", ");
                try emitExpr(w, ast, ctx, ix.index);
                try w.write(")");
                return;
            }
            // A dynamic-array receiver (M0.8 E3-C tranche 3) indexes through
            // its backing items slice; range-slicing a dynamic array (a fresh
            // array in the interpreter) is deferred — fail loud.
            const recv_is_dyn = dynArrayElemZig(inferExprZigType(ast, ctx, ix.receiver)) != null;
            if (recv_is_dyn and ast.exprKind(ix.index) == .range) return CodegenError.UnsupportedConstruct;
            try emitExpr(w, ast, ctx, ix.receiver);
            if (recv_is_dyn) try w.write(".items");
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
            // body; } }` (M0.8 closures). A CAPTURING closure (E3-C tranche 6)
            // lowers to struct-with-fields: the captured outer values are
            // snapshotted into the instance AT CREATION — the same logical
            // point as the interpreter's locals snapshot (§5.6 value capture)
            // — and the body reads them through the `__self` receiver. The
            // capture-free form stays the bare TYPE (namespace call); both
            // shapes serve `callee.call(args)` at the call site. A BLOCK body
            // emits its statements straight into the `call` fn — a `return`
            // inside is the fn's own natural Zig boundary, the exact image of
            // the interpreter's boundary-consume (a return exits the closure,
            // never the enclosing fn — the ratified E2 forward note); the
            // trailing value becomes the final `return`.
            const ce = ast.closure_exprs.items[data];
            var captures: std.ArrayListUnmanaged(Capture) = .empty;
            defer captures.deinit(w.gpa);
            try collectClosureCaptures(w.gpa, ast, ctx, ce, &captures);
            const is_block = ast.exprKind(ce.body) == .block_expr;
            const saved = ctx.records.items.len;
            var i: u32 = 0;
            while (i < ce.params_len) : (i += 1) {
                const p = ast.closure_params.items[ce.params_start + i];
                try ctx.records.append(w.gpa, .{ .key = .{ .name = p.name }, .info = .{ .kind = .value, .zig_type = closureParamZigType(ast, p), .is_mut = false } });
            }
            for (captures.items) |c| {
                try ctx.records.append(w.gpa, .{ .key = .{ .name = c.name }, .info = .{ .kind = .capture, .zig_type = c.zig_type, .is_mut = false } });
            }
            const ret_zig = blk: {
                if (!is_block) break :blk inferExprZigType(ast, ctx, ce.body);
                const body_blk = ast.block_exprs.items[ast.exprData(ce.body)];
                if (body_blk.value.isNone()) break :blk "void";
                break :blk inferExprZigType(ast, ctx, body_blk.value);
            };
            // A body whose Zig type is not inferable would emit a void fn
            // returning a value — fail loud instead (interpreter reference).
            if (ret_zig.len == 0) return CodegenError.UnsupportedConstruct;
            // The closure's `call` fn is a NEW fn boundary: the enclosing
            // try label / frame arena / `throws` out-param are not in scope
            // inside it. A THROWING body rides the closure's OWN hidden
            // `__err` out-param — the tranche-2 throws-fn machinery verbatim
            // (the sanctioned call site re-raises; thrown PROPAGATES through
            // the closure boundary where returning is consumed inside).
            const body_throws = exprCanThrow(ast, ce.body);
            const saved_try = ctx.try_label;
            const saved_arena = ctx.arena_param;
            const saved_throws = ctx.throws_fn;
            const saved_fn_ret = ctx.fn_ret_zig;
            ctx.try_label = null;
            ctx.arena_param = null;
            ctx.throws_fn = body_throws;
            ctx.fn_ret_zig = if (std.mem.eql(u8, ret_zig, "void")) "" else ret_zig;
            try w.write("struct { ");
            for (captures.items) |c| {
                try w.ident(ast.strings.slice(c.name));
                try w.print(": {s}, ", .{c.zig_type});
            }
            try w.write("fn call(");
            var first = true;
            if (captures.items.len > 0) {
                try w.write("__self: @This()");
                first = false;
            }
            i = 0;
            while (i < ce.params_len) : (i += 1) {
                if (!first) try w.write(", ");
                first = false;
                const p = ast.closure_params.items[ce.params_start + i];
                try w.ident(ast.strings.slice(p.name));
                try w.print(": {s}", .{closureParamZigType(ast, p)});
            }
            if (body_throws) {
                if (!first) try w.write(", ");
                first = false;
                try w.write("__err: *?Error");
            }
            if (is_block) {
                const body_blk = ast.block_exprs.items[ast.exprData(ce.body)];
                try w.print(") {s} {{\n", .{ret_zig});
                w.indentBy(1);
                var s: u32 = 0;
                while (s < body_blk.body_len) : (s += 1) {
                    try emitStmt(w, ast, ctx, @bitCast(ast.extra.items[body_blk.body_start + s]));
                }
                if (!body_blk.value.isNone()) {
                    try w.writeIndent();
                    try w.write("return ");
                    try emitExpr(w, ast, ctx, body_blk.value);
                    try w.write(";\n");
                }
                w.indentBy(-1);
                try w.writeIndent();
                try w.write("} }");
            } else {
                try w.print(") {s} {{ return ", .{ret_zig});
                try emitExpr(w, ast, ctx, ce.body);
                try w.write("; } }");
            }
            ctx.try_label = saved_try;
            ctx.arena_param = saved_arena;
            ctx.throws_fn = saved_throws;
            ctx.fn_ret_zig = saved_fn_ret;
            ctx.records.items.len = saved;
            // Instantiate with the CURRENT outer values (the records are
            // restored first, so each name resolves to the outer binding).
            if (captures.items.len > 0) {
                try w.write("{ ");
                for (captures.items, 0..) |c, c_i| {
                    if (c_i > 0) try w.write(", ");
                    try w.write(".");
                    try w.ident(ast.strings.slice(c.name));
                    try w.write(" = ");
                    try w.ident(ast.strings.slice(c.name));
                }
                try w.write(" }");
            }
        },
        .fn_call => {
            // Two callee shapes (M0.8 E2). A callee that is an ident not bound
            // to a local is a top-level `fn` → direct `name(args)`. Otherwise
            // it's a closure-typed local → `callee.call(args)` (E1 closures,
            // lowered to the anonymous struct above).
            const call = ast.call_exprs.items[data];
            const is_free_fn = ast.exprKind(call.callee) == .ident and ctx.lookup(ast.exprData(call.callee)) == null;
            if (is_free_fn) {
                // A `throws` fn call in expression position (M0.8 E3-C
                // tranche 2): the hidden out-param needs statement-level
                // sequencing — sanctioned positions are a `let` initializer
                // and a bare call statement, anything nested fails loud.
                if (throwsCalleeDecl(ast, ctx, call) != null) return CodegenError.UnsupportedConstruct;
                try w.ident(ast.strings.slice(ast.exprData(call.callee)));
            } else {
                // A throwing-closure call needs the statement-level `__terr`
                // sequencing — the sanctioned position is a `let`
                // initializer; any nested position fails loud (M0.8 E3-C
                // tranche 6, the throws-fn rule above mirrored).
                if (throwingClosureCallee(ast, ctx, call) != null) return CodegenError.UnsupportedConstruct;
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
            // anonymous `.{ … }` form (`type_name == 0`, M0.8 E3-C tranche 8)
            // is emitted by its typed context (let annotation / typed field
            // value) through `emitStructLitAs` — the resolver rejects any
            // other position (E0210); belt here.
            const sl = ast.struct_lits.items[data];
            if (sl.type_name == 0) return CodegenError.UnsupportedConstruct;
            try emitStructLitAs(w, ast, ctx, sl, sl.type_name);
        },
        .method_call => {
            // `recv.method(args)` / `Type.assoc(args)` → Zig method / associated
            // call (M0.8 E2 block 3, §5.1). Inherent methods are emitted inside
            // the struct, so Zig's `value.method(args)` / `Type.assoc(args)`
            // syntax resolves them directly.
            const mc = ast.method_calls.items[data];
            // `recv?.method()` — optional chain (M0.8 E3-C tranche 4): a Zig
            // if-capture that short-circuits to `null`. The resolver bounds
            // the op to builtin-payload methods; the only one in the M0.8
            // subset is string `len`, so the emission is closed over it —
            // anything else fails loud (interpreter reference).
            if (mc.opt_chain) {
                const recv_zig = inferExprZigType(ast, ctx, mc.receiver);
                if (std.mem.eql(u8, recv_zig, "?[]const u8") and
                    std.mem.eql(u8, ast.strings.slice(mc.method_name), "len") and mc.args_len == 0)
                {
                    try w.write("(if (");
                    try emitExpr(w, ast, ctx, mc.receiver);
                    try w.write(") |__opv| @as(?i64, @intCast(__opv.len)) else null)");
                    return;
                }
                return CodegenError.UnsupportedConstruct;
            }
            // Builtin dynamic-array / map methods (M0.8 E3-C tranches 3-4 —
            // minimal faithful subset, stdlib §13.2/§14.2), routed on the
            // receiver's emitted declaration type. `push` / `insert` allocate
            // on the frame arena and value as Zig `void` — sound in statement
            // position (the resolver bounds them there); a value-position use
            // fails loud downstream (`void` binding). `len` is the count as
            // Etch `int`; `pop` maps to the list's own `?T`-returning pop
            // (tranche 4). Anything else is stdlib Phase 1+ → fail loud.
            if (ast.exprKind(mc.receiver) != .path) {
                const recv_zig = inferExprZigType(ast, ctx, mc.receiver);
                if (dynArrayElemZig(recv_zig) != null) {
                    const mname = ast.strings.slice(mc.method_name);
                    if (std.mem.eql(u8, mname, "pop") and mc.args_len == 0) {
                        try w.write("(");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.write(").pop()");
                        return;
                    }
                    if (std.mem.eql(u8, mname, "push") and mc.args_len == 1) {
                        const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
                        w.arena_used = true;
                        try w.write("(");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.print(").append({s}, ", .{fa});
                        try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[mc.args_start]));
                        try w.write(") catch unreachable");
                        return;
                    }
                    if (std.mem.eql(u8, mname, "len") and mc.args_len == 0) {
                        try w.write("@as(i64, @intCast((");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.write(").items.len))");
                        return;
                    }
                    return CodegenError.UnsupportedConstruct;
                }
                if (mapKVZig(recv_zig) != null) {
                    const mname = ast.strings.slice(mc.method_name);
                    if (std.mem.eql(u8, mname, "insert") and mc.args_len == 2) {
                        const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
                        w.arena_used = true;
                        try w.write("__etchMapInsert(&(");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.print("), {s}, ", .{fa});
                        try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[mc.args_start]));
                        try w.write(", ");
                        try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[mc.args_start + 1]));
                        try w.write(")");
                        return;
                    }
                    if (std.mem.eql(u8, mname, "len") and mc.args_len == 0) {
                        try w.write("@as(i64, @intCast((");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.write(").items.len))");
                        return;
                    }
                    return CodegenError.UnsupportedConstruct;
                }
                // Builtin set methods (M0.8 E3-C tranche 3bis — minimal
                // faithful subset, stdlib §15.2), routed on the emitted
                // declaration type like arrays / maps. `insert` goes through
                // the scan-skip-or-append prelude helper (statement position,
                // Zig `void`); `contains` through the matching scan helper
                // (→ bool); `len` is the element count as Etch `int`.
                // Anything else is stdlib Phase 1+ → fail loud.
                if (setElemZig(recv_zig) != null) {
                    const mname = ast.strings.slice(mc.method_name);
                    if (std.mem.eql(u8, mname, "insert") and mc.args_len == 1) {
                        const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
                        w.arena_used = true;
                        try w.write("__etchSetInsert(&(");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.print("), {s}, ", .{fa});
                        try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[mc.args_start]));
                        try w.write(")");
                        return;
                    }
                    if (std.mem.eql(u8, mname, "contains") and mc.args_len == 1) {
                        try w.write("__etchSetContains(");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.write(", ");
                        try emitExpr(w, ast, ctx, @bitCast(ast.extra.items[mc.args_start]));
                        try w.write(")");
                        return;
                    }
                    if (std.mem.eql(u8, mname, "len") and mc.args_len == 0) {
                        try w.write("@as(i64, @intCast((");
                        try emitExpr(w, ast, ctx, mc.receiver);
                        try w.write(").items.len))");
                        return;
                    }
                    return CodegenError.UnsupportedConstruct;
                }
            }
            // Builtin string method (M0.8 sub-slice C tranche 1). `s.len()` →
            // Zig `(s).len` cast to `i64` (Etch `int`). Other string methods are
            // stdlib Phase 1+ → fail loud (the resolver already rejects them, so
            // this is a defensive belt).
            if (ast.exprKind(mc.receiver) != .path and
                std.mem.eql(u8, inferExprZigType(ast, ctx, mc.receiver), "[]const u8"))
            {
                if (!std.mem.eql(u8, ast.strings.slice(mc.method_name), "len")) {
                    return CodegenError.UnsupportedConstruct;
                }
                try w.write("@as(i64, @intCast((");
                try emitExpr(w, ast, ctx, mc.receiver);
                try w.write(").len))");
                return;
            }
            if (ast.exprKind(mc.receiver) == .path) {
                // Associated fn: the receiver is a bare type name. A `Set.*`
                // builtin call outside the `emitLet` set route (the only
                // supported position, M0.8 E3-C tranche 3bis) fails loud
                // here rather than emitting an undeclared `Set`.
                const tname = ast.strings.slice(ast.exprData(mc.receiver));
                if (std.mem.eql(u8, tname, "Set")) return CodegenError.UnsupportedConstruct;
                try w.write(tname);
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
            // `string + string` → concat allocated in the tick's frame arena
            // via the rule's threaded `fa` (M0.8 E3-C tranche 1b; stdlib
            // §12.4, arena model `etch-memory-model.md` §3 / abi-zig §5.6).
            // Same logical point as the interpreter's `.add` intercept in
            // `evalExpr` — byte-exact by construction. The resolver only
            // lets string+string through, so one string operand suffices to
            // classify. No arena in scope (fn/method body) → fail loud.
            if (b.op == .add and
                (std.mem.eql(u8, inferExprZigType(ast, ctx, b.lhs), "[]const u8") or
                    std.mem.eql(u8, inferExprZigType(ast, ctx, b.rhs), "[]const u8")))
            {
                const fa = ctx.arena_param orelse return CodegenError.UnsupportedConstruct;
                w.arena_used = true;
                try w.print("(std.mem.concat({s}, u8, &.{{ ", .{fa});
                try emitExpr(w, ast, ctx, b.lhs);
                try w.write(", ");
                try emitExpr(w, ast, ctx, b.rhs);
                try w.write(" }) catch unreachable)");
                return;
            }
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
                // `expr!` → Zig `.?` (M0.8 E3-C tranche 4, stdlib §16.2):
                // the null-unwrap panic is the same observable as the
                // interpreter's RuntimeFailure on a `none`.
                .force_unwrap => {
                    try w.write("(");
                    try emitExpr(w, ast, ctx, u.operand);
                    try w.write(").?");
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
        // `a ?? b` → Zig `orelse` (M0.8 E3-C tranche 4): same short-circuit
        // semantics as the interpreter's coalesce intercept.
        .coalesce => "orelse",
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
            // `some(v)` / `none` optional patterns (M0.8 E3-C tranche 4,
            // part1 §7.6) → Zig optional capture / null comparison on the
            // scrutinee snapshot.
            .optional_some => {
                const name: StringId = arm.pattern_payload;
                try w.print("if (__m{d}) |", .{lbl});
                try w.ident(ast.strings.slice(name));
                try w.print("| break :blk{d} ", .{lbl});
                const saved_len = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{
                    .key = .{ .name = name },
                    .info = .{ .kind = .value, .zig_type = "", .is_mut = false },
                });
                try emitExpr(w, ast, ctx, arm.body);
                ctx.records.items.len = saved_len;
                try w.write("; ");
            },
            .optional_none => {
                try w.print("if (__m{d} == null) break :blk{d} ", .{ lbl, lbl });
                try emitExpr(w, ast, ctx, arm.body);
                try w.write("; ");
            },
        }
    }
    // bool- / optional-exhaustive matches have no catch-all arm; the
    // type-checker proved every case is covered, so the fall-through is
    // unreachable.
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
            // `some(v)` / `none` optional patterns in statement position
            // (M0.8 E3-C tranche 4): Zig optional capture / null comparison.
            .optional_some => {
                try w.print("if (__ms{d}) |", .{lbl});
                try w.ident(ast.strings.slice(arm.pattern_payload));
                try w.write("| ");
                const saved_len = ctx.records.items.len;
                try ctx.records.append(w.gpa, .{
                    .key = .{ .name = arm.pattern_payload },
                    .info = .{ .kind = .value, .zig_type = "", .is_mut = false },
                });
                try emitArmBodyAsStmts(w, ast, ctx, arm.body, lbl, null);
                ctx.records.items.len = saved_len;
                chained = true;
            },
            .optional_none => {
                try w.print("if (__ms{d} == null) ", .{lbl});
                try emitArmBodyAsStmts(w, ast, ctx, arm.body, lbl, null);
                chained = true;
            },
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

/// One captured outer binding of a closure (M0.8 E3-C tranche 6): the Etch
/// name doubles as the generated closure struct's field name; `zig_type` is
/// the binding's recorded scalar Zig type.
const Capture = struct { name: StringId, zig_type: []const u8 };

/// True for the POD scalar Zig types a closure may capture (M0.8 E3-C
/// tranche 6) — the `etch-resolver-types.md` §8.2 value-by-copy rows the
/// M0.8 codegen subset records concretely. Strings / collections are
/// ref-captures per §8.2 and stay deferred (interpreter reference).
fn isCapturableZigType(t: []const u8) bool {
    return std.mem.eql(u8, t, "i64") or std.mem.eql(u8, t, "f64") or std.mem.eql(u8, t, "bool");
}

/// Collect the outer bindings a closure body references, in first-reference
/// order — the generated struct's field order, stable per program (M0.8
/// E3-C tranche 6). `bound` tracks the names the body itself binds (params,
/// body-local `let`s, loop vars, catch bindings); the set is flat
/// (post-resolver, Etch forbids same-scope shadowing — a nested-scope
/// shadow that escapes its block was already resolver-rejected, and an
/// exotic miss surfaces as an undeclared identifier at `zig build`, never a
/// silent divergence). Captures are bounded to POD scalar value locals; a
/// body reference to any other outer binding (component alias, string /
/// collection handle, struct, closure) fails loud — interpreter reference.
fn collectClosureCaptures(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    ctx: *const LocalCtx,
    ce: ast_mod.ClosureExpr,
    out: *std.ArrayListUnmanaged(Capture),
) CodegenError!void {
    var bound: std.AutoHashMapUnmanaged(StringId, void) = .empty;
    defer bound.deinit(gpa);
    var i: u32 = 0;
    while (i < ce.params_len) : (i += 1) {
        try bound.put(gpa, ast.closure_params.items[ce.params_start + i].name, {});
    }
    try collectCapturesExpr(gpa, ast, ctx, &bound, out, ce.body);
}

fn collectCapturesExpr(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    ctx: *const LocalCtx,
    bound: *std.AutoHashMapUnmanaged(StringId, void),
    out: *std.ArrayListUnmanaged(Capture),
    expr: NodeId,
) CodegenError!void {
    const data = ast.exprData(expr);
    switch (ast.exprKind(expr)) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .tag_path, .none_lit => {},
        .ident => {
            const name: StringId = data;
            if (bound.contains(name)) return;
            // An unknown name is a top-level fn (free-call callee) — not a
            // capture; a plain undefined ident was resolver-rejected.
            const local = ctx.lookup(name) orelse return;
            if (local.kind != .value or !isCapturableZigType(local.zig_type)) {
                return CodegenError.UnsupportedConstruct;
            }
            for (out.items) |c| {
                if (c.name == name) return;
            }
            try out.append(gpa, .{ .name = name, .zig_type = local.zig_type });
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            try collectCapturesExpr(gpa, ast, ctx, bound, out, b.lhs);
            try collectCapturesExpr(gpa, ast, ctx, bound, out, b.rhs);
        },
        .unary => try collectCapturesExpr(gpa, ast, ctx, bound, out, ast.unary_exprs.items[data].operand),
        .cast => try collectCapturesExpr(gpa, ast, ctx, bound, out, ast.casts.items[data].operand),
        .some_lit => try collectCapturesExpr(gpa, ast, ctx, bound, out, @bitCast(data)),
        .fn_call => {
            const call = ast.call_exprs.items[data];
            try collectCapturesExpr(gpa, ast, ctx, bound, out, call.callee);
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                try collectCapturesExpr(gpa, ast, ctx, bound, out, @bitCast(ast.extra.items[call.args_start + i]));
            }
        },
        .method_call => {
            const mc = ast.method_calls.items[data];
            if (ast.exprKind(mc.receiver) != .path) try collectCapturesExpr(gpa, ast, ctx, bound, out, mc.receiver);
            var i: u32 = 0;
            while (i < mc.args_len) : (i += 1) {
                try collectCapturesExpr(gpa, ast, ctx, bound, out, @bitCast(ast.extra.items[mc.args_start + i]));
            }
        },
        .field_access => {
            // `EnumName.variant` is an enum VALUE — nothing to capture
            // (mirrors the emission's `enumValueName` route).
            if (enumValueName(ast, expr) != null) return;
            try collectCapturesExpr(gpa, ast, ctx, bound, out, ast.field_accesses.items[data].receiver);
        },
        .path => {},
        .index => {
            const ix = ast.index_exprs.items[data];
            try collectCapturesExpr(gpa, ast, ctx, bound, out, ix.receiver);
            try collectCapturesExpr(gpa, ast, ctx, bound, out, ix.index);
        },
        .range => {
            const r = ast.ranges.items[data];
            try collectCapturesExpr(gpa, ast, ctx, bound, out, r.start);
            try collectCapturesExpr(gpa, ast, ctx, bound, out, r.end);
        },
        .struct_lit => {
            const sl = ast.struct_lits.items[data];
            var i: u32 = 0;
            while (i < sl.fields_len) : (i += 1) {
                try collectCapturesExpr(gpa, ast, ctx, bound, out, ast.struct_lit_fields.items[sl.fields_start + i].value);
            }
        },
        .array_lit => {
            const al = ast.array_lits.items[data];
            var i: u32 = 0;
            while (i < al.elements_len) : (i += 1) {
                try collectCapturesExpr(gpa, ast, ctx, bound, out, @bitCast(ast.extra.items[al.elements_start + i]));
            }
            if (al.is_fill) try collectCapturesExpr(gpa, ast, ctx, bound, out, al.fill_count);
        },
        .string_interp => {
            const si = ast.string_interps.items[data];
            var i: u32 = 0;
            while (i < si.n_exprs) : (i += 1) {
                try collectCapturesExpr(gpa, ast, ctx, bound, out, @bitCast(ast.extra.items[si.exprs_start + i]));
            }
        },
        .if_expr => {
            const ife = ast.if_exprs.items[data];
            try collectCapturesExpr(gpa, ast, ctx, bound, out, ife.cond);
            if (ife.let_binding != 0) try bound.put(gpa, ife.let_binding, {});
            try collectCapturesExpr(gpa, ast, ctx, bound, out, ife.then_block);
            if (!ife.else_branch.isNone()) try collectCapturesExpr(gpa, ast, ctx, bound, out, ife.else_branch);
        },
        .block_expr => {
            const blk = ast.block_exprs.items[data];
            try collectCapturesStmtRun(gpa, ast, ctx, bound, out, blk.body_start, blk.body_len);
            if (!blk.value.isNone()) try collectCapturesExpr(gpa, ast, ctx, bound, out, blk.value);
        },
        .loop_expr => {
            const lp = ast.loop_exprs.items[data];
            try collectCapturesStmtRun(gpa, ast, ctx, bound, out, lp.body_start, lp.body_len);
        },
        // Match arms (pattern bindings), nested closures, ECS accessors
        // (`entity.get` — cross-fn world machinery) and anything else inside
        // a closure body stay deferred: fail loud, interpreter reference.
        else => return CodegenError.UnsupportedConstruct,
    }
}

fn collectCapturesStmtRun(
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    ctx: *const LocalCtx,
    bound: *std.AutoHashMapUnmanaged(StringId, void),
    out: *std.ArrayListUnmanaged(Capture),
    start: u32,
    len: u32,
) CodegenError!void {
    var s: u32 = 0;
    while (s < len) : (s += 1) {
        const stmt_id: NodeId = @bitCast(ast.extra.items[start + s]);
        const data = ast.stmtData(stmt_id);
        switch (ast.stmtKind(stmt_id)) {
            .let_stmt => {
                const let = ast.let_stmts.items[data];
                try collectCapturesExpr(gpa, ast, ctx, bound, out, let.value);
                try bound.put(gpa, let.name, {});
            },
            .assign_stmt => {
                const a = ast.assign_stmts.items[data];
                try collectCapturesExpr(gpa, ast, ctx, bound, out, a.target);
                try collectCapturesExpr(gpa, ast, ctx, bound, out, a.value);
            },
            .expr_stmt => try collectCapturesExpr(gpa, ast, ctx, bound, out, @bitCast(data)),
            .return_stmt => {
                const value: NodeId = @bitCast(data);
                if (!value.isNone()) try collectCapturesExpr(gpa, ast, ctx, bound, out, value);
            },
            .throw_stmt => try collectCapturesExpr(gpa, ast, ctx, bound, out, ast.throw_stmts.items[data].value),
            .assert_stmt => try collectCapturesExpr(gpa, ast, ctx, bound, out, ast.assert_stmts.items[data].cond),
            .break_stmt => {
                const b = ast.break_stmts.items[data];
                if (!b.value.isNone()) try collectCapturesExpr(gpa, ast, ctx, bound, out, b.value);
            },
            .continue_stmt => {},
            .while_stmt => {
                const wh = ast.while_stmts.items[data];
                if (wh.let_binding != 0) try bound.put(gpa, wh.let_binding, {});
                try collectCapturesExpr(gpa, ast, ctx, bound, out, wh.cond);
                try collectCapturesStmtRun(gpa, ast, ctx, bound, out, wh.body_start, wh.body_len);
            },
            .for_stmt => {
                const f = ast.for_stmts.items[data];
                try collectCapturesExpr(gpa, ast, ctx, bound, out, f.iterable);
                try bound.put(gpa, f.var_name, {});
                if (f.index_name != 0) try bound.put(gpa, f.index_name, {});
                try collectCapturesStmtRun(gpa, ast, ctx, bound, out, f.body_start, f.body_len);
            },
            .try_catch_stmt => {
                const tc = ast.try_catch_stmts.items[data];
                try collectCapturesStmtRun(gpa, ast, ctx, bound, out, tc.try_start, tc.try_len);
                try bound.put(gpa, tc.catch_name, {});
                try collectCapturesStmtRun(gpa, ast, ctx, bound, out, tc.catch_start, tc.catch_len);
            },
            // `emit` inside a closure body needs the rule fn's `world`
            // param — cross-fn; deferred (interpreter reference), as is any
            // statement kind not listed.
            else => return CodegenError.UnsupportedConstruct,
        }
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
    // `string?` (M0.8 E3-C tranche 4): `string` is deliberately not in
    // `type_map.mapBuiltin` (the let-routing leaves plain string bindings
    // un-annotated) — only the optional path needs its Zig spelling.
    if (std.mem.eql(u8, tname, "string")) return optionalOf("[]const u8");
    return optionalOf(type_map.mapBuiltin(tname) orelse return null);
}

/// Map a builtin Zig scalar type to its `?`-prefixed optional literal (M0.8 E2
/// block 5; string payloads tranche 4). Returns `null` for any other payload.
fn optionalOf(zig_scalar: []const u8) ?[]const u8 {
    const pairs = .{
        .{ "i64", "?i64" },       .{ "f64", "?f64" },               .{ "bool", "?bool" },
        .{ "i32", "?i32" },       .{ "u32", "?u32" },               .{ "f32", "?f32" },
        .{ "Entity", "?Entity" }, .{ "[]const u8", "?[]const u8" },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, zig_scalar, p[0])) return p[1];
    }
    return null;
}

/// The Zig declaration type of an Etch dynamic-array local `E[]` (M0.8 E3-C
/// tranche 3) — a frame-arena-backed list. The table is closed over the E1
/// builtin element scalars (+ string); any other element type is deferred
/// (fail loud). Static strings keep the emitter allocation-free and make the
/// reverse lookup (`dynArrayElemZig`) exact.
fn dynArrayZigType(elem_zig: []const u8) ?[]const u8 {
    inline for (dyn_array_types) |p| {
        if (std.mem.eql(u8, elem_zig, p[0])) return p[1];
    }
    return null;
}

/// Reverse of `dynArrayZigType`: the element Zig type of a dynamic-array
/// local's declaration type, or `null` when the type is not one the emitter
/// produced. Drives the method / index / for-in routing on a receiver's
/// inferred type.
fn dynArrayElemZig(zig_t: []const u8) ?[]const u8 {
    inline for (dyn_array_types) |p| {
        if (std.mem.eql(u8, zig_t, p[1])) return p[0];
    }
    return null;
}

const dyn_array_types = .{
    .{ "i64", "std.ArrayListUnmanaged(i64)" },
    .{ "f64", "std.ArrayListUnmanaged(f64)" },
    .{ "bool", "std.ArrayListUnmanaged(bool)" },
    .{ "[]const u8", "std.ArrayListUnmanaged([]const u8)" },
};

/// The Zig declaration type of an Etch map local `[K: V]` (M0.8 E3-C tranche
/// 3) — an insertion-ordered key/value pair list, mirroring the interpreter's
/// map store so iteration order (and therefore every differential) is
/// byte-exact by construction. Keys are bounded to `int`/`bool`: string keys
/// need content equality (Eq on strings is deferred with the same policy as
/// tranche 1) and float keys are not hashable per stdlib §4.3 — both fail
/// loud here, the interpreter staying the reference.
fn mapZigType(key_zig: []const u8, value_zig: []const u8) ?[]const u8 {
    inline for (map_types_table) |p| {
        if (std.mem.eql(u8, key_zig, p[0]) and std.mem.eql(u8, value_zig, p[1])) return p[2];
    }
    return null;
}

/// Reverse of `mapZigType`: the (key, value) Zig types of a map local's
/// declaration type, or `null`.
fn mapKVZig(zig_t: []const u8) ?struct { key: []const u8, value: []const u8 } {
    inline for (map_types_table) |p| {
        if (std.mem.eql(u8, zig_t, p[2])) return .{ .key = p[0], .value = p[1] };
    }
    return null;
}

const map_types_table = .{
    .{ "i64", "i64", "std.ArrayListUnmanaged(struct { key: i64, value: i64 })" },
    .{ "i64", "f64", "std.ArrayListUnmanaged(struct { key: i64, value: f64 })" },
    .{ "i64", "bool", "std.ArrayListUnmanaged(struct { key: i64, value: bool })" },
    .{ "i64", "[]const u8", "std.ArrayListUnmanaged(struct { key: i64, value: []const u8 })" },
    .{ "bool", "i64", "std.ArrayListUnmanaged(struct { key: bool, value: i64 })" },
    .{ "bool", "f64", "std.ArrayListUnmanaged(struct { key: bool, value: f64 })" },
    .{ "bool", "bool", "std.ArrayListUnmanaged(struct { key: bool, value: bool })" },
    .{ "bool", "[]const u8", "std.ArrayListUnmanaged(struct { key: bool, value: []const u8 })" },
};

/// The list declaration type for a `T[]` slice annotation with a builtin
/// scalar element (M0.8 E3-C tranche 3), or `null` (non-named / non-scalar
/// element → the caller fails loud).
fn sliceAnnotationListType(ast: *const AstArena, annotation: NodeId) ?[]const u8 {
    const at = ast.array_types.items[ast.typeNodeData(annotation)];
    if (ast.typeNodeKind(at.elem) != .named) return null;
    const named = ast.named_types.items[ast.typeNodeData(at.elem)];
    const elem_zig = type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(named.name))) orelse return null;
    return dynArrayZigType(elem_zig);
}

/// The list declaration type for a `[K: V]` map annotation (M0.8 E3-C tranche
/// 3), or `null` when the key/value pair is outside the emitter's map table.
fn mapAnnotationListType(ast: *const AstArena, annotation: NodeId) ?[]const u8 {
    const mt = ast.map_types.items[ast.typeNodeData(annotation)];
    if (ast.typeNodeKind(mt.key) != .named or ast.typeNodeKind(mt.value) != .named) return null;
    const knamed = ast.named_types.items[ast.typeNodeData(mt.key)];
    const vnamed = ast.named_types.items[ast.typeNodeData(mt.value)];
    const key_zig = type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(knamed.name))) orelse return null;
    const value_zig = type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(vnamed.name))) orelse return null;
    return mapZigType(key_zig, value_zig);
}

/// The Zig declaration type of an Etch set local `Set<T>` (M0.8 E3-C tranche
/// 3bis) — an insertion-ordered single-field element list, mirroring the
/// interpreter's set store so element order (and therefore every
/// differential) is byte-exact by construction. The `struct { item: T }`
/// wrapper keeps the type distinct from the dyn-array list types — the
/// method / index / for-in routing is keyed on the emitted declaration type.
/// Elements are bounded to `int`/`bool`: string elements need content
/// equality (deferred — the ratified tranche-3 map-key policy, interp
/// reference) and float elements are resolver-rejected (E0601).
fn setZigType(elem_zig: []const u8) ?[]const u8 {
    inline for (set_types_table) |p| {
        if (std.mem.eql(u8, elem_zig, p[0])) return p[1];
    }
    return null;
}

/// Reverse of `setZigType`: the element Zig type of a set local's
/// declaration type, or `null`.
fn setElemZig(zig_t: []const u8) ?[]const u8 {
    inline for (set_types_table) |p| {
        if (std.mem.eql(u8, zig_t, p[1])) return p[0];
    }
    return null;
}

const set_types_table = .{
    .{ "i64", "std.ArrayListUnmanaged(struct { item: i64 })" },
    .{ "bool", "std.ArrayListUnmanaged(struct { item: bool })" },
};

/// The list declaration type for a `Set<T>` annotation (M0.8 E3-C tranche
/// 3bis), or `null` when the element is outside the emitter's set table.
fn setAnnotationListType(ast: *const AstArena, annotation: NodeId) ?[]const u8 {
    const st = ast.set_types.items[ast.typeNodeData(annotation)];
    if (ast.typeNodeKind(st.elem) != .named) return null;
    const named = ast.named_types.items[ast.typeNodeData(st.elem)];
    const elem_zig = type_map.mapBuiltin(ast.strings.slice(ast.resolveTypeAliasName(named.name))) orelse return null;
    return setZigType(elem_zig);
}

/// The declared enum type name of struct field `field_name` on struct
/// `type_name`, or `null` when the field is not enum-typed (M0.8 E3-C
/// tranche 4) — drives the qualified emission of a bare `.variant`
/// field value (part1 §10.2).
fn structFieldEnumName(ast: *const AstArena, type_name: StringId, field_name: StringId) ?[]const u8 {
    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .struct_decl) continue;
        const sd = ast.struct_decls.items[ast.items.items(.data)[i]];
        if (sd.name != type_name) continue;
        var f_i: u32 = 0;
        while (f_i < sd.fields_len) : (f_i += 1) {
            const f = ast.fields.items[sd.fields_start + f_i];
            if (f.name != field_name) continue;
            if (ast.typeNodeKind(f.type_node) != .named) return null;
            const named = ast.named_types.items[ast.typeNodeData(f.type_node)];
            const resolved = ast.resolveTypeAliasName(named.name);
            if (!isEnumName(ast, resolved)) return null;
            return ast.strings.slice(resolved);
        }
        return null;
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

/// `true` if `name` is a declared `struct` (M0.8 E3-C tranche 8).
fn isStructName(ast: *const AstArena, name: StringId) bool {
    var i: usize = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .struct_decl) continue;
        if (ast.struct_decls.items[ast.items.items(.data)[i]].name == name) return true;
    }
    return false;
}

/// Emit a struct literal as the qualified Zig `TypeName{ .f = v, … }` (M0.8
/// E2 block 3; split out in E3-C tranche 8 so the anonymous `.{ … }` form
/// emits through the same point with the name supplied by its context — the
/// same logical point as the resolver's check mode and the interp's
/// `evalStructLitAs`). Omitted fields fall back to the `extern struct`
/// declared defaults.
fn emitStructLitAs(w: *Writer, ast: *const AstArena, ctx: *LocalCtx, sl: ast_mod.StructLitExpr, type_name: StringId) CodegenError!void {
    try w.print("{s}{{", .{ast.strings.slice(type_name)});
    var i: u32 = 0;
    while (i < sl.fields_len) : (i += 1) {
        const flit = ast.struct_lit_fields.items[sl.fields_start + i];
        if (i > 0) try w.write(",");
        try w.write(" .");
        try w.ident(ast.strings.slice(flit.name));
        try w.write(" = ");
        // Bare `.variant` shorthand in field-value position (M0.8
        // E3-C tranche 4, part1 §10.2): qualified `EnumName.variant`
        // from the field's declared enum type — the same
        // declared-type lookup as the interp's struct-literal
        // resolution. A tag_path on a non-enum field has no Zig
        // value — fail loud (the resolver already rejects it).
        if (ast.exprKind(flit.value) == .tag_path) {
            // Expression-position `tag_path` data IS the variant
            // ident (multi-segment is a parse error there).
            const ename = structFieldEnumName(ast, type_name, flit.name) orelse return CodegenError.UnsupportedConstruct;
            try w.print("{s}.", .{ename});
            try w.ident(ast.strings.slice(ast.exprData(flit.value)));
            continue;
        }
        // Anonymous `.{ … }` in field-value position (M0.8 E3-C tranche 8):
        // qualified recursively from the field's declared struct type — the
        // same declared-type lookup as the interp's resolution.
        if (ast.exprKind(flit.value) == .struct_lit) {
            const inner = ast.struct_lits.items[ast.exprData(flit.value)];
            if (inner.type_name == 0) {
                const sname = structFieldStructName(ast, type_name, flit.name) orelse return CodegenError.UnsupportedConstruct;
                try emitStructLitAs(w, ast, ctx, inner, sname);
                continue;
            }
        }
        try emitExpr(w, ast, ctx, flit.value);
    }
    try w.write(" }");
}

/// The declared struct type name of struct field `field_name` on struct
/// `type_name`, or `null` when the field is not struct-typed (M0.8 E3-C
/// tranche 8) — drives the qualified emission of an anonymous `.{ … }`
/// field value, mirroring `structFieldEnumName`.
fn structFieldStructName(ast: *const AstArena, type_name: StringId, field_name: StringId) ?StringId {
    var i: u28 = 0;
    while (i < ast.items.len) : (i += 1) {
        if (ast.items.items(.kind)[i] != .struct_decl) continue;
        const sd = ast.struct_decls.items[ast.items.items(.data)[i]];
        if (sd.name != type_name) continue;
        var f_i: u32 = 0;
        while (f_i < sd.fields_len) : (f_i += 1) {
            const f = ast.fields.items[sd.fields_start + f_i];
            if (f.name != field_name) continue;
            if (ast.typeNodeKind(f.type_node) != .named) return null;
            const named = ast.named_types.items[ast.typeNodeData(f.type_node)];
            const resolved = ast.resolveTypeAliasName(named.name);
            if (!isStructName(ast, resolved)) return null;
            return resolved;
        }
        return null;
    }
    return null;
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

/// Re-emit an Etch string literal's raw bytes as a valid Zig string literal
/// (M0.8 sub-slice C tranche 1). Escapes the quote / backslash / common
/// control bytes; any other non-printable byte becomes `\xHH`.
fn emitZigStringLiteral(w: *Writer, bytes: []const u8) CodegenError!void {
    try w.write("\"");
    for (bytes) |c| {
        switch (c) {
            '"' => try w.write("\\\""),
            '\\' => try w.write("\\\\"),
            '\n' => try w.write("\\n"),
            '\r' => try w.write("\\r"),
            '\t' => try w.write("\\t"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.buffer.append(w.gpa, c);
                }
            },
        }
    }
    try w.write("\"");
}

/// Write one interpolation segment into the `std.fmt` format string being
/// emitted (M0.8 E3-C tranche 1c): the same byte escaping as
/// `emitZigStringLiteral` (without the surrounding quotes) plus `{`/`}`
/// doubling, since the destination is a format string.
fn emitFmtSegment(w: *Writer, bytes: []const u8) CodegenError!void {
    for (bytes) |c| {
        switch (c) {
            '"' => try w.write("\\\""),
            '\\' => try w.write("\\\\"),
            '\n' => try w.write("\\n"),
            '\r' => try w.write("\\r"),
            '\t' => try w.write("\\t"),
            '{' => try w.write("{{"),
            '}' => try w.write("}}"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.buffer.append(w.gpa, c);
                }
            },
        }
    }
}

fn inferExprZigType(ast: *const AstArena, ctx: *LocalCtx, expr: NodeId) []const u8 {
    const kind = ast.exprKind(expr);
    const data = ast.exprData(expr);
    return switch (kind) {
        .int_lit => "i64",
        .float_lit => "f64",
        .bool_lit => "bool",
        // String (M0.8 sub-slice C tranche 1) → `[]const u8`; drives the
        // string-receiver dispatch in the `method_call` emit. Interpolation
        // (tranche 1c) produces a string too.
        .string_lit, .string_interp => "[]const u8",
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
                // `a ?? b` unwraps the lhs optional (M0.8 E3-C tranche 4):
                // strip the `?` when known, else fall back to the default's
                // type.
                .coalesce => {
                    const lz = inferExprZigType(ast, ctx, b.lhs);
                    if (lz.len > 1 and lz[0] == '?') break :blk lz[1..];
                    break :blk inferExprZigType(ast, ctx, b.rhs);
                },
                else => inferExprZigType(ast, ctx, b.lhs),
            };
        },
        .unary => blk: {
            const u = ast.unary_exprs.items[data];
            break :blk switch (u.op) {
                .logical_not => "bool",
                .neg => inferExprZigType(ast, ctx, u.operand),
                // `expr!` unwraps the operand optional (M0.8 E3-C tranche 4).
                .force_unwrap => {
                    const oz = inferExprZigType(ast, ctx, u.operand);
                    if (oz.len > 1 and oz[0] == '?') break :blk oz[1..];
                    break :blk "";
                },
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
                // A resource alias resolves field types the same way — the
                // registry-backed decl lookup covers resource decls too.
                if (local.kind == .component_alias or local.kind == .resource_alias) break :blk local.component_name;
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
                // A non-named field type (`Error?` — the builtin Error's
                // `source`) has no scalar Zig name; the caller falls back.
                // Guards the `named_types` mis-index too (M0.8 E3-C tranche 2).
                if (ast.typeNodeKind(f.type_node) != .named) return null;
                const tnode = ast.named_types.items[ast.typeNodeData(f.type_node)];
                const resolved = ast.resolveTypeAliasName(tnode.name);
                const etch_t = ast.strings.slice(resolved);
                // `string` fields (`Error.message`) → the codegen string
                // type, driving `.len()` dispatch; enum-typed fields
                // (`Error.code`) map 1:1, driving the match shorthand
                // (M0.8 E3-C tranche 2).
                if (std.mem.eql(u8, etch_t, "string")) return "[]const u8";
                if (isEnumName(ast, resolved)) return etch_t;
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
                // `expr!` needs a runtime optional — never const-evaluable.
                .force_unwrap => return CodegenError.UnsupportedConstruct,
            }
        },
        else => return CodegenError.UnsupportedConstruct,
    }
}

// ─── `tick` ─────────────────────────────────────────────────────────────────

fn emitTick(w: *Writer, rules: []const RuleEmit, program_has_changed: bool) CodegenError!void {
    var any_tag_mutation = false;
    var any_observer = false;
    var any_arena = false;
    for (rules) |r| {
        if (r.tag_mutating) any_tag_mutation = true;
        if (r.event_type != null) any_observer = true;
        if (r.needs_arena) any_arena = true;
    }

    try w.line("/// Execute every rule once in source declaration order, apply any");
    try w.line("/// deferred tag mutations, then clear resource dirty bits —");
    try w.line("/// equivalent to a single tick of the S4 interpreter's `stepOnce`");
    try w.line("/// (rules + `flushPendingTags`) + `tickBoundary`. `gpa` is the");
    try w.line("/// uniform allocator-threading contract for the generated code");
    try w.line("/// (M0.8 E3); the tag command buffer and the per-tick frame arena");
    try w.line("/// (string concat results — `etch-memory-model.md` §3) consume it.");
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
    }
    if (any_arena) {
        // Frame arena (M0.8 E3-C tranche 1b, `etch-memory-model.md` §3 /
        // abi-zig §5.6): transient non-POD allocations (string concat) live
        // here, threaded into arena-needing rule fns as `fa`. Arena-per-tick
        // mounted on the threaded gpa = reset-at-tick-boundary by
        // construction (deinit when `tick` returns). The interpreter's
        // per-body string-store reset is finer-grained but observably
        // identical — strings never enter the POD world state.
        try w.line("var __frame = std.heap.ArenaAllocator.init(gpa);");
        try w.line("defer __frame.deinit();");
    }
    if (!any_tag_mutation and !any_arena) {
        // No tag mutation, no frame arena → the threaded gpa is unused this
        // tick (event drain / subscribe / poll need no allocator).
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
            if (r.needs_arena) {
                try w.printLine("rule_{s}(world, &cmd, __frame.allocator());", .{r.name});
            } else {
                try w.printLine("rule_{s}(world, &cmd);", .{r.name});
            }
        } else if (r.event_type != null) {
            if (r.needs_arena) {
                try w.printLine("rule_{s}(world, &__evcur_{d}, __frame.allocator());", .{ r.name, i });
            } else {
                try w.printLine("rule_{s}(world, &__evcur_{d});", .{ r.name, i });
            }
        } else if (r.needs_arena) {
            try w.printLine("rule_{s}(world, __frame.allocator());", .{r.name});
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
