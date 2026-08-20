//! Rule `no_float_reduce` — `@reduce` with an arithmetic operation is forbidden
//! unless the site declares that its lanes are integers.
//!
//! `ARCH-031` rule 3 fixes the reduction order of every float reduction on a
//! compared path, and `@reduce` does not carry it today. The language specifies
//! the order — the langref calls it "a sequential horizontal reduction" and
//! states that on floats "the operation associativity is preserved, unless the
//! float mode is set to `Optimized`" — but two Zig 0.16 backends were measured
//! at M1.1.14 to disagree on the SAME `x86_64` target: LLVM folds a 3-lane f32
//! sum as `(p₀ + p₁) + p₂`, the self-hosted backend as `p₁ + (p₂ + p₀)`, under
//! the default float mode and under an explicit `.strict` alike. Those two
//! functions differ on 31.4% of random f32 triples, and in the determinism
//! harness it showed as the continuous state diverging at frame 1.
//!
//! So the sanctioned form is `foundation/math/reduce`, whose folds are written
//! in source and are therefore the same function under every backend, version
//! and float mode. The compiler defect is owed upstream; the rule does not wait
//! for it, because determinism that rests on someone else's release is not a
//! property the engine holds.
//!
//! WHY THIS RULE EXISTS AT ALL, rather than the fix alone: the twelve production
//! sites were replaced in one pass, and nothing would stop the thirteenth. A
//! rule written down without a check is an intention.
//!
//! WHAT IS FLAGGED. `.Add`, `.Mul`, `.Min` and `.Max` — the four operations
//! meaningful on floats. `.And`, `.Or` and `.Xor` are boolean and integer only,
//! are order-free, and are never flagged; the tree's `@reduce(.And, a <= b)`
//! predicates are legitimate and stay.
//!
//! THE ESCAPE, and why it is a marker rather than a path allowlist. Integer
//! lanes make `.Add`/`.Mul`/`.Min`/`.Max` exact under any order, so those sites
//! are legitimate — but the linter is a tokenizer and cannot see an element
//! type. A path allowlist would grant the exemption to a whole file, including
//! the float reduction someone adds to it next year. `WELD_INTEGER_LANES` on the
//! statement's own line or the line above grants it to ONE site, in the reader's
//! view, and reads as the claim it is: *these lanes are integers.*
//!
//! This rule is deliberately not scoped to `src/`: `bench/` and the test files
//! feed the same measurements, and a float reduction in a bench is a reason for
//! a bench figure that cannot be reproduced.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_float_reduce";

/// The marker a site uses to declare integer lanes, on the `@reduce` line or the
/// line immediately above it.
const integer_marker = "WELD_INTEGER_LANES";

/// The reduction operations that are meaningful on floats, hence order- or
/// NaN-sensitive. Kept as a table so a reader sees the whole flagged set at once.
const arithmetic_ops = [_][]const u8{ "Add", "Mul", "Min", "Max" };

/// Hook called by `main.runLint` once per `.zig` file.
///
/// Tokenizes and looks for the shape `@reduce` `(` `.` IDENT, flagging the site
/// when IDENT is one of `arithmetic_ops` and neither the site's own line nor the
/// one above carries `WELD_INTEGER_LANES`. Tokenizing rather than substring
/// matching is what keeps the rule off its own prose: this file names
/// `@reduce(.Add` in a doc comment above, and a doc comment is one token.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    var tokenizer = std.zig.Tokenizer.init(source);

    // The three-token window `@reduce` `(` `.` that must precede the operation.
    var saw_reduce = false;
    var saw_lparen = false;
    var saw_period = false;

    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        const slice = source[tok.loc.start..tok.loc.end];

        if (saw_reduce and saw_lparen and saw_period and tok.tag == .identifier) {
            if (isArithmetic(slice) and !hasIntegerMarker(source, tok.loc.start)) {
                const pos = diag.lineColFromOffset(source, tok.loc.start);
                try out.append(arena, .{
                    .file = file,
                    .line = pos.line,
                    .col = pos.col,
                    .rule = name,
                    .message = "`@reduce` with an arithmetic operation delegates the reduction order to the backend, which `ARCH-031` rule 3 forbids on a compared path — use `foundation/math/reduce` (`foldAdd`/`foldMul`/`foldMin`/`foldMax`), or declare integer lanes with a `WELD_INTEGER_LANES` comment on this line or the line above",
                });
            }
        }

        switch (tok.tag) {
            .builtin => {
                saw_reduce = std.mem.eql(u8, slice, "@reduce");
                saw_lparen = false;
                saw_period = false;
            },
            .l_paren => {
                saw_lparen = saw_reduce;
                saw_period = false;
            },
            .period => {
                saw_period = saw_reduce and saw_lparen;
            },
            else => {
                saw_reduce = false;
                saw_lparen = false;
                saw_period = false;
            },
        }
    }
}

