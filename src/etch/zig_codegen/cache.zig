//! Per-file content-hash cache for the codegen, keyed by a hash of the source
//! `.etch` content and stored under `zig-out/etch-gen/.cache/`.
//!
//! `shouldRegenerate` answers `true` on a miss or a mismatch; callers write the
//! fresh hash with `writeHash` after regenerating.
//!
//! The hash file lives at `<cache_dir>/<hash of input_path>.hash` and holds the
//! raw 8-byte content hash plus a `\n`. Hashing the PATH is what keeps the
//! directory flat — a nested input path needs no nested directory.

const std = @import("std");

/// 64-bit content digest written beside each generated `.zig` file so the
/// codegen can skip emission when the source is unchanged.
pub const Hash = u64;

/// Wyhash of the source content. The spec names xxHash; the Zig stdlib exposes
/// only Wyhash and Fnv1a, and Wyhash has the same design goals. Stated because
/// the corpus and the code disagree on the name.
pub fn computeHash(bytes: []const u8) Hash {
    return std.hash.Wyhash.hash(0, bytes);
}

/// Cache filename derived from the input path by hashing it, so the directory
/// layout stays flat. The path itself is NOT recoverable from the name or from
/// the file, which holds the content hash alone.
fn cacheFileName(gpa: std.mem.Allocator, input_path: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0xCA0FFE5);
    hasher.update(input_path);
    const path_hash = hasher.final();
    return try std.fmt.allocPrint(gpa, "{x:0>16}.hash", .{path_hash});
}

/// The cached hash for `input_path`, or `null`. A missing cache directory reads
/// as a miss.
pub fn readCachedHash(gpa: std.mem.Allocator, cache_dir: []const u8, input_path: []const u8) !?Hash {
    const filename = try cacheFileName(gpa, input_path);
    defer gpa.free(filename);
    const joined = try std.fs.path.join(gpa, &.{ cache_dir, filename });
    defer gpa.free(joined);
    const cwd = std.fs.cwd();
    const file = cwd.openFile(joined, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    var buf: [16]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n < @sizeOf(Hash)) return null;
    return std.mem.readInt(Hash, buf[0..@sizeOf(Hash)], .little);
}

/// Write the freshly-computed hash to the cache file for `input_path`.
/// Creates the cache directory if missing.
pub fn writeHash(gpa: std.mem.Allocator, cache_dir: []const u8, input_path: []const u8, hash: Hash) !void {
    const cwd = std.fs.cwd();
    cwd.makePath(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const filename = try cacheFileName(gpa, input_path);
    defer gpa.free(filename);
    const joined = try std.fs.path.join(gpa, &.{ cache_dir, filename });
    defer gpa.free(joined);
    const file = try cwd.createFile(joined, .{ .truncate = true });
    defer file.close();
    var buf: [@sizeOf(Hash) + 1]u8 = undefined;
    std.mem.writeInt(Hash, buf[0..@sizeOf(Hash)], hash, .little);
    buf[@sizeOf(Hash)] = '\n';
    try file.writeAll(&buf);
}

/// `true` when the source's hash differs from the cached one, or the cache is
/// missing. Callers regenerate, then call `writeHash`.
pub fn shouldRegenerate(gpa: std.mem.Allocator, cache_dir: []const u8, input_path: []const u8, source: []const u8) !bool {
    const current = computeHash(source);
    const cached = readCachedHash(gpa, cache_dir, input_path) catch |err| switch (err) {
        else => return true, // any read error => regenerate
    };
    if (cached) |c| return c != current;
    return true;
}

test "computeHash is stable across calls" {
    const a = computeHash("hello");
    const b = computeHash("hello");
    try std.testing.expectEqual(a, b);
    const c = computeHash("world");
    try std.testing.expect(a != c);
}

test "missing cache file means regeneration is required" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(cache_dir);

    const should = try shouldRegenerate(gpa, cache_dir, "absent.etch", "some source");
    try std.testing.expect(should);
}

// Cache hit / miss tests on disk live under
// `src/etch/zig_codegen/tests/cache_test.zig`.
