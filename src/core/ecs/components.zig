//! S1 component definitions — `Transform` and `Velocity` POD `extern struct`.
//!
//! Layout follows the suggested baseline of `briefs/S1-mini-ecs.md` (Notes):
//! pos/rot/scale (resp. linear/angular) each on their own 16-byte lane via
//! field-level `align(16)`. Total sizes are 48 (Transform) and 32 (Velocity)
//! bytes, both 16-byte aligned — friendly to `@Vector(4, f32)` SIMD and to
//! the chunk SoA layout (cf. `chunk.zig`). Per `engine-zig-conventions.md`
//! §16, components are `extern struct` POD, carry no methods, and default
//! every field. The trailing `_pad*` slots round each lane to 16 bytes.

const std = @import("std");

/// 64-bit entity identifier. S1 uses a flat monotonic counter without a
/// generational tag — `briefs/S1-mini-ecs.md` Out-of-scope explicitly defers
/// generational indices and FreeList sophistication beyond what spawning and
/// despawning 100 000 entities requires.
pub const EntityId = u64;

/// Position, rotation (quaternion), and scale of an entity in world space.
pub const Transform = extern struct {
    pos: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad0: f32 = 0,
    rot: [4]f32 align(16) = .{ 0, 0, 0, 1 },
    scale: [3]f32 align(16) = .{ 1, 1, 1 },
    _pad1: f32 = 0,
};

/// Linear and angular velocity of an entity (units per second / radians per
/// second). The S1 bench body integrates `linear` against `Transform.pos`.
pub const Velocity = extern struct {
    linear: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad0: f32 = 0,
    angular: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad1: f32 = 0,
};

comptime {
    // Lock the layout assumed by `chunk.zig` and the bench. Any future change
    // to these sizes/alignments must update the chunk capacity test.
    std.debug.assert(@sizeOf(Transform) == 48);
    std.debug.assert(@alignOf(Transform) == 16);
    std.debug.assert(@sizeOf(Velocity) == 32);
    std.debug.assert(@alignOf(Velocity) == 16);
    std.debug.assert(@sizeOf(EntityId) == 8);
}
