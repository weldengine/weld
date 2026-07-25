//! M1.1.6 acceptance suite for the Sequential Impulses contact solver, extended at
//! M1.1.7 with the NGS position pass.
//!
//! `World` composes the full per-tick pipeline IN TESTS ONLY (the production
//! `step()` orchestration is M1.1.15). Normative per-tick cycle
//! (`engine-physics-forge.md` §1.7):
//!   (1) `Broadphase.computePairs` on the current poses (moved-driven deltas)
//!   (2) candidate-pair retention: merge the deltas into a PERSISTENT set
//!   (3) `integrateVelocities(dt, gravity)`
//!   (4) velocity pass — `cache.beginTick` → `build` (narrowphase `collidePair`
//!       per candidate) + `prepare` (captures v_n⁻) → `warmStart` → `solveRange`
//!       × `velocity_iterations`
//!   (5) `integratePositions(dt)`
//!   (6) NGS position pass — `solvePositionRange` × `position_iterations` (§1.7.2)
//!   (7) `storeContacts` (harvest) → `cache.endTick` (sort + swap)
//!   (8) broadphase proxy updates on the corrected poses.
//!
//! `computePairs` is moved-driven with fat-AABB hysteresis (it reports a pair only
//! when a proxy moves enough to exit its fat AABB), so the consumer keeps a
//! PERSISTENT candidate set (`active`, a sorted-deduped key list) and merges each
//! tick's deltas into it. NORMATIVE retention rule for the M1.1.15
//! `step()`/`PhysicsWorld` (b2ContactManager semantics): a pair is retained while
//! the two FAT broadphase AABBs overlap, dropped only when they separate — which
//! is safe, since any later re-contact first requires a proxy to exit its fat
//! AABB, which re-marks it moved and re-emits the pair. This test harness keeps
//! EVERY emitted pair (never drops) — a conservative superset of that rule, valid
//! in test: the narrowphase filters non-touching pairs (a pair with no manifold
//! produces no constraint), so a retained separated pair only costs a redundant
//! `collidePair`, never a wrong contact. Dropping a contacting pair on transient
//! separation (e.g. a small hop within the fat margin), by contrast, would lose
//! the contact until the body sank past the margin.

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

/// A `Vec3r` literal at solver precision.
pub fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// A descriptor-precision (`f32`) `Vec3` literal.
pub fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
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
/// The single definition of the normative per-tick cycle (see the file header):
/// `tests/position_solver_test.zig` drives this same harness rather than copying
/// it, so the cycle cannot drift between the two suites.
pub const World = struct {
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
    /// Telemetry of the last tick's NGS position pass (step 6).
    position_result: rigid.PositionSolveResult = .{},

    /// A world with the given gravity and fixed timestep. Default `SolverConfig`.
    pub fn init(gravity: Vec3r, dt: Real) World {
        return .{ .bp = Bp.init(.{}), .gravity = gravity, .dt = dt };
    }

    /// Release every owned buffer.
    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
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

    /// Create a body and insert its broadphase proxy on the matching layer.
    pub fn addBody(self: *World, gpa: std.mem.Allocator, desc: api.BodyDescriptor) !BodyId {
        const id = try self.bm.addBody(gpa, &self.store, desc);
        const aabb = self.bm.bodyAabb(&self.store, id).?;
        const proxy = try self.bp.insert(gpa, broadphaseLayer(desc.body_type), aabb, id);
        try self.bodies.append(gpa, .{ .id = id, .proxy = proxy });
        return id;
    }

    /// Advance one fixed tick through the normative cycle (file header, steps 1-8).
    pub fn step(self: *World, gpa: std.mem.Allocator) !void {
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

        // (6) NGS position pass — resorb the residual penetration by correcting
        // poses only (no velocity is touched, no accumulated impulse is modified).
        self.position_result = rigid.solvePositionRange(
            &self.bm,
            self.constraints.items,
            0,
            self.constraints.items.len,
            self.cfg,
        );

        // (7) harvest solved impulses into the cache, then finalize (sort + swap).
        try rigid.storeContacts(gpa, &self.cache, self.constraints.items);
        self.cache.endTick();

        // `active` is NOT pruned — every emitted pair is retained (see the file
        // header). The narrowphase filters non-touching pairs at `build`, so a
        // retained separated pair costs only a redundant `collidePair`.

        // (8) broadphase proxy updates to the poses corrected by step (6).
        for (self.bodies.items) |b| {
            if (self.bm.bodyAabb(&self.store, b.id)) |aabb| try self.bp.update(gpa, b.proxy, aabb);
        }
    }
};

