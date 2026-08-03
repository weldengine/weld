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
//!     normal + two tangent effective masses, pre-solve normal velocity `v_n⁻`,
//!     and — for the NGS position pass — the two body-local surface anchors plus
//!     the pose-invariant local inverse inertias).
//!
//! Import discipline (brief): `foundation`, `weld_forge` (handle types),
//! `../config.zig`, `../body_manager.zig`, `../pipeline/narrowphase/root.zig`, and
//! since M1.1.8 `../pipeline/sleep.zig` — `build` is where the wake fixpoint lives,
//! so it needs the awake predicate; `rigid/island_manager.zig` already depends on
//! the same file. NEVER `broadphase.zig`: candidate pairs are consumed as data
//! (packed `u64` keys), never re-derived.
//!
//! The velocity solver carries NO positional bias (no Baumgarte, no split
//! impulse) — position error is entirely the NGS position pass's business
//! (`engine-physics-forge.md` §1.7). `ContactPoint.penetration` is consumed HERE
//! and only here, at `prepare`, to derive the two surface anchors; the position
//! iterations then re-derive the separation from the current poses instead of
//! re-reading the frozen manifold (§1.7.2).

const std = @import("std");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const sleep = @import("../pipeline/sleep.zig");
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

/// Combined friction for a contact pair: the geometric mean √(a·b), computed as
/// √a·√b. Both inputs are non-negative (the `addBody` domain guard). The √-first
/// form is the identical geometric mean but stays finite across the whole finite
/// domain — it avoids the intermediate `a*b` overflow (→ inf, then `inf·0 = NaN`
/// in the friction clamp when λₙ = 0) and underflow of a naive `√(a·b)`.
pub fn combineFriction(a: Real, b: Real) Real {
    return @sqrt(a) * @sqrt(b);
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
    /// Surface penetration along the normal (≥ 0). Consumed ONCE, here at
    /// `prepare`, to derive the two surface anchors below; it is never re-read from
    /// the frozen manifold during the position iterations — the NGS pass re-derives
    /// the separation from the CURRENT poses, which is what makes it non-linear
    /// (`engine-physics-forge.md` §1.7.2). The velocity pass carries no positional
    /// bias and never reads it.
    penetration: Real,
    /// Contact anchor in body A's LOCAL frame: A's surface point at prepare time,
    /// `conj(q_a)·(surface_a − x_a)` — rigidly attached, so the NGS position pass
    /// re-derives its world position from A's current pose.
    local_anchor_a: Vec3r,
    /// Contact anchor in body B's LOCAL frame (mirror of `local_anchor_a`, on B's
    /// surface). The two anchors are `penetration` apart along the normal at
    /// prepare time; their world separation is what the position pass drives to
    /// `−penetration_slop`.
    local_anchor_b: Vec3r,
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
    /// The SUB-SHAPE this constraint came from — a mesh's triangle index, and `0` when
    /// neither body carries sub-shapes (§1.11.16).
    ///
    /// **The second term of the warm-start cache key, which held `0` from M1.1.6 until
    /// M1.1.11.1.** A mesh pair produces one constraint per contacting triangle, so without it
    /// every triangle of one body would warm-start from whichever neighbour happened to share a
    /// `feature_id` — and `feature_id` is a LOCAL identity, unique within a manifold and not
    /// across them. Filling it makes the reheating per triangle and makes it survive a
    /// re-traversal that offers the candidates in a different order.
    ///
    /// ONE term suffices while at most one side of a pair carries sub-shapes, which is exactly
    /// the case today: mesh↔mesh is an asserted precondition. Compounds (M1.1.20) put sub-shapes
    /// on both sides and are the milestone that owes the key its second axis; the frozen spec
    /// key has one.
    subshape_id: u32 = 0,
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
    /// Pose-invariant LOCAL inverse inertia per body, copied from
    /// `MotionProperties`. The NGS position pass rebuilds the world tensor
    /// `R_current · I_local⁻¹ · R_currentᵀ` from the CURRENT rotation on every
    /// point/iteration (it moves the poses it reads), so it never calls
    /// `motionProperties` in its inner loop.
    local_inv_inertia_a: Mat3r,
    local_inv_inertia_b: Mat3r,
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
fn prepare(bm: *const BodyManager, a: BodyId, b: BodyId, pair_key: u64, subshape_id: u32, manifold: ContactManifold) ?ContactConstraint {
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
        .subshape_id = subshape_id,
        .normal = normal,
        .tangent1 = tb.t1,
        .tangent2 = tb.t2,
        .friction = combineFriction(bm.friction(a).?, bm.friction(b).?),
        .restitution = combineRestitution(bm.restitution(a).?, bm.restitution(b).?),
        .inv_mass_a = mp_a.inv_mass,
        .inv_mass_b = mp_b.inv_mass,
        .inv_inertia_a = inv_inertia_a,
        .inv_inertia_b = inv_inertia_b,
        .local_inv_inertia_a = mp_a.local_inv_inertia,
        .local_inv_inertia_b = mp_b.local_inv_inertia,
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

        // Surface anchors for the NGS position pass. The manifold point IS the
        // midpoint of the two surface points (`pipeline/narrowphase/manifold.zig`
        // `ContactPoint`), so they reconstruct exactly from the penetration:
        // A's surface sits half a penetration toward B, B's half a penetration
        // back. Each is stored in its OWN body's local frame below ⇒ rigidly
        // attached (`engine-physics-forge.md` §1.7.2).
        const half_penetration = p.penetration * 0.5;
        const surface_a = p.position.add(normal.scale(half_penetration));
        const surface_b = p.position.sub(normal.scale(half_penetration));

        c.points[i] = .{
            .r_a = r_a,
            .r_b = r_b,
            .normal_mass = effectiveMass(c.inv_mass_a, c.inv_mass_b, inv_inertia_a, inv_inertia_b, r_a, r_b, normal),
            .tangent1_mass = effectiveMass(c.inv_mass_a, c.inv_mass_b, inv_inertia_a, inv_inertia_b, r_a, r_b, tb.t1),
            .tangent2_mass = effectiveMass(c.inv_mass_a, c.inv_mass_b, inv_inertia_a, inv_inertia_b, r_a, r_b, tb.t2),
            .rel_normal_velocity = normal.dot(v_pb.sub(v_pa)),
            .penetration = p.penetration,
            .local_anchor_a = rot_a.conjugate().rotateVec3(surface_a.sub(pos_a)),
            .local_anchor_b = rot_b.conjugate().rotateVec3(surface_b.sub(pos_b)),
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
///
/// **This is also the wake fixpoint** (`engine-physics-forge.md` §1.8.5), which is
/// why `bm` is mutable here. A sleeping island's internal contacts are not built,
/// so on the tick a projectile lands on top of a sleeping stack only the
/// projectile↔top pair produces a manifold; waking those two alone would leave the
/// top of the stack awake with no support under it and propagate the wake one layer
/// per tick. Instead:
///
///   1. a pair with NEITHER endpoint awake is skipped — zero narrowphase, zero
///      `prepare` — and recorded in a deferred list;
///   2. a pair that produces a manifold WAKES any sleeping endpoint, whatever the
///      other endpoint is: dynamic, static, or a moving kinematic platform;
///   3. the deferred list is re-scanned while a pass wakes at least one body.
///
/// Termination is bounded by the number of sleeping bodies, since each round that
/// continues has strictly reduced it. The narrowphase work is exactly that of the
/// contacts which end up in the array — nothing is spent twice. Determinism is
/// preserved — the scan follows the sorted pair order and the output is re-sorted by
/// pair key.
///
/// At rest nothing wakes, so the fixpoint loop does not run at all — the
/// deferred list is built and never re-scanned. What a resting tick still
/// costs is one awake test per candidate pair and one `u32` appended per
/// deferred pair, including that list's allocation; what the skip removes is
/// the narrowphase and the `prepare` of every one of those pairs, which is
/// the whole of the saving. Should that per-tick buffer ever matter, it moves
/// to the orchestrator's scratch when `step()` lands (M1.1.15) — it is not
/// reusable from here, `build` owning no state.
pub fn build(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ContactConstraint),
    bm: *BodyManager,
    store: *const ShapeStore,
    pairs: []const u64,
) !void {
    out.clearRetainingCapacity();

    // Indices into `pairs`, not keys: the list only ever holds skipped pairs, so it
    // stays empty — and unallocated — in a fully awake scene.
    var deferred: std.ArrayListUnmanaged(u32) = .empty;
    defer deferred.deinit(gpa);

    // The first pass CARRIES its wake signal into the loop condition rather than
    // discarding it: `bothAsleep` can only change through a wake, so if this pass
    // woke nobody, no deferred pair has become processable and the loop below must
    // not run at all.
    var woke_someone = false;
    for (pairs, 0..) |key, index| {
        if (bothAsleep(bm, key)) {
            try deferred.append(gpa, @intCast(index));
            continue;
        }
        if (try emitPair(gpa, out, bm, store, key)) woke_someone = true;
    }

    while (woke_someone and deferred.items.len > 0) {
        woke_someone = false;
        var kept: usize = 0;
        for (deferred.items) |index| {
            const key = pairs[index];
            if (bothAsleep(bm, key)) {
                deferred.items[kept] = index;
                kept += 1;
                continue;
            }
            if (try emitPair(gpa, out, bm, store, key)) woke_someone = true;
        }
        deferred.shrinkRetainingCapacity(kept);
    }

    // Deterministic iteration order: sort ascending by the packed pair key (a
    // total order; the pairs are deduped so keys are unique). No hash containers
    // anywhere on the path (M1.1.14).
    std.mem.sort(ContactConstraint, out.items, {}, lessByPairKey);
}

/// Whether neither endpoint of `key` is a motion source — the pair the fixpoint
/// defers.
fn bothAsleep(bm: *const BodyManager, key: u64) bool {
    const a: BodyId = @intCast(key >> 32);
    const b: BodyId = @intCast(key & 0xFFFF_FFFF);
    return !sleep.isAwake(bm, a) and !sleep.isAwake(bm, b);
}

/// Narrowphase one candidate pair; on a manifold, wake any sleeping endpoint and
/// append the prepared constraint. Returns whether a body was woken — which is the
/// fixpoint's progress signal, since only a wake can make another deferred pair
/// processable.
fn emitPair(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ContactConstraint),
    bm: *BodyManager,
    store: *const ShapeStore,
    key: u64,
) !bool {
    const a: BodyId = @intCast(key >> 32);
    const b: BodyId = @intCast(key & 0xFFFF_FFFF);
    // Pairs arrive canonical; the solver asserts the order, never re-derives it.
    std.debug.assert(a <= b);

    // SEVERAL constraints per pair since M1.1.11.1: a mesh↔convex pair produces one manifold
    // per contacting triangle, and that is the only shape change the mesh imposes on this
    // solver (§1.11.17). A pair with no sub-shapes still produces at most one, so the
    // convex↔convex path is unchanged in everything but the shape of the call.
    var collector = ConstraintCollector{
        .gpa = gpa,
        .out = out,
        .bm = bm,
        .a = a,
        .b = b,
        .key = key,
    };
    bm.collidePairEach(store, a, b, &collector);
    if (collector.err) |e| return e;

    // Wake if ANY manifold appeared. The wake now follows `prepare` instead of preceding it,
    // and the two are PROVABLY equivalent rather than merely believed to be: `prepare` reads
    // `motionProperties`, `position`, `rotation`, the two velocities, `friction` and
    // `restitution`, while `wakeBody` writes `flags.sleeping`, `sleep_time` and the two
    // `sleep_ref_*` columns. The two field sets are DISJOINT, so no constraint's contents can
    // depend on the order. Reordering was forced by the collector: waking from inside it would
    // mean holding a mutable `BodyManager` while `collidePairEach` walks it through a `*const`.
    var woke = false;
    if (collector.emitted > 0) {
        for ([_]BodyId{ a, b }) |id| {
            if (bm.isSleeping(id) orelse false) {
                bm.wakeBody(id);
                woke = true;
            }
        }
    }
    return woke;
}

/// Prepares and appends one `ContactConstraint` per manifold `collidePairEach` offers, latching
/// an allocation failure rather than propagating it — the collector contract being infallible.
const ConstraintCollector = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ContactConstraint),
    bm: *const BodyManager,
    a: BodyId,
    b: BodyId,
    key: u64,
    /// How many manifolds arrived, whether or not each produced a constraint — the wake signal
    /// is "the pair touches", not "the pair produced solver work": a pair of infinite masses
    /// touches and `prepare` skips it at true zero.
    emitted: u32 = 0,
    err: ?std.mem.Allocator.Error = null,

    pub fn add(self: *ConstraintCollector, subshape_id: u32, manifold: ContactManifold) void {
        self.emitted += 1;
        if (self.err != null) return;
        const constraint = prepare(self.bm, self.a, self.b, self.key, subshape_id, manifold) orelse return;
        self.out.append(self.gpa, constraint) catch |e| {
            self.err = e;
        };
    }
};

