//! Rule `comment_density` — a per-file ceiling on the fraction of comment lines.
//!
//! A density ceiling is not a measurement, it is a house rule of the same class as
//! a line-length limit, and it is written down rather than derived: **25 %**. It is
//! not adjusted to fit whatever a pass happens to produce.
//!
//! WHAT A COMMENT LINE IS. A line whose first non-blank token is `//`. Trailing
//! comments do not count toward the ratio — they are a review concern, and counting
//! them would make the ceiling reachable by moving a comment rather than by
//! removing it.
//!
//! WHAT THE DENOMINATOR IS, and this was measured rather than chosen. The ratio is
//! `comment / (comment + code)` with blank lines in NEITHER term. Four candidate
//! denominators were computed over `src/`; only this one reproduces the recorded
//! baseline — 275 files, 46 963 comment lines, 114 631 code lines, 29.06 % — to the
//! digit. `comment / total_lines` gives 26.76 % on the same tree, so a rule written
//! on it would be measuring a different quantity under the same name.
//!
//! THE COMPARISON IS INTEGER, so the boundary is exact and not a rounding: a file
//! exceeds when `comment * 100 > ceiling * (comment + code)`. At exactly the
//! ceiling it passes; one comment line above, it fails.
//!
//! PERIMETER — `src/` only, and the bound is the milestone's, not a modesty. The
//! conservation criterion was applied to `src/`, so that is where the ceiling can
//! be met; `bench/`, `tests/` and `tools/` were never swept and a ceiling there
//! would be a rule that fires on work nobody has done. Their density is explicitly
//! not measured and not ceilinged.
//!
//! THE ALLOWLIST IS NOT A BYPASS, and the check that makes it one is bilateral.
//! A file whose every remaining comment meets the conservation criterion and which
//! still exceeds the ceiling is listed with a one-line reason — that is the declared
//! escape. The other direction is what keeps it honest: an entry naming a file that
//! does NOT exceed the ceiling is itself a diagnostic, so a stale entry cannot sit
//! there granting an exemption nobody needs. Same shape as the declared exclusions
//! of `dead_tests` and the escape list of `no_precision_crossing`.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "comment_density";

/// The ceiling, as a percentage of `comment + code` lines. A house rule.
pub const ceiling_percent: u32 = 25;

/// Whether a file over the ceiling produces a DIAGNOSTIC or only a report line.
///
/// The removal pass and the rule that prevents its undoing cannot both land at
/// once: with the tree at 29 % the rule would fail the build before a single line
/// had been removed, and a lint that is red for the duration of a milestone is a
/// lint nobody reads. So the rule ships measuring and reporting, and this constant
/// flips at the closing gate — one line, greppable, and a property of the tree's
/// state rather than of how the linter was invoked.
pub const enforced: bool = false;

/// Path of the allowlist, relative to the repository root.
pub const allowlist_path = "tools/weld_lint/comment_density_allowlist.txt";

/// The directory prefix the ceiling applies to.
pub const perimeter = "src";

/// Per-file line counts under the definitions in the module header.
pub const Counts = struct {
    comment: u32 = 0,
    code: u32 = 0,

    /// True when the file is over the ceiling. Integer comparison, so the
    /// boundary is exact: equality passes.
    pub fn exceedsCeiling(self: Counts) bool {
        const total = self.comment + self.code;
        if (total == 0) return false;
        return @as(u64, self.comment) * 100 > @as(u64, ceiling_percent) * @as(u64, total);
    }

    /// Ratio in hundredths of a percent, for report lines. Integer, so two runs
    /// of the report over one tree cannot differ in their last digit.
    pub fn ratioBasisPoints(self: Counts) u32 {
        const total = self.comment + self.code;
        if (total == 0) return 0;
        return @intCast(@as(u64, self.comment) * 10_000 / @as(u64, total));
    }

    /// How many comment lines must go for this file to reach the ceiling.
    ///
    /// Removing a comment line shrinks the DENOMINATOR as well as the numerator,
    /// which is why this is not the excess over 25 % of the current total: from
    /// `c <= (ceiling/100)(c + k)` the surviving count is at most
    /// `k * ceiling / (100 - ceiling)`, so for a 25 % ceiling a file may keep one
    /// comment line per three lines of code. The naive form understates the work
    /// by a third on this tree.
    pub fn linesOverCeiling(self: Counts) u32 {
        const keep: u64 = @as(u64, self.code) * ceiling_percent / (100 - ceiling_percent);
        if (self.comment <= keep) return 0;
        return @intCast(@as(u64, self.comment) - keep);
    }
};

