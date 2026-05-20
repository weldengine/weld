//! Filesystem walker for the Weld linter.
//!
//! Walks a list of input paths (files or directories) and yields the
//! `.zig` files that the rules should inspect. Skips vendored build
//! caches, the fixture corpus of intentionally bad files, and a small
//! hard-coded ignore list.

const std = @import("std");

/// Directories that must never be traversed regardless of the input.
const ignored_dir_names = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "zig-pkg",
    ".cache",
    "node_modules",
};

/// Path substrings whose entries are skipped by the walker.
/// `tests/lint/bad` holds the intentionally non-compliant fixture
/// corpus — the `lint` step must never visit it; the runner_test
/// drives it explicitly with the expected non-zero exit code.
/// `tests/lint/commit` is plain text, not `.zig` source.
const ignored_path_substrings = [_][]const u8{
    "tests/lint/bad",
    "tests/lint/commit",
};

/// Append every `.zig` file reachable from `path` to `out`. `path` may
/// be a regular file (added directly if it ends with `.zig`) or a
/// directory (walked recursively). Strings are duplicated into `arena`.
pub fn collectZigFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .file => {
            if (std.mem.endsWith(u8, path, ".zig")) {
                const dup = try arena.dupe(u8, path);
                try out.append(arena, dup);
            }
            return;
        },
        .directory => {},
        else => return,
    }

    if (isIgnoredPath(path)) return;

    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        var skip = false;
        var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |seg| {
            for (ignored_dir_names) |needle| {
                if (std.mem.eql(u8, seg, needle)) {
                    skip = true;
                    break;
                }
            }
            if (skip) break;
        }
        if (skip) continue;

        const joined = try std.fs.path.join(arena, &.{ path, entry.path });
        if (isIgnoredPath(joined)) continue;
        try out.append(arena, joined);
    }
}

fn isIgnoredPath(path: []const u8) bool {
    for (ignored_path_substrings) |needle| {
        if (std.mem.indexOf(u8, path, needle)) |_| return true;
    }
    return false;
}

/// Read a file into a null-terminated buffer owned by `arena`. The
/// sentinel lets the Zig tokenizer and AST parser consume the slice as
/// `[:0]const u8` without an extra copy.
pub fn readSourceZ(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try arena.allocSentinel(u8, size, 0);

    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    if (written != size) return error.UnexpectedEndOfFile;
    return buf;
}
