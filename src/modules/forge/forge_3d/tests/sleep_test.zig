//! M1.1.8 acceptance suite for sleep detection: the displacement window, the
//! separation of write intents (`engine-physics-forge.md` §1.8.4), and the sleep
//! transition.
//!
//! Everything here is BODY-level. The island-level scenarios — a resting island
//! whose constraint array goes empty, a stack woken whole in one tick, W4 — need
//! the island manager and the full harness and live in `tests/island_test.zig` and
//! `tests/solver_test.zig`.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const sleep = @import("../pipeline/sleep.zig");
const integration = @import("../pipeline/integration.zig");
const rigid = @import("../rigid/root.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const BodyId = api.BodyId;
const SleepConfig = sleep.SleepConfig;
const testing = std.testing;

const dt: Real = 1.0 / 60.0;

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

/// One free-standing dynamic unit box (half-extents 0.5) at the origin — no ground,
/// no contact. The window tests drive its pose by hand, so nothing else may move it.
fn loneBox(gpa: std.mem.Allocator, store: *ShapeStore, bm: *BodyManager) !BodyId {
    const s = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var d = descOf(0, .dynamic, s);
    d.mass = 1;
    return bm.addBody(gpa, store, d);
}

// --- the window ---------------------------------------------------------------

test "the sleep window is a displacement bound, not an instantaneous velocity" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    const cfg = SleepConfig{};

    // A JITTERING body: it hops 1 mm back and forth every tick, so its
    // instantaneous speed is 0.06 m/s — twice `point_velocity_threshold` — while it
    // never gets further than 1 mm from where the window opened, 15× under
    // `maxDisplacement()`. The displacement bound must let it sleep. This is the
    // discriminating case between the two criteria: they agree on steady motion (a
    // constant speed under the threshold can never exceed threshold × time) and
    // disagree exactly here.
    const hop: Real = 0.001;
    bm.setLinearVelocity(box, vr(hop / dt, 0, 0)); // 0.06 m/s, above the threshold

    var t: u32 = 0;
    while (t < 20) : (t += 1) {
        bm.setPosition(box, vr(if (t % 2 == 0) hop else 0, 0, 0));
        sleep.updateWindows(&bm, dt, cfg);
    }
    // 20 ticks is 0.333 s — the window is filling but not yet full.
    try testing.expect(!sleep.isEligible(&bm, box, cfg));
    try testing.expect(bm.sleepTime(box).? > 0);

    while (t < 40) : (t += 1) {
        bm.setPosition(box, vr(if (t % 2 == 0) hop else 0, 0, 0));
        sleep.updateWindows(&bm, dt, cfg);
    }
    // 40 ticks is 0.667 s, past `time_before_sleep`: eligible despite never once
    // having been slow.
    try testing.expect(sleep.isEligible(&bm, box, cfg));

    // Crossing the bound restarts the window AND re-anchors the reference pose: one
    // step of 20 mm > 15 mm.
    const jump = vr(0.02, 0, 0);
    bm.setPosition(box, jump);
    sleep.updateWindows(&bm, dt, cfg);
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);
    try testing.expect(!sleep.isEligible(&bm, box, cfg));

    // Re-anchored: staying at the NEW pose accumulates again instead of measuring
    // against the old one (which would keep it permanently reset).
    sleep.updateWindows(&bm, dt, cfg);
    try testing.expect(bm.sleepTime(box).? > 0);
}

test "rotation alone resets the window through the sleep radius" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    const cfg = SleepConfig{};

    // A unit box's sleep radius is the half-diagonal |(0.5, 0.5, 0.5)| ≈ 0.866.
    const radius = bm.sleepRadius(box).?;
    try testing.expectApproxEqAbs(@sqrt(@as(Real, 0.75)), radius, 1e-6);

    // Pure rotation: the position never changes, so a linear-only criterion — and
    // an instantaneous-velocity one, the linear velocity being zero — would see a
    // perfectly still body. The angular step is 0.05 rad per tick, whose point
    // displacement is 2·r·sin(0.025) ≈ 43 mm, well past the 15 mm bound.
    const step: Real = 0.05;
    try testing.expect(2 * radius * @sin(step / 2) > cfg.maxDisplacement());

    var angle: Real = 0;
    var t: u32 = 0;
    while (t < 60) : (t += 1) {
        angle += step;
        bm.setRotation(box, Quatr.fromAxisAngle(Vec3r.unit_z, angle));
        sleep.updateWindows(&bm, dt, cfg);
        // Reset on every single tick: the window never gets off the ground.
        try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);
    }
    try testing.expect(!sleep.isEligible(&bm, box, cfg));
    try testing.expect(bm.position(box).?.eql(Vec3r.zero)); // it really never translated

    // Stopping the rotation lets the window fill: the bound is on MOTION, not on
    // being at some particular orientation.
    t = 0;
    while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    try testing.expect(sleep.isEligible(&bm, box, cfg));
}

