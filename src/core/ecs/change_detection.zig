//! The per-chunk dirty bitset behind `Changed<T>`: one bit per slot, set when any
//! component in that slot is modified, cleared by `World.beginFrame`.
//!
//! So the bit means MODIFIED SINCE THIS FRAME BEGAN and nothing wider. It exists to
//! let a query skip a whole chunk before paying the per-slot `changed_tick` compare;
//! the durable answer is the tick sidecar, never the bit.

const std = @import("std");

/// `u64`-word view; the length is `ceil(capacity / 64)`, computed in `chunk.zig`.
pub const DirtyBitset = []u64;

/// Set the bit at `slot` — UNCHECKED past `capacity`, which the chunk guarantees.
pub fn setDirty(bitset: DirtyBitset, slot: u32) void {
    const word_idx: usize = @intCast(slot / 64);
    const bit_idx: u6 = @intCast(slot % 64);
    bitset[word_idx] |= (@as(u64, 1) << bit_idx);
}

/// Test the bit at `slot`; `false` past `capacity`.
pub fn isDirty(bitset: DirtyBitset, slot: u32) bool {
    const word_idx: usize = @intCast(slot / 64);
    if (word_idx >= bitset.len) return false;
    const bit_idx: u6 = @intCast(slot % 64);
    return (bitset[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// Reset every bit; `World.beginFrame` calls this on every chunk.
pub fn clearAll(bitset: DirtyBitset) void {
    @memset(bitset, 0);
}

/// Hot path for the chunk skip; takes `[]const u64` so a read-only probe keeps it.
pub fn isAllZero(bitset: []const u64) bool {
    for (bitset) |word| if (word != 0) return false;
    return true;
}

test "setDirty / isDirty round-trip" {
    var words: [4]u64 = .{ 0, 0, 0, 0 };
    const bitset: DirtyBitset = &words;
    try std.testing.expect(!isDirty(bitset, 0));
    try std.testing.expect(!isDirty(bitset, 64));
    setDirty(bitset, 0);
    setDirty(bitset, 63);
    setDirty(bitset, 64);
    setDirty(bitset, 191);
    try std.testing.expect(isDirty(bitset, 0));
    try std.testing.expect(isDirty(bitset, 63));
    try std.testing.expect(isDirty(bitset, 64));
    try std.testing.expect(isDirty(bitset, 191));
    try std.testing.expect(!isDirty(bitset, 1));
    try std.testing.expect(!isDirty(bitset, 65));
}

test "clearAll resets every word" {
    var words: [3]u64 = .{ std.math.maxInt(u64), 0xdeadbeef, 0x1 };
    const bitset: DirtyBitset = &words;
    try std.testing.expect(!isAllZero(bitset));
    clearAll(bitset);
    try std.testing.expect(isAllZero(bitset));
    for (words) |w| try std.testing.expectEqual(@as(u64, 0), w);
}

test "isAllZero short-circuits on the first non-zero word" {
    var words: [3]u64 = .{ 0, 0, 0 };
    const bitset: DirtyBitset = &words;
    try std.testing.expect(isAllZero(bitset));

    words[2] = 1;
    try std.testing.expect(!isAllZero(bitset));

    words[2] = 0;
    words[0] = 1;
    try std.testing.expect(!isAllZero(bitset));
}

test "isDirty past the end of the bitset is false (defensive)" {
    var words: [2]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64) };
    const bitset: DirtyBitset = &words;
    try std.testing.expect(isDirty(bitset, 0));
    try std.testing.expect(isDirty(bitset, 127));
    try std.testing.expect(!isDirty(bitset, 200));
}
