//! M1.1.5 acceptance suite for semi-implicit Euler integration. E2 covers the
//! linear half (gravity as acceleration, clamped-linear damping, position from
//! the new velocity) plus the discrete free-fall oracle, force consumption,
//! impulse, static/kinematic invariance, freed-slot skipping, and determinism.
//! E3 adds the angular tests to this same file.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const integration = @import("../pipeline/integration.zig");
const api = @import("weld_forge");
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const Vec3 = math.Vec3; // f32 descriptor vector
const testing = std.testing;

// --- helpers -----------------------------------------------------------------

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// A dynamic descriptor with damping forced to 0 (the descriptor default is
/// 0.05; the integration tests set damping explicitly where they exercise it).
fn dynDesc(entity_index: u32, shape: api.ShapeId) api.BodyDescriptor {
    return .{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
        .linear_damping = 0,
    };
}

// --- E2 tests ----------------------------------------------------------------

test "free fall matches the discrete semi-implicit oracle" {
    // Semi-implicit Euler integrates v then x from the *new* v, so after N steps
    // x = x0 + N·v0·dt + g·dt²·N(N+1)/2 — NOT the continuous parabola. At 60 Hz
    // over 1 s with v0 = 0 that is −4.98675 m (the continuous value is −4.905,
    // 0.08 m away), while v = N·g·dt = −9.81 m/s matches the continuous velocity.
    //
    // Named tolerance: 60 f32 accumulations at |x| ≈ 5 carry ~60 ULP ≈ 1e-4 of
    // rounding; 1e-3 bounds that and still excludes the continuous −4.905. f64 is
    // ~9 orders tighter, so the same bound holds there too.
    const oracle_tol: Real = 1e-3;
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const id = try bm.addBody(gpa, &store, dynDesc(0, s));

    const dt: Real = 1.0 / 60.0;
    const g = vr(0, -9.81, 0);
    var step: u32 = 0;
    while (step < 60) : (step += 1) integration.integrate(&bm, dt, g);

    const pos = bm.position(id).?.toArray();
    const vel = bm.linearVelocity(id).?.toArray();
    try testing.expectApproxEqAbs(@as(Real, -4.98675), pos[1], oracle_tol);
    try testing.expectApproxEqAbs(@as(Real, -9.81), vel[1], oracle_tol);
    // X and Z stay put — gravity is Y-only.
    try testing.expectApproxEqAbs(@as(Real, 0), pos[0], oracle_tol);
    try testing.expectApproxEqAbs(@as(Real, 0), pos[2], oracle_tol);
}

test "free fall is mass-independent" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    var light = dynDesc(0, s);
    light.mass = 1;
    var heavy = dynDesc(1, s);
    heavy.mass = 1000;
    const id_light = try bm.addBody(gpa, &store, light);
    const id_heavy = try bm.addBody(gpa, &store, heavy);

    const dt: Real = 1.0 / 60.0;
    const g = vr(0, -9.81, 0);
    var step: u32 = 0;
    while (step < 30) : (step += 1) integration.integrate(&bm, dt, g);

    // Gravity is an acceleration, so the two trajectories are bit-identical.
    const pl = bm.position(id_light).?.toArray();
    const ph = bm.position(id_heavy).?.toArray();
    const vl = bm.linearVelocity(id_light).?.toArray();
    const vh = bm.linearVelocity(id_heavy).?.toArray();
    inline for (0..3) |k| {
        try testing.expectEqual(pl[k], ph[k]);
        try testing.expectEqual(vl[k], vh[k]);
    }
}

test "gravity_factor scales the fall" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    var full = dynDesc(0, s);
    full.gravity_factor = 1.0;
    var half = dynDesc(1, s);
    half.gravity_factor = 0.5;
    var none = dynDesc(2, s);
    none.gravity_factor = 0.0;
    const id_full = try bm.addBody(gpa, &store, full);
    const id_half = try bm.addBody(gpa, &store, half);
    const id_none = try bm.addBody(gpa, &store, none);

    const dt: Real = 1.0 / 60.0;
    const g = vr(0, -9.81, 0);
    integration.integrate(&bm, dt, g);

    const v_full = bm.linearVelocity(id_full).?.toArray()[1];
    const v_half = bm.linearVelocity(id_half).?.toArray()[1];
    const v_none = bm.linearVelocity(id_none).?.toArray()[1];
    try testing.expectApproxEqAbs(@as(Real, -9.81) * dt, v_full, 1e-6);
    try testing.expectApproxEqAbs(v_full * 0.5, v_half, 1e-6); // half the acceleration
    try testing.expectEqual(@as(Real, 0), v_none); // no gravity contribution
}

