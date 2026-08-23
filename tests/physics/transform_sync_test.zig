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

/// The same timestep as `fixed_dt`, in the `f32` the frame context carries.
const fixed_dt_f32: f32 = 1.0 / 60.0;

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
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    // TWO dynamic bodies at different heights, so an assertion that read the wrong one —
    // or an aggregate over both — could not pass by accident: they fall to different
    // places and each is checked against ITS OWN solver pose, by entity.
    const a = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    const high = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 4.0, 0 });
    const low = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 2, 1.6, 0 });
    _ = a;

    var t: u32 = 0;
    while (t < 20) : (t += 1) try frame(gpa, &pw, &ecs);

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
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    const scene = try restingScene(gpa, &ecs, &pw);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try frame(gpa, &pw, &ecs);
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
    while (k < 30) : (k += 1) try frame(gpa, &pw, &ecs);
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
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    const scene = try restingScene(gpa, &ecs, &pw);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try frame(gpa, &pw, &ecs);
    }
    try testing.expect(ecs.get(Sleeping, scene.box_entity) != null);

    // THE MIRROR OF THE ORDERING TRAP. Untagging AFTER publication instead of before
    // would lose the first tick a woken body moves — the same class of defect at the
    // other end of the cycle — so the wake side is asserted as well as the sleep side.
    pw.addImpulse(scene.box, vr(2, 0, 0));
    try frame(gpa, &pw, &ecs);
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
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    const scene = try restingScene(gpa, &ecs, &pw);

    // A FULL CYCLE EACH WAY: absent while awake, present once asleep, absent again on
    // wake, present again once it settles. One direction alone is satisfied by a rule
    // that only ever adds, or only ever removes.
    try testing.expect(ecs.get(Sleeping, scene.box_entity) == null);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try frame(gpa, &pw, &ecs);
    }
    try testing.expect(ecs.get(Sleeping, scene.box_entity) != null);

    pw.addImpulse(scene.box, vr(2, 0, 0));
    try frame(gpa, &pw, &ecs);
    try testing.expect(ecs.get(Sleeping, scene.box_entity) == null);

    t = 0;
    while (t < 600 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try frame(gpa, &pw, &ecs);
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
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    const scene = try restingScene(gpa, &ecs, &pw);

    var t: u32 = 0;
    while (t < 400 and !pw.bm.isSleeping(scene.box).?) : (t += 1) {
        try frame(gpa, &pw, &ecs);
    }
    try testing.expect(pw.bm.isSleeping(scene.box).?);

    // C1.1's own wording: an Etch system can write `Velocity` and the solver applies it.
    // Written on the ECS component, which is the only surface a rule has.
    ecs.getMut(Velocity, scene.box_entity).?.linear = .{ 3, 0, 0 };
    try frame(gpa, &pw, &ecs);

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
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    const dyn = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 10, 0 });
    const kin = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 20, 0, 0 });
    const sta = try spawnLinked(gpa, &ecs, &pw, .static, .{ 0.5, 0.5, 0.5 }, .{ 40, 0, 0 });

    // DYNAMIC — the SOLVER is the authority. A gameplay write to `Transform` is
    // overwritten at the next sync-out, and that is the contract: the legitimate ways to
    // move a dynamic body are `setBodyTransform`, a force or an impulse.
    ecs.getMut(Transform, dyn.entity).?.pos = .{ 99, 99, 99 };
    try frame(gpa, &pw, &ecs);
    try testing.expect(ecs.get(Transform, dyn.entity).?.pos[0] != 99);
    try testing.expectEqual(
        @as(f32, @floatCast(pw.bm.position(dyn.body).?.toArray()[1])),
        ecs.get(Transform, dyn.entity).?.pos[1],
    );

    // KINEMATIC — GAMEPLAY is the authority. A `Transform` written by a rule is pushed in
    // at sync-in and survives the tick, and the solver's own pose follows it.
    ecs.getMut(Transform, kin.entity).?.pos = .{ 25, 3, 0 };
    try frame(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 25), ecs.get(Transform, kin.entity).?.pos[0]);
    try testing.expectEqual(@as(f32, 3), ecs.get(Transform, kin.entity).?.pos[1]);
    try testing.expectEqual(@as(Real, 25), pw.bm.position(kin.body).?.toArray()[0]);

    // STATIC — no per-tick synchronisation in EITHER direction. The ECS write stands
    // because nothing publishes over it, and the solver pose does NOT follow it, because
    // nothing pushes it in: a static body that moves is a teleportation through
    // `setBodyTransform`, not a `Transform` write.
    ecs.getMut(Transform, sta.entity).?.pos = .{ 77, 0, 0 };
    try frame(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 77), ecs.get(Transform, sta.entity).?.pos[0]);
    try testing.expectEqual(@as(Real, 40), pw.bm.position(sta.body).?.toArray()[0]);
}