/// Ground (static box, top at y = 0.5) + a dynamic unit box dropped from y = `drop_y`.
/// Returns the dynamic box's BodyId. Restitution `e` on both.
pub fn groundAndBox(gpa: std.mem.Allocator, world: *World, drop_y: Real, e: f32) !BodyId {
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

    // Run 5 s. Capture the height at the FIRST tick that produces a contact
    // constraint (impact), then require the box never sinks below it afterwards.
    var y_impact: ?Real = null;
    var min_after_impact: Real = 1e30;
    var t: u32 = 0;
    while (t < 300) : (t += 1) {
        try world.step(gpa);
        const y = world.bm.position(box).?.toArray()[1];
        if (y_impact == null and world.constraints.items.len > 0) y_impact = y;
        if (y_impact != null and y < min_after_impact) min_after_impact = y;
    }
    const y_final = world.bm.position(box).?.toArray()[1];
    const v_final = world.bm.linearVelocity(box).?.toArray()[1];

    // The box made contact and never sank below the at-impact height thereafter.
    // NOTE: since M1.1.7 the box RISES from its at-impact height (the position pass
    // resorbs the penetration), so this floor is vacuous by construction — it is
    // kept as the M1.1.6 no-sinking statement, not as an active assertion.
    try testing.expect(y_impact != null);
    try testing.expect(min_after_impact >= y_impact.? - 1e-3);

    // RECOVERY (M1.1.7). The M1.1.6 statement — "penetration bounded at its
    // at-impact value, absolute non-recovery accepted" — is obsolete: the NGS
    // position pass resorbs the impact penetration down to the slop, which is
    // precisely where it stops so the contact (and its warm-start entry) stays
    // alive instead of oscillating between contact and no contact.
    try testing.expectEqual(@as(usize, 1), world.constraints.items.len);
    var resting_penetration: Real = 0;
    for (0..world.constraints.items[0].count) |i| {
        resting_penetration = @max(resting_penetration, world.constraints.items[0].points[i].penetration);
    }
    // The rest sits exactly at the NGS fixed point `separation = −penetration_slop`
    // (a contraction never crosses its fixed point), so the resting penetration
    // equals the slop up to the float noise of reconstructing it — a difference of
    // two world coordinates of magnitude ≈ 1 m. Measured: 0 at f64, 5.9e-7 at f32
    // (≈ 5 ULP of 1.0). `noise_margin` is that noise floor in the M1.1.4 form
    // `k·floatEps(Real)·coordScale`, NOT a geometric threshold: the physical
    // statement is the recovery from the ≈ 7 cm at-impact penetration down to the
    // 5 mm slop, a factor of ~14.
    const coord_scale: Real = 1.0; // the contact sits at y ≈ 1 m
    const noise_margin: Real = 16 * std.math.floatEps(Real) * coord_scale;
    try testing.expect(resting_penetration <= world.cfg.penetration_slop + noise_margin);

    // Envelope: analytic rest y = ground_top(0.5) + box_half(0.5) = 1.0, and NGS
    // converges to `1.0 − penetration_slop` from below. Never fell through, rests
    // one slop under the analytic height, at rest.
    try testing.expect(y_final > 1.0 - 2 * world.cfg.penetration_slop);
    try testing.expect(y_final < 1.0 + 1e-4);
    try testing.expect(@abs(v_final) < 0.05);
}

test "small hop within the fat margin keeps the contact pair alive" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 1.0, 0); // starts flush, e = 0

    // Settle, then record the resting height.
    var t: u32 = 0;
    while (t < 120) : (t += 1) try world.step(gpa);
    const y_rest = world.bm.position(box).?.toArray()[1];

    // A small upward hop: apex ≈ v²/2g = 0.25/19.62 ≈ 1.3 cm, well within the
    // broadphase fat-AABB margin (0.1 m). The box never moves far enough to be
    // re-emitted by the moved-driven `computePairs`, so retaining the pair is what
    // keeps the contact live and catches the box on its way down. Dropping the pair
    // on separation would lose it until the box sank past the fat margin (~0.1 m).
    world.bm.addImpulse(box, vr(0, 0.5, 0));
    var min_y: Real = y_rest;
    t = 0;
    while (t < 120) : (t += 1) {
        try world.step(gpa);
        const y = world.bm.position(box).?.toArray()[1];
        if (y < min_y) min_y = y;
    }
    try testing.expect(min_y >= y_rest - 0.02);
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
