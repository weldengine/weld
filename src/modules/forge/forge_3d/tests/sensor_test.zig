//! Acceptance suite for the sensor traversal (M1.1.13).
//!
//! Trigger-proxy enumeration, the unilateral mask, the exact narrowphase confirmation, the
//! probe rule and the creation-time refusal of the role on a mesh; then the observable state
//! and its two deltas.
//!
//! **No domain bound remains.** An earlier version carried one, excluding pairs whose two
//! sides both carried a static-only shape; it grouped half-space and mesh by BODY TYPE where
//! the question is whether the shape has an INTERIOR, and it is retracted (§1.13.6). A mesh
//! cannot be a trigger, a half-space can, and every reachable pair has an exact kernel.
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
const query = @import("../query/root.zig");
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

test "the sensor role is refused on a mesh, by typed error, and kept on a half-space" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // **A SENSOR NEEDS AN INTERIOR, and a triangle soup has none.** A `MeshShape` is a SURFACE
    // and not a solid — categorical, not a setting (§1.11.17) — so membership is false
    // everywhere on it and `pointQuery` never returns a body carrying one. A sensor answers
    // "who is inside"; a surface has no inside. The refusal is a DIAGNOSTIC and not a silent
    // answer, and it is named on the INVARIANT so the next surface-like class reuses it.
    const V = @typeInfo(@FieldType(@FieldType(api.ShapeDescriptor, "triangle_mesh"), "vertices")).pointer.child;
    const verts = [_]V{
        .{ .data = .{ -5, 0, -5 } }, .{ .data = .{ 5, 0, -5 } },
        .{ .data = .{ -5, 0, 5 } },  .{ .data = .{ 5, 0, 5 } },
    };
    const tris = [_]u32{ 0, 2, 1, 1, 2, 3 };
    const mesh = try world.store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &tris } });

    try testing.expectError(error.TriggerShapeMustBeSolid, world.bm.addBody(gpa, &world.store, .{
        .entity = ent(1),
        .body_type = .static,
        .shape = mesh,
        .position = av(0, 0, 0),
        .is_trigger = true,
    }));

    // POSITIVE CONTROL 1: the SAME mesh without the role is accepted, so the refusal is about
    // the role and not about the shape being unusable.
    _ = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .static,
        .shape = mesh,
        .position = av(0, 0, 0),
    });

    // POSITIVE CONTROL 2: a HALF-SPACE keeps the role. It IS a volume with a well-defined
    // interior — the kill plane under the level — and that is exactly the distinction, which a
    // test refusing both would have hidden.
    const plane = try addHalfSpaceTrigger(gpa, &world, 3);
    try testing.expectEqual(true, world.bm.isTrigger(plane).?);
}

