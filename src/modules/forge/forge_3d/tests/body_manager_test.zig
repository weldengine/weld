//! M1.1.0 / E3 acceptance suite for the forge_3d foundations (C1.1 verification
//! path): id allocation, LIFO slot reuse + generation checking, determinism,
//! exact per-primitive world AABBs, and analytic inertia.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const body_mod = @import("../body.zig");
const api = @import("weld_forge");
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const MotionProperties = body_mod.MotionProperties;
const Vec3 = math.Vec3; // f32 descriptor vector
const Quatf = math.Quatf;
const testing = std.testing;

// --- helpers -----------------------------------------------------------------

fn descOf(entity_index: u32, body_type: api.BodyType, shape: api.ShapeId) api.BodyDescriptor {
    return .{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = body_type,
        .shape = shape,
    };
}

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// Recover the inertia diagonal from a (diagonal) `local_inv_inertia`.
fn inertiaDiag(mp: MotionProperties) [3]Real {
    const c = mp.local_inv_inertia.cols;
    return .{
        1.0 / c[0].toArray()[0],
        1.0 / c[1].toArray()[1],
        1.0 / c[2].toArray()[2],
    };
}

fn expectInertiaRel(mp: MotionProperties, expected: [3]Real, rel: Real) !void {
    const got = inertiaDiag(mp);
    inline for (0..3) |i| {
        try testing.expect(@abs(got[i] - expected[i]) <= rel * @abs(expected[i]));
    }
}

/// Independent reference for the composite capsule inertia (mirrors the impl's
/// derivation so a coding typo in `shape.zig` is caught).
fn capsuleInertiaRef(r: Real, h: Real, mass: Real) [3]Real {
    const pi: Real = std.math.pi;
    const v_cyl = 2.0 * pi * r * r * h;
    const v_sph = (4.0 / 3.0) * pi * r * r * r;
    const vt = v_cyl + v_sph;
    const mc = mass * v_cyl / vt;
    const ms = mass * v_sph / vt;
    const iyy = mc * (0.5 * r * r) + ms * (0.4 * r * r);
    const ixx = mc * (h * h / 3.0 + r * r / 4.0) + ms * (0.4 * r * r + h * h + 0.75 * h * r);
    return .{ ixx, iyy, ixx };
}

// --- tests -------------------------------------------------------------------

test "create 1000 bodies yields valid unique ids" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    var seen: std.AutoHashMapUnmanaged(api.BodyId, void) = .empty;
    defer seen.deinit(gpa);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const id = try bm.addBody(gpa, &store, descOf(i, .dynamic, sphere));
        try testing.expect(bm.isValid(id));
        const gop = try seen.getOrPut(gpa, id);
        try testing.expect(!gop.found_existing);
    }
    try testing.expectEqual(@as(u32, 1000), bm.count());
}

test "create 10000 bodies smoke (capacity growth)" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{} });
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        _ = try bm.addBody(gpa, &store, descOf(i, .dynamic, box));
    }
    try testing.expectEqual(@as(u32, 10000), bm.count());
}

test "slot reuse is LIFO and generation-checked" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const sphere = try store.createShape(gpa, .{ .sphere = .{} });

    const a = try bm.addBody(gpa, &store, descOf(0, .dynamic, sphere));
    const b = try bm.addBody(gpa, &store, descOf(1, .dynamic, sphere));
    bm.removeBody(b);
    const c = try bm.addBody(gpa, &store, descOf(2, .dynamic, sphere)); // reuses b's slot

    try testing.expect(c != b);
    try testing.expectEqual(api.PackedId.unpack(b).index, api.PackedId.unpack(c).index);
    try testing.expectEqual(api.PackedId.unpack(b).generation +% 1, api.PackedId.unpack(c).generation);
    try testing.expect(!bm.isValid(b));
    try testing.expect(bm.position(b) == null); // stale ⇒ safe getter returns null
    try testing.expect(bm.isValid(a));
    try testing.expect(bm.isValid(c));

    // LIFO: free a then c ⇒ the next add reuses c's slot (last freed).
    bm.removeBody(a);
    bm.removeBody(c);
    const d = try bm.addBody(gpa, &store, descOf(3, .dynamic, sphere));
    try testing.expectEqual(api.PackedId.unpack(c).index, api.PackedId.unpack(d).index);
}

