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

/// Etch lexer module — token stream + comment span tracking.
pub const lexer = @import("lexer.zig");
/// Etch parser module — recursive-descent + Pratt expression parser.
pub const parser = @import("parser.zig");
/// Etch AST module — tabular SoA `AstArena` and node accessors.
pub const ast = @import("ast.zig");
/// Etch type-checker module — pass 1 + pass 2 over the SoA arena.
pub const types = @import("types.zig");
/// Etch diagnostics module — typed `Diagnostic` + line index helpers.
pub const diagnostics = @import("diagnostics.zig");
/// Etch token module — token kinds, keyword table, source spans.
pub const token = @import("token.zig");

// S4 interpreter surface.
/// S4 interpreter values — primitive `Value` union + arithmetic helpers.
pub const value = @import("value.zig");
/// S4 ECS bridge — byte ↔ `Value` conversion against runtime archetypes.
pub const ecs_bridge = @import("ecs_bridge.zig");
/// S4 tree-walking interpreter — runs Etch rules over a `World`.
pub const interp = @import("interp.zig");

// S5 Zig codegen surface. Generates idiomatic Zig source from a parsed +
// type-checked Etch AST per `briefs/S5-etch-codegen-zig.md`.
/// S5 Etch → Zig codegen — emits a `.zig` shipping module from an AST.
pub const codegen_zig = @import("zig_codegen/root.zig");

/// Re-exports `lexer.Lexer` — token-producing iterator over Etch source.
pub const Lexer = lexer.Lexer;
/// Re-exports `token.Token` — lexed unit (kind + span).
pub const Token = token.Token;
/// Re-exports `token.TokenKind` — closed enum of all Etch token kinds.
pub const TokenKind = token.TokenKind;
/// Re-exports `token.SourceSpan` — byte-range location inside an Etch source.
pub const SourceSpan = token.SourceSpan;
/// Re-exports `parser.Parser` — explicit parser state for advanced uses.
pub const Parser = parser.Parser;
/// Re-exports `parser.ParseResult` — `{ ast, diagnostic? }` return shape.
pub const ParseResult = parser.ParseResult;
/// Re-exports `ast.AstArena` — tabular SoA arena holding the whole AST.
pub const Ast = ast.AstArena;
/// Re-exports `ast.NodeId` — opaque handle into the `AstArena`.
pub const NodeId = ast.NodeId;
/// Re-exports `ast.NodeCategory` — coarse-grained classification of AST nodes.
pub const NodeCategory = ast.NodeCategory;
/// Re-exports `ast.StringId` — interned-string handle inside the arena.
pub const StringId = ast.StringId;
/// Re-exports `types.TypeChecker` — entry point of pass 1 + pass 2.
pub const TypeChecker = types.TypeChecker;
/// Re-exports `diagnostics.Diagnostic` — typed parser / checker error.
pub const Diagnostic = diagnostics.Diagnostic;
/// Re-exports `diagnostics.DiagnosticCode` — closed set of E-codes.
pub const DiagnosticCode = diagnostics.DiagnosticCode;
/// Re-exports `diagnostics.Severity` — `error` vs `warning` discriminator.
pub const Severity = diagnostics.Severity;
/// Re-exports `diagnostics.LineIndex` — byte-offset → line/column lookup.
pub const LineIndex = diagnostics.LineIndex;

/// Re-exports `value.Value` — interpreter tagged value union.
pub const Value = value.Value;
/// Re-exports `value.RuntimeError` — typed interpreter runtime failure.
pub const RuntimeError = value.RuntimeError;
/// Re-exports `interp.Interpreter` — tree-walking executor.
pub const Interpreter = interp.Interpreter;
/// Re-exports `interp.RuntimeReport` — counter of runtime errors per tick.
pub const RuntimeReport = interp.RuntimeReport;
/// Re-exports `Interpreter.runProgram` — entry for `runtime.run(world, ast)`.
pub const runProgram = interp.Interpreter.runProgram;
/// Re-exports `Interpreter.run` — runs the interpreter over an already-parsed AST.
pub const runWithAst = interp.Interpreter.run;
/// Re-exports `interp.evalConst` — pure constant folder over an AST subtree.
pub const evalConst = interp.evalConst;

/// Parse a full Etch source file. The returned `ParseResult` owns its
/// `AstArena` — call `result.ast.deinit(gpa)` when done. The diagnostic
/// (if any) owns its `primary_message` slice — call `diag.deinit(gpa)`.
pub fn parseSource(gpa: std.mem.Allocator, source: []const u8) !ParseResult {
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
    defer result.ast.deinit(gpa);
    try std.testing.expect(result.diagnostic == null);
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
    defer result.ast.deinit(gpa);
    try std.testing.expect(result.diagnostic == null);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try typeCheck(gpa, &result.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
