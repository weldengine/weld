//! M1.1.3/E3 acceptance suite for the forge_3d contact-manifold generator
//! (`collide`: GJK → supporting-face clipping, both regimes). Keyed to
//! `config.Real` so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const math = @import("foundation").math;
const api = @import("weld_forge");
const bm_mod = @import("../body_manager.zig");
const shape_mod = @import("../shape.zig");
const broadphase = @import("../pipeline/broadphase.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const BodyManager = bm_mod.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const Broadphase = broadphase.Broadphase(Real);
const BodyId = api.BodyId;
const ApiVec3 = math.Vec3;
const testing = std.testing;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}
fn sphereShape(radius: Real) SupportShape {
    return .{ .core = .point, .radius = radius };
}
fn capsuleShape(half_height: Real, radius: Real) SupportShape {
    return .{ .core = .{ .segment = half_height }, .radius = radius };
}
fn boxShape(hx: Real, hy: Real, hz: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = 0 };
}
fn roundedBoxShape(hx: Real, hy: Real, hz: Real, radius: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = radius };
}

const tol: Real = 1.0e-3;

fn finite3(v: Vec3r) bool {
    const a = v.toArray();
    return std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(a[2]);
}

fn collide(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) ?ContactManifold {
    return narrowphase.collide(Real, sa, pa, ra, sb, pb, rb);
}

test "box-box face contact yields a multi-point manifold" {
    // A unit box at the origin, another stacked 1.5 above ⇒ overlap 0.5 along Y.
    // Face-face contact: 4 points on the contact plane (y = 0.75), each
    // penetration 0.5, normal +Y (A→B).
    const box = boxShape(1, 1, 1);
    const m = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.5, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m.count);
    try testing.expect(m.normal.approxEql(vr(0, 1, 0), tol));
    for (0..m.count) |i| {
        try testing.expectApproxEqAbs(@as(Real, 0.5), m.points[i].penetration, tol);
        try testing.expect(finite3(m.points[i].position));
        // On the contact plane midway between the two faces (y = 0.75).
        try testing.expectApproxEqAbs(@as(Real, 0.75), m.points[i].position.toArray()[1], tol);
    }

    // Same overlap under an oblique global transform ⇒ depth invariant, normal
    // rotated, still 4 points.
    const g = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7);
    const t = vr(-4, 7, 2);
    const m2 = collide(box, g.rotateVec3(vr(0, 0, 0)).add(t), g, box, g.rotateVec3(vr(0, 1.5, 0)).add(t), g).?;
    try testing.expectEqual(@as(u8, 4), m2.count);
    try testing.expect(m2.normal.approxEql(g.rotateVec3(vr(0, 1, 0)), tol));
    for (0..m2.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.5), m2.points[i].penetration, tol);
}

test "manifold feature matrix" {
    // sphere/* ⇒ exactly 1 point.
    {
        // sphere/box: sphere centre 0.6 inside the +Z face ⇒ pen 0.6 + r_sum.
        const m = collide(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(0, 0, 0.4), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), m.count);
        try testing.expect(m.normal.approxEql(vr(0, 0, 1), tol));
        try testing.expectApproxEqAbs(@as(Real, 0.6 + 0.5), m.points[0].penetration, tol);
    }
    {
        // sphere/sphere overlapping (cores 1.2 apart, r_sum 2) ⇒ 1 point, pen 0.8.
        const m = collide(sphereShape(1), vr(0, 0, 0), Quatr.identity, sphereShape(1), vr(1.2, 0, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), m.count);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
        try testing.expectApproxEqAbs(@as(Real, 0.8), m.points[0].penetration, tol);
    }
    // capsule/capsule parallel side overlap ⇒ 1-2 points (segment feature).
    {
        // Two Y-axis capsules, cores 0.3 apart in X, r_sum 1 ⇒ shallow line contact.
        const m = collide(capsuleShape(1, 0.5), vr(0, 0, 0), Quatr.identity, capsuleShape(1, 0.5), vr(0.8, 0, 0), Quatr.identity).?;
        try testing.expect(m.count >= 1 and m.count <= 2);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
        for (0..m.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.2), m.points[i].penetration, tol);
    }
    // box/capsule side ⇒ 1-2 points.
    {
        // A Y-capsule whose segment lies just past the box +X face.
        const m = collide(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, capsuleShape(0.5, 0.5), vr(1.3, 0, 0), Quatr.identity).?;
        try testing.expect(m.count >= 1 and m.count <= 2);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
    }
}

/// Whether the first `count` manifold points are pairwise distinct.
fn pointsDistinct(m: ContactManifold) bool {
    for (0..m.count) |i| {
        for (i + 1..m.count) |j| {
            if (m.points[i].position.approxEql(m.points[j].position, 1.0e-4)) return false;
        }
    }
    return true;
}