/// Was `T`'s slot for `entity` stamped at the world's CURRENT tick? This reads the SIGNAL
/// `Changed<T>` is built on (`core/ecs/world.zig` `getMut` → `archetype.markChanged`), and
/// deliberately not the value: under the defect these guards refuse, the value is already
/// correct and only the signal lies.
fn markedThisTick(ecs: *World, comptime T: type, entity: EntityId) bool {
    const loc = ecs.dynamicLocation(entity).?;
    const arch = ecs.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const col = arch.componentIndex(ecs.componentId(@typeName(T)).?).?;
    return arch.changedTick(chunk, col, loc.slot) == ecs.current_tick;
}

test "publication does not mark a component whose value did not change" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);

    // ZERO gravity and sleeping OFF: the body is awake forever and exactly immobile, which
    // is the awake-and-immobile case the `Sleeping` marker says nothing about. Immobility
    // is EXACT and not approximate here — `v = 0` damped is `0`, and `x + 0 · dt` is `x` —
    // so a mark can only come from an unconditional write, never from a settling residue.
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    const b = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 2, 0 });

    // One tick to let publication write whatever it wants to write once.
    try frame(gpa, &pw, &ecs);
    const settled_pos = ecs.get(Transform, b.entity).?.pos;

    // From here on, nothing in the scene changes. Every further tick opens a NEW ECS frame,
    // so a stamp at `current_tick` can only have been made during that tick — and the test
    // touches no component itself, so publication is the only possible author.
    var k: u32 = 0;
    while (k < 8) : (k += 1) {
        try frame(gpa, &pw, &ecs);
        try testing.expect(!markedThisTick(&ecs, Transform, b.entity));
        try testing.expect(!markedThisTick(&ecs, Velocity, b.entity));
    }
    // The body genuinely did not move, so the quiet signal is not hiding a lost write.
    try testing.expectEqualSlices(f32, &settled_pos, &ecs.get(Transform, b.entity).?.pos);

    // NON-VACUITY, and it is what separates this from a `syncOut` that publishes NOTHING.
    // A gameplay `Velocity` write goes in, the body moves, and the marks must FIRE.
    ecs.beginFrame();
    ecs.getMut(Velocity, b.entity).?.linear = .{ 3, 0, 0 };
    try frame(gpa, &pw, &ecs);

    // A fresh tick the test does not touch: any stamp below is publication's own.
    try frame(gpa, &pw, &ecs);
    try testing.expect(markedThisTick(&ecs, Transform, b.entity));
    try testing.expect(ecs.get(Transform, b.entity).?.pos[0] > settled_pos[0]);
}

