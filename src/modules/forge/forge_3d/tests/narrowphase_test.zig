//! M1.1.2 acceptance suite for the forge_3d narrowphase (distance-based GJK).
//! Grows gate by gate: **E1** covers the support functions + the relative-pose
//! transform; E2 the Voronoi-region simplex solver; E3 the GJK descent loop and
//! `GjkResult`; E4 the broadphase→narrowphase integration. Keyed to
//! `config.Real` so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase.zig");
const math = @import("foundation").math;
const api = @import("weld_forge");
const bm_mod = @import("../body_manager.zig");
const shape_mod = @import("../shape.zig");
const broadphase = @import("../pipeline/broadphase.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const RelativePose = narrowphase.RelativePose(Real);
const Simplex = narrowphase.Simplex(Real);
const GjkResult = narrowphase.GjkResult(Real);
const BodyManager = bm_mod.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const Broadphase = broadphase.Broadphase(Real);
const BodyId = api.BodyId;
const ApiVec3 = math.Vec3; // f32 descriptor vector
const testing = std.testing;

/// Solver-precision Vec3 from literals.
fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

// Loosened for f32; f64 passes the same bound comfortably. Rotated support
// points go through `rotateVec3` (float ops), so exact equality is not used
// there — the tie-break test below uses exact equality on purpose.
const tol: Real = 1e-5;

test "support functions return extremal points" {
    // Point core (sphere): always the local origin, for any direction.
    const p = SupportShape{ .core = .point, .radius = 0.5 };
    try testing.expect(p.support(vr(1, 0, 0)).approxEql(Vec3r.zero, tol));
    try testing.expect(p.support(vr(-3, 2, 7)).approxEql(Vec3r.zero, tol));

    // Segment core (capsule): ±half_height along Y, chosen by the sign of dir.y.
    const seg = SupportShape{ .core = .{ .segment = 0.9 }, .radius = 0.3 };
    try testing.expect(seg.support(vr(0, 1, 0)).approxEql(vr(0, 0.9, 0), tol));
    try testing.expect(seg.support(vr(0, -1, 0)).approxEql(vr(0, -0.9, 0), tol));
    // Oblique: only the sign of Y matters.
    try testing.expect(seg.support(vr(5, 2, -4)).approxEql(vr(0, 0.9, 0), tol));
    try testing.expect(seg.support(vr(5, -0.1, -4)).approxEql(vr(0, -0.9, 0), tol));

    // Box core: per-component sign select on the half-extents.
    const box = SupportShape{ .core = .{ .box = vr(1, 2, 3) }, .radius = 0 };
    try testing.expect(box.support(vr(1, 1, 1)).approxEql(vr(1, 2, 3), tol));
    try testing.expect(box.support(vr(-1, 1, -1)).approxEql(vr(-1, 2, -3), tol));
    try testing.expect(box.support(vr(-2, -5, 8)).approxEql(vr(-1, -2, 3), tol));
    // Cardinal direction picks one face.
    try testing.expect(box.support(vr(1, 0, 0)).approxEql(vr(1, 2, 3), tol));

    // Through a non-trivial relative rotation: B is the box above, rotated +90°
    // about +Z (A frame = identity, both at the origin). For dir = +X in A's
    // frame, the direction inverse-rotates to B-local (0,-1,0) → B-local support
    // (1,-2,3) → mapped back to A (+90° about Z: (x,y,z)→(-y,x,z)) = (2,1,3).
    const rp_rot = RelativePose.init(
        Vec3r.zero,
        Quatr.identity,
        Vec3r.zero,
        Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0),
    );
    try testing.expect(rp_rot.supportB(box, vr(1, 0, 0)).approxEql(vr(2, 1, 3), tol));

    // Segment core (capsule) through a non-trivial relative rotation — the real
    // capsule GJK path the box/point cases above never exercise: inverse-rotate
    // the direction into B-local, sign-of-local-Y endpoint select, map back. B
    // is `seg`, rotated +90° about +Z relative to A. For dir = +X in A's frame,
    // the direction inverse-rotates to B-local (0,−1,0) ⇒ B-local support
    // (0,−0.9,0) ⇒ mapped back to A ((x,y,z)→(−y,x,z)) = (0.9,0,0).
    const rp_seg = RelativePose.init(
        Vec3r.zero,
        Quatr.identity,
        Vec3r.zero,
        Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0),
    );
    try testing.expect(rp_seg.supportB(seg, vr(1, 0, 0)).approxEql(vr(0.9, 0, 0), tol));
    try testing.expect(rp_seg.supportB(seg, vr(-1, 0, 0)).approxEql(vr(-0.9, 0, 0), tol));

    // Through a non-trivial rotation on A *and* a translation, exercising the
    // full `pos_rel = conj(rot_a)·(pos_b − pos_a)` formula. Both bodies rotated
    // +90° about +Y ⇒ rot_rel = identity; pos_b − pos_a = (0,0,5), inverse-
    // rotated by conj(+90° Y) = −90° Y ⇒ (−5,0,0). A point core sits at pos_rel.
    const rp_pose = RelativePose.init(
        vr(10, 0, 0),
        Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 2.0),
        vr(10, 0, 5),
        Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 2.0),
    );
    try testing.expect(rp_pose.supportB(p, vr(1, 0, 0)).approxEql(vr(-5, 0, 0), tol));
    try testing.expect(rp_pose.supportB(p, vr(1, 1, 1)).approxEql(vr(-5, 0, 0), tol));
}

