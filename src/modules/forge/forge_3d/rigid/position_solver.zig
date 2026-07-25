//! `forge_3d/rigid/position_solver.zig` — the NGS (Non-linear Gauss-Seidel)
//! position pass of the rigid contact solver (`engine-physics-forge.md` §1.7.2;
//! Jolt `ContactConstraintManager::sSolvePositionConstraint` /
//! `AxisConstraintPart::SolvePositionConstraint` lineage, cross-checked against
//! Box2D's position solver).
//!
//! Role: resorb the residual penetration by correcting the POSES — position AND
//! orientation — without ever touching a velocity. The pseudo-impulses are
//! integrated straight into the pose and the velocity change is DISCARDED (Catto,
//! GDC 2007: the Baumgarte term is split out of the velocity solver precisely so
//! it adds no momentum). The velocity pass therefore keeps carrying no positional
//! bias of any kind, and no accumulated impulse is modified here — the next tick
//! revalidates the features through the manifold as usual.
//!
//! Placement in the normative per-tick cycle (§1.7): after `integratePositions`,
//! before `storeContacts` and before the broadphase proxy updates.
//!
//! Non-linear means the separation is RE-DERIVED from the current poses at every
//! point of every iteration, never re-read from the frozen manifold: `prepare`
//! consumed `penetration` once to store two rigidly-attached body-local surface
//! anchors, and this pass reconstructs their world positions from whatever pose the
//! bodies now have. The world inverse inertia is likewise rebuilt from the CURRENT
//! rotation — the pass moves the bodies it reads, so freezing the tensor would be
//! an unjustified approximation.
//!
//! The contact normal, by contrast, stays FIXED in world for the whole pass and is
//! attached to no body. Normative reason (§1.7.2): the frozen `ContactManifold`
//! does not carry the reference-face owner at all, and that owner is not
//! necessarily A — `pipeline/narrowphase/manifold.zig` picks it by alignment with
//! the contact axis, and a LYING CAPSULE against a box gives the box the reference
//! face (`tests/position_solver_test.zig` witnesses it). Following one body's
//! rotation would require extending the frozen manifold. (Box2D may attach its
//! normal to the reference face only because it records which one that is.)
//!
//! Import discipline (brief): `foundation`, `weld_forge`, `../config.zig`,
//! `../body_manager.zig`, sibling `contact_constraint.zig`/`solver_config.zig`.
//! NEVER `broadphase.zig`, never any `pipeline/` file — including
//! `pipeline/integration.zig`, whose orientation step is deliberately NOT factored
//! into a shared helper (see `rotateByDelta`).

