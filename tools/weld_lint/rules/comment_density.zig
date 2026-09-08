//! Rule `comment_density` — a per-file ceiling on the fraction of comment lines.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "comment_density";

/// The ceiling, as a percentage of `comment + code` lines.
pub const ceiling_percent: u32 = 25;

/// Whether a file over the ceiling produces a diagnostic or only a report line.
pub const enforced: bool = false;

/// Path of the allowlist, relative to the repository root.
pub const allowlist_path = "tools/weld_lint/comment_density_allowlist.txt";

/// Directory prefixes the ceiling applies to.
pub const perimeter = [_][]const u8{ "src", "tools", "bench" };

/// Per-file line counts.
pub const Counts = struct {
    comment: u32 = 0,
    code: u32 = 0,

    /// True when the file is over the ceiling; equality passes.
    pub fn exceedsCeiling(self: Counts) bool {
        const total = self.comment + self.code;
        if (total == 0) return false;
        return @as(u64, self.comment) * 100 > @as(u64, ceiling_percent) * @as(u64, total);
    }

    /// Ratio in hundredths of a percent.
    pub fn ratioBasisPoints(self: Counts) u32 {
        const total = self.comment + self.code;
        if (total == 0) return 0;
        return @intCast(@as(u64, self.comment) * 10_000 / @as(u64, total));
    }

    /// How many comment lines must go for this file to reach the ceiling.
    ///
    /// NOT the excess over the ceiling: removing a comment line shrinks the
    /// denominator too, so the surviving count is `code * ceiling / (100 - ceiling)`.
    pub fn linesOverCeiling(self: Counts) u32 {
        const keep: u64 = @as(u64, self.code) * ceiling_percent / (100 - ceiling_percent);
        if (self.comment <= keep) return 0;
        return @intCast(@as(u64, self.comment) - keep);
    }
};

/// Count the comment and code lines of `source`.
///
/// A comment line's first non-blank token is `//`; blank lines are in neither term
/// and a trailing comment belongs to its code line. Counting trailing comments
/// would let a file reach the ceiling by moving text rather than removing it.
pub fn countLines(source: []const u8) Counts {
    var counts: Counts = .{};
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) {
            counts.comment += 1;
        } else {
            counts.code += 1;
        }
    }
    return counts;
}

/// One allowlist entry: a file that cannot reach the ceiling, and why.
pub const Entry = struct {
    path: []const u8,
    reason: []const u8,
    line: u32,
    seen: bool = false,
    over: bool = false,
};

/// Parsed allowlist plus the per-file measurements of one run.
pub const Tally = struct {
    entries: std.ArrayList(Entry) = .empty,
    files: std.ArrayList(Measured) = .empty,

    pub const Measured = struct {
        path: []const u8,
        counts: Counts,
    };

    /// Release both lists.
    pub fn deinit(self: *Tally, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.files.deinit(gpa);
    }

    fn find(self: *Tally, path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (samePath(e.path, path)) return e;
        }
        return null;
    }
};

/// Parse the allowlist: `<path> | <reason>` per line, `#` comments, blanks ignored.
///
/// An entry with an empty reason is refused rather than accepted half-parsed.
pub fn parseAllowlist(
    arena: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
    tally: *Tally,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const bar = std.mem.indexOfScalar(u8, line, '|') orelse {
            try out.append(arena, .{
                .file = file,
                .line = line_no,
                .col = 1,
                .rule = name,
                .message = "allowlist entry needs `<path> | <reason>` — an exemption without a reason is a bypass",
            });
            continue;
        };
        const path = std.mem.trim(u8, line[0..bar], " \t");
        const reason = std.mem.trim(u8, line[bar + 1 ..], " \t");
        if (path.len == 0 or reason.len == 0) {
            try out.append(arena, .{
                .file = file,
                .line = line_no,
                .col = 1,
                .rule = name,
                .message = "allowlist entry needs a non-empty path and a non-empty reason",
            });
            continue;
        }
        try tally.entries.append(arena, .{ .path = path, .reason = reason, .line = line_no });
    }
}

/// Measure `file` and, when enforcing, flag it if it is over the ceiling.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
    tally: *Tally,
) !void {
    if (!inPerimeter(file)) return;

    const counts = countLines(source);
    try tally.files.append(arena, .{ .path = file, .counts = counts });

    const over = counts.exceedsCeiling();
    if (tally.find(file)) |entry| {
        entry.seen = true;
        entry.over = over;
        return;
    }
    if (!over) return;
    if (!enforced) return;

    try out.append(arena, .{
        .file = file,
        .line = 1,
        .col = 1,
        .rule = name,
        .message = try std.fmt.allocPrint(
            arena,
            "comment density {d}.{d:0>2} % exceeds the {d} % ceiling " ++
                "({d} comment lines, {d} code lines — {d} to remove, or an allowlist entry with its reason)",
            .{
                counts.ratioBasisPoints() / 100,
                counts.ratioBasisPoints() % 100,
                ceiling_percent,
                counts.comment,
                counts.code,
                counts.linesOverCeiling(),
            },
        ),
    });
}

