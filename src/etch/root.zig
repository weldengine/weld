//! Public surface of the `weld_etch` module — the Etch parser, type-checker,
//! interpreter and codegen. **ADDITIVE CHANGES ONLY**: a removal or a rename
//! here is a breaking change for every out-of-module consumer, and the AST
//! contract block below states which half of the surface that binds.
//!
//! High-level helpers:
//! - `parseSource(gpa, source) !ParseResult` — runs the lexer + parser and
//!   returns the AST plus the parse diagnostics, of which there may be SEVERAL:
//!   top-level recovery continues past a broken construct, so an empty slice is
//!   the only signal of a clean parse.
//! - `typeCheck(gpa, ast, diags_out) !void` — runs pass 1 + pass 2 on a
//!   resolved arena, accumulating diagnostics in `diags_out`.
//!
//! The surface is NOT encapsulated, and writing that it is would mislead: the
//! frozen AST contract below publishes the `items`/`stmts`/`exprs`/`type_nodes`
//! SoA columns and the `strings` intern pool, and `parser.Parser` is reachable
//! through the `parser` re-export. What holds instead is the contract below.

const std = @import("std");

const lexer = @import("lexer.zig");
/// Exposed at the module surface because FIVE out-of-module consumers drive
/// `parser.parseWithMode` directly — four test files and `examples/arena/`,
/// which is a standalone sub-project and not a test. `.d.etch` mode has no
/// helper on this surface. The recursive-descent entry `parser.parse` is the
/// canonical batch path, and `parseSource` below wraps it for an ordinary file.
pub const parser = @import("parser.zig");
const ast = @import("ast.zig");
/// Exposed at the module surface for SIX out-of-module consumers — five test
/// files and `examples/arena/` — and what they reach is `types.TypeChecker` and
/// `types.requiresNamesOf`, the only `pub` decls of that file they name.
/// `StorageKind` and `DiagnosticCode` are NOT pub there and are not reachable
/// this way; a consumer needing them goes through `weld_core.ecs` and the
/// sibling `diagnostics` re-export. NOT for the codegen, which imports
/// `../types.zig` directly and never needed this.
pub const types = @import("types.zig");
/// Exposed at the module surface so callers can construct / inspect
/// `Diagnostic` values (build a tooling test harness, assert
/// `DiagnosticCode`s) without pulling the internals directly.
pub const diagnostics = @import("diagnostics.zig");
/// Tier 1 service registry and the tree-walker invocation path
/// (`etch-abi-zig.md` §8.7). Exposed at the module surface
/// because a Tier 1 module declares its `ServiceSpec` and registers it from
/// outside `src/etch/`.
pub const services = @import("services.zig");
/// Typed bridge from a Tier 0 `EventQueue(T)` into the interpreter's per-tick
/// event store. Exposed because a Tier 1 module owns the queue.
pub const event_bridge = @import("event_bridge.zig");

// Interpreter surface.
const value = @import("value.zig");
const ecs_bridge = @import("ecs_bridge.zig");
const interp = @import("interp.zig");

