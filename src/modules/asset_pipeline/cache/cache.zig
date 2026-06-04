//! Local cooking cache — a directory of `<key>.bin` cooked artifacts.
//!
//! Key = BLAKE3-128 hex of `source_hash ++ settings ++ platform`
//! (brief §E4): the cache invalidates on `source_hash`, the settings, or the
//! target platform. A cache hit avoids re-running the (expensive) decode +
//! cook; the differential is measured in `tests/assets/cache_diff.zig`.
//!
//! Only the local tier exists in M0.6 (network/cloud tiers are Phase 2+).

const std = @import("std");

const Blake3 = std.crypto.hash.Blake3;

/// Compute the 32-hex cache key from the cook inputs.
pub fn computeKey(source_hash: []const u8, settings: []const u8, platform: u16) [32]u8 {
    var h = Blake3.init(.{});
    h.update(source_hash);
    h.update(settings);
    h.update(std.mem.asBytes(&platform));
    var digest: [16]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// A cooking cache rooted at an open directory.
pub const Cache = struct {
    /// The cache directory (e.g. `.weld/cache/`).
    dir: std.Io.Dir,

    /// Wrap an already-open directory as a cache.
    pub fn init(dir: std.Io.Dir) Cache {
        return .{ .dir = dir };
    }

    fn fileName(key_hex: []const u8, buf: *[36]u8) []const u8 {
        @memcpy(buf[0..32], key_hex[0..32]);
        @memcpy(buf[32..36], ".bin");
        return buf[0..36];
    }

    /// True if a cooked artifact exists for `key_hex` (a cache hit).
    pub fn contains(self: Cache, io: std.Io, key_hex: []const u8) bool {
        var buf: [36]u8 = undefined;
        const f = self.dir.openFile(io, fileName(key_hex, &buf), .{}) catch return false;
        f.close(io);
        return true;
    }

    /// Store cooked `bin` under `key_hex`.
    pub fn put(self: Cache, io: std.Io, key_hex: []const u8, bin: []const u8) !void {
        var buf: [36]u8 = undefined;
        const f = try self.dir.createFile(io, fileName(key_hex, &buf), .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, bin);
    }

    /// Read the cooked artifact for `key_hex` (caller-owned), or null if
    /// absent.
    pub fn get(self: Cache, gpa: std.mem.Allocator, io: std.Io, key_hex: []const u8) !?[]u8 {
        var buf: [36]u8 = undefined;
        const f = self.dir.openFile(io, fileName(key_hex, &buf), .{}) catch return null;
        defer f.close(io);

        const size: usize = @intCast((try f.stat(io)).size);
        const out = try gpa.alloc(u8, size);
        errdefer gpa.free(out);

        var read_buf: [4096]u8 = undefined;
        var reader = f.reader(io, &read_buf);
        var written: usize = 0;
        while (written < size) {
            const n = try reader.interface.readSliceShort(out[written..]);
            if (n == 0) break;
            written += n;
        }
        return out[0..written];
    }
};
