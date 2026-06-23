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
    _ = @import("persistent.zig");
}

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

    const ctx: TypeChecker.ProjectContext = .{ .prefabs = &prefabs, .uuids = &uuids };
    for (asts.items) |*a| {
        try TypeChecker.checkProject(gpa, a, diags_out, &ctx);
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