/// Total order over constraints — `(pair_key, subshape_id)`, and the second term is load-bearing
/// (M1.1.11.1 closure, finding F4).
///
/// `std.mem.sort` is `std.sort.block`, which is UNSTABLE. While a pair produced at most one
/// constraint, `pair_key` alone was a total order and the instability could not be observed. A mesh
/// pair produces one per contacting triangle, and on `pair_key` alone their relative order becomes
/// neither the traversal's nor a contract of any kind: it is the sort algorithm's internal
/// behaviour. Sequential Impulses is ORDER-SENSITIVE — it is a Gauss-Seidel sweep — so that is the
/// determinism path, not a cosmetic one.
///
/// M1.1.8 stated the invariant this restores, in these words: the constraints are ordered by an
/// explicit composite key "so contiguity never rests on sort stability". Several constraints per
/// pair had quietly annulled it, in the island ordering as well as here.
///
/// TOTAL because two constraints of one pair cannot share a `subshape_id`: the sub-shape is the
/// triangle index, and `collidePairEach` offers each triangle at most once.
pub fn lessByPairKey(_: void, x: ContactConstraint, y: ContactConstraint) bool {
    if (x.pair_key != y.pair_key) return x.pair_key < y.pair_key;
    return x.subshape_id < y.subshape_id;
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

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

/// Float-noise tolerance for a unit-scale world-anchor reconstruction. The anchor
/// round-trip runs the narrowphase, one conjugate quaternion rotation per body and
/// one subtraction of same-magnitude world coordinates, so the residue is a few
/// ULPs of an O(1) coordinate (the re-posed scene adds the f32 rounding of its
/// descriptor positions). Not a geometric threshold — nothing is classified by it.
const anchor_tol: Real = 1e-5;

/// Two overlapping unit-mass spheres (radius 0.5, centres 0.9 apart along the
/// scene's local +X ⇒ 0.1 of penetration), re-posed by the rigid transform
/// (`rot`, `translation`) applied to BOTH bodies. Returns the single prepared
/// constraint.
fn twoSpheresPosed(
    gpa: std.mem.Allocator,
    store: *ShapeStore,
    bm: *BodyManager,
    constraints: *std.ArrayListUnmanaged(ContactConstraint),
    rot: foundation.math.Quatf,
    translation: foundation.math.Vec3,
) !ContactConstraint {
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    da.rotation = rot;
    da.position = rot.rotateVec3(av3(0, 0, 0)).add(translation);
    var db = descOf(1, .dynamic, s);
    db.mass = 1;
    db.rotation = rot;
    db.position = rot.rotateVec3(av3(0.9, 0, 0)).add(translation);
    const id_a = try bm.addBody(gpa, store, da);
    const id_b = try bm.addBody(gpa, store, db);

    try build(gpa, constraints, bm, store, &.{pairKey(id_a, id_b)});
    try testing.expectEqual(@as(usize, 1), constraints.items.len);
    return constraints.items[0];
}

test "prepare stores body-local surface anchors that reproduce the penetration" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);

    const c = try twoSpheresPosed(gpa, &store, &bm, &constraints, .identity, av3(0, 0, 0));
    const pt = c.points[0];
    try testing.expect(pt.penetration > 0.05); // ≈ 0.1 — well above the float noise

    // Reconstruct both world anchors at the prepare-time pose (`x + q·local`): the
    // two surface points must be `penetration` apart along the normal, B's behind
    // A's — `(p_b − p_a)·n == −penetration`. A single midpoint anchor stored twice
    // would give 0 here.
    const p_a = bm.position(c.body_a).?.add(bm.rotation(c.body_a).?.rotateVec3(pt.local_anchor_a));
    const p_b = bm.position(c.body_b).?.add(bm.rotation(c.body_b).?.rotateVec3(pt.local_anchor_b));
    try testing.expectApproxEqAbs(-pt.penetration, p_b.sub(p_a).dot(c.normal), anchor_tol);

    // Pose-invariance: the SAME physical contact, with both bodies re-posed by one
    // rigid transform (scene rotated 0.7 rad about Z, then translated), stores the
    // same BODY-LOCAL anchors — that is what makes them rigidly attached.
    var store2 = ShapeStore{};
    defer store2.deinit(gpa);
    var bm2 = BodyManager{};
    defer bm2.deinit(gpa);
    var constraints2: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints2.deinit(gpa);
    const rot = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), 0.7);
    const c2 = try twoSpheresPosed(gpa, &store2, &bm2, &constraints2, rot, av3(3, -2, 1));

    try testing.expect(c2.points[0].local_anchor_a.approxEql(pt.local_anchor_a, anchor_tol));
    try testing.expect(c2.points[0].local_anchor_b.approxEql(pt.local_anchor_b, anchor_tol));
}