test "a character presence never answers for its entity, in either direction" {
    // ONE ENTITY, TWO BODIES. `character.zig` creates the presence with
    // `.entity = desc.entity`, so the body store cannot tell the controller's inner body from
    // the entity's own. Walked as an ordinary body by this seam it corrupts BOTH directions,
    // and both halves are measured here because each fails differently.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    // Ground, so the character has something to stand on and the scene is not degenerate.
    _ = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });

    const hero = try ecs.spawn(gpa, .{ .pos = .{ 0, 0.5, 0 } }, .{});
    const character = try pw.createCharacter(gpa, .{ .entity = hero, .position = av3(0, 0.5, 0) });
    const presence = (try pw.chars.getCharacterInnerBody(character)).?;
    try testing.expectEqual(hero, pw.bm.entity(presence).?);

    // PRECONDITION, so the test cannot pass because the presence was never registered: it IS
    // in the world's body list, which is what makes it reachable by the seam at all.
    var registered = false;
    for (pw.bodies.items) |e| {
        if (e.id == presence) registered = true;
    }
    try testing.expect(registered);

    // INWARD. A gameplay write to the character's `Transform` must NOT teleport the presence:
    // that would bypass `moveCharacter`'s sweep and depenetration, which is what a controller
    // is for. The presence is kinematic, so before the fix `syncIn` saw a kinematic whose
    // pose differed and pushed it straight through `setBodyTransform`.
    ecs.getMut(Transform, hero).?.pos = .{ 40, 60, 80 };
    const presence_before = pw.bm.position(presence).?.toArray();
    try frame(gpa, &pw, &ecs);
    const presence_after = pw.bm.position(presence).?.toArray();
    try testing.expect(@abs(presence_after[0] - presence_before[0]) < 1.0);
    try testing.expect(@abs(presence_after[2] - presence_before[2]) < 1.0);
    try testing.expect(presence_after[1] < 40); // nowhere near the written pose

    // OUTWARD. The presence is moved by pose write, so its velocity columns are zero forever.
    // Published into the entity they would overwrite the entity's own `Velocity` with a
    // constant zero, every tick. The value written here survives because the seam skips it.
    ecs.getMut(Velocity, hero).?.linear = .{ 7, 0, 0 };
    try frame(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 7), ecs.get(Velocity, hero).?.linear[0]);
    try testing.expectEqual(@as(Real, 0), pw.bm.linearVelocity(presence).?.toArray()[0]);
}

/// A gameplay rule, standing in for an Etch system: it writes `Velocity` from `update`.
///
/// **The position in the frame is the whole point.** A test writing `Velocity` from its own
/// body between two dispatches writes it OUTSIDE any phase, where the next `pre_update`
/// picks it up and the defect never shows. C1.1's claim is about a system, so the guard has
/// to be one.
const GameplayPush = struct {
    var target_entity: EntityId = undefined;
    var frames_left: u32 = 0;

    fn run(ctx: core.ecs.SystemContext) anyerror!void {
        if (frames_left == 0) return;
        frames_left -= 1;
        const v = ctx.world.getMut(Velocity, target_entity) orelse return;
        v.linear = .{ 4, 0, 0 };
    }
};

test "the registered systems drive a real frame: the solver's pose reaches the ECS" {
    // THE DELIVERABLE F5 NAMES. Before this, `stepSynchronised` had no caller outside this
    // file: the seam existed only in its own tests, and the milestone shipped a mechanism
    // nothing executed. What is measured here is the SCHEDULER path — `registerSystems` plus
    // `dispatchFrame` — and not the direct composition the tests above drive.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    _ = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    const faller = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 4, 0 });

    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);

    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    try sync.registerSystems(gpa, &sched, &ecs);

    // TWO systems: the publication rides the tick in `fixed_update`. Three, with the
    // publication alone in `post_update`, is what lost a gameplay `Velocity` write.
    try testing.expectEqual(@as(usize, 2), sched.systemCount());

    const start = ecs.get(Transform, faller.entity).?.pos[1];
    var f: u32 = 0;
    while (f < 30) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    // The body fell in the SOLVER and the ECS learned about it, per entity and by identity.
    const published = ecs.get(Transform, faller.entity).?.pos[1];
    const solver = pw.bm.position(faller.body).?.toArray()[1];
    try testing.expect(published < start - 0.05); // NON-VACUITY: it really moved
    try testing.expectEqual(@as(f32, @floatCast(solver)), published);
}