// Pull the interpreter surface files into the module's test import graph
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
    _ = @import("const_eval.zig");
    // `persistent.zig` lives in Tier 0 (`src/core/memory`) and is pinned by
    // `src/core/memory/root.zig`, reached here via `weld_core.memory` — so it
    // needs no entry of its own below.
    // pull the scene cook driver into the test import graph (§13).
    _ = @import("scene_cook.zig");
    // the service registry's inline tests. The `pub const
    // services` re-export above pulls its DECLARATIONS, not its `test` blocks
    // (§13, and the four-case experiment recorded below).
    _ = @import("services.zig");
    _ = @import("event_bridge.zig");
    // the test runner's inline tests (the `pub const test_runner`
    // re-export pulls its declarations, NOT its `test` blocks — §13).
    _ = @import("test_runner.zig");
    // explicit wire-in of `types.zig`'s inline tests (E0101,
    // scene/prefab/const validation, the resource-collection acceptance tests,
    // …), consistent with the sibling entries above.
    //
    // THIS LINE IS LOAD-BEARING, and do NOT conclude otherwise from removing it
    // and watching the count hold: `types.zig` is ALSO reached through
    // `interp.zig`, pinned above, so the count is insensitive to this line alone
    // and that insensitivity proves nothing. **AN UNREFERENCED PUBLIC RE-EXPORT
    // DOES NOT FORCE-ANALYSE A FILE'S TESTS** — the qualifier is the whole rule,
    // since a re-export that IS referenced elsewhere in the root's closure does
    // pull the file. Measured on four cases: with `pub const leaf =
    // @import("leaf.zig")` ALONE the root collects ZERO of leaf's tests, with or
    // without a test of its own; only a reference collects them.
    _ = @import("types.zig");
    // `zig_codegen/root.zig` carries the correct reference guard for its own
    // three test files, and nothing runs it — but NOT because of the binding
    // form: `codegen_zig` IS referenced, from five call sites. **Zig collects no
    // tests ACROSS A MODULE BOUNDARY**, and every one of those sites reaches it
    // through the `weld_etch` module rather than from inside it. Thirty-seven
    // test blocks, `lower_test.zig`'s twenty-six among them, do not execute.
    //
    // **THE COMMENTED LINE BELOW IS READ AS DATA.** `dead_tests` extracts every
    // `@import` literal from this file's source and skips it only because it
    // sits inside a `//` comment; its head ending in `_ =` is the exact shape
    // that tool takes for a reference guard. Keep the `//` on the same line and
    // keep the text intact — moving it into a MULTILINE STRING flips
    // `src/etch/zig_codegen/` to a FALSE alive, `inComment` bailing only on `"`
    // and so reading a `\\`-prefixed line as code. UNCOMMENTING it is the other
    // case and not the same one: that edge becomes REAL, which is a true alive
    // and a loud build failure on `cache.zig` — see the paragraph below.
    //
    // THE WIRE-IN IS HELD, NOT FORGOTTEN, and the reason is a bigger finding than
    // the dead tests: `zig_codegen/cache.zig` does not COMPILE under the pinned
    // Zig 0.16. `std.fs.cwd()` was removed and `Io.Dir` carries no `realpath`, so
    // `writeHash`, `readCachedHash` and `root.writeFileAndCache` have been dead
    // code since the 0.16 pin — and `root.zig` already documents `cookTree` as
    // having "no current in-tree consumer". Repairing it is not a rename: the
    // 0.16 filesystem API takes an `io` parameter these functions do not have, so
    // it changes the codegen cache's public signatures. That is an Etch decision
    // and not a determinism one. Enable this line with that repair.
    //   _ = @import("zig_codegen/root.zig");
}

/// Scene cook — `.scene.etch` source → the neutral Tier-0 scene model
/// (`weld_core.scene.format.CookModel`) the writer serializes to `.scene.bin`.
/// World-free: registers types into a standalone RTTI `Registry` and const-evals
/// the scene's values. Imports `weld_core.scene`; the Tier-0 side never imports
/// `weld_etch` (tier discipline).
pub const scene_cook = @import("scene_cook.zig");

/// Zig codegen surface — exposed at the module surface so
/// `tools/etch_cook` and downstream consumers can drive the codegen
/// without depending on the internal path layout.
pub const codegen_zig = @import("zig_codegen/root.zig");

/// Descriptor surface — Level B and the Level C scene/prefab arms, typed domain
/// descriptors
/// (`etch-ast-ir.md` §3.5) + the canonical serializer backing the
/// serialized-IR differential. The interpreter builds them at compile
/// (`Interpreter.descriptors`); the differential harness serializes both
/// backends through this surface.
pub const descriptor = @import("descriptor.zig");

/// Exposed at the module surface for TWO out-of-module consumers that drive the
/// lexer alone, without a full parser run: `bench/etch_parse.zig` — a bench, not
/// a test — and `tests/etch/lexer_triple_quote_test.zig`. Both are in-tree.
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

/// Public entry point of the tree-walking interpreter. Consumers
/// instantiate one per Etch program and drive ticks through it.
pub const Interpreter = interp.Interpreter;
/// Public tick-level report — exposed at the surface so bench
/// harnesses and the corpus driver can assert against
/// `entities_iterated` / `rules_matched` without reaching into the
/// interpreter internals.
pub const RuntimeReport = interp.RuntimeReport;

