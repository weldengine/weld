//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! `AssetHandle` — the 64-bit typed, generation-checked asset reference.
//!
//! Layout frozen day 1 (M0.6, brief §Scope). `packed struct(u64)` fixes the
//! field order low-to-high: `index` (u32) addresses the registry slot table,
//! `generation` (u16) detects use-after-unload of a stale handle, `type_tag`
//! (u16) carries the `AssetType` so a handle can be type-checked without a
//! registry lookup. Named `AssetHandle`, not `AssetRef`
//! (`engine-asset-pipeline.md` §8).

const std = @import("std");
const AssetType = @import("../format/asset_type.zig").AssetType;

/// 64-bit asset reference. Always 8 bytes; the `packed struct(u64)` layout
/// is the frozen surface — `@as(u64, @bitCast(h))` is stable on-the-wire.
pub const AssetHandle = packed struct(u64) {
    /// Registry slot index.
    index: u32,
    /// Slot generation at allocation time; bumped on unload so any
    /// outstanding handle to the previous occupant fails resolution.
    generation: u16,
    /// `AssetType` value (`@intFromEnum`) of the referenced asset.
    type_tag: u16,

    /// Bit pattern reserved for "no asset". Never produced by
    /// `Registry.alloc` — `index = maxInt(u32)` would require 4 G slots.
    pub const none = AssetHandle{
        .index = std.math.maxInt(u32),
        .generation = std.math.maxInt(u16),
        .type_tag = std.math.maxInt(u16),
    };

    /// Pack the handle into its raw 64-bit representation.
    pub fn toU64(self: AssetHandle) u64 {
        return @bitCast(self);
    }

    /// Reconstruct a handle from its raw 64-bit representation.
    pub fn fromU64(bits: u64) AssetHandle {
        return @bitCast(bits);
    }

    /// Decode the `type_tag` into an `AssetType`, or `null` if it is not a
    /// known variant.
    pub fn assetType(self: AssetHandle) ?AssetType {
        return AssetType.fromU16(self.type_tag);
    }

    /// `true` if both handles refer to the same slot, generation, and type.
    pub fn eql(a: AssetHandle, b: AssetHandle) bool {
        return a.toU64() == b.toU64();
    }
};

test "asset handle is exactly 64 bits" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(AssetHandle));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(AssetHandle));
}

test "asset handle packs and unpacks losslessly" {
    const h = AssetHandle{ .index = 7, .generation = 3, .type_tag = AssetType.texture.toU16() };
    const bits = h.toU64();
    const back = AssetHandle.fromU64(bits);
    try std.testing.expect(h.eql(back));
    try std.testing.expectEqual(AssetType.texture, back.assetType().?);
}

test "asset handle low-to-high field packing matches the frozen layout" {
    const h = AssetHandle{ .index = 0x11223344, .generation = 0x5566, .type_tag = 0x7788 };
    // index in the low 32 bits, generation in [32,48), type_tag in [48,64).
    try std.testing.expectEqual(@as(u64, 0x7788_5566_11223344), h.toU64());
}

test "asset handle none sentinel is distinct from a real handle" {
    const real = AssetHandle{ .index = 0, .generation = 0, .type_tag = 0 };
    try std.testing.expect(!real.eql(AssetHandle.none));
}
