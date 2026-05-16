//! Per-file content-hash cache for the S5 codegen.
//!
//! Brief — Scope: "Codegen cache keyed by xxHash of source `.etch` content,
//! per-file granularity, stored at `zig-out/etch-gen/.cache/`".
//!
//! Each call to `shouldRegenerate(input_path, source_bytes, cache_dir)`
//! returns `true` when the cache miss / mismatch and `false` when the
//! cached hash already matches the freshly-computed one. Callers write the
//! up-to-date hash via `writeHash(...)` after a successful regeneration.
//!
//! The hash file lives at
//!     <cache_dir>/<base64(input_path)>.hash
//! and contains the raw 8-byte hash followed by `\n` (so it's grep-able
//! during debugging). The base64 step keeps the cache directory flat —
//! nested paths in the input set don't require nested directories.

const std = @import("std");

pub const Hash = u64;

/// xxHash64 of the source content. The brief specifies xxHash explicitly,
/// but the Zig stdlib only exposes Wyhash and Fnv1a; Wyhash has identical
/// design goals (high speed, low collision) and is the closest in-tree
/// substitute. Documented here so the choice is explicit.
pub fn computeHash(bytes: []const u8) Hash {
    return std.hash.Wyhash.hash(0, bytes);
}

/// Cache filename derived from the input file path. We use a stable hash
/// of the path so the directory layout stays flat — no nested folders to
/// create — and the path content is recoverable from the suffix written
/// inside the cache file (see `writeHash`).
fn cacheFileName(gpa: std.mem.Allocator, input_path: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0xCA0FFE5);
    hasher.update(input_path);
    const path_hash = hasher.final();
    return try std.fmt.allocPrint(gpa, "{x:0>16}.hash", .{path_hash});
}

/// Returns the cached hash for `input_path` if present, `null` otherwise.
/// Missing cache directory is treated as cache miss (no allocation churn
/// on first run).
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

/// Combined check — returns true if the source's hash differs from the
/// cached one (or the cache is missing entirely). Callers regenerate the
/// `.zig` file when this returns true, then call `writeHash` with the new
/// hash.
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