/// Whether `op` names one of the float-meaningful reduction operations.
fn isArithmetic(op: []const u8) bool {
    for (arithmetic_ops) |candidate| {
        if (std.mem.eql(u8, op, candidate)) return true;
    }
    return false;
}

/// Whether the site at `offset` is exempted: the marker sits on its own line, or
/// on the line immediately above WHEN THAT LINE IS A PURE COMMENT.
///
/// The line above is admitted because the claim usually deserves a sentence, and
/// a justification pushed onto its own line should not have to repeat the marker
/// on the statement. The pure-comment restriction is what keeps that from
/// leaking: without it a trailing `// WELD_INTEGER_LANES` on one statement
/// silently exempts the NEXT one, which is how two adjacent reductions come to
/// share a single claim that was only ever made about the first. Found by a
/// failing test whose own premise was wrong — it expected per-site scoping from
/// two adjacent lines, and the rule as first written did not have it.
fn hasIntegerMarker(source: []const u8, offset: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
    if (std.mem.indexOf(u8, source[line_start..line_end], integer_marker) != null) return true;

    if (line_start == 0) return false;
    const prev_end = line_start - 1;
    const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0..prev_end], '\n')) |i| i + 1 else 0;
    const prev = std.mem.trim(u8, source[prev_start..prev_end], " \t\r");
    if (!std.mem.startsWith(u8, prev, "//")) return false;
    return std.mem.indexOf(u8, prev, integer_marker) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Runs the rule over `source` and returns how many diagnostics it produced.
fn countOn(source: [:0]const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try check(arena_state.allocator(), "probe.zig", source, &diags);
    defer diags.deinit(arena_state.allocator());
    return diags.items.len;
}

test "the four float-meaningful operations are flagged" {
    try std.testing.expectEqual(@as(usize, 1), try countOn("const x = @reduce(.Add, v);\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("const x = @reduce(.Mul, v);\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("const x = @reduce(.Min, v);\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("const x = @reduce(.Max, v);\n"));
}

test "the order-free boolean operations are not flagged" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("const x = @reduce(.And, a <= b);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const x = @reduce(.Or, a > b);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const x = @reduce(.Xor, a);\n"));
}

test "the integer-lanes marker exempts one site, on its line or the line above" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "const x = @reduce(.Add, v); // WELD_INTEGER_LANES u32 lanes\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "// WELD_INTEGER_LANES u32 lanes\nconst x = @reduce(.Add, v);\n",
    ));
    // TWO lines above is out of reach: the exemption is per-site, and a marker
    // that drifts arbitrarily far from its statement stops being a claim about it.
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        "// WELD_INTEGER_LANES\n\nconst x = @reduce(.Add, v);\n",
    ));
}

test "the marker exempts only the site it sits on" {
    // Non-vacuity for the test above: with two sites and one marker, exactly one
    // must survive — a rule that exempted the whole FILE would report zero here
    // and would still pass every single-site test written above.
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        \\const a = @reduce(.Add, v); // WELD_INTEGER_LANES
        \\const b = @reduce(.Add, w);
        \\
    ));
}

test "a trailing marker does not leak onto the statement below it" {
    // The case that made the test above fail when the line-above allowance was
    // unconditional: line 1's marker is a trailing comment on a STATEMENT line,
    // so it is a claim about line 1 and about nothing else. Only a line that is
    // wholly a comment may speak for the statement beneath it.
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        \\const a = @reduce(.Add, v); // WELD_INTEGER_LANES
        \\const b = @reduce(.Add, w);
        \\
    ));
    // And the legitimate form still works, so the restriction did not close the
    // door it exists to keep open.
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        \\// WELD_INTEGER_LANES: `u32` lanes, exact under any order.
        \\const b = @reduce(.Add, w);
        \\
    ));
}

test "the rule is written on tokens, so prose naming the builtin is not a site" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "/// Never write `@reduce(.Add, v)` on a float path.\nconst x = 1;\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "// @reduce(.Max, v) is what this replaces.\nconst x = 1;\n",
    ));
}

test "an unrelated builtin taking an enum literal is not a site" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("const x = @as(.Add, v);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const x = foo(.Max, v);\n"));
}

test "several sites on one line are each reported" {
    try std.testing.expectEqual(@as(usize, 2), try countOn(
        "const x = @reduce(.Add, v) + @reduce(.Max, w);\n",
    ));
}