/// Flag every allowlist entry naming no measured file, or a file under the ceiling.
///
/// `perimeter_walked` must be false for a partial invocation: it reads fewer files
/// and cannot tell a stale entry from an unvisited one.
pub fn checkAllowlist(
    arena: std.mem.Allocator,
    tally: *Tally,
    out: *std.ArrayList(diag.Diagnostic),
    perimeter_walked: bool,
) !void {
    for (tally.entries.items) |e| {
        if (!e.seen) {
            if (!perimeter_walked) continue;
            try out.append(arena, .{
                .file = allowlist_path,
                .line = e.line,
                .col = 1,
                .rule = name,
                .message = try std.fmt.allocPrint(
                    arena,
                    "allowlist names `{s}`, which this run did not measure — a path that matches no file grants nothing",
                    .{e.path},
                ),
            });
            continue;
        }
        if (!e.over) {
            try out.append(arena, .{
                .file = allowlist_path,
                .line = e.line,
                .col = 1,
                .rule = name,
                .message = try std.fmt.allocPrint(
                    arena,
                    "allowlist names `{s}`, which is UNDER the {d} % ceiling — remove the entry",
                    .{ e.path, ceiling_percent },
                ),
            });
        }
    }
}

/// True when `file`'s first path segment is one of `perimeter`.
///
/// By segment: a `src/` prefix test puts the whole tree outside the perimeter on
/// Windows, where the walker emits `\`, and the rule passes by measuring nothing.
pub fn inPerimeter(file: []const u8) bool {
    var it = std.mem.splitScalar(u8, file, std.fs.path.sep);
    const first = it.next() orelse return false;
    for (perimeter) |dir| {
        if (std.mem.eql(u8, first, dir)) return true;
    }
    return false;
}

/// Path equality treating `\` and `/` alike, so one allowlist serves both platforms.
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '\\') '/' else ca;
        const nb = if (cb == '\\') '/' else cb;
        if (na != nb) return false;
    }
    return true;
}

fn countOn(source: []const u8) Counts {
    return countLines(source);
}

test "a comment line is one whose first non-blank token is //" {
    const c = countOn(
        \\// a full-line comment
        \\    // an indented one
        \\/// a doc comment
        \\//! a module doc comment
        \\const x = 1;
        \\
    );
    try std.testing.expectEqual(@as(u32, 4), c.comment);
    try std.testing.expectEqual(@as(u32, 1), c.code);
}

test "a trailing comment is code, not comment" {
    // Same two comments twice: if trailing ones counted, both would read 2/1.
    const trailing = countOn("const x = 1; // why\nconst y = 2; // why\n");
    try std.testing.expectEqual(@as(u32, 0), trailing.comment);
    try std.testing.expectEqual(@as(u32, 2), trailing.code);

    const own_lines = countOn("// why\nconst x = 1;\n// why\nconst y = 2;\n");
    try std.testing.expectEqual(@as(u32, 2), own_lines.comment);
    try std.testing.expectEqual(@as(u32, 2), own_lines.code);
}

test "blank lines are in neither term" {
    const c = countOn("\n// c\n\n   \nconst x = 1;\n\n");
    try std.testing.expectEqual(@as(u32, 1), c.comment);
    try std.testing.expectEqual(@as(u32, 1), c.code);
    try std.testing.expectEqual(@as(u32, 5000), c.ratioBasisPoints());
}

test "a multiline string literal line is code even when it contains //" {
    const c = countOn(
        \\const usage =
        \\    \\  // this is help text, not a comment
        \\;
        \\
    );
    try std.testing.expectEqual(@as(u32, 0), c.comment);
    try std.testing.expectEqual(@as(u32, 3), c.code);
}

test "the boundary is exact — at the ceiling passes, one line above fails" {
    var at: Counts = .{ .comment = 25, .code = 75 };
    try std.testing.expect(!at.exceedsCeiling());
    try std.testing.expectEqual(@as(u32, 2500), at.ratioBasisPoints());

    var over: Counts = .{ .comment = 26, .code = 75 };
    try std.testing.expect(over.exceedsCeiling());

    // Below the ceiling too, so this pins a boundary and not one side of it.
    var under: Counts = .{ .comment = 24, .code = 75 };
    try std.testing.expect(!under.exceedsCeiling());
}

