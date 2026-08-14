//! M1.1.13.1 acceptance suite for the SUBSTEPPED rigid contact solver (TGS Soft),
//! replacing the M1.1.6 Sequential Impulses suite and absorbing the M1.1.7 NGS
//! suite, whose model no longer exists.
//!
//! `World` composes the full per-tick pipeline IN TESTS ONLY (the production
//! `step()` orchestration is M1.1.15). The normative cycle
//! (`engine-physics-solver.md` §1.7), in order — step numbers are STABLE anchors and
//! step 8 is retired at a frozen number:
//!   (1)  `Broadphase.computePairs` on the current poses (moved-driven deltas)
//!   (2)  candidate-pair retention: merge the deltas into a PERSISTENT set
//!   (3)  external forces — READ-ONLY, and it owns no code. The force/torque
//!        accumulators are constant for the whole of `step()` (nothing writes them
//!        between ticks), so they ARE the tick's accelerations and every substep
//!        reads them directly. The uniform §2 reset is not here: it runs once at the
//!        END of step 6, because clearing an accumulator before anything consumes it
//!        delivers `F/m·0` (blocker B1).
//!   (4)  `cache.beginTick` → `build` (narrowphase `collidePair` per candidate,
//!        `prepare` capturing `v_n⁻` PRE-GRAVITY, the local anchors, the softness
//!        selection and the warm-start SEEDING, plus the wake fixpoint of §1.8.5)
//!   (5)  island partition + activation (W2, W3) — never puts anything to sleep
//!   (6)  the SUBSTEP LOOP and (7) the restitution pass, both inside
//!        `rigid.solveTick`: per substep `integrateVelocitiesNoReset(h)` → warm-start
//!        APPLICATION → biased solve (normal points only) → `integratePositions(h)` →
//!        relax (normal points unbiased, then friction); after the loop the uniform
//!        accumulator reset, then restitution per island.
//!   (8)  retired — there is no position pass. Position error is corrected by the
//!        bias inside step 6, and penetration recovery is PACED by
//!        `contact_push_max_speed` rather than resorbed in one frame.
//!   (9)  `storeContacts` (harvest) → `cache.endTick` (sort + swap)
//!   (10) broadphase proxy updates on the final poses — skips sleeping bodies
//!   (10 bis) the sensor pass (§1.13.4), when `sensors_on`
//!   (11) sleep window sweep on the POST-SOLVE state, then the sleep transition:
//!        the only point in the cycle where a body falls asleep.
//!
//! Sleeping is ENABLED by default here. Every convergence measurement — resting box,
//! five-box stack, mass ratio, drift — sets `sleep_cfg.allow_sleeping = false`, which
//! is normative and not a convenience (§1.8.3): a displacement-bounded criterion lets
//! a slowly creeping body sleep, so a converging-or-not question must be asked with
//! sleeping off.
//!
//! `computePairs` is moved-driven with fat-AABB hysteresis (it reports a pair only
//! when a proxy moves enough to exit its fat AABB), so the consumer keeps a
//! PERSISTENT candidate set (`active`, a sorted-deduped key list) and merges each
//! tick's deltas into it. NORMATIVE retention rule for the M1.1.15
//! `step()`/`PhysicsWorld` (b2ContactManager semantics): a pair is retained while the
//! two FAT broadphase AABBs overlap, dropped only when they separate. This harness
//! keeps EVERY emitted pair (never drops) — a conservative superset of that rule,
//! valid in test: the narrowphase filters non-touching pairs, so a retained separated
//! pair costs a redundant `collidePair` and never a wrong contact. Dropping a
//! contacting pair on transient separation would lose it until the body sank past the
//! margin.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const broadphase = @import("../pipeline/broadphase.zig");
const integration = @import("../pipeline/integration.zig");
const sleep = @import("../pipeline/sleep.zig");
const sensor = @import("../pipeline/sensor.zig");
const rigid = @import("../rigid/root.zig");
// M1.1.14 — the module's float-environment check, asserted where a world opens.
const determinism = @import("../determinism.zig");
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

const gravity_y: Real = -9.81;
const fixed_dt: Real = 1.0 / 60.0;

/// A `Vec3r` literal at solver precision.
pub fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// A descriptor-precision (`f32`) `Vec3` literal.
pub fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