test "support tie-breaks are fixed" {
    // Box: a zero direction component resolves to the +half_extent corner.
    const box = SupportShape{ .core = .{ .box = vr(1, 2, 3) }, .radius = 0 };
    try testing.expect(box.support(vr(0, 0, 0)).eql(vr(1, 2, 3)));
    try testing.expect(box.support(vr(0, -1, 0)).eql(vr(1, -2, 3)));
    try testing.expect(box.support(vr(-1, 0, 0)).eql(vr(-1, 2, 3)));

    // Capsule: a direction orthogonal to the Y axis (dir.y == 0) resolves to
    // the +Y endpoint.
    const seg = SupportShape{ .core = .{ .segment = 0.9 }, .radius = 0.3 };
    try testing.expect(seg.support(vr(1, 0, 0)).eql(vr(0, 0.9, 0)));
    try testing.expect(seg.support(vr(0, 0, -1)).eql(vr(0, 0.9, 0)));
    try testing.expect(seg.support(vr(-1, 0, 3)).eql(vr(0, 0.9, 0)));

    // Byte-stable across runs: pure sign selection, no float arithmetic, so two
    // invocations on the same input are bit-identical.
    try testing.expect(box.support(vr(0, -1, 0)).eql(box.support(vr(0, -1, 0))));
    try testing.expect(seg.support(vr(1, 0, 0)).eql(seg.support(vr(1, 0, 0))));
}

// --- E2: Voronoi-region simplex solver ---------------------------------------

/// Every component of `v` is finite (no NaN, no inf) — the degenerate-input bar.
fn finite3(v: Vec3r) bool {
    const a = v.toArray();
    return std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(a[2]);
}

/// Sum of the barycentric weights of the surviving feature (must be ≈ 1).
fn barySum(r: Simplex.Result) Real {
    var s: Real = 0;
    for (0..r.count) |i| s += r.bary[i];
    return s;
}

/// Whether the surviving feature is exactly the set `expected` (order-agnostic).
fn hasFeature(r: Simplex.Result, expected: []const u8) bool {
    if (r.count != expected.len) return false;
    for (expected) |e| {
        var found = false;
        for (0..r.count) |i| {
            if (r.indices[i] == e) found = true;
        }
        if (!found) return false;
    }
    return true;
}

test "closest point on segment/triangle/tetrahedron regions" {
    // --- segment: vertex A, vertex B, edge interior ---
    {
        const a_reg = Simplex.closestOriginSegment(vr(1, 0, 0), vr(2, 0, 0));
        try testing.expect(a_reg.closest.approxEql(vr(1, 0, 0), tol));
        try testing.expect(hasFeature(a_reg, &.{0}));

        const b_reg = Simplex.closestOriginSegment(vr(-2, 0, 0), vr(-1, 0, 0));
        try testing.expect(b_reg.closest.approxEql(vr(-1, 0, 0), tol));
        try testing.expect(hasFeature(b_reg, &.{1}));

        const e = Simplex.closestOriginSegment(vr(-1, 1, 0), vr(1, 1, 0));
        try testing.expect(e.closest.approxEql(vr(0, 1, 0), tol));
        try testing.expect(hasFeature(e, &.{ 0, 1 }));
        try testing.expectApproxEqAbs(@as(Real, 1), barySum(e), tol);
    }

    // --- triangle: 3 vertex regions, 3 edge regions, 1 face region ---
    {
        // Vertex A / B / C.
        const va = Simplex.closestOriginTriangle(vr(1, 1, 1), vr(2, 1, 1), vr(1, 2, 1));
        try testing.expect(va.closest.approxEql(vr(1, 1, 1), tol));
        try testing.expect(hasFeature(va, &.{0}));

        const vb = Simplex.closestOriginTriangle(vr(2, 0, 0), vr(1, 0, 0), vr(2, 1, 0));
        try testing.expect(vb.closest.approxEql(vr(1, 0, 0), tol));
        try testing.expect(hasFeature(vb, &.{1}));

        const vc = Simplex.closestOriginTriangle(vr(0, 2, 0), vr(1, 2, 0), vr(0, 1, 0));
        try testing.expect(vc.closest.approxEql(vr(0, 1, 0), tol));
        try testing.expect(hasFeature(vc, &.{2}));

        // Edge AB / AC / BC — each resolves to the midpoint (0,1,0).
        const eab = Simplex.closestOriginTriangle(vr(-1, 1, 0), vr(1, 1, 0), vr(0, 2, 0));
        try testing.expect(eab.closest.approxEql(vr(0, 1, 0), tol));
        try testing.expect(hasFeature(eab, &.{ 0, 1 }));
        try testing.expectApproxEqAbs(@as(Real, 1), barySum(eab), tol);

        const eac = Simplex.closestOriginTriangle(vr(1, 1, 0), vr(1, 2, 0), vr(-1, 1, 0));
        try testing.expect(eac.closest.approxEql(vr(0, 1, 0), tol));
        try testing.expect(hasFeature(eac, &.{ 0, 2 }));

        const ebc = Simplex.closestOriginTriangle(vr(0, 2, 0), vr(-1, 1, 0), vr(1, 1, 0));
        try testing.expect(ebc.closest.approxEql(vr(0, 1, 0), tol));
        try testing.expect(hasFeature(ebc, &.{ 1, 2 }));

        // Face region: origin projects inside a triangle in the z=1 plane.
        const face = Simplex.closestOriginTriangle(vr(-1, -1, 1), vr(1, -1, 1), vr(0, 1, 1));
        try testing.expect(face.closest.approxEql(vr(0, 0, 1), tol));
        try testing.expect(hasFeature(face, &.{ 0, 1, 2 }));
        try testing.expectApproxEqAbs(@as(Real, 1), barySum(face), tol);
    }

    // --- tetrahedron: vertex, edge, face, interior ---
    {
        // Vertex: a corner tetra in the (≥1,≥1,≥1) octant ⇒ closest is vertex a.
        const tv = Simplex.closestOriginTetra(vr(1, 1, 1), vr(3, 1, 1), vr(1, 3, 1), vr(1, 1, 3));
        try testing.expect(tv.closest.approxEql(vr(1, 1, 1), tol));
        try testing.expect(hasFeature(tv, &.{0}));

        // Edge: closest is the midpoint of edge a–b at (0,1,1).
        const te = Simplex.closestOriginTetra(vr(-1, 1, 1), vr(1, 1, 1), vr(0, 2, 1), vr(0, 1, 3));
        try testing.expect(te.closest.approxEql(vr(0, 1, 1), tol));
        try testing.expect(hasFeature(te, &.{ 0, 1 }));

        // Face: origin projects inside face a–b–c in the z=1 plane.
        const tf = Simplex.closestOriginTetra(vr(-1, -1, 1), vr(1, -1, 1), vr(0, 1, 1), vr(0, 0, 3));
        try testing.expect(tf.closest.approxEql(vr(0, 0, 1), tol));
        try testing.expect(hasFeature(tf, &.{ 0, 1, 2 }));
        try testing.expectApproxEqAbs(@as(Real, 1), barySum(tf), tol);

        // Interior: a tetra whose centroid is the origin ⇒ closest is the origin,
        // all four vertices survive, each weight 1/4.
        const ti = Simplex.closestOriginTetra(vr(1, 1, 1), vr(1, -1, -1), vr(-1, 1, -1), vr(-1, -1, 1));
        try testing.expect(ti.closest.approxEql(Vec3r.zero, tol));
        try testing.expect(hasFeature(ti, &.{ 0, 1, 2, 3 }));
        try testing.expectApproxEqAbs(@as(Real, 1), barySum(ti), tol);
        for (0..ti.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.25), ti.bary[i], tol);
    }
}

