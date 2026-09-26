//! Whether a pull request's tree may inherit the green verdict of an earlier
//! commit instead of running the matrix again.

const std = @import("std");

/// Path prefixes no CI job reads. The digest leaves them out. `guard.zig` checks
/// that claim for literal paths only: a path computed at run time or passed to a
/// system command is not seen.
pub const excluded_prefixes = [_][]const u8{"briefs/"};
/// Whole paths no CI job reads. The digest leaves them out.
pub const excluded_files = [_][]const u8{"CLAUDE.md"};

/// The GitHub Actions app, the only producer of a check run the ruleset accepts.
pub const github_actions_app_id: u64 = 15368;

/// Most check-run queries one decision may make before it gives up and runs.
pub const max_queries = 10;

/// Whether the digest leaves `path` out.
pub fn isExcluded(path: []const u8) bool {
    for (excluded_prefixes) |p| if (std.mem.startsWith(u8, path, p)) return true;
    for (excluded_files) |f| if (std.mem.eql(u8, path, f)) return true;
    return false;
}

/// The digest of a tree's kept records.
pub const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// SHA-256 over the records of `git ls-tree -r -z --full-tree <rev>` whose path
/// `isExcluded` keeps, in the order git lists them.
pub fn treeDigest(ls_tree_z: []const u8) error{MalformedTree}!Digest {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var rest = ls_tree_z;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.MalformedTree;
        const record = rest[0 .. end + 1];
        rest = rest[end + 1 ..];
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.MalformedTree;
        if (!wellFormedHeader(record[0..tab])) return error.MalformedTree;
        const path = record[tab + 1 .. record.len - 1];
        if (path.len == 0) return error.MalformedTree;
        if (isExcluded(path)) continue;
        h.update(record);
    }
    return h.finalResult();
}