test "a rotation aliased to a whole turn per tick is invisible to the window (documented limit)" {
    const gpa = testing.allocator;
    // Documents a LIMIT, not a desired behaviour: the criterion measures net
    // displacement from the reference pose, so a body completing an exact
    // revolution every tick samples as motionless and sleeps while spinning at
    // 2π/dt ≈ 377 rad/s. Inherent to any pose-sampled criterion (Jolt's tracked
    // points alias identically). Pinned so the claim in `sleep.zig`'s header
    // stays true and so a later change cannot silently alter the regime.
    const tau: Real = 2 * std.math.pi;
    const cfg = SleepConfig{};

    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    const radius = bm.sleepRadius(box).?;

    var t: u32 = 1;
    while (t <= 40) : (t += 1) {
        const q = Quatr.fromAxisAngle(Vec3r.unit_z, tau * @as(Real, @floatFromInt(t)));
        bm.setRotation(box, q);
        // Sanity: the sampled chord — the very quantity the sweep measures against
        // the creation reference, which never resets here — really is negligible.
        // What is being observed is the ALIASING, not a rotation the test forgot to
        // apply.
        const v = q.toArray();
        const chord = 2 * radius * @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        try testing.expect(chord < cfg.maxDisplacement());
        sleep.updateWindows(&bm, dt, cfg);
    }
    try testing.expect(sleep.isEligible(&bm, box, cfg));

    // Discrimination guard: the SAME loop at a half turn per tick sweeps a chord of
    // 2·r ≈ 1.73 m and never becomes eligible. So the sleep above is the aliasing of
    // a rotation that genuinely happened, not a test that rotates nothing.
    var store_half = ShapeStore{};
    defer store_half.deinit(gpa);
    var bm_half = BodyManager{};
    defer bm_half.deinit(gpa);
    const spinner = try loneBox(gpa, &store_half, &bm_half);

    t = 1;
    while (t <= 40) : (t += 1) {
        bm_half.setRotation(spinner, Quatr.fromAxisAngle(
            Vec3r.unit_z,
            std.math.pi * @as(Real, @floatFromInt(t)),
        ));
        sleep.updateWindows(&bm_half, dt, cfg);
    }
    try testing.expect(!sleep.isEligible(&bm_half, spinner, cfg));
    try testing.expectEqual(@as(Real, 0), bm_half.sleepTime(spinner).?);
}

// --- write-intent separation (§1.8.4) ------------------------------------------

/// Ground (static box, top face at y = 0.5) plus a dynamic unit box dropped from
/// `drop_y`, both at zero restitution. Returns the dynamic box.
fn groundAndBox(gpa: std.mem.Allocator, store: *ShapeStore, bm: *BodyManager, drop_y: f32) ![2]BodyId {
    const ground_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    const box_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

    var ground = descOf(0, .static, ground_shape);
    ground.restitution = 0;
    const ground_id = try bm.addBody(gpa, store, ground);

    var box = descOf(1, .dynamic, box_shape);
    box.mass = 1;
    box.restitution = 0;
    box.position = av3(0, drop_y, 0);
    const box_id = try bm.addBody(gpa, store, box);
    return .{ ground_id, box_id };
}

