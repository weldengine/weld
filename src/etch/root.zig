//! Public surface of the `weld_etch` module — the S3 Etch parser + minimal
//! type-checker. Designed to survive Phase 0.2 with additive changes only
//! per `briefs/S3-etch-parser-subset.md` Scope / Public surface.
//!
//! High-level helpers:
//! - `parse(gpa, source) !ParseResult` — runs the lexer + parser, returns
//!   the AST plus at most one parse diagnostic.
//! - `typeCheck(gpa, ast, diags_out) !void` — runs pass 1 + pass 2 on a
//!   resolved arena, accumulating diagnostics in `diags_out`.
//!
//! No public type exposes parser internal state, allocator-stored fields,
//! or pointers into the arena.

const std = @import("std");

const lexer = @import("lexer.zig");
/// Exposed at the module surface so callers can drive the parser
/// incrementally (LSP, future Phase 0.2 hybrid LR(1)+Pratt). The
/// recursive-descent entry `parser.parse` is the canonical batch path.
pub const parser = @import("parser.zig");
const ast = @import("ast.zig");
/// Exposed at the module surface so the S5 codegen and Phase 0.2
/// passes can iterate the AST through the type-checker's pass 2
/// without re-importing the internals.
pub const types = @import("types.zig");
/// Exposed at the module surface so callers can construct / inspect
/// `Diagnostic` values (build a tooling test harness, assert
/// `DiagnosticCode`s) without pulling the internals directly.
pub const diagnostics = @import("diagnostics.zig");

// S4 interpreter surface.
const value = @import("value.zig");
const ecs_bridge = @import("ecs_bridge.zig");
const interp = @import("interp.zig");

// Pull the S4 interpreter surface files into the module's test import graph
// so `zig build test` collects their inline tests. The type aliases below
// (`Interpreter`, `RuntimeReport`) reference `interp.zig`'s declarations but
// do NOT force analysis of these files' `test` blocks — under Zig 0.16 lazy
// analysis a referenced declaration pulls only that declaration, not the
// containing file's tests (`engine-zig-conventions.md` §13). Without this
// guard `interp.zig` (the file these very change-detection tests live in),
// `value.zig` and `ecs_bridge.zig` are silently skipped by the test runner.
// Mirrors the same reference-guard idiom in `zig_codegen/root.zig`.
comptime {
    _ = @import("interp.zig");
    _ = @import("value.zig");
    _ = @import("ecs_bridge.zig");
    // M1.0.5 — `persistent.zig` moved to Tier 0 (`src/core/memory`); it is now
    // pinned by `src/core/memory/root.zig` (reached here via `weld_core.memory`).
    // M1.0.4 — pull the scene cook driver into the test import graph (§13).
    _ = @import("scene_cook.zig");
}

/// M1.0.4 scene cook — `.scene.etch` source → the neutral Tier-0 scene model
/// (`weld_core.scene.format.CookModel`) the writer serializes to `.scene.bin`.
/// World-free: registers types into a standalone RTTI `Registry` and const-evals
/// the scene's values. Imports `weld_core.scene`; the Tier-0 side never imports
/// `weld_etch` (tier discipline).
pub const scene_cook = @import("scene_cook.zig");

/// S5 Zig codegen surface — exposed at the module surface so
/// `tools/etch_cook` and downstream consumers can drive the codegen
/// without depending on the internal path layout.
pub const codegen_zig = @import("zig_codegen/root.zig");

/// Level-B descriptor surface (M0.8 E4) — typed domain descriptors
/// (`etch-ast-ir.md` §3.5) + the canonical serializer backing the
/// serialized-IR differential. The interpreter builds them at compile
/// (`Interpreter.descriptors`); the differential harness serializes both
/// backends through this surface.
pub const descriptor = @import("descriptor.zig");

