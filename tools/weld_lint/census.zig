//! Comment census and token fingerprint — the two REPORTERS of the linter.
//!
//! Neither gates anything on a ratio, and neither ever will: `build.zig` wires
//! them to their own steps, not to `lint`, so no density number this file
//! computes has a path to an exit code that blocks a merge. A threshold on a
//! comment ratio makes the executed question "how do I get under it" instead of
//! "does this comment deserve to exist" (`engine-zig-conventions.md` §12).
//!
//! They live beside the rules because the census must walk EXACTLY the file set
//! the rules walk, and that set is defined once, in `scan.zig`. A separate
//! binary would need its own copy of the walker and its ignore list — two
//! answers to "what is in the perimeter", where a report would then describe a
//! different tree than the verdict printed next to it.
//!
//! The fingerprint is the one thing here that CAN fail: `fingerprint --check`
//! exits non-zero when a file's token stream moved. That is a check on token
//! identity, never on a quantity.

const std = @import("std");

/// Line counts for one source file.
///
/// `comment` and `code` partition the NON-BLANK lines: a line is a comment line
/// when its first non-whitespace bytes are `//`, and a code line otherwise. Blank
/// lines are in neither, so `density` is not diluted by spacing.
pub const Counts = struct {
    /// Non-blank lines that are not comment lines.
    code: usize = 0,
    /// Non-blank lines whose first non-whitespace bytes are `//`.
    comment: usize = 0,
    /// Subset of `comment` carrying `///` or `//!`.
    doc: usize = 0,
    /// Maximal runs of consecutive comment lines. The unit of judgement.
    blocks: usize = 0,

    /// Comment share of the non-blank lines, in percent. Zero for an empty file.
    pub fn density(self: Counts) f64 {
        const total = self.code + self.comment;
        if (total == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(self.comment)) / @as(f64, @floatFromInt(total));
    }

    /// Accumulate `other` into `self`.
    pub fn add(self: *Counts, other: Counts) void {
        self.code += other.code;
        self.comment += other.comment;
        self.doc += other.doc;
        self.blocks += other.blocks;
    }
};

/// Count `source` line by line.
///
/// A `//` inside a string literal is NOT a comment, and this pass does not know
/// that: it classifies on the first non-whitespace bytes of the line, so only a
/// line that STARTS with `//` counts. A trailing `// note` after code is a code
/// line here. That is the same convention the density figures of
/// `engine-development-workflow.md` §5.3 were measured under, and changing it
/// would make this tool's output incomparable with them.
pub fn countSource(source: []const u8) Counts {
    var c: Counts = .{};
    var in_block = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            in_block = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "//")) {
            c.comment += 1;
            if (std.mem.startsWith(u8, line, "///") or std.mem.startsWith(u8, line, "//!")) c.doc += 1;
            if (!in_block) c.blocks += 1;
            in_block = true;
        } else {
            c.code += 1;
            in_block = false;
        }
    }
    return c;
}

/// SHA-256 over the ordered `(tag, exact text)` sequence of `source`'s tokens.
///
/// POSITIONS ARE EXCLUDED and doc-comment tokens are dropped, which is what makes
/// this invariant under every edit this milestone is allowed to make and sensitive
/// to every edit it is not. An ordinary `//` comment produces no token at all, so
/// removing one cannot move the digest; `.doc_comment` and `.container_doc_comment`
/// DO produce tokens and are skipped explicitly. Whitespace produces no token, so
/// reindentation cannot move it either.
///
/// The tag is hashed alongside the text because the text alone is ambiguous: an
/// identifier `x` and a string `"x"` would otherwise collide once the quotes are
/// counted as text — and they are, `loc` spanning the delimiters.
pub fn fingerprint(source: [:0]const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var tok = std.zig.Tokenizer.init(source);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) continue;
        hasher.update(@tagName(t.tag));
        hasher.update(&.{0});
        hasher.update(source[t.loc.start..t.loc.end]);
        hasher.update(&.{0});
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Lowercase hex of a fingerprint, for printing and for parsing back.
pub fn hex(digest: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;
    return out;
}

