//! `forge_3d/tests/overlap_test.zig` — the overlap, point-query and closest-point
//! acceptance suites (M1.1.10, opened at E5 and completed at E6).
//!
//! Every expectation is written from the geometry, in the comment above it. The first
//! section is the per-entry behaviour — what each one returns, and what it refuses —
//! and the second is what the four share: the object mask and the exclusion list at
//! both ends of their domain, a sleeping body, a caller buffer that overflows, and
//! invariance under a permutation of creation order asserted on the IDENTITY of the
//! bodies returned rather than on their count.
//!
//! Two E5 tests were removed at E6 rather than left beside their successors: a
//! sphere-only point-query test strictly subsumed by the three-shape one, and a
//! closest-point test whose three claims each acquired a dedicated test. One item of
//! the brief, one test.

const std = @import("std");
const config = @import("../config.zig");
const query = @import("../query/root.zig");
const harness = @import("solver_test.zig");
const api = @import("weld_forge");

const testing = std.testing;
const Real = config.Real;
const Vec3r = config.Vec3r;

const tol: Real = if (Real == f32) 1e-5 else 1e-12;

fn v(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// A static unit-radius sphere body at `centre`, on `entity_index` so the ordering
/// key has something to rank by.
fn addSphere(gpa: std.mem.Allocator, world: *harness.World, centre: [3]f32, radius: f32, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = radius } });
    return world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(centre[0], centre[1], centre[2]),
        .body_type = .static,
        .entity = .{ .index = entity_index, .generation = 0 },
    });
}

test "overlapShape returns the overlapping bodies and nothing else" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // A unit sphere probe at the origin against three unit spheres: one concentric
    // (cores coincide), one at 1.9 (r_sum = 2, so they overlap by 0.1), one at 5
    // (clear by 3). The predicate is "the GJK regime is not `separated`" and it
    // introduces no threshold of its own (§1.11.12).
    const inside = try addSphere(gpa, &world, .{ 0, 0, 0 }, 1, 0);
    const grazing = try addSphere(gpa, &world, .{ 1.9, 0, 0 }, 1, 1);
    _ = try addSphere(gpa, &world, .{ 5, 0, 0 }, 1, 2);

    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    var out: [8]api.BodyId = undefined;
    const n = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .position = Vec3r.zero,
    }, &out);
    try testing.expectEqual(@as(u32, 2), n);
    // Sorted by `(entity, BodyId)`, and entity 0 is the concentric one.
    try testing.expectEqual(inside, out[0]);
    try testing.expectEqual(grazing, out[1]);

    // A probe far from everything returns nothing rather than the candidate set.
    const empty = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .position = v(100, 0, 0),
    }, &out);
    try testing.expectEqual(@as(u32, 0), empty);
}

test "overlapAabb rejects a body inside the fat margin but outside the tight box" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // A unit sphere at (10, 0, 0): its TIGHT world AABB is [9, 11]³-ish, and the
    // tree stores it FATTENED by `BroadphaseConfig.margin` (0.1) to [8.9, 11.1].
    // A query box starting at 11.05 therefore overlaps the fat box and NOT the tight
    // one — which is precisely the case §1.11.12 says must come back empty, because
    // otherwise the answer would be a function of a tuning constant.
    const body = try addSphere(gpa, &world, .{ 10, 0, 0 }, 1, 0);

    const near_min = v(11.05, -1, -1);
    const near_max = v(12, 1, 1);

    // DISCRIMINATION GUARD, observed on the traversal itself rather than argued from
    // box arithmetic. Without it the test could pass because the candidate was never
    // delivered at all, which would prove nothing about the exact kernel. Here the
    // broadphase really does hand this body over — its FAT box reaches the query —
    // and its TIGHT box really does not, so the rejection is the exact kernel's.
    const Seen = struct {
        target: api.BodyId,
        seen: bool = false,
        pub fn add(self: *@This(), user_data: u32) void {
            if (user_data == self.target) self.seen = true;
        }
    };
    var seen = Seen{ .target = body };
    _ = world.bp.queryAabb(config.Aabbr.fromMinMax(near_min, near_max), &seen);
    try testing.expect(seen.seen);
    const tight = world.bm.bodyAabb(&world.store, body).?;
    try testing.expect(!tight.overlaps(config.Aabbr.fromMinMax(near_min, near_max)));

    var out: [8]api.BodyId = undefined;
    try testing.expectEqual(@as(u32, 0), query.overlapAabb(&world.bp, &world.bm, &world.store, near_min, near_max, .{}, &out));

    // A box that does reach the tight AABB returns it. Faces count: a box whose min
    // is exactly the sphere's max X still overlaps (§1.11.12, face-inclusive).
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(11, -1, -1), v(12, 1, 1), .{}, &out));
    try testing.expectEqual(body, out[0]);
}

// ---------------------------------------------------------------------------
// M1.1.10 / E6 — the overlap, point-query and closest-point acceptance suites
// ---------------------------------------------------------------------------

const narrowphase = @import("../pipeline/narrowphase/root.zig");
const shape_mod = @import("../shape.zig");
const cast_tests = @import("shapecast_test.zig");
const Quatr = config.Quatr;

