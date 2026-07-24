//! `forge_3d/rigid/contact_constraint.zig` — the velocity-level contact
//! constraint of the rigid-body Sequential Impulses solver (Catto lineage,
//! Box2D/Jolt tradition), plus its build/precompute front end.
//!
//! The rigid branch lives in `rigid/` (distinct from the branch-shared
//! `pipeline/`; `engine-physics-forge.md` §1.2). This file owns:
//!   - the material combine rules (`combineFriction` = √(a·b), `combineRestitution`
//!     = max(a, b) — the Box2D/Jolt convention);
//!   - `tangentBasis`, a trig-free deterministic orthonormal basis for a contact
//!     normal;
//!   - `ContactConstraint` (one per manifold, ≤ 4 inline points) with its
//!     per-point solver data;
//!   - `build`, which turns canonical broadphase candidate pairs into a
//!     deterministically-ordered constraint array, running the narrowphase and
//!     the per-point `prepare` precompute (lever arms, world inverse inertias,
//!     normal + two tangent effective masses, pre-solve normal velocity `v_n⁻`).
//!
//! Import discipline (brief): `foundation`, `weld_forge` (handle types),
//! `../config.zig`, `../body_manager.zig`, `../pipeline/narrowphase/root.zig`.
//! NEVER `broadphase.zig` — candidate pairs are consumed as data (packed `u64`
//! keys), never re-derived — and never any `pipeline/` file beyond the
//! narrowphase facade.
//!
//! M1.1.6 is a VELOCITY solver: it carries NO positional bias (no Baumgarte, no
//! split impulse). `ContactPoint.penetration` is carried but unconsumed here; the
//! NGS position solver (M1.1.7) is the spec's position-correction answer.

const std = @import("std");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const BodyManager = bm_mod.BodyManager;
const ShapeStore = bm_mod.ShapeStore;
const BodyId = api.BodyId;
const ContactManifold = narrowphase.ContactManifold(Real);

// --- Material combine rules (Box2D/Jolt convention) --------------------------

/// Combined friction for a contact pair: the geometric mean √(a·b). Both inputs
/// are non-negative (the `addBody` domain guard), so the product is ≥ 0.
pub fn combineFriction(a: Real, b: Real) Real {
    return @sqrt(a * b);
}

/// Combined restitution for a contact pair: the maximum. A single bouncy surface
/// makes the contact bouncy.
pub fn combineRestitution(a: Real, b: Real) Real {
    return @max(a, b);
}

// --- Tangent basis -----------------------------------------------------------

/// An orthonormal tangent basis spanning the plane ⊥ a contact normal.
pub const TangentBasis = struct {
    t1: Vec3r,
    t2: Vec3r,
};

/// Orthonormal, right-handed tangent basis `(t1, t2)` for the unit world normal
/// `n` (so `t1 × t2 == n`). Trig-free and deterministic: branch on the dominant
/// |component| of `n` (fixed tie-breaks x ≥ y ≥ z) to pick a seed world axis
/// guaranteed non-parallel to `n`, Gram-Schmidt it against `n` for `t1`, then
/// `t2 = n × t1`. Continuous while `n` moves continuously, but DISCONTINUOUS
/// across a dominant-axis flip — the warm-start tangent reprojection (E3)
/// compensates, so basis stability is never assumed.
pub fn tangentBasis(n: Vec3r) TangentBasis {
    const a = n.toArray();
    const ax = @abs(a[0]);
    const ay = @abs(a[1]);
    const az = @abs(a[2]);
    // Seed = the world axis cyclically after the dominant one, which is
    // guaranteed not parallel to `n`, so the Gram-Schmidt residual is nonzero.
    var seed: Vec3r = undefined;
    if (ax >= ay and ax >= az) {
        seed = Vec3r.unit_y; // x dominant
    } else if (ay >= az) {
        seed = Vec3r.unit_z; // y dominant
    } else {
        seed = Vec3r.unit_x; // z dominant
    }
    const t1 = seed.sub(n.scale(seed.dot(n))).normalize();
    const t2 = n.cross(t1).normalize();
    return .{ .t1 = t1, .t2 = t2 };
}

// --- Contact constraint ------------------------------------------------------

