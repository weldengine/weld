//! M0.9 E2-A — triple-quote `"""…"""` multiline string literal.
//!
//! Lexer-level coverage: the new `multiline_string_literal` token, its byte
//! boundaries, newline/quote-spanning bodies, the `"`-vs-`"""` greedy split,
//! and the unterminated → `error_byte` fall-through (the `lexString`
//! precedent). Plus a parse-level companion that pins the `etch-grammar.md`
//! §1.4 common-indentation strip (a parser behaviour, not a lexer one) by
//! reading the interned `string_lit` value off the AST arena, and a check
//! that an interpolated triple-quote lowers to a `string_interp` node.

const std = @import("std");
const etch = @import("weld_etch");

test "triple quote multiline string" {
    const gpa = std.testing.allocator;
    const src = "\"\"\"hello\"\"\"";
    var lex = etch.Lexer.init(src);
    defer lex.deinit(gpa);
    const t = try lex.next(gpa);
    try std.testing.expect(t.kind == .multiline_string_literal);
    // Span covers the full `"""hello"""`.
    try std.testing.expectEqual(@as(u32, 0), t.span.byte_start);
    try std.testing.expectEqual(@as(u32, @intCast(src.len)), t.span.byte_end);
    const eof = try lex.next(gpa);
    try std.testing.expect(eof.kind == .eof);
}

test "triple quote spans embedded newlines and lone quotes" {
    const gpa = std.testing.allocator;
    // Body holds a newline and a lone `"` and a `""` pair — none of which
    // close the literal (only a contiguous `"""` does).
    const src = "\"\"\"line one\nhe said \"hi\" and \"\" too\nline three\"\"\"";
    var lex = etch.Lexer.init(src);
    defer lex.deinit(gpa);
    const t = try lex.next(gpa);
    try std.testing.expect(t.kind == .multiline_string_literal);
    try std.testing.expectEqual(@as(u32, 0), t.span.byte_start);
    try std.testing.expectEqual(@as(u32, @intCast(src.len)), t.span.byte_end);
    try std.testing.expect((try lex.next(gpa)).kind == .eof);
}

test "triple quote empty body" {
    const gpa = std.testing.allocator;
    const src = "\"\"\"\"\"\""; // six quotes = `"""` + `"""`
    var lex = etch.Lexer.init(src);
    defer lex.deinit(gpa);
    const t = try lex.next(gpa);
    try std.testing.expect(t.kind == .multiline_string_literal);
    try std.testing.expectEqual(@as(u32, @intCast(src.len)), t.span.byte_end);
}

test "triple quote unterminated is an error token" {
    const gpa = std.testing.allocator;
    const src = "\"\"\"abc\ndef"; // never closed
    var lex = etch.Lexer.init(src);
    defer lex.deinit(gpa);
    const t = try lex.next(gpa);
    try std.testing.expect(t.kind == .error_byte);
}

test "double quote is not a triple quote (greedy split)" {
    const gpa = std.testing.allocator;
    // A single-line `"hi"` stays a `string_literal`; the trailing empty `""`
    // is a second simple string, not a triple-quote opener.
    var lex = etch.Lexer.init("\"hi\" \"\"");
    defer lex.deinit(gpa);
    try std.testing.expect((try lex.next(gpa)).kind == .string_literal);
    try std.testing.expect((try lex.next(gpa)).kind == .string_literal);
    try std.testing.expect((try lex.next(gpa)).kind == .eof);
}

/// Walk the arena's expr column and return the interned bytes of the first
/// `string_lit` (M0.9 E2-A pins the §1.4 dedent through this).
fn firstStringLit(arena: *const etch.Ast) ?[]const u8 {
    var i: usize = 0;
    while (i < arena.exprs.len) : (i += 1) {
        const id: etch.NodeId = .{ .category = .expr, .index = @intCast(i) };
        if (arena.exprKind(id) == .string_lit) {
            return arena.strings.slice(arena.exprData(id));
        }
    }
    return null;
}

fn firstExprKind(arena: *const etch.Ast, target: etch.ExprKind) bool {
    var i: usize = 0;
    while (i < arena.exprs.len) : (i += 1) {
        const id: etch.NodeId = .{ .category = .expr, .index = @intCast(i) };
        if (arena.exprKind(id) == target) return true;
    }
    return false;
}

test "triple quote common indentation is stripped at parse (§1.4)" {
    const gpa = std.testing.allocator;
    // Both content lines share a 6-space indent; the closing-fence line is
    // all-whitespace (blank, excluded from the min). Common indent = 6.
    const src =
        \\rule r() {
        \\  let s = """
        \\      alpha
        \\      beta
        \\      """
        \\}
    ;
    var result = try etch.parseSource(gpa, src);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const v = firstStringLit(&result.ast) orelse return error.NoStringLit;
    // The opening-fence newline and the closing-fence newline stay (the spec
    // strips common indentation only, not surrounding newlines); the 6-space
    // common indent is removed from every line.
    try std.testing.expectEqualStrings("\nalpha\nbeta\n", v);
}

test "triple quote with interpolation lowers to string_interp" {
    const gpa = std.testing.allocator;
    const src =
        \\rule r() {
        \\  let n = 2
        \\  let s = """value is {n}"""
        \\}
    ;
    var result = try etch.parseSource(gpa, src);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(firstExprKind(&result.ast, .string_interp));
}

fn firstStringInterpId(arena: *const etch.Ast) ?etch.NodeId {
    var i: usize = 0;
    while (i < arena.exprs.len) : (i += 1) {
        const id: etch.NodeId = .{ .category = .expr, .index = @intCast(i) };
        if (arena.exprKind(id) == .string_interp) return id;
    }
    return null;
}

test "triple quote multiline interpolation dedents literals only, not expression bytes (§1.4)" {
    const gpa = std.testing.allocator;
    // Both literal lines share a 4-space indent (stripped). The interpolation
    // `{1 +\n      2}` spans two lines, its inner `2` indented 6 — those bytes
    // are EXPRESSION source, consumed by the embedded-expr sub-parser. They
    // must never be dedented nor land in a literal segment: the walk jumps the
    // whole `{…}` via the sub-parser's resume offset.
    const src =
        \\rule r() {
        \\  let x = """
        \\    before {1 +
        \\      2} after
        \\    """
        \\}
    ;
    var result = try etch.parseSource(gpa, src);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const id = firstStringInterpId(&result.ast) orelse return error.NoStringInterp;
    const row = result.ast.exprData(id);
    const si = result.ast.string_interps.items[row];
    try std.testing.expectEqual(@as(u32, 1), si.n_exprs);
    // Segment 0 — the literal before the interpolation: opening-fence newline +
    // "before " with the 4-space common indent stripped.
    const seg0 = result.ast.strings.slice(result.ast.extra.items[si.segs_start]);
    try std.testing.expectEqualStrings("\nbefore ", seg0);
    // Segment 1 — the literal after the interpolation: " after" + newline + the
    // closing-fence line dedented to empty. It does NOT contain the
    // interpolation's inner `      2` bytes (those are expression source).
    const seg1 = result.ast.strings.slice(result.ast.extra.items[si.segs_start + 1]);
    try std.testing.expectEqualStrings(" after\n", seg1);
}
