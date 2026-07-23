//! M1.1.3/E2 acceptance suite for the forge_3d narrowphase EPA (penetration axis
//! + core depth over the GJK terminal `.deep` simplex). Keyed to `config.Real`
//! so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const RelativePose = narrowphase.RelativePose(Real);
const GjkResult = narrowphase.GjkResult(Real);
const EpaResult = narrowphase.EpaResult(Real);
const testing = std.testing;

/// Solver-precision Vec3 from literals.
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

/// Distance tolerance for EPA results (convergence + f32 + oblique rotations
/// accumulate; f64 passes far tighter — mirrors the GJK suite's `gjk_test_tol`).
const epa_tol: Real = 1.0e-3;

fn finite3(v: Vec3r) bool {
    const a = v.toArray();
    return std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(a[2]);
}

/// Run GJK then EPA on a pair, mirroring the E4 `collide` deep path. The caller
/// guarantees (or asserts) the pair is `.deep`.
fn deepEpa(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) EpaResult {
    const relpose = RelativePose.init(pa, ra, pb, rb);
    const g = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    return narrowphase.epa(Real, sa, pa, ra, relpose, sb, rb, g, null);
}

test "epa penetration axis and depth match analytic" {
    // A single oblique global rigid transform applied to both bodies leaves the
    // (rotation-invariant) core depth unchanged and rotates the normal — the
    // oriented coverage without losing the analytic value.
    const g_rot = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7);
    const g_trans = vr(-4, 7, 2);

    const Combo = struct {
        sa: SupportShape,
        pa: Vec3r,
        sb: SupportShape,
        pb: Vec3r,
        normal: Vec3r, // expected A->B normal (canonical, identity rotations)
        depth: Real,
    };
    const combos = [_]Combo{
        // sphere/box: point core 0.6 inside the +Z face of a unit box (A = box).
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = sphereShape(0.5), .pb = vr(0, 0, 0.4), .normal = vr(0, 0, 1), .depth = 0.6 },
        // sphere/box, other axis (A = box), nearest +X face.
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = sphereShape(0.5), .pb = vr(0.3, 0, 0), .normal = vr(1, 0, 0), .depth = 0.7 },
        // box/box axis-aligned overlap 0.5 along X (A at origin, B at +1.5 X).
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(1.5, 0, 0), .normal = vr(1, 0, 0), .depth = 0.5 },
        // box/capsule: segment core inside the box, nearest +X face at 0.5.
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = capsuleShape(0.5, 0.3), .pb = vr(0.5, 0, 0), .normal = vr(1, 0, 0), .depth = 0.5 },
    };

    for (combos) |c| {
        // Canonical (identity rotations).
        {
            const r = deepEpa(c.sa, c.pa, Quatr.identity, c.sb, c.pb, Quatr.identity);
            try testing.expectApproxEqAbs(c.depth, r.depth, epa_tol);
            try testing.expect(r.normal.approxEql(c.normal, epa_tol));
            // Unit normal, finite closest points.
            try testing.expectApproxEqAbs(@as(Real, 1), r.normal.length(), epa_tol);
            try testing.expect(finite3(r.closest_a) and finite3(r.closest_b));
        }
        // Same scene under the oblique global transform ⇒ same depth, rotated normal.
        {
            const r = deepEpa(
                c.sa,
                g_rot.rotateVec3(c.pa).add(g_trans),
                g_rot,
                c.sb,
                g_rot.rotateVec3(c.pb).add(g_trans),
                g_rot,
            );
            try testing.expectApproxEqAbs(c.depth, r.depth, epa_tol);
            try testing.expect(r.normal.approxEql(g_rot.rotateVec3(c.normal), epa_tol));
        }
    }
}

test "epa is order-independent" {
    // Non-degenerate deep pairs: epa(A,B) and epa(B,A) give opposite world normals
    // and equal depth (the closest face of B⊖A is the antipode of A⊖B's).
    const Combo = struct { sa: SupportShape, pa: Vec3r, sb: SupportShape, pb: Vec3r };
    const combos = [_]Combo{
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = sphereShape(0.5), .pb = vr(0, 0, 0.4) },
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(1.5, 0, 0) },
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = capsuleShape(0.5, 0.3), .pb = vr(0.5, 0, 0) },
    };
    const g_rot = Quatr.fromAxisAngle(vr(2, -1, 4).normalize(), 1.1);
    for (combos) |c| {
        for ([_]Quatr{ Quatr.identity, g_rot }) |ra| {
            const rb = ra;
            const ab = deepEpa(c.sa, c.pa, ra, c.sb, c.pb, rb);
            const ba = deepEpa(c.sb, c.pb, rb, c.sa, c.pa, ra);
            try testing.expectApproxEqAbs(ab.depth, ba.depth, epa_tol);
            try testing.expect(ab.normal.approxEql(ba.normal.neg(), epa_tol));
        }
    }
}

