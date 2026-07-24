//! M1.1.6 acceptance suite for the Sequential Impulses contact solver.
//!
//! `World` composes the full per-tick pipeline IN TESTS ONLY (the production
//! `step()` orchestration is M1.1.15). Normative per-tick cycle (brief E6):
//!   (1) `Broadphase.computePairs` on the current poses (moved-driven deltas)
//!   (2) narrowphase `collidePair` per candidate — done inside `rigid.build`
//!   (3) `integrateVelocities(dt, gravity)`
//!   (4) `cache.beginTick` → `build` + `prepare` (captures v_n⁻) → `warmStart`
//!       → `solveRange` × `velocity_iterations`
//!   (5) `integratePositions(dt)`
//!   (6) `storeContacts` (harvest) → `cache.endTick` (sort + swap)
//!   (7) broadphase proxy updates.
//!
//! `computePairs` is moved-driven (it reports only pairs touching a proxy that
//! moved since the last call), so the harness keeps a PERSISTENT candidate set
//! (`active`, a sorted-deduped key list): it merges each tick's deltas and, after
//! the solve, retains only the pairs that produced a constraint (contacting
//! ones), so a resting contact — whose proxies stop moving and thus stop being
//! reported — stays live and keeps being solved (no sinking). A real `step()` /
//! `PhysicsWorld` at M1.1.15 owns the same persistent pair set.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const broadphase = @import("../pipeline/broadphase.zig");
const integration = @import("../pipeline/integration.zig");
const rigid = @import("../rigid/root.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const BodyId = api.BodyId;
const Bp = broadphase.Broadphase(Real);
const ContactConstraint = rigid.ContactConstraint;
const ContactCache = rigid.ContactCache;
const SolverConfig = rigid.SolverConfig;
const testing = std.testing;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

fn broadphaseLayer(bt: api.BodyType) broadphase.BroadphaseLayer {
    return if (bt == .static) .static else .dynamic;
}

fn sortDedup(list: *std.ArrayListUnmanaged(u64)) void {
    std.mem.sort(u64, list.items, {}, std.sort.asc(u64));
    if (list.items.len == 0) return;
    var w: usize = 1;
    var i: usize = 1;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] != list.items[w - 1]) {
            list.items[w] = list.items[i];
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

const BodyProxy = struct { id: BodyId, proxy: Bp.Proxy };

/// A minimal physics world composing the full contact-solver pipeline for tests.
const World = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    bp: Bp,
    cache: ContactCache = .{},
    cfg: SolverConfig = .{},
    gravity: Vec3r,
    dt: Real,
    bodies: std.ArrayListUnmanaged(BodyProxy) = .empty,
    active: std.ArrayListUnmanaged(u64) = .empty,
    constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty,
    scratch: std.ArrayListUnmanaged(Bp.Pair) = .empty,

    fn init(gravity: Vec3r, dt: Real) World {
        return .{ .bp = Bp.init(.{}), .gravity = gravity, .dt = dt };
    }

    fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
        self.bp.deinit(gpa);
        self.cache.deinit(gpa);
        self.bodies.deinit(gpa);
        self.active.deinit(gpa);
        self.constraints.deinit(gpa);
        self.scratch.deinit(gpa);
        self.* = undefined;
    }

    fn addBody(self: *World, gpa: std.mem.Allocator, desc: api.BodyDescriptor) !BodyId {
        const id = try self.bm.addBody(gpa, &self.store, desc);
        const aabb = self.bm.bodyAabb(&self.store, id).?;
        const proxy = try self.bp.insert(gpa, broadphaseLayer(desc.body_type), aabb, id);
        try self.bodies.append(gpa, .{ .id = id, .proxy = proxy });
        return id;
    }

    fn step(self: *World, gpa: std.mem.Allocator) !void {
        // (1) broadphase candidate deltas → persistent active set.
        try self.bp.computePairs(gpa, &self.scratch);
        for (self.scratch.items) |p| try self.active.append(gpa, (@as(u64, p.a) << 32) | p.b);
        sortDedup(&self.active);

        // (3) integrate velocities (gravity + accumulators + clamped damping).
        integration.integrateVelocities(&self.bm, self.dt, self.gravity);

        // (4) solve: prepare captures v_n⁻ (post-gravity), then warm start + iterate.
        self.cache.beginTick();
        try rigid.build(gpa, &self.constraints, &self.bm, &self.store, self.active.items);
        rigid.warmStart(&self.bm, &self.cache, self.constraints.items);
        rigid.solveRange(&self.bm, self.constraints.items, 0, self.constraints.items.len, self.cfg);

        // (5) integrate positions from the solved velocities.
        integration.integratePositions(&self.bm, self.dt);

        // (6) harvest solved impulses into the cache, then finalize (sort + swap).
        try rigid.storeContacts(gpa, &self.cache, self.constraints.items);
        self.cache.endTick();

        // Persist only contacting pairs; separated ones drop (re-added by
        // computePairs when their proxies move back into overlap).
        self.active.clearRetainingCapacity();
        for (self.constraints.items) |c| try self.active.append(gpa, c.pair_key);

        // (7) broadphase proxy updates to the new poses.
        for (self.bodies.items) |b| {
            if (self.bm.bodyAabb(&self.store, b.id)) |aabb| try self.bp.update(gpa, b.proxy, aabb);
        }
    }
};

