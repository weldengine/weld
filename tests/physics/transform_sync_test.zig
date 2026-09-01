//! M1.1.15 — the solver → ECS publication.
//!
//! What this file measures is the SEAM: which body speaks for an entity, what is published per
//! `BodyType`, and what the `Sleeping` marker does to publication. The ECS → solver direction
//! is M1.1.15.2's, with the Tier 1 Etch service — the tests that measured it left with it, and
//! two more kept only their publication half. The physics itself is measured by `forge_3d`'s
//! own suite and is not re-measured here.
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
const WorldRealT = api.precision.WorldReal;

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
/// entity identity — the binding the publication seam walks.
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

/// One driven frame on the DIRECT path: open the ECS frame, then run the tick and its
/// publication.
///
/// **The frame boundary is the caller's and never `stepAndPublish`'s.** An app loop and
/// `dispatchFrame` both open the frame themselves, so modelling it here keeps the two paths
/// identical in shape — and the change-detection guard below needs the tick to advance to say
/// anything at all.
fn frame(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    ecs.beginFrame();
    try sync.stepAndPublish(gpa, pw, ecs);
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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
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

test "Sleeping tag tracks island state through both transitions" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
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

test "publication authority per BodyType" {
    // The PUBLICATION half only. The reception half — a kinematic `Transform` written by
    // gameplay reaching the solver — moved to M1.1.15.2 with `syncIn`; see Closing notes. Two
    // assertions that the SOLVER had not moved were dropped with it: with no inward direction
    // they held for every body and named nothing about authority.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

    const dyn = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 10, 0 });
    const kin = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 20, 0, 0 });
    const sta = try spawnLinked(gpa, &ecs, &pw, .static, .{ 0.5, 0.5, 0.5 }, .{ 40, 0, 0 });

    // DYNAMIC — the SOLVER is the authority over the pose, so a gameplay write to `Transform`
    // is overwritten by the publication. That is the contract and not a bug: the legitimate
    // ways to move a dynamic body are `setBodyTransform`, a force or an impulse.
    ecs.getMut(Transform, dyn.entity).?.pos = .{ 99, 99, 99 };
    try frame(gpa, &pw, &ecs);
    try testing.expect(ecs.get(Transform, dyn.entity).?.pos[0] != 99);
    try testing.expectEqual(
        @as(f32, @floatCast(pw.bm.position(dyn.body).?.toArray()[1])),
        ecs.get(Transform, dyn.entity).?.pos[1],
    );

    // KINEMATIC — gameplay owns the pose, so the publication does NOT write it back and the
    // ECS value stands.
    ecs.getMut(Transform, kin.entity).?.pos = .{ 25, 3, 0 };
    try frame(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 25), ecs.get(Transform, kin.entity).?.pos[0]);

    // STATIC — no publication at all, so the ECS write stands. A static body that moves is a
    // teleportation through `setBodyTransform`, never a `Transform` write.
    ecs.getMut(Transform, sta.entity).?.pos = .{ 77, 0, 0 };
    try frame(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 77), ecs.get(Transform, sta.entity).?.pos[0]);
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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
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

    // NON-VACUITY, and it is what separates this from a publication that writes NOTHING. The
    // body is set moving through the INTERFACE — `syncIn` left for M1.1.15.2, so the ECS is no
    // longer a way in — and the marks must then FIRE.
    pw.setLinearVelocity(b.body, vr(3, 0, 0));

    // A fresh tick the test does not touch: any stamp below is publication's own.
    try frame(gpa, &pw, &ecs);
    try testing.expect(markedThisTick(&ecs, Transform, b.entity));
    try testing.expect(ecs.get(Transform, b.entity).?.pos[0] > settled_pos[0]);
}

test "a character presence never publishes for its entity" {
    // ONE ENTITY, TWO BODIES. `character.zig` creates the presence with
    // `.entity = desc.entity`, so the body store cannot tell the controller's inner body from
    // the entity's own. Walked as an ordinary body it would publish its own velocity — exactly
    // zero forever, a presence being kinematic and moved by pose write — over the entity's.
    //
    // This test measured a second half until the re-scope: that a gameplay `Transform` write
    // did not teleport the presence. There is no inward direction left here, so that assertion
    // held for EVERY body and discriminated nothing. The absence itself is pinned once, by
    // name, in `no component write reaches the solver` below.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

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

    // OUTWARD. The presence is moved by pose write, so its velocity columns are zero forever.
    // Published into the entity they would overwrite the entity's own `Velocity` with a
    // constant zero, every tick. The value written here survives because the seam skips it.
    ecs.getMut(Velocity, hero).?.linear = .{ 7, 0, 0 };
    try frame(gpa, &pw, &ecs);
    try testing.expectEqual(@as(f32, 7), ecs.get(Velocity, hero).?.linear[0]);
    try testing.expectEqual(@as(Real, 0), pw.bm.linearVelocity(presence).?.toArray()[0]);
}

test "the registered system drives a real frame: the solver's pose reaches the ECS" {
    // THE DELIVERABLE F5 NAMES. Before this, the composition entry had no caller outside this
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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
    try sync.registerSystems(gpa, &sched, &ecs);

    // ONE system: the publication rides the tick in `fixed_update`. Splitting it into a tick
    // and a `post_update` publication is what lost a gameplay `Velocity` write, and the
    // inward direction left for M1.1.15.2 — see Closing notes.
    try testing.expectEqual(@as(usize, 1), sched.systemCount());

    const start = ecs.get(Transform, faller.entity).?.pos[1];
    var f: u32 = 0;
    while (f < 30) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    // The body fell in the SOLVER and the ECS learned about it, per entity and by identity.
    const published = ecs.get(Transform, faller.entity).?.pos[1];
    const solver = pw.bm.position(faller.body).?.toArray()[1];
    try testing.expect(published < start - 0.05); // NON-VACUITY: it really moved
    try testing.expectEqual(@as(f32, @floatCast(solver)), published);
}

test "a trigger sharing an entity with a solid body does not publish" {
    // §1.13.7 denies a trigger a manifold, a constraint and an impulse, and the amended text
    // distinguishes TWO kinds of island entry: the CONSTRAINT island it cannot enter, no pair
    // reaching it, and the INTEGRATION SINGLETON it does enter — which is why a dynamic trigger
    // can ever stop being integrated. §1.13.1 makes two-bodies-one-entity the normal shape, and
    // the election settles which of the two speaks. The RECEPTION half of this test — sync-in pushing the entity's pose into the
    // trigger — left for M1.1.15.2 with `syncIn`; see Closing notes.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

    _ = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    const solid = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 4, 0 });

    // Registered AFTER the solid, so under a last-write-wins seam it is the trigger that wins
    // the tick — the order that makes the defect visible rather than benign.
    _ = try addTriggerBody(gpa, &pw, solid.entity, .{ 9, 9, 9 });

    var t: u32 = 0;
    while (t < 20) : (t += 1) try frame(gpa, &pw, &ecs);

    // The entity's Transform is the SOLID's pose, to the bit. Under the defect it is the
    // trigger's, nine metres away — not a tolerance question.
    const published = ecs.get(Transform, solid.entity).?.pos;
    const solid_pose = pw.bm.position(solid.body).?.toArray();
    try testing.expectEqual(@as(f32, @floatCast(solid_pose[1])), published[1]);
    try testing.expect(published[1] < 3.9); // NON-VACUITY: the solid really fell
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
    try testing.expect(sync.publishedPhysicsWorld(&ecs) == null);
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
    try testing.expect(sync.publishedPhysicsWorld(&ecs) == null);

    var f: u32 = 0;
    while (f < 3) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    try testing.expect(sync.publishedPhysicsWorld(&ecs) == null);
}