test "a gameplay Velocity written from an update system reaches the solver" {
    // C1.1, literally: an Etch system can write `Velocity` and the solver applies it. The
    // write is issued FROM A SYSTEM IN `update`, which is the only position that exercises
    // the defect — between two dispatches it lands outside every phase and the next
    // `pre_update` reads it whatever the publication does.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ecs = World.init();
    defer ecs.deinit(gpa);
    // ZERO gravity: the only thing that can move this body along +X is the pushed velocity,
    // so displacement along X is attributable and not a component of a fall.
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    const b = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 2, 0 });

    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);

    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    try sync.registerSystems(gpa, &sched, &ecs);

    GameplayPush.target_entity = b.entity;
    GameplayPush.frames_left = 1; // ONE write, so what is measured is that it survived
    try sched.registerSystem(gpa, &ecs, .{
        .phase = .update,
        .name = "gameplay_push",
        .run = GameplayPush.run,
        .accesses = &.{core.ecs.Writes(Velocity)},
    });

    const start_x = ecs.get(Transform, b.entity).?.pos[0];
    var f: u32 = 0;
    while (f < 10) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    // The SOLVER carries it — the assertion is on the solver's own column and not on the
    // published mirror, so a publication that echoed the ECS back to itself cannot satisfy it.
    try testing.expect(pw.bm.linearVelocity(b.body).?.toArray()[0] > 3.9);
    // And the body actually moved, which no amount of velocity bookkeeping alone would do.
    try testing.expect(ecs.get(Transform, b.entity).?.pos[0] > start_x + 0.2);
}

/// One driven frame on the DIRECT path: open the ECS frame, then run the tick with both
/// halves of the seam around it.
///
/// **The frame boundary is the caller's and never `stepSynchronised`'s.** Sync-in gates on
/// the change stamp against a watermark, so a tick that never advances leaves every stamp
/// equal to the watermark and no gameplay write is ever seen — which is exactly what an app
/// loop or `dispatchFrame` avoids by opening the frame itself. Modelling that here rather
/// than folding `beginFrame` into the seam keeps the two paths identical in shape.
fn frame(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    ecs.beginFrame();
    try sync.stepSynchronised(gpa, pw, ecs);
}

/// Bind a SECOND body to an entity that already has one — the shape
/// `engine-physics-solver.md` §1.13.1 makes normal: "a mixed body does not exist; an entity
/// that must both collide and detect carries two bodies".
fn addTriggerBody(
    gpa: std.mem.Allocator,
    pw: *PhysicsWorld,
    entity: EntityId,
    centre: [3]f32,
) !api.BodyId {
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(1, 1, 1) } });
    var desc = api.BodyDescriptor{
        .entity = entity,
        .body_type = .kinematic,
        .shape = shape,
    };
    desc.position = av3(centre[0], centre[1], centre[2]);
    desc.is_trigger = true;
    return try pw.addBody(gpa, desc);
}

test "a trigger body publishes nothing and still receives the entity's pose" {
    // §1.13.7: a trigger body has no manifold, no constraint, no impulse and no island entry
    // — it has no resolved fact to publish. §1.13.1 makes two-bodies-one-entity the normal
    // shape, so the entity's facts are its SOLID body's.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    _ = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    const solid = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 4, 0 });

    // Registered AFTER the solid, so under the defect it is the trigger that wins the last
    // write of the tick — the order that makes the defect visible rather than benign.
    const trigger = try addTriggerBody(gpa, &pw, solid.entity, .{ 9, 9, 9 });

    var t: u32 = 0;
    while (t < 19) : (t += 1) try frame(gpa, &pw, &ecs);

    // The pose the ECS holds going INTO the last tick. Sync-in runs before the step, so this
    // is exactly what the last tick pushes into the trigger — the relationship is one tick,
    // and stating it is better than absorbing it in a tolerance.
    const before_last = ecs.get(Transform, solid.entity).?.pos;
    try frame(gpa, &pw, &ecs);

    // PUBLICATION: the entity's Transform is the SOLID's pose, to the bit. Under the defect
    // it is the trigger's, which is nine metres away — so this is not a tolerance question.
    const published = ecs.get(Transform, solid.entity).?.pos;
    const solid_pose = pw.bm.position(solid.body).?.toArray();
    try testing.expectEqual(@as(f32, @floatCast(solid_pose[1])), published[1]);
    try testing.expect(published[1] < 3.9); // NON-VACUITY: the solid really fell

    // RECEPTION is kept: sync-in pushed the entity's pose into the trigger, because a trigger
    // that does not follow its entity detects the wrong region. Bit-exact against the pose
    // that tick read, on the trigger's own solver column, which started nine metres away.
    const trigger_pose = pw.bm.position(trigger).?.toArray();
    try testing.expectEqual(before_last[1], @as(f32, @floatCast(trigger_pose[1])));
    try testing.expect(trigger_pose[0] < 1.0); // it moved off (9,9,9)
}

