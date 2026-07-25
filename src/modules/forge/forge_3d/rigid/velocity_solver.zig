//! `forge_3d/rigid/velocity_solver.zig` — the Sequential Impulses velocity
//! solver (Catto lineage). M1.1.6 lands warm starting here; the velocity
//! iterations (normal + restitution, then friction) and the `SolverConfig` +
//! range-shaped entry land at E4/E5 as additive changes to this same file.
//!
//! This is a VELOCITY solver only: no positional bias (no Baumgarte, no split
//! impulse). Warm start re-applies the previous tick's accumulated impulses
//! (from `ContactCache`) before the first iteration, which is what lets the
//! iterative solve converge in a handful of passes.
//!
//! Import discipline (brief): `foundation`, `weld_forge`, `../config.zig`,
//! `../body_manager.zig`, sibling `contact_constraint.zig`/`contact_cache.zig`/
//! `solver_config.zig`.
//! Velocities are read/written through `BodyManager`'s stale-safe getters/setters
//! (immediate Gauss-Seidel propagation across contacts and points).

const std = @import("std");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const cc = @import("contact_constraint.zig");
const cache_mod = @import("contact_cache.zig");
const solver_config = @import("solver_config.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyManager = bm_mod.BodyManager;
const ContactConstraint = cc.ContactConstraint;
const ContactCache = cache_mod.ContactCache;
/// Solver tuning, owned by `solver_config.zig` since M1.1.7 (one struct shared by
/// the velocity and position passes belongs to neither solver). The velocity half
/// — `velocity_iterations`, `restitution_threshold` — is unchanged by the move.
const SolverConfig = solver_config.SolverConfig;

/// Apply a world-space impulse `p` at the contact levers `r_a`/`r_b` to both
/// bodies' velocities: body A receives −p, body B receives +p (the normal is
/// A→B). Naturally a no-op on an infinite-mass body (inv_mass and inv_inertia
/// are both zero for static/kinematic), so no `body_type` branch is needed.
fn applyImpulse(bm: *BodyManager, c: *const ContactConstraint, r_a: Vec3r, r_b: Vec3r, p: Vec3r) void {
    bm.setLinearVelocity(c.body_a, bm.linearVelocity(c.body_a).?.sub(p.scale(c.inv_mass_a)));
    bm.setAngularVelocity(c.body_a, bm.angularVelocity(c.body_a).?.sub(c.inv_inertia_a.mulVec(r_a.cross(p))));
    bm.setLinearVelocity(c.body_b, bm.linearVelocity(c.body_b).?.add(p.scale(c.inv_mass_b)));
    bm.setAngularVelocity(c.body_b, bm.angularVelocity(c.body_b).?.add(c.inv_inertia_b.mulVec(r_b.cross(p))));
}

/// Warm-start every constraint from the previous tick's cache. For each point
/// that matches (per full feature key), re-apply the cached normal impulse along
/// the NEW normal plus the cached WORLD tangent impulse reprojected onto the new
/// tangent plane and clamped to μ·λₙ; seed the accumulated impulses and apply
/// them to both bodies' velocities before the first iteration. A per-feature miss
/// cold-starts (impulses left at 0, nothing applied).
pub fn warmStart(bm: *BodyManager, cache: *ContactCache, constraints: []ContactConstraint) void {
    for (constraints) |*c| {
        for (0..c.count) |i| {
            const pt = &c.points[i];
            const cached = cache.lookup(.{ .pair_key = c.pair_key, .feature_id = pt.feature_id }) orelse continue;
            const lambda_n = cached.lambda_n;

            // Reproject the cached WORLD tangent onto the new tangent plane
            // (remove the component along the new normal — the basis may have
            // rotated since it was cached), then circular-clamp its norm to μ·λₙ.
            var j_t = cached.tangent_impulse.sub(c.normal.scale(cached.tangent_impulse.dot(c.normal)));
            const max_t = c.friction * lambda_n;
            const len_sq = j_t.lengthSq();
            if (len_sq > max_t * max_t) {
                j_t = j_t.scale(max_t / @sqrt(len_sq));
            }

            // Seed the accumulated impulses (decompose the tangent onto the basis)
            // and apply the total impulse to both bodies.
            pt.normal_impulse = lambda_n;
            pt.tangent1_impulse = j_t.dot(c.tangent1);
            pt.tangent2_impulse = j_t.dot(c.tangent2);
            const impulse = c.normal.scale(lambda_n).add(j_t);
            applyImpulse(bm, c, pt.r_a, pt.r_b, impulse);
        }
    }
}

/// Harvest each constraint point's solved impulse into the cache's current buffer
/// (key `(pair_key, 0, feature_id)`, tangent = λ_t1·t1 + λ_t2·t2 in world space).
/// Called after the velocity iterations, before `ContactCache.endTick` sorts and
/// swaps.
pub fn storeContacts(gpa: std.mem.Allocator, cache: *ContactCache, constraints: []const ContactConstraint) !void {
    for (constraints) |c| {
        for (0..c.count) |i| {
            const pt = c.points[i];
            const tangent = c.tangent1.scale(pt.tangent1_impulse).add(c.tangent2.scale(pt.tangent2_impulse));
            try cache.store(
                gpa,
                .{ .pair_key = c.pair_key, .feature_id = pt.feature_id },
                .{ .lambda_n = pt.normal_impulse, .tangent_impulse = tangent },
            );
        }
    }
}

/// What one `solveRangeReport` pass observed.
///
/// TELEMETRY ONLY — never a control input. Feeds `get_solver_iterations_stats`
/// (`PhysicsDebugProvider`, `engine-physics-forge.md` §1.10), symmetrically to the
/// position pass's `PositionSolveResult`.
pub const VelocitySolveResult = struct {
    /// Velocity iterations actually run, `<= cfg.velocity_iterations`. The pass
    /// stops on the first iteration that applies no impulse at all.
    iterations_run: u32 = 0,
};

/// `solveRange` with the iteration telemetry returned — the SIBLING entry
/// (`engine-physics-forge.md` §1.8.2). The `void` entry keeps its exact signature,
/// so the range seam the island manager consumes does not move.
pub fn solveRangeReport(
    bm: *BodyManager,
    constraints: []ContactConstraint,
    from: usize,
    to: usize,
    cfg: SolverConfig,
) VelocitySolveResult {
    // A finite, non-negative restitution threshold — a negative one would rearm
    // the M1.1.6 defect (restitution bias applied to a separating contact). Zero
    // `velocity_iterations` is legal (warm start only) and needs no guard.
    std.debug.assert(std.math.isFinite(cfg.restitution_threshold) and cfg.restitution_threshold >= 0);

    var result: VelocitySolveResult = .{};
    var iter: u32 = 0;
    while (iter < cfg.velocity_iterations) : (iter += 1) {
        result.iterations_run = iter + 1;
        var applied_any = false;
        for (constraints[from..to]) |*c| {
            for (0..c.count) |i| {
                // Normal impulse first, then friction clamped against the CURRENT
                // accumulated normal impulse of this point. This is a DELIBERATE
                // DIVERGENCE from both references, which solve friction first and
                // non-penetration last, clamping the cone with the previous
                // iteration's λₙ (Jolt `ContactConstraintManager.cpp`
                // `sSolveVelocityConstraint`; Box2D `b2_contact_solver.cpp`). An
                // earlier comment here credited this order to Jolt — that
                // attribution was wrong. No performance or accuracy motive is
                // claimed for the divergence: swapping the order was measured at
                // M1.1.7 and did not improve the five-box stack (see that brief's
                // Recorded deviations). Porting the reference friction model is a
                // whole-model change (order + per-manifold aggregation + twist
                // friction), tracked as an open design item.
                if (solveNormalPoint(bm, c, &c.points[i], cfg)) applied_any = true;
                if (solveFrictionPoint(bm, c, &c.points[i])) applied_any = true;
            }
        }
        // An iteration that applied NO impulse ends the pass. The equivalence is
        // exact, not approximate: velocities change only through an applied `Δλ`,
        // so an iteration that applies nothing leaves the next one reading an
        // identical state, which will likewise apply nothing. The test is at TRUE
        // ZERO — never an epsilon; an epsilon would break the bit-exact equivalence
        // and the threshold discipline both.
        //
        // The early-out is exact and free, but its YIELD is scene- and
        // precision-dependent, precisely because the predicate is a true-zero test:
        // it fires only once `Δλ` underflows to exactly zero, which happens sooner in
        // coarser precision. Measured on a resting five-box stack (40 contact points),
        // ceiling 16: 11 iterations at f32, all 16 at f64. So this is not generally a
        // rarely-reached ceiling — see `solver_config.zig`'s `velocity_iterations`.
        // The position pass already terminates the same way, and there the saving is
        // unambiguous: 1 iteration of 3 at rest, at both precisions.
        if (!applied_any) break;
    }
    return result;
}

/// Solve the velocity constraints over the constraint index range `[from, to)`
/// with at most `cfg.velocity_iterations` Gauss-Seidel passes. Constraints are
/// visited in ascending pair-key order (as `build` sorted them) and points in
/// manifold order. The explicit range is the island seam: `rigid/island_manager.zig`
/// sorts constraints into contiguous per-island ranges and this is called once per
/// range. Signature unchanged since M1.1.6 — the iteration telemetry arrives
/// through `solveRangeReport`, never through a changed return type.
pub fn solveRange(bm: *BodyManager, constraints: []ContactConstraint, from: usize, to: usize, cfg: SolverConfig) void {
    _ = solveRangeReport(bm, constraints, from, to, cfg);
}

/// One Gauss-Seidel normal-impulse update for a contact point: drive the relative
/// normal velocity toward its restitution target, with the accumulated-impulse
/// clamp `λₙ ≥ 0` (Catto — the solver can only push, never pull). Returns whether a
/// non-zero impulse was applied, at TRUE ZERO — the early-out's progress signal.
fn solveNormalPoint(bm: *BodyManager, c: *const ContactConstraint, pt: *cc.ConstraintPoint, cfg: SolverConfig) bool {
    const v_a = bm.linearVelocity(c.body_a).?;
    const w_a = bm.angularVelocity(c.body_a).?;
    const v_b = bm.linearVelocity(c.body_b).?;
    const w_b = bm.angularVelocity(c.body_b).?;
    const v_rel = v_b.add(w_b.cross(pt.r_b)).sub(v_a.add(w_a.cross(pt.r_a)));
    const v_n = c.normal.dot(v_rel);

    // Restitution bias — the solver's ONLY velocity bias (no Baumgarte, no
    // positional bias): when the pre-solve contact is APPROACHING faster than the
    // threshold (v_n⁻ < −threshold), target a separating rebound speed −e·v_n⁻
    // (> 0); otherwise target rest (0). Keyed on the approach direction, never on
    // |v_n⁻|, so a capture-time SEPARATING contact never yields a negative target
    // that would under-enforce non-penetration.
    const restitution_bias: Real = if (pt.rel_normal_velocity < -cfg.restitution_threshold)
        -c.restitution * pt.rel_normal_velocity
    else
        0;

    // Impulse driving v_n toward the target (Δv_n = kₙ·Δλ, kₙ = 1/normal_mass).
    const dlambda = pt.normal_mass * (restitution_bias - v_n);
    const new_lambda = @max(@as(Real, 0), pt.normal_impulse + dlambda);
    const applied = new_lambda - pt.normal_impulse;
    pt.normal_impulse = new_lambda;
    applyImpulse(bm, c, pt.r_a, pt.r_b, c.normal.scale(applied));
    return applied != 0;
}

/// One Gauss-Seidel friction update for a contact point (run after the normal
/// update): two INDEPENDENT per-axis tangential impulses driving the tangential
/// velocity toward 0 (coupling ignored — Jolt convention), then a CIRCULAR clamp
/// of the accumulated `(λ_t1, λ_t2)` pair to the friction cone `‖λ_t‖ ≤ μ·λₙ`
/// (against the current accumulated normal impulse). The circular clamp is
/// isotropic and basis-independent — coherent with the world-space tangent cache;
/// the box clamp is anisotropic (up to √2·μ·λₙ on the diagonal) and basis-biased.
/// Returns whether a non-zero impulse was applied, at TRUE ZERO (see
/// `solveNormalPoint`).
fn solveFrictionPoint(bm: *BodyManager, c: *const ContactConstraint, pt: *cc.ConstraintPoint) bool {
    const v_a = bm.linearVelocity(c.body_a).?;
    const w_a = bm.angularVelocity(c.body_a).?;
    const v_b = bm.linearVelocity(c.body_b).?;
    const w_b = bm.angularVelocity(c.body_b).?;
    const v_rel = v_b.add(w_b.cross(pt.r_b)).sub(v_a.add(w_a.cross(pt.r_a)));

    // Independent per-axis tangential impulses driving each axis toward 0.
    const v_t1 = c.tangent1.dot(v_rel);
    const v_t2 = c.tangent2.dot(v_rel);
    var new_t1 = pt.tangent1_impulse - pt.tangent1_mass * v_t1;
    var new_t2 = pt.tangent2_impulse - pt.tangent2_mass * v_t2;

    // Circular (isotropic, basis-independent) clamp of the accumulated tangent
    // pair to the friction cone μ·λₙ — rescale the vector, never per-axis (the box
    // form is anisotropic, up to √2·μ·λₙ on the diagonal, and basis-biased). The
    // branch guarantees `len_sq > max_friction² ≥ 0`, so the √ divisor is nonzero.
    const max_friction = c.friction * pt.normal_impulse;
    const len_sq = new_t1 * new_t1 + new_t2 * new_t2;
    if (len_sq > max_friction * max_friction) {
        const scale = max_friction / @sqrt(len_sq);
        new_t1 *= scale;
        new_t2 *= scale;
    }

    // Apply the accumulated delta on both axes.
    const applied_t1 = new_t1 - pt.tangent1_impulse;
    const applied_t2 = new_t2 - pt.tangent2_impulse;
    pt.tangent1_impulse = new_t1;
    pt.tangent2_impulse = new_t2;
    const impulse = c.tangent1.scale(applied_t1).add(c.tangent2.scale(applied_t2));
    applyImpulse(bm, c, pt.r_a, pt.r_b, impulse);
    return applied_t1 != 0 or applied_t2 != 0;
}

// --- tests -------------------------------------------------------------------

const api = @import("weld_forge");
const foundation = @import("foundation");
const ShapeStore = bm_mod.ShapeStore;
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

fn pairKey(a: api.BodyId, b: api.BodyId) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// Two overlapping unit-mass spheres along +X (centres 0.9 apart, radii sum 1.0).
fn twoOverlappingSpheres(gpa: std.mem.Allocator, store: *ShapeStore, bm: *BodyManager) ![2]api.BodyId {
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    var db = descOf(1, .dynamic, s);
    db.mass = 1;
    db.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    const id_a = try bm.addBody(gpa, store, da);
    const id_b = try bm.addBody(gpa, store, db);
    return .{ id_a, id_b };
}

test "warm start applies the cached normal impulse and records a hit" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try twoOverlappingSpheres(gpa, &store, &bm);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
    try testing.expectEqual(@as(usize, 1), constraints.items.len);

    // Seed the cache with a known normal impulse for this contact's feature.
    var cache = ContactCache{};
    defer cache.deinit(gpa);
    try cache.store(gpa, .{
        .pair_key = constraints.items[0].pair_key,
        .feature_id = constraints.items[0].points[0].feature_id,
    }, .{ .lambda_n = 5, .tangent_impulse = Vec3r.zero });
    cache.endTick();

    cache.beginTick();
    warmStart(&bm, &cache, constraints.items);

    // λₙ = 5 seeded; applied along n = +X ⇒ A gets −5X (inv_mass 1), B gets +5X.
    try testing.expectApproxEqAbs(@as(Real, 5), constraints.items[0].points[0].normal_impulse, 1e-5);
    try testing.expectApproxEqAbs(@as(Real, -5), bm.linearVelocity(ids[0]).?.toArray()[0], 1e-5);
    try testing.expectApproxEqAbs(@as(Real, 5), bm.linearVelocity(ids[1]).?.toArray()[0], 1e-5);
    try testing.expectEqual(@as(u32, 1), cache.hits);
}

