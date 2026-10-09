//! No tracked file may read a path the digest leaves out: an `@embedFile`, a
//! `.path(` call or a file-opening call in Zig, a string in a manifest, a line of a
//! workflow.

const std = @import("std");
const verdict = @import("verdict.zig");

/// A read of an excluded path: the file, its line, and the excluded name reached.
pub const Finding = struct {
    file: []const u8,
    line: usize,
    target: []const u8,
};

/// Methods whose string arguments name a file to read, build from or open.
const readers = [_][]const u8{
    "path",
    "openFile",
    "openDir",
    "readFile",
    "readFileAlloc",
    "readFileAllocOptions",
    "statFile",
    "access",
    "copyFile",
    "readLink",
};

/// Appends a finding for every excluded path `source`, the Zig file `file`, reads.
/// A literal resolves against the file's directory and against the repository
/// root, which is the working directory of every build and test step.
pub fn scanZig(gpa: std.mem.Allocator, file: []const u8, source: [:0]const u8, out: *std.ArrayList(Finding)) !void {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(gpa);
    var tok = std.zig.Tokenizer.init(source);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        try tokens.append(gpa, t);
    }
    const ts = tokens.items;
    var i: usize = 0;
    while (i + 2 < ts.len) : (i += 1) {
        const embed = ts[i].tag == .builtin and std.mem.eql(u8, text(source, ts[i]), "@embedFile");
        const reader = ts[i].tag == .period and ts[i + 1].tag == .identifier and isReader(text(source, ts[i + 1]));
        if (embed and ts[i + 1].tag == .l_paren and ts[i + 2].tag == .string_literal) {
            try checkLiteral(gpa, file, source, ts[i + 2], out);
        } else if (reader and ts[i + 2].tag == .l_paren) {
            var depth: usize = 1;
            var j = i + 3;
            while (j < ts.len and depth > 0) : (j += 1) {
                switch (ts[j].tag) {
                    .l_paren => depth += 1,
                    .r_paren => depth -= 1,
                    .string_literal => if (depth == 1) try checkLiteral(gpa, file, source, ts[j], out),
                    else => {},
                }
            }
        }
    }
}

/// Appends a finding for every string literal of the manifest `source` that names
/// an excluded path.
pub fn scanZon(gpa: std.mem.Allocator, file: []const u8, source: [:0]const u8, out: *std.ArrayList(Finding)) !void {
    var tok = std.zig.Tokenizer.init(source);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .string_literal) try checkLiteral(gpa, file, source, t, out);
    }
}

/// Appends a finding for every line of the workflow `source`, outside comments,
/// that names an excluded path.
pub fn scanWorkflow(gpa: std.mem.Allocator, file: []const u8, source: []const u8, out: *std.ArrayList(Finding)) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        const line = if (std.mem.indexOf(u8, raw, " #")) |c| raw[0..c] else raw;
        for (verdict.excluded_prefixes ++ verdict.excluded_files) |name| {
            if (std.mem.indexOf(u8, line, name) != null) {
                try out.append(gpa, .{ .file = file, .line = n, .target = name });
            }
        }
    }
}

/// Scans every tracked Zig source, manifest and workflow outside the excluded
/// paths. Runs from the repository root.
pub fn scanTree(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Finding)) !void {
    const listed = try std.process.run(arena, io, .{ .argv = &.{ "git", "ls-files", "-z" }, .stdout_limit = .limited(16 << 20) });
    switch (listed.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    var it = std.mem.splitScalar(u8, listed.stdout, 0);
    while (it.next()) |path| {
        if (path.len == 0 or verdict.isExcluded(path)) continue;
        const zig = std.mem.endsWith(u8, path, ".zig");
        const zon = std.mem.endsWith(u8, path, ".zon");
        const yml = std.mem.startsWith(u8, path, ".github/workflows/") and
            (std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml"));
        if (!zig and !zon and !yml) continue;
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u8), 0);
        if (zig) try scanZig(gpa, path, source, out);
        if (zon) try scanZon(gpa, path, source, out);
        if (yml) try scanWorkflow(gpa, path, source, out);
    }
}

