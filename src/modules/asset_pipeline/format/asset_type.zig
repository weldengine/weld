//! Frozen `AssetType` enum — the category tag shared by the runtime
//! `.<type>.bin` header (`asset_type` field) and `AssetHandle.type_tag`.
//!
//! The variant list and explicit values are frozen day 1 (M0.6): the
//! `asset_type` u16 is an on-disk field of every cooked `.bin`, so the
//! numbering must never change. New categories append with the next free
//! value (additive, no renumber). Mirrors the canonical list in
//! `engine-asset-pipeline.md` §10.
//!
//! M0.6 only *populates* `texture`, `mesh`, and `audio` (PNG / static-glTF
//! / WAV); the remaining variants are declared so the frozen numbering is
//! already reserved for later phases.

const std = @import("std");

/// Asset category. Backing type is `u16` to match the `.bin` header
/// `asset_type` field and `AssetHandle.type_tag`. Values are frozen.
pub const AssetType = enum(u16) {
    /// Mesh (M0.6: static only).
    mesh = 0,
    /// 2D texture / image.
    texture = 1,
    /// Audio clip (raw PCM in M0.6).
    audio = 2,
    /// Skeletal animation clip (Phase 1).
    animation = 3,
    /// Font (Phase 1).
    font = 4,
    /// Scene graph.
    scene = 5,
    /// Entity template.
    prefab = 6,
    /// Gameplay code unit.
    script = 7,
    /// Shader program.
    shader = 8,
    /// Material definition.
    material = 9,
    /// Visual effect.
    vfx = 10,
    /// Data table.
    data = 11,
    /// UI widget.
    widget = 12,
    /// Motion asset.
    motion = 13,
    /// Cinematic sequence.
    sequence = 14,
    /// Animation graph.
    anim_graph = 15,
    /// Audio graph.
    audio_graph = 16,
    /// Audio score / arrangement.
    audio_score = 17,
    /// Localization table.
    locale = 18,

    /// Numeric value stored in the `.bin` header `asset_type` field and in
    /// `AssetHandle.type_tag`.
    pub fn toU16(self: AssetType) u16 {
        return @intFromEnum(self);
    }

    /// Decode a stored `u16` into an `AssetType`, or `null` when the value
    /// is not a known variant (e.g. a `.bin` cooked by a future engine
    /// version carrying a category this build does not know).
    pub fn fromU16(value: u16) ?AssetType {
        return std.enums.fromInt(AssetType, value);
    }

    /// Lowercase category tag used in the runtime extension `.<tag>.bin`
    /// (e.g. `mesh` → `.mesh.bin`). Equal to the enum field name.
    pub fn tag(self: AssetType) []const u8 {
        return @tagName(self);
    }
};

test "asset_type u16 round-trips for the populated M0.6 subset" {
    inline for (.{ AssetType.texture, AssetType.mesh, AssetType.audio }) |t| {
        try std.testing.expectEqual(t, AssetType.fromU16(t.toU16()).?);
    }
    // Explicit frozen values — guard against an accidental renumber.
    try std.testing.expectEqual(@as(u16, 0), AssetType.mesh.toU16());
    try std.testing.expectEqual(@as(u16, 1), AssetType.texture.toU16());
    try std.testing.expectEqual(@as(u16, 2), AssetType.audio.toU16());
}

test "asset_type fromU16 rejects an out-of-range value" {
    try std.testing.expectEqual(@as(?AssetType, null), AssetType.fromU16(9999));
}

test "asset_type tag matches the field name" {
    try std.testing.expectEqualStrings("texture", AssetType.texture.tag());
    try std.testing.expectEqualStrings("mesh", AssetType.mesh.tag());
    try std.testing.expectEqualStrings("audio", AssetType.audio.tag());
}
