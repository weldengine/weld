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
