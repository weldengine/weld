//! Rule `comment_identifiers` — no milestone, gate or review identifier in a
//! comment.
//!
//! Normative at `engine-zig-conventions.md` §12. The rule has NO exception: it
//! covers debt identifiers too, because a reference by identifier goes false in
//! silence at a renumbering. A site carrying a debt stays markable without one —
//! the falsifiable claim about the code is what a reader searches for.
//!
//! **THE PREDICATE IS FOUR TOKEN CLASSES, AND ITS BOUNDS ARE MEASURED RATHER
//! THAN CHOSEN.** Each class was counted over every comment in the tree and each
//! has ZERO occurrence carrying a non-identifier meaning:
//!
//!   - a milestone: an upper- or lower-case `M`, digits, then at least one
//!     dot-component that is digits, one capital, or a lower-case x. THE DOT IS
//!     REQUIRED, and that is the bound: a bare capital-M-plus-digits has zero
//!     milestone uses in the tree and eleven other ones — an Apple CPU model, a
//!     bench component type, a local scalar — so catching it buys nothing and
//!     costs false positives. Requiring a milestone-shaped component after the
//!     dot is what lets the lower-case spelling in without catching a field
//!     access written in prose.
//!   - a spike: a capital S and one digit from zero to six. The range is CLOSED —
//!     the seven spikes exist and no eighth will — so this list cannot go stale.
//!   - a gate: a capital G, digits, and an optional single lower-case letter for
//!     a split gate. Both boundaries are load-bearing: without the left one the
//!     rule fires inside a packed colour-format name, five real occurrences.
//!   - a step or review: a capital E and ONE digit from one to nine, with an
//!     optional sub-part; or the recorded-deviation prefix and digits. The single
//!     digit plus a right boundary is what separates these from the four-digit
//!     diagnostic codes, of which the tree holds 1220 — a right-unbounded form
//!     would fire on 697 of them.
//!
//! **WHAT THE RULE DELIBERATELY DOES NOT COVER, each with its reason.** Review
//! passes, findings, hypotheses, hotfixes and decisions are also written as a
//! capital letter plus digits, and forbidding that shape generally would fire on
//! vocabulary §12 does not forbid and the corpus cites on purpose: wake causes
//! owned by the physics solver document, drift patterns owned by the audit
//! checklist, phase criteria, generic type parameters, archetype labels in a
//! bench, and an image-format magic. Those shapes are review-level, not lint.
//! And a sub-work-unit is written as a bare number after a naming word, so no
//! token shape reaches it at all.
//!
//! Perimeter, its `tests/` exclusion and the declared unread subtrees:
//! `comment_scan.isCovered`.

const std = @import("std");
const diag = @import("../diagnostic.zig");
const comment_scan = @import("../comment_scan.zig");

const name = "comment_identifiers";

/// Which class of identifier a match belongs to. Reported so a reader of the
/// diagnostic knows which of the four bounds fired.
pub const Kind = enum {
    milestone,
    spike,
    gate,
    step,
    review,

    /// The word used in the diagnostic message.
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .milestone => "milestone",
            .spike => "spike",
            .gate => "gate",
            .step => "step",
            .review => "review",
        };
    }
};

/// A matched identifier: its byte length and which class matched.
pub const Match = struct {
    /// Length in bytes of the matched token.
    len: usize,
    /// The class that matched.
    kind: Kind,
};

/// Match an identifier starting exactly at `i` in `text`, or null.
///
/// The caller is responsible for the left boundary; this only looks forward.
/// Exported because the tag rule needs the same predicate inside a tag's
/// parentheses, and two predicates for one object is how they come to disagree.
pub fn matchAt(text: []const u8, i: usize) ?Match {
    if (matchMilestone(text, i)) |n| return .{ .len = n, .kind = .milestone };
    if (matchSpike(text, i)) |n| return .{ .len = n, .kind = .spike };
    if (matchGate(text, i)) |n| return .{ .len = n, .kind = .gate };
    if (matchStep(text, i)) |n| return .{ .len = n, .kind = .step };
    if (matchReview(text, i)) |n| return .{ .len = n, .kind = .review };
    return null;
}

