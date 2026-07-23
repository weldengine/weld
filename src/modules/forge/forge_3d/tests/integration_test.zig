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
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const Vec3 = math.Vec3; // f32 descriptor vector
const Quatf = math.Quatf; // f32 descriptor quaternion
const testing = std.testing;

// --- helpers -----------------------------------------------------------------

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// Euclidean norm of a quaternion (Quat.length is not public).
fn quatNorm(q: Quatr) Real {
    const a = q.toArray();
    return @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2] + a[3] * a[3]);
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

    const rot = Quatf.fromAxisAngle(Vec3.unit_y, 0.7);
    const rot_r = Quatr.fromArray(.{ rot.x, rot.y, rot.z, rot.w });

    // Static at a fixed pose + orientation, with a force and torque applied.
    var stat = api.BodyDescriptor{
        .entity = .{ .index = 0, .generation = 0 },
        .body_type = .static,
        .shape = s,
    };
    stat.position = Vec3.fromArray(.{ 1, 2, 3 });
    stat.rotation = rot;
    const id_stat = try bm.addBody(gpa, &store, stat);
    bm.addForce(id_stat, vr(50, 50, 50));
    bm.addTorque(id_stat, vr(9, 9, 9));

    // Kinematic with a velocity set (no position-from-velocity in M1.1.5),
    // an orientation, and a force + torque.
    var kin = api.BodyDescriptor{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .kinematic,
        .shape = s,
    };
    kin.position = Vec3.fromArray(.{ 4, 5, 6 });
    kin.rotation = rot;
    const id_kin = try bm.addBody(gpa, &store, kin);
    bm.setLinearVelocity(id_kin, vr(1, 0, 0));
    bm.setAngularVelocity(id_kin, vr(0, 2, 0));
    bm.addForce(id_kin, vr(50, 50, 50));
    bm.addTorque(id_kin, vr(9, 9, 9));

    integration.integrate(&bm, dt, g);

    // Neither moved or rotated.
    try testing.expect(bm.position(id_stat).?.approxEql(vr(1, 2, 3), 0));
    try testing.expect(bm.position(id_kin).?.approxEql(vr(4, 5, 6), 0));
    try testing.expect(bm.rotation(id_stat).?.approxEql(rot_r, 0));
    try testing.expect(bm.rotation(id_kin).?.approxEql(rot_r, 0));
    // Kinematic velocities are untouched (not consumed in M1.1.5).
    try testing.expect(bm.linearVelocity(id_kin).?.approxEql(vr(1, 0, 0), 0));
    try testing.expect(bm.angularVelocity(id_kin).?.approxEql(vr(0, 2, 0), 0));
    // But their accumulators ARE cleared (§2 uniform reset).
    const i_stat = bm.alloc.validate(id_stat).?;
    const i_kin = bm.alloc.validate(id_kin).?;
    try testing.expect(bm.bodies.items(.force)[i_stat].approxEql(Vec3r.zero, 0));
    try testing.expect(bm.bodies.items(.force)[i_kin].approxEql(Vec3r.zero, 0));
    try testing.expect(bm.bodies.items(.torque)[i_stat].approxEql(Vec3r.zero, 0));
    try testing.expect(bm.bodies.items(.torque)[i_kin].approxEql(Vec3r.zero, 0));
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

    // Seed a's slot with a distinctive velocity + force before freeing it, so the
    // snapshot below can prove the dead slot was left untouched by `integrate`.
    bm.setLinearVelocity(a, vr(7, 3, -2));
    bm.addForce(a, vr(11, 0, 5));
    const ia = api.PackedId.unpack(a).index;
    bm.removeBody(a); // dead slot between live ones — must be skipped, no crash

    // Snapshot the dead slot's raw columns after the free, before integrating.
    const pos_dead = bm.bodies.items(.position)[ia].toArray();
    const vel_dead = bm.bodies.items(.linear_velocity)[ia].toArray();
    const force_dead = bm.bodies.items(.force)[ia].toArray();

    integration.integrate(&bm, dt, g); // step 1: b falls one step, a's slot skipped

    // Double lock on the `isAliveIndex` filter: the dead slot is bit-unchanged —
    // position not integrated, velocity not touched by gravity, AND the stale
    // force NOT cleared (the §2 uniform reset runs only for LIVE slots, so a dead
    // slot keeps its stale accumulator). Checked before `c` overwrites the slot.
    try testing.expectEqual(pos_dead, bm.bodies.items(.position)[ia].toArray());
    try testing.expectEqual(vel_dead, bm.bodies.items(.linear_velocity)[ia].toArray());
    try testing.expectEqual(force_dead, bm.bodies.items(.force)[ia].toArray());

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
    const Out = struct {
        pos: [4][3]Real = undefined,
        vel: [4][3]Real = undefined,
        rot: [4][4]Real = undefined,
        ang: [4][3]Real = undefined,
    };
    const Runner = struct {
        fn run(g_alloc: std.mem.Allocator, out: *Out) !void {
            var store = ShapeStore{};
            defer store.deinit(g_alloc);
            var bm = BodyManager{};
            defer bm.deinit(g_alloc);
            const box = try store.createShape(g_alloc, .{ .box = .{ .half_extents = Vec3.fromArray(.{ 1, 2, 3 }) } });

            var ids: [4]api.BodyId = undefined;
            inline for (0..4) |k| {
                const kf = @as(f32, @floatFromInt(k)); // f32 descriptor fields
                const kr = @as(Real, @floatFromInt(k)); // Real velocities/torques
                var d = dynDesc(@intCast(k), box);
                d.mass = kf + 1.0;
                d.gravity_factor = 1.0 - kf * 0.2;
                d.rotation = Quatf.fromAxisAngle(Vec3.fromArray(.{ 1, kf + 1, 0.5 }).normalize(), 0.3 + kf * 0.2);
                ids[k] = try bm.addBody(g_alloc, &store, d);
                bm.setLinearVelocity(ids[k], vr(kr, 0, -kr));
                bm.setAngularVelocity(ids[k], vr(0.5 * kr, 1.0, -0.3 * kr));
                bm.addTorque(ids[k], vr(kr, 0.5, -kr)); // consumed on the first tick
            }

            const dt: Real = 1.0 / 60.0;
            const g = vr(0.5, -9.81, 0.25);
            var step: u32 = 0;
            while (step < 45) : (step += 1) integration.integrate(&bm, dt, g);

            inline for (0..4) |k| {
                out.pos[k] = bm.position(ids[k]).?.toArray();
                out.vel[k] = bm.linearVelocity(ids[k]).?.toArray();
                out.rot[k] = bm.rotation(ids[k]).?.toArray();
                out.ang[k] = bm.angularVelocity(ids[k]).?.toArray();
            }
        }
    };
    var a: Out = .{};
    var b: Out = .{};
    try Runner.run(gpa, &a);
    try Runner.run(gpa, &b);
    inline for (0..4) |k| {
        try testing.expectEqual(a.pos[k], b.pos[k]); // bit-identical
        try testing.expectEqual(a.vel[k], b.vel[k]);
        try testing.expectEqual(a.rot[k], b.rot[k]);
        try testing.expectEqual(a.ang[k], b.ang[k]);
    }
}