/// One contact point's precomputed solver data.
pub const ConstraintPoint = struct {
    /// Lever arm from body A's centre to the contact point (world).
    r_a: Vec3r,
    /// Lever arm from body B's centre to the contact point (world).
    r_b: Vec3r,
    /// Normal effective mass = 1 / kₙ (the impulse scale along the normal).
    normal_mass: Real,
    /// Tangent effective mass on axis 1 = 1 / k_t1.
    tangent1_mass: Real,
    /// Tangent effective mass on axis 2 = 1 / k_t2.
    tangent2_mass: Real,
    /// Pre-solve relative normal velocity `v_n⁻` captured in `prepare` (for the
    /// restitution bias in E4). Negative when the bodies are approaching.
    rel_normal_velocity: Real,
    /// Surface penetration along the normal (≥ 0). Carried but UNCONSUMED in
    /// M1.1.6 (no positional bias); the NGS position solver reads it at M1.1.7.
    penetration: Real,
    /// Per-contact feature id — the warm-start matching key (E3). Frame-stable
    /// via `BodyManager.collidePair`'s BodyId order.
    feature_id: u32,
    /// Accumulated normal impulse (warm-started in E3, clamped ≥ 0 in E4).
    normal_impulse: Real = 0,
    /// Accumulated tangent impulses on the `(t1, t2)` basis (E5).
    tangent1_impulse: Real = 0,
    tangent2_impulse: Real = 0,
};

/// One manifold's worth of contact constraints between a canonical body pair.
/// Points are stored inline (≤ 4); `count` marks the valid entries.
pub const ContactConstraint = struct {
    /// Canonical body A (the min BodyId of the pair).
    body_a: BodyId,
    /// Canonical body B (the max BodyId of the pair).
    body_b: BodyId,
    /// Packed canonical pair key `min(BodyId)<<32 | max` — the deterministic sort
    /// key (ascending iteration order; M1.1.14).
    pair_key: u64,
    /// World-space contact normal A→B, shared by all points.
    normal: Vec3r,
    /// Orthonormal tangent basis spanning the contact plane.
    tangent1: Vec3r,
    tangent2: Vec3r,
    /// Combined friction / restitution for the pair.
    friction: Real,
    restitution: Real,
    /// Cached inverse mass and world-space inverse inertia per body — precomputed
    /// once in `prepare`, reused by warm start (E3) and the iterations (E4/E5).
    inv_mass_a: Real,
    inv_mass_b: Real,
    inv_inertia_a: Mat3r,
    inv_inertia_b: Mat3r,
    /// Per-point solver data.
    points: [4]ConstraintPoint,
    /// Valid entries in `points`, 1..4.
    count: u8,
};

/// Effective mass along a unit direction `d` at a contact with lever arms `r_a`,
/// `r_b`: `1 / (invMassA + invMassB + (r_a×d)ᵀ Iₐ⁻¹ (r_a×d) + (r_b×d)ᵀ I_b⁻¹ (r_b×d))`.
/// The denominator is strictly positive for any constraint that survives the
/// true-zero skip (invMassA + invMassB > 0), so the inverse is finite.
fn effectiveMass(
    inv_mass_a: Real,
    inv_mass_b: Real,
    inv_inertia_a: Mat3r,
    inv_inertia_b: Mat3r,
    r_a: Vec3r,
    r_b: Vec3r,
    d: Vec3r,
) Real {
    const rda = r_a.cross(d);
    const rdb = r_b.cross(d);
    const k = inv_mass_a + inv_mass_b +
        rda.dot(inv_inertia_a.mulVec(rda)) +
        rdb.dot(inv_inertia_b.mulVec(rdb));
    return 1.0 / k;
}