test "an empty file is not over the ceiling" {
    var empty: Counts = .{};
    try std.testing.expect(!empty.exceedsCeiling());
    try std.testing.expectEqual(@as(u32, 0), empty.ratioBasisPoints());
}

test "linesOverCeiling accounts for the denominator shrinking" {
    // The excess over the ceiling would answer 44 here.
    var worst: Counts = .{ .comment = 61, .code = 4 };
    try std.testing.expectEqual(@as(u32, 60), worst.linesOverCeiling());

    // The survivor must actually pass, or the bound is arithmetic.
    var after: Counts = .{ .comment = 61 - 60, .code = 4 };
    try std.testing.expect(!after.exceedsCeiling());

    var fine: Counts = .{ .comment = 10, .code = 90 };
    try std.testing.expectEqual(@as(u32, 0), fine.linesOverCeiling());
}

test "the perimeter is decided by segment" {
    try std.testing.expect(inPerimeter("src" ++ [_]u8{std.fs.path.sep} ++ "core" ++ [_]u8{std.fs.path.sep} ++ "root.zig"));
    try std.testing.expect(inPerimeter("tools" ++ [_]u8{std.fs.path.sep} ++ "weld_lint" ++ [_]u8{std.fs.path.sep} ++ "main.zig"));
    try std.testing.expect(inPerimeter("bench" ++ [_]u8{std.fs.path.sep} ++ "ecs_benchmark.zig"));
    try std.testing.expect(!inPerimeter("tests" ++ [_]u8{std.fs.path.sep} ++ "lint" ++ [_]u8{std.fs.path.sep} ++ "x.zig"));
    // Not a prefix match.
    try std.testing.expect(!inPerimeter("srcgen" ++ [_]u8{std.fs.path.sep} ++ "x.zig"));
}

/// Drive `check` over one synthetic file and return the diagnostics it produced.
fn checkOn(
    arena: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    allowlist: []const u8,
    diags: *std.ArrayList(diag.Diagnostic),
) !void {
    var tally: Tally = .{};
    defer tally.deinit(arena);
    try parseAllowlist(arena, allowlist_path, allowlist, &tally, diags);
    try check(arena, path, source, diags, &tally);
    try checkAllowlist(arena, &tally, diags, true);
}

const dense_src: [:0]const u8 =
    \\// one
    \\// two
    \\// three
    \\const x = 1;
    \\
;

test "a file over the ceiling is reported only once enforcement is on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;

    const path = "src" ++ [_]u8{std.fs.path.sep} ++ "dense.zig";
    try checkOn(arena, path, dense_src, "", &diags);

    // 75 %, so what this pins is the mode and not the measurement.
    try std.testing.expect(countLines(dense_src).exceedsCeiling());
    if (enforced) {
        try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    } else {
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }
}

test "a file outside the perimeter is measured by nobody" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;

    const path = "tests" ++ [_]u8{std.fs.path.sep} ++ "dense.zig";
    try checkOn(arena, path, dense_src, "", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "an allowlist entry for a file UNDER the ceiling is itself a diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;

    const sparse: [:0]const u8 =
        \\// one
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
        \\const d = 4;
        \\
    ;
    const path = "src/sparse.zig";
    try checkOn(arena, path, sparse, "src/sparse.zig | no reason can be true here\n", &diags);

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "UNDER") != null);
}

test "an allowlist entry naming no measured file is a diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;

    try checkOn(arena, "src/dense.zig", dense_src, "src/typo_in_this_path.zig | stale\n", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "did not measure") != null);
}

test "an allowlist entry suppresses the ceiling diagnostic for its file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;

    try checkOn(arena, "src/dense.zig", dense_src, "src/dense.zig | every survivor meets the criterion\n", &diags);
    // Zero in both modes: the entry is legitimate, so neither half fires either.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "an allowlist entry without a reason is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    var tally: Tally = .{};
    defer tally.deinit(arena);

    // No separator, then a separator with nothing after it.
    try parseAllowlist(
        arena,
        allowlist_path,
        "src/a.zig\nsrc/b.zig |   \n",
        &tally,
        &diags,
    );
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
    try std.testing.expectEqual(@as(usize, 0), tally.entries.items.len);
}

test "allowlist parsing skips blanks and # comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    var tally: Tally = .{};
    defer tally.deinit(arena);

    try parseAllowlist(
        arena,
        allowlist_path,
        "# a header line\n\n   \nsrc/a.zig | a reason\n",
        &tally,
        &diags,
    );
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), tally.entries.items.len);
    try std.testing.expectEqualStrings("src/a.zig", tally.entries.items[0].path);
    try std.testing.expectEqualStrings("a reason", tally.entries.items[0].reason);
}