/// Exposed at the module surface so out-of-tree spike tests that
/// drive the lexer alone (without a full parser run) can construct
/// one without depending on the internal path.
pub const Lexer = lexer.Lexer;
/// Exposed at the module surface so the corpus driver and the
/// codegen / interpreter runners can declare `*Ast` parameters
/// without pulling the internal path.
pub const Ast = ast.AstArena;
/// Public entry point of the type-checker. Consumers drive pass 1 +
/// pass 2 through this single struct; the internal pass functions
/// remain hidden.
pub const TypeChecker = types.TypeChecker;
/// Public diagnostic type — consumers store, format, and propagate
/// `Diagnostic` values across the parser / type-checker boundary.
pub const Diagnostic = diagnostics.Diagnostic;

/// Public entry point of the S4 tree-walking interpreter. Consumers
/// instantiate one per Etch program and drive ticks through it.
pub const Interpreter = interp.Interpreter;
/// Public tick-level report — exposed at the surface so bench
/// harnesses and the corpus driver can assert against
/// `entities_iterated` / `rules_matched` without reaching into the
/// interpreter internals.
pub const RuntimeReport = interp.RuntimeReport;

// ───────────────────────────────────────────────────────────────────────────
// AST stable interface — Level 1 (frozen cross-phase)
//
// Mirrors `etch-parser.md` §10.3.1 "Interface contract stable cross-phase".
// M0.8 (the full v0.6 grammar) settles every Item/Stmt/Expr/TypeNode kind
// variant, so the public AST surface is frozen HERE: the Phase 1 / S0 parser
// rewrite (recursive-descent → LR(1)) must preserve this surface byte-for-byte
// so the ~5000 lines of consumers (interpreter, codegen, ECS bridge, validate,
// LS) compile unchanged.
//
// FROZEN — Level 1 (a removal/rename is a breaking change forbidden Phase 0 →
// Phase 1; ADDING an enum variant or an accessor is non-breaking):
//
//   • Discrimination enums — `ItemKind`, `StmtKind`, `ExprKind`,
//     `TypeNodeKind`, `BinaryOp`, `UnaryOp`, `AssignOp`, `NodeCategory`.
//   • Node handle / intern — `NodeId` (packed struct(u32){ category, index };
//     `.none`, `.isNone()`, `.raw()`), `StringId` (= u32).
//   • Span value — `SourceSpan { byte_start: u32, byte_end: u32 }`.
//   • Accessors on `Ast` (= AstArena), all `pub`: the per-category
//     kind/data/span triplets (`itemKind`/`itemData`/`itemSpan`,
//     `stmtKind`/…, `exprKind`/…, `typeNodeKind`/…), `isEmpty()`, the
//     `items`/`stmts`/`exprs`/`type_nodes` SoA columns, the `strings` intern
//     pool (`strings.slice(id)` → []const u8, `.find`, `.intern`), and
//     `docCommentsOf`/`leadingCommentsOf`.
//
// NOT frozen — Level 2 (Phase 1 may mutate freely): the `NodeId` 4+28-bit
// packing, the `MultiArrayList` column layout, the `extra` slabs, the `add*`
// builder methods (parser-side writes, not consumer reads).
//
// NOTE — §10.3.1 drift (KB-patch at M0.8 close): the spec prose names an
// idealized single `NodeKind` (~150 variants) + a `LiteralKind` + four tagged
// unions (`TopLevelDecl`/`Expression`/`Statement`/`Type`). The delivered AST is
// a tabular SoA instead: the FOUR per-category kind enums above are the
// discriminators, `NodeId` is the universal handle, literals are variants of
// `ExprKind`, and consumers discriminate via `arena.<cat>Kind(id)` +
// `arena.<cat>Data(id)` (no union switch). The contract above is the REAL
// frozen surface; §10.3.1 is to be re-aligned to the SoA reality at the close.
//
// Guard: `tests/etch/ast_stable_interface.zig` exercises ≥20 distinct Level-1
// entry points; its COMPILATION is the invariant. A Phase 1 change that breaks
// it blocks the LR transition and demands an explicit AST-API semver bump.
// ───────────────────────────────────────────────────────────────────────────