// The harness does NOT compute a broad layer of its own. It calls
// `BodyManager.broadLayerFor`, the same derivation production will use, so a trigger
// lands in the `trigger` class BY THE RULE and not by a literal that happens to agree
// with it.

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
/// The single definition of the normative per-tick cycle (see the file header).
pub const World = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    bp: Bp,
    cache: ContactCache = .{},
    cfg: SolverConfig = .{},
    /// Sleep tuning. Enabled by default; convergence measurements switch it off.
    sleep_cfg: sleep.SleepConfig = .{},
    gravity: Vec3r,
    dt: Real,
    bodies: std.ArrayListUnmanaged(BodyProxy) = .empty,
    active: std.ArrayListUnmanaged(u64) = .empty,
    constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty,
    scratch: std.ArrayListUnmanaged(Bp.Pair) = .empty,
    /// The island partition of the last tick (step 5).
    islands: rigid.IslandManager = .{},
    /// Last tick's solver telemetry (steps 6 and 7) — substeps executed, solve and
    /// relax sweeps, and the minimum separation any biased sweep observed.
    solver_stats: rigid.SolverStats = .{},
    /// Islands put to sleep at step 11 of the last tick.
    slept_last_tick: u32 = 0,
    /// The sensor state, updated at STEP 10 BIS when `sensors_on` (M1.1.13).
    sensors: sensor.SensorState = .{},
    /// Whether step 10 bis runs. Set by the sensor suite before its first step.
    sensors_on: bool = false,

    /// A world with the given gravity and fixed timestep. Default `SolverConfig`,
    /// sleeping ENABLED.
    pub fn init(gravity: Vec3r, dt: Real) World {
        // M1.1.14 — THE physics entry point, until `PhysicsWorld` exists at
        // M1.1.15 and inherits this call. Opening a world on a thread whose
        // float environment is not the engine's makes every number this world
        // produces incomparable with the same world opened elsewhere, so the
        // state is checked once, here, where a world begins — and ASSERTED, not
        // installed (`ARCH-031` rule 5; the reason the two verbs differ is in
        // `../determinism.zig`).
        determinism.assertFloatEnvironment();
        return .{ .bp = Bp.init(.{}), .gravity = gravity, .dt = dt };
    }

    /// `init` with sleeping switched off — the world every MEASUREMENT of the solver
    /// uses: settling, penetration recovery, drift, friction decay, determinism.
    ///
    /// Normative, not a convenience (§1.8.3). The sleep criterion is a displacement
    /// bound over a window, so a body creeping at 5 mm/s moves 2.5 mm per 0.5 s window
    /// against a 15 mm bound and falls asleep while still creeping. Ask "does this
    /// settle?" with sleeping on and the answer you measure is "it fell asleep", which
    /// is not the same question.
    pub fn initNoSleep(gravity: Vec3r, dt: Real) World {
        var world = init(gravity, dt);
        world.sleep_cfg.allow_sleeping = false;
        return world;
    }

    /// Release every owned buffer.
    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.sensors.deinit(gpa);
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
        self.bp.deinit(gpa);
        self.cache.deinit(gpa);
        self.bodies.deinit(gpa);
        self.active.deinit(gpa);
        self.constraints.deinit(gpa);
        self.scratch.deinit(gpa);
        self.islands.deinit(gpa);
        self.* = undefined;
    }

    /// Create a body and insert its broadphase proxy on the matching layer.
    /// Dispatches on the shape CLASS: an unbounded half-space has no world AABB and
    /// goes into the layer's flat list (§1.11.15); a MESH is a finite surface, so it
    /// takes the bounded arm. Exhaustive on the class, no `else`.
    pub fn addBody(self: *World, gpa: std.mem.Allocator, desc: api.BodyDescriptor) !BodyId {
        const id = try self.bm.addBody(gpa, &self.store, desc);
        const layer = BodyManager.broadLayerFor(desc.is_trigger, desc.body_type);
        const shape = self.store.get(desc.shape).?;
        const proxy = switch (shape.class()) {
            .convex, .triangle_soup => try self.bp.insert(gpa, layer, self.bm.bodyAabb(&self.store, id).?, id),
            .half_space => blk: {
                const world = shape_mod.halfSpace(shape).transformed(
                    self.bm.rotation(id).?,
                    self.bm.position(id).?,
                );
                break :blk try self.bp.insertUnbounded(gpa, layer, .{
                    .normal = world.normal,
                    .distance = world.distance,
                }, id);
            },
        };
        try self.bodies.append(gpa, .{ .id = id, .proxy = proxy });
        return id;
    }

    /// Remove a body, applying wake cause W4 (§1.8.5) first: every sleeper retained
    /// in a candidate pair with it is woken, because removing it changes what
    /// supports them and a sleeper emits nothing in broadphase that could notice.
    pub fn removeBody(self: *World, id: BodyId) void {
        for (self.active.items) |key| {
            const a: BodyId = @intCast(key >> 32);
            const b: BodyId = @intCast(key & 0xFFFF_FFFF);
            if (a != id and b != id) continue;
            self.bm.wakeBody(if (a == id) b else a);
        }
        for (self.bodies.items, 0..) |entry, i| {
            if (entry.id != id) continue;
            self.bp.remove(entry.proxy);
            _ = self.bodies.orderedRemove(i); // ordered: the sweep order stays stable
            break;
        }
        self.bm.removeBody(id);
    }

    /// The proxy of `id`, or `null` once the body has been removed.
    fn proxyOf(self: *const World, id: BodyId) ?Bp.Proxy {
        for (self.bodies.items) |b| {
            if (b.id == id) return b.proxy;
        }
        return null;
    }

    /// Whether a retained pair still satisfies §1.7 step 2 — "removal on FAT-AABB
    /// separation only".
    ///
    /// Three cases, exhaustive on what a proxy can be, and the middle one is why
    /// this is not a two-box test. A half-space has no box at all (§1.11.15), so a
    /// pair with one on either side is tested by the SAME exact predicate the
    /// traversal uses, `Aabb.overlapsHalfSpace` from `foundation/math` — never a
    /// second copy of that formula. Two half-spaces both force static bodies and
    /// can never separate, so such a pair is retained unconditionally.
    ///
    /// The FAT boxes are the ones compared, deliberately. Comparing the tight boxes
    /// would purge on a transient sub-margin separation and lose the contact until
    /// the body sank back past the margin — the defect `test "small hop within the
    /// fat margin keeps the contact pair alive"` was written for at M1.1.6. The
    /// margin exists precisely so that this test has hysteresis.
    fn pairStillOverlaps(self: *const World, a: BodyId, b: BodyId) bool {
        // A removed body's pair serves nothing: W4 has already woken whoever was
        // retained with it, at `removeBody`, and there is no proxy left to test.
        const pa = self.proxyOf(a) orelse return false;
        const pb = self.proxyOf(b) orelse return false;

        const box_a = self.bp.proxyAabb(pa);
        const box_b = self.bp.proxyAabb(pb);
        if (box_a) |ba| {
            if (box_b) |bb| return ba.overlaps(bb);
            const hs = self.bp.unboundedShape(pb) orelse return false;
            return ba.overlapsHalfSpace(hs.normal, hs.distance);
        }
        if (box_b) |bb| {
            const hs = self.bp.unboundedShape(pa) orelse return false;
            return bb.overlapsHalfSpace(hs.normal, hs.distance);
        }
        return true; // two half-spaces: both static, no separation is possible
    }

    /// Advance one fixed tick through the normative cycle (file header).
    pub fn step(self: *World, gpa: std.mem.Allocator) !void {
        // (1) broadphase candidate deltas → (2) persistent active set.
        //
        // The set is PERSISTENT and its retention is a CORRECTNESS condition of
        // sleep (§1.8.7), not merely warm-start persistence — a sleeper emits
        // nothing in broadphase, so these retained pairs ARE the wake graph.
        //
        // M1.1.14 — it is also PRUNED, on the one condition §1.7 step 2 allows:
        // the two FAT AABBs have separated. Until this milestone the harness kept
        // every pair it had ever seen, a conservative superset of the normative
        // rule; that is sound for the wake graph but makes the retained set a
        // monotonically growing sequence, and a determinism trace over a set that
        // can only grow passes by ACCUMULATION and proves nothing. The
        // non-vacuity probe on this set is what turns it back into an oracle.
        try self.bp.computePairs(gpa, &self.scratch);
        for (self.scratch.items) |p| try self.active.append(gpa, (@as(u64, p.a) << 32) | p.b);
        sortDedup(&self.active);
        {
            var w: usize = 0;
            for (self.active.items) |key| {
                const a: BodyId = @intCast(key >> 32);
                const b: BodyId = @intCast(key & 0xFFFF_FFFF);
                if (!self.pairStillOverlaps(a, b)) continue;
                self.active.items[w] = key;
                w += 1;
            }
            self.active.shrinkRetainingCapacity(w);
        }

        // (3) external forces — read-only, no code. See the file header.

        // (4) build: narrowphase per candidate; `prepare` captures `v_n⁻` PRE-GRAVITY
        // (the velocity integration has moved into the substep loop), selects the
        // softness, SEEDS the warm start from the cache, and the wake fixpoint runs.
        self.cache.beginTick();
        try rigid.build(
            gpa,
            &self.constraints,
            &self.bm,
            &self.store,
            self.active.items,
            rigid.prepareContext(self.cfg, self.dt, &self.cache),
        );

        // (5) partition into islands and arbitrate activation. Reorders the
        // constraint array into one contiguous range per island. Wakes only.
        try self.islands.partition(gpa, &self.bm, self.constraints.items);

        // (6) the substep loop and (7) the restitution pass. Islands advance in
        // LOCKSTEP inside: every stage sweeps all intervals before the next begins.
        self.solver_stats = rigid.solveTick(
            &self.bm,
            self.constraints.items,
            self.islands.islandsSlice(),
            self.cfg,
            self.dt,
            self.gravity,
        );

        // (9) harvest solved impulses into the cache, then finalize (sort + swap).
        try rigid.storeContacts(gpa, &self.cache, self.constraints.items);
        self.cache.endTick();

        // (10) broadphase proxy updates to the final poses.
        for (self.bodies.items) |b| {
            const sleeping = self.bm.isSleeping(b.id) orelse continue; // stale handle
            if (sleeping) continue; // a sleeper's AABB is unchanged by construction
            // An UNBOUNDED proxy has no box to update and cannot move: a half-space
            // forces a STATIC body, so its pairs are established once at insertion
            // and then carried by the retention rule of step 2 (§1.11.15).
            if (b.proxy.kind == .unbounded) continue;
            if (self.bm.bodyAabb(&self.store, b.id)) |aabb| try self.bp.update(gpa, b.proxy, aabb);
        }

        // (10 BIS) the sensor pass (§1.13.4). Placement rests on two claims of
        // UNEQUAL rank: BEFORE step 11 is MEASURED (the sleep case asserts that
        // falling asleep inside a trigger never produces an exit, and a sleep filter
        // on the traversal makes it fail); AFTER step 10 is a DESIGN REASONING — the
        // poses there are the ones the tick publishes, so an `enter` cannot announce
        // a crossing the solver then undoes.
        if (self.sensors_on) try self.sensors.update(gpa, &self.bp, &self.bm, &self.store);

        // (11) advance the sleep windows on the POST-SOLVE state, then put to sleep
        // every island all of whose members are eligible.
        sleep.updateWindows(&self.bm, self.dt, self.sleep_cfg);
        self.slept_last_tick = self.islands.sleepEligibleIslands(&self.bm, self.sleep_cfg);
    }

    /// Deepest penetration across the manifolds this world currently holds.
    pub fn deepestPenetration(self: *const World) Real {
        var deepest: Real = 0;
        for (self.constraints.items) |c| {
            for (0..c.count) |i| deepest = @max(deepest, c.points[i].penetration);
        }
        return deepest;
    }
};