test "id allocation is deterministic" {
    const gpa = testing.allocator;
    const Runner = struct {
        fn run(g: std.mem.Allocator, out: *[6]api.BodyId) !void {
            var store = ShapeStore{};
            defer store.deinit(g);
            var bm = BodyManager{};
            defer bm.deinit(g);
            const s = try store.createShape(g, .{ .sphere = .{} });
            out[0] = try bm.addBody(g, &store, descOf(0, .dynamic, s));
            out[1] = try bm.addBody(g, &store, descOf(1, .dynamic, s));
            out[2] = try bm.addBody(g, &store, descOf(2, .dynamic, s));
            bm.removeBody(out[1]);
            bm.removeBody(out[0]);
            out[3] = try bm.addBody(g, &store, descOf(3, .dynamic, s));
            out[4] = try bm.addBody(g, &store, descOf(4, .dynamic, s));
            out[5] = try bm.addBody(g, &store, descOf(5, .dynamic, s));
        }
    };
    var run1: [6]api.BodyId = undefined;
    var run2: [6]api.BodyId = undefined;
    try Runner.run(gpa, &run1);
    try Runner.run(gpa, &run2);
    try testing.expectEqualSlices(api.BodyId, &run1, &run2);
}

test "sphere world aabb" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    var d = descOf(0, .dynamic, s);
    d.position = Vec3.fromArray(.{ 10, -2, 3 });
    const id = try bm.addBody(gpa, &store, d);
    const aabb = bm.bodyAabb(&store, id).?;
    try testing.expect(aabb.min.approxEql(vr(9.5, -2.5, 2.5), 1e-6));
    try testing.expect(aabb.max.approxEql(vr(10.5, -1.5, 3.5), 1e-6));
}

test "rotated box world aabb (45 deg about Z)" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = Vec3.fromArray(.{ 1, 1, 1 }) } });
    var d = descOf(0, .dynamic, box);
    d.rotation = Quatf.fromAxisAngle(Vec3.unit_z, std.math.pi / 4.0);
    const id = try bm.addBody(gpa, &store, d);
    const aabb = bm.bodyAabb(&store, id).?;
    // extent_x = extent_y = |cos45|·1 + |sin45|·1 = √2 ; extent_z = 1.
    const s2: Real = std.math.sqrt2;
    try testing.expect(aabb.max.approxEql(vr(s2, s2, 1), 1e-5));
    try testing.expect(aabb.min.approxEql(vr(-s2, -s2, -1), 1e-5));
}

test "rotated capsule world aabb (90 deg about Z)" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const cap = try store.createShape(gpa, .{ .capsule = .{ .radius = 0.3, .half_height = 1.0 } });
    var d = descOf(0, .dynamic, cap);
    d.rotation = Quatf.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0);
    const id = try bm.addBody(gpa, &store, d);
    const aabb = bm.bodyAabb(&store, id).?;
    // Y-axis capsule rotated 90° about Z ⇒ along X. End caps at ±(1,0,0), r=0.3.
    try testing.expect(aabb.max.approxEql(vr(1.3, 0.3, 0.3), 1e-5));
    try testing.expect(aabb.min.approxEql(vr(-1.3, -0.3, -0.3), 1e-5));
}

test "static body has zero inverse mass and inertia" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 1.0 } });
    var d = descOf(0, .static, s);
    d.mass = 50; // ignored for static
    const id = try bm.addBody(gpa, &store, d);
    const mp = bm.motionProperties(id).?;
    try testing.expectEqual(@as(Real, 0), mp.inv_mass);
    for (mp.local_inv_inertia.cols) |col| {
        try testing.expect(col.approxEql(Vec3r.zero, 0));
    }
}

test "collision_layer is stored and retrievable" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    // Round-trip a non-default layer.
    var d = descOf(0, .dynamic, s);
    d.collision_layer = 7;
    const id = try bm.addBody(gpa, &store, d);
    try testing.expectEqual(@as(?u8, 7), bm.collisionLayer(id));

    // Descriptor default is 0.
    const id0 = try bm.addBody(gpa, &store, descOf(1, .dynamic, s));
    try testing.expectEqual(@as(?u8, 0), bm.collisionLayer(id0));

    // Stale handle ⇒ null.
    bm.removeBody(id);
    try testing.expectEqual(@as(?u8, null), bm.collisionLayer(id));
}