/// Frozen Level-1 discriminator for top-level declarations.
pub const ItemKind = ast.ItemKind;
/// Frozen Level-1 discriminator for statements.
pub const StmtKind = ast.StmtKind;
/// Frozen Level-1 discriminator for expressions (literals are variants here).
pub const ExprKind = ast.ExprKind;
/// Frozen Level-1 discriminator for type nodes.
pub const TypeNodeKind = ast.TypeNodeKind;
/// Frozen Level-1 binary-operator tag.
pub const BinaryOp = ast.BinaryOp;
/// Frozen Level-1 unary-operator tag.
pub const UnaryOp = ast.UnaryOp;
/// Frozen Level-1 assignment-operator tag.
pub const AssignOp = ast.AssignOp;
/// Frozen Level-1 node category selecting which kind enum / table applies.
pub const NodeCategory = ast.NodeCategory;
/// Frozen Level-1 universal node handle (packed struct(u32){ category, index }).
pub const NodeId = ast.NodeId;
/// Frozen Level-1 opaque string-intern handle (= u32).
pub const StringId = ast.StringId;
/// Frozen Level-1 span value — the return type of every `Ast` span accessor.
pub const SourceSpan = @import("token.zig").SourceSpan;

/// Parse a full Etch source file. The returned `ParseResult` owns its
/// `AstArena` and its `diagnostics` slice — call `result.deinit(gpa)`
/// when done (or move `ast` / `diagnostics` out and free them yourself).
/// With the M0.8 top-level recovery sync-point the result may carry
/// several diagnostics (one per broken construct); an empty slice means a
/// clean parse.
pub fn parseSource(gpa: std.mem.Allocator, source: []const u8) !parser.ParseResult {
    return try parser.parse(gpa, source);
}

/// Run pass 1 + pass 2 of the S3 type-checker on an already-parsed AST.
/// Accumulates diagnostics in `diags_out` (caller-owned). Each appended
/// diagnostic owns its `primary_message` slice.
pub fn typeCheck(gpa: std.mem.Allocator, arena: *Ast, diags_out: *std.ArrayListUnmanaged(Diagnostic)) !void {
    try TypeChecker.check(gpa, arena, diags_out);
}

/// One source file of a multi-file Etch project, fed to `validateProject`.
/// `name` is the caller's label (path); the validator does not interpret it.
pub const ProjectFile = struct {
    name: []const u8,
    source: []const u8,
};

/// Module path of a project file from its `ProjectFile.name` (path under `src/`,
/// `etch-reference-part1.md` §1.1): strip an optional leading `src/`, strip the
/// file extension (a typed compound `.scene.etch`/`.prefab.etch`/`.layer.etch`/
/// `.manifest.etch`/`.d.etch` if present, else plain `.etch`), and map `/`→`.`.
/// The returned slice is `gpa`-owned. Typed-extension files (scene/prefab/…) take
/// their basename as the module label; they are never import *targets* (they
/// declare no top-level types — only one scene/prefab + imports), so the label
/// only identifies them as nodes in the dependency graph (M1.0.7 E4).
fn deriveModulePath(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var s = name;
    if (std.mem.startsWith(u8, s, "src/")) s = s["src/".len..];
    const typed_exts = [_][]const u8{ ".d.etch", ".scene.etch", ".prefab.etch", ".layer.etch", ".manifest.etch" };
    var stripped = false;
    for (typed_exts) |ext| {
        if (std.mem.endsWith(u8, s, ext)) {
            s = s[0 .. s.len - ext.len];
            stripped = true;
            break;
        }
    }
    if (!stripped and std.mem.endsWith(u8, s, ".etch")) s = s[0 .. s.len - ".etch".len];
    const out = try gpa.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return out;
}

/// The dotted module path an `ImportDecl` references (`import a.b.c` → `"a.b.c"`),
/// joined from its `import_path_segs` run. `gpa`-owned (M1.0.7 E4).
fn joinImportPath(gpa: std.mem.Allocator, a: *const Ast, decl: ast.ImportDecl) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < decl.path_len) : (i += 1) {
        if (i != 0) try buf.append(gpa, '.');
        try buf.appendSlice(gpa, a.strings.slice(a.import_path_segs.items[decl.path_start + i]));
    }
    return try buf.toOwnedSlice(gpa);
}