test "simplex solver handles degenerate inputs" {
    // Duplicated segment endpoint (a == b) ⇒ the point a, no NaN.
    const dup_seg = Simplex.closestOriginSegment(vr(1, 2, 3), vr(1, 2, 3));
    try testing.expect(dup_seg.closest.approxEql(vr(1, 2, 3), tol));
    try testing.expect(finite3(dup_seg.closest));
    try testing.expectEqual(@as(u8, 1), dup_seg.count);
    try testing.expectApproxEqAbs(@as(Real, 1), barySum(dup_seg), tol);

    // Duplicated triangle vertex (a == b) ⇒ collapses to a segment; finite,
    // ≤ 2-vertex feature.
    const dup_tri = Simplex.closestOriginTriangle(vr(1, 1, 0), vr(1, 1, 0), vr(2, 2, 0));
    try testing.expect(finite3(dup_tri.closest));
    try testing.expect(dup_tri.count >= 1 and dup_tri.count <= 2);
    try testing.expectApproxEqAbs(@as(Real, 1), barySum(dup_tri), tol);

    // Collinear triangle (three points on a line) ⇒ closest on the line, finite,
    // ≤ 2-vertex feature.
    const collinear = Simplex.closestOriginTriangle(vr(-2, 1, 0), vr(2, 1, 0), vr(4, 1, 0));
    try testing.expect(collinear.closest.approxEql(vr(0, 1, 0), tol));
    try testing.expect(finite3(collinear.closest));
    try testing.expect(collinear.count >= 1 and collinear.count <= 2);
    try testing.expectApproxEqAbs(@as(Real, 1), barySum(collinear), tol);

    // Coplanar tetrahedron (all four vertices in the z=1 plane) ⇒ interior branch
    // falls back to the closest face; finite, sane feature, weights sum to 1.
    const coplanar = Simplex.closestOriginTetra(vr(-1, -1, 1), vr(1, -1, 1), vr(0, 1, 1), vr(0, 0, 1));
    try testing.expect(finite3(coplanar.closest));
    try testing.expect(coplanar.count >= 1 and coplanar.count <= 3);
    try testing.expectApproxEqAbs(@as(Real, 1), barySum(coplanar), tol);
}

test "simplex feature reconstructs closest from barycentrics" {
    // The triplet contract: Σ bary·w over the surviving vertices equals the
    // returned closest — the property the GJK loop relies on to rebuild the
    // closest points on A and B from the same weights (E3).
    const v0 = Simplex.Vertex{ .w = vr(-1, 1, 0), .support_a = vr(-1, 1, 0), .support_b = Vec3r.zero };
    const v1 = Simplex.Vertex{ .w = vr(1, 1, 0), .support_a = vr(1, 1, 0), .support_b = Vec3r.zero };
    const v2 = Simplex.Vertex{ .w = vr(0, 2, 0), .support_a = vr(0, 2, 0), .support_b = Vec3r.zero };
    const verts = [3]Simplex.Vertex{ v0, v1, v2 };

    const r = Simplex.closestOriginTriangle(v0.w, v1.w, v2.w);
    var recon = Vec3r.zero;
    for (0..r.count) |i| recon = recon.add(verts[r.indices[i]].w.scale(r.bary[i]));
    try testing.expect(recon.approxEql(r.closest, tol));

    // For this triangle the origin's closest is the AB midpoint (0,1,0).
    try testing.expect(r.closest.approxEql(vr(0, 1, 0), tol));
    try testing.expect(hasFeature(r, &.{ 0, 1 }));
}

// --- E3: GJK loop + result ---------------------------------------------------

/// Distance tolerance for GJK results (looser than `tol`: convergence + f32 +
/// an oblique global rotation accumulate error; f64 passes far tighter).
const gjk_test_tol: Real = 1.0e-3;

/// Build a support shape from a core + radius (test brevity).
fn sphereShape(radius: Real) SupportShape {
    return .{ .core = .point, .radius = radius };
}
fn capsuleShape(half_height: Real, radius: Real) SupportShape {
    return .{ .core = .{ .segment = half_height }, .radius = radius };
}
fn boxShape(hx: Real, hy: Real, hz: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = 0 };
}
/// A box core with a convex (inflation) radius — a "rounded box". forge_3d's
/// `supportShape` produces radius-0 boxes, so this is only for exercising the
/// narrowphase's radius-agnostic classification (e.g. box/box in the shallow
/// regime, which a radius-0 box pair cannot reach).
fn roundedBoxShape(hx: Real, hy: Real, hz: Real, radius: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = radius };
}