test "registering twice is refused, and refused before anything is registered" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.registerSystems(gpa, &sched, &ecs);
    try testing.expectEqual(@as(usize, 1), sched.systemCount());

    // PREFLIGHT: refused before anything is registered. The count is what discriminates — an
    // implementation that registered then failed would leave two.
    try testing.expectError(error.SystemAlreadyRegistered, sync.registerSystems(gpa, &sched, &ecs));
    try testing.expectEqual(@as(usize, 1), sched.systemCount());
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
    // constraint and no impulse, and its island exclusion is the CONSTRAINT island only: the
    // amended text grants it the INTEGRATION SINGLETON, without which it could never sleep and
    // would be integrated forever. `integration.zig` filters on `body_type != .dynamic` and
    // never on the trigger flag, so a dynamic trigger falls under gravity: its pose IS a fact
    // the solver resolved. Excluded from publication it would drift away from its entity in
    // silence, and its detection volume with it.
    //
    // The rule is exclusion by CONCURRENCY, not by nature: a trigger yields only when another
    // body on the same entity publishes for it. Alone, it publishes per its type.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

    const t = try spawnLoneTrigger(gpa, &ecs, &pw, .dynamic, .{ 0, 4, 0 });

    var k: u32 = 0;
    while (k < 20) : (k += 1) try frame(gpa, &pw, &ecs);

    const solver = pw.bm.position(t.body).?.toArray()[1];
    const published = ecs.get(Transform, t.entity).?.pos[1];
    try testing.expect(solver < 4.0 - 0.1); // NON-VACUITY: it really fell in the solver
    try testing.expectEqual(@as(f32, @floatCast(solver)), published);
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

test "the registered system declares the solver resource it mutates through the pointer" {
    // This test exists because its counter-factual first measured NOTHING: dropping the
    // declaration left every test green, which is a declaration nobody checks — and writing it
    // is what surfaced the dangling access slice. `ARCH-030` makes the declared set the TYPE
    // of the view a system receives, so an undeclared mutation lets two physics modules sit in
    // one phase with no edge between them.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);
    try sync.registerSystems(gpa, &sched, &ecs);

    const systems = sched.systemsInPhase(.fixed_update);
    try testing.expectEqual(@as(usize, 1), systems.len);
    var declared = false;
    for (systems[0].accesses) |a| {
        if (a.kind == .writes_resource and
            std.mem.eql(u8, a.type_name, @typeName(sync.PhysicsWorldRef))) declared = true;
    }
    try testing.expect(declared);

    // And nothing is registered in `pre_update` any more: the inward direction left with
    // `syncIn`. Asserted rather than assumed, so a re-registration there is visible.
    try testing.expectEqual(@as(usize, 0), sched.systemsInPhase(.pre_update).len);
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

test "publication order is unchanged by the index" {
    // **THE DENSE `BodyId` INDEX OF M1.1.15.1 IS AN ACCELERATOR AND NOT AN ORDER**, and this
    // is what says so. `proxyOf` became O(1) by reading a table keyed on the body index; the
    // two orders that the publication actually depends on — the registration order of
    // `bodies`, and the identity order the election sorts by — must be exactly what they
    // were. The scene is built so REGISTRATION ORDER AND IDENTITY ORDER DISAGREE, because
    // with them in step no assertion here could tell which one is being followed.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

    const spare = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const entity = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});

    // **THE CONSTRUCTION RESTS ON A LAYOUT FACT, and getting it backwards is how the first
    // version of this test failed on its own premise.** `PackedId` is
    // `index:24 | generation:8`, and a Zig packed struct puts its FIRST field in the LOW
    // bits — so a handle's numeric value is GENERATION-MAJOR, and a recycled index carries a
    // LARGER identity than a fresh one, not a smaller. The election compares the raw handle
    // (`Candidate.lessThan`, `a.body < b.body`), so to make registration order and identity
    // order disagree, the entity's FIRST body must be the recycled one.
    const throwaway = try addSibling(gpa, &pw, spare, false, .{ 0, 0, 0 });
    pw.removeBody(throwaway);
    const registered_first = try addSibling(gpa, &pw, entity, false, .{ 0, 1, 0 }); // recycled: high identity
    const registered_second = try addSibling(gpa, &pw, entity, false, .{ 0, 9, 0 }); // fresh: low identity

    // THE PREMISE, asserted rather than assumed — the whole test is vacuous without it.
    try testing.expect(registered_second < registered_first); // identity order is REVERSED
    try testing.expectEqual(registered_first, pw.bodies.items[0].id); // registration order
    try testing.expectEqual(registered_second, pw.bodies.items[1].id);

    var k: u32 = 0;
    while (k < 5) : (k += 1) try frame(gpa, &pw, &ecs);

    // (1) THE ELECTION STILL FOLLOWS IDENTITY, not the registration list and not the index's
    // own ascending order. The two candidates are eight metres apart, so an election that
    // picked the other one cannot satisfy this.
    const published = ecs.get(Transform, entity).?.pos[1];
    try testing.expectEqual(
        @as(f32, @floatCast(pw.bm.position(registered_second).?.toArray()[1])),
        published,
    );
    try testing.expect(@abs(pw.bm.position(registered_first).?.toArray()[1] - published) > 7);

    // (2) `bodies` KEPT ITS ORDER across the ticks. The index does not touch this list, and
    // a future edit that made the list follow the table instead would reverse these two.
    try testing.expectEqual(@as(usize, 2), pw.bodies.items.len);
    try testing.expectEqual(registered_first, pw.bodies.items[0].id);
    try testing.expectEqual(registered_second, pw.bodies.items[1].id);

    // (3) STEP 10 REFRESHED EVERY REGISTERED PROXY, whatever order it walked them in: each
    // body's stored fat box contains its tight box at the pose the tick ended on. A sweep
    // that lost a body — the M1.1.15 gate C defect, where a registration gap made step 2
    // prune every pair of one body — leaves that body's box stale and fails here.
    var refreshed: usize = 0;
    for (pw.bodies.items) |entry| {
        const fat = pw.bp.proxyAabb(entry.proxy).?;
        const tight = pw.bm.bodyAabb(&pw.store, entry.id).?;
        try testing.expect(fat.contains(tight.min));
        try testing.expect(fat.contains(tight.max));
        refreshed += 1;
    }
    try testing.expectEqual(pw.bodies.items.len, refreshed);
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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

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
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

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

test "a solid body wins over a trigger of SMALLER identity" {
    // NON-VACUITY for the criterion's SECOND level, and it exists because the counter-factual
    // that removes that level measured NOTHING against the tests above: in each of them the
    // solid happens to be created first, so identity alone already elects it. Here the trigger
    // is created FIRST and therefore has the smaller handle — only the solid-before-trigger
    // level can still elect the solid.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);

    const entity = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const trigger = try addSibling(gpa, &pw, entity, true, .{ 0, 9, 0 });
    const solid = try addSibling(gpa, &pw, entity, false, .{ 0, 1, 0 });
    try testing.expect(trigger < solid); // the premise: the loser has the SMALLER identity

    var k: u32 = 0;
    while (k < 5) : (k += 1) try frame(gpa, &pw, &ecs);

    const published = ecs.get(Transform, entity).?.pos[1];
    try testing.expectEqual(@as(f32, @floatCast(pw.bm.position(solid).?.toArray()[1])), published);
    try testing.expect(@abs(pw.bm.position(trigger).?.toArray()[1] - published) > 7);
}

test "a competing writer of Sleeping in fixed_update is refused at registration" {
    // The twin of the `Transform` conflict test. The publication adds and removes the marker,
    // so a second writer of it in the same phase must be refused — without the declaration it
    // would pass the preflight, and `ARCH-030` will make the declared set the TYPE of the view
    // a system receives at M1.A.
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
        .name = "sleeping_writer_stand_in",
        .run = Competitor.run,
        .accesses = &.{core.ecs.Writes(Sleeping)},
    }));

    // NON-VACUITY: the same writer in a phase forge does not write is accepted, so what the
    // assertion above measures is the conflict and not a registration that always fails.
    try sched.registerSystem(gpa, &ecs, .{
        .phase = .late_update,
        .name = "sleeping_writer_elsewhere",
        .run = Competitor.run,
        .accesses = &.{core.ecs.Writes(Sleeping)},
    });
}