/// A static body of the given shape descriptor at `centre`, on `entity_index` and
/// `layer`. Returns both handles: several tests need the shape to rebuild the
/// support form for a guard.
const Placed = struct { id: api.BodyId, shape: api.ShapeId };

fn place(
    gpa: std.mem.Allocator,
    world: *harness.World,
    desc: api.ShapeDescriptor,
    centre: [3]f32,
    entity_index: u32,
    layer: u8,
) !Placed {
    const shape = try world.store.createShape(gpa, desc);
    const id = try world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(centre[0], centre[1], centre[2]),
        .body_type = .static,
        .collision_layer = layer,
        .entity = .{ .index = entity_index, .generation = 0 },
    });
    return .{ .id = id, .shape = shape };
}

test "overlapShape accepts bodies inside and touching, and rejects those clear of it" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // A unit-sphere probe at the origin against three unit spheres: concentric,
    // exactly TOUCHING at 2 (r_sum = 2, so the inflated surfaces meet — which the
    // frozen convention counts as contact, not separation), and clear at 5.
    const inside = (try place(gpa, &world, .{ .sphere = .{ .radius = 1 } }, .{ 0, 0, 0 }, 0, 0)).id;
    const touching = (try place(gpa, &world, .{ .sphere = .{ .radius = 1 } }, .{ 2, 0, 0 }, 1, 0)).id;
    _ = try place(gpa, &world, .{ .sphere = .{ .radius = 1 } }, .{ 5, 0, 0 }, 2, 0);

    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    var out: [8]api.BodyId = undefined;
    const n = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .position = Vec3r.zero,
    }, &out);
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(inside, out[0]);
    try testing.expectEqual(touching, out[1]);
}

test "overlapAabb is face-inclusive" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // A unit box at the origin: its tight world AABB is exactly [-1, 1]³.
    const body = (try place(gpa, &world, .{ .box = .{ .half_extents = harness.av3(1, 1, 1) } }, .{ 0, 0, 0 }, 0, 0)).id;
    var out: [4]api.BodyId = undefined;

    // A query box whose MIN corner is exactly the body's MAX corner shares one point
    // and counts — the same inclusive convention as `Aabb.overlaps`, `contains` and
    // the ray slab test.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(1, 1, 1), v(3, 3, 3), .{}, &out));
    try testing.expectEqual(body, out[0]);
    // A degenerate query box ON the face is still a hit.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(1, 0, 0), v(1, 0, 0), .{}, &out));
    // One ulp past the face is not, and that is the discrimination: without it
    // "inclusive" would be indistinguishable from "generous".
    const past: Real = @bitCast(@as(if (Real == f32) u32 else u64, @bitCast(@as(Real, 1))) + 1);
    try testing.expectEqual(@as(u32, 0), query.overlapAabb(&world.bp, &world.bm, &world.store, v(past, past, past), v(3, 3, 3), .{}, &out));
}

test "pointQuery is solid with the boundary included, for each of the three shapes" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // Each shape gets its own body, far enough apart that no probe can reach two.
    // Per shape: a point strictly inside, one exactly ON the boundary, one just
    // outside — the three cases §1.11.4's solidity convention distinguishes.
    const sphere_body = (try place(gpa, &world, .{ .sphere = .{ .radius = 2 } }, .{ 0, 0, 0 }, 0, 0)).id;
    const box_body = (try place(gpa, &world, .{ .box = .{ .half_extents = harness.av3(1, 2, 3) } }, .{ 50, 0, 0 }, 1, 0)).id;
    const capsule_body = (try place(gpa, &world, .{ .capsule = .{ .radius = 0.5, .half_height = 1 } }, .{ 100, 0, 0 }, 2, 0)).id;

    const Case = struct { body: api.BodyId, inside: Vec3r, boundary: Vec3r, outside: Vec3r };
    const cases = [_]Case{
        // Sphere radius 2 at the origin.
        .{ .body = sphere_body, .inside = v(1, 0, 0), .boundary = v(2, 0, 0), .outside = v(2.001, 0, 0) },
        // Box half-extents (1, 2, 3) at x = 50 — the boundary point is a face centre,
        // and the outside one clears the SHORT axis, not the long ones.
        .{ .body = box_body, .inside = v(50, 1, 2), .boundary = v(51, 0, 0), .outside = v(51.001, 0, 0) },
        // Capsule (Y segment ±1, radius 0.5) at x = 100: the boundary point is on the
        // cylindrical wall at the segment's midpoint.
        .{ .body = capsule_body, .inside = v(100, 0.5, 0), .boundary = v(100.5, 0, 0), .outside = v(100.501, 0, 0) },
    };

    var out: [4]api.BodyId = undefined;
    for (cases) |case| {
        for ([_]Vec3r{ case.inside, case.boundary }) |p| {
            try testing.expectEqual(@as(u32, 1), query.pointQuery(&world.bp, &world.bm, &world.store, p, .{}, &out));
            try testing.expectEqual(case.body, out[0]);
        }
        try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, case.outside, .{}, &out));
    }
}