// --- named envelopes ----------------------------------------------------------
//
// Every margin below is a measured value with headroom, never a tuning knob.

/// Per-contact spring sag at rest, ON TOP of the slop dead zone — the quantity that
/// replaces the M1.1.7 NGS fixed point.
///
/// Inside the dead zone the bias term is exactly zero, so the contact is held by
/// impulse alone and settles a little deeper than the slop; how much deeper is set by
/// `(contact_hertz, contact_damping_ratio)` and the load, not by a closed form.
///
/// MEASURED DIRECTLY, and the distinction matters because a first version of this
/// comment derived it instead. The worst per-contact overlap is what
/// `deepestPenetration()` reports — the penetration carried by a constraint point —
/// and on the five-box stack after 1200 ticks that is **7.216632 mm at f32 and
/// 7.208680 mm at f64**, against the 5 mm slop: about **2.2 mm of sag**.
///
/// It is NOT the per-box sink divided by the number of contacts under it. Those sinks
/// are 5.345643, 12.551069, 19.206524, 25.311708 and 30.867100 mm from the bottom up
/// (f32; 5.345057, 12.551584, 19.206999, 25.310440, 30.862218 at f64), and dividing
/// the third by three gives 6.402 mm — a number with no physical referent, since a
/// sink is a CENTRE displacement that also carries whatever tilt the settling
/// transient left. The two quantities happen to land within a millimetre of each
/// other here, which is exactly why the derivation went unnoticed.
///
/// 3 mm against a measured 2.2 mm of sag leaves ~1.35× headroom on the quantity this
/// constant names.
const soft_sag: Real = 3e-3;
/// Rest budget for ONE contact: the dead zone the solver stops pushing inside, plus
/// the sag it leaves under load. A chain of `n` contacts is allowed `n` times this.
///
/// Two different physical quantities are compared against it, deliberately and with
/// the same allowance: a constraint point's PENETRATION (a surface overlap) and a
/// body's SINK below its analytic rest height (a centre displacement down a chain of
/// `n` contacts). They are not the same measurement — see `soft_sag` — but a contact
/// that overlaps by at most `slop + sag` cannot lower the body above it by more than
/// that either, so one allowance bounds both.
fn restBudget(cfg: SolverConfig, contacts: usize) Real {
    return @as(Real, @floatFromInt(contacts)) * (cfg.penetration_slop + soft_sag);
}
/// A body may not sit ABOVE its analytic rest height by more than float noise.
const rest_overshoot: Real = 1e-4;
/// The anti-BOUNCE ceiling: the speed a free-falling body picks up in one tick
/// (`g·dt`). Below it no body is in sustained free fall. PHYSICAL, not fitted.
const settle_speed: Real = 9.81 * fixed_dt;
/// The IMMOBILITY criterion, two orders below `settle_speed`: 1 mm/s is stopped, not
/// merely slow.
const rest_speed: Real = 1e-3;
/// Sideways offset a body may end up with after the settling transient.
const lateral_bound: Real = 4e-2;
/// How much that offset may still GROW over the second half of a run — what rejects
/// a WALKING stack independently of how large the settling transient was.
const lateral_creep_bound: Real = 1e-3;

/// Float noise of a separation reconstructed from two world coordinates, in the
/// M1.1.4 `k·floatEps·coordScale` form.
fn noiseMargin(coord_scale: Real) Real {
    return 16 * std.math.floatEps(Real) * coord_scale;
}

// --- scene helpers ------------------------------------------------------------

/// Ground (static box, top at y = 0.5) + a dynamic unit box dropped from `drop_y`.
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

/// A static ground box (half-extents 5 × 0.5 × 5) whose top face sits at
/// `base_y + 0.5`.
fn addGround(gpa: std.mem.Allocator, world: *World, base_y: f32) !BodyId {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    var desc = api.BodyDescriptor{
        .entity = .{ .index = 0, .generation = 0 },
        .body_type = .static,
        .shape = shape,
    };
    desc.position = av3(0, base_y, 0);
    desc.restitution = 0;
    return world.addBody(gpa, desc);
}

/// Fill `out` with `out.len` unit boxes stacked flush above a ground whose top face
/// is at `base_y + 0.5`: box `i` starts at its analytic rest height
/// `base_y + 1.0 + i`, so the stack begins with zero penetration everywhere.
fn addStack(gpa: std.mem.Allocator, world: *World, out: []BodyId, base_y: f32, mass: f32) !void {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    for (out, 0..) |*id, i| {
        var desc = api.BodyDescriptor{
            .entity = .{ .index = @intCast(i + 1), .generation = 0 },
            .body_type = .dynamic,
            .shape = shape,
        };
        desc.mass = mass;
        desc.restitution = 0;
        desc.position = av3(0, base_y + 1.0 + @as(f32, @floatFromInt(i)), 0);
        id.* = try world.addBody(gpa, desc);
    }
}

/// Horizontal (XZ) distance of `id` from the world's Y axis at `base_x`/`base_z`.
fn lateralOffset(world: *const World, id: BodyId, base_x: Real, base_z: Real) Real {
    const p = world.bm.position(id).?.toArray();
    const dx = p[0] - base_x;
    const dz = p[2] - base_z;
    return @sqrt(dx * dx + dz * dz);
}

fn descOf(idx: u32, bt: api.BodyType, shape: api.ShapeId) api.BodyDescriptor {
    return .{ .entity = .{ .index = idx, .generation = 0 }, .body_type = bt, .shape = shape };
}