test "prepare caches the pose-invariant local inverse inertias" {
    const gpa = testing.allocator;
    // One dynamic body against an infinite-mass one: the pair survives the
    // true-zero skip, and the infinite-mass side must carry a zero local inverse
    // inertia (both static and kinematic).
    inline for (.{ api.BodyType.static, api.BodyType.kinematic }) |bt| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
        var da = descOf(0, .dynamic, s);
        da.mass = 2;
        var db = descOf(1, bt, s);
        db.position = av3(0.9, 0, 0);
        const id_a = try bm.addBody(gpa, &store, da);
        const id_b = try bm.addBody(gpa, &store, db);

        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        try build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});
        try testing.expectEqual(@as(usize, 1), constraints.items.len);
        const c = constraints.items[0];

        // An exact copy of `MotionProperties.local_inv_inertia` (pose-invariant, so
        // the position pass rebuilds the world tensor from the current rotation
        // without touching `motionProperties`).
        const local_a = bm.motionProperties(id_a).?.local_inv_inertia;
        inline for (0..3) |k| {
            try testing.expect(c.local_inv_inertia_a.cols[k].approxEql(local_a.cols[k], 0));
            try testing.expect(c.local_inv_inertia_b.cols[k].approxEql(Vec3r.zero, 0));
        }
        try testing.expect(local_a.cols[0].toArray()[0] > 0); // the dynamic side is non-zero
    }
}

test "combine rules: friction is the geometric mean, restitution is the max" {
    try testing.expectApproxEqAbs(@as(Real, 0.5), combineFriction(0.25, 1.0), 1e-6); // √0.25
    try testing.expectEqual(@as(Real, 0), combineFriction(0, 0.9));
    try testing.expectEqual(@as(Real, 0.8), combineRestitution(0.2, 0.8));
    try testing.expectEqual(@as(Real, 0.8), combineRestitution(0.8, 0.2)); // symmetric
}

test "combineFriction stays finite and positive across the domain" {
    // The sqrt-first form avoids the intermediate a*b overflow/underflow of a
    // naive √(a·b): at f32, a*b = 1e40 overflows (→ inf) and 1e-60 underflows (→ 0).
    const big = combineFriction(1e20, 1e20);
    try testing.expect(std.math.isFinite(big) and big > 0);
    try testing.expect(combineFriction(1e-30, 1e-30) > 0);
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