test "closestPoint on a point inside the solid returns zero and the point itself" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = (try place(gpa, &world, .{ .box = .{ .half_extents = harness.av3(2, 2, 2) } }, .{ 0, 0, 0 }, 0, 0)).id;

    // Strictly inside, and exactly ON the boundary — both are "inside the solid"
    // under §1.11.13's convention, decided upstream of any GJK classification.
    for ([_]Vec3r{ Vec3r.zero, v(1, -1, 0.5), v(2, 0, 0) }) |p| {
        const hit = query.closestPoint(&world.bp, &world.bm, &world.store, p, 100, .{}).?;
        try testing.expectEqual(body, hit.body);
        try testing.expectEqual(@as(Real, 0), hit.distance);
        // The closest point is the queried point ITSELF, exactly — not a projection
        // onto the surface, which is what "distance to the solid" means.
        inline for (0..3) |i| try testing.expectEqual(p.toArray()[i], hit.position.toArray()[i]);
    }
}

test "closestPoint in the shallow band returns a positive surface distance" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // `.shallow` means the CORES are disjoint beyond the noise floor while the
    // INFLATED surfaces touch or overlap: a real separation absorbed by the numeric
    // margin, and NOT an interior. Collapsing it into `.deep` would return 0 for a
    // point that is measurably outside — the defect this test exists to catch.
    //
    // For a point probe (radius 0) against a sphere of radius `r`, the regime is
    // `shallow` exactly when `r < dist <= r + margin`, the margin being GJK's
    // accumulated-rounding bound `conv_k · floatEps · coordScale` with `conv_k = 16`
    // and, here, `coordScale ≈ r`. The band is therefore a few ULPs wide BY
    // CONSTRUCTION, so the probe is placed inside it in those units and not in
    // metres: 8 ULPs of the coordinate scale sits above the `noise_k = 2` deep floor
    // and below the 16-ULP contact margin.
    const radius: Real = 2;
    const delta: Real = 8 * std.math.floatEps(Real) * radius;
    const placed = try place(gpa, &world, .{ .sphere = .{ .radius = 2 } }, .{ 0, 0, 0 }, 0, 0);
    const probe_point = v(radius + delta, 0, 0);

    // The point is OUTSIDE the solid — otherwise the solidity gate would answer
    // first and the shallow path would never run.
    try testing.expect(!world.bm.containsPointBody(&world.store, placed.id, probe_point).?);

    // DISCRIMINATION GUARD. GJK really classified this pair `.shallow`. Without it
    // the test would pass on a `.separated` pair, where a positive distance is
    // trivially right and proves nothing about the shallow path — which is precisely
    // the path §1.11.13 says must not be read as an interior.
    const point_core: narrowphase.SupportShape(Real) = .{ .core = .point, .radius = 0 };
    const regime = narrowphase.gjk(
        Real,
        point_core,
        probe_point,
        Quatr.identity,
        shape_mod.supportShape(world.store.get(placed.shape).?),
        Vec3r.zero,
        Quatr.identity,
    );
    try testing.expectEqual(narrowphase.GjkResult(Real).Status.shallow, regime.status);

    // THE CLAIM: a positive surface distance, not zero.
    const hit = query.closestPoint(&world.bp, &world.bm, &world.store, probe_point, 100, .{}).?;
    try testing.expectEqual(placed.id, hit.body);
    try testing.expect(hit.distance > 0);
    try testing.expectApproxEqAbs(delta, hit.distance, 4 * std.math.floatEps(Real) * radius);
}

test "closestPoint projects onto the inflated surface" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // Two shapes whose CORE distance and SURFACE distance differ by the radius, so a
    // projection that forgot the inflation would be visible in both.
    const ball = (try place(gpa, &world, .{ .sphere = .{ .radius = 2 } }, .{ 0, 0, 0 }, 0, 0)).id;
    const pill = (try place(gpa, &world, .{ .capsule = .{ .radius = 0.5, .half_height = 1 } }, .{ 100, 0, 0 }, 1, 0)).id;

    // SPHERE. Core = the centre. From (10, 0, 0) the core distance is 10, so the
    // surface distance is 10 − 2 = 8 and the surface point is (2, 0, 0).
    {
        const hit = query.closestPoint(&world.bp, &world.bm, &world.store, v(10, 0, 0), 100, .{}).?;
        try testing.expectEqual(ball, hit.body);
        try testing.expectApproxEqAbs(@as(Real, 8), hit.distance, tol);
        try testing.expect(hit.position.approxEql(v(2, 0, 0), tol));
    }

    // CAPSULE. Core = the Y segment ±1 at x = 100. From (110, 5, 0) the closest core
    // point is the +Y endpoint (100, 1, 0), so the core offset is (10, 4, 0) of
    // length √116, the surface distance is √116 − 0.5, and the surface point is that
    // endpoint plus 0.5 along the unit offset.
    {
        const point = v(110, 5, 0);
        const endpoint = v(100, 1, 0);
        const offset = point.sub(endpoint);
        const hit = query.closestPoint(&world.bp, &world.bm, &world.store, point, 100, .{}).?;
        try testing.expectEqual(pill, hit.body);
        try testing.expectApproxEqAbs(@sqrt(@as(Real, 116)) - 0.5, hit.distance, tol);
        try testing.expect(hit.position.approxEql(endpoint.add(offset.normalize().scale(0.5)), tol));
    }
}

