//! `forge_3d/body.zig` — per-body data and its derived motion properties.
//!
//! `MotionProperties` holds the inverse mass + inverse local inertia the solver
//! integrates against; `computeMotion` derives them from a `BodyDescriptor` and
//! its `Shape`. Static and kinematic bodies have zero inverse mass and inertia
//! (infinite effective mass). `Body` is the SoA row `BodyManager` stores.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const Shape = @import("shape.zig").Shape;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const BodyType = api.BodyType;
const BodyDescriptor = api.BodyDescriptor;
const ShapeId = api.ShapeId;
const EntityId = api.EntityId;

/// Per-body simulation flags packed into one byte.
pub const BodyFlags = packed struct(u8) {
    /// Continuous collision detection for fast movers (stored, unused until CCD).
    continuous: bool = false,
    _reserved: u7 = 0,
};

/// The inverse quantities the integrator/solver act on. Static and kinematic
/// bodies carry zeros (they are not moved by forces).
pub const MotionProperties = struct {
    /// 1/mass, or 0 for static/kinematic.
    inv_mass: Real,
    /// Inverse of the local inertia tensor (diagonal for M1.1.0 shapes), or the
    /// zero matrix for static/kinematic.
    local_inv_inertia: Mat3r,
    /// Linear velocity damping per second.
    linear_damping: Real,
    /// Angular velocity damping per second.
    angular_damping: Real,
    /// Per-body gravity multiplier.
    gravity_factor: Real,
};

/// One SoA row of the `BodyManager`.
pub const Body = struct {
    /// World-space position.
    position: Vec3r,
    /// World-space orientation.
    rotation: Quatr,
    /// World-space linear velocity.
    linear_velocity: Vec3r,
    /// World-space angular velocity.
    angular_velocity: Vec3r,
    /// Derived inverse mass/inertia + damping/gravity.
    motion: MotionProperties,
    /// Collision-shape handle (into a `ShapeStore`).
    shape: ShapeId,
    /// Simulation class.
    body_type: BodyType,
    /// Per-body flags.
    flags: BodyFlags,
    /// Owning ECS entity.
    entity: EntityId,
};

/// Derive `MotionProperties` from a descriptor and its shape. Inertia is the
/// shape's unit-mass diagonal scaled by `desc.mass`, then inverted per axis.
/// Static/kinematic bodies get zero inverse mass and inertia.
pub fn computeMotion(desc: BodyDescriptor, shape: Shape) MotionProperties {
    const ld: Real = desc.linear_damping;
    const ad: Real = desc.angular_damping;
    const gf: Real = desc.gravity_factor;

    if (desc.body_type != .dynamic) {
        return .{
            .inv_mass = 0,
            .local_inv_inertia = Mat3r.fromDiagonal(Vec3r.zero),
            .linear_damping = ld,
            .angular_damping = ad,
            .gravity_factor = gf,
        };
    }

    // A dynamic body must have positive mass (inv_mass/inertia divide by it).
    // Full descriptor validation (typed errors, degenerate geometry) is a later
    // milestone; this guards the unchecked dynamic path.
    std.debug.assert(desc.mass > 0);
    const mass: Real = desc.mass;
    const inertia = shape.unit_inertia.scale(mass).toArray(); // principal-axis diagonal
    const inv_inertia = Vec3r.fromArray(.{
        1.0 / inertia[0],
        1.0 / inertia[1],
        1.0 / inertia[2],
    });
    return .{
        .inv_mass = 1.0 / mass,
        .local_inv_inertia = Mat3r.fromDiagonal(inv_inertia),
        .linear_damping = ld,
        .angular_damping = ad,
        .gravity_factor = gf,
    };
}

test "static and kinematic bodies have zero inverse mass and inertia" {
    const zero_shape = Shape{
        .shape_type = .sphere,
        .radius = 1,
        .local_aabb = config.Aabbr.fromCenterHalfExtents(Vec3r.zero, Vec3r.splat(1)),
        .unit_inertia = Vec3r.splat(0.4),
    };
    inline for (.{ BodyType.static, BodyType.kinematic }) |bt| {
        const mp = computeMotion(.{
            .entity = .{ .index = 0, .generation = 0 },
            .body_type = bt,
            .shape = 0,
            .mass = 10,
        }, zero_shape);
        try std.testing.expectEqual(@as(Real, 0), mp.inv_mass);
        const c = mp.local_inv_inertia.cols;
        try std.testing.expect(c[0].approxEql(Vec3r.zero, 0));
        try std.testing.expect(c[1].approxEql(Vec3r.zero, 0));
        try std.testing.expect(c[2].approxEql(Vec3r.zero, 0));
    }
}
