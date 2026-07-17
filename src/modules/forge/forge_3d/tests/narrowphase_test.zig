//! M1.1.2 acceptance suite for the forge_3d narrowphase (distance-based GJK).
//! Grows gate by gate: **E1** covers the support functions + the relative-pose
//! transform; E2 the Voronoi-region simplex solver; E3 the GJK descent loop and
//! `GjkResult`; E4 the broadphase→narrowphase integration. Keyed to
//! `config.Real` so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const RelativePose = narrowphase.RelativePose(Real);
const Simplex = narrowphase.Simplex(Real);
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