test "solver writes never rearm the sleep window" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const ids = try groundAndBox(gpa, &store, &bm, 1.0);
    const box = ids[1];
    const cfg = SleepConfig{};
    const solver_cfg = rigid.SolverConfig{};
    const gravity = vr(0, -9.81, 0);

    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    var cache = rigid.ContactCache{};
    defer cache.deinit(gpa);
    const pairs = [_]u64{pairKey(ids[0], ids[1])};

    // The real per-tick cycle, minus only the broadphase (the pair is fed directly)
    // and the island partition (E3). BOTH solver passes run: the velocity pass
    // writes this box's velocity on every single tick — gravity keeps adding
    // −9.81·dt and the normal solve keeps cancelling it — and the position pass
    // writes its pose while the impact penetration is being resorbed.
    //
    // If any of those four writes were treated as an external mutation, the window
    // would be restarted every tick and the box would never become eligible. That
    // is exactly what this test refuses.
    var t: u32 = 0;
    while (t < 300) : (t += 1) {
        integration.integrateVelocities(&bm, dt, gravity);
        cache.beginTick();
        try rigid.build(gpa, &constraints, &bm, &store, &pairs);
        rigid.warmStart(&bm, &cache, constraints.items);
        rigid.solveRange(&bm, constraints.items, 0, constraints.items.len, solver_cfg);
        integration.integratePositions(&bm, dt);
        _ = rigid.solvePositionRange(&bm, constraints.items, 0, constraints.items.len, solver_cfg);
        try rigid.storeContacts(gpa, &cache, constraints.items);
        cache.endTick();
        sleep.updateWindows(&bm, dt, cfg);
    }

    // The contact really is live and really is being solved every tick — otherwise
    // this would prove nothing about solver writes.
    try testing.expectEqual(@as(usize, 1), constraints.items.len);
    try testing.expect(constraints.items[0].points[0].normal_impulse > 0);
    try testing.expect(sleep.isEligible(&bm, box, cfg));
}

test "a non-activating pose write does not wake, an explicit wake does" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);

    sleep.putToSleep(&bm, box);
    try testing.expect(bm.isSleeping(box).?);

    // The four solver write paths leave a sleeper asleep.
    bm.setPosition(box, vr(3, 0, 0));
    bm.setRotation(box, Quatr.fromAxisAngle(Vec3r.unit_x, 1.0));
    bm.setLinearVelocity(box, vr(5, 0, 0));
    bm.setAngularVelocity(box, vr(0, 4, 0));
    try testing.expect(bm.isSleeping(box).?);

    // The explicit primitive does wake it, and re-anchors the window on the pose it
    // now has — not on the one it had when it fell asleep.
    bm.wakeBody(box);
    try testing.expect(!bm.isSleeping(box).?);
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);
    sleep.updateWindows(&bm, dt, SleepConfig{});
    try testing.expect(bm.sleepTime(box).? > 0); // no reset ⇒ the reference followed
}

test "an external impulse wakes a sleeping body and resets its window" {
    const gpa = testing.allocator;

    // Every activating mutator, each against a freshly sleeping body with a FULL
    // window — so "the window was reset" is observable and not merely already zero.
    inline for (.{ "impulse", "force", "torque" }) |kind| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        const box = try loneBox(gpa, &store, &bm);
        const cfg = SleepConfig{};

        var t: u32 = 0;
        while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
        try testing.expect(sleep.isEligible(&bm, box, cfg));
        sleep.putToSleep(&bm, box);
        try testing.expect(bm.isSleeping(box).?);
        try testing.expect(bm.sleepTime(box).? >= cfg.time_before_sleep);

        if (comptime std.mem.eql(u8, kind, "impulse")) {
            bm.addImpulse(box, vr(0, 1, 0));
        } else if (comptime std.mem.eql(u8, kind, "force")) {
            bm.addForce(box, vr(0, 10, 0));
        } else {
            bm.addTorque(box, vr(0, 0, 2));
        }

        try testing.expect(!bm.isSleeping(box).?);
        try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);
        try testing.expect(!sleep.isEligible(&bm, box, cfg));
    }
}

test "an activating mutator also resets the window of an already-awake body" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    const cfg = SleepConfig{};

    // §1.8.4 spells this out: an external mutation resets the window "even if the
    // body was already awake". A wake that only fired on sleepers would let a body
    // solicited every tick drift into sleep anyway.
    var t: u32 = 0;
    while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    try testing.expect(sleep.isEligible(&bm, box, cfg));
    try testing.expect(!bm.isSleeping(box).?); // never slept

    bm.addForce(box, vr(1, 0, 0));
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);
    try testing.expect(!sleep.isEligible(&bm, box, cfg));
}