fn pairKey(a: BodyId, b: BodyId) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// A `PrepareContext` at the default config and tick, with no warm-start source —
/// every point cold-starts. The shape most constraint-level scenarios want.
fn coldContext() rigid.PrepareContext {
    return rigid.prepareContext(.{}, fixed_dt, null);
}

// --- resting, recovery and the substep budget ---------------------------------

test "box dropped on a static ground comes to rest without sinking (e = 0)" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 2.0, 0);

    var t: u32 = 0;
    while (t < 300) : (t += 1) try world.step(gpa);

    const y_final = world.bm.position(box).?.toArray()[1];
    const v_final = world.bm.linearVelocity(box).?.toArray()[1];

    // Analytic rest y = ground_top(0.5) + box_half(0.5) = 1.0. The box settles just
    // under it: the soft constraint holds a small steady overlap rather than driving
    // it to zero, which is the slop's whole role — keeping the contact, and its
    // warm-start entry, alive instead of oscillating between contact and no contact.
    try testing.expect(y_final > 1.0 - restBudget(world.cfg, 1));
    try testing.expect(y_final < 1.0 + rest_overshoot);
    try testing.expect(@abs(v_final) < rest_speed);
}

test "rest overlap at equilibrium is measured and bounded" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndBox(gpa, &world, 1.0, 0); // starts flush, settles in place

    var t: u32 = 0;
    while (t < 600) : (t += 1) try world.step(gpa);

    // The equilibrium overlap under soft constraints is NOT the NGS fixed point the
    // M1.1.7 model converged to (`slop` exactly, approached from below, measured
    // `5.9e-7` above it at f32 — SUPERSEDED). It is the slop dead zone plus the sag
    // the spring leaves under the load: inside the dead zone the bias term is zero,
    // so the contact holds by impulse alone and sits slightly deeper.
    //
    // MEASURED here, one box on the ground after 600 ticks: **5.068719 mm at f32,
    // 5.069011 mm at f64** — 69 µm of sag over the 5 mm slop. The same quantity on the
    // most loaded contact of the five-box stack is 7.216632 mm (f32), i.e. 2.2 mm of
    // sag. That the sag GROWS WITH THE LOAD is the whole difference from the model it
    // replaces: the NGS fixed point was the slop whatever the load, because a position
    // pass drives error to a target, where a spring deflects under force.
    const overlap = world.deepestPenetration();
    try testing.expect(overlap > 0); // the contact is alive, not oscillating
    try testing.expect(overlap <= restBudget(world.cfg, 1));

    // Steady, not still drifting: the overlap 60 ticks later is the same to within
    // float noise, which is what "equilibrium" claims.
    const settled = overlap;
    t = 0;
    while (t < 60) : (t += 1) try world.step(gpa);
    try testing.expectApproxEqAbs(settled, world.deepestPenetration(), 1e-4);
}

test "five-box stack comes to rest at substep_count=4" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, 0);
    var boxes: [5]BodyId = undefined;
    try addStack(gpa, &world, &boxes, 0, 1);

    // THE DISCRIMINATING ORACLE of the port. This is the scene that measured the
    // 16-iteration floor at M1.1.7 — a five-deep chain of four-point face manifolds,
    // forty contact points — and it must now come to rest on the substep budget
    // alone, with no iteration count anywhere in the config.
    try testing.expectEqual(@as(u32, 4), world.cfg.substep_count);

    var lateral_mid: [5]Real = undefined;
    var max_speed_late: Real = 0;
    var t: u32 = 0;
    while (t < 1200) : (t += 1) {
        try world.step(gpa);
        if (t == 599) {
            for (boxes, 0..) |b, i| lateral_mid[i] = lateralOffset(&world, b, 0, 0);
        }
        if (t >= 1140) { // the last second
            for (boxes) |b| max_speed_late = @max(max_speed_late, world.bm.linearVelocity(b).?.length());
        }
    }

    for (boxes, 0..) |b, i| {
        // Box `i` rests on `i + 1` contacts, each holding at most one slop of overlap
        // plus its share of the spring sag.
        const analytic = 1.0 + @as(Real, @floatFromInt(i));
        const allowed_sink = restBudget(world.cfg, i + 1);
        const y = world.bm.position(b).?.toArray()[1];
        try testing.expect(y >= analytic - allowed_sink);
        try testing.expect(y <= analytic + rest_overshoot);

        // Bounded sideways offset, and — the statement that actually rejects a
        // walking stack — that offset must not still be GROWING in the second half.
        const lateral_end = lateralOffset(&world, b, 0, 0);
        try testing.expect(lateral_end <= lateral_bound);
        try testing.expect(lateral_end - lateral_mid[i] <= lateral_creep_bound);
    }
    // STOPPED, not merely slow.
    try testing.expect(max_speed_late <= rest_speed);
    try testing.expect(max_speed_late <= settle_speed);

    // Determinism: an identical second run reproduces every pose bit-for-bit.
    var replay = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer replay.deinit(gpa);
    _ = try addGround(gpa, &replay, 0);
    var replay_boxes: [5]BodyId = undefined;
    try addStack(gpa, &replay, &replay_boxes, 0, 1);
    t = 0;
    while (t < 1200) : (t += 1) try replay.step(gpa);
    for (boxes, replay_boxes) |a, b| {
        const pa = world.bm.position(a).?.toArray();
        const pb = replay.bm.position(b).?.toArray();
        const qa = world.bm.rotation(a).?.toArray();
        const qb = replay.bm.rotation(b).?.toArray();
        inline for (0..3) |k| try testing.expectEqual(pa[k], pb[k]);
        inline for (0..4) |k| try testing.expectEqual(qa[k], qb[k]);
    }
}

test "substep_count=1 degenerate big-step runs" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    world.cfg.substep_count = 1; // the A/B lever
    const box = try groundAndBox(gpa, &world, 1.0, 0);

    var t: u32 = 0;
    while (t < 300) : (t += 1) try world.step(gpa);

    // The lever RUNS and the telemetry follows it — that is the whole claim. Stack
    // depth is deliberately NOT asserted: at one substep the effective hertz clamps
    // to `0.125/dt` = 7.5 Hz, a quarter of the authored stiffness, so visibly softer
    // contacts are the expected behaviour of the lever and not a defect of it.
    try testing.expectEqual(@as(u32, 1), world.solver_stats.substeps_executed);
    try testing.expectEqual(@as(u32, 1), world.solver_stats.solve_sweeps);
    try testing.expectEqual(@as(u32, 1), world.solver_stats.relax_sweeps);

    // It still holds the box up — softer, not broken.
    const y = world.bm.position(box).?.toArray()[1];
    try testing.expect(y > 0.5); // never fell through the ground
    try testing.expect(y < 1.0 + rest_overshoot);
}

