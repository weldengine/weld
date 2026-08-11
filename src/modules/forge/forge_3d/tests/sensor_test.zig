//! Acceptance suite for the sensor traversal (M1.1.13).
//!
//! Gate D covers the traversal alone: trigger-proxy enumeration, the unilateral mask, the
//! exact narrowphase confirmation, the probe rule and the domain bound. It produces a set
//! of BODY-level overlaps; the entity mapping and the two deltas are the gate above.
//!
//! Half of this milestone's claims are NEGATIVE, so every negative case ships with the
//! positive control that proves the apparatus can observe the thing being denied.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const sensor = @import("../pipeline/sensor.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");
const harness = @import("solver_test.zig");
const Layer = @import("../pipeline/broadphase.zig").BroadphaseLayer;

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyManager = bm_mod.BodyManager;
const math = foundation.math;
const ApiVec3 = math.Vec3;
const testing = std.testing;

fn ent(index: u32) api.EntityId {
    return .{ .index = index, .generation = 0 };
}

fn av(x: f32, y: f32, z: f32) ApiVec3 {
    return ApiVec3.fromArray(.{ x, y, z });
}

/// A box body at `centre`, optionally a trigger, on object layer `layer`.
fn addBox(
    gpa: std.mem.Allocator,
    world: *harness.World,
    half: ApiVec3,
    centre: ApiVec3,
    entity_index: u32,
    is_trigger: bool,
    layer: u8,
) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = half } });
    return world.addBody(gpa, .{
        .entity = ent(entity_index),
        .body_type = .static,
        .shape = shape,
        .position = centre,
        .is_trigger = is_trigger,
        .collision_layer = layer,
    });
}

/// The overlaps of the whole world, rebuilt from scratch.
fn collect(gpa: std.mem.Allocator, world: *harness.World, out: *std.ArrayListUnmanaged(sensor.BodyOverlap)) !void {
    try sensor.collectOverlaps(gpa, &world.bp, &world.bm, &world.store, out);
}

fn hasOverlap(items: []const sensor.BodyOverlap, trigger: api.BodyId, other: api.BodyId) bool {
    for (items) |o| {
        if (o.trigger == trigger and o.other == other) return true;
    }
    return false;
}

test "a trigger detects an overlapping body and not a separated one" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // A unit trigger box at the origin. The near body overlaps it; the far one is 10 m away
    // and cannot, so the pass is not simply reporting every candidate it visits.
    const trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
    const near = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0.5, 0.5), 2, false, 0);
    const far = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(10, 0, 0), 3, false, 0);

    try collect(gpa, &world, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(hasOverlap(out.items, trigger, near));
    try testing.expect(!hasOverlap(out.items, trigger, far));

    // ORIENTED from the trigger: the reverse direction is not in the set, and a solid body
    // never detects anything of its own.
    try testing.expect(!hasOverlap(out.items, near, trigger));
}

