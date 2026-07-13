//! `forge/api/components.zig` — the public Forge ECS components.
//!
//! `extern struct` POD, no methods, every field defaulted — same discipline as
//! `core.ecs.components` (`engine-zig-conventions.md` §16). Definitions only:
//! no registration here (that is runtime wiring for the milestone that
//! instantiates the module). Layouts pinned by comptime size/align asserts.
//! Per `engine-physics-forge.md` §2.

const std = @import("std");
const core = @import("weld_core");
const types = @import("types.zig");

const BodyType = types.BodyType;
const ShapeType = types.ShapeType;

/// Linear + angular velocity — re-exported from `core.ecs.components` rather
/// than redefined (moving it into Forge would invert the core→Tier-1
/// dependency; Notes decision 2). All physics call sites use `api.Velocity`.
pub const Velocity = core.ecs.components.Velocity;

/// A rigid body's material and simulation parameters
/// (`engine-physics-forge.md` §2). Position/rotation live on the ECS
/// `Transform`; velocity on `Velocity`; accumulated forces on `PhysicsForces`.
pub const RigidBody = extern struct {
    /// Simulation class.
    body_type: BodyType = .dynamic,
    /// Mass (kg).
    mass: f32 = 1.0,
    /// Linear velocity damping per second.
    linear_damping: f32 = 0.05,
    /// Angular velocity damping per second.
    angular_damping: f32 = 0.05,
    /// Coulomb friction coefficient.
    friction: f32 = 0.5,
    /// Restitution (bounciness).
    restitution: f32 = 0.3,
    /// Per-body gravity multiplier.
    gravity_scale: f32 = 1.0,
    /// Continuous collision detection for fast movers.
    continuous_collision: bool = false,
    /// Whether the body may go to sleep when at rest.
    can_sleep: bool = true,
};

/// Per-shape parameters for a `CollisionShape`, an `extern` (untagged) union
/// overlaid by `CollisionShape.shape_type` (§2 "extern union of per-shape
/// params"). M1.1.0 carries sphere/box/capsule; other shapes read no params.
pub const ShapeParams = extern union {
    /// Sphere radius (metres).
    sphere: extern struct { radius: f32 = 0.5 },
    /// Box half-extents (metres).
    box: extern struct { half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 } },
    /// Capsule radius + cylinder half-height (metres), Y axis.
    capsule: extern struct { radius: f32 = 0.3, half_height: f32 = 0.5 },
};

/// A collision shape attached to an entity (`engine-physics-forge.md` §2). The
/// `shape_type` tag selects the active `params` variant.
pub const CollisionShape = extern struct {
    /// Which shape the `params` union holds.
    shape_type: ShapeType = .sphere,
    /// Per-shape parameters, overlaid by `shape_type`.
    params: ShapeParams = .{ .sphere = .{} },
    /// Local-space position offset (metres).
    offset: [3]f32 = .{ 0, 0, 0 },
    /// Local-space rotation offset (quaternion, x, y, z, w).
    rotation_offset: [4]f32 = .{ 0, 0, 0, 1 },
    /// Collision-layer index.
    collision_layer: u8 = 0,
    /// Trigger (overlap events only, no physical response).
    is_trigger: bool = false,
};

/// Forces + torques accumulated during a frame, applied and reset each fixed
/// tick. Padded to 16-byte lanes like `Velocity` (§2).
pub const PhysicsForces = extern struct {
    /// Accumulated linear force (N).
    force: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad0: f32 = 0,
    /// Accumulated torque (N·m).
    torque: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad1: f32 = 0,
};

comptime {
    // POD layout pins — any future field change must revisit these.
    std.debug.assert(@sizeOf(RigidBody) == 32);
    std.debug.assert(@alignOf(RigidBody) == 4);
    std.debug.assert(@sizeOf(CollisionShape) == 48);
    std.debug.assert(@alignOf(CollisionShape) == 4);
    std.debug.assert(@sizeOf(PhysicsForces) == 32);
    std.debug.assert(@alignOf(PhysicsForces) == 16);
}

const testing = std.testing;

test "component layouts are the pinned extern-POD sizes" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(RigidBody));
    try testing.expectEqual(@as(usize, 4), @alignOf(RigidBody));
    try testing.expectEqual(@as(usize, 48), @sizeOf(CollisionShape));
    try testing.expectEqual(@as(usize, 4), @alignOf(CollisionShape));
    try testing.expectEqual(@as(usize, 32), @sizeOf(PhysicsForces));
    try testing.expectEqual(@as(usize, 16), @alignOf(PhysicsForces));
}

test "Velocity is the core component (re-export identity)" {
    try testing.expect(Velocity == core.ecs.components.Velocity);
}

test "RigidBody defaults match the spec" {
    const rb = RigidBody{};
    try testing.expectEqual(BodyType.dynamic, rb.body_type);
    try testing.expectEqual(@as(f32, 1.0), rb.mass);
    try testing.expectEqual(@as(f32, 0.05), rb.linear_damping);
    try testing.expectEqual(@as(f32, 0.05), rb.angular_damping);
    try testing.expectEqual(@as(f32, 0.5), rb.friction);
    try testing.expectEqual(@as(f32, 0.3), rb.restitution);
    try testing.expectEqual(@as(f32, 1.0), rb.gravity_scale);
    try testing.expectEqual(false, rb.continuous_collision);
    try testing.expectEqual(true, rb.can_sleep);
}

test "CollisionShape default is a unit-ish sphere trigger-off" {
    const cs = CollisionShape{};
    try testing.expectEqual(ShapeType.sphere, cs.shape_type);
    try testing.expectEqual(@as(f32, 0.5), cs.params.sphere.radius);
    try testing.expectEqual(@as(f32, 1), cs.rotation_offset[3]);
    try testing.expectEqual(false, cs.is_trigger);
}
