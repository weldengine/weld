//! The TIME_LITERAL expression arm.
//!
//! A builtin `Time` exists in the type catalogue (`etch-grammar.md` §2.2,
//! "Timestamp relatif"), so §3.2's `time_lit` expression-literal arm is wired
//! on the DURATION_LIT / COLOR_LITERAL precedent: the lexer produces the
//! `TIME_LITERAL` token (`HH:MM`), the parser emits a `time_lit` expr where a
//! primary-switch default would give a parse error, and it type-checks as the
//! builtin `Time`. EVALUATION stays fail-loud in both backends — no runtime
//! semantics are invented, the same as for duration and color — and the
//! descriptor renderer renders its canonical lexeme. A routine's `at HH:MM`
//! trigger keeps its own dedicated parse path, unchanged.

const std = @import("std");
const weld_etch = @import("weld_etch");

test "TIME_LITERAL in expression position: parses as time_lit + type-checks as Time" {
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