test "a moving non-member wakes the island resting on it (W3)" {
    const gpa = testing.allocator;
    // The W3 half the partition test in `island_test.zig` leaves to this suite: a
    // kinematic platform is NOT an island member, so an island resting on it would
    // otherwise show nothing but eligible members and fall asleep on a support that
    // is moving.
    const cfg = SleepConfig{};

    inline for (.{ true, false }) |platform_moves| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
        defer constraints.deinit(gpa);
        var manager = rigid.IslandManager{};
        defer manager.deinit(gpa);

        const platform_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(20, 0.5, 20) } });
        const box_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        const platform = try bm.addBody(gpa, &store, descOf(0, .kinematic, platform_shape));
        var box_desc = descOf(1, .dynamic, box_shape);
        box_desc.mass = 1;
        box_desc.position = av3(0, 0.99, 0);
        const box = try bm.addBody(gpa, &store, box_desc);
        if (platform_moves) bm.setLinearVelocity(platform, vr(1, 0, 0));

        // Fill the box's window: on its own it is perfectly eligible.
        var t: u32 = 0;
        while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
        try testing.expect(sleep.isEligible(&bm, box, cfg));

        try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(platform, box)});
        try testing.expectEqual(@as(usize, 1), constraints.items.len);
        try manager.partition(gpa, &bm, constraints.items);
        try testing.expectEqual(@as(usize, 1), manager.islandsSlice().len);

        if (platform_moves) {
            // W3 is a real wake: the window is restarted, so the island cannot
            // accumulate toward sleep while the support moves.
            try testing.expect(manager.islandsSlice()[0].touches_moving_non_member);
            try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);
            try testing.expect(!sleep.isEligible(&bm, box, cfg));
            try testing.expectEqual(@as(u32, 0), manager.sleepEligibleIslands(&bm, cfg));
            try testing.expect(!bm.isSleeping(box).?);
        } else {
            // Same scene, platform at rest: nothing is disturbed and the island sleeps.
            try testing.expect(!manager.islandsSlice()[0].touches_moving_non_member);
            try testing.expect(sleep.isEligible(&bm, box, cfg));
            try testing.expectEqual(@as(u32, 1), manager.sleepEligibleIslands(&bm, cfg));
            try testing.expect(bm.isSleeping(box).?);
            // The kinematic platform is not a member, so it is never put to sleep.
            try testing.expect(!bm.isSleeping(platform).?);
        }
    }
}

test "an island sleeps only when every member is eligible (W2)" {
    const gpa = testing.allocator;
    const cfg = SleepConfig{};
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    var manager = rigid.IslandManager{};
    defer manager.deinit(gpa);

    // Two boxes in contact ⇒ one island of two members.
    const s = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var lower = descOf(0, .dynamic, s);
    lower.mass = 1;
    var upper = descOf(1, .dynamic, s);
    upper.mass = 1;
    upper.position = av3(0, 0.99, 0);
    const a = try bm.addBody(gpa, &store, lower);
    const b = try bm.addBody(gpa, &store, upper);

    var t: u32 = 0;
    while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(a, b)});
    try manager.partition(gpa, &bm, constraints.items);
    try testing.expectEqual(@as(usize, 1), manager.islandsSlice().len);
    try testing.expectEqual(@as(u32, 2), manager.islandsSlice()[0].member_to);

    // One member forbidden to sleep keeps the WHOLE island awake — the AND over
    // members, which is W2 in its operative form.
    bm.setCanSleep(b, false);
    try testing.expectEqual(@as(u32, 0), manager.sleepEligibleIslands(&bm, cfg));
    try testing.expect(!bm.isSleeping(a).?);
    try testing.expect(!bm.isSleeping(b).?);

    // Allowing it again is not enough on its own: `setCanSleep(false)` woke it, so
    // its window has to refill before the island qualifies.
    bm.setCanSleep(b, true);
    try testing.expectEqual(@as(u32, 0), manager.sleepEligibleIslands(&bm, cfg));
    t = 0;
    while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    try testing.expectEqual(@as(u32, 1), manager.sleepEligibleIslands(&bm, cfg));
    try testing.expect(bm.isSleeping(a).?);
    try testing.expect(bm.isSleeping(b).?);
}

// --- the two switches -----------------------------------------------------------

test "can_sleep false never sleeps" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var d = descOf(0, .dynamic, s);
    d.mass = 1;
    d.can_sleep = false;
    const box = try bm.addBody(gpa, &store, d);
    const cfg = SleepConfig{}; // sleeping globally ENABLED — this switch is per body

    try testing.expect(!bm.canSleep(box).?);
    var t: u32 = 0;
    while (t < 120) : (t += 1) sleep.updateWindows(&bm, dt, cfg);

    // The window still fills — the flag gates ELIGIBILITY, not the measurement, so
    // the debug overlay keeps showing a truthful window.
    try testing.expect(bm.sleepTime(box).? >= cfg.time_before_sleep);
    try testing.expect(!sleep.isEligible(&bm, box, cfg));

    // Flipping it on makes the very same body eligible: nothing else differed.
    bm.setCanSleep(box, true);
    try testing.expect(sleep.isEligible(&bm, box, cfg));
}

