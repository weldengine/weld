//! Rule `no_milestone_ids` — no milestone, gate or review identifier in a comment.
//!
//! `M1.B`, `M1.1.15.1`, `G7`, `E4`, `P1-3`, `RD-1`, `B1`, `F2` name a moment in the
//! project's history, and history lives in `git log`. A comment that needs one is
//! recording how the code came to be rather than what a reader must not get wrong;
//! a comment that needs the FACT the milestone established states the fact.
//!
//! THE SHAPE SET WAS AUDITED, NOT ASSUMED, and the audit changed it twice.
//!
//! `M<digit>.<segment>…` — 61 distinct tokens over 3 131 occurrences in `src/`, every
//! one a genuine milestone identifier. `M4` and `M1 Pro` (the reference machine) do
//! not match: a milestone identifier carries at least one dotted segment.
//!
//! `D<n>` IS DELIBERATELY NOT IN THE SET, and this is the rule naming what it does
//! not cover. The token is overloaded three ways across 33 occurrences: a hotfix
//! defect id (`M1.1.1-HF1 D3/D4`, 24 of them), a drift pattern of
//! `engine-audit-checklist.md` §3 which is a citable registry entry like `ARCH-nnn`
//! and is written WITH its owner (`pattern D11 of …`, 4), and the interpreter's own
//! internal pass name (`pass D2`, 2). No regex separates history from a citation
//! here. The 24 that are history travel beside an `M1.1.1-HF1` the milestone shape
//! already catches, so the class is reached through its companion instead of through
//! an ambiguous token.
//!
//! `ARCH-nnn`, `C0.5`/`C1.1` and the four-digit diagnostic codes are NOT history and
//! no shape matches them: an invariant, a phase criterion and `E0503` are citable
//! identifiers of live registries. `E<n>` matches a SINGLE digit, which is what
//! separates the gate `E4` from the diagnostic `E0503`.
//!
//! THE ONE FALSE POSITIVE THE AUDIT FOUND, and why the obvious guard was refused.
//! `Alt-F4` in `platform/window.zig` is a key name. The reflex fix — ignore a match
//! preceded by `-` — was MEASURED against the tree and rejected: of the 13 shape
//! tokens preceded by `-` or `+`, twelve are real gates in hyphenated prose (`pre-E4`
//! layout, `Post-E4`, `pre-E3` runtime) and one is the key. That guard would have
//! bought one true negative for twelve false ones. What ships instead names exactly
//! what it excludes: a keyboard modifier immediately before the token.
//!
//! MODE. Report at first, blocking on the whole scanned tree at the closing gate,
//! same reason as `comment_density`: with the tree carrying some 5 400 occurrences
//! the rule would fail the build before a line had been removed.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_milestone_ids";

/// Whether a match produces a DIAGNOSTIC or only a report line. Flipped at the
/// closing gate — one line, greppable, a property of the tree's state.
pub const enforced: bool = false;

/// Keyboard modifiers that turn a following `F<n>` into a key name.
///
/// Narrow on purpose. A broad "preceded by a dash" exclusion was measured to cost
/// twelve real gate references to save this one key, so the exclusion names the
/// keys instead of the punctuation.
const key_modifiers = [_][]const u8{
    "Alt", "alt", "Ctrl", "ctrl", "Shift", "shift", "Cmd", "cmd", "Meta", "meta", "Win", "win", "Super", "super",
};

/// The kinds of identifier this rule recognises, each with the vocabulary a
/// diagnostic uses to name it.
const Kind = enum {
    milestone,
    gate,
    review,

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .milestone => "milestone",
            .gate => "gate",
            .review => "review",
        };
    }
};

/// A match: the identifier text and what kind it is.
pub const Match = struct {
    text: []const u8,
    kind: Kind,
    /// Byte offset of the match within the line.
    offset: usize,
};

/// Hook called by `main.runLint` once per `.zig` file.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    if (!enforced) return;
    try collect(arena, file, source, out);
}

/// The rule's body, separated from its enforcement so the report subcommand and
/// the unit tests exercise the SAME matcher the blocking mode will use. A report
/// built on a second matcher would measure a quantity the rule does not enforce.
pub fn collect(
    arena: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const start = commentStart(line) orelse continue;
        const text = line[start..];

        var scan_at: usize = 0;
        while (findIdentifier(text, scan_at)) |m| {
            scan_at = m.offset + m.text.len;
            try out.append(arena, .{
                .file = file,
                .line = line_no,
                .col = @intCast(start + m.offset + 1),
                .rule = name,
                .message = try std.fmt.allocPrint(
                    arena,
                    "{s} identifier `{s}` in a comment — history lives in `git log`; " ++
                        "state the fact it established, or cite a live registry (`ARCH-nnn`, a criterion, a diagnostic code)",
                    .{ m.kind.label(), m.text },
                ),
            });
        }
    }
}