test "a body overlapping no trigger produces nothing at all" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // Two SOLID bodies interpenetrating: no trigger in the scene, so no membership. The
    // positive control is the test above, on the same geometry with the role set.
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, false, 0);
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0.5, 0, 0), 2, false, 0);

    try collect(gpa, &world, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the mask filters the candidate's object layer, and it is unilateral" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // One trigger seeing layer 3 ONLY, and two overlapping candidates that differ in
    // nothing but their object layer — same shape, same pose.
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(1, 1, 1) } });
    const trigger = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .static,
        .shape = shape,
        .position = av(0, 0, 0),
        .is_trigger = true,
        .trigger_layer_mask = 1 << 3,
    });
    const seen = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0, 0), 2, false, 3);
    const unseen = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0, 0), 3, false, 4);

    try collect(gpa, &world, &out);
    try testing.expect(hasOverlap(out.items, trigger, seen)); // POSITIVE CONTROL
    try testing.expect(!hasOverlap(out.items, trigger, unseen));
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "two triggers with asymmetric masks see each other asymmetrically" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // A on layer 1 sees layer 2; B on layer 2 sees layer 5, which is nobody. They overlap.
    // The mask belongs to the TRIGGER and describes what IT sees, so the relation is not
    // symmetric — A sees B and B does not see A (§1.13.5).
    const sa = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(1, 1, 1) } });
    const sb = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(1, 1, 1) } });
    const a = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .static,
        .shape = sa,
        .position = av(0, 0, 0),
        .is_trigger = true,
        .collision_layer = 1,
        .trigger_layer_mask = 1 << 2,
    });
    const b = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .static,
        .shape = sb,
        .position = av(0.5, 0, 0),
        .is_trigger = true,
        .collision_layer = 2,
        .trigger_layer_mask = 1 << 5,
    });

    try collect(gpa, &world, &out);
    try testing.expect(hasOverlap(out.items, a, b));
    try testing.expect(!hasOverlap(out.items, b, a));
    // A trigger detecting another trigger is legal and produces no contact of any kind:
    // detection and physical response are two axes (§1.13.2).
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "membership is decided by the exact shapes and never by the AABB" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // A unit SPHERE trigger at the origin, and a small box parked near the corner of the
    // sphere's world box. The two AABBs overlap; the exact shapes do not.
    //
    // Closed form. The box spans [0.95, 1.15] on each axis, so its nearest point to the
    // origin is its own corner (0.95, 0.95, 0.95), at distance 0.95·√3 = 1.6454 > 1. And
    // the sphere's world AABB is [−1, 1]³, which meets the box's range on every axis, so
    // the AABB test says yes and the exact test says no. Without this case the suite
    // cannot tell an exact traversal from an AABB one.
    const sphere = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const trigger = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .static,
        .shape = sphere,
        .position = av(0, 0, 0),
        .is_trigger = true,
    });
    const corner = try addBox(gpa, &world, av(0.1, 0.1, 0.1), av(1.05, 1.05, 1.05), 2, false, 0);

    try collect(gpa, &world, &out);
    try testing.expect(!hasOverlap(out.items, trigger, corner));

    // POSITIVE CONTROL on the SAME trigger: a body genuinely inside it is detected, so the
    // refusal above is the exact kernel and not a traversal that reaches nothing.
    const inside = try addBox(gpa, &world, av(0.1, 0.1, 0.1), av(0.2, 0, 0), 3, false, 0);
    try collect(gpa, &world, &out);
    try testing.expect(hasOverlap(out.items, trigger, inside));
    try testing.expect(!hasOverlap(out.items, trigger, corner));
}

test "a trigger detects across every broad class" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // The pass consults NO pair matrix — after gate B the whole `trigger` row and column
    // read `false`, so a pass that consulted it would return nothing at all. A trigger
    // detects a static body, a moving one and another trigger alike (§1.13.2).
    const st = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, false, 0);
    const shape_k = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(1, 1, 1) } });
    const kin = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .kinematic,
        .shape = shape_k,
        .position = av(0.5, 0, 0),
    });
    const other_trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, 0.5, 0), 3, true, 0);
    const trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0.5), 4, true, 0);

    try collect(gpa, &world, &out);
    try testing.expect(hasOverlap(out.items, trigger, st));
    try testing.expect(hasOverlap(out.items, trigger, kin));
    try testing.expect(hasOverlap(out.items, trigger, other_trigger));
    // And the broad classes really are the three the rule produces, so "across every class"
    // is a statement about the scene and not only about the answer.
    try testing.expectEqual(Layer.static, world.bm.broadLayer(st).?);
    try testing.expectEqual(Layer.dynamic, world.bm.broadLayer(kin).?);
    try testing.expectEqual(Layer.trigger, world.bm.broadLayer(other_trigger).?);
}

