//! POD `extern struct` components, every field defaulted. Each lane carries a
//! field-level `align(16)` and a trailing `_pad`, so the sizes are 48 and 32 —
//! pinned below, because `chunk.zig`'s capacity math assumes them.

const std = @import("std");
const entity_mod = @import("entity.zig");

/// Canonical generational entity identifier — see `entity.zig`.
pub const EntityId = entity_mod.EntityId;

/// Position, rotation (quaternion), and scale of an entity in world space.
pub const Transform = extern struct {
    pos: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad0: f32 = 0,
    rot: [4]f32 align(16) = .{ 0, 0, 0, 1 },
    scale: [3]f32 align(16) = .{ 1, 1, 1 },
    _pad1: f32 = 0,
};

/// Linear and angular velocity, per second and radians per second.
pub const Velocity = extern struct {
    linear: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad0: f32 = 0,
    angular: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad1: f32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Transform) == 48);
    std.debug.assert(@alignOf(Transform) == 16);
    std.debug.assert(@sizeOf(Velocity) == 32);
    std.debug.assert(@alignOf(Velocity) == 16);
    std.debug.assert(@sizeOf(EntityId) == 8);
}
