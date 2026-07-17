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