/// Whether `world_pt` lies on `shape`'s core, given the shape's world pose. The
/// point is mapped into the shape's local frame and tested per core kind.
fn onCore(shape: SupportShape, pos: Vec3r, rot: Quatr, world_pt: Vec3r, eps: Real) bool {
    const local = rot.conjugate().rotateVec3(world_pt.sub(pos)).toArray();
    switch (shape.core) {
        .point => return @abs(local[0]) <= eps and @abs(local[1]) <= eps and @abs(local[2]) <= eps,
        .segment => |h| return @abs(local[0]) <= eps and @abs(local[2]) <= eps and
            local[1] >= -h - eps and local[1] <= h + eps,
        .box => |he_v| {
            const he = he_v.toArray();
            return @abs(local[0]) <= he[0] + eps and @abs(local[1]) <= he[1] + eps and @abs(local[2]) <= he[2] + eps;
        },
    }
}

/// Assert a separated pair: status, analytic distance, `|closest_a − closest_b|
/// == distance`, and each closest point on its core.
fn checkSeparated(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr, dist: Real) !void {
    const r = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    try testing.expectEqual(GjkResult.Status.separated, r.status);
    try testing.expectApproxEqAbs(dist, r.distance, gjk_test_tol);
    try testing.expectApproxEqAbs(dist, r.closest_a.sub(r.closest_b).length(), gjk_test_tol);
    try testing.expect(onCore(sa, pa, ra, r.closest_a, gjk_test_tol));
    try testing.expect(onCore(sb, pb, rb, r.closest_b, gjk_test_tol));
}

/// Assert a shallow pair: status, analytic core distance, `|closest_a −
/// closest_b| == distance`, and each closest point on its core.
fn checkShallow(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr, dist: Real) !void {
    const r = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    try testing.expectEqual(GjkResult.Status.shallow, r.status);
    try testing.expectApproxEqAbs(dist, r.distance, gjk_test_tol);
    try testing.expectApproxEqAbs(dist, r.closest_a.sub(r.closest_b).length(), gjk_test_tol);
    try testing.expect(onCore(sa, pa, ra, r.closest_a, gjk_test_tol));
    try testing.expect(onCore(sb, pb, rb, r.closest_b, gjk_test_tol));
}

/// Whether the terminal simplex encloses the origin — the origin-closest point
/// on it (re-solved) is the origin.
fn enclosesOrigin(simplex: [4]Simplex.Vertex, count: u8) bool {
    const res = switch (count) {
        1 => Simplex.closestOriginPoint(simplex[0].w),
        2 => Simplex.closestOriginSegment(simplex[0].w, simplex[1].w),
        3 => Simplex.closestOriginTriangle(simplex[0].w, simplex[1].w, simplex[2].w),
        4 => Simplex.closestOriginTetra(simplex[0].w, simplex[1].w, simplex[2].w, simplex[3].w),
        else => return false,
    };
    return res.closest.approxEql(Vec3r.zero, gjk_test_tol);
}

/// Assert a deep pair: status and the terminal simplex encloses the origin.
fn checkDeep(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) !void {
    const r = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    try testing.expectEqual(GjkResult.Status.deep, r.status);
    try testing.expect(r.simplex_count >= 1 and r.simplex_count <= 4);
    try testing.expect(enclosesOrigin(r.simplex, r.simplex_count));
}

test "gjk separated pairs report analytic distance" {
    // A single oblique global rigid transform, applied to both bodies, must
    // leave the (rotation-invariant) core distance unchanged — the "non-trivial
    // rotation" coverage without losing the analytic value.
    const g_rot = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7);
    const g_trans = vr(-4, 7, 2);

    const Combo = struct { sa: SupportShape, pa: Vec3r, sb: SupportShape, pb: Vec3r, dist: Real };
    const combos = [_]Combo{
        // ss: two point cores 3 apart.
        .{ .sa = sphereShape(0.5), .pa = vr(0, 0, 0), .sb = sphereShape(0.5), .pb = vr(3, 0, 0), .dist = 3 },
        // sb: point vs box [4,6]³ ⇒ closest face at x=4.
        .{ .sa = sphereShape(0.5), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(5, 0, 0), .dist = 4 },
        // sc: point vs Y-segment at x=5 ⇒ perpendicular foot (5,0,0).
        .{ .sa = sphereShape(0.5), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.3), .pb = vr(5, 0, 0), .dist = 5 },
        // bb: box +X face x=1 vs box −X face x=4.
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(5, 0, 0), .dist = 3 },
        // bc: box +X face x=1 vs Y-segment at x=5.
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.3), .pb = vr(5, 0, 0), .dist = 4 },
        // cc: two parallel Y-segments at x=0 and x=5.
        .{ .sa = capsuleShape(1, 0.3), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.3), .pb = vr(5, 0, 0), .dist = 5 },
    };

    for (combos) |c| {
        // Canonical (identity rotations).
        try checkSeparated(c.sa, c.pa, Quatr.identity, c.sb, c.pb, Quatr.identity, c.dist);
        // Same scene under the oblique global transform ⇒ identical distance.
        try checkSeparated(
            c.sa,
            g_rot.rotateVec3(c.pa).add(g_trans),
            g_rot,
            c.sb,
            g_rot.rotateVec3(c.pb).add(g_trans),
            g_rot,
            c.dist,
        );
    }
}