test "a half-space trigger detects a mesh, one vertex on the solid side being enough" {
    const gpa = testing.allocator;
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // The kernel is exact rather than approximate, and by CONVEXITY: a triangle is the convex
    // hull of its vertices and a half-space is a convex set, so `n·x − d` attains its minimum
    // over the triangle at a VERTEX. No edge or interior point can be inside while all three
    // vertices are outside — which is why one vertex suffices and why stopping at the first is
    // not a shortcut.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addHalfSpaceTrigger(gpa, &world, 1); // solid {y <= 0}
        const floor = try addMeshFloor(gpa, &world, -0.5, 2); // entirely inside it
        try collect(gpa, &world, &out);
        try testing.expect(hasOverlap(out.items, trigger, floor));
    }

    // NEGATIVE, on the same trigger: a mesh entirely OUTSIDE the solid is not detected. Without
    // it the case above is satisfied by a kernel that answers `true` unconditionally.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addHalfSpaceTrigger(gpa, &world, 1);
        const above = try addMeshFloor(gpa, &world, 3, 2);
        try collect(gpa, &world, &out);
        try testing.expect(!hasOverlap(out.items, trigger, above));
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "two half-spaces meet unless their normals are opposite and their boundaries disjoint" {
    const gpa = testing.allocator;
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // The trigger's solid is `{y <= 0}`. A second half-space `{-y <= d}` is `{y >= -d}`, so the
    // two are disjoint exactly when `0 + d < 0`. Analytic, no iteration, and the antiparallel
    // test is at TRUE ZERO — two normals merely CLOSE to opposite still meet, in a wedge, so an
    // epsilon there would answer "no overlap" for a pair that genuinely overlaps.
    const cases = [_]struct { normal: [3]f32, distance: f32, expect: bool, why: []const u8 }{
        .{ .normal = .{ 0, -1, 0 }, .distance = -1, .expect = false, .why = "opposite, d = -1 < 0: disjoint" },
        .{ .normal = .{ 0, -1, 0 }, .distance = 1, .expect = true, .why = "opposite, d = 1 >= 0: they meet" },
        .{ .normal = .{ 0, -1, 0 }, .distance = 0, .expect = true, .why = "opposite, d = 0: boundaries touch" },
        .{ .normal = .{ 1, 0, 0 }, .distance = -50, .expect = true, .why = "not antiparallel: always meet" },
    };
    for (cases, 0..) |c, i| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addHalfSpaceTrigger(gpa, &world, 1);
        const shape = try world.store.createShape(gpa, .{ .plane = .{
            .normal = av(c.normal[0], c.normal[1], c.normal[2]),
            .distance = c.distance,
        } });
        const other = try world.addBody(gpa, .{
            .entity = ent(2 + @as(u32, @intCast(i))),
            .body_type = .static,
            .shape = shape,
            .position = av(0, 0, 0),
        });
        try collect(gpa, &world, &out);
        try testing.expectEqual(c.expect, hasOverlap(out.items, trigger, other));
        // A trigger never detects itself, whatever the direction of the walk — and the
        // unbounded list now offers it its own proxy back, so this is a live exclusion.
        try testing.expect(!hasOverlap(out.items, trigger, trigger));
    }
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
/// implies — the two halves the caller owes together (`BodyManager.clearTrigger`).
///
/// **THE PROXY MOVE DISPATCHES ON THE SHAPE TOO**, and a first version did not: it called
/// `bodyAabb` unconditionally, which ASSERTS on a half-space, so the helper worked for a box
/// trigger and crashed on the other shape the role admits. The same lesson as the owed wake
/// one line below — one recipe does not serve both shapes — met once in the wake and once in
/// the proxy move.
fn clearTriggerRole(gpa: std.mem.Allocator, world: *harness.World, id: api.BodyId) !void {
    world.bm.clearTrigger(id);
    const layer = BodyManager.broadLayerFor(false, world.bm.bodyType(id).?);
    const record = world.store.get(world.bm.shapeOf(id).?).?;
    for (world.bodies.items) |*b| {
        if (b.id != id) continue;
        world.bp.remove(b.proxy);
        b.proxy = switch (record.class()) {
            .convex, .triangle_soup => try world.bp.insert(
                gpa,
                layer,
                world.bm.bodyAabb(&world.store, id).?,
                id,
            ),
            .half_space => blk: {
                const w = shape_mod.halfSpace(record).transformed(
                    world.bm.rotation(id).?,
                    world.bm.position(id).?,
                );
                break :blk try world.bp.insertUnbounded(gpa, layer, .{
                    .normal = w.normal,
                    .distance = w.distance,
                }, id);
            },
        };
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

        // **THE REVERSE DIRECTION IS NOT IN THE SURFACE, and that is a refusal rather than an
        // omission.** Pinned as an ABSENCE, because that is the form the regression would
        // take: `clearTrigger` takes no value, and no entry sets the role on a live body.
        //
        // Clearing is safe because a body in the `trigger` class has NO retained pairs — the
        // whole row and column of the matrix are `false` — so it has nothing to purge.
        // SETTING would be unsound today: the retained candidate set is a correctness
        // condition of sleep and is never pruned, and `build` carries no revalidation of the
        // role, so a body flipped to `true` would keep producing constraints for the pairs it
        // had already accumulated while the sensor pass reported it as a trigger — a body
        // that both detects and responds, which §1.13.1 states does not exist.
        try testing.expect(!@hasDecl(BodyManager, "setTrigger"));
        try testing.expectEqual(
            @as(usize, 2),
            @typeInfo(@TypeOf(BodyManager.clearTrigger)).@"fn".params.len,
        );

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

test "clearing the role leaves an overlapping sleeper asleep until the caller composes" {
    const gpa = testing.allocator;
    // REAL sleep, not `initNoSleep`: the whole point is what happens to a body that is
    // ACTUALLY asleep, and a world that never sleeps cannot show it.
    var world = harness.World.init(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    world.sensors_on = true;

    // A trigger volume with a DYNAMIC body resting inside it. While the role is on, the pair
    // is detected and the body sleeps: a trigger reaches no constraint, so the body is a
    // singleton island and nothing keeps it awake.
    const tshape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(2, 2, 2) } });
    const trigger = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .static,
        .shape = tshape,
        .position = av(0, 0, 0),
        .is_trigger = true,
    });
    const bshape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(0.5, 0.5, 0.5) } });
    const sleeper = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .dynamic,
        .shape = bshape,
        .position = av(0, 0, 0),
    });

    for (0..60) |_| try world.step(gpa);
    try testing.expectEqual(true, world.bm.isSleeping(sleeper).?);
    try testing.expect(hasPair(world.sensors.current.items, 1, 2));

    // CLEAR THE ROLE. The volume becomes SOLID, and the sleeper is inside it.
    try clearTriggerRole(gpa, &world, trigger);
    try world.step(gpa);

    // The pair exits, which is the fourth disappearance cause and is already covered above.
    try testing.expect(hasPair(world.sensors.exited.items, 1, 2));

    // **AND THE SLEEPER IS STILL ASLEEP, STILL INTERPENETRATED.** This is the PRECONDITION the
    // entry documents, pinned rather than believed done: a sleeper emits nothing in
    // broadphase, and the retained candidate set never held a pair for a body that was in the
    // `trigger` class, so nothing in the cycle notices that a solid has appeared around it.
    // Ten more ticks change nothing.
    for (0..10) |_| {
        try world.step(gpa);
        try testing.expectEqual(true, world.bm.isSleeping(sleeper).?);
    }
    try testing.expect(world.bm.position(sleeper).?.approxEql(Vec3r.zero, 1e-6));

    // POSITIVE CONTROL — what the caller owes, performed: find the bodies overlapping the new
    // solid with a query, and wake them. This is the composition the doc-comment names, and
    // without it the assertion above is satisfied by a body that could never have woken.
    var found: [8]api.BodyId = undefined;
    const n = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = world.bm.shapeOf(trigger).?,
        .position = world.bm.position(trigger).?,
        .rotation = world.bm.rotation(trigger).?,
    }, &found);
    try testing.expect(n >= 1);
    var woke = false;
    for (found[0..n]) |id| {
        if (id == trigger) continue;
        world.bm.wakeBody(id);
        if (id == sleeper) woke = true;
    }
    try testing.expect(woke); // the query really did find the sleeper
    try testing.expectEqual(false, world.bm.isSleeping(sleeper).?);
}