test "box-box rotated face reduces to four distinct points" {
    // Adversarial-review regime (finding F): a yawed box makes the incident face
    // clip to an OCTAGON (8 coplanar points), which the reduction must collapse to
    // four DISTINCT spread points — not a degenerate set with a duplicated corner.
    // Unit box A at origin; unit box B 1.9 above, yawed 45° about Y ⇒ overlap 0.1.
    const box = boxShape(1, 1, 1);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0);
    const m = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.9, 0), yaw).?;
    try testing.expectEqual(@as(u8, 4), m.count);
    try testing.expect(pointsDistinct(m)); // no duplicated corner (finding F)
    try testing.expect(m.normal.approxEql(vr(0, 1, 0), tol));
    for (0..m.count) |i| {
        try testing.expectApproxEqAbs(@as(Real, 0.1), m.points[i].penetration, tol);
        try testing.expectApproxEqAbs(@as(Real, 0.95), m.points[i].position.toArray()[1], tol); // contact plane
    }
}

test "staggered capsule segment clips without a duplicate point" {
    // Adversarial-review regime (finding E): two parallel Y-capsules staggered
    // along their axis so B's segment straddles A's endpoint plane. The segment
    // clip must yield two DISTINCT points, not a doubled crossing point.
    const cap = capsuleShape(1, 0.5);
    const m = collide(cap, vr(0, 0, 0), Quatr.identity, cap, vr(0, 0.5, 0.8), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 2), m.count);
    try testing.expect(pointsDistinct(m));
    try testing.expect(m.normal.approxEql(vr(0, 0, 1), tol));
    for (0..m.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.2), m.points[i].penetration, tol); // r_sum(1) − dist(0.8)
}

test "edge-edge penetration is measured along the contact axis" {
    // Fix-1: for an oblique (edge/vertex) contact the EPA normal `n_a` is not a
    // box-face normal, so measuring depth along the reference face normal `rn`
    // diverges. The manifold depth must match the EPA depth along `n_a`.
    const box = boxShape(1, 1, 1);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 4.0);
    const pa = vr(0, 0, 0);
    const pb = vr(1.35, 1.35, 0); // corner overlap ⇒ oblique closest features
    // Reference EPA result.
    const g = narrowphase.gjk(Real, box, pa, Quatr.identity, box, pb, yaw);
    try testing.expectEqual(narrowphase.GjkResult(Real).Status.deep, g.status);
    const relpose = narrowphase.RelativePose(Real).init(pa, Quatr.identity, pb, yaw);
    const e = narrowphase.epa(Real, box, pa, Quatr.identity, relpose, box, g);
    // Confirm the contact axis is genuinely oblique (not a face normal) so this
    // exercises the edge path, not the face-face quad path.
    const na = e.normal.toArray();
    const max_comp = @max(@abs(na[0]), @max(@abs(na[1]), @abs(na[2])));
    try testing.expect(max_comp < 0.999);

    const m = collide(box, pa, Quatr.identity, box, pb, yaw).?;
    // Normal agrees with EPA (no canonical swap here: A's position sorts first).
    try testing.expect(m.normal.approxEql(e.normal, tol));
    // Depth along the contact axis matches EPA (r_sum = 0), not the ~rn-projected
    // value the old code produced.
    var max_pen: Real = 0;
    for (0..m.count) |i| max_pen = @max(max_pen, m.points[i].penetration);
    try testing.expectApproxEqAbs(e.depth, max_pen, tol);
}

test "manifold feature ids are frame-stable" {
    // Fix-2: feature_id must identify the physical feature, surviving a small pose
    // change (a clip-buffer index would reorder). A smaller incident box seated on
    // a larger reference face (so its four corners stay INSIDE the reference face
    // under a tiny lateral shift, i.e. the incident vertices remain the kept
    // features) translated ±0.0001 ⇒ the same set of feature_ids (same corners).
    const big = boxShape(1, 1, 1);
    const small = boxShape(0.5, 1, 0.5);
    const m1 = collide(big, vr(0, 0, 0), Quatr.identity, small, vr(0, 1.5, 0), Quatr.identity).?;
    const m2 = collide(big, vr(0, 0, 0), Quatr.identity, small, vr(0.0001, 1.5, -0.0001), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m1.count);
    try testing.expectEqual(m1.count, m2.count);
    // Every m1 feature_id appears in m2 (same physical corners → same ids).
    for (0..m1.count) |i| {
        var found = false;
        for (0..m2.count) |j| {
            if (m1.points[i].feature_id == m2.points[j].feature_id) found = true;
        }
        try testing.expect(found);
    }
    // The four ids are distinct (four distinct corners).
    for (0..m1.count) |i| {
        for (i + 1..m1.count) |j| try testing.expect(m1.points[i].feature_id != m1.points[j].feature_id);
    }
}

