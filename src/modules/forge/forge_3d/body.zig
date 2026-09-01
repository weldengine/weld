//! `forge_3d/body.zig` — per-body data and its derived motion properties.
//!
//! `MotionProperties` holds the inverse mass + inverse local inertia the solver
//! integrates against; `computeMotion` derives them from a `BodyDescriptor` and
//! its `Shape`. Static and kinematic bodies have zero inverse mass and inertia
//! (infinite effective mass). `Body` is the SoA row `BodyManager` stores. The
//! `friction`/`restitution` columns are the per-body material coefficients the
//! Sequential Impulses contact solver reads (M1.1.6).
//!
//! The `force`/`torque` columns are world-space per-tick accumulators (N, N·m):
//! `BodyManager.addForce`/`addTorque` add into them and `integrate` (E2) reads
//! then clears them each fixed tick (the `engine-physics-forge.md` §2 per-tick
//! reset contract). Being independent SoA columns, they leave the
//! position/rotation bulk-sync layout invariant (M1.1.15) untouched.

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
    /// Whether this body is ALLOWED to fall asleep. `false` forbids it — and
    /// therefore forbids any island it belongs to from sleeping, since an island
    /// sleeps only if every member can (`engine-physics-forge.md` §1.8.3).
    can_sleep: bool = true,
    /// Whether this body is currently asleep. A sleeper is not simulated: it is
    /// skipped by both integration passes and by the broadphase proxy update, its
    /// pairs produce no narrowphase work, and its sleep window stops advancing
    /// (§1.8.6).
    sleeping: bool = false,
    /// Whether this body is a SENSOR: it detects without responding
    /// (`engine-physics-solver.md` §1.13). It is inserted into the `trigger` broad
    /// class, whose pair-matrix row and column are `false` in full, so no candidate
    /// pair involving it ever reaches constraint construction — hence no manifold,
    /// no impulse and no island membership (§1.13.7).
    ///
    /// A FLAG and not a column because it is one bit that costs nothing here; the
    /// detection MASK is a separate column, being 32 bits wide.
    is_trigger: bool = false,
    /// Whether gameplay, and not the solver, is the WRITE AUTHORITY on this body's
    /// pose (`engine-physics-forge.md` § *Autorite d'ecriture*, ASCII-folded here for
    /// the same reason every other citation in this tree is). It mirrors the ECS
    /// `RigidBody.authority` field, which is Tier 1 and which the solver cannot read.
    ///
    /// **What it means is declared in ONE place** — `weld_forge`'s
    /// `PhysicsAuthority`, which transcribes the owner document's three clauses. This
    /// field is the solver-side MIRROR of that declaration and states none of it.
    ///
    /// The prose that stood here said the flag's "ONE effect inside the solver is that
    /// the inverse mass is set to zero during resolution", and that the body was
    /// "integrated normally" and kept "the same island". All three became false — the
    /// first named one impulse path of three, and the other two were reversed when the
    /// regime was corrected to follow the kinematic one.
    gameplay_authority: bool = false,
    _reserved: u3 = 0,
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
    ///
    /// **INVARIANT: unit at the solver's precision, permanently.** `addBody`
    /// establishes it — the descriptor rotation is `f32` by design
    /// (`engine-physics-forge.md` §1.11.8), and an `f32`-unit quaternion widened
    /// to `f64` is off by `|q|² − 1 ≈ 3e-8`, so the widened value is normalised at
    /// creation — and both integrators maintain it, each re-normalising after its
    /// first-order orientation step. Before M1.1.9 the invariant held by accident
    /// for a dynamic body from its first tick and NEVER for a static or kinematic
    /// one, which are never integrated: a static collider's frame was scaled by
    /// `1 ± 3e-8`, which at 10 km — the regime `-Dphysics_f64` exists for — is
    /// 0.34 mm on geometry that never moves. Every consumer that rotates a vector
    /// by this field relies on it: inertia transport, lever arms, the sleep chord,
    /// the ray transport of `raycastBody`.
    rotation: Quatr,
    /// World-space linear velocity.
    linear_velocity: Vec3r,
    /// World-space angular velocity.
    angular_velocity: Vec3r,
    /// Accumulated world-space force (N) for the current tick; `addForce`
    /// accumulates, `integrate` reads then clears it each fixed tick.
    force: Vec3r,
    /// Accumulated world-space torque (N·m) for the current tick; `addTorque`
    /// accumulates, `integrate` reads then clears it each fixed tick.
    torque: Vec3r,
    /// Derived inverse mass/inertia + damping/gravity.
    motion: MotionProperties,
    /// Coulomb friction coefficient (>= 0), stored from the descriptor. Consumed
    /// by the Sequential Impulses contact solver (M1.1.6); the M1.1.5 `addBody`
    /// dropped it.
    friction: Real,
    /// Restitution / bounciness in [0, 1], stored from the descriptor. Consumed
    /// by the Sequential Impulses contact solver (M1.1.6); the M1.1.5 `addBody`
    /// dropped it.
    restitution: Real,
    /// Collision-shape handle (into a `ShapeStore`).
    shape: ShapeId,
    /// Simulation class.
    body_type: BodyType,
    /// Object collision-layer index (stored from the descriptor). Read by the query
    /// family's object-layer mask (§1.11.5) and, since M1.1.13, by the sensor pass,
    /// which tests it against the TRIGGER's `trigger_layer_mask` (§1.13.5). The
    /// object-layer pair filtering / `CollisionConfig` matrix is still unwired.
    collision_layer: u8,
    /// OBJECT layers this body detects WHEN IT IS A TRIGGER — inert otherwise. A
    /// candidate passes when `(1 << candidate.collision_layer) & trigger_layer_mask`
    /// is non-zero (§1.13.5).
    ///
    /// UNILATERAL: it belongs to the trigger and describes what IT sees, so two
    /// overlapping triggers are two relations evaluated separately and A may see B
    /// without B seeing A. It is therefore NOT a pair predicate and must never be
    /// consulted symmetrically.
    ///
    /// A separate SoA COLUMN and not a flag: 32 bits do not fit in `BodyFlags`, and
    /// storing it beside `collision_layer` keeps the two object-layer quantities —
    /// what the body IS and what it SEES — adjacent, which is the pairing
    /// §1.12.4 already draws for the character controller.
    trigger_layer_mask: u32,
    /// Per-body flags.
    flags: BodyFlags,
    /// Seconds the body has stayed within `SleepConfig.maxDisplacement()` of its
    /// reference pose. Eligibility is `sleep_time >= time_before_sleep`
    /// (`engine-physics-forge.md` §1.8.3). The window lives on the BODY and never
    /// on the island: an island is rebuilt every tick and its identity is not
    /// persistent, so a timer attached to one would be incoherent by construction.
    sleep_time: Real,
    /// Position at the start of the current sleep window. The criterion is a
    /// DISPLACEMENT bound measured against this reference, never an instantaneous
    /// velocity — a velocity criterion resets on a single noisy tick and never
    /// sleeps a jittering body.
    sleep_ref_position: Vec3r,
    /// Orientation at the start of the current sleep window (see
    /// `sleep_ref_position`).
    sleep_ref_rotation: Quatr,
    /// Distance from the body centre to the furthest corner of its shape's LOCAL
    /// AABB, computed once at creation. It converts the rotation since the
    /// reference pose into the displacement of the body's furthest material point,
    /// so one bound in metres covers both translation and rotation.
    ///
    /// **NaN for a half-space**, which has no local AABB to derive it from. Nothing
    /// reads it there: such a body can only be `.static` (`addBody` rejects any other
    /// type with `error.ShapeMustBeStatic`), and both `sleep.updateWindows` and the
    /// island seeding skip a non-dynamic body before touching the radius.
    sleep_radius: Real,
    /// Owning ECS entity.
    entity: EntityId,
    /// The body's TIGHT world AABB, cached at creation — **valid ONLY while the shape is a
    /// `.triangle_soup`**, NaN on every other body.
    ///
    /// **Why it exists, and it is a measured decision and not a precaution.** A mesh's world
    /// box is the tight bound over its TRANSPORTED VERTICES, an O(V) pass, and
    /// `aabbOverlapsBody` runs it once per candidate body per query. Measured in ReleaseFast
    /// on `bench/forge_3d_mesh.zig`: 9.0 µs at 1 000 triangles, 20.4 µs at 4 000 and
    /// **72.8 µs at 16 000**, against **11.5 ns** for the same value read back — some 6 300×
    /// — with `overlapAabb` end to end at 85.8 µs, i.e. dominated by that one pass. The
    /// cheapest entry of the family was the most expensive.
    ///
    /// **Why it needs no invalidation LOGIC.** A mesh forces a STATIC body
    /// (`error.ShapeMustBeStatic`), whose pose no solver pass writes: both integrators skip
    /// a non-dynamic body, and the NGS position pass guards its pose writes at EXACT ZERO
    /// precisely so a non-dynamic body stays bit-unchanged. So the cached box cannot go
    /// stale from inside the simulation.
    ///
    /// **What it does instead of invalidating: it POISONS.** The only way the pose can move
    /// is an external teleport, and `setPosition` / `setRotation` set this field back to NaN
    /// for any non-dynamic body rather than trying to recompute it — they hold no store and
    /// could not. The mesh arm then falls back to the O(V) pass, which is the pre-cache
    /// behaviour: slower, never wrong. That is what keeps the correctness of this cache from
    /// resting on a promise about a milestone that does not exist yet.
    ///
    /// NaN and not a sentinel box, for the reason `local_aabb` and `sleep_radius` carry NaN:
    /// a plausible finite value would be read by mistake and never noticed.
    world_aabb: config.Aabbr,
};