/// The first identifier in `text`, or null. Used by the tag rule on a
/// parenthesised argument, where the whole argument is the haystack.
pub fn firstIn(text: []const u8) ?Match {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!comment_scan.atLeftBoundary(text, i)) continue;
        if (matchAt(text, i)) |m| return m;
    }
    return null;
}

/// Hook called by `main.runLint` once per `.zig` file.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    if (!comment_scan.isCovered(file)) return;
    // A generated file's comments belong to its emitter — see
    // `comment_scan.isGenerated`. The sibling rules `doc_comments` and
    // `c_module_isolation` suppress on the same marker; this rule did not, and
    // the omission invited a hand-edit that the bindgen round-trip guard
    // correctly refused.
    if (comment_scan.isGenerated(source)) return;

    var spans: std.ArrayList(comment_scan.Span) = .empty;
    defer spans.deinit(arena);
    try comment_scan.collect(arena, source, &spans);

    for (spans.items) |span| {
        const text = span.text(source);
        var i: usize = 0;
        while (i < text.len) {
            if (!comment_scan.atLeftBoundary(text, i)) {
                i += 1;
                continue;
            }
            const m = matchAt(text, i) orelse {
                i += 1;
                continue;
            };
            const pos = diag.lineColFromOffset(source, span.start + i);
            try out.append(arena, .{
                .file = file,
                .line = pos.line,
                .col = pos.col,
                .rule = name,
                .message = try std.fmt.allocPrint(
                    arena,
                    "{s} identifier `{s}` in a comment; the history belongs to `git log`",
                    .{ m.kind.label(), text[i .. i + m.len] },
                ),
            });
            i += m.len;
        }
    }
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn hasPrefix(text: []const u8, i: usize, needle: []const u8) bool {
    return i + needle.len <= text.len and std.mem.eql(u8, text[i .. i + needle.len], needle);
}

fn matchMilestone(text: []const u8, i: usize) ?usize {
    if (i >= text.len) return null;
    if (text[i] != 'M' and text[i] != 'm') return null;
    var j = i + 1;
    const digits_start = j;
    while (j < text.len and isDigit(text[j])) j += 1;
    if (j == digits_start) return null;

    var groups: usize = 0;
    while (j < text.len and text[j] == '.') {
        const after = j + 1;
        if (after >= text.len) break;
        const c = text[after];
        if (isDigit(c)) {
            var k = after;
            while (k < text.len and isDigit(text[k])) k += 1;
            j = k;
            groups += 1;
            continue;
        }
        if (isUpper(c)) {
            // One capital is a milestone letter; a lower-case letter after it
            // makes the whole thing an ordinary capitalised word instead.
            if (after + 1 < text.len and isLower(text[after + 1])) break;
            j = after + 1;
            groups += 1;
            continue;
        }
        if (c == 'x') {
            if (after + 1 < text.len and comment_scan.isWordByte(text[after + 1])) break;
            j = after + 1;
            groups += 1;
            continue;
        }
        break;
    }
    if (groups == 0) return null;
    if (!comment_scan.atRightBoundary(text, j)) return null;
    return j - i;
}

fn matchSpike(text: []const u8, i: usize) ?usize {
    if (i >= text.len or text[i] != 'S') return null;
    if (i + 1 >= text.len) return null;
    const c = text[i + 1];
    if (c < '0' or c > '6') return null;
    if (!comment_scan.atRightBoundary(text, i + 2)) return null;
    return 2;
}

fn matchGate(text: []const u8, i: usize) ?usize {
    if (i >= text.len or text[i] != 'G') return null;
    var j = i + 1;
    const digits_start = j;
    while (j < text.len and isDigit(text[j])) j += 1;
    if (j == digits_start) return null;
    if (j < text.len and isLower(text[j])) j += 1;
    if (!comment_scan.atRightBoundary(text, j)) return null;
    return j - i;
}