/// Cross-file scene/prefab validation (M0.9 E2-B). Parses every project file,
/// builds the byte-keyed global prefab-name index and a shared cross-scene
/// UUID tracker, then type-checks each file with that project context so the
/// three cross-file diagnostics resolve across the whole set:
///   - `E1786 PrefabRefNotFound` — `instance of "X"` where no project file
///     declares prefab `X`.
///   - `E1791 PrefabBaseNotFound` — `prefab "Y" of/extends "Z"` where no
///     project file declares prefab `Z`.
///   - `E1782 DuplicateUUID` (cross-scene) — the same entity/instance UUID in
///     two scenes (same or different file).
///
/// Every file's parse + type-check diagnostics accumulate in `diags_out`
/// (caller-owned; each owns its `primary_message`). Bounded to the E2-B sizing
/// guard — enumerate files, index prefab names + scene UUIDs, resolve the three
/// references. No general dependency graph, no watch mode, no incremental
/// invalidation.
pub fn validateProject(
    gpa: std.mem.Allocator,
    files: []const ProjectFile,
    diags_out: *std.ArrayListUnmanaged(Diagnostic),
) !void {
    // Parse every file up front; the arenas stay alive for the whole pass so
    // the byte-keyed indexes below can reference their interned strings.
    var asts: std.ArrayListUnmanaged(Ast) = .empty;
    defer {
        for (asts.items) |*a| a.deinit(gpa);
        asts.deinit(gpa);
    }
    try asts.ensureTotalCapacity(gpa, files.len);
    for (files) |f| {
        const pr = try parser.parse(gpa, f.source);
        // Move each parse diagnostic into diags_out (its gpa-owned message
        // transfers), then free only the now-vacated backing slice — never
        // `pr.deinit`, which would double-free the arena we keep below.
        for (pr.diagnostics) |d| try diags_out.append(gpa, d);
        gpa.free(pr.diagnostics);
        asts.appendAssumeCapacity(pr.ast);
    }

    // Global byte-keyed prefab-name index (E1786 / E1791). Keys reference the
    // arenas' string pools; the maps free before the arenas (LIFO defers).
    var prefabs: std.StringHashMapUnmanaged(void) = .empty;
    defer prefabs.deinit(gpa);
    for (asts.items) |*a| {
        const kinds = a.items.items(.kind);
        const datas = a.items.items(.data);
        var i: usize = 0;
        while (i < a.items.len) : (i += 1) {
            if (kinds[i] != .prefab_decl) continue;
            const decl = a.prefab_decls.items[datas[i]];
            try prefabs.put(gpa, a.strings.slice(decl.name), {});
        }
    }

    // Shared cross-scene UUID tracker (E1782): the first occurrence of a UUID
    // is recorded, a later one is the duplicate.
    var uuids: std.StringHashMapUnmanaged(void) = .empty;
    defer uuids.deinit(gpa);

    // ── M1.0.7 E4 — module graph + topological order + cycle detection ──
    // Derive each file's module path and build module-path → index map.
    const n = asts.items.len;
    var module_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (module_paths.items) |p| gpa.free(p);
        module_paths.deinit(gpa);
    }
    try module_paths.ensureTotalCapacity(gpa, n);
    var module_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer module_index.deinit(gpa);
    for (files, 0..) |f, idx| {
        const mp = try deriveModulePath(gpa, f.name);
        module_paths.appendAssumeCapacity(mp);
        // A duplicate module path (an out-of-scope edge case) maps to the last
        // file; E4 only needs a consistent node identity for the graph.
        try module_index.put(gpa, mp, idx);
    }

    // Build the directed import-dependency graph: edge importer → imported, for
    // each import whose target module resolves to a file in the set. Targets that
    // resolve to no file are an E5 concern (E0103/E0104), not a cycle edge.
    const Edge = struct { to: usize, span: SourceSpan };
    var adj: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Edge)) = .empty;
    defer {
        for (adj.items) |*lst| lst.deinit(gpa);
        adj.deinit(gpa);
    }
    try adj.ensureTotalCapacity(gpa, n);
    for (0..n) |_| adj.appendAssumeCapacity(.empty);
    for (asts.items, 0..) |*a, u| {
        const kinds = a.items.items(.kind);
        const datas = a.items.items(.data);
        const spans = a.items.items(.span);
        var i: usize = 0;
        while (i < a.items.len) : (i += 1) {
            if (kinds[i] != .import_decl) continue;
            const decl = a.import_decls.items[datas[i]];
            const target_path = try joinImportPath(gpa, a, decl);
            defer gpa.free(target_path);
            if (module_index.get(target_path)) |v| {
                try adj.items[u].append(gpa, .{ .to = v, .span = spans[i] });
            }
        }
    }

    // Iterative DFS: post-order yields a dependencies-first topological order; a
    // back-edge (to a gray/on-stack node) closes a cycle → E0108 pointing at the
    // import that closes the loop. White = 0, gray = 1, black = 2.
    const colors = try gpa.alloc(u8, n);
    defer gpa.free(colors);
    @memset(colors, 0);
    var order: std.ArrayListUnmanaged(usize) = .empty;
    defer order.deinit(gpa);
    try order.ensureTotalCapacity(gpa, n);
    const Frame = struct { node: usize, ei: usize };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(gpa);
    var cycle_found = false;
    for (0..n) |start| {
        if (colors[start] != 0) continue;
        colors[start] = 1;
        stack.clearRetainingCapacity();
        try stack.append(gpa, .{ .node = start, .ei = 0 });
        while (stack.items.len > 0) {
            const frame = &stack.items[stack.items.len - 1];
            const edges = adj.items[frame.node].items;
            if (frame.ei < edges.len) {
                const edge = edges[frame.ei];
                frame.ei += 1;
                switch (colors[edge.to]) {
                    0 => {
                        colors[edge.to] = 1;
                        try stack.append(gpa, .{ .node = edge.to, .ei = 0 });
                    },
                    1 => {
                        // Back-edge: `from` imports `to`, already on the stack.
                        cycle_found = true;
                        const from_node = frame.node;
                        const msg = try std.fmt.allocPrint(
                            gpa,
                            "import cycle detected: module '{s}' imports '{s}', which closes a cycle back to '{s}'",
                            .{ module_paths.items[from_node], module_paths.items[edge.to], module_paths.items[edge.to] },
                        );
                        errdefer gpa.free(msg);
                        try diags_out.append(gpa, .{
                            .code = .import_cycle,
                            .severity = .error_,
                            .primary_span = edge.span,
                            .primary_message = msg,
                        });
                    },
                    else => {}, // black: already finished, no cycle
                }
            } else {
                colors[frame.node] = 2;
                order.appendAssumeCapacity(frame.node);
                _ = stack.pop();
            }
        }
    }

    // Check each file with the project context. Acyclic → topological order so a
    // module's dependencies are checked first (M1.0.7 E6 exports collection);
    // on a cycle, fall back to input order (the graph has no valid linearization).
    const ctx: TypeChecker.ProjectContext = .{ .prefabs = &prefabs, .uuids = &uuids };
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const idx = if (cycle_found) k else order.items[k];
        try TypeChecker.checkProject(gpa, &asts.items[idx], diags_out, &ctx);
    }
}

test "public API builds + serializes a Level-B data descriptor (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseSource(gpa,
        \\struct Item { value: int }
        \\data Db: Item { a: { value: 1 } }
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    var descs = try descriptor.build(gpa, &result.ast);
    defer descs.deinit(gpa);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try descs.serialize(gpa, &out);
    try std.testing.expect(out.items.len > 0);
}

test "public API parses an empty source successfully" {
    const gpa = std.testing.allocator;
    var result = try parseSource(gpa, "");
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len == 0);
    try std.testing.expect(result.ast.isEmpty());
}

test "public API parses and type-checks a minimal component + rule" {
    const gpa = std.testing.allocator;
    var result = try parseSource(gpa,
        \\component Health { current: float = 100.0 }
        \\rule heal(entity: Entity)
        \\  when entity has Health
        \\{
        \\  entity.get_mut(Health).current += 1.0
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try typeCheck(gpa, &result.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
