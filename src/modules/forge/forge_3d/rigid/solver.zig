//! `forge_3d/rigid/solver.zig` — the substepped rigid contact solver (TGS Soft,
//! Catto lineage: Solver2D → Box2D v3), executing steps 6 and 7 of the normative
//! per-tick cycle (`engine-physics-solver.md` §1.7).
//!
//! It replaces the M1.1.6 Sequential Impulses velocity pass and the M1.1.7 NGS
//! position pass, which it merges into one loop: **there is no position pass**.
//! Position error enters the solve as a bounded VELOCITY BIAS derived from soft
//! constraints, and each substep re-integrates the poses, so the separation the next
//! substep reads is the one the previous one produced. Penetration recovery is PACED
//! by `contact_push_max_speed` instead of resorbed in a single frame.
//!
//! Per substep, in this exact order (read on the pinned reference
//! `erincatto/box2d @ 56edae7`, never deduced):
//!
//!   1. `integrateVelocitiesNoReset(h)` — gravity, the tick's force/torque
//!      accumulators, clamped damping. NoReset because the accumulators must survive
//!      every substep; the uniform §2 clear runs once after the last one.
//!   2. warm-start APPLICATION — inject the CURRENT accumulators, growth from earlier
//!      substeps included. Distinct from the SEEDING, which ran once at `prepare`.
//!   3. biased solve — normal points only, one sweep.
//!   4. `integratePositions(h)`.
//!   5. relax — one sweep: every normal point unbiased, THEN every friction point.
//!
//! After the loop: the accumulator reset, then the restitution pass (step 7). The
//! per-tick constraint cost is therefore `3·substep_count + 1` sweeps — `n`
//! applications, `n` solves, `n` relaxes, one restitution: 13 at the defaults, FIXED
//! by construction. No early-out, no convergence predicate, no iteration budget.
//!
//! **Friction runs in relax only**, after every normal point of its constraint —
//! source parity. Its mechanics are unchanged from M1.1.6: two independent tangent
//! axes driven to zero, a CIRCULAR clamp `‖(λ_t1, λ_t2)‖ ≤ μ·λₙ` against the point's
//! current accumulated normal impulse, the vector rescaled and never per-axis, and no
//! bias of any kind — position error is normal by construction. The M1.1.6 comment
//! claiming normal-first as a divergence from the references retires with this file:
//! the pinned source is normal-first too.
//!
//! **Island seam.** Every stage is range-shaped `[from, to)` and is called once per
//! island interval per stage per substep, islands advancing in LOCKSTEP — each stage
//! sweeps all intervals before the next begins. Per-island solving is bit-exactly
//! equivalent to one global range on disjoint islands (§1.8.1), which is structural:
//! two islands touch disjoint bodies, so no update of one can change an input of the
//! other, and the composite sort key preserves relative order inside each range.
//!
//! Import discipline: `foundation`, `weld_forge`, `../config.zig`,
//! `../body_manager.zig`, the `rigid/` siblings — and `../pipeline/integration.zig`,
//! which is the THIRD and last pipeline import of this branch (after the narrowphase
//! facade and, since M1.1.8, `sleep.zig`). It is required rather than convenient: the
//! substep loop IS the interleaving of integration with the constraint stages, and
//! splitting that order across two files would leave the normative sequence written
//! down in neither.