fn matchStep(text: []const u8, i: usize) ?usize {
    if (i >= text.len or text[i] != 'E') return null;
    if (i + 1 >= text.len) return null;
    const d = text[i + 1];
    if (d < '1' or d > '9') return null;
    var j = i + 2;
    // Longest sub-part first: the three-letter forms must be tried before the
    // single-letter one, or they degrade to their first letter and then fail the
    // right boundary on their second.
    if (hasPrefix(text, j, "bis") or hasPrefix(text, j, "ter")) {
        j += 3;
    } else if (j + 2 < text.len and text[j] == '(' and isLower(text[j + 1]) and text[j + 2] == ')') {
        j += 3;
    } else if (j + 1 < text.len and text[j] == '-' and isUpper(text[j + 1])) {
        j += 2;
        if (j < text.len and isDigit(text[j])) j += 1;
    } else if (j < text.len and isLower(text[j])) {
        j += 1;
    }
    if (!comment_scan.atRightBoundary(text, j)) return null;
    return j - i;
}

fn matchReview(text: []const u8, i: usize) ?usize {
    if (!hasPrefix(text, i, "RD-")) return null;
    var j = i + 3;
    const digits_start = j;
    while (j < text.len and isDigit(text[j])) j += 1;
    if (j == digits_start) return null;
    if (!comment_scan.atRightBoundary(text, j)) return null;
    return j - i;
}

/// Count the diagnostics `check` produces for `source` at `file`.
fn countOn(file: []const u8, source: [:0]const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try check(arena, file, source, &diags);
    return diags.items.len;
}

/// Whether the predicate fires anywhere in `text`, used to drive the table below.
fn fires(text: []const u8) bool {
    return firstIn(text) != null;
}

test "the four shapes the convention names are rejected" {
    // Written as data and never as prose: this file is itself linted by this
    // rule, so spelling one of these in a comment would fire on its own source.
    try std.testing.expect(fires("M1.B"));
    try std.testing.expect(fires("M1.1.15.1/H1"));
    try std.testing.expect(fires("G7"));
    try std.testing.expect(fires("M1.D.18"));
}

test "the two ordinary words the convention protects are accepted" {
    // The other half of the acceptance criterion, and the half that constrains
    // the predicate from below: a bare capital M with digits, and a bare G.
    try std.testing.expect(!fires("M0"));
    try std.testing.expect(!fires("G"));
}

test "a milestone must show a dot component" {
    // Measured: the tree holds zero bare-M milestone references and eleven
    // collisions. These four are real occurrences, quoted as data.
    try std.testing.expect(!fires("was calibrated for the M4 Pro 14-core dev box"));
    try std.testing.expect(!fires("component types M1, M2 and M3"));
    try std.testing.expect(!fires("the scalar bound m0"));
    try std.testing.expect(fires("the storage-mode milestone M1.B"));
}

test "a lower-case milestone citation fires, a field access written in prose does not" {
    // The reason the dot component is shape-restricted rather than free: milestone
    // filenames are cited in lower case, and manifold locals are discussed in
    // prose with a dotted field.
    try std.testing.expect(fires("m1.1.14"));
    try std.testing.expect(fires("m1.B"));
    try std.testing.expect(!fires("m1.normal is the manifold normal"));
    try std.testing.expect(!fires("m1.position"));
}

test "a capitalised word after a dot is not a milestone letter" {
    try std.testing.expect(!fires("M1.Beta"));
    try std.testing.expect(fires("M1.D"));
}

test "the closed spike range fires and its neighbours do not" {
    try std.testing.expect(fires("S0"));
    try std.testing.expect(fires("S6"));
    try std.testing.expect(!fires("S7"));
    try std.testing.expect(!fires("S"));
    try std.testing.expect(!fires("Set"));
}

test "a split gate fires and a packed colour format does not" {
    // The left boundary is what separates them, and the format name is a real
    // occurrence: without it the rule fires five times on graphics vocabulary.
    try std.testing.expect(fires("G5a"));
    try std.testing.expect(fires("G22"));
    try std.testing.expect(!fires("R8G8B8A8_UNORM"));
    try std.testing.expect(!fires("B8G8R8A8_UNORM"));
    try std.testing.expect(!fires("G19Mode"));
}

