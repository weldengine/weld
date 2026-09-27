//! The header of an archived bench report (`engine-phase-0-criteria.md` § Rapport
//! de bench): the commit measured, the machine, the build mode, and whether the
//! run followed the cold-isolated protocol.

const std = @import("std");
const builtin = @import("builtin");

/// `--protocol` on the command line: the operator ran under the cold-isolated or
/// thermal-aware protocol, which the bench cannot observe.
pub fn protocolFlag(args: []const [:0]const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, "--protocol")) return true;
    return false;
}

/// `git` run in the working directory, trimmed, or null when it fails.
fn git(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
            const out = gpa.dupe(u8, trimmed) catch null;
            gpa.free(result.stdout);
            return out;
        },
        else => {},
    }
    gpa.free(result.stdout);
    return null;
}

/// Writes the title and the four facts the protocol asks of every report.
pub fn write(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, title: []const u8, protocol: bool) !void {
    const commit = git(gpa, io, &.{ "git", "rev-parse", "HEAD" });
    defer if (commit) |c| gpa.free(c);
    const status = git(gpa, io, &.{ "git", "status", "--porcelain", "--untracked-files=no" });
    defer if (status) |s| gpa.free(s);

    try w.print("# {s}\n\n", .{title});
    try w.print("- Commit: {s}", .{commit orelse "unknown"});
    if (status) |s| if (s.len > 0) try w.writeAll(" with uncommitted changes");
    try w.writeAll("\n");
    try w.print("- Machine: {s}, {s}-{s}\n", .{ builtin.cpu.model.name, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    try w.print("- Zig {d}.{d}.{d}, {s}\n", .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch, @tagName(builtin.mode) });
    try w.print("- Protocol: {s}\n\n", .{if (protocol) "cold-isolated, compliant" else "dev run — not opposable"});
}

/// `bench/reports/<name>_<YYYY-MM-DD>.md`, dated by the wall clock.
pub fn datedPath(buf: []u8, io: std.Io, name: []const u8) ![]const u8 {
    const wall = std.Io.Clock.now(.real, io);
    const secs: u64 = @intCast(@max(@as(i96, 0), wall.toSeconds()));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "bench/reports/{s}_{d:0>4}-{d:0>2}-{d:0>2}.md", .{
        name, year_day.year, month_day.month.numeric(), @as(u8, month_day.day_index) + 1,
    });
}

/// Median, 99th percentile and maximum of a sample set.
pub const Distribution = struct {
    median: u64,
    p99: u64,
    max: u64,

    /// Sorts `samples` in place.
    pub fn of(samples: []u64) Distribution {
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        return .{
            .median = samples[samples.len / 2],
            .p99 = samples[(samples.len * 99) / 100],
            .max = samples[samples.len - 1],
        };
    }
};

/// Nanoseconds from `a` to `b` on the awake clock.
pub fn elapsedNs(a: std.Io.Timestamp, b: std.Io.Timestamp) u64 {
    return @intCast(@max(@as(i96, 0), a.durationTo(b).nanoseconds));
}

/// Nanoseconds as milliseconds.
pub fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