/// Comment and code lines ADDED by a unified diff.
///
/// Counts only `+` lines, and only their content: `+++` headers are excluded by
/// requiring the second byte not to be `+`. Removed lines are not counted at all —
/// the quantity §5.3 measures is the density of what a gate WRITES, and a pass
/// that only deletes would otherwise report a ratio it never produced.
pub fn diffCounts(diff: []const u8) Counts {
    var c: Counts = .{};
    var in_block = false;
    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0 or raw[0] != '+') {
            in_block = false;
            continue;
        }
        if (raw.len >= 2 and raw[1] == '+') {
            in_block = false;
            continue;
        }
        const line = std.mem.trim(u8, raw[1..], " \t\r");
        if (line.len == 0) {
            in_block = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "//")) {
            c.comment += 1;
            if (std.mem.startsWith(u8, line, "///") or std.mem.startsWith(u8, line, "//!")) c.doc += 1;
            if (!in_block) c.blocks += 1;
            in_block = true;
        } else {
            c.code += 1;
            in_block = false;
        }
    }
    return c;
}

/// Rewrite `path` with `/` separators, into `arena`.
///
/// THE BASELINE IS A COMMITTED ARTEFACT AND CI READS IT ON THREE OPERATING
/// SYSTEMS. The walker yields `\`-separated paths on Windows, so a listing
/// written on POSIX would match nothing there and the check would report every
/// file MISSING — green nowhere, and for a reason that has nothing to do with
/// the token streams it is meant to compare. `no_precision_crossing` carries the
/// same hazard and answers it the same way.
pub fn normalizePath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dup = try arena.dupe(u8, path);
    for (dup) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return dup;
}

/// Order two `<digest, path>` rows by path, so the listing is a stable artefact.
///
/// The walker's order is the filesystem's, which differs between machines: an
/// unsorted listing would diff against itself on a re-run elsewhere, and a
/// reviewer could not tell that from a real move.
pub fn lessByPath(_: void, a: BaselineEntry, b: BaselineEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// One line of a fingerprint baseline: `<64 hex><tab><path>`.
pub const BaselineEntry = struct {
    /// Hex digest as it was written, compared byte for byte.
    digest: []const u8,
    /// Repo-relative path the digest was taken over.
    path: []const u8,
};

/// Parse a baseline listing. Blank lines and `#` comments are skipped; any other
/// malformed line is an error rather than a silent skip, because a baseline that
/// quietly loses entries is a check that quietly stops checking.
pub fn parseBaseline(
    arena: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList(BaselineEntry),
) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.MalformedBaseline;
        const digest = line[0..tab];
        const path = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
        if (digest.len != 64 or path.len == 0) return error.MalformedBaseline;
        try out.append(arena, .{ .digest = digest, .path = path });
    }
}

test "density partitions the non-blank lines and ignores blanks" {
    const c = countSource(
        \\const a = 1;
        \\
        \\// one
        \\// two
        \\const b = 2;
    );
    try std.testing.expectEqual(@as(usize, 2), c.code);
    try std.testing.expectEqual(@as(usize, 2), c.comment);
    try std.testing.expectEqual(@as(usize, 1), c.blocks);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), c.density(), 1e-9);
}

test "a blank line ends a block, so two runs are two units of judgement" {
    // The block is what the pass judges whole; a run separated by a blank line is
    // a second decision, not a continuation of the first.
    const c = countSource(
        \\// a
        \\
        \\// b
        \\const x = 0;
    );
    try std.testing.expectEqual(@as(usize, 2), c.blocks);
    try std.testing.expectEqual(@as(usize, 2), c.comment);
}

test "a trailing comment after code counts as code, not as a comment line" {
    // NON-VACUITY for the convention stated on `countSource`: were it otherwise,
    // this file's own marker lines would move every density figure it reports.
    const c = countSource("const x = 0; // note\n");
    try std.testing.expectEqual(@as(usize, 1), c.code);
    try std.testing.expectEqual(@as(usize, 0), c.comment);
}

test "doc lines are a subset of comment lines" {
    const c = countSource(
        \\//! module
        \\/// decl
        \\// plain
        \\const x = 0;
    );
    try std.testing.expectEqual(@as(usize, 3), c.comment);
    try std.testing.expectEqual(@as(usize, 2), c.doc);
}

test "the fingerprint survives removing an ordinary comment" {
    const a: [:0]const u8 = "const x = 1;\n";
    const b: [:0]const u8 = "// explanation\nconst x = 1;\n";
    try std.testing.expectEqual(fingerprint(a), fingerprint(b));
}

