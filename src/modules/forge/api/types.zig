//! `forge/api/types.zig` — the public Forge descriptor and handle types.
//!
//! These mirror `engine-tier-interfaces.md` §1 (the day-1 interface contract).
//! Type definitions only — no ECS registration, no module instantiation. When
//! `src/interfaces/PhysicsModule.zig` lands (a later milestone) these become
//! its canonical home and `api/` re-exports, touching zero call sites.
//!
//! Math types come from `foundation.math` (Notes decision 3d). Per the E1
//! naming scheme the descriptor fields use the f32 aliases: `Vec3`
//! (`math.Vec3`) and `Quatf` (`math.Quatf`).

const std = @import("std");
const math = @import("foundation").math;
const core = @import("weld_core");

const Vec3 = math.Vec3;
const Quatf = math.Quatf;
const EntityId = core.ecs.EntityId;

/// Opaque physics-body handle. `u32` at the interface boundary
/// (`engine-tier-interfaces.md` §1); internally `index:24 | generation:8`
/// (Notes decision 4) — 16.7 M live bodies, a 256-generation ABA window.
/// Pack/unpack via `PackedId`.
pub const BodyId = u32;

/// Opaque collision-shape handle — same `u32` boundary and `index:24 |
/// generation:8` packing as `BodyId`.
pub const ShapeId = u32;

/// The `index:24 | generation:8` bit layout shared by `BodyId` and `ShapeId`
/// (index in the low 24 bits, generation in the high 8). Stale-handle
/// detection for the free-list slot reuse in `ShapeStore`/`BodyManager` (E3).
pub const PackedId = packed struct(u32) {
    /// Slot index into the owning pool (low 24 bits).
    index: u24,
    /// Generation tag bumped on slot reuse (high 8 bits).
    generation: u8,

    /// Pack an index + generation into the `u32` handle.
    pub fn pack(index: u24, generation: u8) u32 {
        return @bitCast(PackedId{ .index = index, .generation = generation });
    }

    /// Unpack a `u32` handle into its index + generation fields.
    pub fn unpack(id: u32) PackedId {
        return @bitCast(id);
    }
};

/// Simulation class of a rigid body (shared with `PhysicsModule2D`).
/// Explicit `u8` backing so it embeds in the `extern` `RigidBody` component
/// (values and order per `engine-tier-interfaces.md` §1).
pub const BodyType = enum(u8) {
    /// Immovable, never simulated (ground, walls, static geometry).
    static,
    /// Position driven by gameplay; affects dynamics but is not affected.
    kinematic,
    /// Fully simulated — gravity, forces, collision response.
    dynamic,
};

/// Collision-shape kind. `u8`-backed (component tag). C1.1-complete set —
/// the spec §1 enum is a subset; the extension (plane, tapered_cylinder,
/// height_field, mutable_compound, empty) is additive and pre-freeze
/// (Notes decision 3b). M1.1.0 constructs only sphere/box/capsule.
pub const ShapeType = enum(u8) {
    /// Sphere (radius).
    sphere,
    /// Axis-aligned box (half-extents).
    box,
    /// Capsule (radius + cylinder half-height, Y axis).
    capsule,
    /// Solid cylinder.
    cylinder,
    /// Tapered cylinder (cone frustum).
    tapered_cylinder,
    /// Convex hull of a point set.
    convex_hull,
    /// Infinite half-space plane.
    plane,
    /// Static triangle mesh.
    triangle_mesh,
    /// Terrain height field.
    height_field,
    /// Immutable compound of sub-shapes.
    compound,
    /// Mutable compound of sub-shapes.
    mutable_compound,
    /// Empty (no geometry).
    empty,
};

/// Shape parameters, a tagged union discriminated by `ShapeType` (the spec §1
/// flat struct annotates itself as "union discriminée par shape_type —
/// simplifié ici"; the union IS the specified design, Notes decision 3a).
/// M1.1.0 carries payloads for sphere/box/capsule; the rest are `void`
/// placeholders whose payloads land at their own sub-milestones (pre-freeze).
pub const ShapeDescriptor = union(ShapeType) {
    /// Sphere of `radius` metres.
    sphere: struct { radius: f32 = 0.5 },
    /// Box with the given half-extents (metres).
    box: struct { half_extents: Vec3 = Vec3.splat(0.5) },
    /// Capsule of `radius` and cylinder `half_height` (metres), Y axis.
    capsule: struct { radius: f32 = 0.3, half_height: f32 = 0.5 },
    /// Placeholder — payload lands at the cylinder sub-milestone.
    cylinder: void,
    /// Placeholder — payload lands at the tapered-cylinder sub-milestone.
    tapered_cylinder: void,
    /// Placeholder — payload lands at the convex-hull sub-milestone.
    convex_hull: void,
    /// Placeholder — payload lands at the plane sub-milestone.
    plane: void,
    /// Placeholder — payload lands at the triangle-mesh sub-milestone.
    triangle_mesh: void,
    /// Placeholder — payload lands at the height-field sub-milestone.
    height_field: void,
    /// Placeholder — payload lands at the compound sub-milestone.
    compound: void,
    /// Placeholder — payload lands at the mutable-compound sub-milestone.
    mutable_compound: void,
    /// Placeholder — the empty shape carries no parameters.
    empty: void,
};