/// Etch `test` runner — iterates a type-checked program's `test`
/// blocks in isolation and reports pass/fail/skip. Exposed at the module
/// surface so the `etch_test` shim (and, later, `weld test`) drive it without
/// reaching into the internal path. Also roots the module for its inline tests
/// (Zig 0.16 lazy analysis, `engine-zig-conventions.md` §13).
pub const test_runner = @import("test_runner.zig");
/// Aggregate result of a `test_runner.run` — per-test results plus
/// passed/failed/skipped counts. Owns its strings (internal arena).
pub const RunReport = test_runner.RunReport;
/// One test's outcome: name, status, wall-clock duration, and (on failure)
/// message + source span.
pub const TestResult = test_runner.TestResult;
/// Whether a test passed, failed, or was skipped.
pub const TestStatus = test_runner.TestStatus;

// ───────────────────────────────────────────────────────────────────────────
// AST stable interface — Level 1 (frozen cross-phase)
//
// Mirrors `etch-parser.md` §10.3.1 "Interface contract stable cross-phase".
// The full v0.6 grammar settles every Item/Stmt/Expr/TypeNode kind variant, so
// the public AST surface is FROZEN HERE: a parser rewrite
// (recursive-descent → LR(1)) must preserve this surface byte-for-byte
// so the ~5000 lines of consumers (interpreter, codegen, ECS bridge, validate,
// LS) compile unchanged.
//
// FROZEN — Level 1. A removal or a rename is a BREAKING change and is
// forbidden; ADDING an enum variant or an accessor is non-breaking:
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
// NOT frozen — Level 2, mutable at will: the `NodeId` 4+28-bit
// packing, the `MultiArrayList` column layout, the `extra` slabs, the `add*`
// builder methods (parser-side writes, not consumer reads).
//
// NOTE — §10.3.1 drift: the spec prose names an
// idealized single `NodeKind` (~150 variants) + a `LiteralKind` + four tagged
// unions (`TopLevelDecl`/`Expression`/`Statement`/`Type`). The delivered AST is
// a tabular SoA instead: the FOUR per-category kind enums above are the
// discriminators, `NodeId` is the universal handle, literals are variants of
// `ExprKind`, and consumers discriminate via `arena.<cat>Kind(id)` +
// `arena.<cat>Data(id)` (no union switch). The contract above is the REAL
// frozen surface; §10.3.1 is to be re-aligned to the SoA reality at the close.
//
// Guard: `tests/etch/ast_stable_interface.zig` exercises ≥20 distinct Level-1
// entry points; its COMPILATION is the invariant. A change that breaks it
// blocks the LR transition and demands an explicit AST-API semver bump.
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
/// With the top-level recovery sync-point the result may carry
/// several diagnostics (one per broken construct); an empty slice means a
/// clean parse.
pub fn parseSource(gpa: std.mem.Allocator, source: []const u8) !parser.ParseResult {
    return try parser.parse(gpa, source);
}

/// Run pass 1 + pass 2 of the type-checker on an already-parsed AST.
/// Accumulates diagnostics in `diags_out` (caller-owned). Each appended
/// diagnostic owns its `primary_message` slice.
pub fn typeCheck(gpa: std.mem.Allocator, arena: *Ast, diags_out: *std.ArrayListUnmanaged(Diagnostic)) !void {
    try TypeChecker.check(gpa, arena, diags_out);
}

/// A set of source files parsed and indexed together (`validateProject`, the
/// project cook).
pub const project = @import("project.zig");
/// One source file of a multi-file project.
pub const ProjectFile = project.ProjectFile;

/// Cross-file scene/prefab validation. Parses every project file,
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
/// The files are checked dependencies first along the import graph, which
/// also resolves every `import` (E0103 / E0104 / E0107 / E0108). Every file's
/// parse + type-check diagnostics accumulate in `diags_out` (caller-owned; each
/// owns its `primary_message`). No watch mode, no incremental invalidation.
pub fn validateProject(
    gpa: std.mem.Allocator,
    files: []const ProjectFile,
    diags_out: *std.ArrayListUnmanaged(Diagnostic),
) !void {
    var p = try project.Project.init(gpa, files, diags_out);
    defer p.deinit();
    const ctx = p.context();
    for (p.order) |idx| try TypeChecker.checkProject(gpa, &p.arenas.items[idx], diags_out, &ctx);
}

test "public API builds + serializes a Level-B data descriptor" {
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