test "no component write reaches the solver: the inward direction is M1.1.15.2's" {
    // THE ABSENCE, pinned ONCE and by name. Several tests used to carry an assertion of this
    // shape as a second half — "the solver did not follow the ECS write" — and after the
    // re-scope each held for every body and discriminated nothing, which is a test counted and
    // half empty.
    //
    // Driven through `registerSystems` and `dispatchFrame`, which is the PRODUCTION path: the
    // first version went through `stepAndPublish`, so an inward read reintroduced inside
    // `stepAndPublishSystem` would have left it green. And every field the departed `syncIn`
    // acted on is written here — position AND rotation, linear AND angular — because the name
    // says "no component write" and a body that walked only two of the four would claim a
    // wider set than it visits.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    const dyn = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 2, 0 });
    const kin = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 20, 0, 0 });

    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
    try sync.registerSystems(gpa, &sched, &ecs);

    const dyn_pose = pw.bm.position(dyn.body).?.toArray();
    const kin_pose = pw.bm.position(kin.body).?.toArray();
    const dyn_rot = pw.bm.rotation(dyn.body).?;
    const kin_rot = pw.bm.rotation(kin.body).?;

    // EVERY field the inward direction acted on, on both simulated kinds.
    for ([_]EntityId{ dyn.entity, kin.entity }) |e| {
        const t = ecs.getMut(Transform, e).?;
        t.pos = .{ 90, 91, 92 };
        t.rot = .{ 0.5, 0.5, 0.5, 0.5 }; // a unit quaternion, and not the identity
        const v = ecs.getMut(Velocity, e).?;
        v.linear = .{ 5, 0, 0 };
        v.angular = .{ 0, 3, 0 };
    }

    var f: u32 = 0;
    while (f < 5) : (f += 1) try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

    // ZERO gravity and no contact, so the solver has no reason of its own to move either body:
    // any movement here is a component write that got through.
    try testing.expectEqual(kin_pose[0], pw.bm.position(kin.body).?.toArray()[0]);
    try testing.expectEqual(kin_pose[1], pw.bm.position(kin.body).?.toArray()[1]);
    try testing.expectEqual(dyn_pose[0], pw.bm.position(dyn.body).?.toArray()[0]);
    try testing.expectEqual(dyn_pose[1], pw.bm.position(dyn.body).?.toArray()[1]);
    try testing.expectEqual(dyn_rot.w, pw.bm.rotation(dyn.body).?.w);
    try testing.expectEqual(kin_rot.w, pw.bm.rotation(kin.body).?.w);
    try testing.expectEqual(@as(Real, 0), pw.bm.linearVelocity(dyn.body).?.toArray()[0]);
    try testing.expectEqual(@as(Real, 0), pw.bm.linearVelocity(kin.body).?.toArray()[0]);
    try testing.expectEqual(@as(Real, 0), pw.bm.angularVelocity(dyn.body).?.toArray()[1]);
    try testing.expectEqual(@as(Real, 0), pw.bm.angularVelocity(kin.body).?.toArray()[1]);

    // NON-VACUITY: the API path DOES move the solver on this very scene, so the assertions
    // above are about the component path and not about a world where nothing ever moves.
    pw.setLinearVelocity(dyn.body, vr(5, 0, 0));
    try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);
    try testing.expect(pw.bm.position(dyn.body).?.toArray()[0] > dyn_pose[0]);
}

test "the published handle is withdrawn before the world it names is destroyed" {
    // P1-1, and the sequence is the whole test. `publishPhysicsWorld` writes raw pointers,
    // `PhysicsWorld.deinit` frees and poisons, and nothing used to clear the resource:
    // the accessor kept answering with a dead address and the next dispatch dereferenced it.
    // The ordinary runtime order being safe is not a contract.
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

    {
        var pw = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
        _ = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 4, 0 });
        try sync.publishPhysicsWorld(gpa, &ecs, &pw);
        defer sync.unpublishPhysicsWorld(&ecs, &pw);
        try sync.registerSystems(gpa, &sched, &ecs);
        try testing.expect(sync.publishedPhysicsWorld(&ecs) != null);

        try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);

        // WITHDRAWN BEFORE DESTROYED, and asserted in that order: after this line nothing can
        // reach the world, which is what makes the destruction below safe.
        sync.unpublishPhysicsWorld(&ecs, &pw);
        try testing.expect(sync.publishedPhysicsWorld(&ecs) == null);
        pw.deinit(gpa);
    }

    // And a frame dispatched afterwards is a no-op rather than a dereference of freed memory.
    // Under the defect this is where the world would be read back.
    try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);
    try testing.expect(sync.publishedPhysicsWorld(&ecs) == null);
}

test "a late withdrawal cannot erase the world published after it" {
    // THE SEQUENCE: publish A, publish B, then run A's deferred teardown. A withdrawal that
    // cleared whatever it found would erase B, and every frame afterwards would be a silent
    // no-op — the owner of B having done nothing wrong and nobody having withdrawn it.
    //
    // The assertion is on the IDENTITY of the resolved handle and never on a boolean: a
    // withdrawal that had erased B and left something else resolvable would satisfy
    // "something is published" and fail only here.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);

    var a = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer a.deinit(gpa);
    var b = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer b.deinit(gpa);

    try sync.publishPhysicsWorld(gpa, &ecs, &a);
    try testing.expectEqual(@as(?*PhysicsWorld, &a), sync.publishedPhysicsWorld(&ecs));

    // A withdraws itself, then B takes the slot — the ordered form the contract asks for.
    sync.unpublishPhysicsWorld(&ecs, &a);
    try sync.publishPhysicsWorld(gpa, &ecs, &b);
    try testing.expectEqual(@as(?*PhysicsWorld, &b), sync.publishedPhysicsWorld(&ecs));

    // A's LATE teardown, however far behind it runs. It must find someone else's handle and
    // leave it alone.
    sync.unpublishPhysicsWorld(&ecs, &a);
    try testing.expectEqual(@as(?*PhysicsWorld, &b), sync.publishedPhysicsWorld(&ecs));

    // And B's own withdrawal still works, so the guard refuses the wrong caller and not every
    // caller — without this the test would pass against a withdrawal that never clears.
    sync.unpublishPhysicsWorld(&ecs, &b);
    try testing.expectEqual(@as(?*PhysicsWorld, null), sync.publishedPhysicsWorld(&ecs));
}

test "publishing over a live publication is refused, and leaves the first in place" {
    // The twin: a silent replacement is the exact counterpart of a blind withdrawal — it makes
    // A disappear without anyone having withdrawn it. Refused, not replaced.
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);

    var a = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer a.deinit(gpa);
    var b = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer b.deinit(gpa);

    try sync.publishPhysicsWorld(gpa, &ecs, &a);
    defer sync.unpublishPhysicsWorld(&ecs, &a);

    try testing.expectError(
        error.PhysicsWorldAlreadyPublished,
        sync.publishPhysicsWorld(gpa, &ecs, &b),
    );
    // IDENTITY again: a refusal that had still written B would leave a boolean green.
    try testing.expectEqual(@as(?*PhysicsWorld, &a), sync.publishedPhysicsWorld(&ecs));

    // And the ordered form is accepted, so the refusal is about a LIVE publication and not
    // about publishing twice ever.
    sync.unpublishPhysicsWorld(&ecs, &a);
    try sync.publishPhysicsWorld(gpa, &ecs, &b);
    try testing.expectEqual(@as(?*PhysicsWorld, &b), sync.publishedPhysicsWorld(&ecs));
    sync.unpublishPhysicsWorld(&ecs, &b);
}

// --- M1.1.15.2 G5b — the inward direction and the authority model -------------

const sync_in = sync.in;
const RigidBody = api.RigidBody;