/// A mesh whose single triangle sits at height `tri_y`, plus an UNREFERENCED vertex at
/// `orphan_y`. `MeshData` validates that every index is inside the vertex array and never the
/// converse, so an orphan is legal and an imported mesh may carry one.
fn addMeshWithOrphan(
    gpa: std.mem.Allocator,
    world: *harness.World,
    tri_y: f32,
    orphan_y: f32,
    entity_index: u32,
) !api.BodyId {
    const V = @typeInfo(@FieldType(@FieldType(api.ShapeDescriptor, "triangle_mesh"), "vertices")).pointer.child;
    const verts = [_]V{
        .{ .data = .{ -1, tri_y, -1 } }, .{ .data = .{ 1, tri_y, -1 } }, .{ .data = .{ 0, tri_y, 1 } },
        .{ .data = .{ 0, orphan_y, 0 } }, // index 3, referenced by NO triangle
    };
    const tris = [_]u32{ 0, 2, 1 };
    const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &tris } });
    return world.addBody(gpa, .{
        .entity = ent(entity_index),
        .body_type = .static,
        .shape = shape,
        .position = av(0, 0, 0),
    });
}

test "an unreferenced vertex inside the solid does not make the surface overlap it" {
    const gpa = testing.allocator;
    var out: std.ArrayListUnmanaged(sensor.BodyOverlap) = .empty;
    defer out.deinit(gpa);

    // **THE CONVEXITY ARGUMENT IS ABOUT THE VERTICES OF A TRIANGLE, and the stored array is
    // not that set.** A predicate walking the stored array answers "overlap" for a surface
    // lying wholly outside the solid that merely stores an orphan inside it — a FALSE
    // POSITIVE, which in a sensor is a phantom `TriggerEnter`: not a conservative answer, a
    // wrong one, and more visible in play than a miss.
    //
    // The orphan is NOT rejected at creation, deliberately: an imported mesh may legitimately
    // carry unreferenced vertices, and refusing them would break valid assets for a defect
    // that lives in the predicate.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addHalfSpaceTrigger(gpa, &world, 1); // solid {y <= 0}
        // Triangle entirely at y = +2, outside the solid; orphan at y = −5, inside it.
        const mesh = try addMeshWithOrphan(gpa, &world, 2, -5, 2);

        // The traversal REALLY REACHES the body: its world AABB is tight over the stored
        // vertices, orphan included, so it spans y ∈ [−5, 2] and meets the half-space. The
        // refusal below is therefore the kernel's and not a candidate that was never offered.
        try testing.expect(world.bm.bodyAabb(&world.store, mesh).?.min.toArray()[1] < 0);

        try collect(gpa, &world, &out);
        try testing.expect(!hasOverlap(out.items, trigger, mesh));
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }

    // POSITIVE CONTROL, same shape of scene: move the TRIANGLE inside the solid and the same
    // predicate answers overlap. Without it the assertion above is satisfied by a kernel that
    // answers `false` unconditionally.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const trigger = try addHalfSpaceTrigger(gpa, &world, 1);
        const mesh = try addMeshWithOrphan(gpa, &world, -1, -5, 2);
        try collect(gpa, &world, &out);
        try testing.expect(hasOverlap(out.items, trigger, mesh));
    }
}