/// A flat quad at height `y`, spanning [-5, 5] on x and z, wound so its normal is +Y.
fn addMeshFloor(gpa: std.mem.Allocator, world: *harness.World, y: f32, entity_index: u32) !api.BodyId {
    const V = @typeInfo(@FieldType(@FieldType(api.ShapeDescriptor, "triangle_mesh"), "vertices")).pointer.child;
    const verts = [_]V{
        .{ .data = .{ -5, y, -5 } }, .{ .data = .{ 5, y, -5 } },
        .{ .data = .{ -5, y, 5 } },  .{ .data = .{ 5, y, 5 } },
    };
    const tris = [_]u32{ 0, 2, 1, 1, 2, 3 };
    const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &tris } });
    return world.addBody(gpa, .{
        .entity = ent(entity_index),
        .body_type = .static,
        .shape = shape,
        .position = av(0, 0, 0),
    });
}

/// A half-space trigger for the solid `{y <= 0}`.
fn addHalfSpaceTrigger(gpa: std.mem.Allocator, world: *harness.World, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .plane = .{ .normal = av(0, 1, 0), .distance = 0 } });
    return world.addBody(gpa, .{
        .entity = ent(entity_index),
        .body_type = .static,
        .shape = shape,
        .position = av(0, 0, 0),
        .is_trigger = true,
    });
}

test "the probe rule serves both configurations in which it decides the answer" {
    const gpa = testing.allocator;
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // The exact predicate takes a CONVEX probe and a body of any class, so the rule picks
    // the trigger when the trigger is convex and the candidate otherwise (§1.13.6). These
    // are the two configurations where the choice DECIDES the answer rather than merely the
    // arithmetic: pick the wrong side in either and the probe is inadmissible, so the pass
    // produces nothing at all.

    // (a) CONVEX trigger x MESH candidate — the probe must be the TRIGGER, a triangle soup
    // having no support map. The mesh quad sits at y = 0 and the trigger box spans
    // y in [-1, 1], so they genuinely meet.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
        const floor = try addMeshFloor(gpa, &world, 0, 2);
        try collect(gpa, &world, &out);
        try testing.expect(hasOverlap(out.items, trigger, floor));
    }

    // (b) HALF-SPACE trigger x CONVEX candidate — the probe must be the CANDIDATE, a
    // half-space having an unbounded support map. The box spans y in [-1, 1] and the solid
    // is {y <= 0}, so they meet.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addHalfSpaceTrigger(gpa, &world, 1);
        const box = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 2, false, 0);
        try collect(gpa, &world, &out);
        try testing.expect(hasOverlap(out.items, trigger, box));
    }

    // The THIRD configuration — both sides convex — is fixed to the TRIGGER by the rule, and
    // it is deliberately not asserted here: the overlap boolean is symmetric in exact
    // arithmetic, so no observable of this pass distinguishes the two orders. What the rule
    // buys there is that the order is STATED rather than left to whichever side happened to
    // be usable, so M1.1.14 can verify it instead of establishing it.
}

test "a pair of static-only shapes is out of the detection domain" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // A WRITTEN BOUND, not a tolerated gap (§1.13.6). Neither a half-space nor a triangle
    // soup can be a probe, so this pair has no exact predicate in either direction. It
    // produces no membership — and the motive is that the combination carries nothing:
    // `addBody` forces `.static` on both classes, so the overlap cannot vary under
    // simulation and would yield one entry on the first tick and never a transition again.
    //
    // GEOMETRY SAYS YES HERE, which is what makes the case discriminating: the quad sits at
    // y = -0.5, entirely inside the solid {y <= 0}, so the two shapes really do intersect
    // and it is the bound alone that refuses them.
    const trigger = try addHalfSpaceTrigger(gpa, &world, 1);
    const floor = try addMeshFloor(gpa, &world, -0.5, 2);

    try collect(gpa, &world, &out);
    try testing.expect(!hasOverlap(out.items, trigger, floor));
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // POSITIVE CONTROL, on the SAME trigger rather than a fresh one: a convex body in the
    // same solid IS detected. Without it the assertion above is satisfied by a traversal
    // that reaches nothing at all — a half-space trigger visiting no tree would look
    // identical.
    const box = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 3, false, 0);
    try collect(gpa, &world, &out);
    try testing.expect(hasOverlap(out.items, trigger, box));
    try testing.expect(!hasOverlap(out.items, trigger, floor));
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // And the mesh really was a CANDIDATE the traversal reached: the same mesh, against a
    // CONVEX trigger, is detected. So the refusal above is the domain bound and not a
    // traversal that never met the body.
    const convex_trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, -0.5, 0), 4, true, 0);
    try collect(gpa, &world, &out);
    try testing.expect(hasOverlap(out.items, convex_trigger, floor));
}