/// Give `entity` a `RigidBody` carrying `auth`. The component is what the model
/// DECLARES authority through — there is nothing to detect and nothing to infer.
fn declare(gpa: std.mem.Allocator, ecs: *World, entity: EntityId, auth: api.PhysicsAuthority) !void {
    try ecs.addComponent(gpa, entity, RigidBody, .{ .authority = auth });
}

/// One inward pass at the top of a frame, in the normative order:
/// gameplay writes → syncIn → step → syncOut.
fn frameWithSyncIn(
    gpa: std.mem.Allocator,
    pw: *PhysicsWorld,
    ecs: *World,
    journal: *sync_in.Journal,
) !sync_in.SyncInResult {
    ecs.beginFrame();
    const r = try sync_in.syncIn(gpa, pw, ecs, journal);
    try sync.stepAndPublish(gpa, pw, ecs);
    return r;
}

test "dynamic gameplay-authoritative body is not published" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    // TWO dynamic bodies falling under identical gravity, differing ONLY in their
    // declared authority — so the difference below is the authority and nothing else.
    const solver_side = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 10, 0 });
    const gameplay_side = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 5, 10, 0 });
    try declare(gpa, &ecs, solver_side.entity, .solver);
    try declare(gpa, &ecs, gameplay_side.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    for (0..4) |_| _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    // The solver-authoritative one has been published: its ECS pose FELL.
    const published = ecs.get(Transform, solver_side.entity).?.pos[1];
    try testing.expect(published < 10);

    // The gameplay-authoritative one publishes NOTHING: its ECS pose is exactly where
    // gameplay left it, to the bit.
    try testing.expectEqual(@as(WorldRealT, 10), ecs.get(Transform, gameplay_side.entity).?.pos[1]);

    // AND IT STILL STEPPED — the half a "not published" assertion cannot carry on its
    // own. The SOLVER's own position for that body has fallen, so the body kept its mass
    // and its integration; only the publication was withheld. Removing it from
    // integration would amount to changing its `BodyType` at runtime.
    const solver_y = pw.bm.position(gameplay_side.body).?.toArray()[1];
    try testing.expect(solver_y < 10);

    // Its velocity is not published either — both channels, not just the pose.
    try testing.expectEqual(@as(WorldRealT, 0), ecs.get(Velocity, gameplay_side.entity).?.linear[1]);
}

test "no wake on an unchanged gameplay body" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    // THE LOAD-BEARING TEST OF THIS GATE. `setBodyTransform` composes the wake
    // UNCONDITIONALLY — itself, W4 on retained partners, `refreshProxy` — and the
    // velocity setters wake before writing. Without the change-driven guard every
    // `.gameplay` entity stays awake and feeds the broadphase for nothing.
    const g = try spawnLinked(gpa, &ecs, &pw, .static, .{ 5, 0.5, 5 }, .{ 0, 0, 0 });
    _ = g;
    const b = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 1.0, 0 });
    try declare(gpa, &ecs, b.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    // First pass consumes nothing: the ECS pose was written at spawn to the same value
    // the body was created with, so the VALUE predicate refuses it even though the tick
    // predicate admits it. That conjunction is the subject.
    const first = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), first.woke);

    // Let it settle, then keep ticking with NOBODY touching the ECS.
    for (0..200) |_| _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expect(pw.bm.isSleeping(b.body).?);

    var total_woke: u32 = 0;
    for (0..30) |_| {
        const r = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
        total_woke += r.woke;
    }
    // ZERO wakes over thirty ticks, and the body is STILL asleep — the second half,
    // because a count of zero would also hold for a pass that never ran.
    try testing.expectEqual(@as(u32, 0), total_woke);
    try testing.expect(pw.bm.isSleeping(b.body).?);

    // NON-VACUITY, and it is what makes the zero above mean something: one real ECS
    // write DOES wake it, on the very next pass. A guard that refused everything would
    // pass every assertion so far.
    const t = ecs.getMut(Transform, b.entity).?;
    t.pos[0] += 1;
    const after = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), after.woke);
    try testing.expectEqual(@as(u32, 1), after.poses_applied);

    // AND THE OTHER HALF OF THE CONJUNCTION: a `getMut` that changes NOTHING marks
    // `changed_tick` all the same, so the tick predicate admits it — and the value
    // predicate must still refuse. Without this the guard could be the tick alone.
    _ = ecs.getMut(Transform, b.entity).?;
    const touched = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), touched.woke);
}

test "wrapper application is not replayed by syncIn in the same tick" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    const b = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs, b.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    ecs.beginFrame();

    // THE WRAPPER PATH: an explicit call applies to the solver AND mirrors into the ECS,
    // then marks the journal. `physics_move_kinematic` is the real one; here the two
    // halves are written out so the journal's job is visible.
    pw.moveKinematic(b.body, vr(3, 0, 0), forge_3d.Quatr.identity, fixed_dt);
    const t = ecs.getMut(Transform, b.entity).?;
    t.pos[0] = 3;
    try journal.markApplied(gpa, b.body, ecs.current_tick);

    // syncIn must NOT apply it a second time. The difference is observable: the wrapper
    // DERIVED a velocity, and a replay through `setBodyTransform` — a teleportation that
    // derives nothing — would wipe it.
    const derived_before = pw.bm.linearVelocity(b.body).?.toArray()[0];
    try testing.expect(derived_before > 0);

    const r = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), r.poses_applied);
    try testing.expectApproxEqAbs(derived_before, pw.bm.linearVelocity(b.body).?.toArray()[0], 1e-5);

    // NON-VACUITY: without the mark, the same setup DOES get consumed — so the zero above
    // is the journal's doing and not a pass that consumes nothing.
    var naive: sync_in.Journal = .{};
    defer naive.deinit(gpa);
    const r2 = try sync_in.syncIn(gpa, &pw, &ecs, &naive);
    try testing.expectEqual(@as(u32, 0), r2.poses_applied); // values already agree
    // Make them disagree and the naive journal consumes what the marked one refused.
    ecs.beginFrame();
    ecs.getMut(Transform, b.entity).?.pos[0] = 9;
    const r3 = try sync_in.syncIn(gpa, &pw, &ecs, &naive);
    try testing.expectEqual(@as(u32, 1), r3.poses_applied);
}

test "authority transition solver→gameplay seeds from the published pose" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    const b = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 10, 0 });
    try declare(gpa, &ecs, b.entity, .solver);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    for (0..10) |_| _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    // The body has fallen and its pose has been PUBLISHED, so the ECS already holds the
    // seed. Handing authority to gameplay must therefore push NOTHING — the two sides
    // already agree, which is the whole content of "seeds from the published pose".
    const published = ecs.get(Transform, b.entity).?.pos;
    try testing.expect(published[1] < 10);

    ecs.getMut(RigidBody, b.entity).?.authority = .gameplay;
    const r = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), r.transitions);
    try testing.expectEqual(@as(u32, 0), r.poses_applied);
    try testing.expectEqual(@as(u32, 0), r.woke);

    // And from that tick on the pose is FROZEN in the ECS: gameplay owns it, so the
    // publication stops. Without this the transition could be counted and ignored.
    const held = ecs.get(Transform, b.entity).?.pos[1];
    for (0..5) |_| _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(held, ecs.get(Transform, b.entity).?.pos[1]);
}

test "gameplay→solver pushes current ECS Transform and Velocity" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    const b = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs, b.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    // Gameplay drives the body somewhere the solver has never been, and gives it a
    // velocity the solver never computed.
    ecs.beginFrame();
    ecs.getMut(Transform, b.entity).?.pos[0] = 12;
    ecs.getMut(Velocity, b.entity).?.linear[0] = 7;
    _ = try sync_in.syncIn(gpa, &pw, &ecs, &journal);

    // Hand authority back. The pose and the velocity the ECS holds are pushed AS THEY
    // ARE — no derivation. Derivation stays the explicit operation of `moveKinematic`,
    // and a derived velocity here would be `(12 - previous) / dt`, nothing like 7.
    ecs.beginFrame();
    ecs.getMut(RigidBody, b.entity).?.authority = .solver;
    const r = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), r.transitions);

    try testing.expectApproxEqAbs(@as(Real, 12), pw.bm.position(b.body).?.toArray()[0], 1e-5);
    try testing.expectApproxEqAbs(@as(Real, 7), pw.bm.linearVelocity(b.body).?.toArray()[0], 1e-5);
}