test "closestPoint selects among several candidates by SURFACE distance" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // The discriminating scene: the body whose CENTRE is nearest is NOT the body
    // whose SURFACE is nearest. A small sphere at 5 has its surface at 4.5; a large
    // one at 10 has its surface at 1. Ranking on the centre — or on the GJK core
    // distance without subtracting the radius — would answer the small one.
    _ = try place(gpa, &world, .{ .sphere = .{ .radius = 0.5 } }, .{ 5, 0, 0 }, 0, 0);
    const big = (try place(gpa, &world, .{ .sphere = .{ .radius = 9 } }, .{ 10, 0, 0 }, 1, 0)).id;

    const hit = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{}).?;
    try testing.expectEqual(big, hit.body);
    try testing.expectApproxEqAbs(@as(Real, 1), hit.distance, tol);
    try testing.expect(hit.position.approxEql(v(1, 0, 0), tol));
}

test "closestPoint returns nothing beyond max_distance" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try place(gpa, &world, .{ .sphere = .{ .radius = 1 } }, .{ 10, 0, 0 }, 0, 0);

    // The surface is at 9. The bound is CLOSED, so 9 answers and one ulp below does
    // not — the same convention, and the same pair of assertions, as the ray's.
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 9, .{}) != null);
    const just_below: Real = @bitCast(@as(if (Real == f32) u32 else u64, @bitCast(@as(Real, 9))) - 1);
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, just_below, .{}) == null);
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 0, .{}) == null);
}

// --- Shared across the four entries -----------------------------------------
//
// The three multi-result entries share a shape, so they share a driver: five
// radius-3 spheres clustered on the origin, each containing it, each overlapping a
// unit probe there, each inside the query box. Every one of them therefore answers
// all three entries, and the behaviour under test is the filtering, the retention
// and the ordering — not the geometry, which has its own tests above.

const Entry = enum { shape, aabb, point };

const entry_names = [_][]const u8{ "overlapShape", "overlapAabb", "pointQuery" };

fn buildCluster(gpa: std.mem.Allocator, world: *harness.World, order: []const usize) !void {
    const centres = [5][3]f32{ .{ 0, 0, 0 }, .{ 0.5, 0, 0 }, .{ -0.5, 0, 0 }, .{ 0, 0.5, 0 }, .{ 0, -0.5, 0 } };
    for (order) |which| {
        _ = try place(gpa, world, .{ .sphere = .{ .radius = 3 } }, centres[which], @intCast(which), @intCast(which));
    }
}

/// Fallible since M1.1.11/E3: `overlapShape` takes a caller-supplied shape handle and
/// so carries `query.Error`, while the other two entries take none and stay total. The
/// helper propagates rather than swallowing, so a stale probe or an inadmissible one
/// would fail the calling test instead of reading as an empty answer.
fn runEntry(world: *harness.World, entry: Entry, probe: api.ShapeId, filter: query.Filter, out: []api.BodyId) !u32 {
    return switch (entry) {
        .shape => try query.overlapShape(&world.bp, &world.bm, &world.store, .{
            .shape = probe,
            .position = Vec3r.zero,
            .filter = filter,
        }, out),
        .aabb => query.overlapAabb(&world.bp, &world.bm, &world.store, v(-1, -1, -1), v(1, 1, 1), filter, out),
        .point => query.pointQuery(&world.bp, &world.bm, &world.store, Vec3r.zero, filter, out),
    };
}

/// The entity indices behind a returned body slice, in order.
fn entitiesOf(world: *const harness.World, ids: []const api.BodyId, buf: []u32) []u32 {
    for (ids, 0..) |id, i| buf[i] = world.bm.entity(id).?.index;
    return buf[0..ids.len];
}

test "the object mask filters every overlap entry" {
    const gpa = std.testing.allocator;
    inline for (@typeInfo(Entry).@"enum".fields, 0..) |field, ei| {
        const entry: Entry = @enumFromInt(field.value);
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        try buildCluster(gpa, &world, &.{ 0, 1, 2, 3, 4 });
        const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
        var out: [8]api.BodyId = undefined;
        var ents: [8]u32 = undefined;

        // FULL mask: all five, ordered by entity.
        const all = try runEntry(&world, entry, probe, .{}, &out);
        try testing.expectEqual(@as(u32, 5), all);
        try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, entitiesOf(&world, out[0..all], &ents));

        // A mask naming layers 1 and 3 — the layer IS the entity index here.
        const two = try runEntry(&world, entry, probe, .{ .layer_mask = (@as(u32, 1) << 1) | (@as(u32, 1) << 3) }, &out);
        if (two != 2) {
            std.debug.print("{s}: masked to two layers, got {d}\n", .{ entry_names[ei], two });
            return error.MaskIgnored;
        }
        try testing.expectEqualSlices(u32, &.{ 1, 3 }, entitiesOf(&world, out[0..two], &ents));

        // EMPTY mask: nothing at all, which is the other end of the domain.
        try testing.expectEqual(@as(u32, 0), try runEntry(&world, entry, probe, .{ .layer_mask = 0 }, &out));
    }
}