// ---------------------------------------------------------------------------
// M1.1.13 / gate E — the observable state and its two deltas
// ---------------------------------------------------------------------------

fn hasPair(items: []const sensor.EntityPair, trigger: u32, other: u32) bool {
    for (items) |p| {
        if (p.trigger.index == trigger and p.other.index == other) return true;
    }
    return false;
}

/// Move a body and refresh its broadphase proxy — what step 10 does for one body.
fn moveTo(gpa: std.mem.Allocator, world: *harness.World, id: api.BodyId, p: [3]Real) !void {
    world.bm.setPosition(id, Vec3r.fromArray(p));
    for (world.bodies.items) |b| {
        if (b.id != id) continue;
        try world.bp.update(gpa, b.proxy, world.bm.bodyAabb(&world.store, id).?);
    }
}

test "one enter, no delta while maintained, one exit" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var state: sensor.SensorState = .{};
    defer state.deinit(gpa);

    // A unit trigger at the origin; the body starts 10 m away, walks in, stays, walks out.
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
    const body = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(10, 0, 0), 2, false, 0);

    // OUTSIDE: no state, no delta.
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 0), state.current.items.len);
    try testing.expectEqual(@as(usize, 0), state.entered.items.len);
    try testing.expectEqual(@as(usize, 0), state.exited.items.len);

    // ENTER: exactly one, and the state holds exactly one pair.
    try moveTo(gpa, &world, body, .{ 0.5, 0, 0 });
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 1), state.entered.items.len);
    try testing.expectEqual(@as(usize, 0), state.exited.items.len);
    try testing.expect(hasPair(state.current.items, 1, 2));

    // MAINTAINED: the deltas are asserted EMPTY over three ticks, not skipped. There is no
    // third list, and "no delta while maintained" is exactly what its absence means
    // (§1.13.12) — a `TriggerStay` would show up here as a non-empty `entered` every tick.
    for (0..3) |_| {
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 0), state.entered.items.len);
        try testing.expectEqual(@as(usize, 0), state.exited.items.len);
        try testing.expectEqual(@as(usize, 1), state.current.items.len);
    }

    // EXIT: exactly one, and the state is empty again.
    try moveTo(gpa, &world, body, .{ 10, 0, 0 });
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 0), state.entered.items.len);
    try testing.expectEqual(@as(usize, 1), state.exited.items.len);
    try testing.expect(hasPair(state.exited.items, 1, 2));
    try testing.expectEqual(@as(usize, 0), state.current.items.len);

    // And it stays exited: the delta is produced once, not every tick.
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 0), state.exited.items.len);
}