test "syncIn pushes only the elected body" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    // ONE entity, TWO bodies. Both directions must elect the SAME one, or `syncOut`
    // publishes from a body `syncIn` does not drive — two sources answering differently
    // about one geometric fact.
    const a = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    const second = try pw.addBody(gpa, blk: {
        const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        var d = api.BodyDescriptor{ .entity = a.entity, .body_type = .kinematic, .shape = shape };
        d.position = av3(0, 0, 0);
        break :blk d;
    });
    try declare(gpa, &ecs, a.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    ecs.beginFrame();
    ecs.getMut(Transform, a.entity).?.pos[0] = 4;
    const r = try sync_in.syncIn(gpa, &pw, &ecs, &journal);

    // EXACTLY ONE application, not two — the entity has two bodies and only the elected
    // one is driven.
    try testing.expectEqual(@as(u32, 1), r.poses_applied);

    // And it is the SAME body `syncOut` elects. Asserted by identity rather than by
    // count: a count of one would hold whichever of the two was driven.
    const table = try sync.electPublishers(gpa, &pw);
    defer table.deinit(gpa);
    var elected: api.BodyId = 0;
    for (pw.bodies.items, 0..) |entry, reg| {
        if (table.publishes[reg]) elected = entry.id;
    }
    const moved = pw.bm.position(elected).?.toArray()[0];
    const other = pw.bm.position(if (elected == a.body) second else a.body).?.toArray()[0];
    try testing.expectApproxEqAbs(@as(Real, 4), moved, 1e-5);
    try testing.expectApproxEqAbs(@as(Real, 0), other, 1e-5);
}

test "a gameplay-authoritative trigger follows before the sensor pass reads it" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    // THE SENSOR FOLLOWS FROM THE ORDER AND FROM NOTHING ELSE — measured rather than
    // assumed. `syncIn` runs before `step`, and the sensor pass is step 10 bis, so a
    // gameplay-authored trigger is already at its new pose when the pass reads it.
    const trigger_entity = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const trigger = try addTriggerBody(gpa, &pw, trigger_entity, .{ 0, 0, 0 });
    _ = trigger;
    try declare(gpa, &ecs, trigger_entity, .gameplay);
    const occupant = try spawnLinked(gpa, &ecs, &pw, .static, .{ 0.5, 0.5, 0.5 }, .{ 20, 0, 0 });
    _ = occupant;

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(usize, 0), pw.sensors.current.items.len);

    // Gameplay teleports the trigger onto the occupant. The overlap must appear in the
    // SAME tick — a tick later would mean the pose reached the solver after the pass.
    ecs.beginFrame();
    ecs.getMut(Transform, trigger_entity).?.pos[0] = 20;
    _ = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try sync.stepAndPublish(gpa, &pw, &ecs);
    try testing.expectEqual(@as(usize, 1), pw.sensors.current.items.len);
    try testing.expectEqual(trigger_entity.index, pw.sensors.current.items[0].trigger.index);
}

test "the registered system runs syncIn before step when a journal is attached" {
    // THE ORDER, THROUGH THE SCHEDULER and not through a test's own composition. Without
    // this the inward direction would exist only where a test calls it — the very defect
    // M1.1.15's closing pass fixed for the outward half, and the reason `syncIn` runs
    // inside `stepAndPublishSystem` rather than in a caller's discipline.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    const b = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs, b.entity, .gameplay);

    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);
    var sched = core.ecs.SystemScheduler.init();
    defer sched.deinit(gpa);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs, &pw);
    defer sync.unpublishPhysicsWorld(&ecs, &pw);
    try sync.attachSyncInJournal(&ecs, &journal);
    try sync.registerSystems(gpa, &sched, &ecs);

    // Gameplay writes the ECS; the dispatched frame must carry it into the solver.
    ecs.getMut(Transform, b.entity).?.pos[0] = 6;
    try sched.dispatchFrame(&ecs, gpa, io, &jobs, fixed_dt_f32, null);
    try testing.expectApproxEqAbs(@as(Real, 6), pw.bm.position(b.body).?.toArray()[0], 1e-5);

    // NON-VACUITY on the attachment: a SECOND world with no journal does not consume,
    // so the assertion above is the journal's doing and not something the frame would
    // do anyway. Same shape, same write, one difference.
    var ecs2 = World.init();
    defer ecs2.deinit(gpa);
    var pw2 = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw2.deinit(gpa);
    const b2 = try spawnLinked(gpa, &ecs2, &pw2, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs2, b2.entity, .gameplay);
    var sched2 = core.ecs.SystemScheduler.init();
    defer sched2.deinit(gpa);
    try sync.publishPhysicsWorld(gpa, &ecs2, &pw2);
    defer sync.unpublishPhysicsWorld(&ecs2, &pw2);
    try sync.registerSystems(gpa, &sched2, &ecs2);
    ecs2.getMut(Transform, b2.entity).?.pos[0] = 6;
    try sched2.dispatchFrame(&ecs2, gpa, io, &jobs, fixed_dt_f32, null);
    try testing.expectApproxEqAbs(@as(Real, 0), pw2.bm.position(b2.body).?.toArray()[0], 1e-5);
}

test "the change baseline advances on a comparison without difference" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    // **F8.** The baseline used to advance only when a value was APPLIED, so a body
    // whose ECS and solver agree — which is every `.gameplay` body from creation until
    // gameplay first moves it — kept `consumed_tick` at `null` FOREVER and was
    // re-compared every tick. The tick predicate then filtered nothing, and the guard
    // the two-predicate design exists for was carried entirely by the value comparison
    // it was supposed to spare.
    const b = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs, b.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    // Tick 1 — the spawn stamped `Transform`, so the TICK predicate admits, the VALUE
    // predicate refuses (ECS and solver agree), and nothing is applied.
    const first = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), first.poses_applied);

    // THE ASSERTION: the baseline moved anyway. Read through the journal itself, which
    // is what distinguishes "examined and found equal" from "never looked at" — the two
    // are indistinguishable from the outside, and that is why the defect was silent.
    try testing.expect(journal.entryOf(b.body).?.consumed_tick != null);
    const baseline = journal.entryOf(b.body).?.consumed_tick.?;

    // Tick 2 — nobody touched the ECS, so the TICK predicate now refuses and the
    // baseline does NOT move. Under the defect it stayed `null` here and the value
    // comparison ran again.
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(baseline, journal.entryOf(b.body).?.consumed_tick.?);

    // A REAL write moves it again and is applied — so the advance above is a filter and
    // not a journal that stopped recording.
    ecs.beginFrame();
    ecs.getMut(Transform, b.entity).?.pos[0] = 3;
    const applied = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), applied.poses_applied);
    try testing.expect(journal.entryOf(b.body).?.consumed_tick.? > baseline);

    // And a `getMut` that changes NOTHING advances the baseline without applying —
    // the exact case the fix is about, asserted on both halves at once.
    const after_real = journal.entryOf(b.body).?.consumed_tick.?;
    ecs.beginFrame();
    _ = ecs.getMut(Transform, b.entity).?;
    const touched = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), touched.poses_applied);
    try testing.expectEqual(@as(u32, 0), touched.woke);
    try testing.expect(journal.entryOf(b.body).?.consumed_tick.? > after_real);
}