/// The body's sleep radius: the distance from its centre to the furthest corner
/// of `shape`'s local AABB (`engine-physics-forge.md` §1.8.3). Taking the
/// component-wise maximum of `|min|` and `|max|` picks that corner without
/// enumerating all eight — the furthest one is the one furthest along every axis
/// at once. Computed once, at body creation: it is pose-invariant.
///
/// **PRECONDITION: the shape has a local AABB.** This reads `local_aabb`, so it is a
/// DISPATCH on the class and not an assert on one variant of it (M1.1.11.1): a bounded
/// convex and a triangle soup both have a valid local box and the same formula answers
/// both, a half-space has none at all — the field is NaN there.
///
/// The two admitted categories differ in one respect the formula already handles: a
/// mesh's local box is NOT centred on the origin, and taking the corner furthest from
/// the body CENTRE is what this computes either way.
///
/// A mesh body's radius is never read in practice, a mesh forcing a static body just as
/// a half-space does; it is returned rather than poisoned because it is DEFINED, and
/// answering a defined quantity costs nothing while poisoning it would need a reader to
/// justify it. `addBody` never asks the half-space: a non-static body carrying one is
/// rejected with `error.ShapeMustBeStatic` before the `Body` literal is built, and for a
/// static one the literal dispatches on the class instead of calling this
/// (`sleep.updateWindows` and the island seeding both skip a non-dynamic body before
/// reading the radius).
pub fn computeSleepRadius(shape: Shape) Real {
    switch (shape.class()) {
        .convex, .triangle_soup => {},
        .half_space => unreachable,
    }
    return shape.local_aabb.min.abs().max(shape.local_aabb.max.abs()).length();
}