test "epa expands a low-dimensional deep seed" {
    // Crossing segment cores (two capsules, B rotated onto the X axis, both at the
    // origin): the Minkowski difference of two segments is planar, so the GJK deep
    // seed is < 4 vertices and cannot tetra-expand to a 3-D polytope. EPA must
    // still converge (bounded) to a sane touching result: a unit separation
    // normal (perpendicular to both segments) and core depth 0.
    const rot_z90 = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);
    const a = capsuleShape(1, 0.3);
    const b = capsuleShape(1, 0.3);

    const g = narrowphase.gjk(Real, a, vr(0, 0, 0), Quatr.identity, b, vr(0, 0, 0), rot_z90);
    try testing.expectEqual(GjkResult.Status.deep, g.status);
    try testing.expect(g.simplex_count < 4); // the flag-6 low-dimensional seed

    const r = deepEpa(a, vr(0, 0, 0), Quatr.identity, b, vr(0, 0, 0), rot_z90);
    // Converged to a sane touching result.
    try testing.expect(finite3(r.normal) and finite3(r.closest_a) and finite3(r.closest_b));
    try testing.expectApproxEqAbs(@as(Real, 1), r.normal.length(), epa_tol); // unit
    try testing.expectApproxEqAbs(@as(Real, 0), r.depth, epa_tol); // touching cores
    // Perpendicular to both segment axes (A along Y, B along X ⇒ normal along ±Z).
    try testing.expectApproxEqAbs(@as(Real, 1), @abs(r.normal.toArray()[2]), epa_tol);

    // Point-on-segment (sphere centre on the capsule axis) is likewise a low-dim
    // seed; EPA converges to depth 0 with a unit radial normal.
    const g2 = narrowphase.gjk(Real, a, vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(0, 0.3, 0), Quatr.identity);
    try testing.expectEqual(GjkResult.Status.deep, g2.status);
    try testing.expect(g2.simplex_count < 4);
    const r2 = deepEpa(a, vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(0, 0.3, 0), Quatr.identity);
    try testing.expect(finite3(r2.normal));
    try testing.expectApproxEqAbs(@as(Real, 1), r2.normal.length(), epa_tol);
    try testing.expectApproxEqAbs(@as(Real, 0), r2.depth, epa_tol);
}

test "epa handles eccentric thin-box deep overlaps" {
    // Adversarial-review regime (finding 1): an eccentric (thin) box whose deep
    // overlap makes the Minkowski polytope long/flat, so the loop expands over
    // several iterations and the fan-face winding (inherited from the horizon,
    // not reoriented against the near-coplanar interior) is exercised. Two thin
    // boxes overlap 0.1 along Y (huge overlap along X and Z), so the min-
    // penetration axis is +Y at depth 0.1. Canonical and globally rotated.
    const g_rot = Quatr.fromAxisAngle(vr(1, -2, 3).normalize(), 0.9);
    const g_trans = vr(3, -5, 2);
    const thin = boxShape(5, 0.3, 4);
    {
        const r = deepEpa(thin, vr(0, 0, 0), Quatr.identity, thin, vr(0, 0.5, 0), Quatr.identity);
        try testing.expectApproxEqAbs(@as(Real, 0.1), r.depth, epa_tol);
        try testing.expect(r.normal.approxEql(vr(0, 1, 0), epa_tol));
    }
    {
        const r = deepEpa(
            thin,
            g_rot.rotateVec3(vr(0, 0, 0)).add(g_trans),
            g_rot,
            thin,
            g_rot.rotateVec3(vr(0, 0.5, 0)).add(g_trans),
            g_rot,
        );
        try testing.expectApproxEqAbs(@as(Real, 0.1), r.depth, epa_tol);
        try testing.expect(r.normal.approxEql(g_rot.rotateVec3(vr(0, 1, 0)), epa_tol));
    }
    // Order-independence must survive the eccentric polytope too.
    const ab = deepEpa(thin, vr(0, 0, 0), Quatr.identity, thin, vr(0, 0.5, 0), Quatr.identity);
    const ba = deepEpa(thin, vr(0, 0.5, 0), Quatr.identity, thin, vr(0, 0, 0), Quatr.identity);
    try testing.expectApproxEqAbs(ab.depth, ba.depth, epa_tol);
    try testing.expect(ab.normal.approxEql(ba.normal.neg(), epa_tol));
}

test "epa is deterministic and iteration-bounded" {
    // Determinism: a fixed oriented deep pair, run twice ⇒ bit-identical.
    const ra = Quatr.fromAxisAngle(vr(1, 1, 0).normalize(), 0.5);
    const rb = Quatr.fromAxisAngle(vr(0, 1, 1).normalize(), 1.1);
    const r1 = deepEpa(boxShape(1, 1, 1), vr(0, 0, 0), ra, boxShape(1, 1, 1), vr(1.2, 0.3, 0.1), rb);
    const r2 = deepEpa(boxShape(1, 1, 1), vr(0, 0, 0), ra, boxShape(1, 1, 1), vr(1.2, 0.3, 0.1), rb);
    try testing.expectEqual(r1.depth, r2.depth);
    try testing.expect(r1.normal.eql(r2.normal));
    try testing.expect(r1.closest_a.eql(r2.closest_a));
    try testing.expect(r1.closest_b.eql(r2.closest_b));

    // Adversarial: two nearly-coincident unit boxes (deep, worst case for the
    // polytope). A pure `iter < max_epa_iterations` loop cannot hang, so a finite
    // sane result IS the termination proof.
    const adv = deepEpa(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, boxShape(1, 1, 1), vr(0.01, 0.01, 0.01), Quatr.identity);
    try testing.expect(finite3(adv.normal) and finite3(adv.closest_a) and finite3(adv.closest_b));
    try testing.expect(adv.depth >= 0);
    try testing.expectApproxEqAbs(@as(Real, 1), adv.normal.length(), epa_tol);
}