test "allow_sleeping false never sleeps" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm); // can_sleep defaults to TRUE
    const off = SleepConfig{ .allow_sleeping = false };

    try testing.expect(bm.canSleep(box).?);
    var t: u32 = 0;
    while (t < 120) : (t += 1) sleep.updateWindows(&bm, dt, off);
    try testing.expect(!sleep.isEligible(&bm, box, off));

    // The switch is global and nothing else: the same body, the same window, with
    // sleeping enabled, is eligible.
    try testing.expect(sleep.isEligible(&bm, box, SleepConfig{}));
}

test "setCanSleep false wakes a sleeping body" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);

    sleep.putToSleep(&bm, box);
    try testing.expect(bm.isSleeping(box).?);

    // Wake cause W1 (§1.8.5): a body that may no longer sleep must not stay asleep.
    bm.setCanSleep(box, false);
    try testing.expect(!bm.isSleeping(box).?);
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(box).?);

    // Re-allowing does NOT put it back to sleep — that decision belongs to the
    // island arbitration at step 11, never to a flag write.
    bm.setCanSleep(box, true);
    try testing.expect(!bm.isSleeping(box).?);
}

// --- the transition -------------------------------------------------------------

test "falling asleep zeroes both velocities exactly" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);

    bm.setLinearVelocity(box, vr(0.017, -0.004, 0.009));
    bm.setAngularVelocity(box, vr(-0.006, 0.011, 0.002));
    sleep.putToSleep(&bm, box);

    // EXACT zero, not an approximate comparison: the residue is discarded outright,
    // which is what guarantees a woken body cannot resume on a stale velocity.
    inline for (0..3) |k| {
        try testing.expectEqual(@as(Real, 0), bm.linearVelocity(box).?.toArray()[k]);
        try testing.expectEqual(@as(Real, 0), bm.angularVelocity(box).?.toArray()[k]);
    }
    try testing.expect(bm.isSleeping(box).?);
}

test "a sleeping body's window and pose are frozen by the sweep" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    const cfg = SleepConfig{};

    var t: u32 = 0;
    while (t < 40) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    const window_at_sleep = bm.sleepTime(box).?;
    sleep.putToSleep(&bm, box);

    // The sweep skips sleepers (§1.8.6, cycle step 11): the window neither advances
    // nor resets, so the state a body fell asleep with is exactly the state it wakes
    // in.
    t = 0;
    while (t < 120) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    try testing.expectEqual(window_at_sleep, bm.sleepTime(box).?);
    try testing.expect(bm.isSleeping(box).?);
}

test "static and kinematic bodies are skipped by the window sweep" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const st = try bm.addBody(gpa, &store, descOf(0, .static, s));
    const kin = try bm.addBody(gpa, &store, descOf(1, .kinematic, s));
    const cfg = SleepConfig{};

    // Neither ever joins an island (§1.8.1), so their window is never read and the
    // sweep does not pay for it. Observable as the window staying at zero.
    var t: u32 = 0;
    while (t < 120) : (t += 1) sleep.updateWindows(&bm, dt, cfg);
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(st).?);
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(kin).?);
}

test "sleep config defaults and derived max displacement" {
    const cfg = SleepConfig{};
    try testing.expectEqual(true, cfg.allow_sleeping);
    try testing.expectEqual(@as(Real, 0.03), cfg.point_velocity_threshold);
    try testing.expectEqual(@as(Real, 0.5), cfg.time_before_sleep);
    // 15 mm at the defaults — the product, never a literal.
    try testing.expectApproxEqAbs(@as(Real, 0.015), cfg.maxDisplacement(), 1e-9);
    sleep.assertDomain(cfg);
}