test "the owed wake dispatches on the shape, and a half-space trigger needs the other path" {
    const gpa = testing.allocator;
    var world = harness.World.init(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    world.sensors_on = true;

    // **THE SECOND SHAPE THE ROLE ADMITS, and the one a single recipe cannot serve.** A
    // half-space keeps the sensor role — it is a volume with an interior — and it is exactly
    // the shape `overlapShape` refuses as a probe. A caller told only to "run an overlap query"
    // would get `error.UnsupportedShape` on half of the role's own domain.
    const trigger = try addHalfSpaceTrigger(gpa, &world, 1); // solid {y <= 0}
    const bshape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(0.5, 0.5, 0.5) } });
    const sleeper = try world.addBody(gpa, .{
        .entity = ent(2),
        .body_type = .dynamic,
        .shape = bshape,
        .position = av(0, -2, 0), // well inside the solid
    });

    for (0..60) |_| try world.step(gpa);
    try testing.expectEqual(true, world.bm.isSleeping(sleeper).?);
    try testing.expect(hasPair(world.sensors.current.items, 1, 2));

    // THE RECIPE THAT DOES NOT WORK, asserted rather than described: the query entry refuses a
    // half-space probe outright. Without this line the dispatch below reads as a preference.
    var found: [8]api.BodyId = undefined;
    try testing.expectError(error.UnsupportedShape, query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = world.bm.shapeOf(trigger).?,
        .position = world.bm.position(trigger).?,
    }, &found));

    try clearTriggerRole(gpa, &world, trigger);
    try world.step(gpa);
    try testing.expect(hasPair(world.sensors.exited.items, 1, 2));

    // The sleeper is still asleep inside what is now a solid half-space: the precondition, on
    // the second shape.
    for (0..10) |_| {
        try world.step(gpa);
        try testing.expectEqual(true, world.bm.isSleeping(sleeper).?);
    }

    // THE RECIPE THAT WORKS, performed — `queryHalfSpace` for the candidates, then the exact
    // kernel per candidate. It is what the sensor pass itself does for a half-space trigger,
    // so the caller composes an existing path instead of needing a new query entry.
    const shape = world.store.get(world.bm.shapeOf(trigger).?).?;
    const world_plane = shape_mod.halfSpace(shape).transformed(
        world.bm.rotation(trigger).?,
        world.bm.position(trigger).?,
    );
    var candidates = Candidates{ .gpa = gpa };
    defer candidates.deinit();
    _ = world.bp.queryHalfSpace(world_plane.normal, world_plane.distance, &candidates);

    var woke = false;
    for (candidates.items.items) |id| {
        if (id == trigger) continue;
        const overlaps = if (probeIsConvex(&world, id))
            world.bm.overlapShapeBody(
                &world.store,
                trigger,
                shape_mod.supportShape(world.store.get(world.bm.shapeOf(id).?).?),
                world.bm.position(id).?,
                world.bm.rotation(id).?,
                .ignore,
            ) orelse false
        else
            world.bm.halfSpaceOverlapsBody(&world.store, trigger, id) orelse false;
        if (!overlaps) continue;
        world.bm.wakeBody(id);
        if (id == sleeper) woke = true;
    }
    try testing.expect(woke); // the composition really found the sleeper
    try testing.expectEqual(false, world.bm.isSleeping(sleeper).?);
}