/// `<mode> <type> <object>`: six octal digits, a word, forty hex digits.
fn wellFormedHeader(header: []const u8) bool {
    var it = std.mem.splitScalar(u8, header, ' ');
    const mode = it.next() orelse return false;
    const kind = it.next() orelse return false;
    const object = it.next() orelse return false;
    if (it.next() != null) return false;
    if (mode.len != 6) return false;
    for (mode) |c| if (c < '0' or c > '7') return false;
    if (kind.len == 0) return false;
    if (object.len != 40) return false;
    for (object) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// What a candidate's check run says about its code.
pub const CheckVerdict = enum {
    /// Completed with `success`.
    green,
    /// Completed with a conclusion other than `success`, `cancelled`, `skipped` or `stale`.
    red,
    /// Not completed yet.
    pending,
    /// No verdict produced: no such check run, or one that was cancelled, skipped or stale.
    none,
};

const CheckRuns = struct {
    check_runs: []const struct {
        id: u64,
        name: []const u8,
        status: []const u8,
        conclusion: ?[]const u8 = null,
        app: ?struct { id: u64 } = null,
    },
};

/// The verdict of the latest check run named `name` and produced by `app_id`, in
/// the body of a GitHub `commits/{sha}/check-runs` response.
pub fn checkRunVerdict(gpa: std.mem.Allocator, body: []const u8, name: []const u8, app_id: u64) !CheckVerdict {
    const parsed = try std.json.parseFromSlice(CheckRuns, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var latest: ?usize = null;
    for (parsed.value.check_runs, 0..) |run, i| {
        if (!std.mem.eql(u8, run.name, name)) continue;
        const app = run.app orelse continue;
        if (app.id != app_id) continue;
        if (latest == null or run.id > parsed.value.check_runs[latest.?].id) latest = i;
    }
    const run = parsed.value.check_runs[latest orelse return .none];
    if (!std.mem.eql(u8, run.status, "completed")) return .pending;
    const conclusion = run.conclusion orelse return .pending;
    if (std.mem.eql(u8, conclusion, "success")) return .green;
    for ([_][]const u8{ "cancelled", "skipped", "stale" }) |c| {
        if (std.mem.eql(u8, conclusion, c)) return .none;
    }
    return .red;
}

/// The workflow event, as far as the decision tells events apart.
pub const Event = enum { pull_request, other };

/// A commit whose verdict the head may inherit.
pub const Candidate = struct {
    sha: []const u8,
    /// The pull request's base is an ancestor of this commit.
    descends_from_base: bool,
    /// This commit's digest equals the head's.
    same_digest: bool,
};

/// What git says about the head and its candidates.
pub const Facts = struct {
    event: Event,
    /// The base is an ancestor of the head.
    head_descends_from_base: bool,
    /// The tree the jobs check out is the head's tree.
    tested_is_head: bool,
    /// The pull request's commits other than the head, newest first, then the base.
    candidates: []const Candidate,
};

/// Run the jobs, for the reason given, or inherit the verdict of the commit named.
pub const Decision = union(enum) {
    run: []const u8,
    inherit: []const u8,
};

/// Decides for the head described by `facts`. `verdicts.of(sha)` returns the
/// `CheckVerdict` of a candidate, or an error, which decides a run.
pub fn decide(facts: Facts, verdicts: anytype) Decision {
    if (facts.event != .pull_request) return .{ .run = "not a pull request" };
    if (!facts.head_descends_from_base) return .{ .run = "the head does not contain the base" };
    if (!facts.tested_is_head) return .{ .run = "the tested tree is not the head tree" };
    var queries: usize = 0;
    for (facts.candidates) |c| {
        if (!c.descends_from_base or !c.same_digest) continue;
        if (queries == max_queries) return .{ .run = "the query budget is spent" };
        queries += 1;
        const v = verdicts.of(c.sha) catch return .{ .run = "a verdict could not be read" };
        switch (v) {
            .green => return .{ .inherit = c.sha },
            .red => return .{ .run = "the same code was verified red" },
            .pending => return .{ .run = "the same code is still being verified" },
            .none => continue,
        }
    }
    return .{ .run = "no commit with the same code was verified green" };
}

inline fn lsRecord(comptime mode: []const u8, comptime kind: []const u8, comptime path: []const u8) []const u8 {
    return mode ++ " " ++ kind ++ " " ++ "0123456789abcdef0123456789abcdef01234567" ++ "\t" ++ path ++ "\x00";
}

test "the exclusion keeps every path a job reads" {
    try std.testing.expect(isExcluded("briefs/m1.d-phase-1-debt.md"));
    try std.testing.expect(isExcluded("briefs/artifacts/repro.zig"));
    try std.testing.expect(isExcluded("CLAUDE.md"));
    try std.testing.expect(!isExcluded("tests/etch/ebnf_examples.md"));
    try std.testing.expect(!isExcluded("src/core/ecs/README.md"));
    try std.testing.expect(!isExcluded("README.md"));
    try std.testing.expect(!isExcluded("briefsx/a.md"));
    try std.testing.expect(!isExcluded("src/CLAUDE.md"));
}

test "a change under an excluded path leaves the digest unchanged" {
    const a = lsRecord("100644", "blob", "CLAUDE.md") ++ lsRecord("100644", "blob", "build.zig");
    const b = lsRecord("100644", "blob", "build.zig");
    try std.testing.expectEqual(try treeDigest(b), try treeDigest(a));
}

test "a change under a kept path moves the digest" {
    const a = lsRecord("100644", "blob", "tests/etch/ebnf_examples.md");
    const b = lsRecord("100755", "blob", "tests/etch/ebnf_examples.md");
    const c = lsRecord("100644", "blob", "tests/etch/other.md");
    try std.testing.expect(!std.mem.eql(u8, &(try treeDigest(a)), &(try treeDigest(b))));
    try std.testing.expect(!std.mem.eql(u8, &(try treeDigest(a)), &(try treeDigest(c))));
}

test "a malformed ls-tree record is refused" {
    try std.testing.expectError(error.MalformedTree, treeDigest("100644 blob abc\tpath\x00"));
    try std.testing.expectError(error.MalformedTree, treeDigest(lsRecord("100644", "blob", "a")[0..20]));
    try std.testing.expectError(error.MalformedTree, treeDigest("no tab here\x00"));
}

test "the latest check run of the named app decides the verdict" {
    const gpa = std.testing.allocator;
    const body =
        \\{"total_count":3,"check_runs":[
        \\ {"id":7,"name":"ci-gate","status":"completed","conclusion":"failure","app":{"id":15368}},
        \\ {"id":9,"name":"ci-gate","status":"completed","conclusion":"success","app":{"id":15368}},
        \\ {"id":11,"name":"ci-gate","status":"completed","conclusion":"failure","app":{"id":1}}
        \\]}
    ;
    try std.testing.expectEqual(CheckVerdict.green, try checkRunVerdict(gpa, body, "ci-gate", github_actions_app_id));
}

test "a check run's conclusion maps to one verdict" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { status: []const u8, conclusion: []const u8, want: CheckVerdict }{
        .{ .status = "completed", .conclusion = "\"success\"", .want = .green },
        .{ .status = "completed", .conclusion = "\"failure\"", .want = .red },
        .{ .status = "completed", .conclusion = "\"timed_out\"", .want = .red },
        .{ .status = "completed", .conclusion = "\"neutral\"", .want = .red },
        .{ .status = "completed", .conclusion = "\"cancelled\"", .want = .none },
        .{ .status = "completed", .conclusion = "\"skipped\"", .want = .none },
        .{ .status = "in_progress", .conclusion = "null", .want = .pending },
        .{ .status = "queued", .conclusion = "null", .want = .pending },
    };
    for (cases) |c| {
        const body = try std.fmt.allocPrint(gpa,
            \\{{"check_runs":[{{"id":1,"name":"ci-gate","status":"{s}","conclusion":{s},"app":{{"id":15368}}}}]}}
        , .{ c.status, c.conclusion });
        defer gpa.free(body);
        try std.testing.expectEqual(c.want, try checkRunVerdict(gpa, body, "ci-gate", github_actions_app_id));
    }
}

test "no check run of that name and app is no verdict" {
    const gpa = std.testing.allocator;
    const body =
        \\{"check_runs":[{"id":1,"name":"build","status":"completed","conclusion":"success","app":{"id":15368}},
        \\ {"id":2,"name":"ci-gate","status":"completed","conclusion":"success","app":{"id":99}}]}
    ;
    try std.testing.expectEqual(CheckVerdict.none, try checkRunVerdict(gpa, body, "ci-gate", github_actions_app_id));
}

const FakeVerdicts = struct {
    by_sha: []const struct { sha: []const u8, v: CheckVerdict },
    asked: usize = 0,

    pub fn of(self: *FakeVerdicts, sha: []const u8) error{NotFound}!CheckVerdict {
        self.asked += 1;
        for (self.by_sha) |e| if (std.mem.eql(u8, e.sha, sha)) return e.v;
        return error.NotFound;
    }
};

fn pr(candidates: []const Candidate) Facts {
    return .{ .event = .pull_request, .head_descends_from_base = true, .tested_is_head = true, .candidates = candidates };
}

test "a docs-only head inherits the newest green commit with the same code" {
    var fake: FakeVerdicts = .{ .by_sha = &.{ .{ .sha = "b", .v = .green }, .{ .sha = "a", .v = .green } } };
    const d = decide(pr(&.{
        .{ .sha = "b", .descends_from_base = true, .same_digest = true },
        .{ .sha = "a", .descends_from_base = true, .same_digest = true },
    }), &fake);
    try std.testing.expectEqualStrings("b", d.inherit);
    try std.testing.expectEqual(@as(usize, 1), fake.asked);
}

test "a commit that ran nothing is looked past" {
    var fake: FakeVerdicts = .{ .by_sha = &.{ .{ .sha = "c", .v = .none }, .{ .sha = "b", .v = .green } } };
    const d = decide(pr(&.{
        .{ .sha = "c", .descends_from_base = true, .same_digest = true },
        .{ .sha = "b", .descends_from_base = true, .same_digest = true },
    }), &fake);
    try std.testing.expectEqualStrings("b", d.inherit);
}

test "a red verdict on the same code is never looked past" {
    var fake: FakeVerdicts = .{ .by_sha = &.{ .{ .sha = "c", .v = .red }, .{ .sha = "b", .v = .green } } };
    const d = decide(pr(&.{
        .{ .sha = "c", .descends_from_base = true, .same_digest = true },
        .{ .sha = "b", .descends_from_base = true, .same_digest = true },
    }), &fake);
    try std.testing.expect(d == .run);
}

test "a verdict still being produced decides a run" {
    var fake: FakeVerdicts = .{ .by_sha = &.{ .{ .sha = "c", .v = .pending }, .{ .sha = "b", .v = .green } } };
    const d = decide(pr(&.{
        .{ .sha = "c", .descends_from_base = true, .same_digest = true },
        .{ .sha = "b", .descends_from_base = true, .same_digest = true },
    }), &fake);
    try std.testing.expect(d == .run);
}

test "a candidate with other code or outside the base is never asked" {
    var fake: FakeVerdicts = .{ .by_sha = &.{ .{ .sha = "c", .v = .green }, .{ .sha = "b", .v = .green } } };
    const d = decide(pr(&.{
        .{ .sha = "c", .descends_from_base = true, .same_digest = false },
        .{ .sha = "b", .descends_from_base = false, .same_digest = true },
    }), &fake);
    try std.testing.expect(d == .run);
    try std.testing.expectEqual(@as(usize, 0), fake.asked);
}

test "each of the three conditions alone decides a run" {
    var fake: FakeVerdicts = .{ .by_sha = &.{.{ .sha = "b", .v = .green }} };
    const cand = [_]Candidate{.{ .sha = "b", .descends_from_base = true, .same_digest = true }};
    var f = pr(&cand);
    f.event = .other;
    try std.testing.expect(decide(f, &fake) == .run);
    f = pr(&cand);
    f.head_descends_from_base = false;
    try std.testing.expect(decide(f, &fake) == .run);
    f = pr(&cand);
    f.tested_is_head = false;
    try std.testing.expect(decide(f, &fake) == .run);
    try std.testing.expectEqual(@as(usize, 0), fake.asked);
    try std.testing.expectEqualStrings("b", decide(pr(&cand), &fake).inherit);
}

test "an unreadable verdict decides a run" {
    var fake: FakeVerdicts = .{ .by_sha = &.{} };
    const d = decide(pr(&.{.{ .sha = "b", .descends_from_base = true, .same_digest = true }}), &fake);
    try std.testing.expect(d == .run);
}

test "the query budget bounds the walk" {
    var cands: [max_queries + 1]Candidate = undefined;
    for (&cands) |*c| c.* = .{ .sha = "x", .descends_from_base = true, .same_digest = true };
    var fake: FakeVerdicts = .{ .by_sha = &.{.{ .sha = "x", .v = .none }} };
    const d = decide(pr(&cands), &fake);
    try std.testing.expect(d == .run);
    try std.testing.expectEqual(@as(usize, max_queries), fake.asked);
}