const std = @import("std");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const cc = @import("contact_constraint.zig");
const solver_config = @import("solver_config.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const BodyManager = bm_mod.BodyManager;
const ContactConstraint = cc.ContactConstraint;
const ConstraintPoint = cc.ConstraintPoint;
const SolverConfig = solver_config.SolverConfig;

/// What one `solvePositionRange` pass observed.
///
/// TELEMETRY ONLY — never a control input: the pass's own decisions read the poses
/// and the config, nothing else. Feeds `get_solver_iterations_stats`
/// (`PhysicsDebugProvider`, `engine-physics-forge.md` §1.9); no other consumer is
/// claimed at M1.1.7.
pub const PositionSolveResult = struct {
    /// Position iterations actually run, `<= cfg.position_iterations`. The pass
    /// stops on the first iteration that applies no correction at all.
    iterations_run: u32 = 0,
    /// Smallest separation observed over the pass: the raw geometric
    /// `(p_b − p_a)·n` (negative = overlap), BEFORE the slop and before the error
    /// clamp, so it reads as the worst residual penetration seen. `null` when no
    /// point was evaluated (an empty range, or `position_iterations == 0`).
    min_separation: ?Real = null,
};

/// Resorb penetration over the constraint index range `[from, to)` with at most
/// `cfg.position_iterations` NGS passes, correcting poses through
/// `BodyManager.setPosition`/`setRotation`. Velocities and accumulated impulses are
/// left bit-unchanged.
///
/// Constraints are visited in ascending pair-key order (as `build` sorted them) and
/// points in manifold order — the same order as the velocity pass, so determinism
/// is by construction (M1.1.14). `constraints` is taken as a mutable slice to
/// mirror `velocity_solver.solveRange`'s island seam signature; this pass only
/// reads it.
///
/// The range shape IS the island seam (M1.1.8 sorts constraints into contiguous
/// per-island ranges — purely additive). Termination is evaluated ON THE RANGE,
/// never globally: each island converges independently, which is the correct
/// semantics (Jolt iterates position steps per island) and what a global
/// termination would break.
pub fn solvePositionRange(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    from: usize,
    to: usize,
    cfg: SolverConfig,
) PositionSolveResult {
    solver_config.assertPositionDomain(cfg);

    var result: PositionSolveResult = .{};
    // `position_iterations == 0` is legal: no position correction whatsoever, i.e.
    // the velocity-only behaviour (the M1.1.6 contract) reproduced exactly.
    if (cfg.position_iterations == 0) return result;

    var iter: u32 = 0;
    while (iter < cfg.position_iterations) : (iter += 1) {
        result.iterations_run = iter + 1;
        var applied_any = false;
        for (constraints[from..to]) |*c| {
            for (0..c.count) |i| {
                if (solvePoint(bm, c, &c.points[i], cfg, &result)) applied_any = true;
            }
        }
        // Jolt semantics: an iteration that applied no correction ends the pass.
        // No convergence-threshold constant of any kind.
        if (!applied_any) break;
    }
    return result;
}

/// One NGS point correction, applied immediately to both poses (Gauss-Seidel — the
/// next point already sees the moved bodies). Returns whether a pose was actually
/// written.
fn solvePoint(
    bm: *BodyManager,
    c: *const ContactConstraint,
    pt: *const ConstraintPoint,
    cfg: SolverConfig,
    result: *PositionSolveResult,
) bool {
    const x_a = bm.position(c.body_a).?;
    const x_b = bm.position(c.body_b).?;
    const q_a = bm.rotation(c.body_a).?;
    const q_b = bm.rotation(c.body_b).?;

    // World anchors from the CURRENT poses, then the separation along the FIXED
    // world normal (negative = overlap).
    const p_a = x_a.add(q_a.rotateVec3(pt.local_anchor_a));
    const p_b = x_b.add(q_b.rotateVec3(pt.local_anchor_b));
    const separation = p_b.sub(p_a).dot(c.normal);
    if (result.min_separation == null or separation < result.min_separation.?) {
        result.min_separation = separation;
    }

    // The clamp is on the ERROR going in, not on the correction coming out: it
    // bounds how much penetration one pass takes into account (Jolt
    // `mMaxPenetrationDistance`). The `sep >= 0` gate replaces any upper clamp.
    const sep = @max(separation + cfg.penetration_slop, -cfg.max_penetration_correction);
    if (sep >= 0) return false;

    // Lever arms from the MIDPOINT of the two current anchors.
    const p = p_a.add(p_b).scale(0.5);
    const r_a = p.sub(x_a);
    const r_b = p.sub(x_b);

    // World inverse inertia at the CURRENT rotation, per body:
    // I⁻¹ = R · I_local⁻¹ · Rᵀ (Rᵀ == R⁻¹ for an orthonormal rotation).
    const rot_a = Mat3r.fromQuat(q_a);
    const inv_inertia_a = rot_a.mul(c.local_inv_inertia_a).mul(rot_a.transpose());
    const rot_b = Mat3r.fromQuat(q_b);
    const inv_inertia_b = rot_b.mul(c.local_inv_inertia_b).mul(rot_b.transpose());

    // Normal effective mass at the current geometry. The denominator is strictly
    // positive for any constraint that survived `prepare`'s true-zero skip
    // (`inv_mass_a + inv_mass_b > 0`), so the division is finite — no guard.
    const rna = r_a.cross(c.normal);
    const rnb = r_b.cross(c.normal);
    const k = c.inv_mass_a + c.inv_mass_b +
        rna.dot(inv_inertia_a.mulVec(rna)) +
        rnb.dot(inv_inertia_b.mulVec(rnb));
    const lambda = -cfg.position_correction_factor * sep / k;
    const impulse = c.normal.scale(lambda);

    // Static and kinematic bodies zero their own correction EXACTLY (`inv_mass == 0`
    // and a zero local inverse inertia), so no `body_type` branch exists. The pose
    // write is nevertheless guarded at exact zero, because `normalize` on an
    // already-unit quaternion is not bit-neutral: a non-dynamic body must come out
    // bit-unchanged. The same guard makes "applied" mean "a pose was written", so
    // the termination above cannot be fooled by a zero-magnitude correction.
    var applied = false;

    const dx_a = impulse.scale(-c.inv_mass_a);
    if (!dx_a.eql(Vec3r.zero)) {
        bm.setPosition(c.body_a, x_a.add(dx_a));
        applied = true;
    }
    const dtheta_a = inv_inertia_a.mulVec(r_a.cross(impulse)).neg();
    if (!dtheta_a.eql(Vec3r.zero)) {
        bm.setRotation(c.body_a, rotateByDelta(q_a, dtheta_a));
        applied = true;
    }

    const dx_b = impulse.scale(c.inv_mass_b);
    if (!dx_b.eql(Vec3r.zero)) {
        bm.setPosition(c.body_b, x_b.add(dx_b));
        applied = true;
    }
    const dtheta_b = inv_inertia_b.mulVec(r_b.cross(impulse));
    if (!dtheta_b.eql(Vec3r.zero)) {
        bm.setRotation(c.body_b, rotateByDelta(q_b, dtheta_b));
        applied = true;
    }

    return applied;
}

/// Apply the angular correction `dtheta` (world-space) to `q` by the first-order
/// linearized rule `q ← normalize(q + ½·(Δθ_quat ⊗ q))`, `Δθ` on the LEFT — the
/// same rule `pipeline/integration.zig`'s `integratePositions` uses for `ω·dt`.
/// It divides by no `|Δθ|`, so it is regular at zero and needs NO absolute guard
/// (M1.1.4 threshold discipline). `Δθ_quat ⊗ q` is orthogonal to `q` in 4D, so
/// `‖q + dq‖ >= 1` and `normalize` never approaches a zero divisor.
///
/// Deliberate divergence from Jolt's exact axis-angle `SubRotationStep`, which needs
/// an absolute `|Δθ| > 1e-6` guard because that routine is shared with kinematic
/// pose driving (large deltas) — a regime absent from a position solver, where the
/// angular delta is bounded by `max_penetration_correction` over the lever arm.
/// Deliberately NOT factored into a helper shared with the integrator: `rigid/`
/// must not import `pipeline/` outside the narrowphase facade, and the integrator
/// carries a flagged additive option (exact non-linearized orientation integration)
/// this pass would not follow.
fn rotateByDelta(q: Quatr, dtheta: Vec3r) Quatr {
    const d = dtheta.toArray();
    const dtheta_quat = Quatr{ .x = d[0], .y = d[1], .z = d[2], .w = 0 };
    return q.add(dtheta_quat.mul(q).scale(0.5)).normalize();
}

// --- tests -------------------------------------------------------------------

const api = @import("weld_forge");
const foundation = @import("foundation");
const ShapeStore = bm_mod.ShapeStore;
const BodyId = api.BodyId;
const testing = std.testing;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
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

/// Float-noise tolerance for a unit-scale world separation re-derived from two
/// anchors: a narrowphase result, two quaternion rotations and a difference of
/// same-magnitude coordinates, so a few ULPs of an O(1) coordinate. Not a geometric
/// threshold — nothing is classified by it.
const noise_tol: Real = 1e-5;

/// Re-derive the current separation of a constraint's point `i` exactly the way the
/// solver does: world anchors from the current poses, projected on the stored world
/// normal.
fn currentSeparation(bm: *const BodyManager, c: ContactConstraint, i: usize) Real {
    const pt = c.points[i];
    const p_a = bm.position(c.body_a).?.add(bm.rotation(c.body_a).?.rotateVec3(pt.local_anchor_a));
    const p_b = bm.position(c.body_b).?.add(bm.rotation(c.body_b).?.rotateVec3(pt.local_anchor_b));
    return p_b.sub(p_a).dot(c.normal);
}

/// Two unit-mass spheres (radius 0.5) whose centres are `gap` apart along +X, so
/// they penetrate by `1.0 − gap`. Returns their handles.
fn twoSpheres(gpa: std.mem.Allocator, store: *ShapeStore, bm: *BodyManager, gap: f32) ![2]BodyId {
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    var db = descOf(1, .dynamic, s);
    db.mass = 1;
    db.position = av3(gap, 0, 0);
    const id_a = try bm.addBody(gpa, store, da);
    const id_b = try bm.addBody(gpa, store, db);
    return .{ id_a, id_b };
}

test "position solve resorbs penetration down to the slop" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try twoSpheres(gpa, &store, &bm, 0.9); // 0.1 of penetration
    const cfg = SolverConfig{};

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
    try testing.expectEqual(@as(usize, 1), constraints.items.len);
    try testing.expect(currentSeparation(&bm, constraints.items[0], 0) < -0.05);

    // NGS is a geometric contraction toward `separation = −penetration_slop` from
    // below: each correction removes `position_correction_factor` of the remaining
    // deficit, so the limit is approached and never crossed. 10 calls × 3 iterations
    // leave a residue of ≈ 0.095 · 0.8³⁰ ≈ 0.1 mm — that residue is what
    // `convergence_residue` names; it is not a geometric threshold.
    const convergence_residue: Real = 1e-3;
    var pass: u32 = 0;
    while (pass < 10) : (pass += 1) {
        const result = solvePositionRange(&bm, constraints.items, 0, constraints.items.len, cfg);
        try testing.expect(result.min_separation != null);
    }

    const separation = currentSeparation(&bm, constraints.items[0], 0);
    try testing.expect(separation >= -cfg.penetration_slop - convergence_residue);
    try testing.expect(separation <= 0);
    // Symmetric unit masses ⇒ each sphere backed off half the correction.
    try testing.expect(bm.position(ids[0]).?.toArray()[0] < -0.04);
    try testing.expect(bm.position(ids[1]).?.toArray()[0] > 0.94);
}