// --- E3 angular tests --------------------------------------------------------

test "torque on a rotated anisotropic box" {
    // With angular_damping = 0 and ω₀ = 0, one step gives
    // ω = (R·I_local_inv·Rᵀ)·τ·dt for the pre-step rotation R = fromQuat(q₀) and
    // the diagonal local inverse inertia — recomputed independently here.
    // Named tolerance: O(1) values over one step, f32 ~1e-5.
    const angular_tol: Real = 1e-5;
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = Vec3.fromArray(.{ 1, 2, 3 }) } });

    var d = dynDesc(0, box);
    d.mass = 6;
    d.angular_damping = 0; // isolate the closed form
    d.rotation = Quatf.fromAxisAngle(Vec3.fromArray(.{ 0.3, 1, 0.2 }).normalize(), 0.9);
    const id = try bm.addBody(gpa, &store, d);

    const torque = vr(5, -3, 2);
    bm.addTorque(id, torque);

    // Capture the pre-step pose + inertia the integrator will use.
    const rot_before = bm.rotation(id).?;
    const local_inv_inertia = bm.motionProperties(id).?.local_inv_inertia;

    const dt: Real = 1.0 / 60.0;
    integration.integrate(&bm, dt, vr(0, 0, 0)); // no gravity

    const r = Mat3r.fromQuat(rot_before);
    const i_world_inv = r.mul(local_inv_inertia).mul(r.transpose());
    const expected = i_world_inv.mulVec(torque).scale(dt);
    try testing.expect(bm.angularVelocity(id).?.approxEql(expected, angular_tol));
}