test "warm start cold-starts and records a miss on an unknown key" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try twoOverlappingSpheres(gpa, &store, &bm);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

    var cache = ContactCache{}; // empty ⇒ every lookup misses
    defer cache.deinit(gpa);
    cache.beginTick();
    warmStart(&bm, &cache, constraints.items);

    try testing.expectEqual(@as(Real, 0), constraints.items[0].points[0].normal_impulse);
    try testing.expect(bm.linearVelocity(ids[0]).?.approxEql(Vec3r.zero, 0)); // unchanged
    try testing.expectEqual(@as(u32, 1), cache.misses);
}

test "warm start reprojects the cached world tangent onto the new normal plane" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try twoOverlappingSpheres(gpa, &store, &bm); // both friction default 0.5

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

    // The contact normal is +X. Inject a cached world tangent with a LARGE
    // component along the normal (X) and a small in-plane component (Y): the raw
    // magnitude far exceeds μ·λₙ = 0.5, but the IN-PLANE magnitude 0.3 is below
    // it. Reprojecting first clamps the in-plane part (0.3 < 0.5 ⇒ preserved);
    // clamping the RAW magnitude would wrongly shrink the in-plane part.
    var cache = ContactCache{};
    defer cache.deinit(gpa);
    try cache.store(gpa, .{
        .pair_key = constraints.items[0].pair_key,
        .feature_id = constraints.items[0].points[0].feature_id,
    }, .{ .lambda_n = 1, .tangent_impulse = vr(4.0, 0.3, 0.0) });
    cache.endTick();

    cache.beginTick();
    warmStart(&bm, &cache, constraints.items);

    // t1 = +Y, t2 = +Z for n = +X ⇒ the in-plane part decomposes to λ_t1 = 0.3.
    try testing.expectApproxEqAbs(@as(Real, 0.3), constraints.items[0].points[0].tangent1_impulse, 1e-5);
    try testing.expectApproxEqAbs(@as(Real, 0), constraints.items[0].points[0].tangent2_impulse, 1e-5);
}