test "position solve applies no correction beyond the slop" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    // 2 mm of penetration — strictly inside the 5 mm slop.
    const ids = try twoSpheres(gpa, &store, &bm, 0.998);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
    const before_a = bm.position(ids[0]).?.toArray();
    const before_b = bm.position(ids[1]).?.toArray();
    const before_qa = bm.rotation(ids[0]).?.toArray();
    const before_qb = bm.rotation(ids[1]).?.toArray();

    const result = solvePositionRange(&bm, constraints.items, 0, constraints.items.len, .{});

    // The first pass applies nothing, so the pass terminates right there.
    try testing.expectEqual(@as(u32, 1), result.iterations_run);
    try testing.expect(result.min_separation.? < 0); // it DID evaluate the point
    // Both poses bit-unchanged (no pose write at all ⇒ no `normalize` either).
    inline for (0..3) |k| {
        try testing.expectEqual(before_a[k], bm.position(ids[0]).?.toArray()[k]);
        try testing.expectEqual(before_b[k], bm.position(ids[1]).?.toArray()[k]);
    }
    inline for (0..4) |k| {
        try testing.expectEqual(before_qa[k], bm.rotation(ids[0]).?.toArray()[k]);
        try testing.expectEqual(before_qb[k], bm.rotation(ids[1]).?.toArray()[k]);
    }
}