test "two bodies of one entity aggregate to a single pair" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var state: sensor.SensorState = .{};
    defer state.deinit(gpa);

    _ = try addBox(gpa, &world, av(2, 2, 2), av(0, 0, 0), 1, true, 0);
    // TWO bodies, ONE entity (index 2). Both overlap the trigger.
    const first = try addBox(gpa, &world, av(0.3, 0.3, 0.3), av(0.5, 0, 0), 2, false, 0);
    const second = try addBox(gpa, &world, av(0.3, 0.3, 0.3), av(-0.5, 0, 0), 2, false, 0);

    // The traversal really does see TWO body overlaps — without this the aggregation below
    // would be indistinguishable from a scene that only ever had one.
    try sensor.collectOverlaps(gpa, &world.bp, &world.bm, &world.store, &state.overlaps);
    try testing.expectEqual(@as(usize, 2), state.overlaps.items.len);

    // ONE enter, one pair.
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 1), state.entered.items.len);
    try testing.expectEqual(@as(usize, 1), state.current.items.len);

    // Removing ONE of the two produces NO exit: the pair survives while the last overlap
    // does (§1.13.8 rule 1).
    world.removeBody(first);
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 0), state.exited.items.len);
    try testing.expectEqual(@as(usize, 1), state.current.items.len);

    // Removing the LAST one produces exactly one exit.
    world.removeBody(second);
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 1), state.exited.items.len);
    try testing.expectEqual(@as(usize, 0), state.current.items.len);
}

test "an entity carrying both a trigger and a solid body detects nothing" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var state: sensor.SensorState = .{};
    defer state.deinit(gpa);

    // ONE entity (index 1) carrying a trigger body and a solid body that overlap.
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0.5, 0, 0), 1, false, 0);

    // The BODY-level traversal reports the overlap — the two bodies are distinct, so the
    // self-match exclusion does not apply. It is the ENTITY mapping that drops it.
    try sensor.collectOverlaps(gpa, &world.bp, &world.bm, &world.store, &state.overlaps);
    try testing.expectEqual(@as(usize, 1), state.overlaps.items.len);

    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 0), state.current.items.len);
    try testing.expectEqual(@as(usize, 0), state.entered.items.len);

    // POSITIVE CONTROL: the same solid body under a DIFFERENT entity is detected, so the
    // suppression above is the reflexive rule and not a scene that overlaps nothing.
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0.5, 0, 0), 2, false, 0);
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 1), state.current.items.len);
    try testing.expect(hasPair(state.current.items, 1, 2));
}

test "two mutually detecting triggers produce two pairs, one per direction" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var state: sensor.SensorState = .{};
    defer state.deinit(gpa);

    _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
    _ = try addBox(gpa, &world, av(1, 1, 1), av(0.5, 0, 0), 2, true, 0);

    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expectEqual(@as(usize, 2), state.current.items.len);
    try testing.expect(hasPair(state.current.items, 1, 2));
    try testing.expect(hasPair(state.current.items, 2, 1));
    // Both are ENTERS this tick, so the orientation is carried by the deltas too.
    try testing.expectEqual(@as(usize, 2), state.entered.items.len);
}

/// Clear the sensor role on a live body AND move its proxy to the class the role change
/// implies — the two halves the caller owes together (`BodyManager.setTrigger`).
fn clearTriggerRole(gpa: std.mem.Allocator, world: *harness.World, id: api.BodyId) !void {
    world.bm.setTrigger(id, false);
    const layer = BodyManager.broadLayerFor(false, world.bm.bodyType(id).?);
    for (world.bodies.items) |*b| {
        if (b.id != id) continue;
        world.bp.remove(b.proxy);
        b.proxy = try world.bp.insert(gpa, layer, world.bm.bodyAabb(&world.store, id).?, id);
    }
}