/// Build and precompute one contact constraint for the canonical pair `(a, b)`
/// from `manifold`: tangent basis, combined material, cached inverse mass/inertia,
/// and per-point lever arms, effective masses, and pre-solve normal velocity.
fn prepare(bm: *const BodyManager, a: BodyId, b: BodyId, pair_key: u64, manifold: ContactManifold) ?ContactConstraint {
    const mp_a = bm.motionProperties(a).?;
    const mp_b = bm.motionProperties(b).?;

    // True-zero skip: both bodies have infinite mass (static/kinematic ⇒ inv_mass
    // and inv_inertia both zero), so the total inverse mass along the normal is
    // exactly zero and there is nothing to solve. A true-zero guard, not a
    // geometric epsilon (M1.1.4 threshold discipline).
    if (mp_a.inv_mass + mp_b.inv_mass == 0) return null;

    const pos_a = bm.position(a).?;
    const pos_b = bm.position(b).?;
    const rot_a = bm.rotation(a).?;
    const rot_b = bm.rotation(b).?;
    const vel_a = bm.linearVelocity(a).?;
    const vel_b = bm.linearVelocity(b).?;
    const ang_a = bm.angularVelocity(a).?;
    const ang_b = bm.angularVelocity(b).?;

    // World-space inverse inertia I_world_inv = R · I_local_inv · Rᵀ per body.
    const ra_mat = Mat3r.fromQuat(rot_a);
    const inv_inertia_a = ra_mat.mul(mp_a.local_inv_inertia).mul(ra_mat.transpose());
    const rb_mat = Mat3r.fromQuat(rot_b);
    const inv_inertia_b = rb_mat.mul(mp_b.local_inv_inertia).mul(rb_mat.transpose());

    const normal = manifold.normal;
    const tb = tangentBasis(normal);

    var c = ContactConstraint{
        .body_a = a,
        .body_b = b,
        .pair_key = pair_key,
        .normal = normal,
        .tangent1 = tb.t1,
        .tangent2 = tb.t2,
        .friction = combineFriction(bm.friction(a).?, bm.friction(b).?),
        .restitution = combineRestitution(bm.restitution(a).?, bm.restitution(b).?),
        .inv_mass_a = mp_a.inv_mass,
        .inv_mass_b = mp_b.inv_mass,
        .inv_inertia_a = inv_inertia_a,
        .inv_inertia_b = inv_inertia_b,
        .points = undefined,
        .count = manifold.count,
    };

    for (0..manifold.count) |i| {
        const p = manifold.points[i];
        const r_a = p.position.sub(pos_a);
        const r_b = p.position.sub(pos_b);

        // v_n⁻: n · (v_b + ω_b×r_b − v_a − ω_a×r_a) — the contact-point relative
        // velocity projected onto the normal, captured BEFORE warm start.
        const v_pa = vel_a.add(ang_a.cross(r_a));
        const v_pb = vel_b.add(ang_b.cross(r_b));

        c.points[i] = .{
            .r_a = r_a,
            .r_b = r_b,
            .normal_mass = effectiveMass(c.inv_mass_a, c.inv_mass_b, inv_inertia_a, inv_inertia_b, r_a, r_b, normal),
            .tangent1_mass = effectiveMass(c.inv_mass_a, c.inv_mass_b, inv_inertia_a, inv_inertia_b, r_a, r_b, tb.t1),
            .tangent2_mass = effectiveMass(c.inv_mass_a, c.inv_mass_b, inv_inertia_a, inv_inertia_b, r_a, r_b, tb.t2),
            .rel_normal_velocity = normal.dot(v_pb.sub(v_pa)),
            .penetration = p.penetration,
            .feature_id = p.feature_id,
        };
    }
    return c;
}

/// Build the contact constraints for `pairs` (canonical packed keys
/// `min(BodyId)<<32 | max`, the M1.1.1 `computePairs` contract: sorted, deduped)
/// into `out`. `out` is cleared first. For each pair the narrowphase runs via
/// `bm.collidePair` (canonical BodyId order → frame-stable feature ids); a
/// non-null manifold becomes one `ContactConstraint` with per-point data
/// precomputed by `prepare`.
pub fn build(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ContactConstraint),
    bm: *const BodyManager,
    store: *const ShapeStore,
    pairs: []const u64,
) !void {
    out.clearRetainingCapacity();
    for (pairs) |key| {
        const a: BodyId = @intCast(key >> 32);
        const b: BodyId = @intCast(key & 0xFFFF_FFFF);
        // Pairs arrive canonical; the solver asserts the order, never re-derives it.
        std.debug.assert(a <= b);
        const manifold = bm.collidePair(store, a, b) orelse continue; // separated
        const constraint = prepare(bm, a, b, key, manifold) orelse continue;
        try out.append(gpa, constraint);
    }
    // Deterministic iteration order: sort ascending by the packed pair key (a
    // total order; the pairs are deduped so keys are unique). No hash containers
    // anywhere on the path (M1.1.14).
    std.mem.sort(ContactConstraint, out.items, {}, lessByPairKey);
}