test "telemetry reports substeps and sweeps" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndBox(gpa, &world, 1.0, 0);

    var t: u32 = 0;
    while (t < 30) : (t += 1) try world.step(gpa);

    // Fixed cost by construction: one solve sweep and one relax sweep per substep,
    // no early-out and no iteration predicate anywhere. The full per-tick constraint
    // budget is `3·substep_count + 1` (n warm-start applications + n solves + n
    // relaxes + 1 restitution) = 13 at the defaults.
    try testing.expectEqual(@as(u32, 4), world.solver_stats.substeps_executed);
    try testing.expectEqual(@as(u32, 4), world.solver_stats.solve_sweeps);
    try testing.expectEqual(@as(u32, 4), world.solver_stats.relax_sweeps);
    // A resting contact is overlapping, so the minimum separation observed is
    // negative and REAL — the field is not merely defaulting.
    try testing.expect(world.solver_stats.min_separation != null);
    try testing.expect(world.solver_stats.min_separation.? < 0);
}

test "small hop within the fat margin keeps the contact pair alive" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 1.0, 0); // starts flush, e = 0

    var t: u32 = 0;
    while (t < 120) : (t += 1) try world.step(gpa);
    const y_rest = world.bm.position(box).?.toArray()[1];

    // A small upward hop: apex ≈ v²/2g ≈ 1.3 cm, well within the broadphase fat-AABB
    // margin (0.1 m). The box never moves far enough to be re-emitted by the
    // moved-driven `computePairs`, so retaining the pair is what keeps the contact
    // live and catches the box on its way down.
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

test "separation beyond the fat margin prunes the retained pair" {
    // THE COMPLEMENT of the small-hop test above, and the pair is the point: one
    // asserts the set RETAINS inside the margin, this one asserts it PRUNES outside
    // it. Either alone is satisfiable by a degenerate rule — never prune, or always
    // prune — and only the two together pin §1.7 step 2, "removal on fat-AABB
    // separation only".
    //
    // It is also the NON-VACUITY probe M1.1.14 owes its fourth discrete trace. A
    // retained set that can only grow is a monotone sequence, and a trace over a
    // monotone sequence agrees with itself by accumulation whatever the engine did.
    // Until this milestone the harness never pruned, so that trace was about to be
    // an oracle that could not fail.
    const gpa = testing.allocator;
    var world = World.initNoSleep(Vec3r.zero, fixed_dt); // no gravity: a clean departure
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 1.0, 0); // rests flush on the ground

    var t: u32 = 0;
    while (t < 4) : (t += 1) try world.step(gpa);
    const retained_in_contact = world.active.items.len;
    // POSITIVE WITNESS: the pair exists before it can be shown to disappear.
    // Without this, "the set shrank" is satisfied by a set that was empty all along.
    try testing.expect(retained_in_contact >= 1);

    // Leave, decisively. The fat margin is 0.1 m, so a departure of several metres
    // is far outside any hysteresis and separates the two fat boxes.
    world.bm.addImpulse(box, vr(0, 40, 0));
    t = 0;
    while (t < 60) : (t += 1) try world.step(gpa);

    try testing.expect(world.bm.position(box).?.toArray()[1] > 5);
    try testing.expect(world.active.items.len < retained_in_contact);
    try testing.expectEqual(@as(usize, 0), world.active.items.len);
}

test "solve is deterministic across identical runs" {
    const gpa = testing.allocator;

    var w1 = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer w1.deinit(gpa);
    const b1 = try groundAndBox(gpa, &w1, 2.0, 0.5);
    var w2 = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
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

// --- restitution --------------------------------------------------------------

/// Max upward (+Y) velocity the dropped box reaches over `ticks`.
fn maxReboundVy(gpa: std.mem.Allocator, drop_y: Real, e: f32, ticks: u32) !Real {
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
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
    // (≈ 0.16 m/s ≪ the 1.0 threshold), so it settles without a bounce.
    const low = try maxReboundVy(gpa, 1.0, 0.8, 120);
    try testing.expect(low < 0.5);
}

test "resting body arms no restitution from one tick of gravity" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndBox(gpa, &world, 1.0, 1.0); // maximal restitution

    // `v_n⁻` is captured at `prepare`, which is now PRE-GRAVITY: the velocity
    // integration moved into the substep loop, so the capture precedes the first
    // slice. A resting body therefore reads `v_n⁻ ≈ 0` and never arms — where a
    // post-gravity capture would read `−g·dt` every tick and, at `e = 1`, hand a
    // motionless box a phantom rebound forever.
    var t: u32 = 0;
    while (t < 240) : (t += 1) try world.step(gpa);

    const v = world.bm.linearVelocity(box).?.toArray()[1];
    try testing.expect(@abs(v) < rest_speed);
    const y = world.bm.position(box).?.toArray()[1];
    try testing.expect(y > 1.0 - restBudget(world.cfg, 1));
    try testing.expect(y < 1.0 + rest_overshoot);
}

test "restitution predicate: <= threshold boundary arms; zero total impulse skips" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // A dynamic sphere overlapping a static one, e = 1 so a bounce is unmissable.
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    da.restitution = 1;
    var db = descOf(1, .static, s);
    db.position = av3(0.9, 0, 0);
    db.restitution = 1;
    const a = try bm.addBody(gpa, &store, da);
    const b = try bm.addBody(gpa, &store, db);

    const cfg = SolverConfig{};
    bm.setLinearVelocity(a, vr(3, 0, 0)); // approaching, well past the threshold

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, coldContext());
    try testing.expectEqual(@as(usize, 1), constraints.items.len);

    // Drive one substep's worth of solve so the point actually pushes.
    const h = fixed_dt / 4.0;
    rigid.solveRange(&bm, constraints.items, 0, 1, cfg, h);
    rigid.relaxRange(&bm, constraints.items, 0, 1, cfg, h);
    const pt = &constraints.items[0].points[0];
    try testing.expect(pt.total_normal_impulse > 0);
    const pushed = pt.total_normal_impulse;

    // THE BOUNDARY IS SET, NOT AIMED AT. `v_n⁻` is written directly onto the point
    // rather than manufactured by a launch velocity: the captured value goes through a
    // quaternion transport and a dot product, so no choice of scene puts it exactly on
    // the threshold at every precision — a first version of this test aimed at the
    // boundary geometrically, passed at f32 by luck and missed it at f64. What the
    // predicate claims is a CLOSED interval, and that is a statement about the
    // comparison, so the comparison is what gets tested.
    const settled = bm.linearVelocity(a).?.toArray()[0];
    pt.rel_normal_velocity = -cfg.restitution_threshold; // exactly on it ⇒ arms
    rigid.applyRestitutionRange(&bm, constraints.items, 0, 1, cfg);
    try testing.expect(bm.linearVelocity(a).?.toArray()[0] < settled - 0.5); // bounced

    // One ULP on the INSIDE of the threshold — a hair slower than the cutoff — must not
    // arm. Paired with the case above this pins the boundary itself, not merely that
    // fast contacts bounce and slow ones do not.
    bm.setLinearVelocity(a, vr(settled, 0, 0));
    pt.normal_impulse = 0;
    pt.total_normal_impulse = pushed;
    pt.rel_normal_velocity = std.math.nextAfter(Real, -cfg.restitution_threshold, 0);
    rigid.applyRestitutionRange(&bm, constraints.items, 0, 1, cfg);
    try testing.expectEqual(settled, bm.linearVelocity(a).?.toArray()[0]);

    // The SECOND clause: a point that never pushed must not bounce, however fast it
    // approached at capture. `total_normal_impulse` at zero is the state of a
    // speculative point the tick never had to resolve.
    pt.rel_normal_velocity = -10; // far past the threshold
    pt.total_normal_impulse = 0;
    const before = pt.normal_impulse;
    rigid.applyRestitutionRange(&bm, constraints.items, 0, 1, cfg);
    try testing.expectEqual(settled, bm.linearVelocity(a).?.toArray()[0]);
    try testing.expectEqual(before, pt.normal_impulse);
}