/// Derive `MotionProperties` from a descriptor and its shape. Inertia is the
/// shape's unit-mass diagonal scaled by `desc.mass`, then inverted per axis.
/// Static/kinematic bodies get zero inverse mass and inertia.
///
/// The class precondition is on the DYNAMIC PATH ONLY, and deliberately not at the
/// entry: a STATIC body carrying a half-space — or a mesh — is legal (§1.11.15,
/// §1.11.17) and takes the early return below without ever touching `unit_inertia`.
/// Asserting at the entry would refuse the one body type those two are allowed to have.
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

    // The dynamic path reads `unit_inertia`, which NEITHER a half-space NOR a mesh has
    // (NaN in both). A DISPATCH on the class rather than an assert on one variant of it
    // (M1.1.11.1), so a fourth category is a compile error here and must state whether
    // it has an inertia tensor. Both non-convex arms are unreachable from `addBody`,
    // which rejects a dynamic body carrying either with `error.ShapeMustBeStatic` before
    // building the `Body` — this is what makes that rejection's ORDERING load-bearing
    // rather than stylistic (§1.11.15): move it after the literal and a dynamic
    // half-space or mesh lands here instead.
    switch (shape.class()) {
        .convex => {},
        .half_space, .triangle_soup => unreachable,
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

test "the sensor flag costs no byte and leaves the existing flags in place" {
    // `is_trigger` takes one of the five bits `_reserved` carried, so the byte is
    // unchanged — asserted, because the whole reason the role is a FLAG and the mask is
    // a COLUMN is that the flag was free and 32 bits are not.
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(BodyFlags));
    try std.testing.expectEqual(u8, @typeInfo(BodyFlags).@"struct".backing_integer.?);

    // Default OFF, and the three pre-existing defaults unmoved: a body that says nothing
    // about the role is a normal body.
    const f = BodyFlags{};
    try std.testing.expectEqual(false, f.is_trigger);
    try std.testing.expectEqual(false, f.continuous);
    try std.testing.expectEqual(true, f.can_sleep);
    try std.testing.expectEqual(false, f.sleeping);

    // The bit is DISJOINT from the three that already existed. Setting it alone must not
    // move any other, which a positive control makes meaningful: `sleeping` alone gives a
    // different byte, so the comparison below is between two reachable states and not
    // between one state and itself.
    const only_trigger: u8 = @bitCast(BodyFlags{ .can_sleep = false, .is_trigger = true });
    const only_sleeping: u8 = @bitCast(BodyFlags{ .can_sleep = false, .sleeping = true });
    try std.testing.expect(only_trigger != only_sleeping);
    try std.testing.expectEqual(@as(u8, 0), only_trigger & only_sleeping);
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