test "exclusions are honoured by every overlap entry" {
    const gpa = std.testing.allocator;
    inline for (@typeInfo(Entry).@"enum".fields) |field| {
        const entry: Entry = @enumFromInt(field.value);
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        try buildCluster(gpa, &world, &.{ 0, 1, 2, 3, 4 });
        const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
        var out: [8]api.BodyId = undefined;
        var ents: [8]u32 = undefined;

        const all = try runEntry(&world, entry, probe, .{}, &out);
        try testing.expectEqual(@as(u32, 5), all);
        // Exclude two of them by handle — the dominant real case being "myself".
        const excluded = [_]api.BodyId{ out[0], out[2] };
        const rest = try runEntry(&world, entry, probe, .{ .exclude = &excluded }, &out);
        try testing.expectEqual(@as(u32, 3), rest);
        try testing.expectEqualSlices(u32, &.{ 1, 3, 4 }, entitiesOf(&world, out[0..rest], &ents));
    }
}

test "a caller buffer that overflows keeps the best set under the ordering key" {
    const gpa = std.testing.allocator;
    // Five candidates into a two-slot buffer. The retained pair must be entities 0
    // and 1 — the best under `(entity, BodyId)` — WHATEVER order the scene was built
    // in, which is the whole point: a retention keyed on `BodyId` would keep the two
    // created first and answer differently in each order.
    const orders = [3][5]usize{ .{ 0, 1, 2, 3, 4 }, .{ 4, 3, 2, 1, 0 }, .{ 2, 4, 0, 3, 1 } };
    inline for (@typeInfo(Entry).@"enum".fields) |field| {
        const entry: Entry = @enumFromInt(field.value);
        for (orders) |order| {
            var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
            defer world.deinit(gpa);
            try buildCluster(gpa, &world, &order);
            const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });

            var two: [2]api.BodyId = undefined;
            var ents: [2]u32 = undefined;
            const n = try runEntry(&world, entry, probe, .{}, &two);
            try testing.expectEqual(@as(u32, 2), n);
            try testing.expectEqualSlices(u32, &.{ 0, 1 }, entitiesOf(&world, two[0..n], &ents));

            // A zero-length buffer writes nothing and says so, rather than
            // overrunning or reporting what it could not store.
            var none: [0]api.BodyId = undefined;
            try testing.expectEqual(@as(u32, 0), try runEntry(&world, entry, probe, .{}, &none));
        }
    }
}

test "every overlap entry is invariant under creation-order permutation" {
    const gpa = std.testing.allocator;
    // The same scene in six orders. The answer is a SEQUENCE OF ENTITIES and it must
    // be identical every time — identity, not merely cardinality, which is what the
    // M1.1.9 ray test stopped short of asserting.
    const orders = [6][5]usize{
        .{ 0, 1, 2, 3, 4 }, .{ 4, 3, 2, 1, 0 }, .{ 2, 0, 4, 1, 3 },
        .{ 1, 4, 0, 3, 2 }, .{ 3, 2, 4, 0, 1 }, .{ 0, 4, 1, 2, 3 },
    };
    inline for (@typeInfo(Entry).@"enum".fields) |field| {
        const entry: Entry = @enumFromInt(field.value);
        for (orders) |order| {
            var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
            defer world.deinit(gpa);
            try buildCluster(gpa, &world, &order);
            const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
            var out: [8]api.BodyId = undefined;
            var ents: [8]u32 = undefined;
            const n = try runEntry(&world, entry, probe, .{}, &out);
            try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, entitiesOf(&world, out[0..n], &ents));

            // Two identical runs in the same world return bit-identical slices.
            var again: [8]api.BodyId = undefined;
            const m = try runEntry(&world, entry, probe, .{}, &again);
            try testing.expectEqual(n, m);
            try testing.expectEqualSlices(api.BodyId, out[0..n], again[0..m]);
        }
    }
}