test "position solve leaves every accumulated impulse bit-unchanged" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try twoSpheres(gpa, &store, &bm, 0.9);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

    // Seed the accumulated impulses as a solved velocity pass would have left them.
    for (0..constraints.items[0].count) |i| {
        const pt = &constraints.items[0].points[i];
        pt.normal_impulse = 7;
        pt.tangent1_impulse = -1.25;
        pt.tangent2_impulse = 0.5;
    }
    const v_a = bm.linearVelocity(ids[0]).?.toArray();
    const w_a = bm.angularVelocity(ids[0]).?.toArray();

    const result = solvePositionRange(&bm, constraints.items, 0, constraints.items.len, .{});
    try testing.expect(result.iterations_run > 0);

    // The position pass integrates pseudo-impulses into the POSE and discards the
    // velocity change: no accumulated impulse and no velocity may move.
    for (0..constraints.items[0].count) |i| {
        const pt = constraints.items[0].points[i];
        try testing.expectEqual(@as(Real, 7), pt.normal_impulse);
        try testing.expectEqual(@as(Real, -1.25), pt.tangent1_impulse);
        try testing.expectEqual(@as(Real, 0.5), pt.tangent2_impulse);
    }
    inline for (0..3) |k| {
        try testing.expectEqual(v_a[k], bm.linearVelocity(ids[0]).?.toArray()[k]);
        try testing.expectEqual(w_a[k], bm.angularVelocity(ids[0]).?.toArray()[k]);
    }
}

