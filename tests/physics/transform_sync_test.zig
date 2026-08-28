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