fn lessByPairKey(_: void, x: ContactConstraint, y: ContactConstraint) bool {
    return x.pair_key < y.pair_key;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn descOf(entity_index: u32, body_type: api.BodyType, shape: api.ShapeId) api.BodyDescriptor {
    return .{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = body_type,
        .shape = shape,
    };
}

fn pairKey(a: BodyId, b: BodyId) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

test "combine rules: friction is the geometric mean, restitution is the max" {
    try testing.expectApproxEqAbs(@as(Real, 0.5), combineFriction(0.25, 1.0), 1e-6); // √0.25
    try testing.expectEqual(@as(Real, 0), combineFriction(0, 0.9));
    try testing.expectEqual(@as(Real, 0.8), combineRestitution(0.2, 0.8));
    try testing.expectEqual(@as(Real, 0.8), combineRestitution(0.8, 0.2)); // symmetric
}

test "tangent basis is orthonormal, right-handed, and deterministic" {
    const normals = [_]Vec3r{
        vr(1, 0, 0),             vr(0, 1, 0),                vr(0, 0, 1),
        vr(-1, 0, 0),            vr(0, -1, 0),               vr(0, 0, -1),
        vr(1, 1, 1).normalize(), vr(1, -2, 0.5).normalize(), vr(-3, 0.2, 1).normalize(),
    };
    for (normals) |n| {
        const tb = tangentBasis(n);
        try testing.expectApproxEqAbs(@as(Real, 1), tb.t1.length(), 1e-6);
        try testing.expectApproxEqAbs(@as(Real, 1), tb.t2.length(), 1e-6);
        try testing.expectApproxEqAbs(@as(Real, 0), tb.t1.dot(n), 1e-6);
        try testing.expectApproxEqAbs(@as(Real, 0), tb.t2.dot(n), 1e-6);
        try testing.expectApproxEqAbs(@as(Real, 0), tb.t1.dot(tb.t2), 1e-6);
        try testing.expect(tb.t1.cross(tb.t2).approxEql(n, 1e-6)); // right-handed
        const tb2 = tangentBasis(n);
        try testing.expect(tb.t1.approxEql(tb2.t1, 0)); // deterministic
        try testing.expect(tb.t2.approxEql(tb2.t2, 0));
    }
}

test "prepare captures normal effective mass and pre-solve normal velocity" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Two unit-mass spheres overlapping along +X (centres 0.9 apart, radii sum
    // 1.0). For spheres the lever arm r = radius·n ∥ n, so r×n = 0 ⇒ no rotational
    // term ⇒ normal_mass = 1/(invMassA + invMassB) = 1/2 exactly.
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    var db = descOf(1, .dynamic, s);
    db.mass = 1;
    db.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    const id_a = try bm.addBody(gpa, &store, da);
    const id_b = try bm.addBody(gpa, &store, db);
    bm.setLinearVelocity(id_a, vr(1, 0, 0));
    bm.setLinearVelocity(id_b, vr(-1, 0, 0));

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});

    try testing.expectEqual(@as(usize, 1), constraints.items.len);
    const c = constraints.items[0];
    try testing.expectEqual(@as(u8, 1), c.count);
    try testing.expect(c.normal.approxEql(vr(1, 0, 0), 1e-5)); // A→B is +X
    try testing.expectApproxEqAbs(@as(Real, 0.5), c.points[0].normal_mass, 1e-5);
    // v_n⁻ = n·(v_b − v_a) = (1,0,0)·(−2,0,0) = −2 (approaching).
    try testing.expectApproxEqAbs(@as(Real, -2), c.points[0].rel_normal_velocity, 1e-5);
}

test "kinematic vs static pair yields no constraint (true-zero inverse mass skip)" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    const id_a = try bm.addBody(gpa, &store, descOf(0, .static, s));
    var db = descOf(1, .kinematic, s);
    db.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    const id_b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});

    // Both inv_mass == 0 ⇒ total inverse mass exactly zero ⇒ skipped at build.
    try testing.expectEqual(@as(usize, 0), constraints.items.len);
}

test "separated pair yields no constraint" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    const id_a = try bm.addBody(gpa, &store, descOf(0, .dynamic, s));
    var db = descOf(1, .dynamic, s);
    db.position = foundation.math.Vec3.fromArray(.{ 5, 0, 0 }); // far apart
    const id_b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});

    try testing.expectEqual(@as(usize, 0), constraints.items.len);
}

test "constraints come back sorted ascending by pair key" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Three dynamic spheres, all pairwise distances < 1.0 ⇒ all three pairs
    // overlap and produce a constraint.
    const d0 = descOf(0, .dynamic, s);
    var d1 = descOf(1, .dynamic, s);
    d1.position = foundation.math.Vec3.fromArray(.{ 0.8, 0, 0 });
    var d2 = descOf(2, .dynamic, s);
    d2.position = foundation.math.Vec3.fromArray(.{ 0.4, 0.6, 0 });
    const b0 = try bm.addBody(gpa, &store, d0);
    const b1 = try bm.addBody(gpa, &store, d1);
    const b2 = try bm.addBody(gpa, &store, d2);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    // Feed the keys OUT of ascending order — build must sort them.
    try build(gpa, &constraints, &bm, &store, &.{
        pairKey(b1, b2), pairKey(b0, b1), pairKey(b0, b2),
    });

    try testing.expectEqual(@as(usize, 3), constraints.items.len);
    try testing.expect(constraints.items[0].pair_key < constraints.items[1].pair_key);
    try testing.expect(constraints.items[1].pair_key < constraints.items[2].pair_key);
}
