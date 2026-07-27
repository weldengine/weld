//! `forge_3d/tests/overlap_test.zig` — the overlap, point-query and closest-point
//! entries (M1.1.10 / E5: one minimal scene per entry, so no body ships bare).
//!
//! The full acceptance matrix — filtering, sleeping bodies, buffer overflow under the
//! retention key, creation-order invariance, bit-identity between runs — is E6's.
//! What is here is the strict minimum: each entry answers the right thing on a scene
//! whose expected answer is written from the geometry.

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
    const n = query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .position = Vec3r.zero,
    }, &out);
    try testing.expectEqual(@as(u32, 2), n);
    // Sorted by `(entity, BodyId)`, and entity 0 is the concentric one.
    try testing.expectEqual(inside, out[0]);
    try testing.expectEqual(grazing, out[1]);

    // A probe far from everything returns nothing rather than the candidate set.
    const empty = query.overlapShape(&world.bp, &world.bm, &world.store, .{
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

test "pointQuery is solid with the boundary included" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = try addSphere(gpa, &world, .{ 0, 0, 0 }, 1, 0);
    _ = try addSphere(gpa, &world, .{ 10, 0, 0 }, 1, 1);

    var out: [8]api.BodyId = undefined;
    // Strictly inside, and exactly ON the boundary — both are hits, the shape being
    // SOLID and closed (§1.11.4).
    for ([_]Vec3r{ Vec3r.zero, v(0.5, 0, 0), v(1, 0, 0) }) |p| {
        try testing.expectEqual(@as(u32, 1), query.pointQuery(&world.bp, &world.bm, &world.store, p, .{}, &out));
        try testing.expectEqual(body, out[0]);
    }
    // Just outside is not.
    try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, v(1.001, 0, 0), .{}, &out));
}

test "closestPoint returns the nearest surface within the bound" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // Unit spheres at 10 and 30 on +X: from the origin their surfaces are at 9 and 29.
    const near = try addSphere(gpa, &world, .{ 10, 0, 0 }, 1, 0);
    _ = try addSphere(gpa, &world, .{ 30, 0, 0 }, 1, 1);

    const hit = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{}).?;
    try testing.expectEqual(near, hit.body);
    try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
    try testing.expect(hit.position.approxEql(v(9, 0, 0), tol));

    // The bound is real: nothing is within 5.
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 5, .{}) == null);
    // …and CLOSED: a bound of exactly the surface distance still answers.
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 9, .{}) != null);

    // Inside the solid — boundary included — the distance is 0 and the closest point
    // is the queried point ITSELF, decided upstream of any GJK classification
    // (§1.11.13).
    const interior = query.closestPoint(&world.bp, &world.bm, &world.store, v(10.5, 0, 0), 100, .{}).?;
    try testing.expectEqual(near, interior.body);
    try testing.expectEqual(@as(Real, 0), interior.distance);
    try testing.expect(interior.position.approxEql(v(10.5, 0, 0), tol));
}
