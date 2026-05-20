//! Driver for the weld_lint fixture corpus.
//!
//! Each test invokes the installed `zig-out/bin/weld_lint` binary on
//! one fixture group and asserts the expected exit status.
//!
//! The `weld_lint` executable is wired as a dependency of these
//! tests in `build.zig` so `zig build test` builds it first.

const std = @import("std");

const lint_bin = "zig-out/bin/weld_lint";

/// Run `weld_lint <args>` and return the exited code (0 if clean,
/// non-zero if a diagnostic fired).
fn runLint(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !std.process.Child.Term {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.append(gpa, lint_bin);
    try argv_list.appendSlice(gpa, args);

    const result = try std.process.run(gpa, io, .{ .argv = argv_list.items });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    return result.term;
}

fn expectNonZeroExit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
}

fn expectZeroExit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.AbnormalExit,
    }
}

/// Walk `dir_path` and call `f` on each `.zig` file (non-recursive).
fn forEachZigFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    ctx: *Context,
    f: *const fn (*Context, []const u8) anyerror!void,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const joined = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(joined);
        try f(ctx, joined);
    }
}

fn forEachFileWithExt(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    ext: []const u8,
    ctx: *Context,
    f: *const fn (*Context, []const u8) anyerror!void,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        const joined = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(joined);
        try f(ctx, joined);
    }
}

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
};

fn assertBadFixture(ctx: *Context, path: []const u8) !void {
    const term = try runLint(ctx.gpa, ctx.io, &.{ "lint", path });
    expectNonZeroExit(term) catch |err| {
        std.debug.print("expected non-zero exit for {s}, got {any}\n", .{ path, term });
        return err;
    };
}

fn assertGoodFile(ctx: *Context, path: []const u8) !void {
    const term = try runLint(ctx.gpa, ctx.io, &.{ "lint", path });
    expectZeroExit(term) catch |err| {
        std.debug.print("expected zero exit for {s}, got {any}\n", .{ path, term });
        return err;
    };
}

fn assertCommitMsgValid(ctx: *Context, path: []const u8) !void {
    const term = try runLint(ctx.gpa, ctx.io, &.{ "commit-msg", path });
    expectZeroExit(term) catch |err| {
        std.debug.print("expected zero exit on {s}, got {any}\n", .{ path, term });
        return err;
    };
}

fn assertCommitMsgInvalid(ctx: *Context, path: []const u8) !void {
    const term = try runLint(ctx.gpa, ctx.io, &.{ "commit-msg", path });
    expectNonZeroExit(term) catch |err| {
        std.debug.print("expected non-zero exit on {s}, got {any}\n", .{ path, term });
        return err;
    };
}

test "rule no_cimport flags bad fixtures" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachZigFile(ctx.gpa, ctx.io, "tests/lint/bad/cimport", &ctx, &assertBadFixture);
}

test "rule no_usingnamespace flags bad fixtures" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachZigFile(ctx.gpa, ctx.io, "tests/lint/bad/usingnamespace", &ctx, &assertBadFixture);
}

test "rule doc_comments flags bad fixtures" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachZigFile(ctx.gpa, ctx.io, "tests/lint/bad/missing_doc_comment", &ctx, &assertBadFixture);
}

test "rule c_module_isolation flags bad fixtures" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachZigFile(ctx.gpa, ctx.io, "tests/lint/bad/c_module_isolation", &ctx, &assertBadFixture);
}

test "good fixtures pass clean" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachZigFile(ctx.gpa, ctx.io, "tests/lint/good", &ctx, &assertGoodFile);
}

test "production tree passes clean" {
    const ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const term = try runLint(ctx.gpa, ctx.io, &.{ "lint", "src", "bench", "tests" });
    try expectZeroExit(term);
}

test "commit messages valid set accepted" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachFileWithExt(ctx.gpa, ctx.io, "tests/lint/commit/good", ".txt", &ctx, &assertCommitMsgValid);
}

test "commit messages invalid set rejected" {
    var ctx: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try forEachFileWithExt(ctx.gpa, ctx.io, "tests/lint/commit/bad", ".txt", &ctx, &assertCommitMsgInvalid);
}
