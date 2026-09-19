//! Change-detection primitives.
//!
//! Two cooperating layers feed the `Changed<T>` query filter:
//!
//! - **Tick sidecars** (`added_tick[N]`, `changed_tick[N]` per chunk column):
//!   the world tick at which a component was attached / last modified.
//! - **Dirty bitset** (per chunk): one bit per slot, set when any component in
//!   that slot changes, cleared by `World.beginFrame` — so it means "modified
//!   since the start of this frame" and lets a `Changed<T>` query skip a whole
//!   chunk before paying the per-slot tick comparison.
//!
//! This module owns only the bitset. Its byte layout is computed in
//! `chunk.zig`, the tick accessors are on `Archetype`, and the `get_mut(T)`
//! auto-mark is in `world.zig`.

const std = @import("std");

/// `u64`-word view over a per-chunk dirty bitset. The slice length
/// equals `ceil(capacity / 64)` — the layout in `chunk.zig` computes
/// it once per archetype and stores it in `ChunkLayout.dirty_bitset_word_count`.
pub const DirtyBitset = []u64;

/// Set the bit at `slot`. No bounds check beyond the implied
/// `slot < capacity` invariant the chunk maintains.
pub fn setDirty(bitset: DirtyBitset, slot: u32) void {
    const word_idx: usize = @intCast(slot / 64);
    const bit_idx: u6 = @intCast(slot % 64);
    bitset[word_idx] |= (@as(u64, 1) << bit_idx);
}

/// Test the bit at `slot`. Returns `false` past `capacity`.
pub fn isDirty(bitset: DirtyBitset, slot: u32) bool {
    const word_idx: usize = @intCast(slot / 64);
    if (word_idx >= bitset.len) return false;
    const bit_idx: u6 = @intCast(slot % 64);
    return (bitset[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// Reset every bit to zero.
pub fn clearAll(bitset: DirtyBitset) void {
    @memset(bitset, 0);
}

/// `true` iff every word is zero — the chunk early-out for `Changed<T>`. Takes
/// `[]const u64` so a read-only holder can probe without dropping `const`.
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