/// Count the comment and code lines of `source`.
///
/// A line is COMMENT when its first non-blank token is `//`, CODE when it holds
/// anything else, and neither when it is blank. A multiline string literal line
/// (`\\`) is code, which is what it is — the `//` a usage string may contain is
/// not a comment, and treating it as one would let a file lower its own ratio by
/// printing help text.
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
    /// Set by `check` when a measured file matches this entry.
    seen: bool = false,
    /// Set by `check` when the matched file was actually over the ceiling.
    over: bool = false,
};

/// Parsed allowlist plus the per-file measurements of one run.
///
/// Owned by `main.runLint` rather than by this module: the second half of the
/// bilateral control needs state across files, and module-level state would
/// survive between runs and contaminate this rule's own unit tests.
pub const Tally = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Files measured this run, in walk order. Feeds the report subcommand.
    files: std.ArrayList(Measured) = .empty,

    pub const Measured = struct {
        path: []const u8,
        counts: Counts,
    };

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

/// Parse the allowlist from its text form.
///
/// Format: `<path> | <reason>`, one per line. `#` starts a comment line and blank
/// lines are ignored. A path with no reason is refused — the reason is the whole
/// point of the entry, and an unreasoned exemption is the bypass this rule's
/// header says the allowlist is not.
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

/// Hook called by `main.runLint` once per `.zig` file.
///
/// Always measures, so the report and the enforcement read one number. Emits a
/// diagnostic only when the file is inside the perimeter, over the ceiling, not
/// allowlisted, and `enforced` is set.
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

/// The second half of the bilateral control, run once after every file.
///
/// An allowlist entry must name a file that this run MEASURED and that is over the
/// ceiling. Both halves matter and for different reasons: an entry naming a file
/// nobody measured is a path typo, silently granting nothing and hiding the fact;
/// an entry naming a file under the ceiling is a stale exemption, and left in place
/// it would cover the next comment someone adds to that file.
///
/// It needs no notion of a full scan — it follows the files the invocation actually
/// read, so a partial path list simply says less. That is why an unmatched entry is
/// reported only when the perimeter itself was walked.
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

/// True when `file` lies under the perimeter directory.
///
/// Compares by path SEGMENT, because the walker emits `\` on Windows and a raw
/// `src/` prefix test would put the whole tree outside the perimeter there — the
/// rule would pass on that platform by measuring nothing, which is the failure
/// mode that says green.
pub fn inPerimeter(file: []const u8) bool {
    var it = std.mem.splitScalar(u8, file, std.fs.path.sep);
    const first = it.next() orelse return false;
    return std.mem.eql(u8, first, perimeter);
}

/// Path equality across separator conventions, so one allowlist written with `/`
/// serves both platforms.
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '\\') '/' else ca;
        const nb = if (cb == '\\') '/' else cb;
        if (na != nb) return false;
    }
    return true;
}

// ─── tests ──────────────────────────────────────────────────────────────────

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
    // The discriminating pair: the same two comments, once on their own lines and
    // once trailing. If trailing comments counted, both files would read 2/1 and
    // the ceiling could be met by moving text rather than removing it.
    const trailing = countOn("const x = 1; // why\nconst y = 2; // why\n");
    try std.testing.expectEqual(@as(u32, 0), trailing.comment);
    try std.testing.expectEqual(@as(u32, 2), trailing.code);

    const own_lines = countOn("// why\nconst x = 1;\n// why\nconst y = 2;\n");
    try std.testing.expectEqual(@as(u32, 2), own_lines.comment);
    try std.testing.expectEqual(@as(u32, 2), own_lines.code);
}