test "solved impulses round-trip through the cache to the next tick's warm start" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try twoOverlappingSpheres(gpa, &store, &bm);
    const key = pairKey(ids[0], ids[1]);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    var cache = ContactCache{};
    defer cache.deinit(gpa);

    // Tick 1: build, simulate a solve (λₙ = 7), harvest into the cache, finalize.
    cache.beginTick();
    try cc.build(gpa, &constraints, &bm, &store, &.{key});
    constraints.items[0].points[0].normal_impulse = 7;
    try storeContacts(gpa, &cache, constraints.items);
    cache.endTick();

    // Tick 2: rebuild (impulses reset to 0), warm start seeds from tick 1.
    cache.beginTick();
    try cc.build(gpa, &constraints, &bm, &store, &.{key});
    try testing.expectEqual(@as(Real, 0), constraints.items[0].points[0].normal_impulse); // fresh
    warmStart(&bm, &cache, constraints.items);

    try testing.expectApproxEqAbs(@as(Real, 7), constraints.items[0].points[0].normal_impulse, 1e-5);
    try testing.expectEqual(@as(u32, 1), cache.hits);
}

/// Dynamic sphere A at origin + static sphere B at +0.9X (overlapping along +X),
/// both with restitution `e`. The caller sets A's approach velocity, builds, and
/// solves.
fn sphereHitScene(gpa: std.mem.Allocator, store: *ShapeStore, bm: *BodyManager, e: f32) ![2]api.BodyId {
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    da.restitution = e;
    var db = descOf(1, .static, s);
    db.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    db.restitution = e;
    const id_a = try bm.addBody(gpa, store, da);
    const id_b = try bm.addBody(gpa, store, db);
    return .{ id_a, id_b };
}