test "resolving an unpublished world registers nothing" {
    // P1-3, and the object is `resolve` ITSELF. It used to obtain its id by REGISTERING the
    // handle type, and inside a system that meant `ctx.gpa` — the per-frame allocator — while
    // a registration keeps the type's name for the world's whole life.
    //
    // Isolated here rather than measured through a dispatch: since `registerSystems` declares
    // `WritesResource(PhysicsWorldRef)`, registration now interns that name legitimately, with
    // the PERSISTENT allocator, before any frame runs. A test that dispatched first would find
    // the name already there and could not tell the two paths apart.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);

    try testing.expect(ecs.componentId(@typeName(sync.PhysicsWorldRef)) == null);
    try testing.expect(!sync.hasPhysicsWorld(&ecs));
    // THE ASSERTION: the lookup left the registry untouched. Under the defect this call is
    // what interns the name.
    try testing.expect(ecs.componentId(@typeName(sync.PhysicsWorldRef)) == null);
}

test "a frame dispatched before publication does nothing" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ecs = World.init();
    defer ecs.deinit(gpa);
    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.registerSystems(gpa, &sched, &ecs);
    try testing.expect(!sync.hasPhysicsWorld(&ecs));

    var f: u32 = 0;
    while (f < 3) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    try testing.expect(!sync.hasPhysicsWorld(&ecs));
}

test "registering the systems twice is refused, and refused before anything is registered" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.registerSystems(gpa, &sched, &ecs);
    try testing.expectEqual(@as(usize, 2), sched.systemCount());

    // PREFLIGHT: the second call must not register the first system before discovering the
    // second is a duplicate. The count is what discriminates — an implementation that
    // registered then failed would leave three.
    try testing.expectError(error.SystemAlreadyRegistered, sync.registerSystems(gpa, &sched, &ecs));
    try testing.expectEqual(@as(usize, 2), sched.systemCount());
}

/// A trigger body ALONE on its own entity, of a chosen type.
fn spawnLoneTrigger(
    gpa: std.mem.Allocator,
    ecs: *World,
    pw: *PhysicsWorld,
    body_type: api.BodyType,
    centre: [3]f32,
) !struct { entity: EntityId, body: api.BodyId } {
    const entity = try ecs.spawn(gpa, .{ .pos = .{ centre[0], centre[1], centre[2] } }, .{});
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var desc = api.BodyDescriptor{ .entity = entity, .body_type = body_type, .shape = shape };
    desc.position = av3(centre[0], centre[1], centre[2]);
    desc.is_trigger = true;
    if (body_type == .dynamic) desc.mass = 1;
    return .{ .entity = entity, .body = try pw.addBody(gpa, desc) };
}

test "a lone dynamic trigger is integrated, so it publishes its own pose" {
    // THE CASE AN EXCLUSION BY NATURE GOT WRONG. §1.13.7 says a trigger has no manifold, no
    // constraint, no impulse and no island entry — and says NOTHING about integration.
    // `integration.zig` filters on `body_type != .dynamic` and never on the trigger flag, so a
    // dynamic trigger falls under gravity: its pose IS a fact the solver resolved. Excluded
    // from publication it would drift away from its entity in silence, and its detection
    // volume with it.
    //
    // The rule is exclusion by CONCURRENCY, not by nature: a trigger yields only when another
    // body on the same entity publishes for it. Alone, it publishes per its type.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    const t = try spawnLoneTrigger(gpa, &ecs, &pw, .dynamic, .{ 0, 4, 0 });

    var k: u32 = 0;
    while (k < 20) : (k += 1) try frame(gpa, &pw, &ecs);

    const solver = pw.bm.position(t.body).?.toArray()[1];
    const published = ecs.get(Transform, t.entity).?.pos[1];
    try testing.expect(solver < 4.0 - 0.1); // NON-VACUITY: it really fell in the solver
    try testing.expectEqual(@as(f32, @floatCast(solver)), published);
}

