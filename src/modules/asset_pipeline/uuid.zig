//! UUIDv7 — the stable per-asset identity (RFC 9562). Pure Zig, no C binding.
//!
//! Used as the `uuid` field of `<type>.asset.etch` (brief §E4 complement):
//! generated once at first import and preserved across re-imports
//! (rename/move-safe). Distinct from `source_hash`, which *changes* when the
//! source changes; the uuid is stable for life. In M0.6 the uuid is stored
//! only — cross-asset references still resolve by path (uuid-based
//! resolution / rename-propagation is Phase 1+).
//!
//! Layout (128 bits, big-endian on the wire): 48-bit unix-ms timestamp,
//! 4-bit version (0x7), 12-bit rand_a, 2-bit variant (0b10), 62-bit rand_b.
//! Both the timestamp and the random bits come from `io` (`Clock.real` +
//! `io.random`).

const std = @import("std");

/// Generate a fresh UUIDv7. `io` supplies the wall-clock timestamp and the
/// random bits.
pub fn generateV7(io: std.Io) u128 {
    const ns: i96 = std.Io.Clock.real.now(io).nanoseconds;
    const ms: u64 = @intCast(@divFloor(@as(i128, ns), std.time.ns_per_ms));

    var rnd: [10]u8 = undefined;
    io.random(&rnd);
    const rand_a: u128 = std.mem.readInt(u16, rnd[0..2], .little) & 0x0fff;
    const rand_b: u128 = std.mem.readInt(u64, rnd[2..10], .little) & ((@as(u128, 1) << 62) - 1);

    var u: u128 = 0;
    u |= @as(u128, ms & 0xffff_ffff_ffff) << 80; // 48-bit timestamp
    u |= @as(u128, 0x7) << 76; // version 7
    u |= rand_a << 64; // 12 random bits
    u |= @as(u128, 0b10) << 62; // variant
    u |= rand_b; // 62 random bits
    return u;
}

/// Render a uuid as the canonical 36-char `8-4-4-4-12` lowercase string.
pub fn toString(u: u128) [36]u8 {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, u, .big);
    const hex = std.fmt.bytesToHex(bytes, .lower); // [32]u8

    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

/// Parse a canonical 36-char UUID string into a u128, or null if malformed.
pub fn parse(s: []const u8) ?u128 {
    if (s.len != 36) return null;
    var hex: [32]u8 = undefined;
    var hi: usize = 0;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return null;
            continue;
        }
        if (hi >= 32) return null;
        hex[hi] = c;
        hi += 1;
    }
    if (hi != 32) return null;
    var bytes: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, &hex) catch return null;
    return std.mem.readInt(u128, &bytes, .big);
}

/// Extract the 4-bit version field.
pub fn version(u: u128) u4 {
    return @truncate(u >> 76);
}

test "generateV7 sets version 7 and the RFC variant, and is unique" {
    const io = std.testing.io;
    const a = generateV7(io);
    const b = generateV7(io);
    try std.testing.expectEqual(@as(u4, 7), version(a));
    try std.testing.expectEqual(@as(u128, 0b10), (a >> 62) & 0b11); // variant
    try std.testing.expect(a != b);
}

test "uuid toString/parse round-trips" {
    const io = std.testing.io;
    const u = generateV7(io);
    const s = toString(u);
    try std.testing.expectEqual(@as(usize, 36), s.len);
    try std.testing.expectEqual(@as(u8, '-'), s[8]);
    try std.testing.expectEqual(@as(u8, '-'), s[23]);
    try std.testing.expectEqual(u, parse(&s).?);
}

test "uuid parse rejects malformed input" {
    try std.testing.expectEqual(@as(?u128, null), parse("not-a-uuid"));
    try std.testing.expectEqual(@as(?u128, null), parse("0123456789abcdef0123456789abcdef")); // no dashes
}