/// Ground (static box, top at y = 0.5) + a dynamic unit box dropped from y = `drop_y`.
/// Returns the dynamic box's BodyId. Restitution `e` on both.
fn groundAndBox(gpa: std.mem.Allocator, world: *World, drop_y: Real, e: f32) !BodyId {
    const ground_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

    var ground = api.BodyDescriptor{ .entity = .{ .index = 0, .generation = 0 }, .body_type = .static, .shape = ground_shape };
    ground.restitution = e;
    _ = try world.addBody(gpa, ground); // centre at origin ⇒ top face at y = 0.5

    var box = api.BodyDescriptor{ .entity = .{ .index = 1, .generation = 0 }, .body_type = .dynamic, .shape = box_shape };
    box.mass = 1;
    box.restitution = e;
    box.position = av3(0, @floatCast(drop_y), 0);
    return world.addBody(gpa, box);
}

test "box dropped on a static ground comes to rest without sinking (e = 0)" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 2.0, 0);

    // Settle (2 s).
    var t: u32 = 0;
    while (t < 120) : (t += 1) try world.step(gpa);
    const y_settled = world.bm.position(box).?.toArray()[1];

    // Run 3 more seconds — the box must not sink further.
    while (t < 300) : (t += 1) try world.step(gpa);
    const y_final = world.bm.position(box).?.toArray()[1];
    const v_final = world.bm.linearVelocity(box).?.toArray()[1];

    // Analytical rest y = ground_top(0.5) + box_half(0.5) = 1.0; the velocity
    // solver leaves a small constant penetration (no NGS recovery until M1.1.7).
    try testing.expect(y_final > 0.5); // never fell through
    try testing.expect(y_final < 1.02); // resting at/near the contact
    try testing.expect(y_final > 0.8); // penetration bounded (< 0.2)
    try testing.expect(@abs(y_final - y_settled) < 1e-3); // no sinking after settling
    try testing.expect(@abs(v_final) < 0.05); // at rest
}

