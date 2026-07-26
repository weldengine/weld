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

/// Generational ECS entity handle — re-export of `core.ecs.EntityId` so forge
/// solvers reach the core entity type through `api/` (brief §E3), not via a
/// direct `weld_core` import.
pub const EntityId = core.ecs.EntityId;

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

/// Shape parameters, a tagged union discriminated by `ShapeType`. The spec §1
/// flat struct self-describes as a simplification of a discriminated union;
/// the union IS the specified design (Notes decision 3a).
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
    /// Collision-layer index. Bounded to `[0, collision_layer_count)`: the query
    /// mask is 32 bits, so `addBody` REJECTS anything beyond with
    /// `error.InvalidCollisionLayer` instead of creating a body no query could
    /// ever see (§1.11.5).
    collision_layer: u8 = 0,
    /// Per-body gravity multiplier.
    gravity_factor: f32 = 1.0,
    /// Continuous collision detection for fast movers.
    continuous: bool = false,
    /// Whether the body is allowed to fall asleep. Mirrors `RigidBody.can_sleep`
    /// (`engine-physics-forge.md` §2), which the descriptor dropped until M1.1.8 —
    /// the same gap class as the `friction`/`restitution` drop closed at M1.1.6.
    can_sleep: bool = true,
};

// --- Queries (the complete family, frozen before the interface freeze) ---
//
// Mirrors `engine-tier-interfaces.md` §1 verbatim. The family is settled IN FULL
// here even where the body is a Phase-1 stub: adding a method to a comptime
// strategy interface after its freeze (M1.1.15) breaks every Tier 3 solver, so
// deferring a signature is not admissible (`engine-physics-forge.md` §1.11.7).
//
// These types are the f32 PUBLIC boundary, deliberately distinct from their
// solver-side counterparts in `forge_3d/query.zig` (`Filter`, `RayQuery`,
// `RayHit`) which carry the solver scalar. Two levels by design, not duplication:
// §1.11.8 makes the public surface f32 — consistent with `BodyDescriptor`, the
// interface `Transform` and the ECS `Transform` — and widening it is one decision
// over all of them at once, at M1.1.15. The conversion between the two levels is
// the interface tier's, and it is the only place that ever knows both.

/// Number of object layers a query mask can address. The mask is 32 bits, so a
/// body on a layer outside `[0, collision_layer_count)` would be invisible to
/// EVERY query with no diagnostic — which is why `addBody` rejects it with
/// `error.InvalidCollisionLayer` rather than accepting it (§1.11.5). Consistent
/// with the eight default layers of `engine-physics-forge.md` §3.
pub const collision_layer_count: u8 = 32;

/// Filtering shared by the whole query family (`engine-physics-forge.md`
/// §1.11.5). The mask applies to the OBJECT layer of the shape hit, never to the
/// broadphase's broad layers, and a layer is bounded to
/// `[0, collision_layer_count)`.
///
/// Named `PhysicsQueryFilter`, not `QueryFilter`: §6 `AIModule` already carries a
/// `QueryFilter` for its spatial queries. The two are distinct types and neither
/// renames the other.
pub const PhysicsQueryFilter = struct {
    /// A candidate passes when `(1 << layer) & layer_mask` is non-zero.
    layer_mask: u32 = 0xFFFFFFFF,
    /// Bodies ignored. Dominant case: myself.
    exclude: []const BodyId = &.{},
};

/// A world-space ray query. `direction` need not be normalised — it is at the
/// entry. The tested interval is CLOSED, `[0, max_distance]`, and an origin
/// inside a shape produces a hit at distance zero (convexes are solid, §1.11.4).
pub const RaycastQuery = struct {
    /// Ray origin (metres).
    origin: Vec3,
    /// Ray direction.
    direction: Vec3,
    /// Maximum distance; finite and `>= 0`, and `0` degenerates to a point test.
    max_distance: f32,
    /// Object-layer mask + exclusions.
    filter: PhysicsQueryFilter = .{},
};

/// A cast of an arbitrary shape. Replaces the former `SphereCastQuery`: ONE entry
/// serves sphere, box and capsule, and the three Etch forms of
/// `engine-physics-forge.md` §13 are wrappers over it (§1.11.7). Symmetric with
/// `ShapeCastQuery2D`.
pub const ShapeCastQuery = struct {
    /// The shape being cast.
    shape: ShapeId,
    /// Start position of the cast shape (metres).
    origin: Vec3,
    /// Orientation of the cast shape.
    rotation: Quatf = Quatf.identity,
    /// Sweep direction.
    direction: Vec3,
    /// Maximum sweep distance.
    max_distance: f32,
    /// Object-layer mask + exclusions.
    filter: PhysicsQueryFilter = .{},
};