test "solver config defaults" {
    const cfg = SolverConfig{};
    // 16 since M1.1.7 (was 8 at M1.1.6): a 3D face patch is four points and a
    // five-deep stack forty, and 8 does not bring such a stack to rest. See the
    // field's doc in `solver_config.zig`.
    try testing.expectEqual(@as(u32, 16), cfg.velocity_iterations);
    try testing.expectEqual(@as(Real, 1), cfg.restitution_threshold);
}

test "normal solve kills the approach velocity at e = 0" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try sphereHitScene(gpa, &store, &bm, 0);
    bm.setLinearVelocity(ids[0], vr(3, 0, 0)); // approaching +X

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
    solveRange(&bm, constraints.items, 0, constraints.items.len, .{});

    // Approach killed; the static body never moves; λₙ respected the Catto clamp.
    try testing.expectApproxEqAbs(@as(Real, 0), bm.linearVelocity(ids[0]).?.toArray()[0], 1e-5);
    try testing.expect(bm.linearVelocity(ids[1]).?.approxEql(Vec3r.zero, 0));
    try testing.expect(constraints.items[0].points[0].normal_impulse >= 0);
}

test "restitution bounces above the threshold and is inert below it" {
    const gpa = testing.allocator;

    // Above threshold: 3 m/s approach, e = 0.8 ⇒ rebound at 0.8·3 = 2.4 m/s (−X).
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const ids = try sphereHitScene(gpa, &store, &bm, 0.8);
        bm.setLinearVelocity(ids[0], vr(3, 0, 0));
        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
        solveRange(&bm, constraints.items, 0, constraints.items.len, .{});
        try testing.expectApproxEqAbs(@as(Real, -2.4), bm.linearVelocity(ids[0]).?.toArray()[0], 1e-4);
    }

    // Below threshold: 0.5 m/s approach < 1.0 ⇒ no bounce, approach killed.
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const ids = try sphereHitScene(gpa, &store, &bm, 0.8);
        bm.setLinearVelocity(ids[0], vr(0.5, 0, 0));
        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
        solveRange(&bm, constraints.items, 0, constraints.items.len, .{});
        try testing.expectApproxEqAbs(@as(Real, 0), bm.linearVelocity(ids[0]).?.toArray()[0], 1e-5);
    }
}

