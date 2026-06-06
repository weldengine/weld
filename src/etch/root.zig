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

/// S5 Zig codegen surface — exposed at the module surface so
/// `tools/etch_cook` and downstream consumers can drive the codegen
/// without depending on the internal path layout.
pub const codegen_zig = @import("zig_codegen/root.zig");

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