test "a step fires with every sub-part form the tree uses" {
    try std.testing.expect(fires("E1"));
    try std.testing.expect(fires("E2bis"));
    try std.testing.expect(fires("E2ter"));
    try std.testing.expect(fires("E3-C"));
    try std.testing.expect(fires("E4(b)"));
    try std.testing.expect(fires("E5a"));
    try std.testing.expect(fires("E7-J3"));
}

test "a four-digit diagnostic code is not a step" {
    // THE COLLISION THAT MAKES THE RIGHT BOUNDARY LOAD-BEARING. The tree holds
    // 1220 of these codes; a right-unbounded form fires on 697.
    try std.testing.expect(!fires("E1791"));
    try std.testing.expect(!fires("E1901"));
    try std.testing.expect(!fires("E0902"));
    try std.testing.expect(!fires("W0902"));
    try std.testing.expect(!fires("E1216"));
}

test "a recorded deviation fires" {
    try std.testing.expect(fires("RD-4"));
    try std.testing.expect(fires("RD-12"));
    try std.testing.expect(!fires("RD-"));
}

test "the vocabulary the rule must not reach is untouched" {
    // Seven families, each cited on purpose by the corpus. A rule that reached
    // any of them would be over-caught rather than strict.
    try std.testing.expect(!fires("ARCH-005"));
    try std.testing.expect(!fires("C1.6"));
    try std.testing.expect(!fires("C0.1"));
    try std.testing.expect(!fires("wake cause W4"));
    try std.testing.expect(!fires("drift pattern D31"));
    try std.testing.expect(!fires("v0.11.17"));
    try std.testing.expect(!fires("f32 and u64"));
}

test "scientific notation and a hex colour are not steps" {
    // Both are excluded by the left boundary rather than by a special case: the
    // exponent is always preceded by a digit.
    try std.testing.expect(!fires("1e-6"));
    try std.testing.expect(!fires("2E6"));
    try std.testing.expect(!fires("tolerance 1E4"));
}

test "an identifier inside a string literal is not reported" {
    // The structural half of the extraction, exercised through the whole rule
    // rather than through the scanner alone.
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "tools/weld_lint/x.zig",
        "const s = \"M1.B\";\n",
    ));
}

test "an identifier in a trailing comment IS reported" {
    // NON-VACUITY for the test above, and the case a line-oriented rule misses:
    // sixteen real occurrences sit in trailing comments.
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        "tools/weld_lint/x.zig",
        "const s = 1; // see M1.B\n",
    ));
}

test "an identifier in a doc comment IS reported" {
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        "tools/weld_lint/x.zig",
        "/// what it does, since M1.B\npub const x = 1;\n",
    ));
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        "tools/weld_lint/x.zig",
        "//! module header, since G7\n",
    ));
}

test "several identifiers on one line are reported once each" {
    // The unit is the TOKEN and not the line: a line carrying two is two
    // findings, because a rule reporting one would go green on a half-fixed line.
    try std.testing.expectEqual(@as(usize, 3), try countOn(
        "tools/weld_lint/x.zig",
        "// M1.B, G7 and S3\n",
    ));
}

test "the rule speaks on a read file and is silent on the two silenced kinds" {
    // THREE STATES ON ONE SOURCE, and they are three distinct claims: out of
    // perimeter by decision, inside it but not read yet, and read. A test that
    // asserted only the first two would go green if the rule never spoke at all.
    const src: [:0]const u8 = "// see M1.B\n";
    try std.testing.expectEqual(@as(usize, 1), try countOn("tools/weld_lint/x.zig", src));
    try std.testing.expectEqual(@as(usize, 0), try countOn("tests/x.zig", src));
    var buf: [256]u8 = undefined;
    if (comment_scan.anUnreadExample(&buf)) |unread| {
        try std.testing.expectEqual(@as(usize, 0), try countOn(unread, src));
    }
    try std.testing.expectEqual(@as(usize, 0), try countOn("bench/x.zig", src));
}