test "accumulated normal impulse stays non-negative (Catto clamp)" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try sphereHitScene(gpa, &store, &bm, 0);
    bm.setLinearVelocity(ids[0], vr(-3, 0, 0)); // moving AWAY (separating)

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
    solveRange(&bm, constraints.items, 0, constraints.items.len, .{});

    // A separating contact needs no push: the clamp keeps λₙ at 0 (never pulls)
    // and A keeps moving away unchanged.
    try testing.expectEqual(@as(Real, 0), constraints.items[0].points[0].normal_impulse);
    try testing.expectApproxEqAbs(@as(Real, -3), bm.linearVelocity(ids[0]).?.toArray()[0], 1e-5);
}

test "solveRange solves only the given constraint index range" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Pair (0,1) near the origin, pair (2,3) ten metres away — both a dynamic A
    // approaching a static B along +X. pair_key(0,1) = 1 < pair_key(2,3), so the
    // first pair is constraint 0.
    var a0 = descOf(0, .dynamic, s);
    a0.mass = 1;
    a0.restitution = 0;
    var b0 = descOf(1, .static, s);
    b0.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    b0.restitution = 0;
    var a1 = descOf(2, .dynamic, s);
    a1.mass = 1;
    a1.restitution = 0;
    a1.position = foundation.math.Vec3.fromArray(.{ 10, 0, 0 });
    var b1 = descOf(3, .static, s);
    b1.position = foundation.math.Vec3.fromArray(.{ 10.9, 0, 0 });
    b1.restitution = 0;
    const id_a0 = try bm.addBody(gpa, &store, a0);
    const id_b0 = try bm.addBody(gpa, &store, b0);
    const id_a1 = try bm.addBody(gpa, &store, a1);
    const id_b1 = try bm.addBody(gpa, &store, b1);
    bm.setLinearVelocity(id_a0, vr(3, 0, 0));
    bm.setLinearVelocity(id_a1, vr(3, 0, 0));

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{ pairKey(id_a0, id_b0), pairKey(id_a1, id_b1) });
    try testing.expectEqual(@as(usize, 2), constraints.items.len);

    // Solve only the first constraint's range; the second pair is untouched.
    solveRange(&bm, constraints.items, 0, 1, .{});

    try testing.expectApproxEqAbs(@as(Real, 0), bm.linearVelocity(id_a0).?.toArray()[0], 1e-5);
    try testing.expectApproxEqAbs(@as(Real, 3), bm.linearVelocity(id_a1).?.toArray()[0], 1e-5);
}