test "falling asleep inside a trigger never produces an exit" {
    const gpa = testing.allocator;
    // Sleeping ENABLED, gravity zero: a dynamic body at rest forms a singleton island and
    // becomes eligible after `time_before_sleep` (0.5 s = 30 ticks at 60 Hz).
    var world = harness.World.init(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    world.sensors_on = true;

    _ = try addBox(gpa, &world, av(2, 2, 2), av(0, 0, 0), 1, true, 0);
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(0.3, 0.3, 0.3) } });
    const body = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .dynamic,
        .shape = shape,
        .position = av(0, 0, 0),
    });

    try world.step(gpa);
    try testing.expectEqual(@as(usize, 1), world.sensors.entered.items.len);
    try testing.expect(hasPair(world.sensors.current.items, 1, 2));

    // Run well past the sleep window. THE INVARIANT: the body falls asleep inside the
    // trigger and NO exit is ever produced — not on the sleeping tick, not on any tick
    // after. The pass reads no sleep state on either side, which is what forbids the
    // phantom exit structurally rather than by a special case (§1.13.9).
    var slept_at: ?usize = null;
    for (0..60) |i| {
        try world.step(gpa);
        try testing.expectEqual(@as(usize, 0), world.sensors.exited.items.len);
        try testing.expectEqual(@as(usize, 1), world.sensors.current.items.len);
        if (slept_at == null and world.bm.isSleeping(body).?) slept_at = i;
    }

    // NON-VACUITY: the body really did fall asleep, so the ticks above are the case the
    // invariant is about and not a body that stayed awake throughout.
    try testing.expect(slept_at != null);
    try testing.expectEqual(true, world.bm.isSleeping(body).?);

    // POSITIVE CONTROL: woken and moved out, the same scene DOES produce an exit — so the
    // apparatus can observe the thing the invariant denies.
    world.bm.wakeBody(body);
    try moveTo(gpa, &world, body, .{ 20, 0, 0 });
    try world.step(gpa);
    try testing.expectEqual(@as(usize, 1), world.sensors.exited.items.len);
    try testing.expect(hasPair(world.sensors.exited.items, 1, 2));
}

test "a sleeping trigger still detects an arriving body" {
    const gpa = testing.allocator;
    var world = harness.World.init(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    world.sensors_on = true;

    // A DYNAMIC trigger, so it can actually fall asleep — a static body never carries the
    // sleeping flag at all, and asserting on it would prove nothing.
    const tshape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(2, 2, 2) } });
    const trigger = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .dynamic,
        .shape = tshape,
        .position = av(0, 0, 0),
        .is_trigger = true,
    });
    const body = try addBox(gpa, &world, av(0.3, 0.3, 0.3), av(20, 0, 0), 2, false, 0);

    for (0..60) |_| try world.step(gpa);
    try testing.expectEqual(true, world.bm.isSleeping(trigger).?);
    try testing.expectEqual(@as(usize, 0), world.sensors.current.items.len);

    // The trigger is asleep and the body walks in: detection is unchanged. The pass is
    // filtered by no sleep state on EITHER side, and this is the trigger's side.
    try moveTo(gpa, &world, body, .{ 0.5, 0, 0 });
    try world.step(gpa);
    try testing.expectEqual(true, world.bm.isSleeping(trigger).?); // still asleep
    try testing.expectEqual(@as(usize, 1), world.sensors.entered.items.len);
    try testing.expect(hasPair(world.sensors.current.items, 1, 2));
}

test "a detection wakes nobody" {
    const gpa = testing.allocator;
    var world = harness.World.init(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    world.sensors_on = true;

    const tshape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(2, 2, 2) } });
    _ = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .dynamic,
        .shape = tshape,
        .position = av(0, 0, 0),
        .is_trigger = true,
    });
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(0.3, 0.3, 0.3) } });
    const body = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .dynamic,
        .shape = shape,
        .position = av(0, 0, 0),
    });

    // Both asleep, and DETECTED — the state holds the pair while both ends sleep.
    for (0..60) |_| try world.step(gpa);
    try testing.expectEqual(true, world.bm.isSleeping(body).?);
    try testing.expect(hasPair(world.sensors.current.items, 1, 2));

    // Ten more ticks of continuous detection wake NOBODY: a detection is not a
    // solicitation under §1.8.4 and is not a fifth wake cause beside W1-W4 (§1.13.7).
    for (0..10) |_| {
        try world.step(gpa);
        try testing.expectEqual(true, world.bm.isSleeping(body).?);
    }

    // POSITIVE CONTROL: a real wake cause on the same scene DOES wake it — W1, an external
    // impulse, and not W4, whose harness producer is body removal, which would destroy the
    // very body under observation.
    world.bm.addImpulse(body, Vec3r.fromArray(.{ 1, 0, 0 }));
    try testing.expectEqual(false, world.bm.isSleeping(body).?);
}