test "speculative branch limits approach without attraction" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Two spheres in contact at build time, so a constraint exists with its anchors
    // set; then A is MOVED APART so the separation re-derived from the current poses
    // is strictly positive. That is the intra-tick case the `s > 0` branch owns.
    var da = descOf(0, .dynamic, s);
    da.mass = 1;
    var db = descOf(1, .static, s);
    db.position = av3(0.99, 0, 0);
    const a = try bm.addBody(gpa, &store, da);
    const b = try bm.addBody(gpa, &store, db);

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, coldContext());
    try testing.expectEqual(@as(usize, 1), constraints.items.len);

    // The pair is built OVERLAPPING (centres 0.99 apart, radii summing to 1.0), so
    // pulling A back by `gap` leaves `gap − penetration` of clearance, not `gap`. The
    // expectation is derived from the manifold the build actually produced rather than
    // from the displacement — a literal here would encode the initial overlap silently.
    const gap: Real = 0.02;
    const separation = gap - constraints.items[0].points[0].penetration;
    try testing.expect(separation > 0);
    bm.setPosition(a, bm.position(a).?.sub(vr(gap, 0, 0)));
    const cfg = SolverConfig{};
    const h = fixed_dt / 4.0;

    // NO ATTRACTION: a body sitting still at a positive separation is left alone.
    // The accumulated clamp `λₙ ≥ 0` is what forbids the pull, and a speculative
    // point must not manufacture one.
    bm.setLinearVelocity(a, vr(0, 0, 0));
    rigid.solveRange(&bm, constraints.items, 0, 1, cfg, h);
    try testing.expectEqual(@as(Real, 0), constraints.items[0].points[0].normal_impulse);
    try testing.expect(bm.linearVelocity(a).?.approxEql(Vec3r.zero, 0));

    // APPROACH LIMITED: closing faster than the gap can absorb in one substep is cut
    // back to exactly `gap/h` — the speed that just closes the gap and no more.
    const closing = separation / h;
    bm.setLinearVelocity(a, vr(4 * closing, 0, 0));
    rigid.solveRange(&bm, constraints.items, 0, 1, cfg, h);
    try testing.expectApproxEqAbs(closing, bm.linearVelocity(a).?.toArray()[0], 1e-3);

    // And RELAX takes the same branch, not the unbiased one: the speculative bias is
    // active in both passes (§1.7.1), so a second cut leaves the same speed rather
    // than driving it to zero.
    rigid.relaxRange(&bm, constraints.items, 0, 1, cfg, h);
    try testing.expectApproxEqAbs(closing, bm.linearVelocity(a).?.toArray()[0], 1e-3);
}

// --- friction (relax-only scheduling revalidation) ----------------------------

/// Along-surface displacement of a box placed flush on a static incline (rotated θ
/// about Z) with combined friction from `mu`, after `ticks`.
fn inclineDrift(gpa: std.mem.Allocator, theta: Real, mu: f32, ticks: u32) !Real {
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const ground_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const rot = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), @floatCast(theta));

    var ground = api.BodyDescriptor{ .entity = .{ .index = 0, .generation = 0 }, .body_type = .static, .shape = ground_shape };
    ground.rotation = rot;
    ground.friction = mu;
    _ = try world.addBody(gpa, ground);

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
    // Friction now runs in the RELAX sweep only, after every normal point of the
    // constraint — a measurable scheduling change, so the hold/slide threshold is
    // re-established rather than assumed to have survived.
    const theta = std.math.pi / 6.0; // 30° ⇒ tan θ ≈ 0.577
    const holds = try inclineDrift(gpa, theta, 0.8, 180); // μ = 0.8 > tan θ ⇒ holds
    const slides = try inclineDrift(gpa, theta, 0.3, 180); // μ = 0.3 < tan θ ⇒ slides
    try testing.expect(holds < 0.1);
    try testing.expect(slides > 0.5);
}

/// Horizontal speed of a box sliding on flat ground after `ticks`.
fn slideSpeedAfter(gpa: std.mem.Allocator, v0: Vec3r, ticks: u32) !Real {
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
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
    // the circular clamp is basis-independent, and moving friction into relax does
    // not change that.
    const along = try slideSpeedAfter(gpa, vr(3, 0, 0), 20);
    const diagonal = try slideSpeedAfter(gpa, vr(2.1213203, 0, 2.1213203), 20);
    try testing.expectApproxEqAbs(along, diagonal, 1e-2);
}

test "a sheared stack does not walk" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, 0);
    var boxes: [3]BodyId = undefined;
    try addStack(gpa, &world, &boxes, 0, 1);

    // Shear the stack once, then let friction absorb it. What is asserted is not
    // that the transient is small but that it STOPS: the offset must not still be
    // growing in the second half of the run.
    world.bm.setLinearVelocity(boxes[2], vr(1.5, 0, 0));

    var mid: [3]Real = undefined;
    var t: u32 = 0;
    while (t < 900) : (t += 1) {
        try world.step(gpa);
        if (t == 449) for (boxes, 0..) |b, i| {
            mid[i] = lateralOffset(&world, b, 0, 0);
        };
    }
    for (boxes, 0..) |b, i| {
        const end = lateralOffset(&world, b, 0, 0);
        try testing.expect(end - mid[i] <= lateral_creep_bound);
        try testing.expect(world.bm.linearVelocity(b).?.length() <= rest_speed);
    }
}

// --- chains, mass ratio, far field, reference-face ownership -------------------

test "a heavy box resting on a light box does not sink through" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, 0);
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

    var light = api.BodyDescriptor{ .entity = .{ .index = 1, .generation = 0 }, .body_type = .dynamic, .shape = shape };
    light.mass = 1;
    light.restitution = 0;
    light.position = av3(0, 1, 0);
    const light_id = try world.addBody(gpa, light);
    var heavy = light;
    heavy.entity = .{ .index = 2, .generation = 0 };
    heavy.mass = 10; // 10:1 mass ratio — the regime §1.6 claims for substepping
    heavy.position = av3(0, 2, 0);
    const heavy_id = try world.addBody(gpa, heavy);

    var t: u32 = 0;
    while (t < 600) : (t += 1) try world.step(gpa);

    const y_light = world.bm.position(light_id).?.toArray()[1];
    const y_heavy = world.bm.position(heavy_id).?.toArray()[1];
    try testing.expect(y_light >= 1.0 - restBudget(world.cfg, 1));
    try testing.expect(y_light <= 1.0 + rest_overshoot);
    try testing.expect(y_heavy >= 2.0 - restBudget(world.cfg, 2));
    try testing.expect(y_heavy <= 2.0 + rest_overshoot);
}