test "closestPoint filters, is invariant, and is bit-identical twice" {
    const gpa = std.testing.allocator;
    const orders = [4][3]usize{ .{ 0, 1, 2 }, .{ 2, 1, 0 }, .{ 1, 0, 2 }, .{ 2, 0, 1 } };
    // Three spheres whose SURFACES sit at 4, 9 and 14 from the origin, on layers
    // equal to their entity indices.
    const centres = [3][3]f32{ .{ 5, 0, 0 }, .{ 10, 0, 0 }, .{ 15, 0, 0 } };
    var reference: ?Real = null;
    for (orders) |order| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var ids: [3]api.BodyId = undefined;
        for (order) |which| {
            ids[which] = (try place(gpa, &world, .{ .sphere = .{ .radius = 1 } }, centres[which], @intCast(which), @intCast(which))).id;
        }

        // Nearest surface wins, and it is the same ENTITY under every order.
        const hit = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{}).?;
        try testing.expectEqual(ids[0], hit.body);
        try testing.expectEqual(@as(u32, 0), hit.entity.index);
        try testing.expectApproxEqAbs(@as(Real, 4), hit.distance, tol);
        if (reference) |ref| {
            try testing.expectEqual(ref, hit.distance); // bit-identical across worlds
        } else reference = hit.distance;

        // Two identical runs are bit-identical, field by field.
        const again = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{}).?;
        try testing.expectEqual(hit.body, again.body);
        try testing.expectEqual(hit.entity, again.entity);
        try testing.expectEqual(hit.distance, again.distance);
        inline for (0..3) |i| try testing.expectEqual(hit.position.toArray()[i], again.position.toArray()[i]);

        // The mask skips the nearest and answers the next; the empty mask answers
        // nothing; an exclusion does the same by handle.
        const masked = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{
            .layer_mask = (@as(u32, 1) << 1) | (@as(u32, 1) << 2),
        }).?;
        try testing.expectEqual(ids[1], masked.body);
        try testing.expectApproxEqAbs(@as(Real, 9), masked.distance, tol);
        try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{ .layer_mask = 0 }) == null);
        const excluded = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{ .exclude = &.{ids[0]} }).?;
        try testing.expectEqual(ids[1], excluded.body);
    }
}

test "a sleeping body answers every overlap entry and stays asleep" {
    const gpa = std.testing.allocator;
    inline for (@typeInfo(Entry).@"enum".fields) |field| {
        const entry: Entry = @enumFromInt(field.value);
        var world = harness.World.init(harness.vr(0, -9.81, 0), 1.0 / 60.0);
        defer world.deinit(gpa);
        const sleeper = try cast_tests.sleepingBox(gpa, &world);
        const centre = world.bm.position(sleeper).?;
        const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.25 } });

        // Every entry is aimed at the sleeper's own settled pose, so the scene does
        // not depend on where the solver left it.
        var out: [8]api.BodyId = undefined;
        const n = switch (entry) {
            .shape => try query.overlapShape(&world.bp, &world.bm, &world.store, .{ .shape = probe, .position = centre }, &out),
            .aabb => query.overlapAabb(&world.bp, &world.bm, &world.store, centre.sub(v(0.1, 0.1, 0.1)), centre.add(v(0.1, 0.1, 0.1)), .{}, &out),
            .point => query.pointQuery(&world.bp, &world.bm, &world.store, centre, .{}, &out),
        };
        // The ground is static and huge, so it may answer too; what matters is that
        // the SLEEPER is in the answer.
        var found = false;
        for (out[0..n]) |id| {
            if (id == sleeper) found = true;
        }
        try testing.expect(found);
        // Asleep BEFORE (asserted inside `sleepingBox`) and asleep AFTER.
        try testing.expect(world.bm.isSleeping(sleeper).?);
        // …and still asleep once the cycle has been advanced again.
        try world.step(gpa);
        try testing.expect(world.bm.isSleeping(sleeper).?);
    }
}