test "capture-time separating contact still enforces non-penetration" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try sphereHitScene(gpa, &store, &bm, 0.8);

    // At capture (build/prepare) the contact is SEPARATING faster than the
    // threshold (v_n⁻ = +3 > 1.0), so restitution must NOT arm here — a bias
    // keyed on |v_n⁻| would (wrongly) target a NEGATIVE separating speed.
    bm.setLinearVelocity(ids[0], vr(-3, 0, 0));
    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

    // The body then actually approaches at solve time (relative v_n = −2). A
    // capture-time separating velocity must not grant a penetration allowance:
    // the solve must still drive v_n to rest (≈ 0), never to a negative target.
    bm.setLinearVelocity(ids[0], vr(2, 0, 0));
    solveRange(&bm, constraints.items, 0, constraints.items.len, .{});

    const c = constraints.items[0];
    const va = bm.linearVelocity(ids[0]).?;
    const wa = bm.angularVelocity(ids[0]).?;
    const vb = bm.linearVelocity(ids[1]).?;
    const wb = bm.angularVelocity(ids[1]).?;
    const v_rel = vb.add(wb.cross(c.points[0].r_b)).sub(va.add(wa.cross(c.points[0].r_a)));
    const v_n = c.normal.dot(v_rel);
    try testing.expectApproxEqAbs(@as(Real, 0), v_n, 1e-4);
}

