//! M1.1.7 acceptance suite for the NGS position solver
//! (`engine-physics-forge.md` §1.7.2), driven through the full per-tick pipeline.
//!
//! The harness is NOT duplicated here: `World` comes from `solver_test.zig`, which
//! owns the single definition of the normative per-tick cycle (its file header
//! documents the eight steps). Copying it would let the two suites drift apart on
//! the one thing that must not drift.

const std = @import("std");
const config = @import("../config.zig");
const harness = @import("solver_test.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const World = harness.World;
const vr = harness.vr;
const av3 = harness.av3;
const groundAndBox = harness.groundAndBox;
const BodyId = api.BodyId;
const testing = std.testing;

const gravity = -9.81;
const fixed_dt = 1.0 / 60.0;

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

/// Fill `out` with `out.len` unit boxes (half-extents 0.5) stacked flush above a
/// ground whose top face is at `base_y + 0.5`: box `i` starts at its analytic rest
/// height `base_y + 1.0 + i`, so the stack begins with zero penetration everywhere.
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

test "position_iterations = 0 reproduces the velocity-only resting behaviour" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    // The M1.1.6 configuration: velocity pass only, no position correction at all.
    world.cfg.position_iterations = 0;
    const box = try groundAndBox(gpa, &world, 2.0, 0);

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

    // The pass early-returns before evaluating a single point.
    try testing.expectEqual(@as(u32, 0), world.position_result.iterations_run);
    try testing.expectEqual(@as(?Real, null), world.position_result.min_separation);

    // The M1.1.6 statement, preserved verbatim: the penetration is bounded at its
    // at-impact value and never recovered.
    try testing.expect(y_impact != null);
    try testing.expect(min_after_impact >= y_impact.? - 1e-3);
    try testing.expectApproxEqAbs(y_impact.?, y_final, 1e-3);

    // Discrimination guard: this rest is measurably BELOW the envelope the same
    // scene satisfies with the position pass enabled (`solver_test.zig`'s tightened
    // resting test), so the pin really observes the absence of NGS, not a scene
    // that happens to land near the analytic rest anyway. Read from the config, so
    // the guard follows the slop instead of decoupling if the default moves.
    try testing.expect(y_final < 1.0 - 2 * world.cfg.penetration_slop);
}

// --- named envelopes ---------------------------------------------------------
//
// Every margin below is a measured value with headroom, never a tuning knob.
//
// `rest_margin` — how far under `n · penetration_slop` a body in an n-deep contact
// chain may sit. The slop is the exact fixed point of ONE contact; a chain also
// accumulates, per contact, the residual the velocity pass has not propagated down
// it at the default 8 iterations (measured ≈ 1.4 mm per contact). Worst case over
// the suite: 6.1 mm below 5·slop for the top box of the five-box stack (f64;
// 2.8 mm at f32). 10 mm leaves 1.6× headroom.
const rest_margin: Real = 1e-2;
// `rest_overshoot` — NGS approaches its fixed point from below and never crosses
// it, so a body may not sit ABOVE its analytic rest height by more than float
// noise. Same bound as the tightened M1.1.6 resting test.
const rest_overshoot: Real = 1e-4;
// `settle_speed` — residual speed allowed in the last second of a run. The bound is
// PHYSICAL, not fitted: the speed a free-falling body picks up in a single tick
// (`g·dt`). Below it, no body is in sustained free fall — every contact is removing
// its gravity impulse each tick, which is what "not bouncing" means. A single box
// and short chains stop dead (measured 0.0 m/s); a five-deep chain keeps a residual
// motion at the default 8 velocity iterations (measured 0.047 m/s at f32, 0.075 at
// f64, and 0.0 from 16 iterations on) — a Sequential Impulses convergence property
// of the ITERATION BUDGET, not of the position pass. Worst case is 2.2× inside.
const settle_speed: Real = 9.81 * fixed_dt;
// `lateral_bound` — sideways creep allowed over the run. Gauss-Seidel visits the
// four points of a face manifold in sequence, so each pass leaves a small residual
// tilt; in a tall chain that the velocity pass has not fully equilibrated, the tilt
// walks the stack. Measured 0.081 m for the top box of the five-box stack at tick
// 600 (0.022 m at 16 velocity iterations); 0.15 m leaves 1.9× headroom.
const lateral_bound: Real = 0.15;
// `noise_margin` — float noise of a separation reconstructed from two world
// coordinates, in the M1.1.4 `k·floatEps·coordScale` form. `coord_scale` is passed
// per scene because the far-from-origin test works at 5 km.
fn noiseMargin(coord_scale: Real) Real {
    return 16 * std.math.floatEps(Real) * coord_scale;
}