test "the fingerprint survives removing a doc comment" {
    // `.doc_comment` IS a token, unlike `//`, so this half is bought by the
    // explicit skip in `fingerprint` and not by the tokenizer.
    const a: [:0]const u8 = "pub const x = 1;\n";
    const b: [:0]const u8 = "/// what x is\npub const x = 1;\n";
    try std.testing.expectEqual(fingerprint(a), fingerprint(b));
}

test "the fingerprint survives reindentation" {
    const a: [:0]const u8 = "fn f() void {\nreturn;\n}\n";
    const b: [:0]const u8 = "fn f() void {\n        return;\n}\n";
    try std.testing.expectEqual(fingerprint(a), fingerprint(b));
}

test "the fingerprint moves on an inserted token" {
    // The other direction, and it is the one that makes the three above mean
    // something: a digest only shown to be stable is not shown to be sound.
    const a: [:0]const u8 = "const x = 1;\n";
    const b: [:0]const u8 = "const x = 1 + 0;\n";
    try std.testing.expect(!std.mem.eql(u8, &fingerprint(a), &fingerprint(b)));
}

test "the fingerprint moves on a deleted token" {
    const a: [:0]const u8 = "const x = 1;\n";
    const b: [:0]const u8 = "const x = ;\n";
    try std.testing.expect(!std.mem.eql(u8, &fingerprint(a), &fingerprint(b)));
}

test "the fingerprint moves on a renamed test" {
    // The case that puts the test-name sweep OUTSIDE this oracle: a name lives in
    // a `string_literal`, so renaming one is a token edit and reads as a code
    // change here.
    const a: [:0]const u8 = "test \"one\" {}\n";
    const b: [:0]const u8 = "test \"two\" {}\n";
    try std.testing.expect(!std.mem.eql(u8, &fingerprint(a), &fingerprint(b)));
}

test "the fingerprint separates an identifier from the string of the same text" {
    // Why the tag is hashed beside the text: `loc` spans the quotes, so `x` and
    // `"x"` would still differ — but `@tagName` is what makes that structural
    // rather than a property of how the tokenizer happens to place `loc`.
    const a: [:0]const u8 = "const v = x;\n";
    const b: [:0]const u8 = "const v = \"x\";\n";
    try std.testing.expect(!std.mem.eql(u8, &fingerprint(a), &fingerprint(b)));
}

test "diff counts added lines only, and skips the +++ header" {
    const c = diffCounts(
        \\--- a/x.zig
        \\+++ b/x.zig
        \\@@ -1,2 +1,4 @@
        \\ context
        \\-// removed
        \\+// added one
        \\+// added two
        \\+const x = 1;
    );
    try std.testing.expectEqual(@as(usize, 2), c.comment);
    try std.testing.expectEqual(@as(usize, 1), c.code);
    try std.testing.expectEqual(@as(usize, 1), c.blocks);
}

test "a baseline line parses into its digest and its path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(BaselineEntry) = .empty;
    const sixty_four = "0" ** 64;
    try parseBaseline(arena, "# header\n\n" ++ sixty_four ++ "\tsrc/a.zig\n", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("src/a.zig", out.items[0].path);
}

test "a Windows path normalises to the baseline spelling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try normalizePath(arena_state.allocator(), "src\\core\\ecs\\world.zig");
    try std.testing.expectEqualStrings("src/core/ecs/world.zig", p);
}

test "a POSIX path normalises to itself" {
    // NON-VACUITY: the rewrite must be a no-op on the spelling the baseline is
    // written in, or the check would fail on the platform that generated it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try normalizePath(arena_state.allocator(), "src/core/ecs/world.zig");
    try std.testing.expectEqualStrings("src/core/ecs/world.zig", p);
}

test "rows sort by path" {
    var rows = [_]BaselineEntry{
        .{ .digest = "b", .path = "src/z.zig" },
        .{ .digest = "a", .path = "src/a.zig" },
    };
    std.mem.sort(BaselineEntry, &rows, {}, lessByPath);
    try std.testing.expectEqualStrings("src/a.zig", rows[0].path);
}

test "a malformed baseline line is an error, never a silent skip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(BaselineEntry) = .empty;
    try std.testing.expectError(
        error.MalformedBaseline,
        parseBaseline(arena_state.allocator(), "deadbeef\tsrc/a.zig\n", &out),
    );
}