test "solve is deterministic across identical runs" {
    const gpa = testing.allocator;

    var w1 = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer w1.deinit(gpa);
    const b1 = try groundAndBox(gpa, &w1, 2.0, 0.5);
    var w2 = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer w2.deinit(gpa);
    const b2 = try groundAndBox(gpa, &w2, 2.0, 0.5);

    var t: u32 = 0;
    while (t < 300) : (t += 1) {
        try w1.step(gpa);
        try w2.step(gpa);
    }

    const p1 = w1.bm.position(b1).?.toArray();
    const p2 = w2.bm.position(b2).?.toArray();
    const v1 = w1.bm.linearVelocity(b1).?.toArray();
    const v2 = w2.bm.linearVelocity(b2).?.toArray();
    const q1 = w1.bm.rotation(b1).?.toArray();
    const q2 = w2.bm.rotation(b2).?.toArray();
    inline for (0..3) |k| {
        try testing.expectEqual(p1[k], p2[k]);
        try testing.expectEqual(v1[k], v2[k]);
    }
    inline for (0..4) |k| try testing.expectEqual(q1[k], q2[k]);
}

/// Max upward (+Y) velocity the dropped box reaches over `ticks` — the rebound
/// speed after impact (≈ 0 when it does not bounce).
fn maxReboundVy(gpa: std.mem.Allocator, drop_y: Real, e: f32, ticks: u32) !Real {
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, drop_y, e);
    var max_vy: Real = -1e30;
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        try world.step(gpa);
        const vy = world.bm.linearVelocity(box).?.toArray()[1];
        if (vy > max_vy) max_vy = vy;
    }
    return max_vy;
}

test "restitution bounces above the threshold and not below it" {
    const gpa = testing.allocator;
    // Drop from 2 m ⇒ impact ≈ 4.4 m/s > 1.0 threshold, e = 0.8 ⇒ strong rebound.
    const high = try maxReboundVy(gpa, 2.0, 0.8, 120);
    try testing.expect(high > 2.0);
    // A box resting flush only ever approaches at the per-tick gravity speed
    // (≈ 0.16 m/s ≪ the 1.0 threshold), so it settles without a bounce. (The
    // genuine sub-threshold IMPACT case is pinned exactly by the E4 unit test.)
    const low = try maxReboundVy(gpa, 1.0, 0.8, 120);
    try testing.expect(low < 0.5);
}

test "restitution is captured before warm start" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 1.0, 0.8); // starts flush, e = 0.8

    // Rest for 1 s: the per-tick gravity approach (≈ 0.16 m/s) is below the
    // restitution threshold, so the box settles and the cache warms up.
    var t: u32 = 0;
    while (t < 60) : (t += 1) try world.step(gpa);
    try testing.expect(world.cache.hits > 0); // warm start is matching the resting contact
    try testing.expect(@abs(world.bm.linearVelocity(box).?.toArray()[1]) < 0.05); // resting

    // A real downward impact after resting: v_n⁻ is captured (in `prepare`) BEFORE
    // `warmStart`, so the warm-started resting impulse does NOT suppress the bounce.
    world.bm.setLinearVelocity(box, vr(0, -3, 0));
    var max_vy: Real = -1e30;
    t = 0;
    while (t < 60) : (t += 1) {
        try world.step(gpa);
        const vy = world.bm.linearVelocity(box).?.toArray()[1];
        if (vy > max_vy) max_vy = vy;
    }
    try testing.expect(max_vy > 1.5); // bounced (≈ e·3 = 2.4)
}

/// Along-surface displacement of a box placed flush on a static incline (rotated
/// θ about Z) with combined friction from `mu`, after `ticks`.
fn inclineDrift(gpa: std.mem.Allocator, theta: Real, mu: f32, ticks: u32) !Real {
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const rot = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), @floatCast(theta));

    var ground = api.BodyDescriptor{ .entity = .{ .index = 0, .generation = 0 }, .body_type = .static, .shape = ground_shape };
    ground.rotation = rot;
    ground.friction = mu;
    _ = try world.addBody(gpa, ground);

    // Box flush on the incline: centre at R·(0,1,0) (ground half + box half), same rotation.
    var box = api.BodyDescriptor{ .entity = .{ .index = 1, .generation = 0 }, .body_type = .dynamic, .shape = box_shape };
    box.mass = 1;
    box.friction = mu;
    box.rotation = rot;
    box.position = rot.rotateVec3(av3(0, 1, 0));
    const box_id = try world.addBody(gpa, box);

    const p0 = world.bm.position(box_id).?;
    var t: u32 = 0;
    while (t < ticks) : (t += 1) try world.step(gpa);
    return world.bm.position(box_id).?.sub(p0).length();
}

