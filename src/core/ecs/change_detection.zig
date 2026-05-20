//! Change-detection primitives — M0.1 / E4.
//!
//! Two cooperating layers feed the `Changed<T>` query filter:
//!
//! - **Tick sidecars** (`added_tick[N]`, `changed_tick[N]` per chunk
//!   column). Per-slot 32-bit ticks that record the world tick at
//!   which a component was first attached to its entity / last
//!   modified. Lives next to the SoA columns in each chunk; the
//!   offset math is in `chunk.zig`'s `ChunkLayout` and the typed
//!   accessors are on `Archetype`.
//! - **Dirty bitset** (per chunk). One bit per slot; set when **any**
//!   component in that slot is modified during the current frame.
//!   Cleared by `World.beginFrame` so the bit only carries
//!   "modified since the start of this frame" semantics. Lets
//!   `Changed<T>` queries skip whole chunks where the bitset is
//!   all-zero before paying the per-slot `changed_tick` comparison.
//!
//! This module owns the bitset abstraction. The byte-level chunk
//! layout (where the bits live) is computed in `chunk.zig`; the
//! per-component tick column accessors are on `Archetype`. The wiring
//! that auto-marks a slot via `get_mut(T)` lives in `world.zig`.

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

/// Reset every bit to zero. Called by `World.beginFrame` on every
/// chunk so the bitset only ever carries "modified since the start
/// of this frame" semantics.
pub fn clearAll(bitset: DirtyBitset) void {
    @memset(bitset, 0);
}

/// `true` iff every word in the bitset is zero. Hot path for the
/// dirty-skip optimisation — bodies that filter by `Changed<T>`
/// can early-out a chunk when this returns `true`. Accepts a
/// `[]const u64` so callers holding a read-only bitset (the
/// `dirtyBitsetConst` accessor) can probe without dropping `const`.
pub fn isAllZero(bitset: []const u64) bool {
    for (bitset) |word| if (word != 0) return false;
    return true;
}

// ─── tests ────────────────────────────────────────────────────────────────

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