test "closestPoint answers a sleeping body and leaves it asleep" {
    const gpa = std.testing.allocator;
    var world = harness.World.init(harness.vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const sleeper = try cast_tests.sleepingBox(gpa, &world);
    const centre = world.bm.position(sleeper).?;

    // Its own centre is inside it, so the distance is 0 and the point is itself.
    const inside = query.closestPoint(&world.bp, &world.bm, &world.store, centre, 100, .{}).?;
    try testing.expectEqual(@as(Real, 0), inside.distance);
    try testing.expect(world.bm.isSleeping(sleeper).?);
    try world.step(gpa);
    try testing.expect(world.bm.isSleeping(sleeper).?);
}

// ---------------------------------------------------------------------------
// M1.1.10 / E8 — the deep-band exterior answer (P1)
// ---------------------------------------------------------------------------
//
// **The band, MEASURED, and what bounds its reach.** GJK classifies `.deep` when the
// core distance falls inside `conv_k · floatEps · coordScale` with `conv_k = 16` and
// `coordScale = |pos_b − pos_a| + coreExtent(b)` (`gjk.zig`). For `closestPointBody`,
// `pos_a` is the QUERIED POINT — so `coordScale` is RELATIVE geometry, about
// `1 + √3 = 2.732` for a unit box probed near its face, and it does NOT grow with the
// world coordinate. The band width is therefore CONSTANT: 5.211e-6 at f32,
// 9.706e-15 at f64, at 1 m as at 10 km.
//
// What does grow is `ulp(coordinate)`, and that is what bounds the band's REACH.
// Measured, stepping in absolute multiples of `floatEps` (a coordinate-relative step
// is already coarser than the band at 100 m and misses it entirely — the blind spot
// that made a first sweep report nothing):
//
//   | scale   | band      | ulp(coord) | representable steps | outside AND deep |
//   |---------|-----------|------------|---------------------|------------------|
//   | 1 m     | 5.211e-6  | 2.384e-7   | 13                  | 5, widest 3.815e-6 |
//   | 100 m   | 5.211e-6  | 1.204e-5   | 8                   | 0                |
//   | 10 km   | 5.211e-6  | 1.192e-3   | 1                   | 0                |
//
// So the defect is reachable only where `ulp(coordinate) < band`, i.e. near the
// origin. At 100 m and beyond no REPRESENTABLE point lies strictly inside it: the
// nearest float outside the face is already past the band. That is an absence of
// reachability, not an absence of defect — and it is why a probe that steps by a
// coordinate-relative amount sees nothing at scale. f64 shows the identical structure
// shifted by the eps ratio.

test "a point outside the solid but inside GJK's deep band gets an EXTERIOR answer" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // A unit box at the ORIGIN — the only scale at which the band is representable.
    // Its +X face is at x = 1.
    const placed = try place(gpa, &world, .{ .box = .{ .half_extents = harness.av3(1, 1, 1) } }, .{ 0, 0, 0 }, 0, 0);
    const body_shape = shape_mod.supportShape(world.store.get(placed.shape).?);
    const point_core: narrowphase.SupportShape(Real) = .{ .core = .point, .radius = 0 };
    const eps = std.math.floatEps(Real);

    // TWO SIDES, and both are load-bearing. 16 eps sits inside the band (measured
    // widest defective 32 eps); 64 eps sits outside it (band ≈ 43.7 eps). A test that
    // exercised only the band would not notice a fix that broke the healthy path.
    const Side = struct { name: []const u8, delta: Real, want_deep: bool };
    const sides = [_]Side{
        .{ .name = "inside the band", .delta = 16 * eps, .want_deep = true },
        .{ .name = "outside the band", .delta = 64 * eps, .want_deep = false },
    };

    for (sides) |side| {
        const p = v(1 + side.delta, 0, 0);
        // The step must be representable, or the point falls back onto the face and
        // the membership gate answers instead.
        try testing.expect(p.toArray()[0] != @as(Real, 1));

        // GUARD 1 — the membership test, which is the AUTHORITY on solidity, says
        // OUTSIDE. Everything below is therefore an exterior answer or a defect.
        try testing.expect(!world.bm.containsPointBody(&world.store, placed.id, p).?);

        // GUARD 2 — the regime really is the one this side means to exercise. Without
        // it the "inside the band" case could silently be a `.shallow` and prove
        // nothing about the deep path.
        const regime = narrowphase.gjk(Real, point_core, p, Quatr.identity, body_shape, Vec3r.zero, Quatr.identity);
        if (side.want_deep) {
            try testing.expectEqual(narrowphase.GjkResult(Real).Status.deep, regime.status);
        } else {
            try testing.expect(regime.status != .deep);
        }

        const hit = query.closestPoint(&world.bp, &world.bm, &world.store, p, 100, .{}).?;
        try testing.expectEqual(placed.id, hit.body);

        // THE CLAIM, identical on both sides because the membership test's verdict is
        // identical on both sides: an exterior point gets an exterior answer.
        //
        //   - `position` is a point OF THE BODY's surface, boundary included…
        try testing.expect(world.bm.containsPointBody(&world.store, placed.id, hit.position).?);
        //   - …and specifically the face point, never the queried point.
        try testing.expectApproxEqAbs(@as(Real, 1), hit.position.toArray()[0], 4 * eps);
        try testing.expect(hit.position.toArray()[0] != p.toArray()[0]);
        //   - and the distance is the real separation, not zero.
        try testing.expectApproxEqAbs(side.delta, hit.distance, 4 * eps);
        try testing.expect(hit.distance > 0);
    }
}

test "max_distance zero answers only for a point inside the solid" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const placed = try place(gpa, &world, .{ .box = .{ .half_extents = harness.av3(1, 1, 1) } }, .{ 0, 0, 0 }, 0, 0);
    const eps = std.math.floatEps(Real);

    // INTERIOR — boundary included — is at distance 0, so a zero bound admits it.
    for ([_]Vec3r{ Vec3r.zero, v(0.5, 0, 0), v(1, 0, 0) }) |p| {
        const hit = query.closestPoint(&world.bp, &world.bm, &world.store, p, 0, .{}).?;
        try testing.expectEqual(placed.id, hit.body);
        try testing.expectEqual(@as(Real, 0), hit.distance);
    }

    // EXTERIOR is not, however little, and that includes the deep band: an answer
    // there would mean the band had been read as an interior after all.
    for ([_]Real{ 16 * eps, 64 * eps, 0.001, 1 }) |delta| {
        const p = v(1 + delta, 0, 0);
        try testing.expect(!world.bm.containsPointBody(&world.store, placed.id, p).?);
        try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, p, 0, .{}) == null);
    }
}

// ---------------------------------------------------------------------------
// M1.1.10 / E9 — an inverted query box denotes the empty set (P1)
// ---------------------------------------------------------------------------