test "gjk shallow pairs are detected" {
    // All 6 core-pair combinations in the shallow regime (cores disjoint, the
    // inflated shapes overlapping), canonical and under an oblique global rigid
    // transform (non-trivial rotation) — the Scope's "6 combinations in all 3
    // regimes". Line 70's ss+sb-only phrasing was aligned on the Scope (line 25)
    // via a Claude.ai round-trip (see the brief's Recorded deviations).
    const g_rot = Quatr.fromAxisAngle(vr(3, -1, 2).normalize(), 0.9);
    const g_trans = vr(6, -3, 5);

    const Combo = struct { sa: SupportShape, pa: Vec3r, sb: SupportShape, pb: Vec3r, dist: Real };
    const combos = [_]Combo{
        // ss: point cores 3 apart, inflated spheres overlap (r_sum = 4).
        .{ .sa = sphereShape(2), .pa = vr(0, 0, 0), .sb = sphereShape(2), .pb = vr(3, 0, 0), .dist = 3 },
        // sb: point vs box, cores 4 apart, large sphere radius (r_sum = 5).
        .{ .sa = sphereShape(5), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(5, 0, 0), .dist = 4 },
        // sc: point vs Y-segment, cores 5 apart (r_sum = 5.5).
        .{ .sa = sphereShape(5), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.5), .pb = vr(5, 0, 0), .dist = 5 },
        // bb: rounded boxes (radius 1.5), cores 2 apart (r_sum = 3). A radius-0
        // box pair cannot be shallow, so this exercises the narrowphase box-core
        // shallow path with a convex radius (see `roundedBoxShape`).
        .{ .sa = roundedBoxShape(0.5, 0.5, 0.5, 1.5), .pa = vr(0, 0, 0), .sb = roundedBoxShape(0.5, 0.5, 0.5, 1.5), .pb = vr(3, 0, 0), .dist = 2 },
        // bc: box vs Y-segment, cores 4 apart, capsule radius 5 (r_sum = 5).
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 5), .pb = vr(5, 0, 0), .dist = 4 },
        // cc: two parallel Y-segments 3 apart, inflated (r_sum = 4).
        .{ .sa = capsuleShape(1, 2), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 2), .pb = vr(3, 0, 0), .dist = 3 },
    };

    for (combos) |c| {
        try checkShallow(c.sa, c.pa, Quatr.identity, c.sb, c.pb, Quatr.identity, c.dist);
        try checkShallow(
            c.sa,
            g_rot.rotateVec3(c.pa).add(g_trans),
            g_rot,
            c.sb,
            g_rot.rotateVec3(c.pb).add(g_trans),
            g_rot,
            c.dist,
        );
    }

    // Exact-touch boundary: core distance == r_a + r_b (5) ⇒ shallow, not
    // separated (touching counts — honored by the contact margin).
    {
        const r = narrowphase.gjk(Real, sphereShape(2), vr(0, 0, 0), Quatr.identity, sphereShape(3), vr(5, 0, 0), Quatr.identity);
        try testing.expectEqual(GjkResult.Status.shallow, r.status);
        try testing.expectApproxEqAbs(@as(Real, 5), r.distance, gjk_test_tol);
    }
}

test "gjk near-contact pairs are not deep" {
    // (a) A point core ~1 cm outside an ORIENTED box (the P1 repro). The box is
    // rotated 45° about +Z (presenting a diamond edge toward −X) and centered at
    // √2 + 0.01, so its nearest edge sits at x = 0.01 ⇒ core distance 0.01. With
    // radius 0 this is `.separated`, never a false `.deep` (Fixes 1+2 kill the
    // degenerate Minkowski tetrahedron that used to slip through).
    {
        const c: Real = std.math.sqrt2 + 0.01;
        const r = narrowphase.gjk(
            Real,
            sphereShape(0),
            vr(0, 0, 0),
            Quatr.identity,
            boxShape(1, 1, 1),
            vr(c, 0, 0),
            Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 4.0),
        );
        try testing.expect(r.status != .deep);
        try testing.expectEqual(GjkResult.Status.separated, r.status);
        try testing.expectApproxEqAbs(@as(Real, 0.01), r.distance, gjk_test_tol);
    }
    // (b) Two point cores 5e-5 apart with a large inflation sum (r_sum = 1.1):
    // proximity is NOT intersection ⇒ `.shallow`, never `.deep`. The old absolute
    // deep threshold (1e-8) mis-fired here; Fix 3's relative threshold does not.
    {
        const r = narrowphase.gjk(
            Real,
            sphereShape(0.5),
            vr(0, 0, 0),
            Quatr.identity,
            sphereShape(0.6),
            vr(5.0e-5, 0, 0),
            Quatr.identity,
        );
        try testing.expect(r.status != .deep);
        try testing.expectEqual(GjkResult.Status.shallow, r.status);
    }
    // (c) LARGE shape (the Fix 3b repro — the character-on-a-large-ground case).
    // A point core ~1 cm outside a big ORIENTED box (half-extents 50, rotated 45°
    // about +Z, nearest diamond edge at x = 0.01 ⇒ core distance 0.01). Fix 3's
    // deep threshold was relative to the Minkowski-vertex magnitude, which scaled
    // with the box's distant-face support and mis-classified this as `.deep`; Fix
    // 3b's numerical-noise floor (scaled by machine epsilon, not shape size) does
    // not.
    {
        const h: Real = 50;
        const c: Real = h * std.math.sqrt2 + 0.01;
        const r = narrowphase.gjk(
            Real,
            sphereShape(0),
            vr(0, 0, 0),
            Quatr.identity,
            boxShape(h, h, h),
            vr(c, 0, 0),
            Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 4.0),
        );
        try testing.expect(r.status != .deep);
        try testing.expectEqual(GjkResult.Status.separated, r.status);
        try testing.expectApproxEqAbs(@as(Real, 0.01), r.distance, gjk_test_tol);
    }
    // (d) SMALL separation at LARGE scale (scale-robustness of the contact margin
    // after the P1b `conv_k` 2→16 recalibration). The same oriented box-50 with
    // the point 1e-3 outside — comfortably above the 16-ULP accumulated-rounding
    // contact margin (~1.3e-4 at this coordinate scale ~70, ≈119 ULP·coordScale,
    // past the 64-ULP no-false-shallow bound). It is `.separated`, neither `.deep`
    // nor `.shallow`: the margin scales with the coordinate magnitude, so a
    // discernible gap at scale 50 is not swallowed. A sub-margin gap here (e.g.
    // the former 2e-5, ~2 ULP·coordScale) now correctly reads as touch —
    // indistinguishable from tangency at f32 (cf. `gjk oriented tangency stays
    // shallow`). At f64 the floor is ~9 orders tighter.
    {
        const c: Real = 50 * std.math.sqrt2 + 1.0e-3;
        const r = narrowphase.gjk(
            Real,
            sphereShape(0),
            vr(0, 0, 0),
            Quatr.identity,
            boxShape(50, 50, 50),
            vr(c, 0, 0),
            Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 4.0),
        );
        try testing.expectEqual(GjkResult.Status.separated, r.status);
    }
}