test "friction cancels tangential sliding below the cone" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    da.friction = 1;
    var db = descOf(1, .dynamic, s);
    db.mass = 1;
    db.friction = 1;
    db.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    const id_a = try bm.addBody(gpa, &store, da);
    const id_b = try bm.addBody(gpa, &store, db);
    bm.setLinearVelocity(id_a, vr(0, 2, 0)); // sliding tangentially (+Y)

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});
    const c = &constraints.items[0];
    c.points[0].normal_impulse = 10; // large λₙ ⇒ wide cone ⇒ no clamp
    _ = solveFrictionPoint(&bm, c, &c.points[0]);

    // The relative contact-point tangential velocity is driven to ≈ 0.
    const va = bm.linearVelocity(id_a).?;
    const wa = bm.angularVelocity(id_a).?;
    const vb = bm.linearVelocity(id_b).?;
    const wb = bm.angularVelocity(id_b).?;
    const v_rel = vb.add(wb.cross(c.points[0].r_b)).sub(va.add(wa.cross(c.points[0].r_a)));
    try testing.expectApproxEqAbs(@as(Real, 0), c.tangent1.dot(v_rel), 1e-5);
    try testing.expectApproxEqAbs(@as(Real, 0), c.tangent2.dot(v_rel), 1e-5);
}

/// Clamped friction impulse magnitude for a body sliding at `slide` against a
/// fixed normal impulse λₙ = 1 (cone μ·λₙ = 1). Used to compare slide directions.
fn frictionMagnitude(gpa: std.mem.Allocator, slide: Vec3r) !Real {
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    da.friction = 1;
    var db = descOf(1, .dynamic, s);
    db.mass = 1;
    db.friction = 1;
    db.position = foundation.math.Vec3.fromArray(.{ 0.9, 0, 0 });
    const id_a = try bm.addBody(gpa, &store, da);
    const id_b = try bm.addBody(gpa, &store, db);
    bm.setLinearVelocity(id_a, slide);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(id_a, id_b)});
    const c = &constraints.items[0];
    c.points[0].normal_impulse = 1;
    _ = solveFrictionPoint(&bm, c, &c.points[0]);
    const pt = c.points[0];
    return @sqrt(pt.tangent1_impulse * pt.tangent1_impulse + pt.tangent2_impulse * pt.tangent2_impulse);
}

test "friction clamp is isotropic (circular, basis-independent)" {
    const gpa = testing.allocator;
    // Slide fast (10 m/s) so the cone μ·λₙ = 1 clamps. Along a single tangent axis
    // vs the tangent-plane diagonal must yield the SAME clamped magnitude (circular
    // clamp); a box clamp would give √2 on the diagonal.
    const along = try frictionMagnitude(gpa, vr(0, 10, 0));
    const diagonal = try frictionMagnitude(gpa, vr(0, 7.0710678, 7.0710678));
    try testing.expectApproxEqAbs(@as(Real, 1), along, 1e-4); // clamped to μ·λₙ = 1
    try testing.expectApproxEqAbs(along, diagonal, 1e-4); // isotropic
}

/// A dynamic unit-mass sphere at the origin overlapping a STATIC one at +0.9X, with
/// zero restitution. The lever arm is parallel to the normal, so the rotational term
/// of the effective mass vanishes exactly and the single-contact solve is exact
/// arithmetic at both precisions — which is what lets the iteration counts below be
/// asserted as equalities rather than bounds.
fn earlyOutScene(gpa: std.mem.Allocator, store: *ShapeStore, bm: *BodyManager, approach: Real) ![2]api.BodyId {
    const ids = try sphereHitScene(gpa, store, bm, 0);
    bm.setLinearVelocity(ids[0], vr(approach, 0, 0));
    return ids;
}

test "the velocity pass stops as soon as an iteration applies nothing" {
    const gpa = testing.allocator;

    // Approaching: the single contact converges in a couple of iterations and the
    // pass ends well short of its budget. The exact count is NOT asserted — it is the
    // last-bit behaviour of a float convergence and legitimately differs between f32
    // and f64. What is asserted is the contract: the pass stops early, and once
    // stopped the state is a fixed point — solving it again spends exactly ONE
    // iteration, the one that finds nothing to apply, and moves nothing.
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const ids = try earlyOutScene(gpa, &store, &bm, 3);
        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

        const cfg = SolverConfig{};
        const first = solveRangeReport(&bm, constraints.items, 0, constraints.items.len, cfg);
        try testing.expect(first.iterations_run < cfg.velocity_iterations);
        try testing.expectApproxEqAbs(@as(Real, 0), bm.linearVelocity(ids[0]).?.toArray()[0], 1e-6);

        const settled = bm.linearVelocity(ids[0]).?.toArray();
        const again = solveRangeReport(&bm, constraints.items, 0, constraints.items.len, cfg);
        try testing.expectEqual(@as(u32, 1), again.iterations_run);
        inline for (0..3) |k| {
            try testing.expectEqual(settled[k], bm.linearVelocity(ids[0]).?.toArray()[k]);
        }
    }

    // Separating: the Catto clamp holds λₙ at zero and friction's cone is zero-wide,
    // so the very first iteration applies nothing at all.
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const ids = try earlyOutScene(gpa, &store, &bm, -3);
        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

        const result = solveRangeReport(&bm, constraints.items, 0, constraints.items.len, .{});
        try testing.expectEqual(@as(u32, 1), result.iterations_run);
    }

    // A zero budget is legal and runs nothing (warm start only).
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const ids = try earlyOutScene(gpa, &store, &bm, 3);
        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

        const result = solveRangeReport(&bm, constraints.items, 0, constraints.items.len, .{ .velocity_iterations = 0 });
        try testing.expectEqual(@as(u32, 0), result.iterations_run);
        try testing.expectEqual(@as(Real, 3), bm.linearVelocity(ids[0]).?.toArray()[0]); // untouched
    }
}