/// Byte offset of the `//` that opens a comment on `line`, or null.
///
/// Tracks string and character literals so a `//` inside `"http://x"` is not a
/// comment, and skips a multiline-string continuation line outright: the `//` a
/// usage string contains is text the program prints, and treating it as a comment
/// would let this rule fire on help output.
pub fn commentStart(line: []const u8) ?usize {
    const trimmed_start = firstNonBlank(line) orelse return null;
    if (std.mem.startsWith(u8, line[trimmed_start..], "\\\\")) return null;

    var i: usize = 0;
    var in_string = false;
    var in_char = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string or in_char) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (in_string and c == '"') in_string = false;
            if (in_char and c == '\'') in_char = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '\'' => in_char = true,
            '/' => {
                if (i + 1 < line.len and line[i + 1] == '/') return i;
            },
            else => {},
        }
    }
    return null;
}

fn firstNonBlank(line: []const u8) ?usize {
    for (line, 0..) |c, i| {
        if (c != ' ' and c != '\t' and c != '\r') return i;
    }
    return null;
}

/// Find the first identifier in `text` at or after `from`, or null.
pub fn findIdentifier(text: []const u8, from: usize) ?Match {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (!isWordBoundaryBefore(text, i)) continue;
        if (matchAt(text, i)) |m| return m;
    }
    return null;
}

fn matchAt(text: []const u8, i: usize) ?Match {
    const c = text[i];
    switch (c) {
        // `M0.8`, `M1.1.15.2`, `M1.B`, `M1.D.13` — at least one dotted segment,
        // which is what keeps `M4 Pro` out.
        'M' => {
            var j = i + 1;
            if (j >= text.len or !isDigit(text[j])) return null;
            while (j < text.len and isDigit(text[j])) j += 1;
            var segments: usize = 0;
            while (j < text.len and text[j] == '.') {
                var k = j + 1;
                while (k < text.len and isAlnum(text[k])) k += 1;
                if (k == j + 1) break;
                j = k;
                segments += 1;
            }
            if (segments == 0) return null;
            return .{ .text = text[i..j], .kind = .milestone, .offset = i };
        },
        // `RD-1` — a recorded deviation.
        'R' => {
            if (!std.mem.startsWith(u8, text[i..], "RD-")) return null;
            var j = i + 3;
            const digits_at = j;
            while (j < text.len and isDigit(text[j])) j += 1;
            if (j == digits_at) return null;
            if (j < text.len and isWordChar(text[j])) return null;
            return .{ .text = text[i..j], .kind = .review, .offset = i };
        },
        // `G7`, `G10` — a gate.
        'G' => return numbered(text, i, 2, .gate),
        // `E4` — a gate. ONE digit only: `E0503` is a diagnostic code.
        'E' => return numbered(text, i, 1, .gate),
        // `P1`, `P1-3`, `P1b` — a review pass or its findings.
        'P' => {
            var j = i + 1;
            if (j >= text.len or !isDigit(text[j])) return null;
            j += 1;
            if (j < text.len and text[j] == '-') {
                var k = j + 1;
                while (k < text.len and isDigit(text[k])) k += 1;
                if (k > j + 1) j = k;
            } else if (j < text.len and isLower(text[j])) {
                j += 1;
            }
            if (j < text.len and isWordChar(text[j])) return null;
            return .{ .text = text[i..j], .kind = .review, .offset = i };
        },
        // `B1`, `F2`, `H1`, `N4` — blocker, finding, hotfix and note ids. Excluded
        // when a keyboard modifier sits immediately before, which is the one false
        // positive the tree-wide audit found.
        'B', 'F', 'H', 'N' => {
            if (precededByKeyModifier(text, i)) return null;
            const width: usize = if (c == 'N') 1 else 2;
            return numbered(text, i, width, .review);
        },
        else => return null,
    }
}

/// `<letter><1..max_digits>` followed by a non-word character.
fn numbered(text: []const u8, i: usize, max_digits: usize, kind: Kind) ?Match {
    var j = i + 1;
    var digits: usize = 0;
    while (j < text.len and isDigit(text[j]) and digits < max_digits) {
        j += 1;
        digits += 1;
    }
    if (digits == 0) return null;
    // A longer run of digits is a different vocabulary: `E0503` is a diagnostic
    // code, not the gate `E0`.
    if (j < text.len and isWordChar(text[j])) return null;
    return .{ .text = text[i..j], .kind = kind, .offset = i };
}

fn precededByKeyModifier(text: []const u8, i: usize) bool {
    if (i == 0) return false;
    const sep = text[i - 1];
    if (sep != '-' and sep != '+') return false;
    const before = text[0 .. i - 1];
    for (key_modifiers) |mod| {
        if (std.mem.endsWith(u8, before, mod)) return true;
    }
    return false;
}