test "a stale handle is inert on every sleep entry" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    bm.removeBody(box);

    try testing.expectEqual(@as(?bool, null), bm.isSleeping(box));
    try testing.expectEqual(@as(?Real, null), bm.sleepTime(box));
    try testing.expectEqual(@as(?bool, null), bm.canSleep(box));
    try testing.expectEqual(@as(?Real, null), bm.sleepRadius(box));
    try testing.expect(!sleep.isEligible(&bm, box, SleepConfig{}));
    bm.wakeBody(box);
    bm.setCanSleep(box, false);
    sleep.putToSleep(&bm, box);
    sleep.updateWindows(&bm, dt, SleepConfig{}); // the dead slot is skipped
}

// --- the wake fixpoint in `build` (§1.8.5) ---------------------------------------

/// A stack of `n` unit boxes at x = 0, each 0.99 above the previous, all dynamic.
fn stackOfBoxes(
    gpa: std.mem.Allocator,
    store: *ShapeStore,
    bm: *BodyManager,
    comptime n: usize,
    base_y: f32,
) ![n]BodyId {
    const s = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var ids: [n]BodyId = undefined;
    for (0..n) |i| {
        var d = descOf(@intCast(i), .dynamic, s);
        d.mass = 1;
        d.position = av3(0, base_y + @as(f32, @floatFromInt(i)) * 0.99, 0);
        ids[i] = try bm.addBody(gpa, store, d);
    }
    return ids;
}

/// Every pair of `ids`, sorted ascending — the candidate set `build` consumes.
fn allPairs(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u64), ids: []const BodyId) !void {
    out.clearRetainingCapacity();
    for (ids, 0..) |a, i| {
        for (ids[i + 1 ..]) |b| try out.append(gpa, pairKey(a, b));
    }
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

test "build skips a pair whose endpoints are both non-awake" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);

    const ground_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(20, 0.5, 20) } });
    const box_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const ground = try bm.addBody(gpa, &store, descOf(0, .static, ground_shape));
    var box_desc = descOf(1, .dynamic, box_shape);
    box_desc.mass = 1;
    box_desc.position = av3(0, 0.99, 0);
    const box = try bm.addBody(gpa, &store, box_desc);
    const pairs = [_]u64{pairKey(ground, box)};

    // Awake: the contact is built as usual.
    try rigid.build(gpa, &constraints, &bm, &store, &pairs);
    try testing.expectEqual(@as(usize, 1), constraints.items.len);

    // Asleep against a STATIC ground: both endpoints are non-awake, so the pair is
    // skipped — zero narrowphase, zero `prepare`, no constraint. Note the static
    // ground has no `sleeping` flag of its own (the window sweep never touches it),
    // which is exactly why the predicate cannot be "both flags set".
    sleep.putToSleep(&bm, box);
    try rigid.build(gpa, &constraints, &bm, &store, &pairs);
    try testing.expectEqual(@as(usize, 0), constraints.items.len);
    try testing.expect(bm.isSleeping(box).?); // and nothing woke it
}

test "build wakes a sleeping endpoint as soon as a manifold appears" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);

    const ids = try stackOfBoxes(gpa, &store, &bm, 2, 0);
    sleep.putToSleep(&bm, ids[0]);
    try testing.expect(bm.isSleeping(ids[0]).?);
    try testing.expect(!bm.isSleeping(ids[1]).?); // the other stays awake

    try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(ids[0], ids[1])});

    try testing.expectEqual(@as(usize, 1), constraints.items.len);
    try testing.expect(!bm.isSleeping(ids[0]).?);
    try testing.expectEqual(@as(Real, 0), bm.sleepTime(ids[0]).?); // window restarted
}

test "the wake fixpoint reaches a whole sleeping chain in one build" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    var pairs: std.ArrayListUnmanaged(u64) = .empty;
    defer pairs.deinit(gpa);

    // Three stacked boxes, all asleep, plus an awake impactor arriving from below.
    // Only the impactor↔bottom pair has an awake endpoint on the first scan; without
    // the fixpoint the wake would crawl up one layer per tick, leaving the bottom box
    // awake with the rest of the stack still frozen on top of it.
    const stack = try stackOfBoxes(gpa, &store, &bm, 3, 0);
    const impactor_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var impactor_desc = descOf(3, .dynamic, impactor_shape);
    impactor_desc.mass = 1;
    impactor_desc.position = av3(0, -0.99, 0);
    const impactor = try bm.addBody(gpa, &store, impactor_desc);

    for (stack) |id| sleep.putToSleep(&bm, id);
    for (stack) |id| try testing.expect(bm.isSleeping(id).?);

    const all = [_]BodyId{ stack[0], stack[1], stack[2], impactor };
    try allPairs(gpa, &pairs, &all);
    try rigid.build(gpa, &constraints, &bm, &store, pairs.items);

    // ONE build call: every member of the chain is awake and its internal contacts
    // are back — the impactor's plus the stack's two.
    for (stack) |id| try testing.expect(!bm.isSleeping(id).?);
    try testing.expectEqual(@as(usize, 3), constraints.items.len);

    // Output order is unaffected by the deferred re-scan: still ascending pair key.
    for (constraints.items, 0..) |c, i| {
        if (i > 0) try testing.expect(constraints.items[i - 1].pair_key < c.pair_key);
    }
}