test "inclined static box holds below the friction angle and slides above it" {
    const gpa = testing.allocator;
    const theta = std.math.pi / 6.0; // 30° ⇒ tan θ ≈ 0.577
    const holds = try inclineDrift(gpa, theta, 0.8, 180); // μ = 0.8 > tan θ ⇒ holds
    const slides = try inclineDrift(gpa, theta, 0.3, 180); // μ = 0.3 < tan θ ⇒ slides
    try testing.expect(holds < 0.1);
    try testing.expect(slides > 0.5);
}

/// Horizontal speed of a box sliding on flat ground after `ticks`, given the
/// initial horizontal velocity `v0` (default friction 0.5 on both).
fn slideSpeedAfter(gpa: std.mem.Allocator, v0: Vec3r, ticks: u32) !Real {
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 1.0, 0); // starts flush on the ground
    world.bm.setLinearVelocity(box, v0);
    var t: u32 = 0;
    while (t < ticks) : (t += 1) try world.step(gpa);
    const v = world.bm.linearVelocity(box).?.toArray();
    return @sqrt(v[0] * v[0] + v[2] * v[2]);
}

test "friction deceleration is isotropic on flat ground" {
    const gpa = testing.allocator;
    // Same initial speed (3 m/s) along +X vs the XZ diagonal must decay equally —
    // the circular clamp is basis-independent.
    const along = try slideSpeedAfter(gpa, vr(3, 0, 0), 20);
    const diagonal = try slideSpeedAfter(gpa, vr(2.1213203, 0, 2.1213203), 20);
    try testing.expectApproxEqAbs(along, diagonal, 1e-2);
}

// --- constraint/cache-level scenarios (direct build, no broadphase) -----------

fn descOf(idx: u32, bt: api.BodyType, shape: api.ShapeId) api.BodyDescriptor {
    return .{ .entity = .{ .index = idx, .generation = 0 }, .body_type = bt, .shape = shape };
}

fn pairKey(a: BodyId, b: BodyId) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// Warm-start a single sphere contact whose normal is `normalize(n_dir)` with a
/// cached WORLD tangent `t_world`, and return the reconstructed applied tangent
/// (λ_t1·t1 + λ_t2·t2) — the world tangent seeded into the new basis.
fn reconstructWarmTangent(gpa: std.mem.Allocator, n_dir: foundation.math.Vec3, t_world: Vec3r) !Vec3r {
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var da = descOf(0, .dynamic, s);
    da.friction = 1;
    var db = descOf(1, .dynamic, s);
    db.friction = 1;
    db.position = n_dir.normalize().scale(0.9); // overlap along n_dir ⇒ normal ≈ n̂
    const a = try bm.addBody(gpa, &store, da);
    const b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)});
    const c = &constraints.items[0];

    var cache = ContactCache{};
    defer cache.deinit(gpa);
    try cache.store(gpa, .{ .pair_key = c.pair_key, .feature_id = c.points[0].feature_id }, .{ .lambda_n = 10, .tangent_impulse = t_world });
    cache.endTick();
    cache.beginTick();
    rigid.warmStart(&bm, &cache, constraints.items);
    return c.tangent1.scale(c.points[0].tangent1_impulse).add(c.tangent2.scale(c.points[0].tangent2_impulse));
}