/// An overlap test of an arbitrary shape. Same construction as the cast: the
/// sphere and box overlaps of §13 are wrappers over this one entry.
pub const OverlapQuery = struct {
    /// The shape being tested.
    shape: ShapeId,
    /// Its position (metres).
    position: Vec3,
    /// Its orientation.
    rotation: Quatf = Quatf.identity,
    /// Object-layer mask + exclusions.
    filter: PhysicsQueryFilter = .{},
};

/// One ray hit. `subshape_id` identifies the sub-shape hit and is 0 while one
/// shape is one body; the service derives `physics_material` from it, because the
/// solver result carries the sub-shape identity and never the material itself
/// (§1.11.7 — the same construction as the reference's `CastResult.h`).
pub const RaycastHit = struct {
    /// Entity owning the body hit.
    entity: EntityId,
    /// The body hit.
    body: BodyId,
    /// Sub-shape hit; 0 while one shape is one body.
    subshape_id: u32 = 0,
    /// World-space hit point.
    position: Vec3,
    /// World-space outward surface normal at the hit point.
    normal: Vec3,
    /// Distance from the ray origin — a distance, never a fraction (§1.11.4).
    distance: f32,
};

/// One shape-cast hit. Distinct from `RaycastHit` (parity with `ShapeCastHit2D`):
/// a cast has TWO sub-shapes, the one being cast and the one hit.
pub const ShapeCastHit = struct {
    /// Entity owning the body hit.
    entity: EntityId,
    /// The body hit.
    body: BodyId,
    /// Sub-shape of the body that was hit.
    subshape_id: u32 = 0,
    /// Sub-shape of the CAST shape that made contact.
    cast_subshape_id: u32 = 0,
    /// World-space contact point.
    position: Vec3,
    /// World-space contact normal.
    normal: Vec3,
    /// Sweep distance at contact.
    distance: f32,
};

/// Result of `closestPoint`: the closest point on the closest collider within the
/// requested radius.
pub const ClosestPointResult = struct {
    /// Entity owning the collider.
    entity: EntityId,
    /// The body.
    body: BodyId,
    /// Sub-shape carrying the closest point.
    subshape_id: u32 = 0,
    /// World-space closest point on the collider.
    position: Vec3,
    /// Distance from the queried point.
    distance: f32,
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
    try testing.expectEqual(true, d.can_sleep);
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

test "the frozen query family mirrors engine-tier-interfaces.md §1" {
    // Field NAMES and defaults are the contract: this is a verbatim mirror, and a
    // rename here is a break for every Tier 3 solver after the M1.1.15 freeze.
    const f = PhysicsQueryFilter{};
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), f.layer_mask);
    try testing.expectEqual(@as(usize, 0), f.exclude.len);
    try testing.expectEqual(@as(u8, 32), collision_layer_count);

    const ray = RaycastQuery{ .origin = Vec3.zero, .direction = Vec3.unit_x, .max_distance = 10 };
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), ray.filter.layer_mask);

    const cast = ShapeCastQuery{ .shape = 0, .origin = Vec3.zero, .direction = Vec3.unit_x, .max_distance = 1 };
    try testing.expect(cast.rotation.approxEql(Quatf.identity, 0));

    const overlap = OverlapQuery{ .shape = 0, .position = Vec3.zero };
    try testing.expect(overlap.rotation.approxEql(Quatf.identity, 0));

    // `subshape_id` defaults to 0 — one shape is one body today, and it is by this
    // field that the service derives the material, never from the solver result.
    const hit = RaycastHit{
        .entity = .{ .index = 0, .generation = 0 },
        .body = 0,
        .position = Vec3.zero,
        .normal = Vec3.unit_y,
        .distance = 1,
    };
    try testing.expectEqual(@as(u32, 0), hit.subshape_id);

    const cast_hit = ShapeCastHit{
        .entity = .{ .index = 0, .generation = 0 },
        .body = 0,
        .position = Vec3.zero,
        .normal = Vec3.unit_y,
        .distance = 1,
    };
    // A cast has TWO sub-shapes; that second field is what distinguishes this
    // type from `RaycastHit` and why they are not merged.
    try testing.expectEqual(@as(u32, 0), cast_hit.subshape_id);
    try testing.expectEqual(@as(u32, 0), cast_hit.cast_subshape_id);

    const closest = ClosestPointResult{
        .entity = .{ .index = 0, .generation = 0 },
        .body = 0,
        .position = Vec3.zero,
        .distance = 2,
    };
    try testing.expectEqual(@as(u32, 0), closest.subshape_id);

    // The public boundary is f32 (§1.11.8) — pinned, because widening it is a
    // single decision over `BodyDescriptor`, the interface pose, the query results
    // and the ECS `Transform` together, at M1.1.15, and never one of them alone.
    try testing.expectEqual(f32, @TypeOf(hit.distance));
    try testing.expectEqual(f32, @TypeOf(ray.max_distance));
    try testing.expectEqual(f32, @TypeOf(closest.distance));
}