test "a moving kinematic support wakes the sleeper resting on it" {
    const gpa = testing.allocator;
    // The case W3 cannot close, because W3 only protects island MEMBERS and a
    // sleeping body is not one. At step 4 the poses have not been integrated yet, so
    // the manifold with the platform still exists; treating a MOVING kinematic body
    // as awake is what keeps that pair narrowphased, and the fixpoint then wakes the
    // box. From the next tick on it is a member and W3 takes over.
    inline for (.{ true, false }) |platform_moves| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
        defer constraints.deinit(gpa);

        const platform_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(20, 0.5, 20) } });
        const box_shape = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        const platform = try bm.addBody(gpa, &store, descOf(0, .kinematic, platform_shape));
        var box_desc = descOf(1, .dynamic, box_shape);
        box_desc.mass = 1;
        box_desc.position = av3(0, 0.99, 0);
        const box = try bm.addBody(gpa, &store, box_desc);

        sleep.putToSleep(&bm, box);
        if (platform_moves) bm.setLinearVelocity(platform, vr(1, 0, 0));
        try rigid.build(gpa, &constraints, &bm, &store, &.{pairKey(platform, box)});

        if (platform_moves) {
            try testing.expect(!bm.isSleeping(box).?);
            try testing.expectEqual(@as(usize, 1), constraints.items.len);
        } else {
            // A kinematic platform at rest is not a motion source: both endpoints are
            // non-awake and the pair costs nothing.
            try testing.expect(bm.isSleeping(box).?);
            try testing.expectEqual(@as(usize, 0), constraints.items.len);
        }
    }
}

// --- integration skips (§1.8.6) --------------------------------------------------

test "integration skips a sleeping body but still clears its accumulators" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);
    const no_gravity = Vec3r.zero;

    // `addForce` is activating, so the force lands on an awake body; put it to sleep
    // straight after, leaving a pending force on a sleeper.
    bm.addForce(box, vr(0, 100, 0));
    sleep.putToSleep(&bm, box);

    integration.integrateVelocities(&bm, dt, no_gravity);
    // Not integrated: the 100 N never became velocity.
    inline for (0..3) |k| try testing.expectEqual(@as(Real, 0), bm.linearVelocity(box).?.toArray()[k]);

    // But the accumulator WAS cleared — the reset is uniform over every live body
    // (§2). Waking the body and integrating again must not fire a stale force.
    bm.wakeBody(box);
    integration.integrateVelocities(&bm, dt, no_gravity);
    inline for (0..3) |k| try testing.expectEqual(@as(Real, 0), bm.linearVelocity(box).?.toArray()[k]);
}

test "integratePositions leaves a sleeping body bit-frozen" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try loneBox(gpa, &store, &bm);

    sleep.putToSleep(&bm, box);
    // A NON-activating write, so the body stays asleep while carrying a velocity that
    // would move it a long way — exactly what the skip has to ignore.
    bm.setLinearVelocity(box, vr(5, 0, 0));
    bm.setAngularVelocity(box, vr(0, 3, 0));
    const before_position = bm.position(box).?.toArray();
    const before_rotation = bm.rotation(box).?.toArray();

    var t: u32 = 0;
    while (t < 60) : (t += 1) integration.integratePositions(&bm, dt);

    inline for (0..3) |k| try testing.expectEqual(before_position[k], bm.position(box).?.toArray()[k]);
    inline for (0..4) |k| try testing.expectEqual(before_rotation[k], bm.rotation(box).?.toArray()[k]);

    // Waking it re-enters the integration, so the freeze was the sleep and not the
    // velocity being ignored outright.
    bm.wakeBody(box);
    integration.integratePositions(&bm, dt);
    try testing.expect(bm.position(box).?.toArray()[0] > before_position[0]);
}