/// Everything needed to create one body (`engine-tier-interfaces.md` §1).
/// `linear_damping` defaults to 0.05 to agree with the `RigidBody` component
/// and Jolt (spec §1 says 0.01, §2 says 0.05 — Notes decision 3c).
pub const BodyDescriptor = struct {
    /// Owning ECS entity.
    entity: EntityId,
    /// Simulation class.
    body_type: BodyType,
    /// Collision shape (created via `ShapeStore.createShape`).
    shape: ShapeId,
    /// World-space position (metres).
    position: Vec3 = Vec3.zero,
    /// World-space orientation.
    rotation: Quatf = Quatf.identity,
    /// Mass (kg).
    mass: f32 = 1.0,
    /// Coulomb friction coefficient.
    friction: f32 = 0.5,
    /// Restitution (bounciness).
    restitution: f32 = 0.3,
    /// Linear velocity damping per second.
    linear_damping: f32 = 0.05,
    /// Angular velocity damping per second.
    angular_damping: f32 = 0.05,
    /// Collision-layer index.
    collision_layer: u8 = 0,
    /// Per-body gravity multiplier.
    gravity_factor: f32 = 1.0,
    /// Continuous collision detection for fast movers.
    continuous: bool = false,
};

/// A physics pose — position + orientation, no scale. Distinct from the ECS
/// `Transform` component (which carries scale): physics bakes scale into the
/// collider, so runtime scale has no stable physical meaning. Verbatim per
/// `engine-tier-interfaces.md` §1.
pub const Transform = struct {
    /// World-space position (metres).
    position: Vec3,
    /// World-space orientation.
    rotation: Quatf,
};

const testing = std.testing;

test "BodyId pack/unpack round-trip" {
    const id = PackedId.pack(0x123456, 0xAB);
    // index in the low 24 bits, generation in the high 8.
    try testing.expectEqual(@as(u32, (0xAB << 24) | 0x123456), id);
    const u = PackedId.unpack(id);
    try testing.expectEqual(@as(u24, 0x123456), u.index);
    try testing.expectEqual(@as(u8, 0xAB), u.generation);

    const maxed = PackedId.pack(std.math.maxInt(u24), std.math.maxInt(u8));
    try testing.expectEqual(@as(u24, std.math.maxInt(u24)), PackedId.unpack(maxed).index);
    try testing.expectEqual(@as(u8, std.math.maxInt(u8)), PackedId.unpack(maxed).generation);
    try testing.expectEqual(@as(u32, 0), PackedId.pack(0, 0));
}

test "ShapeDescriptor payload defaults" {
    const s = ShapeDescriptor{ .sphere = .{} };
    try testing.expectEqual(@as(f32, 0.5), s.sphere.radius);

    const b = ShapeDescriptor{ .box = .{} };
    try testing.expect(b.box.half_extents.approxEql(Vec3.splat(0.5), 0));

    const c = ShapeDescriptor{ .capsule = .{} };
    try testing.expectEqual(@as(f32, 0.3), c.capsule.radius);
    try testing.expectEqual(@as(f32, 0.5), c.capsule.half_height);
}

test "BodyDescriptor defaults match the brief" {
    const d = BodyDescriptor{
        .entity = EntityId{ .index = 0, .generation = 0 },
        .body_type = .dynamic,
        .shape = 0,
    };
    try testing.expectEqual(@as(f32, 1.0), d.mass);
    try testing.expectEqual(@as(f32, 0.5), d.friction);
    try testing.expectEqual(@as(f32, 0.3), d.restitution);
    try testing.expectEqual(@as(f32, 0.05), d.linear_damping);
    try testing.expectEqual(@as(f32, 0.05), d.angular_damping);
    try testing.expectEqual(@as(u8, 0), d.collision_layer);
    try testing.expectEqual(@as(f32, 1.0), d.gravity_factor);
    try testing.expectEqual(false, d.continuous);
    try testing.expect(d.position.eql(Vec3.zero));
    try testing.expect(d.rotation.approxEql(Quatf.identity, 0));
}

test "ShapeType and BodyType are u8-backed" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ShapeType.sphere));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ShapeType.capsule));
    try testing.expectEqual(@as(u8, 11), @intFromEnum(ShapeType.empty));
    try testing.expectEqual(@as(u8, 0), @intFromEnum(BodyType.static));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(BodyType.dynamic));
}