test "overlapAabb rejects an inverted query box and returns nothing" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // A box body whose TIGHT world AABB is exactly [−2, 2]³ — the scene the rule's
    // three measurements are stated against (§1.11.12).
    const body = (try place(gpa, &world, .{ .box = .{ .half_extents = harness.av3(2, 2, 2) } }, .{ 0, 0, 0 }, 0, 0)).id;
    var out: [8]api.BodyId = undefined;

    // The answer to a malformed box was not merely "sometimes non-empty": it was
    // ARBITRARY, following the AMPLITUDE and the AXES of the inversion. The overlap
    // predicate is written for well-formed boxes and reduces, on an inverted one, to
    // "does the body enclose both bounds" — which the three cases below satisfy
    // differently. Each is annotated with what it returned before the fix.
    const Malformed = struct { name: []const u8, min: Vec3r, max: Vec3r, was: u32 };
    const malformed = [_]Malformed{
        // self.min(−2) <= other.max(−1) and other.min(1) <= self.max(2) → accepted.
        .{ .name = "fully inverted, inside the body", .min = v(1, 1, 1), .max = v(-1, -1, -1), .was = 1 },
        // self.min(−2) <= other.max(−9) is FALSE → rejected, by accident of amplitude.
        .{ .name = "fully inverted, outside the body", .min = v(9, 9, 9), .max = v(-9, -9, -9), .was = 0 },
        // Two axes inverted, one well-formed → accepted again.
        .{ .name = "inverted on two axes only", .min = v(1, 1, -2), .max = v(-1, -1, 2), .was = 1 },
    };

    for (malformed) |case| {
        // GUARD — the malformation is real: at least one component has `min > max`.
        try testing.expect(@reduce(.Or, case.min.data > case.max.data));
        // THE CLAIM: zero, on all three, whatever the amplitude and whatever the axes.
        const n = query.overlapAabb(&world.bp, &world.bm, &world.store, case.min, case.max, .{}, &out);
        if (n != 0) {
            std.debug.print("'{s}': returned {d}, was {d} before the fix\n", .{ case.name, n, case.was });
            return error.InvertedBoxAccepted;
        }
    }

    // THE OTHER SIDE, and it is what makes the rejection a rejection rather than a
    // refusal: the WELL-FORMED equivalent of the first case — the same two corners,
    // ordered — must still answer the body. A rejection that were even slightly too
    // wide would take this with it.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(-1, -1, -1), v(1, 1, 1), .{}, &out));
    try testing.expectEqual(body, out[0]);
    // …and the well-formed equivalents of the other two, which straddle and enclose
    // the body respectively.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(-9, -9, -9), v(9, 9, 9), .{}, &out));
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(-1, -1, -2), v(1, 1, 2), .{}, &out));

    // A DEGENERATE box is not an inverted one: `min == max` on every axis is a single
    // point, a legal region, and it still answers.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, Vec3r.zero, Vec3r.zero, .{}, &out));
    // Degenerate on ONE axis only, well-formed on the others: still legal.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, v(0, -1, -1), v(0, 1, 1), .{}, &out));
}

// ---------------------------------------------------------------------------
// M1.1.11 / E3 — the three-way outcome of `overlapShape`
// ---------------------------------------------------------------------------

test "overlapShape separates a stale handle, an inadmissible probe and an empty answer" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // The mirror of the `shapeCast` case (`engine-physics-forge.md` §1.11.7), and the
    // conflation was the same one: MEASURED on the pre-E3 tree, a stale probe handle
    // returned `0` and a live probe overlapping nothing returned `0`. A count cannot
    // carry a diagnosis, so the entry gains the channel instead of overloading its
    // return value.
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const plane = try world.store.createShape(gpa, .{ .plane = .{} });
    const doomed = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    world.store.destroyShape(gpa, doomed);
    _ = try addSphere(gpa, &world, .{ 0, 0, 0 }, 1, 0);

    var out: [4]api.BodyId = undefined;

    // (1) STALE HANDLE → typed error.
    try testing.expectError(error.InvalidShape, query.overlapShape(
        &world.bp,
        &world.bm,
        &world.store,
        .{ .shape = doomed, .position = Vec3r.zero },
        &out,
    ));

    // (2) INADMISSIBLE PROBE → a distinct typed error. The exact kernel is GJK on the
    // cores (§1.11.12) and a half-space has no bounded core, so the probe is not
    // expressible — never an empty set, which would read as "nothing overlaps".
    try testing.expectError(error.UnsupportedShape, query.overlapShape(
        &world.bp,
        &world.bm,
        &world.store,
        .{ .shape = plane, .position = Vec3r.zero },
        &out,
    ));

    // (3) EMPTY ANSWER → `0`, and only now: a live probe 500 m away from the one body.
    try testing.expectEqual(@as(u32, 0), try query.overlapShape(
        &world.bp,
        &world.bm,
        &world.store,
        .{ .shape = probe, .position = v(0, 500, 0) },
        &out,
    ));

    // Positive control: the same probe on the body's own position finds it, so the
    // three answers above are refusals and not a broken entry.
    try testing.expectEqual(@as(u32, 1), try query.overlapShape(
        &world.bp,
        &world.bm,
        &world.store,
        .{ .shape = probe, .position = Vec3r.zero },
        &out,
    ));
}