test "blank lines are in neither term" {
    // The denominator identity, and it is the one that reproduces the recorded
    // baseline. Four blank lines around one comment and one statement: were blanks
    // in the denominator the ratio would read 16.66 %, not 50 %.
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
    // 25 comment lines against 75 of code is exactly 25 %.
    var at: Counts = .{ .comment = 25, .code = 75 };
    try std.testing.expect(!at.exceedsCeiling());
    try std.testing.expectEqual(@as(u32, 2500), at.ratioBasisPoints());

    var over: Counts = .{ .comment = 26, .code = 75 };
    try std.testing.expect(over.exceedsCeiling());

    // And one line BELOW the ceiling also passes, so the test above pins a
    // boundary rather than the side of it that a `>=` and a `>` share.
    var under: Counts = .{ .comment = 24, .code = 75 };
    try std.testing.expect(!under.exceedsCeiling());
}

test "an empty file is not over the ceiling" {
    var empty: Counts = .{};
    try std.testing.expect(!empty.exceedsCeiling());
    try std.testing.expectEqual(@as(u32, 0), empty.ratioBasisPoints());
}

test "linesOverCeiling accounts for the denominator shrinking" {
    // 61 comment lines against 4 of code is the tree's worst file. A naive excess
    // over 25 % of the current total gives 44; the answer is 60, because removing a
    // comment line removes it from the denominator too and 4 lines of code entitle
    // the file to keep exactly one comment line.
    var worst: Counts = .{ .comment = 61, .code = 4 };
    try std.testing.expectEqual(@as(u32, 60), worst.linesOverCeiling());

    // The claim is that the survivor actually passes — a bound nobody re-checks
    // against the predicate it serves is arithmetic, not a bound.
    var after: Counts = .{ .comment = 61 - 60, .code = 4 };
    try std.testing.expect(!after.exceedsCeiling());

    // A file already under the ceiling owes nothing.
    var fine: Counts = .{ .comment = 10, .code = 90 };
    try std.testing.expectEqual(@as(u32, 0), fine.linesOverCeiling());
}

test "the perimeter is src/ and it is decided by segment" {
    try std.testing.expect(inPerimeter("src" ++ [_]u8{std.fs.path.sep} ++ "core" ++ [_]u8{std.fs.path.sep} ++ "root.zig"));
    try std.testing.expect(!inPerimeter("tools" ++ [_]u8{std.fs.path.sep} ++ "weld_lint" ++ [_]u8{std.fs.path.sep} ++ "main.zig"));
    try std.testing.expect(!inPerimeter("bench" ++ [_]u8{std.fs.path.sep} ++ "ecs_benchmark.zig"));
    try std.testing.expect(!inPerimeter("tests" ++ [_]u8{std.fs.path.sep} ++ "lint" ++ [_]u8{std.fs.path.sep} ++ "x.zig"));
    // Not a prefix match: a sibling directory whose name starts with `src` is out.
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

    // 3 comment lines against 1 of code is 75 %, well over the ceiling — so the
    // measurement is not in question and what this pins is the MODE.
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

    const path = "tools" ++ [_]u8{std.fs.path.sep} ++ "dense.zig";
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
    // Zero in both modes: the entry is legitimate (the file IS over the ceiling),
    // so neither half of the bilateral control fires either.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "an allowlist entry without a reason is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    var tally: Tally = .{};
    defer tally.deinit(arena);

    // Two malformed forms: no separator at all, and a separator with nothing after
    // it. Both are refused, and neither becomes an entry — an exemption that parsed
    // halfway would grant the file the ceiling escape while carrying no reason.
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