test "removing a body leaves its neighbour's journal entry untouched" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    // **G9, and the oracle has to be built so that INHERITANCE IS VISIBLE.** The
    // journal was keyed by registration position and `removeBody` uses
    // `orderedRemove` — its own comment says "ordered: the sweep order stays stable"
    // — so the body after the removed one moved into its slot and took its entry.
    //
    // Asserting that the neighbour "still works" is weaker than the claim. What has
    // to be shown is that it does NOT take the removed body's state, so the removed
    // body is given a state that is DISTINCT and RECOGNISABLE first: `.gameplay`
    // authority and a baseline advanced by a real application. The neighbour has
    // neither. Under the defect it acquires both, and each produces its own
    // observable corruption.
    const doomed = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    const neighbour = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ 50, 0, 0 });
    try declare(gpa, &ecs, doomed.entity, .gameplay);
    try declare(gpa, &ecs, neighbour.entity, .solver);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    // Give the doomed body its recognisable state: a real application, so `seen` is
    // true, `last_authority` is `.gameplay` and `consumed_tick` is advanced.
    ecs.beginFrame();
    ecs.getMut(Transform, doomed.entity).?.pos[0] = 4;
    const seeded = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), seeded.poses_applied);
    const doomed_entry = journal.entryOf(doomed.body).?;
    try testing.expect(doomed_entry.seen);
    try testing.expectEqual(api.PhysicsAuthority.gameplay, doomed_entry.last_authority);
    try testing.expect(doomed_entry.consumed_tick != null);
    // The neighbour HAS an entry, and a first version of this test asserted it did
    // not — measured wrong: `syncIn` takes the slot for every ELECTED body, before
    // the authority check, because the transition detection needs the authority it
    // observed whether or not it consumed anything. What matters is that the entry is
    // DISTINCT: `.solver`, never consumed, against the doomed body's `.gameplay` with
    // an advanced baseline. Inheritance is visible precisely because the two differ
    // on both fields.
    const before = journal.entryOf(neighbour.body).?;
    try testing.expectEqual(api.PhysicsAuthority.solver, before.last_authority);
    // **ASSERTION WEAKENED AT G12, DELIBERATELY, AND THE LOSS IS NAMED.** This line read
    // `try testing.expect(before.consumed_tick == null);` and it was true because nothing
    // advanced a `.solver` baseline. G12 advances it for every `.solver` body, which is
    // what closes the null-baseline trap of the forbidden-mutation diagnostic — so the
    // two entries no longer differ on that field and inheriting it is no longer
    // observable. It is also no longer harmful: both carry the same tick.
    //
    // What still discriminates is `last_authority`, and it is the half that carried the
    // defect — the fabricated transition below comes from inheriting `.gameplay`, never
    // from inheriting a tick. The load-bearing assertion of this test is unchanged.
    try testing.expect(before.consumed_tick != null);
    try testing.expect(before.last_authority != doomed_entry.last_authority);

    // THE REMOVAL. `doomed` was registered first, so the neighbour shifts into its
    // position — which is what the old key was.
    pw.removeBody(doomed.body);

    // (1) NO FABRICATED TRANSITION. Under the defect the neighbour inherits
    // `seen = true` and `last_authority = .gameplay`, so `syncIn` reads its real
    // `.solver` as a CHANGE of the field and performs a `gameplay → solver`
    // transition that never happened — pushing its ECS pose into the solver.
    ecs.beginFrame();
    const after = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), after.transitions);
    try testing.expectEqual(@as(u32, 0), after.poses_applied);
    // Its solver pose is where it was created, not where the ECS holds it — the two
    // agree here, so the assertion above is the discriminating one and this is the
    // corroboration that nothing moved.
    try testing.expectApproxEqAbs(@as(Real, 50), pw.bm.position(neighbour.body).?.toArray()[0], 1e-5);

    // (2) NO INHERITED BASELINE. Hand the neighbour to gameplay and move it: the
    // change must be APPLIED. Under the defect it inherited the doomed body's
    // advanced `consumed_tick`, so the tick predicate filtered its write out and a
    // legitimate modification was ignored — the other direction of the same
    // corruption, and the one an "it still works" assertion would miss entirely.
    //
    // TWO TICKS AND NOT ONE, SINCE G10: the `solver → gameplay` tick SEEDS the ECS from
    // the solver and consumes nothing, so a write made in the same tick as the flip is
    // overwritten by the solver's own state — by design, that state being the control
    // base gameplay is entitled to start from. Gameplay drives from the NEXT tick, and
    // it is that tick the inherited baseline would filter out.
    ecs.beginFrame();
    ecs.getMut(RigidBody, neighbour.entity).?.authority = .gameplay;
    const flip = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), flip.seeded);
    try testing.expectEqual(@as(u32, 0), flip.poses_applied);

    ecs.beginFrame();
    ecs.getMut(Transform, neighbour.entity).?.pos[0] = 77;
    const moved = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), moved.poses_applied);
    try testing.expectApproxEqAbs(@as(Real, 77), pw.bm.position(neighbour.body).?.toArray()[0], 1e-5);

    // (3) THE GENERATION IS PART OF THE KEY. A recycled slot names a different body,
    // so keying on the index alone would reintroduce the inheritance through the
    // recycling path rather than through the shift. The doomed slot is free now; a
    // fresh body takes it and must start with no entry.
    const reused = try spawnLinked(gpa, &ecs, &pw, .kinematic, .{ 0.5, 0.5, 0.5 }, .{ -30, 0, 0 });
    try testing.expect(journal.entryOf(reused.body) == null);
    // Same slot index, different generation — the premise of (3), asserted rather
    // than assumed, since without slot reuse the check above is about a new key and
    // proves nothing about generations.
    const doomed_packed: api.PackedId = @bitCast(doomed.body);
    const reused_packed: api.PackedId = @bitCast(reused.body);
    try testing.expectEqual(doomed_packed.index, reused_packed.index);
    try testing.expect(doomed_packed.generation != reused_packed.generation);
}

// ---------------------------------------------------------------------------
// M1.1.15.2 G10 — the resolution regime of a `.gameplay` DYNAMIC body, and the
// direction of the `solver → gameplay` transition.
// ---------------------------------------------------------------------------

/// A platform of unit mass at `centre`, immobile under gravity so that the only thing
/// separating the three configurations below is its INVERSE MASS during resolution.
fn spawnPlatform(
    gpa: std.mem.Allocator,
    ecs: *World,
    pw: *PhysicsWorld,
    body_type: api.BodyType,
) !struct { entity: EntityId, body: api.BodyId } {
    const centre = [3]f32{ 0, 0, 0 };
    const entity = try ecs.spawn(gpa, .{ .pos = centre }, .{});
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(2, 0.5, 2) } });
    var desc = api.BodyDescriptor{ .entity = entity, .body_type = body_type, .shape = shape };
    desc.position = av3(centre[0], centre[1], centre[2]);
    desc.restitution = 0;
    desc.can_sleep = false;
    if (body_type == .dynamic) {
        desc.mass = 1;
        // Held against gravity WITHOUT being made infinitely heavy: the finite-mass
        // control has to fall under the contact and only under the contact, or the
        // comparison would measure free fall instead of the impulse split.
        desc.gravity_factor = 0;
    }
    return .{ .entity = entity, .body = try pw.addBody(gpa, desc) };
}

/// Drop a unit ball on a platform of the given nature and return the ball's linear
/// velocity along Y after `ticks` frames of the normative order.
fn ballVelocityAfterImpact(
    gpa: std.mem.Allocator,
    platform_type: api.BodyType,
    platform_authority: api.PhysicsAuthority,
    ticks: usize,
) !struct { vy: f32, contacts: u32 } {
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    const platform = try spawnPlatform(gpa, &ecs, &pw, platform_type);
    try declare(gpa, &ecs, platform.entity, platform_authority);
    const ball = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 2.0, 0 });
    try declare(gpa, &ecs, ball.entity, .solver);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    var contacts: u32 = 0;
    var i: usize = 0;
    while (i < ticks) : (i += 1) {
        _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
        if (pw.constraints.items.len > 0) contacts += 1;
    }
    return .{ .vy = sync.solverVelocity(&pw, ball.body).linear[1], .contacts = contacts };
}