test "angular damping and clamp" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const dt: Real = 1.0 / 60.0;
    const no_gravity = vr(0, 0, 0);

    // Reduce: d > 0, no torque, initial ω ⇒ |ω| strictly smaller after one step.
    var damped = dynDesc(0, s);
    damped.angular_damping = 0.5;
    const id_damped = try bm.addBody(gpa, &store, damped);
    bm.setAngularVelocity(id_damped, vr(0, 4, 0));
    integration.integrate(&bm, dt, no_gravity);
    const w = bm.angularVelocity(id_damped).?.toArray()[1];
    try testing.expect(w > 0 and w < 4); // damped toward zero, not past it

    // Clamp: d·dt > 1 ⇒ factor max(0, 1−d·dt) = 0 ⇒ ω zeroed, no sign flip.
    var clamp = dynDesc(1, s);
    clamp.angular_damping = 100; // 100/60 = 1.667 > 1
    const id_clamp = try bm.addBody(gpa, &store, clamp);
    bm.setAngularVelocity(id_clamp, vr(1, -2, 3));
    integration.integrate(&bm, dt, no_gravity);
    try testing.expect(bm.angularVelocity(id_clamp).?.approxEql(Vec3r.zero, 0));
}

test "orientation quaternion stays unit" {
    // The first-order update renormalises each step, so |q| stays ≈ 1 even after
    // many steps of nonzero spin. Named tolerance: accumulated f32 renormalise
    // noise over 120 steps is well under 1e-5.
    const unit_tol: Real = 1e-5;
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    var d = dynDesc(0, s);
    d.angular_damping = 0;
    d.rotation = Quatf.fromAxisAngle(Vec3.unit_z, 0.3);
    const id = try bm.addBody(gpa, &store, d);
    bm.setAngularVelocity(id, vr(1.5, -2.0, 0.7));

    const dt: Real = 1.0 / 60.0;
    var step: u32 = 0;
    while (step < 120) : (step += 1) integration.integrate(&bm, dt, vr(0, 0, 0));

    try testing.expectApproxEqAbs(@as(Real, 1), quatNorm(bm.rotation(id).?), unit_tol);
}

test "zero angular velocity leaves orientation unchanged" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    const q0 = Quatf.fromAxisAngle(Vec3.fromArray(.{ 1, 1, 0 }).normalize(), 0.6);
    var d = dynDesc(0, s);
    d.angular_damping = 0;
    d.rotation = q0;
    const id = try bm.addBody(gpa, &store, d);
    // ω = 0 (default); no torque. The first-order path never divides by |ω|.

    const dt: Real = 1.0 / 60.0;
    var step: u32 = 0;
    while (step < 60) : (step += 1) integration.integrate(&bm, dt, vr(0, 0, 0));

    const q = bm.rotation(id).?;
    const q0r = Quatr.fromArray(.{ q0.x, q0.y, q0.z, q0.w });
    try testing.expect(q.approxEql(q0r, 1e-6)); // unchanged
    // No NaN produced by the ω = 0 path.
    for (q.toArray()) |c| try testing.expect(!std.math.isNan(c));
}

test "orientation update uses the left (world-space) quaternion product" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    // Non-commutative config: an X-axis initial orientation with a Y-axis spin,
    // so the left and right quaternion products give distinct results.
    var d = dynDesc(0, s);
    d.angular_damping = 0;
    const q0 = Quatf.fromAxisAngle(Vec3.unit_x, 0.8);
    d.rotation = q0;
    const id = try bm.addBody(gpa, &store, d);
    bm.setAngularVelocity(id, vr(0, 3, 0));

    const dt: Real = 1.0 / 60.0;
    integration.integrate(&bm, dt, vr(0, 0, 0)); // no gravity, no torque

    // Oracle: replicate the first-order formula both ways. The engine uses the
    // LEFT product (world-space ω): q ← normalize(q + ½·dt·(ω_quat ⊗ q)).
    const w_quat = Quatr{ .x = 0, .y = 3, .z = 0, .w = 0 };
    const q0r = Quatr.fromArray(.{ q0.x, q0.y, q0.z, q0.w });
    const left = q0r.add(w_quat.mul(q0r).scale(0.5 * dt)).normalize();
    const right = q0r.add(q0r.mul(w_quat).scale(0.5 * dt)).normalize();

    // Discrimination guard: this (q0, ω) is non-commutative, so left ≠ right —
    // protects the test's discriminating power if q0/ω are ever changed.
    const discrimination_tol: Real = 1e-4;
    try testing.expect(!left.approxEql(right, discrimination_tol));

    // The engine matches the LEFT product, and NOT the right one.
    const match_tol: Real = 1e-6;
    try testing.expect(bm.rotation(id).?.approxEql(left, match_tol));
    try testing.expect(!bm.rotation(id).?.approxEql(right, discrimination_tol));
}
