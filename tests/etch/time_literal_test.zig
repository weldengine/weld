//! TIME_LITERAL expression arm — M0.8 E7 gate wiring (Guy's ruling 5).
//!
//! A builtin `Time` exists in the type catalogue (`etch-grammar.md` §2.2,
//! "Timestamp relatif"), so the `time_lit` §3.2 expression-literal arm is wired
//! verbatim on the DURATION_LIT / COLOR_LITERAL precedent: the lexer already
//! produces the `TIME_LITERAL` token (`HH:MM`); the parser now emits a
//! `time_lit` expr (was a primary-switch default → parse error before E7); it
//! type-checks as the builtin `Time`. EVALUATION stays fail-loud in both
//! backends (no runtime semantics invented — the duration/color precedent);
//! the descriptor renderer renders its canonical lexeme. (Routine `at HH:MM`
//! triggers keep their own dedicated parse path, unchanged.)

const std = @import("std");
const weld_etch = @import("weld_etch");

test "TIME_LITERAL in expression position: parses as time_lit + type-checks as Time (M0.8 E7)" {
    const gpa = std.testing.allocator;

    // A bare `HH:MM` literal in expression position (dormant in a rule body —
    // type-check only, never evaluated).
    var pr = try weld_etch.parseSource(gpa,
        \\component Clock { ticks: int = 0 }
        \\rule read_time(entity: Entity)
        \\  when entity has Clock
        \\{
        \\  let t = 06:00
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    // The bare time literal produced a `time_lit` expr (not a parse error).
    var found_time_lit = false;
    var i: u28 = 0;
    while (i < pr.ast.exprs.len) : (i += 1) {
        if (pr.ast.exprKind(.{ .category = .expr, .index = i }) == .time_lit) found_time_lit = true;
    }
    try std.testing.expect(found_time_lit);

    // Type-checks clean (`time_lit` synthesizes to the builtin `Time`).
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    if (diags.items.len > 0) {
        for (diags.items) |d| std.debug.print("[time-lit] {s}: {s}\n", .{ d.code.code(), d.primary_message });
    }
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