test "a lone kinematic trigger still receives what gameplay writes" {
    // Reception is governed by TYPE and the trigger rule never touched it. A kinematic body's
    // pose is gameplay's, trigger or not.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    const t = try spawnLoneTrigger(gpa, &ecs, &pw, .kinematic, .{ 0, 1, 0 });
    ecs.getMut(Transform, t.entity).?.pos = .{ 7, 3, -2 };
    try frame(gpa, &pw, &ecs);

    const solver = pw.bm.position(t.body).?.toArray();
    try testing.expectEqual(@as(f32, 7), @as(f32, @floatCast(solver[0])));
    try testing.expectEqual(@as(f32, -2), @as(f32, @floatCast(solver[2])));
}

test "a competing writer of Transform in fixed_update is refused at registration" {
    // P1-2, and this is a FUTURE conflict written down rather than a defect here.
    // `engine-coordinate-system.md` §4.3 runs `TransformSystem` at the head of `fixed_update`
    // AND in `post_update`, writing `Transform` in both, while `scheduler.zig` makes two
    // writers of one component in one phase a hard registration error with no declarative
    // ordering to resolve it. `TransformSystem` exists NOWHERE in this repository — measured
    // — so nothing is broken today.
    //
    // The conflict is DECLARATIVE and not physical: §4.3 has dynamic bodies carry no parent by
    // convention, so the two systems write DISJOINT entity sets. The access model cannot
    // express that disjunction, and that is the real gap. This test makes the wall a measured
    // fact instead of an invisible incompatibility, and it will fail loudly on the day someone
    // attempts the assembly rather than during the integration of `TransformSystem`.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.registerSystems(gpa, &sched, &ecs);

    const Competitor = struct {
        fn run(_: core.ecs.SystemContext) anyerror!void {}
    };
    try testing.expectError(error.WriteWriteConflict, sched.registerSystem(gpa, &ecs, .{
        .phase = .fixed_update,
        .name = "transform_system_stand_in",
        .run = Competitor.run,
        .accesses = &.{core.ecs.Writes(Transform)},
    }));

    // NON-VACUITY: the same registration in a phase forge does not write is accepted, so what
    // the assertion above measures is the conflict and not a registration that always fails.
    try sched.registerSystem(gpa, &ecs, .{
        .phase = .late_update,
        .name = "transform_system_stand_in_elsewhere",
        .run = Competitor.run,
        .accesses = &.{core.ecs.Writes(Transform)},
    });
}

test "both systems declare the solver resource they mutate through the pointer" {
    // P2-3, and this test exists because its counter-factual first measured NOTHING: dropping
    // the declaration left every test green, which is a declaration nobody checks — the exact
    // class this milestone keeps finding. `ARCH-030` makes the declared set the TYPE of the
    // view a system receives, so an undeclared mutation lets two physics modules sit in one
    // phase with no edge between them and gives the future enforcement nothing to catch.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);
    try sync.registerSystems(gpa, &sched, &ecs);

    const wanted = @typeName(sync.PhysicsWorldRef);
    for ([_]core.ecs.Phase{ .pre_update, .fixed_update }) |phase| {
        const systems = sched.systemsInPhase(phase);
        try testing.expectEqual(@as(usize, 1), systems.len);
        var declared = false;
        for (systems[0].accesses) |a| {
            if (a.kind == .writes_resource and std.mem.eql(u8, a.type_name, wanted)) declared = true;
        }
        // Named per phase rather than counted over the pair: an aggregate would pass with one
        // system declaring it twice and the other not at all.
        try testing.expect(declared);
    }
}

/// Bind another body of a chosen role to an entity that already has one.
fn addSibling(
    gpa: std.mem.Allocator,
    pw: *PhysicsWorld,
    entity: EntityId,
    is_trigger: bool,
    centre: [3]f32,
) !api.BodyId {
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var desc = api.BodyDescriptor{ .entity = entity, .body_type = .dynamic, .shape = shape };
    desc.position = av3(centre[0], centre[1], centre[2]);
    desc.is_trigger = is_trigger;
    desc.mass = 1;
    return try pw.addBody(gpa, desc);
}

