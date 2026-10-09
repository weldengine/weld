//! `ci_verdict` — decides whether a workflow run may skip its jobs because the
//! same code was already verified green.
//!
//!     ci_verdict decide --event <name> --base <sha> --head <sha> --tested <rev>
//!                       --repo <owner/name> --check <check run name> [--api <url>]
//!     ci_verdict digest <rev>
//!
//! `decide` prints `code=true|false`, `reason=…` and, on a skip, `inherited=<sha>`
//! on stdout, in the shape `$GITHUB_OUTPUT` takes. Any doubt decides a run. The
//! token, if any, is read from `GITHUB_TOKEN`.

const std = @import("std");
const verdict = @import("verdict.zig");

const usage =
    \\usage: ci_verdict decide --event <name> --base <sha> --head <sha> --tested <rev>
    \\                         --repo <owner/name> --check <name> [--api <url>]
    \\       ci_verdict digest <rev>
    \\
;

/// Newest commits of the pull request considered before the walk gives up.
const max_candidates = 100;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    if (argv.len < 2) {
        try out.writeAll(usage);
        return 2;
    }
    if (std.mem.eql(u8, argv[1], "digest") and argv.len == 3) {
        const d = digestOf(arena, init.io, argv[2]) catch |err| {
            std.debug.print("ci_verdict: {s}\n", .{@errorName(err)});
            return 1;
        };
        try out.print("{x}\n", .{&d});
        return 0;
    }
    if (std.mem.eql(u8, argv[1], "decide")) {
        const opts = parseDecide(argv[2..]) catch {
            try out.writeAll(usage);
            return 2;
        };
        const token = init.environ_map.get("GITHUB_TOKEN");
        const d = decideFor(arena, init.io, opts, token);
        switch (d) {
            .run => |why| try out.print("code=true\nreason={s}\n", .{why}),
            .inherit => |sha| try out.print("code=false\nreason=the same code was verified green at {s}\ninherited={s}\n", .{ sha, sha }),
        }
        std.debug.print("ci_verdict: {s}\n", .{switch (d) {
            .run => |why| why,
            .inherit => |sha| sha,
        }});
        return 0;
    }
    try out.writeAll(usage);
    return 2;
}

const DecideOptions = struct {
    event: []const u8 = "",
    base: []const u8 = "",
    head: []const u8 = "",
    tested: []const u8 = "",
    repo: []const u8 = "",
    check: []const u8 = "",
    api: []const u8 = "https://api.github.com",
};

fn parseDecide(args: []const [:0]const u8) error{Usage}!DecideOptions {
    var o: DecideOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Usage;
        if (!std.mem.startsWith(u8, args[i], "--")) return error.Usage;
        const key = args[i][2..];
        var matched = false;
        inline for (@typeInfo(DecideOptions).@"struct".fields) |f| {
            if (std.mem.eql(u8, key, f.name)) {
                @field(o, f.name) = args[i + 1];
                matched = true;
            }
        }
        if (!matched) return error.Usage;
    }
    if (o.event.len == 0 or o.tested.len == 0 or o.repo.len == 0 or o.check.len == 0) return error.Usage;
    for (o.check) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.Usage;
    return o;
}

fn decideFor(arena: std.mem.Allocator, io: std.Io, o: DecideOptions, token: ?[]const u8) verdict.Decision {
    if (!std.mem.eql(u8, o.event, "pull_request")) return .{ .run = "not a pull request" };
    if (!isSha(o.base) or !isSha(o.head)) return .{ .run = "the event names no base or head" };
    var repo: GitRepo = .{ .arena = arena, .io = io };
    const facts = gather(arena, &repo, o) catch return .{ .run = "git could not describe the tree" };
    var reader: GitHubVerdicts = .{ .arena = arena, .io = io, .options = o, .token = token };
    return verdict.decide(facts, &reader);
}

/// The facts `verdict.decide` needs, read from `repo`: the pull request's commits
/// newest first, then the base, which `main`'s own run verified.
fn gather(arena: std.mem.Allocator, repo: anytype, o: DecideOptions) !verdict.Facts {
    const head_digest = try repo.digest(o.head);
    var candidates: std.ArrayList(verdict.Candidate) = .empty;
    var it = std.mem.tokenizeScalar(u8, try repo.revList(o.base, o.head), '\n');
    while (it.next()) |sha| {
        if (std.mem.eql(u8, sha, o.head)) continue;
        if (candidates.items.len == max_candidates) break;
        const descends = try repo.isAncestor(o.base, sha);
        const same = descends and std.mem.eql(u8, &(try repo.digest(sha)), &head_digest);
        try candidates.append(arena, .{ .sha = sha, .descends_from_base = descends, .same_digest = same });
    }
    const base_same = std.mem.eql(u8, &(try repo.digest(o.base)), &head_digest);
    try candidates.append(arena, .{ .sha = o.base, .descends_from_base = true, .same_digest = base_same });
    return .{
        .event = .pull_request,
        .head_descends_from_base = try repo.isAncestor(o.base, o.head),
        .tested_is_head = std.mem.eql(u8, try repo.tree(o.tested), try repo.tree(o.head)),
        .candidates = candidates.items,
    };
}