test "linear damping bends the trajectory and clamps" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const dt: Real = 1.0 / 60.0;
    const g = vr(0, -9.81, 0);

    // Bend: after one step, |v_damped| < |v_undamped| (both fall, damped less).
    var undamped = dynDesc(0, s);
    undamped.linear_damping = 0;
    var damped = dynDesc(1, s);
    damped.linear_damping = 0.5;
    const id_undamped = try bm.addBody(gpa, &store, undamped);
    const id_damped = try bm.addBody(gpa, &store, damped);
    integration.integrate(&bm, dt, g);
    const v_undamped = bm.linearVelocity(id_undamped).?.toArray()[1];
    const v_damped = bm.linearVelocity(id_damped).?.toArray()[1];
    try testing.expect(v_damped < 0); // still moving down
    try testing.expect(v_damped > v_undamped); // less negative ⇒ smaller magnitude

    // Clamp: d·dt > 1 ⇒ factor max(0, 1−d·dt) = 0 ⇒ velocity zeroed, no sign flip.
    var clamp = dynDesc(2, s);
    clamp.linear_damping = 100; // 100/60 = 1.667 > 1
    const id_clamp = try bm.addBody(gpa, &store, clamp);
    bm.setLinearVelocity(id_clamp, vr(3, -5, 2));
    integration.integrate(&bm, dt, vr(0, 0, 0)); // no gravity, isolate the clamp
    const v_clamp = bm.linearVelocity(id_clamp).?;
    try testing.expect(v_clamp.approxEql(Vec3r.zero, 0)); // exactly zero, no flip
}

test "forces are consumed once per tick" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    var d = dynDesc(0, s);
    d.mass = 2;
    const id = try bm.addBody(gpa, &store, d);
    const idx = bm.alloc.validate(id).?;

    const dt: Real = 1.0 / 60.0;
    const zero_gravity = vr(0, 0, 0);
    bm.addForce(id, vr(10, 0, 0));
    integration.integrate(&bm, dt, zero_gravity); // a = F/m = 5 ⇒ v = 5·dt
    const v_after_1 = bm.linearVelocity(id).?.toArray()[0];
    try testing.expectApproxEqAbs(@as(Real, 5) * dt, v_after_1, 1e-6);
    // Accumulator cleared by the first tick.
    try testing.expect(bm.bodies.items(.force)[idx].approxEql(Vec3r.zero, 0));

    // Second tick with no re-apply: no force contribution ⇒ velocity unchanged.
    integration.integrate(&bm, dt, zero_gravity);
    const v_after_2 = bm.linearVelocity(id).?.toArray()[0];
    try testing.expectEqual(v_after_1, v_after_2);
}

test "impulse is an immediate velocity change" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Dynamic: Δv = impulse · inv_mass, applied immediately (before any integrate).
    var d = dynDesc(0, s);
    d.mass = 4;
    const id = try bm.addBody(gpa, &store, d);
    bm.addImpulse(id, vr(8, 0, -4));
    try testing.expect(bm.linearVelocity(id).?.approxEql(vr(2, 0, -1), 1e-6));

    // Static: inv_mass == 0 ⇒ no change.
    const stat = try bm.addBody(gpa, &store, .{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .static,
        .shape = s,
    });
    bm.addImpulse(stat, vr(100, 100, 100));
    try testing.expect(bm.linearVelocity(stat).?.approxEql(Vec3r.zero, 0));
}

