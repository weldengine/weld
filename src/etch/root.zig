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

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const ast = @import("ast.zig");
pub const types = @import("types.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const token = @import("token.zig");

// S4 interpreter surface.
pub const value = @import("value.zig");
pub const ecs_bridge = @import("ecs_bridge.zig");
pub const interp = @import("interp.zig");

pub const Lexer = lexer.Lexer;
pub const Token = token.Token;
pub const TokenKind = token.TokenKind;
pub const SourceSpan = token.SourceSpan;
pub const Parser = parser.Parser;
pub const ParseResult = parser.ParseResult;
pub const Ast = ast.AstArena;
pub const NodeId = ast.NodeId;
pub const NodeCategory = ast.NodeCategory;
pub const StringId = ast.StringId;
pub const TypeChecker = types.TypeChecker;
pub const Diagnostic = diagnostics.Diagnostic;
pub const DiagnosticCode = diagnostics.DiagnosticCode;
pub const Severity = diagnostics.Severity;
pub const LineIndex = diagnostics.LineIndex;

pub const Value = value.Value;
pub const RuntimeError = value.RuntimeError;
pub const Interpreter = interp.Interpreter;
pub const RuntimeReport = interp.RuntimeReport;
pub const runProgram = interp.Interpreter.runProgram;
pub const runWithAst = interp.Interpreter.run;
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