const GitRepo = struct {
    arena: std.mem.Allocator,
    io: std.Io,

    pub fn digest(self: *GitRepo, rev: []const u8) !verdict.Digest {
        return digestOf(self.arena, self.io, rev);
    }

    pub fn tree(self: *GitRepo, rev: []const u8) ![]const u8 {
        return git(self.arena, self.io, &.{ "rev-parse", try std.fmt.allocPrint(self.arena, "{s}^{{tree}}", .{rev}) });
    }

    pub fn revList(self: *GitRepo, base: []const u8, head: []const u8) ![]const u8 {
        return git(self.arena, self.io, &.{ "rev-list", try std.fmt.allocPrint(self.arena, "{s}..{s}", .{ base, head }) });
    }

    pub fn isAncestor(self: *GitRepo, a: []const u8, b: []const u8) !bool {
        return isAncestorOf(self.arena, self.io, a, b);
    }
};

const GitHubVerdicts = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    options: DecideOptions,
    token: ?[]const u8,

    pub fn of(self: *GitHubVerdicts, sha: []const u8) !verdict.CheckVerdict {
        const url = try std.fmt.allocPrint(self.arena, "{s}/repos/{s}/commits/{s}/check-runs?check_name={s}&filter=latest&per_page=100", .{
            self.options.api, self.options.repo, sha, self.options.check,
        });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "curl", "-sS", "--fail", "--max-time", "30" });
        try argv.appendSlice(self.arena, &.{ "-H", "Accept: application/vnd.github+json" });
        try argv.appendSlice(self.arena, &.{ "-H", "X-GitHub-Api-Version: 2022-11-28" });
        if (self.token) |t| try argv.appendSlice(self.arena, &.{ "-H", try std.fmt.allocPrint(self.arena, "Authorization: Bearer {s}", .{t}) });
        try argv.append(self.arena, url);
        const r = try std.process.run(self.arena, self.io, .{ .argv = argv.items, .stdout_limit = .limited(4 << 20) });
        switch (r.term) {
            .exited => |code| if (code != 0) return error.CurlFailed,
            else => return error.CurlFailed,
        }
        return verdict.checkRunVerdict(self.arena, r.stdout, self.options.check, verdict.github_actions_app_id);
    }
};

fn digestOf(arena: std.mem.Allocator, io: std.Io, rev: []const u8) !verdict.Digest {
    const listed = try gitRaw(arena, io, &.{ "ls-tree", "-r", "-z", "--full-tree", rev });
    return verdict.treeDigest(listed);
}

fn isAncestorOf(arena: std.mem.Allocator, io: std.Io, a: []const u8, b: []const u8) !bool {
    const r = try std.process.run(arena, io, .{ .argv = &.{ "git", "merge-base", "--is-ancestor", a, b } });
    return switch (r.term) {
        .exited => |code| switch (code) {
            0 => true,
            1 => false,
            else => error.GitFailed,
        },
        else => error.GitFailed,
    };
}

/// `git <args>` with its output trimmed of the final newline.
fn git(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    return std.mem.trimEnd(u8, try gitRaw(arena, io, args), "\n");
}

fn gitRaw(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{"git"}, args });
    const r = try std.process.run(arena, io, .{ .argv = argv, .stdout_limit = .limited(64 << 20) });
    switch (r.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return r.stdout;
}

fn isSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return !std.mem.eql(u8, s, "0000000000000000000000000000000000000000");
}

test "only a full non-zero sha names a commit" {
    try std.testing.expect(isSha("c0a1fafb128c03e2bcf30d239d221a86ea24effa"));
    try std.testing.expect(!isSha("0000000000000000000000000000000000000000"));
    try std.testing.expect(!isSha("c0a1fafb"));
    try std.testing.expect(!isSha(""));
}