/// Solve `earlyOutScene` with `iterations` of budget and return the resulting
/// velocity of the dynamic body plus the telemetry.
fn solveWithBudget(gpa: std.mem.Allocator, iterations: u32) !struct { velocity: Vec3r, result: VelocitySolveResult } {
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try earlyOutScene(gpa, &store, &bm, 3);
    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});
    const result = solveRangeReport(&bm, constraints.items, 0, constraints.items.len, .{ .velocity_iterations = iterations });
    return .{ .velocity = bm.linearVelocity(ids[0]).?, .result = result };
}

/// A static ground carrying three stacked dynamic boxes, all driven downward —
/// multi-point face-face manifolds in a chain, so the impulse has to propagate from
/// the ground up and the pass does NOT converge in a couple of iterations. Returns
/// the top box's velocity and the telemetry.
fn solveStackWithBudget(gpa: std.mem.Allocator, iterations: u32) !struct { velocity: Vec3r, result: VelocitySolveResult } {
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = foundation.math.Vec3.fromArray(.{ 0.5, 0.5, 0.5 }) } });
    const ground_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = foundation.math.Vec3.fromArray(.{ 20, 0.5, 20 }) } });

    const ground = try bm.addBody(gpa, &store, descOf(0, .static, ground_shape));
    var ids: [3]api.BodyId = undefined;
    for (0..3) |i| {
        var d = descOf(@intCast(i + 1), .dynamic, box_shape);
        d.mass = 1;
        d.position = foundation.math.Vec3.fromArray(.{ 0, 0.99 + @as(f32, @floatFromInt(i)) * 0.99, 0 });
        ids[i] = try bm.addBody(gpa, &store, d);
        bm.setLinearVelocity(ids[i], vr(0, -2, 0));
    }

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try cc.build(gpa, &constraints, &bm, &store, &.{
        pairKey(ground, ids[0]), pairKey(ids[0], ids[1]), pairKey(ids[1], ids[2]),
    });
    const result = solveRangeReport(&bm, constraints.items, 0, constraints.items.len, .{ .velocity_iterations = iterations });
    return .{ .velocity = bm.linearVelocity(ids[2]).?, .result = result };
}

test "the early-out is bit-exact against a larger iteration budget" {
    const gpa = testing.allocator;

    // The equivalence claim: once an iteration applies nothing, every further
    // iteration reads an identical state and likewise applies nothing. So raising
    // the budget past the early-out cannot change the answer — bit for bit.
    const at_16 = try solveWithBudget(gpa, 16);
    const at_64 = try solveWithBudget(gpa, 64);
    try testing.expect(at_16.result.iterations_run < 16); // the early-out really fired
    try testing.expectEqual(at_16.result.iterations_run, at_64.result.iterations_run);
    inline for (0..3) |k| {
        try testing.expectEqual(at_16.velocity.toArray()[k], at_64.velocity.toArray()[k]);
    }

    // Discrimination guard. On a scene that does NOT converge inside the budget the
    // count genuinely matters: the pass runs to the ceiling and 4 iterations give a
    // different velocity from 16. So the bit-identity above is the early-out being
    // exact, not the iteration count being irrelevant.
    const stack_4 = try solveStackWithBudget(gpa, 4);
    const stack_16 = try solveStackWithBudget(gpa, 16);
    try testing.expectEqual(@as(u32, 4), stack_4.result.iterations_run); // ceiling reached
    try testing.expect(!stack_4.velocity.approxEql(stack_16.velocity, 1e-6));
}