/// Deepest penetration reported by the manifolds currently held by `world`.
fn deepestPenetration(world: *const World) Real {
    var deepest: Real = 0;
    for (world.constraints.items) |c| {
        for (0..c.count) |i| deepest = @max(deepest, c.points[i].penetration);
    }
    return deepest;
}

test "a stack of five boxes is stable" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, gravity, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, 0);
    var boxes: [5]BodyId = undefined;
    try addStack(gpa, &world, &boxes, 0, 1);

    var max_speed_late: Real = 0;
    var t: u32 = 0;
    while (t < 600) : (t += 1) {
        try world.step(gpa);
        if (t >= 540) { // the last second
            for (boxes) |b| max_speed_late = @max(max_speed_late, world.bm.linearVelocity(b).?.length());
        }
    }

    for (boxes, 0..) |b, i| {
        // Box `i` rests on `i + 1` contacts, each holding one slop of overlap.
        const analytic = 1.0 + @as(Real, @floatFromInt(i));
        const allowed_sink = @as(Real, @floatFromInt(i + 1)) * world.cfg.penetration_slop + rest_margin;
        const y = world.bm.position(b).?.toArray()[1];
        try testing.expect(y >= analytic - allowed_sink);
        try testing.expect(y <= analytic + rest_overshoot);
        try testing.expect(lateralOffset(&world, b, 0, 0) <= lateral_bound);
    }
    try testing.expect(max_speed_late <= settle_speed);

    // Determinism: an identical second run reproduces every pose bit-for-bit.
    var replay = World.init(vr(0, gravity, 0), fixed_dt);
    defer replay.deinit(gpa);
    _ = try addGround(gpa, &replay, 0);
    var replay_boxes: [5]BodyId = undefined;
    try addStack(gpa, &replay, &replay_boxes, 0, 1);
    t = 0;
    while (t < 600) : (t += 1) try replay.step(gpa);
    for (boxes, replay_boxes) |a, b| {
        const pa = world.bm.position(a).?.toArray();
        const pb = replay.bm.position(b).?.toArray();
        const qa = world.bm.rotation(a).?.toArray();
        const qb = replay.bm.rotation(b).?.toArray();
        inline for (0..3) |k| try testing.expectEqual(pa[k], pb[k]);
        inline for (0..4) |k| try testing.expectEqual(qa[k], qb[k]);
    }
}

test "a heavy box resting on a light box does not sink through" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, gravity, 0), fixed_dt);
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
    heavy.mass = 10; // 10:1 mass ratio — the property §1.6 claims for SI + NGS
    heavy.position = av3(0, 2, 0);
    const heavy_id = try world.addBody(gpa, heavy);

    var t: u32 = 0;
    while (t < 600) : (t += 1) try world.step(gpa);

    // The light box is not crushed through the ground, and the heavy one is not
    // crushed through the light one: each stays within its slop chain.
    const y_light = world.bm.position(light_id).?.toArray()[1];
    const y_heavy = world.bm.position(heavy_id).?.toArray()[1];
    try testing.expect(y_light >= 1.0 - (world.cfg.penetration_slop + rest_margin));
    try testing.expect(y_light <= 1.0 + rest_overshoot);
    try testing.expect(y_heavy >= 2.0 - (2 * world.cfg.penetration_slop + rest_margin));
    try testing.expect(y_heavy <= 2.0 + rest_overshoot);
}

test "a stack far from the origin along the contact normal still settles" {
    const gpa = testing.allocator;
    // The offset is ALONG the contact normal: that is the configuration exercising
    // the `(p_b − p_a)·n` cancellation, where both terms are ≈ 5000 and their
    // difference is a few millimetres. At f32 the noise there is
    // `floatEps · 5000 ≈ 0.6 mm` against a 5 mm slop — the worldspace precision
    // characteristic §1.7.2 documents, with a positive but thin margin. An offset
    // PERPENDICULAR to the normal would not exercise it.
    const base: f32 = 5000;
    var world = World.init(vr(0, gravity, 0), fixed_dt);
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
        const allowed_sink = @as(Real, @floatFromInt(i + 1)) * world.cfg.penetration_slop +
            rest_margin + noiseMargin(base);
        const y = world.bm.position(b).?.toArray()[1];
        try testing.expect(y >= analytic - allowed_sink);
        try testing.expect(y <= analytic + rest_overshoot + noiseMargin(base));
    }
    try testing.expect(max_speed_late <= settle_speed);
}

