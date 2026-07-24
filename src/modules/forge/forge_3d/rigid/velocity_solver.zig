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
//! `../body_manager.zig`, sibling `contact_constraint.zig`/`contact_cache.zig`.
//! Velocities are read/written through `BodyManager`'s stale-safe getters/setters
//! (immediate Gauss-Seidel propagation across contacts and points).

const std = @import("std");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const cc = @import("contact_constraint.zig");
const cache_mod = @import("contact_cache.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyManager = bm_mod.BodyManager;
const ContactConstraint = cc.ContactConstraint;
const ContactCache = cache_mod.ContactCache;

/// Velocity-solver tuning.
pub const SolverConfig = struct {
    /// Gauss-Seidel velocity iteration passes per tick (named for the M1.1.7
    /// `position_iterations` sibling).
    velocity_iterations: u32 = 8,
    /// Restitution cutoff (m/s): a bounce is applied only when the pre-solve
    /// relative normal speed exceeds this — a PHYSICAL velocity constant (config
    /// field), not a geometric epsilon. Below it, low-speed contacts settle
    /// without jitter.
    restitution_threshold: Real = 1.0,
};

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

/// Solve the velocity constraints over the constraint index range `[from, to)`
/// with `cfg.velocity_iterations` Gauss-Seidel passes. Constraints are visited in
/// ascending pair-key order (as `build` sorted them) and points in manifold
/// order. M1.1.6 always passes the full range; the explicit range is the
/// island-additivity seam (M1.1.8 sorts constraints into contiguous per-island
/// ranges — purely additive).
pub fn solveRange(bm: *BodyManager, constraints: []ContactConstraint, from: usize, to: usize, cfg: SolverConfig) void {
    var iter: u32 = 0;
    while (iter < cfg.velocity_iterations) : (iter += 1) {
        for (constraints[from..to]) |*c| {
            for (0..c.count) |i| {
                solveNormalPoint(bm, c, &c.points[i], cfg);
            }
        }
    }
}

/// One Gauss-Seidel normal-impulse update for a contact point: drive the relative
/// normal velocity toward its restitution target, with the accumulated-impulse
/// clamp `λₙ ≥ 0` (Catto — the solver can only push, never pull).
fn solveNormalPoint(bm: *BodyManager, c: *const ContactConstraint, pt: *cc.ConstraintPoint, cfg: SolverConfig) void {
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
    try testing.expectEqual(@as(u32, 8), cfg.velocity_iterations);
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