test "decide refuses an incomplete or unsafe command line" {
    const ok = [_][:0]const u8{ "--event", "pull_request", "--tested", "HEAD", "--repo", "o/r", "--check", "ci-gate" };
    _ = try parseDecide(&ok);
    const no_check = [_][:0]const u8{ "--event", "pull_request", "--tested", "HEAD", "--repo", "o/r" };
    try std.testing.expectError(error.Usage, parseDecide(&no_check));
    const bad_check = [_][:0]const u8{ "--event", "pull_request", "--tested", "HEAD", "--repo", "o/r", "--check", "ci gate&x=1" };
    try std.testing.expectError(error.Usage, parseDecide(&bad_check));
    const dangling = [_][:0]const u8{"--event"};
    try std.testing.expectError(error.Usage, parseDecide(&dangling));
}

test "a push always decides a run" {
    const d = decideFor(std.testing.allocator, std.testing.io, .{ .event = "push", .tested = "HEAD", .repo = "o/r", .check = "ci-gate" }, null);
    try std.testing.expect(d == .run);
}

/// A repository of named commits, each with a digest byte, a tree, and the
/// commits it descends from.
const FakeRepo = struct {
    commits: []const struct { sha: []const u8, digest: u8, tree: []const u8 = "t", ancestors: []const []const u8 = &.{} },
    listed: []const u8,

    fn find(self: *FakeRepo, sha: []const u8) !usize {
        for (self.commits, 0..) |c, i| if (std.mem.eql(u8, c.sha, sha)) return i;
        return error.NoSuchCommit;
    }

    pub fn digest(self: *FakeRepo, rev: []const u8) !verdict.Digest {
        return @splat(self.commits[try self.find(rev)].digest);
    }

    pub fn tree(self: *FakeRepo, rev: []const u8) ![]const u8 {
        return self.commits[try self.find(rev)].tree;
    }

    pub fn revList(self: *FakeRepo, base: []const u8, head: []const u8) ![]const u8 {
        _ = .{ base, head };
        return self.listed;
    }

    pub fn isAncestor(self: *FakeRepo, a: []const u8, b: []const u8) !bool {
        if (std.mem.eql(u8, a, b)) return true;
        for (self.commits[try self.find(b)].ancestors) |x| if (std.mem.eql(u8, x, a)) return true;
        return false;
    }
};

const pr_options: DecideOptions = .{ .event = "pull_request", .base = "B", .head = "H", .tested = "M", .repo = "o/r", .check = "ci-gate" };

test "the base closes the candidate list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var repo: FakeRepo = .{ .listed = "H\nC\n", .commits = &.{
        .{ .sha = "B", .digest = 1 },
        .{ .sha = "C", .digest = 2, .ancestors = &.{"B"} },
        .{ .sha = "H", .digest = 1, .ancestors = &.{ "C", "B" } },
        .{ .sha = "M", .digest = 1 },
    } };
    const f = try gather(arena_state.allocator(), &repo, pr_options);
    try std.testing.expectEqual(@as(usize, 2), f.candidates.len);
    try std.testing.expectEqualStrings("C", f.candidates[0].sha);
    try std.testing.expect(!f.candidates[0].same_digest);
    try std.testing.expectEqualStrings("B", f.candidates[1].sha);
    try std.testing.expect(f.candidates[1].same_digest);
    try std.testing.expect(f.head_descends_from_base and f.tested_is_head);
}

test "a commit outside the base is a candidate that cannot be inherited" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var repo: FakeRepo = .{ .listed = "H\nX\n", .commits = &.{
        .{ .sha = "B", .digest = 2 },
        .{ .sha = "X", .digest = 1 },
        .{ .sha = "H", .digest = 1, .ancestors = &.{ "X", "B" } },
        .{ .sha = "M", .digest = 1, .tree = "other" },
    } };
    const f = try gather(arena_state.allocator(), &repo, pr_options);
    try std.testing.expect(!f.candidates[0].descends_from_base and !f.candidates[0].same_digest);
    try std.testing.expect(!f.tested_is_head);
}

test "the candidate list is bounded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var listed: std.ArrayList(u8) = .empty;
    for (0..max_candidates + 50) |_| try listed.appendSlice(arena, "C\n");
    var repo: FakeRepo = .{ .listed = listed.items, .commits = &.{
        .{ .sha = "B", .digest = 1 },
        .{ .sha = "C", .digest = 1, .ancestors = &.{"B"} },
        .{ .sha = "H", .digest = 1, .ancestors = &.{"B"} },
        .{ .sha = "M", .digest = 1 },
    } };
    const f = try gather(arena, &repo, pr_options);
    try std.testing.expectEqual(@as(usize, max_candidates + 1), f.candidates.len);
}