test "gjk contact margin is absolute not radius-proportional" {
    // P1 (Codex review): the shallow/separated boundary must absorb only GJK's
    // convergence noise on `dist` (∝ the cores' coordinate scale), never a
    // fraction of r_sum. Two point cores r=500 (r_sum=1000): a genuine 5 cm gap
    // (centers 1000.05) is unambiguously `.separated`. Under the former
    // r_sum-proportional margin (`contact_rel·r_sum` = 0.1 m at r_sum=1000) this
    // 5 cm separation was swallowed as `.shallow` — a collision margin beyond the
    // core radius, out of scope (§32).
    try checkSeparated(sphereShape(500), vr(0, 0, 0), Quatr.identity, sphereShape(500), vr(1000.05, 0, 0), Quatr.identity, 1000.05);
    // Exact tangency (core distance == r_sum) stays `.shallow` (frozen touch =
    // shallow), so the absolute margin has not simply become "always separated".
    try checkShallow(sphereShape(500), vr(0, 0, 0), Quatr.identity, sphereShape(500), vr(1000, 0, 0), Quatr.identity, 1000);
    // Same 5 cm gap under an oblique global rigid transform ⇒ still `.separated`
    // (the additive margin is rotation-invariant, coordinate-scale-based).
    {
        const g_rot = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7);
        const g_trans = vr(-4, 7, 2);
        try checkSeparated(sphereShape(500), g_rot.rotateVec3(vr(0, 0, 0)).add(g_trans), g_rot, sphereShape(500), g_rot.rotateVec3(vr(1000.05, 0, 0)).add(g_trans), g_rot, 1000.05);
    }
}

test "gjk oriented tangency stays shallow" {
    // P1b (Codex review): the exact tangency the `conv_k = 2` margin mis-classified
    // as `.separated`. GJK over-estimates `dist` by the ACCUMULATED rounding of its
    // pipeline (7.15e-7 here, ≈ 2 ULP × coordScale, zero convergence residue) — the
    // contact margin at `conv_k = 16` absorbs it; the pair is `.shallow` (touch).
    {
        const box_rot = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.73);
        const he = vr(0.7, 1.1, 0.6);
        const p = vr(-3.6000001, 2.16, 0.65999997);
        // Exact core distance = |p_local − clamp(p_local, −he, he)| in the box's
        // local frame (box at origin), computed at `Real` precision so the sphere
        // radius makes an EXACT tangency at BOTH f32 and f64. (The reviewer's
        // hardcoded 2.8698921 is the f32 analytic value; recomputing keeps f64
        // exact — a hardcoded f32 radius is off by ~1e-7 at f64, far above the f64
        // margin, and would read `.separated`.) At f32 this ≈ 2.8698921.
        const p_local = box_rot.conjugate().rotateVec3(p);
        const dist_analytic = p_local.sub(p_local.max(he.neg()).min(he)).length();
        const r = narrowphase.gjk(Real, boxShape(0.7, 1.1, 0.6), vr(0, 0, 0), box_rot, sphereShape(dist_analytic), p, Quatr.identity);
        try testing.expectEqual(GjkResult.Status.shallow, r.status);
    }
    // Lock the calibration across scales: exact point–box tangencies at ~10 and
    // ~100, oblique rotations. The point sits `gap` beyond the box's local +X
    // face (`box_rot·(hx + gap, 0, 0)`), so the analytic core distance is exactly
    // `gap`; the sphere radius `gap` makes it a tangency ⇒ `.shallow`.
    {
        const q = Quatr.fromAxisAngle(vr(2, -1, 3).normalize(), 1.1);
        const hx: Real = 10;
        const gap: Real = 4;
        const r = narrowphase.gjk(Real, boxShape(hx, 8, 6), vr(0, 0, 0), q, sphereShape(gap), q.rotateVec3(vr(hx + gap, 0, 0)), Quatr.identity);
        try testing.expectEqual(GjkResult.Status.shallow, r.status);
    }
    {
        const q = Quatr.fromAxisAngle(vr(-1, 2, 1).normalize(), 0.6);
        const hx: Real = 100;
        const gap: Real = 7;
        const r = narrowphase.gjk(Real, boxShape(hx, 70, 40), vr(0, 0, 0), q, sphereShape(gap), q.rotateVec3(vr(hx + gap, 0, 0)), Quatr.identity);
        try testing.expectEqual(GjkResult.Status.shallow, r.status);
    }
}