test "two triggers on one entity elect the smaller identity, not the last writer" {
    // Exclusion by concurrency arbitrated solid-against-trigger and nothing else: two triggers
    // do not exclude each other, so both wrote and the entity kept whichever came last in the
    // registration list — silent last-write-wins, which §1.13.6 refuses.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    const entity = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const first = try addSibling(gpa, &pw, entity, true, .{ 0, 1, 0 });
    const second = try addSibling(gpa, &pw, entity, true, .{ 0, 9, 0 });
    try testing.expect(first < second); // the premise the assertion below rests on

    var k: u32 = 0;
    while (k < 5) : (k += 1) try frame(gpa, &pw, &ecs);

    // THE VALUE, not merely "one write happened": the published pose is the ELECTED body's,
    // and the loser's differs by eight metres — so an election that picked the other one
    // cannot satisfy this.
    const published = ecs.get(Transform, entity).?.pos[1];
    try testing.expectEqual(@as(f32, @floatCast(pw.bm.position(first).?.toArray()[1])), published);
    try testing.expect(@abs(pw.bm.position(second).?.toArray()[1] - published) > 7);
}

test "two solid bodies on one entity elect the smaller identity" {
    // The other half the concurrency rule never reached: two non-triggers never entered the
    // arbitration at all, so both published every tick.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);

    const entity = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const first = try addSibling(gpa, &pw, entity, false, .{ 0, 2, 0 });
    const second = try addSibling(gpa, &pw, entity, false, .{ 0, 11, 0 });
    try testing.expect(first < second);

    var k: u32 = 0;
    while (k < 5) : (k += 1) try frame(gpa, &pw, &ecs);

    const published = ecs.get(Transform, entity).?.pos[1];
    try testing.expectEqual(@as(f32, @floatCast(pw.bm.position(first).?.toArray()[1])), published);
    try testing.expect(@abs(pw.bm.position(second).?.toArray()[1] - published) > 7);
}

/// A gameplay rule that drives a kinematic platform through `moveKinematic`, from `update`.
const KinematicDriver = struct {
    var world: *PhysicsWorld = undefined;
    var gpa: std.mem.Allocator = undefined;
    var body: api.BodyId = 0;
    var target: [3]f32 = .{ 0, 0, 0 };
    var pending: u32 = 0;

    fn run(_: core.ecs.SystemContext) anyerror!void {
        if (pending == 0) return;
        pending -= 1;
        try world.moveKinematic(
            gpa,
            body,
            vr(target[0], target[1], target[2]),
            pw_identity,
            fixed_dt,
        );
    }
    const pw_identity = forge_3d.Quatr{ .x = 0, .y = 0, .z = 0, .w = 1 };
};

test "moveKinematic issued from an update system is not undone by the next sync-in" {
    // P1-2. `moveKinematic` writes the pose and both velocities into the SOLVER; gameplay owns
    // a kinematic `Transform` and physics never publishes it, so the ECS copy stays where it
    // was. A sync-in comparing VALUES reads "they differ" and pushes the stale ECS pose back
    // through `setBodyTransform`, cancelling the move before the step.
    //
    // The call is issued FROM A SYSTEM IN `update`, which is the only position that exercises
    // it: made from the test body between frames it would be picked up as an ordinary gameplay
    // write and the defect would not show.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    const platform = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 2, 0.5, 2 }, .{ 0, 1, 0 });

    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    try sync.registerSystems(gpa, &sched, &ecs);

    KinematicDriver.world = &pw;
    KinematicDriver.gpa = gpa;
    KinematicDriver.body = platform.body;
    KinematicDriver.target = .{ 5, 1, 0 };
    KinematicDriver.pending = 1;
    try sched.registerSystem(gpa, &ecs, .{
        .phase = .update,
        .name = "kinematic_driver",
        .run = KinematicDriver.run,
        .accesses = &.{},
    });

    var f: u32 = 0;
    while (f < 4) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    // THE SOLVER kept the move. Under the defect it is back at x = 0, because sync-in pushed
    // the untouched ECS pose over it on the very next frame.
    try testing.expectEqual(@as(f32, 5), @as(f32, @floatCast(pw.bm.position(platform.body).?.toArray()[0])));
    // And the derived velocity survived too — the other half `moveKinematic` exists for.
    try testing.expect(pw.bm.linearVelocity(platform.body).?.toArray()[0] != 0);
}