test "a tilted anisotropic box resorbs penetration without lateral drift" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, gravity, 0), fixed_dt);
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

    // Normal direction: the box flattened onto the ground and rests one slop under
    // the flush height (ground top 0.5 + half-thickness 0.1).
    const p = world.bm.position(id).?.toArray();
    try testing.expect(p[1] >= 0.6 - (world.cfg.penetration_slop + rest_margin));
    try testing.expect(p[1] <= 0.6 + rest_overshoot);
    try testing.expect(deepestPenetration(&world) <= world.cfg.penetration_slop + noiseMargin(1.0));

    // Tangential: the tip-over displaces the centre once (measured 3.3 cm), but the
    // settled box must not creep afterwards — the position correction is along the
    // normal, so it may not walk the box sideways. Measured creep over the second
    // half of the run: exactly 0.
    const creep = @sqrt((p[0] - mid_x) * (p[0] - mid_x) + (p[2] - mid_z) * (p[2] - mid_z));
    const creep_bound: Real = 1e-3; // 1 mm over 5 s; measured 0
    try testing.expect(creep <= creep_bound);
    try testing.expect(lateralOffset(&world, id, 0, 0) <= lateral_bound);
}

test "reference face carried by B still resorbs penetration" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, gravity, 0), fixed_dt);
    defer world.deinit(gpa);

    // The sphere is added FIRST so it holds the lower BodyId: the canonical pair is
    // (sphere = A, box = B), hence `a_is_ref == false` — the reference face is the
    // BOX's top face, the case §1.7.2 cites for why the normal may not be attached
    // to A.
    const sphere_shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.3 } });
    var sphere = api.BodyDescriptor{ .entity = .{ .index = 0, .generation = 0 }, .body_type = .dynamic, .shape = sphere_shape };
    sphere.mass = 1;
    sphere.restitution = 0;
    sphere.position = av3(0, 0.74, 0); // flush would be 0.8 ⇒ 6 cm of penetration
    const sphere_id = try world.addBody(gpa, sphere);

    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(3, 0.5, 3) } });
    var box = api.BodyDescriptor{ .entity = .{ .index = 1, .generation = 0 }, .body_type = .static, .shape = box_shape };
    box.restitution = 0;
    _ = try world.addBody(gpa, box);

    try world.step(gpa);
    try testing.expectEqual(@as(usize, 1), world.constraints.items.len);
    // Indirect assertion that the reference feature is B's face: the contact axis is
    // the box top face's normal (negated, since it points A→B = sphere→box). A
    // sphere carries no face, so an A-owned reference could not produce this axis.
    try testing.expect(world.constraints.items[0].normal.approxEql(vr(0, -1, 0), 1e-4));
    try testing.expect(world.constraints.items[0].points[0].penetration > 0.05);

    var t: u32 = 0;
    while (t < 300) : (t += 1) try world.step(gpa);

    try testing.expect(deepestPenetration(&world) <= world.cfg.penetration_slop + noiseMargin(1.0));
    const y = world.bm.position(sphere_id).?.toArray()[1];
    try testing.expect(y >= 0.8 - (world.cfg.penetration_slop + rest_margin));
    try testing.expect(y <= 0.8 + rest_overshoot);
}

test "BodyId order permutation converges to the same poses" {
    const gpa = testing.allocator;
    // The same physical scene, built with the two bodies added in swapped order:
    // the canonical pair flips (`A`/`B` roles, normal sign, reference face), so the
    // two runs are NOT bit-identical — they must nonetheless converge to the same
    // rest.
    var ground_first = World.init(vr(0, gravity, 0), fixed_dt);
    defer ground_first.deinit(gpa);
    _ = try addGround(gpa, &ground_first, 0);
    var boxes_a: [1]BodyId = undefined;
    try addStack(gpa, &ground_first, &boxes_a, 0, 1);

    var box_first = World.init(vr(0, gravity, 0), fixed_dt);
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

    // Converged heights agree to the float noise of the two orders' arithmetic.
    const order_tolerance: Real = 1e-4;
    try testing.expectApproxEqAbs(
        ground_first.bm.position(boxes_a[0]).?.toArray()[1],
        box_first.bm.position(box_id).?.toArray()[1],
        order_tolerance,
    );
}