test "gjk classification is order-independent" {
    // Collision detection must be invariant under an A/B swap. Before P1c the
    // contact margin's coordinate scale was the terminal simplex's support
    // magnitude in the frame of A, which depends on which shape is A — a tangency
    // classified `.separated` one way and `.shallow` the other. The symmetric
    // `coord_scale = |Δpos| + coreExtent_a + coreExtent_b` guarantees agreement.
    const expectSame = struct {
        fn f(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) !void {
            const ab = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
            const ba = narrowphase.gjk(Real, sb, pb, rb, sa, pa, ra);
            try testing.expectEqual(ab.status, ba.status);
            try testing.expectApproxEqAbs(ab.distance, ba.distance, gjk_test_tol);
        }
    }.f;

    // separated / shallow / deep baselines.
    try expectSame(sphereShape(0.5), vr(0, 0, 0), Quatr.identity, boxShape(1, 1, 1), vr(5, 0, 0), Quatr.identity);
    try expectSame(sphereShape(2), vr(0, 0, 0), Quatr.identity, sphereShape(2), vr(3, 0, 0), Quatr.identity);
    try expectSame(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, boxShape(1, 1, 1), vr(1, 0, 0), Quatr.identity);

    // Oriented point–box tangencies at two scales, both orders.
    {
        const q = Quatr.fromAxisAngle(vr(2, -1, 3).normalize(), 1.1);
        const hx: Real = 10;
        const gap: Real = 4;
        try expectSame(boxShape(hx, 8, 6), vr(0, 0, 0), q, sphereShape(gap), q.rotateVec3(vr(hx + gap, 0, 0)), Quatr.identity);
    }
    {
        const q = Quatr.fromAxisAngle(vr(-1, 2, 1).normalize(), 0.6);
        const hx: Real = 100;
        const gap: Real = 7;
        try expectSame(boxShape(hx, 70, 40), vr(0, 0, 0), q, sphereShape(gap), q.rotateVec3(vr(hx + gap, 0, 0)), Quatr.identity);
    }

    // The Codex P1c repro: a large oriented box tangent to a point core. Under the
    // former A-frame `coord_scale` this read `.separated` one order and `.shallow`
    // the other; the symmetric scale makes both `.shallow`. The radius (= analytic
    // core distance) is recomputed at `Real` so the tangency is exact at f32+f64.
    {
        const box_rot = (Quatr{ .x = 0.47042668, .y = -0.33259994, .z = 0.7495928, .w = 0.32586288 }).normalize();
        const he = vr(65.80497, 50.802673, 21.834202);
        const p = vr(-11.051631, -65.118095, -66.90062);
        const p_local = box_rot.conjugate().rotateVec3(p);
        const dist_analytic = p_local.sub(p_local.max(he.neg()).min(he)).length();
        const box_shape = SupportShape{ .core = .{ .box = he }, .radius = 0 };
        try expectSame(box_shape, vr(0, 0, 0), box_rot, sphereShape(dist_analytic), p, Quatr.identity);
        const r = narrowphase.gjk(Real, box_shape, vr(0, 0, 0), box_rot, sphereShape(dist_analytic), p, Quatr.identity);
        try testing.expectEqual(GjkResult.Status.shallow, r.status);
    }
}

test "gjk deep pairs enclose the origin" {
    const rot_z90 = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);

    // ss: coincident point cores.
    try checkDeep(sphereShape(0.5), vr(2, 3, 4), Quatr.identity, sphereShape(0.5), vr(2, 3, 4), Quatr.identity);
    // sb: point core inside the box volume.
    try checkDeep(sphereShape(0.5), vr(5, 0, 0), Quatr.identity, boxShape(1, 1, 1), vr(5, 0, 0), Quatr.identity);
    // sc: point core on the capsule segment.
    try checkDeep(sphereShape(0.5), vr(5, 0, 0), Quatr.identity, capsuleShape(1, 0.3), vr(5, 0, 0), Quatr.identity);
    // bb: overlapping box volumes.
    try checkDeep(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, boxShape(1, 1, 1), vr(1, 0, 0), Quatr.identity);
    // bc: segment core passing through the box volume.
    try checkDeep(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, capsuleShape(1, 0.3), vr(0.5, 0, 0), Quatr.identity);
    // cc: two segment cores crossing at the origin (B rotated onto the X axis).
    try checkDeep(capsuleShape(1, 0.3), vr(0, 0, 0), Quatr.identity, capsuleShape(1, 0.3), vr(0, 0, 0), rot_z90);

    // Deep detection holds under an oblique global rotation (bb overlap).
    const g_rot = Quatr.fromAxisAngle(vr(2, -1, 4).normalize(), 1.3);
    const g_trans = vr(6, -3, 8);
    try checkDeep(
        boxShape(1, 1, 1),
        g_rot.rotateVec3(vr(0, 0, 0)).add(g_trans),
        g_rot,
        boxShape(1, 1, 1),
        g_rot.rotateVec3(vr(1, 0, 0)).add(g_trans),
        g_rot,
    );

    // LARGE shape (Fix 3b non-regression): two boxes of half-extents 50 in
    // franc overlap ⇒ `.deep`. The absolute noise floor must not weaken
    // genuine enclosure at scale — deep here is proven by a non-degenerate
    // origin-containing tetrahedron (`count == 4`), not by any distance test.
    try checkDeep(boxShape(50, 50, 50), vr(0, 0, 0), Quatr.identity, boxShape(50, 50, 50), vr(1, 0, 0), Quatr.identity);

    // LARGE DEGENERATE deep (Fix P2 non-regression): two half-height-50 segment
    // cores crossing at the origin. This deep is a planar (non-tetrahedralizable)
    // Minkowski config, so it rests on the numerical-noise floor rather than
    // `count == 4` — the case most sensitive to the floor recalibration. It must
    // stay `.deep` at scale (the closest point lands at the origin up to rounding).
    try checkDeep(capsuleShape(50, 0.3), vr(0, 0, 0), Quatr.identity, capsuleShape(50, 0.3), vr(0, 0, 0), rot_z90);

    // ANISOTROPIC box interior (Codex P1d): a point core well inside a sharp,
    // very flat box (half-extents 50.14 × 0.236 × 0.984, ~212:1) ⇒ `.deep`. The
    // former `maxEdgeSq³` degeneracy normalization rejected the valid but
    // elongated enclosing tetrahedron (its long edge dominated the cube), reading
    // this interior point `.separated`; the dimensionless product-of-edges
    // criterion classifies it correctly. (Aspect ratios beyond a moderate bound
    // are NOT guaranteed — a GJK f32 limitation on sharp cores, deferred to the
    // M1.1.4 analytic box fast paths / M1.1.3 EPA; see `narrowphase.zig`.)
    try checkDeep(boxShape(50.13848, 0.23608336, 0.98368657), vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(14.877217, 0.01973883, 0.07743414), Quatr.identity);
}