test "a stack far from the origin along the contact normal still settles" {
    const gpa = testing.allocator;
    // The offset is ALONG the contact normal: the configuration exercising the
    // `(p_b − p_a)·n` cancellation, where both terms are ≈ 5000 and their difference
    // is a few millimetres. At f32 the noise there is `floatEps · 5000 ≈ 0.6 mm`
    // against a 5 mm slop — the worldspace precision characteristic §1.7.1 documents.
    const base: f32 = 5000;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, base);
    var boxes: [3]BodyId = undefined;
    try addStack(gpa, &world, &boxes, base, 1);

    var max_speed_late: Real = 0;
    var t: u32 = 0;
    while (t < 600) : (t += 1) {
        try world.step(gpa);
        if (t >= 540) {
            for (boxes) |b| max_speed_late = @max(max_speed_late, world.bm.linearVelocity(b).?.length());
        }
    }

    for (boxes, 0..) |b, i| {
        const analytic = @as(Real, base) + 1.0 + @as(Real, @floatFromInt(i));
        const allowed_sink = restBudget(world.cfg, i + 1) + noiseMargin(base);
        const y = world.bm.position(b).?.toArray()[1];
        try testing.expect(y >= analytic - allowed_sink);
        try testing.expect(y <= analytic + rest_overshoot + noiseMargin(base));
    }
    try testing.expect(max_speed_late <= settle_speed);
}

test "a tilted anisotropic box resorbs penetration without lateral drift" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, 0);
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(2, 0.1, 0.5) } });
    var desc = api.BodyDescriptor{ .entity = .{ .index = 1, .generation = 0 }, .body_type = .dynamic, .shape = shape };
    desc.mass = 1;
    desc.restitution = 0;
    desc.rotation = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), 0.15);
    desc.position = av3(0, 0.85, 0); // tilted and already overlapping the ground
    const id = try world.addBody(gpa, desc);

    var mid_x: Real = 0;
    var mid_z: Real = 0;
    var t: u32 = 0;
    while (t < 600) : (t += 1) {
        try world.step(gpa);
        if (t == 299) {
            mid_x = world.bm.position(id).?.toArray()[0];
            mid_z = world.bm.position(id).?.toArray()[2];
        }
    }

    // Normal direction: the box flattened onto the ground and rests just under the
    // flush height (ground top 0.5 + half-thickness 0.1). The recovery is PACED by
    // `contact_push_max_speed` rather than resorbed in one frame, so what is asserted
    // is where it ends up, not how fast it got there.
    const p = world.bm.position(id).?.toArray();
    try testing.expect(p[1] >= 0.6 - restBudget(world.cfg, 1));
    try testing.expect(p[1] <= 0.6 + rest_overshoot);
    try testing.expect(world.deepestPenetration() <= restBudget(world.cfg, 1));

    // Tangential: the tip-over displaces the centre once, but the settled box must
    // not creep afterwards — the bias is along the normal, so it may not walk the box
    // sideways.
    const creep = @sqrt((p[0] - mid_x) * (p[0] - mid_x) + (p[2] - mid_z) * (p[2] - mid_z));
    try testing.expect(creep <= lateral_creep_bound);
    try testing.expect(lateralOffset(&world, id, 0, 0) <= lateral_bound);
}

test "reference face carried by B still resorbs penetration" {
    const gpa = testing.allocator;
    var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);

    // A LYING capsule against a static box, capsule added FIRST so it holds the lower
    // BodyId and is the canonical A. This is the scene that reaches `manifold.zig`'s
    // reference/incident selection with `a_is_ref == false`: a lying capsule's
    // supporting face is its two-endpoint segment (`count == 2`, so not the point-core
    // short-circuit), `face_b.count == 4`, and `align_a` is 0 against `align_b ≈ 1`.
    // The box therefore owns the reference face — the case §1.7.1 cites for why the
    // normal may not follow A.
    const capsule_shape = try world.store.createShape(gpa, .{ .capsule = .{ .radius = 0.2, .half_height = 0.5 } });
    var capsule = api.BodyDescriptor{ .entity = .{ .index = 0, .generation = 0 }, .body_type = .dynamic, .shape = capsule_shape };
    capsule.mass = 1;
    capsule.restitution = 0;
    capsule.rotation = foundation.math.Quatf.fromAxisAngle(av3(0, 0, 1), std.math.pi / 2.0);
    capsule.position = av3(0, 0.64, 0); // flush would be 0.5 + 0.2 ⇒ 6 cm of penetration
    const capsule_id = try world.addBody(gpa, capsule);

    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(3, 0.5, 3) } });
    var box = api.BodyDescriptor{ .entity = .{ .index = 1, .generation = 0 }, .body_type = .static, .shape = box_shape };
    box.restitution = 0;
    _ = try world.addBody(gpa, box);

    try world.step(gpa);
    try testing.expectEqual(@as(usize, 1), world.constraints.items.len);
    // COVERAGE assertion, not a presumption: a 2-point manifold here can only come
    // from clipping the incident SEGMENT against a reference FACE, which is only
    // reachable through the reference/incident selection.
    try testing.expectEqual(@as(u8, 2), world.constraints.items[0].count);
    try testing.expect(world.constraints.items[0].normal.approxEql(vr(0, -1, 0), 1e-4));
    try testing.expect(world.constraints.items[0].points[0].penetration > 0.05);

    var t: u32 = 0;
    while (t < 300) : (t += 1) try world.step(gpa);

    try testing.expect(world.deepestPenetration() <= restBudget(world.cfg, 1));
    const y = world.bm.position(capsule_id).?.toArray()[1];
    try testing.expect(y >= 0.7 - restBudget(world.cfg, 1));
    try testing.expect(y <= 0.7 + rest_overshoot);
}

test "BodyId order permutation converges to the same poses" {
    const gpa = testing.allocator;
    // The same physical scene with the two bodies added in swapped order: the
    // canonical pair flips (A/B roles, normal sign, reference face), so the two runs
    // are NOT bit-identical — they must nonetheless converge to the same rest.
    var ground_first = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer ground_first.deinit(gpa);
    _ = try addGround(gpa, &ground_first, 0);
    var boxes_a: [1]BodyId = undefined;
    try addStack(gpa, &ground_first, &boxes_a, 0, 1);

    var box_first = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer box_first.deinit(gpa);
    const shape = try box_first.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var box = api.BodyDescriptor{ .entity = .{ .index = 0, .generation = 0 }, .body_type = .dynamic, .shape = shape };
    box.mass = 1;
    box.restitution = 0;
    box.position = av3(0, 1, 0);
    const box_id = try box_first.addBody(gpa, box);
    _ = try addGround(gpa, &box_first, 0);

    var t: u32 = 0;
    while (t < 300) : (t += 1) {
        try ground_first.step(gpa);
        try box_first.step(gpa);
    }

    const order_tolerance: Real = 1e-4;
    try testing.expectApproxEqAbs(
        ground_first.bm.position(boxes_a[0]).?.toArray()[1],
        box_first.bm.position(box_id).?.toArray()[1],
        order_tolerance,
    );
}

// --- island lockstep ----------------------------------------------------------

