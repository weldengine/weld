//! Content hashing for the asset pipeline — BLAKE3, native std (no C binding).
//!
//! `source_hash`, `extracted.blob`, and the cooking-cache key are all
//! BLAKE3 truncated to 128 bits, rendered as 32 lowercase hex chars
//! (`engine-asset-pipeline.md §3`, brief §E4). The runtime `.bin` header
//! `hash` field is a u64 (the low 64 bits of the same digest).

const std = @import("std");

const Blake3 = std.crypto.hash.Blake3;

/// 32-char lowercase hex of the BLAKE3-128 (16-byte) digest of `data`.
pub fn hex128(data: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    Blake3.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Low 64 bits of the BLAKE3 digest of `data` (the `.bin` header `hash`).
pub fn u64Of(data: []const u8) u64 {
    var digest: [8]u8 = undefined;
    Blake3.hash(data, &digest, .{});
    return std.mem.readInt(u64, &digest, .little);
}

test "hex128 is 32 lowercase hex chars and stable" {
    const a = hex128("weld");
    const b = hex128("weld");
    try std.testing.expectEqual(@as(usize, 32), a.len);
    try std.testing.expectEqualSlices(u8, &a, &b);
    for (a) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    // Distinct inputs give distinct hashes.
    try std.testing.expect(!std.mem.eql(u8, &a, &hex128("weld!")));
}

test "u64Of is stable and input-sensitive" {
    try std.testing.expectEqual(u64Of("abc"), u64Of("abc"));
    try std.testing.expect(u64Of("abc") != u64Of("abd"));
}