test "gjk deep is reliable to moderate box aspect ratio" {
    // Boundary guarantee (P1d): a point core inside a box is reliably `.deep`
    // up to a MODERATE aspect ratio (~30:1). Beyond that (sharp radius-0 boxes)
    // GJK f32 can miss the enclosure (degeneracy + premature anti-cycling
    // termination) — a documented limitation deferred to M1.1.4 (analytic box
    // fast paths) / M1.1.3 (EPA). This test deliberately stops at the guaranteed
    // regime; it does NOT assert `.deep` at extreme aspect ratios (that would
    // paper over the residual).
    const aspects = [_]Real{ 1, 5, 15, 30 };
    for (aspects) |ar| {
        const box = boxShape(ar, 1, ar * 0.5);
        // A point near the box centre, offset within every half-extent.
        const p = vr(0.3 * ar, 0.2, 0.1 * ar);
        try checkDeep(box, vr(0, 0, 0), Quatr.identity, sphereShape(0.5), p, Quatr.identity);
        // ...and under an oblique rotation (deep is rotation-invariant).
        const q = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.5);
        try checkDeep(box, vr(0, 0, 0), q, sphereShape(0.5), q.rotateVec3(p), Quatr.identity);
    }
}

test "gjk is deterministic and iteration-bounded" {
    // Determinism: a fixed rotated separated pair, run twice ⇒ bit-identical.
    const sa = boxShape(1, 1, 1);
    const sb = capsuleShape(1, 0.3);
    const ra = Quatr.fromAxisAngle(vr(1, 1, 0).normalize(), 0.5);
    const rb = Quatr.fromAxisAngle(vr(0, 1, 1).normalize(), 1.1);
    const r1 = narrowphase.gjk(Real, sa, vr(0, 0, 0), ra, sb, vr(5, 1, 2), rb);
    const r2 = narrowphase.gjk(Real, sa, vr(0, 0, 0), ra, sb, vr(5, 1, 2), rb);
    try testing.expectEqual(r1.status, r2.status);
    try testing.expectEqual(r1.distance, r2.distance);
    try testing.expect(r1.closest_a.eql(r2.closest_a));
    try testing.expect(r1.closest_b.eql(r2.closest_b));

    // Adversarial: exactly-parallel unit box faces (the pathological equidistant-
    // support case) with a gap of 1 ⇒ converges to distance 1. A pure `iter < 32`
    // loop cannot hang, so a sane result IS the termination proof.
    const box = boxShape(1, 1, 1);
    const adv = narrowphase.gjk(Real, box, vr(0, 0, 0), Quatr.identity, box, vr(3, 0, 0), Quatr.identity);
    try testing.expectEqual(GjkResult.Status.separated, adv.status);
    try testing.expectApproxEqAbs(@as(Real, 1), adv.distance, gjk_test_tol);
    try testing.expect(finite3(adv.closest_a) and finite3(adv.closest_b));

    // Near-parallel (tiny rotation on B): still terminates with a sane result.
    const near = narrowphase.gjk(Real, box, vr(0, 0, 0), Quatr.identity, box, vr(3, 0, 0), Quatr.fromAxisAngle(Vec3r.unit_z, 0.02));
    try testing.expectEqual(GjkResult.Status.separated, near.status);
    try testing.expect(finite3(near.closest_a) and finite3(near.closest_b));
    try testing.expect(near.distance > 0.5 and near.distance < 1.2);
}

// --- E4: broadphase → narrowphase integration --------------------------------

/// Add a `.dynamic` box body at (x,y,z) — descriptor positions are the f32 api
/// `Vec3`, so the coordinates are f32.
fn addBoxBodyAt(gpa: std.mem.Allocator, bm: *BodyManager, store: *const ShapeStore, shape: api.ShapeId, entity_index: u32, x: f32, y: f32, z: f32) !BodyId {
    var d = api.BodyDescriptor{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    };
    d.position = ApiVec3.fromArray(.{ x, y, z });
    return bm.addBody(gpa, store, d);
}

/// Whether `p` is the unordered pair `{x, y}` (candidate pairs are canonical,
/// `a < b` by packed `BodyId`).
fn isPair(p: Broadphase.Pair, x: BodyId, y: BodyId) bool {
    return p.a == @min(x, y) and p.b == @max(x, y);
}

test "broadphase pairs filtered by gjkPair" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var bp = Broadphase.init(.{});
    defer bp.deinit(gpa);

    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(0.5) } });

    // A–B: tight AABBs 0.15 apart (disjoint) but fat AABBs (margin 0.1) overlap
    // ⇒ a broadphase fat-AABB false positive the narrowphase must reject.
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);
    const id_b = try addBoxBodyAt(gpa, &bm, &store, box, 1, 1.15, 0, 0);
    // C–D: boxes genuinely overlap ⇒ a real collision (deep) — proves gjkPair
    // discriminates, not just always returns separated.
    const id_c = try addBoxBodyAt(gpa, &bm, &store, box, 2, 10, 0, 0);
    const id_d = try addBoxBodyAt(gpa, &bm, &store, box, 3, 10.3, 0, 0);

    // Proxies via the broadphase, `user_data` = the packed `BodyId` (M1.1.1).
    const ids = [_]BodyId{ id_a, id_b, id_c, id_d };
    for (ids) |id| {
        _ = try bp.insert(gpa, .dynamic, bm.bodyAabb(&store, id).?, id);
    }

    var pairs: std.ArrayListUnmanaged(Broadphase.Pair) = .empty;
    defer pairs.deinit(gpa);
    try bp.computePairs(gpa, &pairs);

    // Classify every broadphase candidate through gjkPair.
    var found_false_positive = false;
    var found_overlap = false;
    for (pairs.items) |p| {
        const res = bm.gjkPair(&store, p.a, p.b).?; // all four bodies still live
        if (isPair(p, id_a, id_b)) {
            found_false_positive = true;
            try testing.expectEqual(GjkResult.Status.separated, res.status);
        } else if (isPair(p, id_c, id_d)) {
            found_overlap = true;
            try testing.expectEqual(GjkResult.Status.deep, res.status);
        }
    }
    // The broadphase surfaced the fat-AABB false positive, and gjkPair rejected
    // it as separated; the genuine overlap came back deep.
    try testing.expect(found_false_positive);
    try testing.expect(found_overlap);

    // Stale-handle pair ⇒ null.
    bm.removeBody(id_d);
    try testing.expect(bm.gjkPair(&store, id_c, id_d) == null);
}