test "island lockstep equivalence per stage per substep" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Two DISJOINT contacting pairs, ten metres apart — two islands by construction.
    var ids: [4]BodyId = undefined;
    var pairs: [2]u64 = undefined;
    for (0..2) |k| {
        const x = @as(f32, @floatFromInt(k)) * 10.0;
        var da = descOf(@intCast(2 * k), .dynamic, s);
        da.mass = 1;
        da.position = av3(x, 0, 0);
        var db = descOf(@intCast(2 * k + 1), .dynamic, s);
        db.mass = 1;
        db.position = av3(x + 0.9, 0, 0);
        ids[2 * k] = try bm.addBody(gpa, &store, da);
        ids[2 * k + 1] = try bm.addBody(gpa, &store, db);
        bm.setLinearVelocity(ids[2 * k], vr(2, 0, 0));
        pairs[k] = pairKey(ids[2 * k], ids[2 * k + 1]);
    }

    var constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &bm, &store, &pairs, coldContext());
    try testing.expectEqual(@as(usize, 2), constraints.items.len);

    const cfg = SolverConfig{};
    const h = fixed_dt / @as(Real, @floatFromInt(cfg.substep_count));

    // Snapshot, solve the two ranges SEPARATELY at every stage, and record.
    const snapshot = [_]Vec3r{
        bm.linearVelocity(ids[0]).?, bm.linearVelocity(ids[1]).?,
        bm.linearVelocity(ids[2]).?, bm.linearVelocity(ids[3]).?,
    };
    rigid.solveRange(&bm, constraints.items, 0, 1, cfg, h);
    rigid.solveRange(&bm, constraints.items, 1, 2, cfg, h);
    rigid.relaxRange(&bm, constraints.items, 0, 1, cfg, h);
    rigid.relaxRange(&bm, constraints.items, 1, 2, cfg, h);
    var per_island: [4]Vec3r = undefined;
    for (ids, 0..) |id, i| per_island[i] = bm.linearVelocity(id).?;

    // Reset and solve the WHOLE array in one range per stage.
    for (ids, snapshot) |id, v| bm.setLinearVelocity(id, v);
    for (constraints.items) |*c| for (0..c.count) |i| {
        c.points[i].normal_impulse = 0;
        c.points[i].tangent1_impulse = 0;
        c.points[i].tangent2_impulse = 0;
        c.points[i].total_normal_impulse = 0;
    };
    rigid.solveRange(&bm, constraints.items, 0, 2, cfg, h);
    rigid.relaxRange(&bm, constraints.items, 0, 2, cfg, h);

    // BIT-EXACT: constraints of two islands touch disjoint bodies, so no update of
    // one can change an input of the other, and the composite sort key preserves
    // relative order inside each range. Structural, not empirical.
    for (ids, per_island) |id, expected| {
        const got = bm.linearVelocity(id).?.toArray();
        inline for (0..3) |k| try testing.expectEqual(expected.toArray()[k], got[k]);
    }
}

// --- warm start: seeding at prepare, application per substep -------------------

test "warm start hits a resting contact and misses on generation reuse" {
    const gpa = testing.allocator;

    // Part A: a resting box in the full pipeline warm-starts (cache hits > 0).
    {
        var world = World.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
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
        const ctx = rigid.prepareContext(.{}, fixed_dt, &cache);

        cache.beginTick();
        try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, ctx);
        constraints.items[0].points[0].normal_impulse = 5;
        try rigid.storeContacts(gpa, &cache, constraints.items);
        cache.endTick();

        bm.removeBody(b);
        const b2 = try bm.addBody(gpa, &store, db); // reuses b's slot, generation bumped
        try testing.expect(b2 != b);

        cache.beginTick();
        try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b2)}, ctx);
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
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, coldContext());
    const n: usize = constraints.items[0].count;
    try testing.expect(n >= 2);

    // Seed the cache for every point EXCEPT the last (simulate that feature vanishing).
    var cache = ContactCache{};
    defer cache.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        try cache.store(gpa, .{
            .pair_key = constraints.items[0].pair_key,
            .feature_id = constraints.items[0].points[i].feature_id,
        }, .{ .lambda_n = 3, .tangent_impulse = Vec3r.zero });
    }
    cache.endTick();

    cache.beginTick();
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, rigid.prepareContext(.{}, fixed_dt, &cache));

    const c = &constraints.items[0];
    i = 0;
    while (i + 1 < n) : (i += 1) {
        try testing.expectApproxEqAbs(@as(Real, 3), c.points[i].normal_impulse, 1e-5);
    }
    try testing.expectEqual(@as(Real, 0), c.points[n - 1].normal_impulse);
    try testing.expectEqual(@as(u32, @intCast(n - 1)), cache.hits);
    try testing.expectEqual(@as(u32, 1), cache.misses);

    // SEEDING DOES NOT APPLY. The seeded impulse sits on the constraint and no body
    // has moved: that separation is N4's hazard made observable — re-calling the
    // seeding per substep would re-read the cache and reset the accumulators, while
    // the APPLICATION is a distinct function called once per substep.
    try testing.expect(bm.linearVelocity(a).?.approxEql(Vec3r.zero, 0));
    try testing.expect(bm.linearVelocity(b).?.approxEql(Vec3r.zero, 0));

    // Applying it moves both bodies, and it credits `total_normal_impulse` with the
    // CURRENT accumulator — the first of the three contributions the restitution
    // predicate reads.
    rigid.applyWarmStartRange(&bm, constraints.items, 0, 1);
    try testing.expect(!bm.linearVelocity(a).?.approxEql(Vec3r.zero, 0));
    try testing.expectApproxEqAbs(@as(Real, 3), c.points[0].total_normal_impulse, 1e-5);
}

/// Warm-start a single sphere contact whose normal is `normalize(n_dir)` with a
/// cached WORLD tangent `t_world`, and return the reconstructed seeded tangent
/// (λ_t1·t1 + λ_t2·t2) — the world tangent projected into the new basis.
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
    var cache = ContactCache{};
    defer cache.deinit(gpa);

    // First build cold, only to learn the feature id this contact will carry.
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, coldContext());
    const feature = constraints.items[0].points[0].feature_id;

    try cache.store(gpa, .{
        .pair_key = constraints.items[0].pair_key,
        .feature_id = feature,
    }, .{ .lambda_n = 10, .tangent_impulse = t_world });
    cache.endTick();
    cache.beginTick();
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, rigid.prepareContext(.{}, fixed_dt, &cache));
    const c = constraints.items[0];
    return c.tangent1.scale(c.points[0].tangent1_impulse).add(c.tangent2.scale(c.points[0].tangent2_impulse));
}

test "warm-started tangent is continuous across a tangent-basis flip" {
    const gpa = testing.allocator;
    // Two normals straddling the x = y dominant-axis boundary (so the tangent basis
    // flips discontinuously). The cached WORLD tangent must reconstruct to the SAME
    // world direction for both — a per-basis-scalar cache would rotate it.
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
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)}, coldContext());
    rigid.solveRange(&bm, constraints.items, 0, constraints.items.len, .{}, fixed_dt / 4.0);

    try testing.expectEqual(@as(usize, 0), constraints.items.len);
    for (bm.position(a).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
    for (bm.position(b).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
    for (bm.linearVelocity(b).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
}