test "a gameplay dynamic body pushes exactly as an infinite mass, and a finite one pushes less" {
    const gpa = testing.allocator;

    // The number of ticks is the SAME for the three, and it is the only thing they share
    // besides the geometry: the ball is dropped from the same height onto a platform of
    // the same size at the same place, so the pre-impact velocity is identical by
    // construction and the post-impact one measures the impulse it received.
    const ticks = 40;

    // (1) REFERENCE — a KINEMATIC platform. Infinite mass, and ORDINARY softness:
    // `usesStaticSoftness` keys on `.static` alone, deliberately, so a kinematic partner
    // and a dynamic one select the same coefficients and the comparison below isolates
    // the inverse mass rather than the stiffening.
    const reference = try ballVelocityAfterImpact(gpa, .kinematic, .solver, ticks);

    // (2) UNDER TEST — a DYNAMIC platform under `.gameplay` authority. Same `BodyType`
    // as (3), same mass, same island, same shapes; only the declared authority differs.
    const gameplay = try ballVelocityAfterImpact(gpa, .dynamic, .gameplay, ticks);

    // (3) THE COUNTER-FACTUAL, MATERIALISED IN TREE rather than left to a code edit: the
    // same dynamic platform with its inverse mass RESTORED, which is what `.solver`
    // authority means for the resolution. It is the regime the normative text names as
    // the defect, and this row is what makes the equality above non-vacuous.
    const finite = try ballVelocityAfterImpact(gpa, .dynamic, .solver, ticks);

    // NON-VACUITY FIRST: all three must actually have resolved contacts, or the three
    // velocities would agree because nothing ever touched.
    try testing.expect(reference.contacts > 0);
    try testing.expect(gameplay.contacts > 0);
    try testing.expect(finite.contacts > 0);

    // CONSERVATION. The gameplay-authoritative body pushes the ball EXACTLY as the
    // infinite mass does — bit for bit, because `resolutionMotion` substitutes the same
    // values `body.zig` writes for a kinematic body and every other input is equal.
    try testing.expectEqual(reference.vy, gameplay.vy);

    // AND THE COUNTER-FACTUAL GOES THE WAY THE DEFECT PREDICTS: with the inverse mass
    // restored, the platform absorbs a share of the impulse, so the ball receives LESS
    // and retains more of its downward velocity. Strictly less, not merely different —
    // the direction is the whole content of the finding.
    try testing.expect(finite.vy < reference.vy);
}

test "solver to gameplay publishes the solver state into the ECS before the flip" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    const s = try restingScene(gpa, &ecs, &pw);
    try declare(gpa, &ecs, s.box_entity, .solver);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    // SLEEP IT, AND LEAVE IT ASLEEP FOR MANY TICKS. An awake body publishes every tick,
    // so its ECS pose is never more than the current one and the two implementations
    // agree — this test would separate nothing. A SLEEPER is skipped by `syncOut`
    // entirely, so nothing refreshes its `Transform` for as long as it sleeps.
    var i: usize = 0;
    while (i < 120) : (i += 1) _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expect(pw.bm.isSleeping(s.box).?);
    try testing.expect(ecs.get(api.Sleeping, s.box_entity) != null);

    // MOVE THE SOLVER BODY THROUGH THE PHYSICS API — `setBodyTransform`, a frozen entry
    // of §1 and the path a level script takes. The ECS `Transform` is NOT mirrored by
    // it, and `syncOut` has not run since, so from here the ECS holds the pose of the
    // last published tick and the solver holds another. That divergence is the whole
    // premise, so it is ASSERTED and not assumed.
    const before = sync.solverPose(&pw, s.box).?;
    const moved_x: f32 = 3.0;
    pw.setBodyTransform(s.box, vr(moved_x, before.pos[1], 0), pw.bm.rotation(s.box).?);
    const stale = ecs.get(Transform, s.box_entity).?.pos;
    try testing.expect(@abs(stale[0] - moved_x) > 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0), stale[0], 1e-3);

    // NOW FLIP, in the same tick and with no other gameplay write.
    ecs.getMut(RigidBody, s.box_entity).?.authority = .gameplay;
    const r = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    // THE PHYSICAL CLAIM FIRST, so a counter-factual reddens this test on the BODY and
    // not on a counter. THE BODY DID NOT JUMP BACKWARD: under the seed-from-the-ECS rule
    // this pass used to apply, the stale `Transform` at x = 0 was pushed into the solver
    // and the body teleported back three metres — permanently, since a `.gameplay` body
    // is never published again and nothing would ever correct it.
    const after = sync.solverPose(&pw, s.box).?;
    try testing.expectApproxEqAbs(moved_x, after.pos[0], 1e-3);

    // And the ECS now agrees with the solver, which is the control base gameplay is
    // entitled to start from.
    try testing.expectApproxEqAbs(moved_x, ecs.get(Transform, s.box_entity).?.pos[0], 1e-3);

    // The counters CORROBORATE: the transition was seen, and it SEEDED rather than
    // consumed — the pass published the solver's state into the ECS and pushed nothing
    // back. They are asserted after the pose deliberately; a pass could in principle
    // reach the right pose by another route, and the direction of the tick is what the
    // normative text names.
    try testing.expectEqual(@as(u32, 1), r.transitions);
    try testing.expectEqual(@as(u32, 1), r.seeded);
    try testing.expectEqual(@as(u32, 0), r.poses_applied);
}

test "the gameplay authority flag reaches every body of the entity, not only the elected one" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    // Two bodies on ONE entity — the shape §1.13.1 makes normal. Exactly one of them is
    // elected to carry the pose; the mass regime is not the election's business, and an
    // entity answering with two different regimes depending on which collider a contact
    // touched is the "two sources, one fact" defect this seam refuses elsewhere.
    const first = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 5, 0 });
    const second = try addTriggerBody(gpa, &pw, first.entity, .{ 0, 5, 0 });
    try declare(gpa, &ecs, first.entity, .gameplay);

    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    try testing.expect(pw.bm.hasGameplayAuthority(first.body).?);
    try testing.expect(pw.bm.hasGameplayAuthority(second).?);

    // And it is a MIRROR, so it follows the declaration back down rather than latching.
    ecs.getMut(RigidBody, first.entity).?.authority = .solver;
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expect(!pw.bm.hasGameplayAuthority(first.body).?);
    try testing.expect(!pw.bm.hasGameplayAuthority(second).?);
}

// ---------------------------------------------------------------------------
// M1.1.15.2 G12 — the consumption predicate: F1 and F2, which are one predicate.
//
// They are in one gate because they COUPLE: admitting statics advances their
// `consumed_tick`, which moves the baseline the diagnostic detects against, and
// closing the diagnostic's null-baseline trap advances every `.solver` baseline,
// which changes what admitting statics observes. Fixed apart, each reopens the
// other.
// ---------------------------------------------------------------------------