test "position solve leaves a static body bit-unchanged" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    var db = descOf(1, .static, s);
    db.position = av3(0.6, 0, 0); // 0.4 of penetration — deep
    // A non-identity static orientation, so `normalize` on it would be observable.
    db.rotation = foundation.math.Quatf.fromAxisAngle(av3(0.3, 1, -0.2).normalize(), 0.8);
    const id_a = try bm.addBody(gpa, &store, da);
    const id_b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});
    const before_b = bm.position(id_b).?.toArray();
    const before_qb = bm.rotation(id_b).?.toArray();
    const before_a = bm.position(id_a).?.toArray();

    const result = solvePositionRange(&bm, constraints.items, 0, constraints.items.len, .{});
    try testing.expect(result.iterations_run > 0);

    inline for (0..3) |k| try testing.expectEqual(before_b[k], bm.position(id_b).?.toArray()[k]);
    inline for (0..4) |k| try testing.expectEqual(before_qb[k], bm.rotation(id_b).?.toArray()[k]);
    // The dynamic side took the whole correction.
    try testing.expect(bm.position(id_a).?.toArray()[0] < before_a[0] - 1e-3);
}

test "the contact normal is not attached to body A" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    // Sphere A under a static box B. A sphere is the right shape HERE because
    // rotating it is physically a no-op, so the spin below changes nothing about
    // the contact except which way A's stored anchor points.
    //
    // The reason the normal may not follow A is NOT anything about this pair: it is
    // that the frozen `ContactManifold` carries no reference-face owner at all, and
    // that owner can be B. The witness for that is the LYING-CAPSULE-against-box
    // scene in `tests/position_solver_test.zig` — sphere-vs-box cannot be the
    // witness, because a sphere core is a point and `manifold.zig:235` exits
    // through `pointCoreContact` before the reference/incident selection ever runs.
    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(2, 0.5, 2) } });
    var da = descOf(0, .dynamic, sphere);
    da.mass = 1;
    var db = descOf(1, .static, box);
    db.position = av3(0, 0.9, 0); // box bottom at y = 0.4 ⇒ 0.1 of penetration
    const id_a = try bm.addBody(gpa, &store, da);
    const id_b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});
    const c = constraints.items[0];
    const normal = c.normal;
    try testing.expect(normal.approxEql(vr(0, 1, 0), 1e-4)); // A→B is +Y

    // Rotate A by a large angle AFTER prepare. A sphere is rotation-invariant, so
    // the physical contact is unchanged; only the stored anchor rides along.
    const spin = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), 0.5);
    bm.setRotation(id_a, Quatr.fromArray(.{ spin.x, spin.y, spin.z, spin.w }));

    const before_a = bm.position(id_a).?;
    const result = solvePositionRange(&bm, constraints.items, 0, constraints.items.len, .{});
    try testing.expect(result.iterations_run > 0);
    const delta = bm.position(id_a).?.sub(before_a);
    try testing.expect(delta.length() > 1e-4); // A really was corrected

    // The correction is along the STORED world normal (A is pushed along −n).
    const direction = delta.normalize();
    try testing.expect(direction.cross(normal).length() <= noise_tol);
    try testing.expect(direction.dot(normal) < 0);

    // Discrimination guard: had the normal been re-rotated with A, the correction
    // would have tilted by sin(0.5) ≈ 0.48 — four orders above the tolerance above.
    const rotated_normal = bm.rotation(id_a).?.rotateVec3(normal);
    try testing.expect(rotated_normal.cross(normal).length() > 100 * noise_tol);
}