fn isReader(name: []const u8) bool {
    for (readers) |r| if (std.mem.eql(u8, r, name)) return true;
    return false;
}

fn text(source: []const u8, t: std.zig.Token) []const u8 {
    return source[t.loc.start..t.loc.end];
}

fn checkLiteral(gpa: std.mem.Allocator, file: []const u8, source: []const u8, t: std.zig.Token, out: *std.ArrayList(Finding)) !void {
    const lit = std.zig.string_literal.parseAlloc(gpa, text(source, t)) catch return;
    defer gpa.free(lit);
    const dir = std.fs.path.dirnamePosix(file) orelse ".";
    for ([_][]const u8{ dir, "." }) |base| {
        const resolved = try std.fs.path.resolvePosix(gpa, &.{ base, lit });
        defer gpa.free(resolved);
        if (verdict.isExcluded(resolved)) {
            const line = std.mem.count(u8, source[0..t.loc.start], "\n") + 1;
            const kept = verdict.excluded_prefixes ++ verdict.excluded_files;
            const target = for (kept) |k| {
                if (std.mem.startsWith(u8, resolved, k)) break k;
            } else "";
            try out.append(gpa, .{ .file = file, .line = line, .target = target });
            return;
        }
    }
}

fn findings(comptime kind: enum { zig, zon, yml }, file: []const u8, source: [:0]const u8) !usize {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(gpa);
    switch (kind) {
        .zig => try scanZig(gpa, file, source, &out),
        .zon => try scanZon(gpa, file, source, &out),
        .yml => try scanWorkflow(gpa, file, source, &out),
    }
    return out.items.len;
}

test "an embed of an excluded path is found through its relative spelling" {
    try std.testing.expectEqual(@as(usize, 1), try findings(.zig, "tests/etch/a.zig",
        \\const x = @embedFile("../../briefs/m1.md");
    ));
}

test "an embed of a kept Markdown file is not a finding" {
    try std.testing.expectEqual(@as(usize, 0), try findings(.zig, "tests/etch/ebnf_examples_test.zig",
        \\const examples_md = @embedFile("ebnf_examples.md");
    ));
}

test "a build path and a file read of an excluded path are found" {
    try std.testing.expectEqual(@as(usize, 1), try findings(.zig, "build.zig",
        \\const p = b.path("CLAUDE.md");
    ));
    try std.testing.expectEqual(@as(usize, 1), try findings(.zig, "tools/x/main.zig",
        \\const s = try std.Io.Dir.cwd().readFileAlloc(io, "briefs/a.md", gpa, .unlimited);
    ));
}

test "a string naming an excluded path outside a read is not a finding" {
    try std.testing.expectEqual(@as(usize, 0), try findings(.zig, "tools/x/main.zig",
        \\const msg = "see briefs/a.md and CLAUDE.md";
        \\const y = foo("briefs/a.md");
    ));
}

test "a manifest string naming an excluded path is found" {
    try std.testing.expectEqual(@as(usize, 1), try findings(.zon, "build.zig.zon",
        \\.{ .paths = .{ "build.zig", "CLAUDE.md" } }
    ));
}

test "a workflow line naming an excluded path is found, a comment is not" {
    try std.testing.expectEqual(@as(usize, 1), try findings(.yml, ".github/workflows/ci.yml",
        \\# briefs/ are documentation
        \\      - run: cat briefs/a.md
        \\      - run: zig build # not CLAUDE.md
    ));
}

test "no tracked file reads a path left out of the digest" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(gpa);
    try scanTree(gpa, arena_state.allocator(), std.testing.io, &out);
    for (out.items) |f| std.debug.print("{s}:{d}: reads {s}, which the digest leaves out\n", .{ f.file, f.line, f.target });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