test "every cause of disappearance produces exactly one exit" {
    const gpa = testing.allocator;

    // FOUR causes, §1.13.10, and none of them has a dedicated path in the pass: the full
    // rebuild covers them all, a body that is gone having no proxy left to visit. Each runs
    // in its own world so the counts are unambiguous, and each starts from a DETECTED state
    // asserted first — otherwise "one exit" could be measured against a pair that never
    // entered.

    // (a) the CANDIDATE is removed.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var state: sensor.SensorState = .{};
        defer state.deinit(gpa);
        _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
        const body = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0, 0), 2, false, 0);
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.current.items.len);
        world.removeBody(body);
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.exited.items.len);
        try testing.expect(hasPair(state.exited.items, 1, 2));
    }

    // (b) the TRIGGER is removed. Symmetric, and worth its own case: the pass is indexed by
    // triggers, so losing one removes an enumeration root rather than a candidate.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var state: sensor.SensorState = .{};
        defer state.deinit(gpa);
        const trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
        _ = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0, 0), 2, false, 0);
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.current.items.len);
        world.removeBody(trigger);
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.exited.items.len);
    }

    // (c) the candidate's SHAPE changes out of overlap. The body does not move at all: only
    // its geometry shrinks, which is a cause no position-based test would reach.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var state: sensor.SensorState = .{};
        defer state.deinit(gpa);
        _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
        // Spans [0.8, 2.8] on x, so it meets the trigger's [-1, 1]. Shrunk to half 0.5 it
        // spans [1.3, 2.3] and no longer does — the centre never moves.
        const body = try addBox(gpa, &world, av(1, 1, 1), av(1.8, 0, 0), 2, false, 0);
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.current.items.len);

        const small = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(0.5, 0.5, 0.5) } });
        world.bm.setShape(&world.store, body, small);
        for (world.bodies.items) |b| {
            if (b.id != body) continue;
            try world.bp.update(gpa, b.proxy, world.bm.bodyAabb(&world.store, body).?);
        }
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.exited.items.len);
        try testing.expectEqual(@as(usize, 0), state.current.items.len);
    }

    // (d) the SENSOR ROLE is cleared. The body stays exactly where it is and keeps its
    // shape: what disappears is the role. It does not become an inert trigger — it stops
    // being one, and its pairs exit (§1.13.10).
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var state: sensor.SensorState = .{};
        defer state.deinit(gpa);
        const trigger = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
        _ = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0, 0), 2, false, 0);
        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.current.items.len);

        try clearTriggerRole(gpa, &world, trigger);
        try testing.expectEqual(false, world.bm.isTrigger(trigger).?);
        try testing.expectEqual(Layer.static, world.bm.broadLayer(trigger).?);

        try state.update(gpa, &world.bp, &world.bm, &world.store);
        try testing.expectEqual(@as(usize, 1), state.exited.items.len);
        try testing.expectEqual(@as(usize, 0), state.current.items.len);
    }
}