test "inertia matches analytic values" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);

    // Sphere: I = 2/5 m r².
    {
        const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
        var d = descOf(0, .dynamic, s);
        d.mass = 4;
        const id = try bm.addBody(gpa, &store, d);
        const e: Real = 2.0 / 5.0 * 4.0 * 0.5 * 0.5;
        try expectInertiaRel(bm.motionProperties(id).?, .{ e, e, e }, 1e-4);
    }
    // Box: Ix = m/3 (hy² + hz²), cyclic.
    {
        const box = try store.createShape(gpa, .{ .box = .{ .half_extents = Vec3.fromArray(.{ 1, 2, 3 }) } });
        var d = descOf(1, .dynamic, box);
        d.mass = 6;
        const id = try bm.addBody(gpa, &store, d);
        const m: Real = 6;
        try expectInertiaRel(bm.motionProperties(id).?, .{
            m / 3.0 * (4.0 + 9.0),
            m / 3.0 * (1.0 + 9.0),
            m / 3.0 * (1.0 + 4.0),
        }, 1e-4);
    }
    // Capsule: composite closed form.
    {
        const cap = try store.createShape(gpa, .{ .capsule = .{ .radius = 0.4, .half_height = 0.9 } });
        var d = descOf(2, .dynamic, cap);
        d.mass = 3;
        const id = try bm.addBody(gpa, &store, d);
        try expectInertiaRel(bm.motionProperties(id).?, capsuleInertiaRef(0.4, 0.9, 3.0), 1e-4);
    }
}

test "rotation getter round-trips and rejects stale handles" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    const q = Quatf.fromAxisAngle(Vec3.unit_y, std.math.pi / 3.0);
    var d = descOf(0, .dynamic, s);
    d.rotation = q;
    const id = try bm.addBody(gpa, &store, d);

    // Round-trips (widened to solver precision).
    const expected = config.Quatr.fromArray(.{ q.x, q.y, q.z, q.w });
    try testing.expect(bm.rotation(id).?.approxEql(expected, 1e-6));

    // Stale handle ⇒ null.
    bm.removeBody(id);
    try testing.expect(bm.rotation(id) == null);
}

// --- E1 velocity / force / torque / impulse mutators & getters ---------------

test "linear and angular velocity set/get round-trip and reject stale handles" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const id = try bm.addBody(gpa, &store, descOf(0, .dynamic, s));

    // Velocities start at zero.
    try testing.expect(bm.linearVelocity(id).?.approxEql(Vec3r.zero, 0));
    try testing.expect(bm.angularVelocity(id).?.approxEql(Vec3r.zero, 0));

    const lin = vr(1, -2, 3);
    const ang = vr(-0.5, 4, 0.25);
    bm.setLinearVelocity(id, lin);
    bm.setAngularVelocity(id, ang);
    try testing.expect(bm.linearVelocity(id).?.approxEql(lin, 0));
    try testing.expect(bm.angularVelocity(id).?.approxEql(ang, 0));

    // Stale handle ⇒ getters null, setters no-op (no crash).
    bm.removeBody(id);
    try testing.expect(bm.linearVelocity(id) == null);
    try testing.expect(bm.angularVelocity(id) == null);
    bm.setLinearVelocity(id, vr(9, 9, 9)); // no-op
    bm.setAngularVelocity(id, vr(9, 9, 9)); // no-op
    try testing.expect(!bm.isValid(id));
}

test "addForce and addTorque accumulate into the per-tick columns" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const id = try bm.addBody(gpa, &store, descOf(0, .dynamic, s));
    const idx = bm.alloc.validate(id).?;

    // Accumulators start at zero.
    try testing.expect(bm.bodies.items(.force)[idx].approxEql(Vec3r.zero, 0));
    try testing.expect(bm.bodies.items(.torque)[idx].approxEql(Vec3r.zero, 0));

    bm.addForce(id, vr(1, 0, 0));
    bm.addForce(id, vr(0, 2, -1));
    bm.addTorque(id, vr(0, 0, 3));
    bm.addTorque(id, vr(1, 0, 0));
    try testing.expect(bm.bodies.items(.force)[idx].approxEql(vr(1, 2, -1), 1e-6));
    try testing.expect(bm.bodies.items(.torque)[idx].approxEql(vr(1, 0, 3), 1e-6));

    // Stale handle ⇒ no-op.
    bm.removeBody(id);
    bm.addForce(id, vr(5, 5, 5)); // no-op, no crash
    bm.addTorque(id, vr(5, 5, 5)); // no-op, no crash
    try testing.expect(!bm.isValid(id));
}