test "static and kinematic bodies are not integrated" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const dt: Real = 1.0 / 60.0;
    const g = vr(0, -9.81, 0);

    // Static at a fixed pose, with a force applied.
    var stat = api.BodyDescriptor{
        .entity = .{ .index = 0, .generation = 0 },
        .body_type = .static,
        .shape = s,
    };
    stat.position = Vec3.fromArray(.{ 1, 2, 3 });
    const id_stat = try bm.addBody(gpa, &store, stat);
    bm.addForce(id_stat, vr(50, 50, 50));

    // Kinematic with a velocity set (no position-from-velocity in M1.1.5) and a force.
    var kin = api.BodyDescriptor{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .kinematic,
        .shape = s,
    };
    kin.position = Vec3.fromArray(.{ 4, 5, 6 });
    const id_kin = try bm.addBody(gpa, &store, kin);
    bm.setLinearVelocity(id_kin, vr(1, 0, 0));
    bm.addForce(id_kin, vr(50, 50, 50));

    integration.integrate(&bm, dt, g);

    // Neither moved.
    try testing.expect(bm.position(id_stat).?.approxEql(vr(1, 2, 3), 0));
    try testing.expect(bm.position(id_kin).?.approxEql(vr(4, 5, 6), 0));
    // Kinematic velocity is untouched (not consumed as position-from-velocity).
    try testing.expect(bm.linearVelocity(id_kin).?.approxEql(vr(1, 0, 0), 0));
    // But their accumulators ARE cleared (§2 uniform reset).
    const i_stat = bm.alloc.validate(id_stat).?;
    const i_kin = bm.alloc.validate(id_kin).?;
    try testing.expect(bm.bodies.items(.force)[i_stat].approxEql(Vec3r.zero, 0));
    try testing.expect(bm.bodies.items(.force)[i_kin].approxEql(Vec3r.zero, 0));
}

test "freed slots are skipped" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const dt: Real = 1.0 / 60.0;
    const g = vr(0, -9.81, 0);
    const one_step: Real = -9.81 * dt * dt; // x after 1 semi-implicit step from rest

    const a = try bm.addBody(gpa, &store, dynDesc(0, s));
    const b = try bm.addBody(gpa, &store, dynDesc(1, s));
    bm.removeBody(a); // dead slot between live ones — must be skipped, no crash

    integration.integrate(&bm, dt, g); // step 1: b falls one step, a's slot skipped

    // A body created in the reused slot integrates correctly from its own start.
    const c = try bm.addBody(gpa, &store, dynDesc(2, s));
    try testing.expectEqual(
        api.PackedId.unpack(a).index,
        api.PackedId.unpack(c).index,
    ); // c reused a's freed slot

    integration.integrate(&bm, dt, g); // step 2: b falls again, c falls once

    try testing.expectApproxEqAbs(one_step * 3.0, bm.position(b).?.toArray()[1], 1e-6); // 2 steps: g·dt²·(1+2)
    try testing.expectApproxEqAbs(one_step, bm.position(c).?.toArray()[1], 1e-6); // 1 step
}

test "integration is deterministic" {
    const gpa = testing.allocator;
    const Runner = struct {
        fn run(g_alloc: std.mem.Allocator, out_pos: *[4][3]Real, out_vel: *[4][3]Real) !void {
            var store = ShapeStore{};
            defer store.deinit(g_alloc);
            var bm = BodyManager{};
            defer bm.deinit(g_alloc);
            const s = try store.createShape(g_alloc, .{ .sphere = .{} });

            var ids: [4]api.BodyId = undefined;
            inline for (0..4) |k| {
                var d = dynDesc(@intCast(k), s);
                // `mass`/`gravity_factor` are f32 descriptor fields regardless of `Real`.
                d.mass = @as(f32, @floatFromInt(k)) + 1.0;
                d.gravity_factor = 1.0 - @as(f32, @floatFromInt(k)) * 0.2;
                ids[k] = try bm.addBody(g_alloc, &store, d);
                bm.setLinearVelocity(ids[k], vr(@floatFromInt(k), 0, -@as(Real, @floatFromInt(k))));
            }

            const dt: Real = 1.0 / 60.0;
            const g = vr(0.5, -9.81, 0.25);
            var step: u32 = 0;
            while (step < 45) : (step += 1) integration.integrate(&bm, dt, g);

            inline for (0..4) |k| {
                out_pos[k] = bm.position(ids[k]).?.toArray();
                out_vel[k] = bm.linearVelocity(ids[k]).?.toArray();
            }
        }
    };
    var p1: [4][3]Real = undefined;
    var v1: [4][3]Real = undefined;
    var p2: [4][3]Real = undefined;
    var v2: [4][3]Real = undefined;
    try Runner.run(gpa, &p1, &v1);
    try Runner.run(gpa, &p2, &v2);
    inline for (0..4) |k| {
        try testing.expectEqual(p1[k], p2[k]); // bit-identical
        try testing.expectEqual(v1[k], v2[k]);
    }
}