const std = @import("std");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const integration = @import("../pipeline/integration.zig");
const cc = @import("contact_constraint.zig");
const cache_mod = @import("contact_cache.zig");
const island_mod = @import("island_manager.zig");
const solver_config = @import("solver_config.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyManager = bm_mod.BodyManager;
const ContactConstraint = cc.ContactConstraint;
const ConstraintPoint = cc.ConstraintPoint;
const ContactCache = cache_mod.ContactCache;
const Island = island_mod.Island;
const SolverConfig = solver_config.SolverConfig;

/// What one tick of the solver did.
///
/// TELEMETRY ONLY — never a control input. Feeds `get_solver_iterations_stats`
/// (`PhysicsDebugProvider`, `engine-physics-forge.md` §1.10). The sweep counts are
/// per SUBSTEP, not per island: a sweep is one pass over the constraint array, which
/// the island loop splits into intervals without multiplying.
pub const SolverStats = struct {
    /// Substeps executed — `cfg.substep_count`, since nothing terminates early.
    substeps_executed: u32 = 0,
    /// Biased solve sweeps (one per substep).
    solve_sweeps: u32 = 0,
    /// Relax sweeps (one per substep).
    relax_sweeps: u32 = 0,
    /// Constraint POINTS the warm start injected this tick, summed over substeps.
    ///
    /// NOT part of what `get_solver_iterations_stats` reports — `engine-physics-solver.md`
    /// §1.8.2 states the reported set as the solve/relax sweeps and explicitly excludes
    /// the warm-start applications. This field is not that surface: it exists so the
    /// APPLICATION half of warm start is observable where it happens, since "applied
    /// once per substep, every substep" (§1.7 step 6) is otherwise a claim no test can
    /// reach. It counts real injections rather than loop turns: a `substep_count` of 4
    /// over one 4-point manifold reads 16, and hoisting the call out of the loop reads
    /// 4 — which is the counter-factual that gives the number its meaning.
    warm_start_injections: u32 = 0,
    /// The smallest separation any biased sweep observed this tick, or `null` if no
    /// point was evaluated at all. Negative means overlap.
    min_separation: ?Real = null,
};

/// What one biased sweep over one island range observed.
pub const RangeStats = struct {
    min_separation: ?Real = null,
};

/// The tick's two coefficient triples, derived once from `(contact_hertz,
/// contact_damping_ratio, h)` with `h = dt / substep_count`.
///
/// The effective hertz is the authored stiffness clamped to an eighth of the substep
/// rate; the static triple takes `static_hertz_factor` times that. Both are
/// constraint-independent, which is why they are derived here and merely SELECTED at
/// `prepare`.
pub fn makeSoftnessPair(cfg: SolverConfig, dt: Real) cc.SoftnessPair {
    solver_config.assertDomain(cfg);
    std.debug.assert(std.math.isFinite(dt) and dt > 0);

    const h = dt / @as(Real, @floatFromInt(cfg.substep_count));
    const f_eff = cc.effectiveContactHertz(cfg.contact_hertz, cfg.substep_count, dt);
    return .{
        .contact = cc.makeSoft(f_eff, cfg.contact_damping_ratio, h),
        .static = cc.makeSoft(cc.static_hertz_factor * f_eff, cfg.contact_damping_ratio, h),
    };
}

/// Everything `build` needs beyond the geometry: the tick's softness pair and the
/// warm-start source. `cache` may be `null`, which cold-starts every point.
pub fn prepareContext(cfg: SolverConfig, dt: Real, cache: ?*ContactCache) cc.PrepareContext {
    return .{ .softness = makeSoftnessPair(cfg, dt), .cache = cache };
}

/// Apply a world-space impulse `p` at the contact levers `r_a`/`r_b` to both bodies'
/// velocities: A receives −p, B receives +p (the normal is A→B). Naturally a no-op on
/// an infinite-mass body — `inv_mass` and `inv_inertia` are both zero for static and
/// kinematic — so no `body_type` branch is needed.
fn applyImpulse(bm: *BodyManager, c: *const ContactConstraint, r_a: Vec3r, r_b: Vec3r, p: Vec3r) void {
    bm.setLinearVelocity(c.body_a, bm.linearVelocity(c.body_a).?.sub(p.scale(c.inv_mass_a)));
    bm.setAngularVelocity(c.body_a, bm.angularVelocity(c.body_a).?.sub(c.inv_inertia_a.mulVec(r_a.cross(p))));
    bm.setLinearVelocity(c.body_b, bm.linearVelocity(c.body_b).?.add(p.scale(c.inv_mass_b)));
    bm.setAngularVelocity(c.body_b, bm.angularVelocity(c.body_b).?.add(c.inv_inertia_b.mulVec(r_b.cross(p))));
}

/// Relative normal velocity at a contact point, from the CURRENT body velocities.
fn relativeNormalVelocity(bm: *const BodyManager, c: *const ContactConstraint, pt: *const ConstraintPoint) Real {
    const v_a = bm.linearVelocity(c.body_a).?;
    const w_a = bm.angularVelocity(c.body_a).?;
    const v_b = bm.linearVelocity(c.body_b).?;
    const w_b = bm.angularVelocity(c.body_b).?;
    return c.normal.dot(v_b.add(w_b.cross(pt.r_b)).sub(v_a.add(w_a.cross(pt.r_a))));
}

/// The point's separation RE-DERIVED from the current poses: the two body-local
/// anchors transported by the current pose, projected on the FROZEN world normal.
/// Negative means overlap.
///
/// This is the one quantity the substep loop recomputes. The Jacobian arms, the world
/// inverse inertias, the effective masses and the tangent basis are frozen at
/// `prepare` for the whole tick (§1.7.1) — re-rotating the arms per substep would
/// leave them inconsistent with those frozen effective masses.
fn currentSeparation(bm: *const BodyManager, c: *const ContactConstraint, pt: *const ConstraintPoint) Real {
    const p_a = bm.position(c.body_a).?.add(bm.rotation(c.body_a).?.rotateVec3(pt.local_anchor_a));
    const p_b = bm.position(c.body_b).?.add(bm.rotation(c.body_b).?.rotateVec3(pt.local_anchor_b));
    return p_b.sub(p_a).dot(c.normal);
}

/// Which of the two normal sweeps is running.
const NormalPass = enum {
    /// The biased sweep: soft coefficients and the position-error bias are active.
    biased,
    /// The relax sweep: bias cut, coefficients neutral. It removes the momentum the
    /// bias injected — the functional replacement for NGS's "throw away the velocity
    /// change", obtained in velocity, inside the loop, instead of by a separate
    /// position pass (§1.7.2).
    relax,
};

/// One normal-impulse update for one contact point.
///
/// Three branches, and the first is shared by both passes (§1.7.1):
///
/// ```
/// if s > 0:                     speculative — bias = s/h, coefficients neutral
/// else if biased:               error = min(s + slop, 0)
///                               bias  = max(mass_scale·bias_rate·error, −push_max)
///                               coefficients = the constraint's softness
/// else (relax, s <= 0):         bias = 0, coefficients neutral
/// Δλ = −normal_mass·(mass_scale·v_n + bias) − impulse_scale·λₙ
/// ```
///
/// The `s > 0` branch is what lets a point whose separation turns positive MID-TICK
/// limit the approach to exactly the speed that closes the gap in one substep,
/// without ever pulling: the accumulated clamp `λₙ ≥ 0` still forbids attraction.
///
/// **The slop dead zone is a documented Weld divergence.** The reference uses the raw
/// separation; the `min(s + penetration_slop, 0)` offset preserves the frozen role of
/// the 5 mm slop — a stationary overlap that keeps the manifold and its warm-start
/// entry persistent — which the reference obtains instead from speculative manifold
/// margins, out of scope here. Setting the offset to zero restores exact parity the
/// day speculative contacts land. Note the coefficients still apply THROUGHOUT the
/// dead zone: only the bias term is zeroed, so a contact inside it is still solved,
/// just not pushed.
///
/// The recovery clamp sits OUTSIDE `mass_scale`, so the effective cap on the bias is
/// exactly `contact_push_max_speed` rather than a fraction of it.
fn solveNormalPoint(
    bm: *BodyManager,
    c: *const ContactConstraint,
    pt: *ConstraintPoint,
    cfg: SolverConfig,
    h: Real,
    pass: NormalPass,
    stats: ?*RangeStats,
) void {
    const s = currentSeparation(bm, c, pt);
    if (stats) |st| {
        if (st.min_separation == null or s < st.min_separation.?) st.min_separation = s;
    }

    var velocity_bias: Real = 0;
    var mass_scale: Real = 1;
    var impulse_scale: Real = 0;
    if (s > 0) {
        velocity_bias = s / h;
    } else if (pass == .biased) {
        const err = @min(s + cfg.penetration_slop, 0);
        velocity_bias = @max(c.softness.mass_scale * c.softness.bias_rate * err, -cfg.contact_push_max_speed);
        mass_scale = c.softness.mass_scale;
        impulse_scale = c.softness.impulse_scale;
    }

    const v_n = relativeNormalVelocity(bm, c, pt);
    const delta = -pt.normal_mass * (mass_scale * v_n + velocity_bias) - impulse_scale * pt.normal_impulse;

    // Accumulated clamp: the solver can push, never pull (Catto).
    const new_lambda = @max(@as(Real, 0), pt.normal_impulse + delta);
    const applied = new_lambda - pt.normal_impulse;
    pt.normal_impulse = new_lambda;
    // The bookkeeping §1.7.2 freezes, and NOTHING MORE than it: the ALGEBRAIC,
    // POST-clamp delta. A retraction subtracts exactly what the push added, so a run of
    // updates between two warm-start applications TELESCOPES to the net change in `λₙ`
    // over that run — a point pushed and then relaxed fully back to zero returns to zero
    // here too.
    //
    // So this is NOT a participation flag, and an earlier comment here said it was. What
    // the restitution predicate reads is the frozen two-clause test on this sum's final
    // value, and the parity claimed against the reference is on the ARITHMETIC — the
    // three contributions and their signs — never on a meaning attached to the result.
    pt.total_normal_impulse += applied;
    applyImpulse(bm, c, pt.r_a, pt.r_b, c.normal.scale(applied));
}

/// One friction update for one contact point, run in the relax sweep after every
/// normal point of its constraint. Two INDEPENDENT per-axis tangential impulses drive
/// the tangential velocity toward 0 (coupling ignored — Jolt convention), then the
/// accumulated `(λ_t1, λ_t2)` pair is CIRCULARLY clamped to the friction cone
/// `‖λ_t‖ ≤ μ·λₙ` against the point's current accumulated normal impulse. The circular
/// clamp is isotropic and basis-independent — coherent with the world-space tangent
/// cache; a box clamp is anisotropic (up to √2·μ·λₙ on the diagonal) and basis-biased.
fn solveFrictionPoint(bm: *BodyManager, c: *const ContactConstraint, pt: *ConstraintPoint) void {
    const v_a = bm.linearVelocity(c.body_a).?;
    const w_a = bm.angularVelocity(c.body_a).?;
    const v_b = bm.linearVelocity(c.body_b).?;
    const w_b = bm.angularVelocity(c.body_b).?;
    const v_rel = v_b.add(w_b.cross(pt.r_b)).sub(v_a.add(w_a.cross(pt.r_a)));

    var new_t1 = pt.tangent1_impulse - pt.tangent1_mass * c.tangent1.dot(v_rel);
    var new_t2 = pt.tangent2_impulse - pt.tangent2_mass * c.tangent2.dot(v_rel);

    // The branch guarantees `len_sq > max_friction² ≥ 0`, so the √ divisor is nonzero.
    const max_friction = c.friction * pt.normal_impulse;
    const len_sq = new_t1 * new_t1 + new_t2 * new_t2;
    if (len_sq > max_friction * max_friction) {
        const scale = max_friction / @sqrt(len_sq);
        new_t1 *= scale;
        new_t2 *= scale;
    }

    const applied_t1 = new_t1 - pt.tangent1_impulse;
    const applied_t2 = new_t2 - pt.tangent2_impulse;
    pt.tangent1_impulse = new_t1;
    pt.tangent2_impulse = new_t2;
    applyImpulse(bm, c, pt.r_a, pt.r_b, c.tangent1.scale(applied_t1).add(c.tangent2.scale(applied_t2)));
}

/// Inject each point's CURRENT accumulated impulses into the body velocities — once
/// per substep, immediately after the velocity integration. Returns the number of
/// points it injected, which is what makes the per-substep cadence observable.
///
/// The accumulators include everything earlier substeps of this tick solved, which is
/// exactly the point: this is the APPLICATION half of warm start, and the SEEDING half
/// ran once at `prepare` (`contact_constraint.seedWarmStart`). The two must stay
/// distinct functions — re-seeding here would re-read the cache every substep and
/// throw away the tick's own progress.
pub fn applyWarmStartRange(bm: *BodyManager, constraints: []ContactConstraint, from: usize, to: usize) u32 {
    var injected: u32 = 0;
    for (constraints[from..to]) |*c| {
        for (0..c.count) |i| {
            injected += 1;
            const pt = &c.points[i];
            const impulse = c.normal.scale(pt.normal_impulse)
                .add(c.tangent1.scale(pt.tangent1_impulse))
                .add(c.tangent2.scale(pt.tangent2_impulse));
            pt.total_normal_impulse += pt.normal_impulse;
            applyImpulse(bm, c, pt.r_a, pt.r_b, impulse);
        }
    }
    return injected;
}

/// The BIASED sweep over the constraint index range `[from, to)` — normal points
/// only, no friction. Constraints are visited in ascending composite-key order (as
/// `build` and the island permutation sorted them) and points in manifold order.
pub fn solveRange(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    from: usize,
    to: usize,
    cfg: SolverConfig,
    h: Real,
) void {
    solver_config.assertDomain(cfg);
    _ = solveRangeReport(bm, constraints, from, to, cfg, h);
}

/// `solveRange` with its telemetry returned — the SIBLING entry (§1.8.2). The `void`
/// entry keeps its exact signature, so the range seam the island manager consumes does
/// not move.
pub fn solveRangeReport(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    from: usize,
    to: usize,
    cfg: SolverConfig,
    h: Real,
) RangeStats {
    solver_config.assertDomain(cfg);
    std.debug.assert(std.math.isFinite(h) and h > 0);
    var stats: RangeStats = .{};
    for (constraints[from..to]) |*c| {
        for (0..c.count) |i| solveNormalPoint(bm, c, &c.points[i], cfg, h, .biased, &stats);
    }
    return stats;
}

/// The RELAX sweep over `[from, to)`: every normal point of a constraint unbiased,
/// THEN every friction point of that constraint — source order, and the only sweep in
/// which friction runs at all.
pub fn relaxRange(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    from: usize,
    to: usize,
    cfg: SolverConfig,
    h: Real,
) void {
    solver_config.assertDomain(cfg);
    std.debug.assert(std.math.isFinite(h) and h > 0);
    for (constraints[from..to]) |*c| {
        for (0..c.count) |i| solveNormalPoint(bm, c, &c.points[i], cfg, h, .relax, null);
        for (0..c.count) |i| solveFrictionPoint(bm, c, &c.points[i]);
    }
}

/// The restitution pass over `[from, to)` — step 7, once after the whole substep loop.
///
/// A point bounces iff BOTH clauses hold, taken literally:
/// `v_n⁻ <= −restitution_threshold` (a closed interval, which supersedes §1.7.2's
/// strict `<` wording) AND `total_normal_impulse != 0`.
///
/// The second clause guarantees ONE direction and only that one: a point that NEVER
/// pushed reads exactly zero, which is what keeps a speculative point the tick never
/// had to resolve from bouncing. The converse is NOT claimed — a push fully retracted
/// by relax telescopes to zero as well, and reads the same. That is reference-conforming
/// behaviour, not a case the predicate distinguishes.
///
/// Placed after the loop rather than inside it because under soft constraints an
/// in-loop restitution would be re-damped substep after substep, making the rebound a
/// function of `substep_count` — which would break the independence of the tuning from
/// the step (§1.7.2).
///
/// The reference's additional `restitution == 0` early-out is NOT ported: the frozen
/// predicate has two clauses. With `e == 0` the update reduces to `−normal_mass · v_n`,
/// which the relax sweep immediately before has already driven to ≈ 0, so what remains
/// is a Gauss-Seidel remainder and not a bounce.
pub fn applyRestitutionRange(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    from: usize,
    to: usize,
    cfg: SolverConfig,
) void {
    solver_config.assertDomain(cfg);
    for (constraints[from..to]) |*c| {
        for (0..c.count) |i| {
            const pt = &c.points[i];
            if (pt.rel_normal_velocity > -cfg.restitution_threshold) continue;
            if (pt.total_normal_impulse == 0) continue;

            const v_n = relativeNormalVelocity(bm, c, pt);
            const delta = -pt.normal_mass * (v_n + c.restitution * pt.rel_normal_velocity);
            const new_lambda = @max(@as(Real, 0), pt.normal_impulse + delta);
            const applied = new_lambda - pt.normal_impulse;
            pt.normal_impulse = new_lambda;
            pt.total_normal_impulse += applied;
            applyImpulse(bm, c, pt.r_a, pt.r_b, c.normal.scale(applied));
        }
    }
}

/// Harvest each constraint point's solved impulse into the cache's current buffer —
/// step 9, AFTER the restitution pass, so the cached impulses include the restitution
/// correction (source parity). The tangent is reconstructed in world space
/// (`λ_t1·t1 + λ_t2·t2`); `total_normal_impulse` is NOT stored, being per-tick
/// bookkeeping in a frozen two-field format.
pub fn storeContacts(gpa: std.mem.Allocator, cache: *ContactCache, constraints: []const ContactConstraint) !void {
    for (constraints) |c| {
        for (0..c.count) |i| {
            const pt = c.points[i];
            const tangent = c.tangent1.scale(pt.tangent1_impulse).add(c.tangent2.scale(pt.tangent2_impulse));
            try cache.store(
                gpa,
                .{ .pair_key = c.pair_key, .subshape_id = c.subshape_id, .feature_id = pt.feature_id },
                .{ .lambda_n = pt.normal_impulse, .tangent_impulse = tangent },
            );
        }
    }
}

/// Steps 6 and 7 of the per-tick cycle: the substep loop, the uniform accumulator
/// reset, and the restitution pass. Islands advance in LOCKSTEP — every stage sweeps
/// all intervals before the next stage begins.
///
/// `islands` may be empty (nothing awake and dynamic): the integrations still run, so
/// a body in free flight with no contact advances exactly as it would have.
pub fn solveTick(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    islands: []const Island,
    cfg: SolverConfig,
    dt: Real,
    gravity: Vec3r,
) SolverStats {
    solver_config.assertDomain(cfg);
    std.debug.assert(std.math.isFinite(dt) and dt > 0);

    var stats: SolverStats = .{};
    const h = dt / @as(Real, @floatFromInt(cfg.substep_count));

    var substep: u32 = 0;
    while (substep < cfg.substep_count) : (substep += 1) {
        integration.integrateVelocitiesNoReset(bm, h, gravity);

        for (islands) |isl| stats.warm_start_injections += applyWarmStartRange(bm, constraints, isl.constraint_from, isl.constraint_to);

        for (islands) |isl| {
            const range = solveRangeReport(bm, constraints, isl.constraint_from, isl.constraint_to, cfg, h);
            if (range.min_separation) |s| {
                stats.min_separation = if (stats.min_separation) |current| @min(current, s) else s;
            }
        }
        stats.solve_sweeps += 1;

        integration.integratePositions(bm, h);

        for (islands) |isl| relaxRange(bm, constraints, isl.constraint_from, isl.constraint_to, cfg, h);
        stats.relax_sweeps += 1;

        stats.substeps_executed += 1;
    }

    // The uniform §2 clear, ONCE, after the last substep consumed the accumulators —
    // never before the first, which would deliver `F/m·0` (blocker B1).
    integration.resetForceAccumulators(bm);

    for (islands) |isl| applyRestitutionRange(bm, constraints, isl.constraint_from, isl.constraint_to, cfg);

    return stats;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "the softness pair clamps its hertz and stiffens the static half" {
    const cfg = SolverConfig{};
    const dt: Real = 1.0 / 60.0;
    const pair = makeSoftnessPair(cfg, dt);

    // At the defaults the clamp binds at equality, so the ordinary triple is the one
    // for 30 Hz, and the static triple is the one for 60 Hz — both at `h = dt/4`.
    const h = dt / 4.0;
    const f_eff = cc.effectiveContactHertz(cfg.contact_hertz, cfg.substep_count, dt);
    const expected_contact = cc.makeSoft(f_eff, cfg.contact_damping_ratio, h);
    const expected_static = cc.makeSoft(2 * f_eff, cfg.contact_damping_ratio, h);

    try testing.expectEqual(expected_contact.bias_rate, pair.contact.bias_rate);
    try testing.expectEqual(expected_static.bias_rate, pair.static.bias_rate);
    try testing.expect(pair.static.bias_rate > pair.contact.bias_rate);

    // At one substep the clamp bites and BOTH halves soften — the A/B lever's
    // documented behaviour, asserted rather than assumed.
    const big_step = makeSoftnessPair(.{ .substep_count = 1 }, dt);
    try testing.expect(big_step.contact.bias_rate < pair.contact.bias_rate);
}

test "solveTick reports a fixed sweep budget and no early-out" {
    const gpa = testing.allocator;
    var store = bm_mod.ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);

    // No bodies, no constraints, no islands: the budget is structural, so it does not
    // depend on there being work to do.
    const stats = solveTick(&bm, &.{}, &.{}, .{}, 1.0 / 60.0, Vec3r.zero);
    try testing.expectEqual(@as(u32, 4), stats.substeps_executed);
    try testing.expectEqual(@as(u32, 4), stats.solve_sweeps);
    try testing.expectEqual(@as(u32, 4), stats.relax_sweeps);
    try testing.expectEqual(@as(?Real, null), stats.min_separation);

    const one = solveTick(&bm, &.{}, &.{}, .{ .substep_count = 1 }, 1.0 / 60.0, Vec3r.zero);
    try testing.expectEqual(@as(u32, 1), one.substeps_executed);
    try testing.expectEqual(@as(u32, 1), one.solve_sweeps);
    try testing.expectEqual(@as(u32, 1), one.relax_sweeps);
}