test "warm-started tangent is continuous across a tangent-basis flip" {
    const gpa = testing.allocator;
    // Two normals straddling the x = y dominant-axis boundary (so the tangent
    // basis flips discontinuously). The cached WORLD tangent must reconstruct to
    // the SAME world direction for both — a per-basis-scalar cache would rotate it.
    const t_world = vr(0.3, -0.3, 0.5);
    const r1 = try reconstructWarmTangent(gpa, av3(1.0, 1.02, 0.0), t_world); // y-dominant
    const r2 = try reconstructWarmTangent(gpa, av3(1.02, 1.0, 0.0), t_world); // x-dominant
    try testing.expect(r1.approxEql(r2, 1e-2));
}

test "kinematic-static contact produces no constraint and no NaN" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const a = try bm.addBody(gpa, &store, descOf(0, .static, s));
    var db = descOf(1, .kinematic, s);
    db.position = av3(0.9, 0, 0);
    const b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)});
    rigid.solveRange(&bm, constraints.items, 0, constraints.items.len, .{});

    try testing.expectEqual(@as(usize, 0), constraints.items.len);
    for (bm.position(a).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
    for (bm.position(b).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
    for (bm.linearVelocity(b).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
}

test "warm start hits a resting contact and misses on generation reuse" {
    const gpa = testing.allocator;

    // Part A: a resting box in the full pipeline warm-starts (cache hits > 0).
    {
        var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
        defer world.deinit(gpa);
        _ = try groundAndBox(gpa, &world, 1.0, 0);
        var t: u32 = 0;
        while (t < 60) : (t += 1) try world.step(gpa);
        try testing.expect(world.cache.hits > 0);
    }

    // Part B: reusing a freed slot bumps the generation ⇒ a new BodyId ⇒ a new
    // pair_key ⇒ the previous tick's cache entry no longer matches (cold start).
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
        const a = try bm.addBody(gpa, &store, descOf(0, .dynamic, s));
        var db = descOf(1, .dynamic, s);
        db.position = av3(0.9, 0, 0);
        const b = try bm.addBody(gpa, &store, db);

        var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        var cache = ContactCache{};
        defer cache.deinit(gpa);

        cache.beginTick();
        try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)});
        constraints.items[0].points[0].normal_impulse = 5;
        try rigid.storeContacts(gpa, &cache, constraints.items);
        cache.endTick();

        bm.removeBody(b);
        const b2 = try bm.addBody(gpa, &store, db); // reuses b's slot, generation bumped
        try testing.expect(b2 != b);

        cache.beginTick();
        try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b2)});
        rigid.warmStart(&bm, &cache, constraints.items);
        try testing.expectEqual(@as(u32, 0), cache.hits);
        try testing.expect(cache.misses > 0);
    }
}

test "per-feature warm start: surviving points keep impulses, a vanished one cold-starts" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const a = try bm.addBody(gpa, &store, descOf(0, .dynamic, s));
    var db = descOf(1, .dynamic, s);
    db.position = av3(0, 0.9, 0); // stacked ⇒ a multi-point face-face manifold
    const b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)});
    const c = &constraints.items[0];
    const n: usize = c.count;
    try testing.expect(n >= 2);

    // Seed the cache for every point EXCEPT the last (simulate that feature vanishing).
    var cache = ContactCache{};
    defer cache.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        try cache.store(gpa, .{ .pair_key = c.pair_key, .feature_id = c.points[i].feature_id }, .{ .lambda_n = 3, .tangent_impulse = Vec3r.zero });
    }
    cache.endTick();

    cache.beginTick();
    rigid.warmStart(&bm, &cache, constraints.items);

    // Surviving points seeded from the cache; the last point cold-starts at 0.
    i = 0;
    while (i + 1 < n) : (i += 1) {
        try testing.expectApproxEqAbs(@as(Real, 3), c.points[i].normal_impulse, 1e-5);
    }
    try testing.expectEqual(@as(Real, 0), c.points[n - 1].normal_impulse);
    try testing.expectEqual(@as(u32, @intCast(n - 1)), cache.hits);
    try testing.expectEqual(@as(u32, 1), cache.misses);
}
