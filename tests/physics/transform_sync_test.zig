//! M1.1.15 gate D — ECS ↔ solver synchronisation, both directions.
//!
//! What this file measures is the SEAM: who owns which fact, when each side reads the
//! other, and what the `Sleeping` marker does to publication. The physics itself is
//! measured by `forge_3d`'s own suite and is not re-measured here.
//!
//! Every assertion names an ENTITY and reads that entity's own components. An aggregate
//! another entity could satisfy is not an assertion about the one named.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const sync = @import("forge_sync");
const foundation = @import("foundation");

const World = core.ecs.World;
const EntityId = core.ecs.EntityId;
const Transform = core.ecs.components.Transform;
const Velocity = api.Velocity;
const Sleeping = api.Sleeping;
const PhysicsWorld = forge_3d.PhysicsWorld;
const Vec3r = forge_3d.Vec3r;
const Real = forge_3d.Real;
const testing = std.testing;

const fixed_dt: Real = 1.0 / 60.0;
const gravity_y: Real = -9.81;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

/// An ECS entity carrying `Transform` and `Velocity`, plus a physics body bound to it by
/// entity identity — the binding the seam walks in both directions.
fn spawnLinked(
    gpa: std.mem.Allocator,
    ecs: *World,
    pw: *PhysicsWorld,
    body_type: api.BodyType,
    half: [3]f32,
    centre: [3]f32,
) !struct { entity: EntityId, body: api.BodyId } {
    const entity = try ecs.spawn(gpa, .{
        .pos = .{ centre[0], centre[1], centre[2] },
    }, .{});
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(half[0], half[1], half[2]) } });
    var desc = api.BodyDescriptor{
        .entity = entity,
        .body_type = body_type,
        .shape = shape,
    };
    desc.position = av3(centre[0], centre[1], centre[2]);
    desc.restitution = 0;
    if (body_type == .dynamic) desc.mass = 1;
    const body = try pw.addBody(gpa, desc);
    return .{ .entity = entity, .body = body };
}

/// Ground at the origin (top face y = 0.5) plus a dynamic unit box resting flush on it.
fn restingScene(gpa: std.mem.Allocator, ecs: *World, pw: *PhysicsWorld) !struct {
    ground: EntityId,
    box_entity: EntityId,
    box: api.BodyId,
} {
    const g = try spawnLinked(gpa, ecs, pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    const b = try spawnLinked(gpa, ecs, pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 1.0, 0 });
    return .{ .ground = g.entity, .box_entity = b.entity, .box = b.body };
}

test "solver pose reaches Transform for every awake body" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    // TWO dynamic bodies at different heights, so an assertion that read the wrong one —
    // or an aggregate over both — could not pass by accident: they fall to different
    // places and each is checked against ITS OWN solver pose, by entity.
    const a = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    const high = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 4.0, 0 });
    const low = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 2, 1.6, 0 });
    _ = a;

    var t: u32 = 0;
    while (t < 20) : (t += 1) try sync.stepSynchronised(gpa, &pw, &ecs);

    for ([_]struct { e: EntityId, b: api.BodyId }{
        .{ .e = high.entity, .b = high.body },
        .{ .e = low.entity, .b = low.body },
    }) |link| {
        const solver = pw.bm.position(link.b).?.toArray();
        const published = ecs.get(Transform, link.e).?.pos;
        try testing.expectEqual(@as(f32, @floatCast(solver[0])), published[0]);
        try testing.expectEqual(@as(f32, @floatCast(solver[1])), published[1]);
        try testing.expectEqual(@as(f32, @floatCast(solver[2])), published[2]);
    }

    // NON-VACUITY: the bodies actually moved, so the equality above is not two identical
    // spawn poses agreeing with themselves.
    try testing.expect(ecs.get(Transform, high.entity).?.pos[1] < 4.0 - 0.1);
    try testing.expect(ecs.get(Transform, low.entity).?.pos[1] < 1.6 - 0.001);
    // And the two are DIFFERENT, which is what an aggregate could have hidden.
    try testing.expect(ecs.get(Transform, high.entity).?.pos[0] != ecs.get(Transform, low.entity).?.pos[0]);
}

test "a sleeping island's Transform is not rewritten and its pose is bit-frozen" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    const scene = try restingScene(gpa, &ecs, &pw);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try sync.stepSynchronised(gpa, &pw, &ecs);
    }
    try testing.expect(pw.bm.isSleeping(scene.box).?);

    // (b) THE VALUE — and this is the half that catches the ordering trap. The island
    // falls asleep at step 11, AFTER steps 6 and 7 wrote its last pose, and sync-out runs
    // after step 11. Tag before publishing and that last pose is never published: the
    // entity keeps the pose of the previous tick, for as long as it sleeps. The body IS
    // frozen either way, so an immobility check alone passes on the defect — it is frozen
    // on the wrong value. This compares the published `Transform` against the pose the
    // SOLVER holds at the sleeping tick.
    const solver = pw.bm.position(scene.box).?.toArray();
    const published = ecs.get(Transform, scene.box_entity).?.pos;
    try testing.expectEqual(@as(f32, @floatCast(solver[0])), published[0]);
    try testing.expectEqual(@as(f32, @floatCast(solver[1])), published[1]);
    try testing.expectEqual(@as(f32, @floatCast(solver[2])), published[2]);

    // (a) THE IMMOBILITY — bit equality across many further ticks, not an epsilon. The
    // marker is on, so publication skips this entity entirely.
    try testing.expect(ecs.get(Sleeping, scene.box_entity) != null);
    const frozen = ecs.get(Transform, scene.box_entity).?.*;
    var k: u32 = 0;
    while (k < 30) : (k += 1) try sync.stepSynchronised(gpa, &pw, &ecs);
    const after = ecs.get(Transform, scene.box_entity).?.*;
    try testing.expectEqualSlices(f32, &frozen.pos, &after.pos);
    try testing.expectEqualSlices(f32, &frozen.rot, &after.rot);
}