test "manifold reduction stays precise far from the origin" {
    // Fix-4: keep the reduction in A's frame. Two coincident tiny boxes at a large
    // world coordinate: the four A-frame contact corners (±0.001) are sub-ULP in
    // f32 world space (they round together → a world-frame dedup collapses to 1),
    // but are distinct in A's frame ⇒ a 4-point face manifold survives.
    const tiny = boxShape(0.001, 0.001, 0.001);
    const far = vr(100000, 100000, 100000);
    const m = collide(tiny, far, Quatr.identity, tiny, far, Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m.count); // A-frame reduction keeps 4 (world-frame would collapse to 1)
    // The four ids are distinct (distinct A-frame corners); world positions round
    // together at f32 (that is exactly why the reduction must stay in A's frame).
    for (0..m.count) |i| {
        for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
        try testing.expectApproxEqAbs(@as(Real, 0.002), m.points[i].penetration, 1.0e-4); // full overlap 2·he
    }
}

test "manifold is order-independent" {
    const g = Quatr.fromAxisAngle(vr(2, -1, 3).normalize(), 0.8);
    const Combo = struct { sa: SupportShape, pa: Vec3r, sb: SupportShape, pb: Vec3r };
    const combos = [_]Combo{
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(0, 1.5, 0) }, // face-face
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = sphereShape(0.5), .pb = vr(0, 0, 0.4) }, // sphere/box
        .{ .sa = sphereShape(1), .pa = vr(0, 0, 0), .sb = sphereShape(1), .pb = vr(1.2, 0, 0) }, // sphere/sphere
        .{ .sa = capsuleShape(1, 0.5), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.5), .pb = vr(0.8, 0, 0) }, // capsule/capsule
        .{ .sa = capsuleShape(1, 0.3), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.3), .pb = vr(0, 0, 0) }, // degenerate crossing (F5)
        // Same position, equal |half_extents| but distinct extents — exercises
        // the canonical-order total-order tie-break on the box core parameters
        // (a `|he|`-only key would collide here and break order-independence).
        .{ .sa = boxShape(1, 2, 3), .pa = vr(0, 0, 0), .sb = boxShape(3, 2, 1), .pb = vr(0, 0, 0) },
    };
    const rot_z90 = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);
    for (combos, 0..) |c, ci| {
        // The crossing-capsule combo needs B rotated to actually cross A.
        const rb = if (ci == 4) rot_z90 else Quatr.identity;
        for ([_]Quatr{ Quatr.identity, g }) |ra| {
            const ab = collide(c.sa, c.pa, ra, c.sb, c.pb, ra.mul(rb)).?;
            const ba = collide(c.sb, c.pb, ra.mul(rb), c.sa, c.pa, ra).?;
            try testing.expectEqual(ab.count, ba.count);
            try testing.expect(ab.normal.approxEql(ba.normal.neg(), tol));
            // Same point set (order may differ) and same per-point penetration.
            for (0..ab.count) |i| {
                var matched = false;
                for (0..ba.count) |j| {
                    if (ab.points[i].position.approxEql(ba.points[j].position, tol) and
                        @abs(ab.points[i].penetration - ba.points[j].penetration) <= tol) matched = true;
                }
                try testing.expect(matched);
            }
        }
    }
}

test "shallow and deep manifolds are continuous" {
    // Sweep two unit-radius spheres from a shallow gap toward coincidence. The
    // per-point penetration r_sum − dist is continuous and monotone, the normal
    // stays +X (no flip) until coincidence.
    const rs = sphereShape(1);
    const ds = [_]Real{ 1.5, 1.0, 0.5, 0.1, 0.01 };
    var prev: Real = -1;
    for (ds) |d| {
        const m = collide(rs, vr(0, 0, 0), Quatr.identity, rs, vr(d, 0, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), m.count);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
        const pen = m.points[0].penetration;
        try testing.expectApproxEqAbs(@as(Real, 2.0) - d, pen, tol); // r_sum − dist
        try testing.expect(pen > prev); // monotone as d shrinks
        prev = pen;
    }
    // Coincident centres (deep, depth 0) ⇒ penetration → r_sum, continuous.
    const mc = collide(rs, vr(0, 0, 0), Quatr.identity, rs, vr(0, 0, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 1), mc.count);
    try testing.expectApproxEqAbs(@as(Real, 2.0), mc.points[0].penetration, tol);
    try testing.expect(finite3(mc.normal));
    try testing.expectApproxEqAbs(@as(Real, 1), mc.normal.length(), tol);

    // Separated ⇒ null.
    try testing.expect(collide(rs, vr(0, 0, 0), Quatr.identity, rs, vr(2.5, 0, 0), Quatr.identity) == null);

    // A rounded-box shallow overlap threads the box-core shallow path (radius-0
    // boxes cannot be shallow) and still produces a valid manifold.
    const rb = roundedBoxShape(0.5, 0.5, 0.5, 1.0);
    const m = collide(rb, vr(0, 0, 0), Quatr.identity, rb, vr(0, 2.5, 0), Quatr.identity).?;
    try testing.expect(m.count >= 1 and m.count <= 4);
    try testing.expect(m.normal.approxEql(vr(0, 1, 0), tol));
    for (0..m.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.5), m.points[i].penetration, tol); // r_sum(2) − dist(1.5)
}