test "world inverse inertia follows the current rotation during the pass" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    // An anisotropic box A resting on a static ground box, tilted about two axes so
    // a single CORNER touches ⇒ one contact point with a long lever arm.
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(1, 0.2, 0.5) } });
    const ground = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    const tilt_z = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), 0.3);
    const tilt_x = foundation.math.Quatf.fromAxisAngle(av3(1, 0, 0), 0.25);
    const tilt = tilt_z.mul(tilt_x);

    var da = descOf(0, .dynamic, box);
    da.mass = 1;
    da.rotation = tilt;
    // The tilted box's world half-height is 0.599, so its flush centre sits at
    // y = 0.5 + 0.599; 1.04 buries the corner ≈ 6 cm into the ground.
    da.position = av3(0, 1.04, 0);
    const db = descOf(1, .static, ground);
    const id_a = try bm.addBody(gpa, &store, da);
    const id_b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});
    try testing.expectEqual(@as(usize, 1), constraints.items.len);
    const c = constraints.items[0];
    try testing.expectEqual(@as(u8, 1), c.count); // a single corner contact

    // Re-orient A AFTER prepare, so the prepare-time world inverse inertia
    // (`c.inv_inertia_a`) and the current one differ substantially.
    const extra = foundation.math.Quatf.fromAxisAngle(av3(1, 0, 0), 0.9).mul(tilt);
    bm.setRotation(id_a, Quatr.fromArray(.{ extra.x, extra.y, extra.z, extra.w }));

    // Closed-form oracle of ONE iteration, computed here from the CURRENT rotation.
    const cfg = SolverConfig{ .position_iterations = 1 };
    const x_a = bm.position(id_a).?;
    const q_a = bm.rotation(id_a).?;
    const pt = c.points[0];
    const p_a = x_a.add(q_a.rotateVec3(pt.local_anchor_a));
    const p_b = bm.position(id_b).?.add(bm.rotation(id_b).?.rotateVec3(pt.local_anchor_b));
    const separation = p_b.sub(p_a).dot(c.normal);
    const sep = @max(separation + cfg.penetration_slop, -cfg.max_penetration_correction);
    try testing.expect(sep < 0); // the oracle covers a real correction
    const mid = p_a.add(p_b).scale(0.5);
    const r_a = mid.sub(x_a);
    const rot_now = Mat3r.fromQuat(q_a);
    const inertia_now = rot_now.mul(c.local_inv_inertia_a).mul(rot_now.transpose());
    const rna = r_a.cross(c.normal);
    const k_now = c.inv_mass_a + rna.dot(inertia_now.mulVec(rna)); // static B adds 0
    const lambda_now = -cfg.position_correction_factor * sep / k_now;
    const expected = rotateByDelta(q_a, inertia_now.mulVec(r_a.cross(c.normal.scale(lambda_now))).neg());

    // The frozen-inertia oracle: the same formula with the PREPARE-time tensor.
    const k_frozen = c.inv_mass_a + rna.dot(c.inv_inertia_a.mulVec(rna));
    const lambda_frozen = -cfg.position_correction_factor * sep / k_frozen;
    const frozen = rotateByDelta(q_a, c.inv_inertia_a.mulVec(r_a.cross(c.normal.scale(lambda_frozen))).neg());

    _ = solvePositionRange(&bm, constraints.items, 0, constraints.items.len, cfg);
    const observed = bm.rotation(id_a).?;

    try testing.expect(observed.approxEql(expected, noise_tol));
    // Discrimination guard: the frozen-inertia prediction is distinguishable (its
    // worst quaternion component is off by 5.3e-3, five times this guard), so the
    // assertion above really tests WHICH rotation the tensor was built from. The
    // gap is a geometric one, identical at f32 and f64 — not float noise.
    try testing.expect(!observed.approxEql(frozen, 100 * noise_tol));
}

test "solvePositionRange corrects only the given constraint index range" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Two independent overlapping pairs, the second ten metres away. pair_key(0,1)
    // < pair_key(2,3), so the first pair is constraint 0.
    var a0 = descOf(0, .dynamic, s);
    a0.mass = 1;
    var b0 = descOf(1, .dynamic, s);
    b0.mass = 1;
    b0.position = av3(0.9, 0, 0);
    var a1 = descOf(2, .dynamic, s);
    a1.mass = 1;
    a1.position = av3(10, 0, 0);
    var b1 = descOf(3, .dynamic, s);
    b1.mass = 1;
    b1.position = av3(10.9, 0, 0);
    const id_a0 = try bm.addBody(gpa, &store, a0);
    const id_b0 = try bm.addBody(gpa, &store, b0);
    const id_a1 = try bm.addBody(gpa, &store, a1);
    const id_b1 = try bm.addBody(gpa, &store, b1);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{
        pairKey(id_a0, id_b0), pairKey(id_a1, id_b1),
    });
    try testing.expectEqual(@as(usize, 2), constraints.items.len);
    const before_a1 = bm.position(id_a1).?.toArray();
    const before_b1 = bm.position(id_b1).?.toArray();

    _ = solvePositionRange(&bm, constraints.items, 0, 1, .{});

    // The first pair separated; the second pair's poses are bit-unchanged.
    try testing.expect(bm.position(id_a0).?.toArray()[0] < -1e-4);
    inline for (0..3) |k| {
        try testing.expectEqual(before_a1[k], bm.position(id_a1).?.toArray()[k]);
        try testing.expectEqual(before_b1[k], bm.position(id_b1).?.toArray()[k]);
    }
}
