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
