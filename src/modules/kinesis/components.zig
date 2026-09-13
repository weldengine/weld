//! The ECS components Kinesis registers.
//!
//! Strictly POD `extern struct` (`ARCH-004`, `engine-zig-conventions.md` §16):
//! no pointer, no slice, no method, every field defaulted. The variable-length
//! state an animated entity needs — its poses — is NOT here and cannot be: it
//! lives in module-owned storage reached through the `SkeletonId` below.

const std = @import("std");

const anim = @import("weld_interfaces_animation");

const AssetHandle = anim.AssetHandle;
const SkeletonId = anim.SkeletonId;

/// An entity posed against a skeleton.
///
/// `instance` is the handle into the module's own storage, where the two poses
/// live: the LOCAL pose, each bone relative to its parent, and the
/// SKELETON-RELATIVE pose that forward kinematics derives from it. Neither is
/// a field here, because a pose is variable-length and a component is not.
///
/// **The entity's own `Transform` is a third space and does not enter either
/// pose.** Composing it inside the kinematics would bake the entity's world
/// placement into every bone, which reads as correct on an entity sitting at
/// the origin and is wrong everywhere else — and it would be wrong twice over
/// at the consumers, which compose it themselves.
pub const Skeleton = extern struct {
    /// The skeleton asset this entity is posed against.
    asset: AssetHandle = @enumFromInt(0),
    /// The module-side instance, or `no_skeleton` while none is bound.
    instance: SkeletonId = anim.no_skeleton,
};

comptime {
    // Pin the wire layout. A size assertion alone would pass a reshuffle of
    // two same-width fields, so the offsets are pinned too — the same guard
    // the engine's reflected composites were missing.
    std.debug.assert(@sizeOf(Skeleton) == 16);
    std.debug.assert(@alignOf(Skeleton) == 8);
    std.debug.assert(@offsetOf(Skeleton, "asset") == 0);
    std.debug.assert(@offsetOf(Skeleton, "instance") == 8);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "Skeleton is POD and defaults to no instance" {
    const s = Skeleton{};
    try testing.expectEqual(anim.no_skeleton, s.instance);
    try testing.expect(s.instance != 0);
    try testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(Skeleton).@"struct".layout);
}