// --- E4: broadphase → collidePair integration ---

/// Add a `.dynamic` box body at (x,y,z). Descriptor positions are the f32 api Vec3.
fn addBoxBodyAt(gpa: std.mem.Allocator, bm: *BodyManager, store: *const ShapeStore, shape: api.ShapeId, entity_index: u32, x: f32, y: f32, z: f32) !BodyId {
    var d = api.BodyDescriptor{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    };
    d.position = ApiVec3.fromArray(.{ x, y, z });
    return bm.addBody(gpa, store, d);
}

/// Whether `p` is the unordered pair `{x, y}` (candidate pairs are canonical).
fn isPair(p: Broadphase.Pair, x: BodyId, y: BodyId) bool {
    return p.a == @min(x, y) and p.b == @max(x, y);
}

test "broadphase pairs to manifolds via collidePair" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var bp = Broadphase.init(.{});
    defer bp.deinit(gpa);

    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(0.5) } });

    // A–B: tight AABBs 0.15 apart (disjoint) but fat AABBs (margin 0.1) overlap ⇒
    // a broadphase fat-AABB false positive the narrowphase must reject (null).
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);
    const id_b = try addBoxBodyAt(gpa, &bm, &store, box, 1, 1.15, 0, 0);
    // C–D: boxes genuinely overlap (0.7 along X) ⇒ a real deep contact manifold.
    const id_c = try addBoxBodyAt(gpa, &bm, &store, box, 2, 10, 0, 0);
    const id_d = try addBoxBodyAt(gpa, &bm, &store, box, 3, 10.3, 0, 0);

    const ids = [_]BodyId{ id_a, id_b, id_c, id_d };
    for (ids) |id| _ = try bp.insert(gpa, .dynamic, bm.bodyAabb(&store, id).?, id);

    var pairs: std.ArrayListUnmanaged(Broadphase.Pair) = .empty;
    defer pairs.deinit(gpa);
    try bp.computePairs(gpa, &pairs);

    var found_false_positive = false;
    var found_overlap = false;
    for (pairs.items) |p| {
        const m = bm.collidePair(&store, p.a, p.b); // all four bodies still live
        if (isPair(p, id_a, id_b)) {
            found_false_positive = true;
            try testing.expect(m == null); // separated ⇒ no manifold
        } else if (isPair(p, id_c, id_d)) {
            found_overlap = true;
            const man = m.?;
            try testing.expect(man.count >= 1 and man.count <= 4);
            try testing.expectApproxEqAbs(@as(Real, 0.7), man.points[0].penetration, tol); // overlap along X
            try testing.expect(finite3(man.normal));
        }
    }
    // The broadphase surfaced the fat-AABB false positive (rejected as null) and
    // the genuine overlap (a valid manifold).
    try testing.expect(found_false_positive);
    try testing.expect(found_overlap);

    // Stale-handle pair ⇒ null.
    bm.removeBody(id_d);
    try testing.expect(bm.collidePair(&store, id_c, id_d) == null);
}

test "collidePair imposes a body-id order on identical geometry" {
    // Fix-3: two bodies with bit-identical shape AND pose overlap degenerately —
    // `collide`'s pose key cannot order them, so its normal is the same in both
    // call orders. `collidePair` breaks the tie by body id (min first) and negates
    // for the swapped caller, so the pair stays order-independent for real bodies.
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(0.5) } });
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);
    const id_b = try addBoxBodyAt(gpa, &bm, &store, box, 1, 0, 0, 0); // same pose as A

    const ab = bm.collidePair(&store, id_a, id_b).?;
    const ba = bm.collidePair(&store, id_b, id_a).?;
    try testing.expect(ab.normal.approxEql(ba.normal.neg(), tol)); // negated by body-id order
    try testing.expectEqual(ab.count, ba.count);
    try testing.expect(finite3(ab.normal));
}
