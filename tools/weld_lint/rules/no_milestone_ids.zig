//! Rule `no_milestone_ids` — no milestone, gate or review identifier in a comment.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_milestone_ids";

/// Whether a match produces a diagnostic or only a report line.
pub const enforced: bool = false;

/// Modifiers that make a following function-key token a key name, not a finding id.
const key_modifiers = [_][]const u8{
    "Alt", "alt", "Ctrl", "ctrl", "Shift", "shift", "Cmd", "cmd", "Meta", "meta", "Win", "win", "Super", "super",
};

/// What kind of identifier a match is.
const Kind = enum {
    milestone,
    gate,
    review,

    /// The word a diagnostic uses to name this kind.
    fn label(self: Kind) []const u8 {
        return switch (self) {
            .milestone => "milestone",
            .gate => "gate",
            .review => "review",
        };
    }
};

/// One identifier found in a comment.
pub const Match = struct {
    text: []const u8,
    kind: Kind,
    offset: usize,
};

/// Flag every identifier in a comment of `file`, when enforcing.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    if (!enforced) return;
    try collect(arena, file, source, out);
}

/// The matcher, callable with enforcement off so the report and the rule share it.
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

/// Byte offset of the `//` opening a comment on `line`, or null.
///
/// String and character literals are tracked, and a multiline-string
/// continuation line is skipped: the `//` a usage string prints is not a comment.
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
        // At least one dotted segment, which keeps a machine name out.
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
        'R' => {
            if (!std.mem.startsWith(u8, text[i..], "RD-")) return null;
            var j = i + 3;
            const digits_at = j;
            while (j < text.len and isDigit(text[j])) j += 1;
            if (j == digits_at) return null;
            if (j < text.len and isWordChar(text[j])) return null;
            return .{ .text = text[i..j], .kind = .review, .offset = i };
        },
        'G' => return numbered(text, i, 2, .gate),
        // One digit only: a longer run is a diagnostic code, not a gate.
        'E' => return numbered(text, i, 1, .gate),
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
    if (j < text.len and isWordChar(text[j])) return null;
    return .{ .text = text[i..j], .kind = kind, .offset = i };
}

/// True when a keyboard modifier sits immediately before the token.
///
/// Only the modifier, never the punctuation: a bare dash before a token is far
/// more often hyphenated prose naming a gate than a key combination.
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
    try std.testing.expectEqual(@as(usize, 0), try countOn("// median measured on an M4 Pro\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// M1 Pro, ReleaseFast\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// M1.0 closed the core language\n"));
}

test "a gate in hyphenated prose IS caught" {
    // Non-vacuity control for the key-modifier test below: a guard excluding every
    // hyphenated form would pass that test and lose all of these.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// mirrors the pre-E4 layout\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// Post-E4 the layout reserves two columns\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// byte-identical to the pre-E3 runtime\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn("// the pre-F1 kernel returned a zero normal\n"));
}

test "a keyboard modifier before the token is a key name, not a finding" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("/// User requested the window be closed (X button, Alt-F4).\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// Ctrl+F4 closes the tab\n"));
    // The bare token is still caught, so the exclusion is the modifier's.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// F4 is the finding this closes\n"));
}

test "the single-letter defect shape is outside the set, by arbitration" {
    // The token names a hotfix defect, a citable drift pattern of
    // `engine-audit-checklist.md` §3, and an interpreter pass, all three.
    try std.testing.expectEqual(@as(usize, 0), try countOn("// pattern D11 of `engine-audit-checklist.md` §3\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("// Inherent impl -> `methods`; trait impl handled in pass D2\n"));
    // Its companion milestone id is what reaches the history-bearing occurrences.
    try std.testing.expectEqual(@as(usize, 1), try countOn("// `add` is reserve-then-mutate (M1.1.1-HF1 D3/D4).\n"));
}

test "the rule reads comments, not code" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("const M1 = struct { pub const B = 1; };\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const label = \"M1.B\";\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("const sep = '/';\n"));
    // A trailing comment is a comment.
    try std.testing.expectEqual(@as(usize, 1), try countOn("const x = 1; // M1.B added this\n"));
}

test "a `//` inside a string literal does not open a comment" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("const url = \"http://example.com/M1.B\";\n"));
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
    try std.testing.expectEqual(@as(u32, 17), diags.items[0].col);
    try std.testing.expectEqual(@as(u32, 1), diags.items[0].line);
}