test "addForce accumulates on a static body too" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });
    const id = try bm.addBody(gpa, &store, descOf(0, .static, s));
    const idx = bm.alloc.validate(id).?;

    // Any live body accumulates; the uniform per-tick clear is `integrate`'s job.
    bm.addForce(id, vr(7, 0, 0));
    try testing.expect(bm.bodies.items(.force)[idx].approxEql(vr(7, 0, 0), 1e-6));
}

test "impulse is an immediate velocity change and is a no-op on a static body" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Dynamic: Δv = impulse · inv_mass, applied immediately (no integrate).
    var dyn = descOf(0, .dynamic, s);
    dyn.mass = 4;
    const dyn_id = try bm.addBody(gpa, &store, dyn);
    bm.addImpulse(dyn_id, vr(8, 0, -4));
    try testing.expect(bm.linearVelocity(dyn_id).?.approxEql(vr(2, 0, -1), 1e-6)); // /4

    // A second impulse accumulates onto the current velocity.
    bm.addImpulse(dyn_id, vr(0, 4, 0));
    try testing.expect(bm.linearVelocity(dyn_id).?.approxEql(vr(2, 1, -1), 1e-6));

    // Static: inv_mass == 0 ⇒ no velocity change.
    const stat_id = try bm.addBody(gpa, &store, descOf(1, .static, s));
    bm.addImpulse(stat_id, vr(100, 100, 100));
    try testing.expect(bm.linearVelocity(stat_id).?.approxEql(Vec3r.zero, 0));

    // Stale handle ⇒ no-op.
    bm.removeBody(dyn_id);
    bm.addImpulse(dyn_id, vr(1, 1, 1)); // no-op, no crash
    try testing.expect(!bm.isValid(dyn_id));
}

test "isAliveIndex tracks liveness across create, free, and reuse" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    // Bare index 0 is not alive before any slot exists.
    try testing.expect(!bm.alloc.isAliveIndex(0));

    const a = try bm.addBody(gpa, &store, descOf(0, .dynamic, s));
    const b = try bm.addBody(gpa, &store, descOf(1, .dynamic, s));
    const ia = api.PackedId.unpack(a).index;
    const ib = api.PackedId.unpack(b).index;
    try testing.expect(bm.alloc.isAliveIndex(ia));
    try testing.expect(bm.alloc.isAliveIndex(ib));
    try testing.expect(!bm.alloc.isAliveIndex(ib + 1)); // out of range

    // Free b: `removeBody` does NOT compact, so the slot count is unchanged but
    // that index is now dead — exactly what an index-ascending pass must skip.
    bm.removeBody(b);
    try testing.expect(bm.alloc.isAliveIndex(ia));
    try testing.expect(!bm.alloc.isAliveIndex(ib));

    // Reuse b's slot (LIFO): the same bare index goes live again.
    const c = try bm.addBody(gpa, &store, descOf(2, .dynamic, s));
    try testing.expectEqual(ib, api.PackedId.unpack(c).index);
    try testing.expect(bm.alloc.isAliveIndex(ib));
}

test "friction and restitution survive addBody" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const s = try store.createShape(gpa, .{ .sphere = .{} });

    // The descriptor material coefficients are dropped by M1.1.5's `addBody`;
    // M1.1.6 stores them on `Body` for the Sequential Impulses solver. 0.25 and
    // 0.75 are exactly representable in f32 and f64, so the f32→Real widening
    // (and the f64 build) both read back the literal exactly.
    var desc = descOf(0, .dynamic, s);
    desc.friction = 0.25;
    desc.restitution = 0.75;
    const id = try bm.addBody(gpa, &store, desc);
    try testing.expectEqual(@as(Real, 0.25), bm.friction(id).?);
    try testing.expectEqual(@as(Real, 0.75), bm.restitution(id).?);

    // Stale handle ⇒ null (parity with the other stale-safe getters).
    bm.removeBody(id);
    try testing.expectEqual(@as(?Real, null), bm.friction(id));
    try testing.expectEqual(@as(?Real, null), bm.restitution(id));
}