fn isWordBoundaryBefore(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    return !isWordChar(text[i - 1]);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isAlnum(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isWordChar(c: u8) bool {
    return isAlnum(c) or c == '_';
}

// ─── tests ──────────────────────────────────────────────────────────────────

fn countOn(source: []const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try collect(arena_state.allocator(), "probe.zig", source, &diags);
    return diags.items.len;
}

fn firstMessage(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try collect(arena, "probe.zig", source, &diags);
    if (diags.items.len == 0) return "";
    return diags.items[0].message;
}

test "the five identifier shapes named in the rule are caught" {
    try std.testing.expectEqual(@as(usize, 1), try countOn("// M1.B — the second storage mode\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// see M1.1.15.1 for the measurement\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// G7 froze the surface\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// P1-3 measured ten sites\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// RD-1 authorised the change\n"));
}

test "a gate letter is caught, and a diagnostic code is not" {
    // The discriminating pair, and the whole reason `E` matches one digit: `E4` is
    // a gate of a brief, `E0503` is a live diagnostic code of `etch-diagnostics.md`.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// E4 added the sidecars\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// returns `E0503` when the value is out of domain\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// `W0902` fires on a public impl of a private type\n"));
}

test "live registry identifiers are not history and are not caught" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("// `ARCH-030` makes the access set the type of the view\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// C1.1 requires 1000 dynamic bodies at 60 Hz\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// C0.5 froze this interface\n"));
}

test "a milestone identifier needs a dotted segment, so a machine name is not one" {
    // `M4 Pro` is the reference machine and appears in bench headers.
    try std.testing.expectEqual(@as(usize, 0), try countOn("// median measured on an M4 Pro\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// M1 Pro, ReleaseFast\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// M1.0 closed the core language\n"));
}

test "a gate in hyphenated prose IS caught — the twelve the naive guard would have lost" {
    // Measured on the tree: twelve of the thirteen shape tokens preceded by `-` or
    // `+` are real gates written this way. This test is the non-vacuity control for
    // the key-modifier test below: a guard that excluded every hyphenated form
    // would pass that test and silently lose all of these.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// mirrors the pre-E4 layout\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// Post-E4 the layout reserves two columns\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// byte-identical to the pre-E3 runtime\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// the pre-F1 kernel returned a zero normal\n"));
}

test "a keyboard modifier before the token is a key name, not a finding" {
    // The one false positive the tree-wide audit found.
    try std.testing.expectEqual(@as(usize, 0), try countOn("/// User requested the window be closed (X button, Alt-F4).\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// Ctrl+F4 closes the tab\n"));
    // And the bare token is still caught, so the exclusion is about the modifier
    // and not about the letter.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// F4 is the finding this closes\n"));
}

test "`D<n>` is outside the shape set, by arbitration" {
    // Not an oversight: the token is a hotfix defect id, an audit-checklist drift
    // pattern that is a citable registry entry, and an interpreter pass name. The
    // rule's header names the measurement.
    try std.testing.expectEqual(@as(usize, 0), try countOn("// pattern D11 of `engine-audit-checklist.md` §3\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// Inherent impl -> `methods`; trait impl handled in pass D2\n"));
    // But the companion milestone id on a hotfix line IS caught, which is how the
    // 24 history-bearing occurrences are reached.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// `add` is reserve-then-mutate (M1.1.1-HF1 D3/D4).\n"));
}

test "the rule reads comments, not code" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("const M1 = struct { pub const B = 1; };\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const label = \"M1.B\";\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const sep = '/';\n"));
    // A trailing comment IS a comment: an identifier is history wherever it sits.
    try std.testing.expectEqual(@as(usize, 1), try countOn("const x = 1; // M1.B added this\n"));
}

test "a `//` inside a string literal does not open a comment" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("const url = \"http://example.com/M1.B\";\n"));
    // And an identifier after the real comment on the same line is still found.
    try std.testing.expectEqual(@as(usize, 1), try countOn("const url = \"http://x\"; // M1.B\n"));
}

test "a multiline string literal line is not a comment" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        \\const usage =
        \\    \\  // M1.B is printed as help text
        \\;
        \\
    ));
}

test "every identifier on a line is reported, not just the first" {
    try std.testing.expectEqual(@as(usize, 3), try countOn("// M1.B / G10 closed P1-2\n"));
}

test "the diagnostic names the kind and quotes the identifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const milestone = try firstMessage(arena, "// M1.B\n");
    try std.testing.expect(std.mem.indexOf(u8, milestone, "milestone identifier `M1.B`") != null);

    const gate = try firstMessage(arena, "// G7\n");
    try std.testing.expect(std.mem.indexOf(u8, gate, "gate identifier `G7`") != null);

    const review = try firstMessage(arena, "// RD-1\n");
    try std.testing.expect(std.mem.indexOf(u8, review, "review identifier `RD-1`") != null);
}

test "the reported column points at the identifier inside the comment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try collect(arena_state.allocator(), "probe.zig", "const x = 1; // M1.B\n", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    // `const x = 1; // ` is 16 bytes, so the identifier starts at column 17.
    try std.testing.expectEqual(@as(u32, 17), diags.items[0].col);
    try std.testing.expectEqual(@as(u32, 1), diags.items[0].line);
}