test "a static under solver authority takes its pose, and a QUERY sees it move" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer pw.deinit(gpa);

    // A STATIC under the DEFAULT authority, which is the whole point of F2: `.solver`
    // is the default for every body type, so the excluded case was not an exotic
    // corner — it was every static in every scene.
    const wall = try spawnLinked(gpa, &ecs, &pw, .static, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs, wall.entity, .solver);
    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    // Settle, so the first pass establishes a baseline and the move below is a real
    // change rather than the first observation.
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    // TWO rays: one along x = 6, where the wall is NOT, and one along x = 0, where it
    // is. The pair is what makes the observation below a movement rather than a hit.
    const probe: forge_3d.query.RayQuery = .{
        .origin = vr(6, 0, -10),
        .direction = vr(0, 0, 1),
        .max_distance = 100,
    };
    const here: forge_3d.query.RayQuery = .{
        .origin = vr(0, 0, -10),
        .direction = vr(0, 0, 1),
        .max_distance = 100,
    };
    try testing.expect(!forge_3d.query.raycastAny(&pw.bp, &pw.bm, &pw.store, probe));
    try testing.expect(forge_3d.query.raycastAny(&pw.bp, &pw.bm, &pw.store, here));

    // GAMEPLAY MOVES THE STATIC through the ECS, which is the authored path the matrix
    // declares: `static | l'un ou l'autre | pose seule, sur changement`.
    ecs.beginFrame();
    ecs.getMut(Transform, wall.entity).?.pos[0] = 6;
    const r = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), r.poses_applied);
    // A static has no velocity columns the solver would read, so nothing else moved.
    try testing.expectEqual(@as(u32, 0), r.velocities_applied);

    // **OBSERVED BY A QUERY AND NOT BY RE-READING THE COMPONENT**, which is the only
    // oracle that separates the two implementations: re-reading `Transform` returns the
    // value the test just wrote, so it would pass with the body and its broadphase
    // proxy still at the origin. The query goes through the proxy.
    try testing.expect(forge_3d.query.raycastAny(&pw.bp, &pw.bm, &pw.store, probe));
    try testing.expect(!forge_3d.query.raycastAny(&pw.bp, &pw.bm, &pw.store, here));

    // AND IT IS NOT A FORBIDDEN MUTATION. The matrix consumes a static's pose under
    // EITHER authority, so the authored path must not also be reported as a defect —
    // the two halves of this gate meet here rather than in two files.
    try testing.expectEqual(@as(u32, 0), r.forbidden_mutations);
}

test "an ECS write under solver authority is reported, and a non-write is not" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    const body = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try declare(gpa, &ecs, body.entity, .solver);
    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);

    // **THE TRAP, and the scene that reaches it is not the ordinary one.** A body whose
    // ECS `Transform` already agrees with its solver pose is silenced by the VALUE
    // predicate on the first pass, guard or no guard — measured: removing the
    // null-baseline guard left the whole tree green. What reaches the trap is a body
    // whose ECS and solver DISAGREE before anything has been published, which
    // `addBody` allows outright since the descriptor's position is independent of the
    // entity's `Transform`. `syncIn` runs before `step` and before `syncOut`, so the
    // very first pass of a scene sees that disagreement — and it is not a mutation, it
    // is a state that has never been reconciled.
    const unpublished = try ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const far_shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    _ = try pw.addBody(gpa, .{
        .entity = unpublished,
        .body_type = .dynamic,
        .shape = far_shape,
        .position = av3(50, 0, 0),
        .mass = 1,
    });
    try declare(gpa, &ecs, unpublished, .solver);

    // **THE TRAP FIRST, because it is what a naive detection fails.** With no baseline
    // `changedSince` returns true unconditionally, so a detection that reported on the
    // tick alone would fire here — on a body nobody has written, on the first pass,
    // and on every `.solver` body in every scene. A change is not reportable against an
    // absent baseline.
    const first = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), first.forbidden_mutations);
    try testing.expect(first.first_forbidden == null);

    // A NON-WRITE. The tick advances, the pass runs, nothing wrote the component.
    const quiet = try frameWithSyncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 0), quiet.forbidden_mutations);

    // A WRITE. Under `.solver` the solver owns the pose and republishes it, so this
    // goes nowhere and is exactly the state the owner declares forbidden.
    ecs.beginFrame();
    ecs.getMut(Transform, body.entity).?.pos[0] = 3;
    const caught = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), caught.forbidden_mutations);
    try testing.expectEqual(body.body, caught.first_forbidden.?);
    // AND IT IS A DIAGNOSTIC AND NOT AN APPLICATION: the pass reports and consumes
    // nothing, so the solver keeps the pose it owns.
    try testing.expectEqual(@as(u32, 0), caught.poses_applied);
    try testing.expectApproxEqAbs(@as(f32, 0), sync.solverPose(&pw, body.body).?.pos[0], 1e-6);

    // THE VELOCITY HALF, which a pose-only detection would miss: `syncOut` republishes
    // both for a dynamic body, so both are the solver's.
    ecs.beginFrame();
    ecs.getMut(Velocity, body.entity).?.linear[1] = 9;
    const vel = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), vel.forbidden_mutations);

    // A `getMut` THAT CHANGES NOTHING IS NOT REPORTED — the second predicate, and the
    // reason it exists: `getMut` marks unconditionally, so the tick alone would report
    // every system that took a handle and wrote the value back unchanged.
    //
    // **TWO BODIES IN ONE TICK, because that is the only shape that separates the two
    // predicates.** Both are stamped; one agrees with the solver and one does not. A
    // sequence of single-body ticks cannot do it — the first version of this case tried,
    // and measured `expected 0, found 1`, because the body it used was still carrying an
    // earlier reported-and-unapplied write.
    //
    // That failure taught the lifetime of a divergence, which is worth stating since it
    // is NOT what the first correction assumed: it does not persist. `syncOut` publishes
    // a dynamic `.solver` body's pose and velocity at the END of the same tick, so a
    // forbidden write is reported once and then overwritten by the publication. It
    // lingers only in a test that calls `syncIn` without a frame around it — which is
    // exactly what the steps above do, deliberately, to keep the solver state readable.
    const clean = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 20, 0, 0 });
    try declare(gpa, &ecs, clean.entity, .solver);
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    ecs.beginFrame();
    const c = ecs.get(Transform, clean.entity).?;
    ecs.getMut(Transform, clean.entity).?.pos = c.pos; // stamped, identical
    ecs.getMut(Transform, body.entity).?.pos[0] = 12; // stamped, different
    const both = try sync_in.syncIn(gpa, &pw, &ecs, &journal);
    try testing.expectEqual(@as(u32, 1), both.forbidden_mutations);
    try testing.expectEqual(body.body, both.first_forbidden.?);
}

test "the diagnostic fires under solver authority and under no other" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.initNoSleep(vr(0, 0, 0), fixed_dt);
    defer pw.deinit(gpa);

    // THREE BODIES, identical but for what the diagnostic is supposed to key on. Each
    // gets the SAME ECS write, so the only thing that can separate the answers is the
    // rule under test — a scene where only one body is written would pass under a
    // detection that reports everything it looks at.
    const solver_side = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    const gameplay_side = try spawnLinked(gpa, &ecs, &pw, .dynamic, .{ 0.5, 0.5, 0.5 }, .{ 5, 0, 0 });
    const static_side = try spawnLinked(gpa, &ecs, &pw, .static, .{ 0.5, 0.5, 0.5 }, .{ 10, 0, 0 });
    try declare(gpa, &ecs, solver_side.entity, .solver);
    try declare(gpa, &ecs, gameplay_side.entity, .gameplay);
    try declare(gpa, &ecs, static_side.entity, .solver);
    var journal: sync_in.Journal = .{};
    defer journal.deinit(gpa);
    _ = try frameWithSyncIn(gpa, &pw, &ecs, &journal);

    ecs.beginFrame();
    ecs.getMut(Transform, solver_side.entity).?.pos[2] = 1;
    ecs.getMut(Transform, gameplay_side.entity).?.pos[2] = 1;
    ecs.getMut(Transform, static_side.entity).?.pos[2] = 1;
    const r = try sync_in.syncIn(gpa, &pw, &ecs, &journal);

    // EXACTLY ONE of the three. The `.gameplay` write is the authored path and the
    // static's is too, since the matrix consumes a static's pose under either
    // authority — so a count of three would mean the rule keys on the write, a count
    // of two would mean it keys on the authority alone and forgot F2, and a count of
    // zero would mean it keys on nothing.
    try testing.expectEqual(@as(u32, 1), r.forbidden_mutations);
    try testing.expectEqual(solver_side.body, r.first_forbidden.?);
    // The two authored writes really were applied, so their silence is a decision and
    // not an oversight — a body the pass never reached would be silent too.
    try testing.expectEqual(@as(u32, 2), r.poses_applied);
}