/// Records every `user_data` a broadphase traversal offers.
const Candidates = struct {
    items: std.ArrayListUnmanaged(api.BodyId) = .empty,
    gpa: std.mem.Allocator,

    pub fn add(self: *Candidates, user_data: u32) void {
        self.items.append(self.gpa, user_data) catch @panic("collector OOM");
    }
    fn deinit(self: *Candidates) void {
        self.items.deinit(self.gpa);
    }
};

fn probeIsConvex(world: *const harness.World, id: api.BodyId) bool {
    const sid = world.bm.shapeOf(id) orelse return false;
    const s = world.store.get(sid) orelse return false;
    return s.class() == .convex;
}

test "the composition must wake the body whose role changed, not only what it overlaps" {
    const gpa = testing.allocator;
    var world = harness.World.init(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    world.sensors_on = true;

    // **THE THIRD BRANCH, and it is the one the other two cases could not show.** There, the
    // sleeper was what the trigger OVERLAPPED, so waking the overlapped bodies was enough.
    // Here the sleeper IS the trigger: a DYNAMIC trigger — a configuration this suite already
    // builds — overlapping a STATIC body.
    //
    // Waking the static changes nothing, and the mechanism is exact: `sleep.isAwake` returns
    // `isMoving` for a non-dynamic body, so a static at rest is NOT awake, and `build` skips
    // and DEFERS any pair with neither endpoint awake. The pair therefore never produces a
    // manifold, nothing wakes the trigger, and the body that just became solid stays
    // interpenetrated indefinitely.
    const tshape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(1, 1, 1) } });
    const trigger = try world.addBody(gpa, .{
        .entity = ent(1),
        .body_type = .dynamic,
        .shape = tshape,
        .position = av(0, 0, 0),
        .is_trigger = true,
    });
    const solid = try addBox(gpa, &world, av(1, 1, 1), av(0.5, 0, 0), 2, false, 0);

    for (0..60) |_| try world.step(gpa);
    try testing.expectEqual(true, world.bm.isSleeping(trigger).?);
    try testing.expect(hasPair(world.sensors.current.items, 1, 2));
    // While the role is on, the pair reaches no constraint at all — the matrix sees to that.
    try testing.expectEqual(@as(usize, 0), world.constraints.items.len);

    try clearTriggerRole(gpa, &world, trigger);
    try world.step(gpa);
    try testing.expect(hasPair(world.sensors.exited.items, 1, 2));

    // NEGATIVE, and it is the discriminator: waking ONLY what the volume overlaps — the recipe
    // that sufficed in the two earlier cases — leaves the trigger asleep and the pair deferred.
    world.bm.wakeBody(solid);
    for (0..10) |_| {
        try world.step(gpa);
        try testing.expectEqual(true, world.bm.isSleeping(trigger).?);
        try testing.expectEqual(@as(usize, 0), world.constraints.items.len);
    }

    // POSITIVE: wake the body whose ROLE CHANGED. The pair reaches `build`, and the fixpoint
    // propagates from there to any neighbour that needs it.
    world.bm.wakeBody(trigger);
    try world.step(gpa);
    try testing.expectEqual(false, world.bm.isSleeping(trigger).?);
    try testing.expect(world.constraints.items.len > 0);
}