test "the state and both deltas are sorted by the COMPLETE entity value" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var state: sensor.SensorState = .{};
    defer state.deinit(gpa);

    // Triggers and candidates created in an order that DISAGREES with the entity order, so
    // a state that followed creation order or traversal order would come out differently.
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(1, 1, 1) } });
    const mk = struct {
        fn body(g: std.mem.Allocator, w: *harness.World, s: api.ShapeId, e: api.EntityId, trig: bool) !api.BodyId {
            return w.addBody(g, .{
                .entity = e,
                .body_type = .static,
                .shape = s,
                .position = av(0, 0, 0),
                .is_trigger = trig,
            });
        }
    };
    // TWO ENTITIES SHARING AN INDEX ACROSS A GENERATION WRAP — index 7, generations 0 and 1
    // — which is the case §1.13.11 exists for: two successive occupants of one index must be
    // DISTINCT and ORDERED, and a key on the index alone would merge them.
    _ = try mk.body(gpa, &world, shape, .{ .index = 9, .generation = 0 }, true);
    _ = try mk.body(gpa, &world, shape, .{ .index = 7, .generation = 1 }, false);
    _ = try mk.body(gpa, &world, shape, .{ .index = 7, .generation = 0 }, false);
    _ = try mk.body(gpa, &world, shape, .{ .index = 2, .generation = 0 }, true);

    try state.update(gpa, &world.bp, &world.bm, &world.store);

    // Every body sits at the origin and overlaps every other, so both triggers see both
    // candidates AND each other: 2 triggers x 3 others = 6 pairs.
    try testing.expectEqual(@as(usize, 6), state.current.items.len);
    try testing.expectEqual(@as(usize, 6), state.entered.items.len);

    // The two index-7 entities are DISTINCT rows, not one merged row.
    var index7: usize = 0;
    for (state.current.items) |p| {
        if (p.other.index == 7) index7 += 1;
    }
    try testing.expectEqual(@as(usize, 4), index7); // two triggers x two generations

    // SORTED, strictly, on `(trigger, other)` with each compared on index THEN generation.
    // Written out here rather than reusing the production comparator, so the test is an
    // independent statement of the order and not a restatement of the implementation.
    for (state.current.items[1..], 0..) |p, i| {
        const q = state.current.items[i];
        const before = q.trigger.index < p.trigger.index or
            (q.trigger.index == p.trigger.index and q.trigger.generation < p.trigger.generation) or
            (q.trigger.index == p.trigger.index and q.trigger.generation == p.trigger.generation and
                (q.other.index < p.other.index or
                    (q.other.index == p.other.index and q.other.generation < p.other.generation)));
        try testing.expect(before);
    }
    // The first row is the smallest trigger index, which creation order would NOT have put
    // first — entity 2's trigger was created last.
    try testing.expectEqual(@as(u32, 2), state.current.items[0].trigger.index);
}

test "a recycled BodyId slot cannot resurrect a membership" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var state: sensor.SensorState = .{};
    defer state.deinit(gpa);

    _ = try addBox(gpa, &world, av(1, 1, 1), av(0, 0, 0), 1, true, 0);
    const inside = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(0.5, 0, 0), 2, false, 0);
    try state.update(gpa, &world.bp, &world.bm, &world.store);
    try testing.expect(hasPair(state.current.items, 1, 2));

    // Destroy the detected body and create another FAR AWAY. The slot allocator recycles
    // LIFO, so the new body takes the freed slot.
    world.removeBody(inside);
    const outside = try addBox(gpa, &world, av(0.5, 0.5, 0.5), av(20, 0, 0), 3, false, 0);

    // NON-VACUITY: the slot really was reused — same index, different generation. Without
    // this the test would pass on an allocator that never recycles, which is not the case
    // under test.
    try testing.expectEqual(
        api.PackedId.unpack(inside).index,
        api.PackedId.unpack(outside).index,
    );
    try testing.expect(api.PackedId.unpack(inside).generation != api.PackedId.unpack(outside).generation);

    try state.update(gpa, &world.bp, &world.bm, &world.store);
    // The exit for the destroyed body fires, and the new occupant of the slot is NOT
    // reported as inside — no handle appears in the state and no membership is carried, so
    // there is nothing for a reissued id to inherit (§1.13.8 rule 4).
    try testing.expectEqual(@as(usize, 1), state.exited.items.len);
    try testing.expect(hasPair(state.exited.items, 1, 2));
    try testing.expectEqual(@as(usize, 0), state.current.items.len);
    try testing.expect(!hasPair(state.current.items, 1, 3));
}