test "the waking tick publishes the pose it moved to" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    const scene = try restingScene(gpa, &ecs, &pw);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try sync.stepSynchronised(gpa, &pw, &ecs);
    }
    try testing.expect(ecs.get(Sleeping, scene.box_entity) != null);

    // THE MIRROR OF THE ORDERING TRAP. Untagging AFTER publication instead of before
    // would lose the first tick a woken body moves — the same class of defect at the
    // other end of the cycle — so the wake side is asserted as well as the sleep side.
    pw.addImpulse(scene.box, vr(2, 0, 0));
    try sync.stepSynchronised(gpa, &pw, &ecs);
    try testing.expect(ecs.get(Sleeping, scene.box_entity) == null);
    const solver = pw.bm.position(scene.box).?.toArray();
    const published = ecs.get(Transform, scene.box_entity).?.pos;
    try testing.expectEqual(@as(f32, @floatCast(solver[0])), published[0]);
    // And it really moved on that very tick, so the equality is not two stale values.
    try testing.expect(@abs(published[0]) > 1e-5);
}

test "Sleeping tag tracks island state in both directions" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    const scene = try restingScene(gpa, &ecs, &pw);

    // A FULL CYCLE EACH WAY: absent while awake, present once asleep, absent again on
    // wake, present again once it settles. One direction alone is satisfied by a rule
    // that only ever adds, or only ever removes.
    try testing.expect(ecs.get(Sleeping, scene.box_entity) == null);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try sync.stepSynchronised(gpa, &pw, &ecs);
    }
    try testing.expect(ecs.get(Sleeping, scene.box_entity) != null);

    pw.addImpulse(scene.box, vr(2, 0, 0));
    try sync.stepSynchronised(gpa, &pw, &ecs);
    try testing.expect(ecs.get(Sleeping, scene.box_entity) == null);

    t = 0;
    while (t < 600 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try sync.stepSynchronised(gpa, &pw, &ecs);
    }
    try testing.expect(pw.bm.isSleeping(scene.box).?);
    try testing.expect(ecs.get(Sleeping, scene.box_entity) != null);

    // The entity kept its other components across the four archetype migrations the two
    // round trips caused — a zero-size column must not disturb its neighbours.
    try testing.expect(ecs.get(Transform, scene.box_entity) != null);
    try testing.expect(ecs.get(Velocity, scene.box_entity) != null);
}

test "gameplay Velocity write is applied by the solver and wakes the body" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    const scene = try restingScene(gpa, &ecs, &pw);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try sync.stepSynchronised(gpa, &pw, &ecs);
    }
    try testing.expect(pw.bm.isSleeping(scene.box).?);

    // C1.1's own wording: an Etch system can write `Velocity` and the solver applies it.
    // Written on the ECS component, which is the only surface a rule has.
    ecs.getMut(Velocity, scene.box_entity).?.linear = .{ 3, 0, 0 };
    try sync.stepSynchronised(gpa, &pw, &ecs);

    // APPLIED — the solver carries it — and the body WOKE, because a gameplay write is an
    // external mutation. Both halves: a seam that pushed the value without waking would
    // hand it to a body the solver skips.
    try testing.expect(!pw.bm.isSleeping(scene.box).?);
    try testing.expect(pw.bm.linearVelocity(scene.box).?.toArray()[0] > 0.5);
    try testing.expect(ecs.get(Transform, scene.box_entity).?.pos[0] > 1e-4);
}

test "authority per BodyType" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    const dyn = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 10, 0 });
    const kin = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 20, 0, 0 });
    const sta = try spawnLinked(gpa, &ecs, &pw, .static, .{ 0.5, 0.5, 0.5 }, .{ 40, 0, 0 });

    // DYNAMIC — the SOLVER is the authority. A gameplay write to `Transform` is
    // overwritten at the next sync-out, and that is the contract: the legitimate ways to
    // move a dynamic body are `setBodyTransform`, a force or an impulse.
    ecs.getMut(Transform, dyn.entity).?.pos = .{ 99, 99, 99 };
    try sync.stepSynchronised(gpa, &pw, &ecs);
    try testing.expect(ecs.get(Transform, dyn.entity).?.pos[0] != 99);
    try testing.expectEqual(
        @as(f32, @floatCast(pw.bm.position(dyn.body).?.toArray()[1])),
        ecs.get(Transform, dyn.entity).?.pos[1],
    );

    // KINEMATIC — GAMEPLAY is the authority. A `Transform` written by a rule is pushed in
    // at sync-in and survives the tick, and the solver's own pose follows it.
    ecs.getMut(Transform, kin.entity).?.pos = .{ 25, 3, 0 };
    try sync.stepSynchronised(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 25), ecs.get(Transform, kin.entity).?.pos[0]);
    try testing.expectEqual(@as(f32, 3), ecs.get(Transform, kin.entity).?.pos[1]);
    try testing.expectEqual(@as(Real, 25), pw.bm.position(kin.body).?.toArray()[0]);

    // STATIC — no per-tick synchronisation in EITHER direction. The ECS write stands
    // because nothing publishes over it, and the solver pose does NOT follow it, because
    // nothing pushes it in: a static body that moves is a teleportation through
    // `setBodyTransform`, not a `Transform` write.
    ecs.getMut(Transform, sta.entity).?.pos = .{ 77, 0, 0 };
    try sync.stepSynchronised(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 77), ecs.get(Transform, sta.entity).?.pos[0]);
    try testing.expectEqual(@as(Real, 40), pw.bm.position(sta.body).?.toArray()[0]);
}
