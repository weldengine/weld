//! `forge_3d/tests/shapecast_test.zig` — the shape-cast kernel and its closed-form
//! oracles (M1.1.10 / E3).
//!
//! Every expectation here is a closed form DERIVED in the comment above it, never a
//! value read back from the implementation. The cast is a raycast against the
//! Minkowski difference of the two cores inflated by `r_a + r_b`
//! (`engine-physics-forge.md` §1.11.11), so each oracle is written on the geometry —
//! where the swept core first comes within `r_sum` of the other core — and the
//! kernel is asked to agree.
//!
//! The full acceptance suites of the five query entries, and the initial-contact
//! witness, are E6's. This file is the kernel and its oracles.

const std = @import("std");
const math = @import("foundation").math;
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const config = @import("../config.zig");

const testing = std.testing;
const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SS = narrowphase.SupportShape(Real);
const RP = narrowphase.RelativePose(Real);

/// Relative slack for a distance oracle: float noise at the scale of the tens of
/// metres these scenes use, not geometric slack.
const tol: Real = if (Real == f32) 1e-4 else 1e-11;

/// Slack on the normal's unit norm, in ULPs of 1. The comparison is against 1, so
/// this is pure float noise — the same constant and the same role as
/// `raycast_test.zig`'s `normal_unit_k`.
const normal_unit_k: Real = 8;
const unit_tol: Real = normal_unit_k * std.math.floatEps(Real);

fn v(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// A sphere support shape: a point core of inflation radius `r`.
fn sphere(r: Real) SS {
    return .{ .core = .point, .radius = r };
}

/// A box support shape: a box core of the given half-extents, radius 0 (the only
/// form the store builds — a rounded box is what the RAY kernels reject and what the
/// cast, having a support map, does not need to).
fn box(hx: Real, hy: Real, hz: Real) SS {
    return .{ .core = .{ .box = v(hx, hy, hz) }, .radius = 0 };
}

/// A capsule support shape: a Y-axis segment core of half-height `h`, radius `r`.
fn capsule(h: Real, r: Real) SS {
    return .{ .core = .{ .segment = h }, .radius = r };
}

/// B's pose relative to an A that sits at the origin with identity rotation, which
/// is how every scene below is framed: A's frame IS world, so the returned witness
/// and normal are directly comparable to the world-space oracle.
fn poseAt(position: Vec3r, rotation: Quatr) RP {
    return RP.init(Vec3r.zero, Quatr.identity, position, rotation);
}

fn poseTranslated(position: Vec3r) RP {
    return poseAt(position, Quatr.identity);
}

/// The two invariants every hit carries, whatever the pair (§1.11.11): the normal is
/// UNIT — asserted tight, so a degenerate normal is always a defect and never an
/// effect of distance — and it opposes the cast direction.
fn expectHitInvariants(hit: narrowphase.CastHit(Real), direction: Vec3r) !void {
    try testing.expectApproxEqAbs(@as(Real, 1), hit.normal.length(), unit_tol);
    try testing.expect(hit.normal.dot(direction.normalize()) <= 0);
    try testing.expect(hit.distance >= 0);
}

// ---------------------------------------------------------------------------
// Sphere against sphere — three obliquities, one of them not axis-aligned
// ---------------------------------------------------------------------------

test "sphere cast against a sphere matches the closed form at three obliquities" {
    // Two point cores of radii `r_a`, `r_b`: A's centre travels `t·d̂` and touches
    // when it reaches `r_sum = r_a + r_b` of B's centre `c`. So `t` is the smaller
    // root of `|c − t·d̂|² = r_sum²`:
    //
    //     t = (c · d̂) − √((c · d̂)² − |c|² + r_sum²)
    //
    // At the contact, B's outward normal points from `c` toward A's centre `t·d̂`,
    // that is `−(c − t·d̂)/r_sum`, and B's surface witness is `c + r_b · normal` —
    // which must also equal A's surface witness `t·d̂ + r_a·(−normal)`, the two
    // coinciding exactly at a non-zero time of impact. Each case below states all
    // three and the coincidence is asserted, not assumed.
    const Case = struct {
        name: []const u8,
        r_a: Real,
        r_b: Real,
        centre: Vec3r,
        direction: Vec3r,
        toi: Real,
    };
    const cases = [_]Case{
        // (1) Head-on, axis-aligned. c·d̂ = 10, |c|² = 100, r_sum = 3
        //     → disc = 100 − 100 + 9 = 9 → t = 10 − 3 = 7.
        .{ .name = "head-on", .r_a = 1, .r_b = 2, .centre = v(10, 0, 0), .direction = v(1, 0, 0), .toi = 7 },
        // (2) Oblique approach, axis-aligned direction. c·d̂ = 10, |c|² = 116,
        //     r_sum = 5 → disc = 100 − 116 + 25 = 9 → t = 10 − 3 = 7.
        .{ .name = "oblique", .r_a = 2, .r_b = 3, .centre = v(10, 4, 0), .direction = v(1, 0, 0), .toi = 7 },
        // (3) Oblique approach AND a direction on no axis: d̂ = (3,4,0)/5, and
        //     c = 10·d̂ + (0,0,4) = (6,8,4). c·d̂ = 3.6 + 6.4 = 10, |c|² = 116,
        //     r_sum = 5 → disc = 9 → t = 7. The perpendicular offset is on Z, which
        //     is orthogonal to d̂ by construction, so the algebra stays integral.
        .{ .name = "oblique off-axis", .r_a = 2, .r_b = 3, .centre = v(6, 8, 4), .direction = v(3, 4, 0), .toi = 7 },
    };

    for (cases) |case| {
        const shape_a = sphere(case.r_a);
        const shape_b = sphere(case.r_b);
        const relpose = poseTranslated(case.centre);
        const hit = narrowphase.castShape(Real, shape_a, relpose, shape_b, case.direction, 100) orelse {
            std.debug.print("case '{s}': constructed hit missed\n", .{case.name});
            return error.ConstructedCastMissed;
        };
        try expectHitInvariants(hit, case.direction);
        try testing.expectApproxEqAbs(case.toi, hit.distance, tol);

        // The closed-form normal and witness, computed here from the geometry.
        const unit_d = case.direction.normalize();
        const a_centre = unit_d.scale(case.toi);
        const gap = case.centre.sub(a_centre);
        const r_sum = case.r_a + case.r_b;
        try testing.expectApproxEqAbs(r_sum, gap.length(), tol); // the contact really is at r_sum
        const want_normal = gap.scale(-1 / r_sum);
        try testing.expect(hit.normal.approxEql(want_normal, tol));

        const want_point = case.centre.add(want_normal.scale(case.r_b));
        try testing.expect(hit.point.approxEql(want_point, tol));
        // …and the same point seen from A: the two witnesses coincide beyond a zero
        // time of impact, which is why only B's is computed.
        const from_a = a_centre.add(want_normal.scale(-case.r_a));
        try testing.expect(from_a.approxEql(want_point, tol));
    }
}

// ---------------------------------------------------------------------------
// Box against box — face, edge, vertex
// ---------------------------------------------------------------------------

test "box cast against a box on a face, an edge and a vertex" {
    const shape_a = box(1, 1, 1);
    const shape_b = box(1, 1, 1);
    const direction = v(1, 0, 0);

    // FACE. Both boxes axis-aligned, B centred at (10, 0, 0). A's +X face starts at
    // x = 1 and travels with A; B's −X face is fixed at x = 9. Contact at t = 8.
    // The contact feature is a whole face, so the witness's Y and Z are not unique —
    // only its X is, and it must lie inside B's face.
    {
        const hit = narrowphase.castShape(Real, shape_a, poseTranslated(v(10, 0, 0)), shape_b, direction, 100).?;
        try expectHitInvariants(hit, direction);
        try testing.expectApproxEqAbs(@as(Real, 8), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        const p = hit.point.toArray();
        try testing.expectApproxEqAbs(@as(Real, 9), p[0], tol);
        try testing.expect(@abs(p[1]) <= 1 + tol and @abs(p[2]) <= 1 + tol);
    }

    // EDGE. B rotated 45° about Z presents a single vertical EDGE toward −X, at
    // x = 10 − √2 (the rotated half-diagonal of its XY cross-section). A's +X face
    // reaches it at t = 9 − √2 ≈ 7.5858. The edge runs along Z, so the witness has
    // y = 0 and a free z inside [−1, 1].
    {
        const rot = Quatr.fromAxisAngle(v(0, 0, 1), std.math.pi / 4.0);
        const hit = narrowphase.castShape(Real, shape_a, poseAt(v(10, 0, 0), rot), shape_b, direction, 100).?;
        try expectHitInvariants(hit, direction);
        try testing.expectApproxEqAbs(9 - @sqrt(@as(Real, 2)), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        const p = hit.point.toArray();
        try testing.expectApproxEqAbs(10 - @sqrt(@as(Real, 2)), p[0], tol);
        try testing.expectApproxEqAbs(@as(Real, 0), p[1], tol);
        try testing.expect(@abs(p[2]) <= 1 + tol);
    }

    // VERTEX. B rotated so its local (1,1,1) diagonal points along world −X: the
    // rotation about `normalize((1,1,1) × (−1,0,0)) = (0,−1,1)/√2` by
    // `acos(−1/√3)`. Its −X extremum is then the single vertex at x = 10 − √3, and
    // A's +X face reaches it at t = 9 − √3 ≈ 7.2679. A vertex contact has a UNIQUE
    // witness, so all three coordinates are pinned.
    {
        const axis = v(0, -1, 1).normalize();
        const angle = std.math.acos(-1.0 / @sqrt(@as(Real, 3)));
        const rot = Quatr.fromAxisAngle(axis, angle);
        const hit = narrowphase.castShape(Real, shape_a, poseAt(v(10, 0, 0), rot), shape_b, direction, 100).?;
        try expectHitInvariants(hit, direction);
        try testing.expectApproxEqAbs(9 - @sqrt(@as(Real, 3)), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        try testing.expect(hit.point.approxEql(v(10 - @sqrt(@as(Real, 3)), 0, 0), tol));
    }
}

// ---------------------------------------------------------------------------
// Capsule against box, capsule against capsule
// ---------------------------------------------------------------------------

test "capsule cast against a box and against a capsule" {
    const direction = v(1, 0, 0);

    // Capsule (Y segment, half-height 1, radius 0.5) against an axis-aligned unit
    // box at (10, 0, 0). The capsule's CORE is the segment through the origin, whose
    // distance to the box's −X face (x = 9) is 9; contact when that closes to
    // r_sum = 0.5, so t = 8.5. The witness lies on the −X face, y free inside the
    // overlap of the segment and the face, z = 0.
    {
        const hit = narrowphase.castShape(Real, capsule(1, 0.5), poseTranslated(v(10, 0, 0)), box(1, 1, 1), direction, 100).?;
        try expectHitInvariants(hit, direction);
        try testing.expectApproxEqAbs(@as(Real, 8.5), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        const p = hit.point.toArray();
        try testing.expectApproxEqAbs(@as(Real, 9), p[0], tol);
        try testing.expect(@abs(p[1]) <= 1 + tol);
        try testing.expectApproxEqAbs(@as(Real, 0), p[2], tol);
    }

    // Capsule against a PARALLEL capsule: both cores are Y segments, B's at
    // (10, 0, 0). The core distance is 10 and closes to r_sum = 1 at t = 9. Parallel
    // segments have a non-unique closest pair, so only the witness's X is pinned:
    // 10 − r_b = 9.5.
    {
        const hit = narrowphase.castShape(Real, capsule(1, 0.5), poseTranslated(v(10, 0, 0)), capsule(1, 0.5), direction, 100).?;
        try expectHitInvariants(hit, direction);
        try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        const p = hit.point.toArray();
        try testing.expectApproxEqAbs(@as(Real, 9.5), p[0], tol);
        try testing.expect(@abs(p[1]) <= 1 + tol);
    }

    // Capsule against a CROSSED capsule: B rotated 90° about X, so its core is a Z
    // segment at (10, 0, 0). The two skew segments are closest at their centres, at
    // distance 10, closing to r_sum = 1 at t = 9 — and here the closest pair IS
    // unique, so the witness is pinned in all three coordinates:
    // (10, 0, 0) + 0.5·(−1, 0, 0) = (9.5, 0, 0).
    {
        const rot = Quatr.fromAxisAngle(v(1, 0, 0), std.math.pi / 2.0);
        const hit = narrowphase.castShape(Real, capsule(1, 0.5), poseAt(v(10, 0, 0), rot), capsule(1, 0.5), direction, 100).?;
        try expectHitInvariants(hit, direction);
        try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        try testing.expect(hit.point.approxEql(v(9.5, 0, 0), tol));
    }
}

// ---------------------------------------------------------------------------
// Domain: the closed interval, a zero bound, a zero direction
// ---------------------------------------------------------------------------

/// The box-against-box FACE scene, whose time of impact is reached EXACTLY and in a
/// single advance: the Minkowski difference of two unit boxes is a box of
/// half-extents (2,2,2) centred at (−10,0,0), the ray along (−1,0,0) enters its
/// x-slab at exactly 8, and the first advance lands on that plane. Being exact is
/// what lets the interval be probed at the bound and one ulp below it.
fn faceSceneCast(max_distance: Real, ceiling: u32, diag: ?*narrowphase.CastDiagnostics) ?narrowphase.CastHit(Real) {
    return narrowphase.castShapeBounded(
        Real,
        box(1, 1, 1),
        poseTranslated(v(10, 0, 0)),
        box(1, 1, 1),
        v(1, 0, 0),
        max_distance,
        ceiling,
        diag,
    );
}

fn nextBelow(x: Real) Real {
    const Bits = if (Real == f32) u32 else u64;
    return @bitCast(@as(Bits, @bitCast(x)) - 1);
}

test "max_distance is a closed interval" {
    // The exact time of impact is 8 (see `faceSceneCast`). A bound of exactly 8
    // admits it — the interval is closed (§1.11.11) — and a bound one ulp below
    // refuses it. Both are exact comparisons: no tolerance appears on either side.
    const at_bound = faceSceneCast(8, narrowphase.max_shapecast_iterations, null);
    try testing.expect(at_bound != null);
    try testing.expectEqual(@as(Real, 8), at_bound.?.distance);

    var diag: narrowphase.CastDiagnostics = undefined;
    const below = faceSceneCast(nextBelow(8), narrowphase.max_shapecast_iterations, &diag);
    try testing.expect(below == null);
    // …and it is the BOUND that refused it, not some other exit taking the blame.
    try testing.expectEqual(narrowphase.CastExit.beyond_bound, diag.exit);
}

test "max_distance zero degenerates to an overlap test at the start pose" {
    // A pair that is clear at the start pose: the parameter would have to reach 8,
    // so a zero bound is a miss, and the bound is what says so.
    var diag: narrowphase.CastDiagnostics = undefined;
    try testing.expect(faceSceneCast(0, narrowphase.max_shapecast_iterations, &diag) == null);
    try testing.expectEqual(narrowphase.CastExit.beyond_bound, diag.exit);

    // A pair that already overlaps at the start pose: two unit boxes 1 apart on X
    // overlap, so the configuration-space origin lies inside the Minkowski
    // difference and the answer is a hit at distance ZERO even with a zero bound.
    const overlapping = narrowphase.castShape(Real, box(1, 1, 1), poseTranslated(v(1, 0, 0)), box(1, 1, 1), v(1, 0, 0), 0).?;
    try testing.expectEqual(@as(Real, 0), overlapping.distance);
    try expectHitInvariants(overlapping, v(1, 0, 0));
}

test "a zero direction returns nothing, and a denormal one is served" {
    // EXACTLY zero is the only degenerate direction, and the guard is at true zero on
    // the largest absolute component — which is zero exactly when all three are.
    try testing.expect(narrowphase.castShape(Real, box(1, 1, 1), poseTranslated(v(10, 0, 0)), box(1, 1, 1), Vec3r.zero, 100) == null);

    // A direction whose SQUARED length underflows to zero is not degenerate: it
    // normalises exactly and must be served (§1.11.4). Squaring first would read it
    // as zero; reducing by the largest component first does not.
    const tiny = std.math.floatTrueMin(Real);
    try testing.expectEqual(@as(Real, 0), tiny * tiny); // the square really does underflow
    const denormal = narrowphase.castShape(Real, box(1, 1, 1), poseTranslated(v(10, 0, 0)), box(1, 1, 1), v(tiny, 0, 0), 100).?;
    const unit = narrowphase.castShape(Real, box(1, 1, 1), poseTranslated(v(10, 0, 0)), box(1, 1, 1), v(1, 0, 0), 100).?;
    try testing.expectEqual(unit.distance, denormal.distance);
    try testing.expectEqual(unit.normal.toArray()[0], denormal.normal.toArray()[0]);

    // And the other end of the range: a huge finite direction whose square overflows
    // to infinity is equally legitimate.
    const huge: Real = if (Real == f32) 1e20 else 1e160;
    try testing.expect(std.math.isInf(huge * huge)); // the square really does overflow
    const large = narrowphase.castShape(Real, box(1, 1, 1), poseTranslated(v(10, 0, 0)), box(1, 1, 1), v(huge, 0, 0), 100).?;
    try testing.expectEqual(unit.distance, large.distance);
}

// ---------------------------------------------------------------------------
// The iteration ceiling
// ---------------------------------------------------------------------------

/// The oblique off-axis sphere pair of the first test — closed-form time of impact
/// 7 — which the march reaches in FOUR iterations rather than one. That is what
/// makes it usable as a ceiling probe: a scene converging in a single advance could
/// not distinguish a cap from a convergence.
fn obliqueSphereCast(ceiling: u32, diag: *narrowphase.CastDiagnostics) ?narrowphase.CastHit(Real) {
    return narrowphase.castShapeBounded(
        Real,
        sphere(2),
        poseTranslated(v(6, 8, 4)),
        sphere(3),
        v(3, 4, 0),
        100,
        ceiling,
        diag,
    );
}

test "the iteration ceiling returns a hit at the current parameter" {
    // §1.11.11 is normative here and the semantics is not left to the implementation:
    // exhausting the ceiling returns a HIT at the current parameter, never a miss.
    // A miss would fabricate a false negative, hence tunnelling; the current
    // parameter fabricates a contact announced EARLY, which is the safe failure
    // direction — and it is safe precisely because the parameter is at every step a
    // LOWER BOUND of the true time of impact.
    //
    // The ceiling is driven small through the same code path, because on the three
    // cores the store builds the real ceiling of 32 is unreachable: this scene
    // converges in 4. Only the constant differs between this run and production.
    var converged_diag: narrowphase.CastDiagnostics = undefined;
    const converged = obliqueSphereCast(narrowphase.max_shapecast_iterations, &converged_diag).?;
    try testing.expectEqual(narrowphase.CastExit.converged, converged_diag.exit);
    try testing.expectApproxEqAbs(@as(Real, 7), converged.distance, tol);

    // DISCRIMINATION GUARD. Each capped run must (a) really have been capped and
    // (b) really have returned something DIFFERENT — a strictly smaller parameter.
    // Without (b) the test would pass on a kernel that converges before the cap can
    // bite, and the normative fallback would never have been exercised at all.
    var capped_any = false;
    for ([_]u32{ 1, 2, 3 }) |ceiling| {
        var diag: narrowphase.CastDiagnostics = undefined;
        const hit = obliqueSphereCast(ceiling, &diag);
        try testing.expectEqual(narrowphase.CastExit.iteration_cap, diag.exit);
        try testing.expectEqual(ceiling, diag.iterations);
        // A HIT, not a miss. This is the whole normative point.
        try testing.expect(hit != null);
        try expectHitInvariants(hit.?, v(3, 4, 0));
        // Announced EARLY: at or below the true time of impact, never past it.
        try testing.expect(hit.?.distance < converged.distance);
        try testing.expect(hit.?.distance > 0);
        capped_any = true;
    }
    try testing.expect(capped_any);

    // And the parameter really is monotone across the caps — it is a lower bound
    // that tightens, which is the property the fallback rests on.
    var previous: Real = 0;
    for ([_]u32{ 1, 2, 3 }) |ceiling| {
        var diag: narrowphase.CastDiagnostics = undefined;
        const hit = obliqueSphereCast(ceiling, &diag).?;
        try testing.expect(hit.distance > previous);
        previous = hit.distance;
    }
}

// ---------------------------------------------------------------------------
// What the cast buys that the ray kernels cannot
// ---------------------------------------------------------------------------

test "sphere cast against a box does not error, where the ray kernel refuses" {
    // The discriminating test for the whole design (§1.11.11). Casting a sphere of
    // radius `r_a` against a box IS, in configuration space, a ray against a box
    // inflated by `r_a` — a ROUNDED box, precisely the shape the ray kernels reject.
    // Both facts are asserted here, in the same test, so the claim that the cast
    // covers what the ray kernel refuses is proven rather than stated.
    const r_a: Real = 0.5;
    const direction = v(1, 0, 0);

    // (1) The ray kernel refuses the rounded box, loudly.
    const rounded: SS = .{ .core = .{ .box = v(1, 1, 1) }, .radius = r_a };
    try testing.expectError(error.UnsupportedShape, narrowphase.rayShape(Real, rounded, v(-10, 0, 0), direction));

    // (2) The cast answers the same geometry with no error channel at all. A sphere
    // of radius 0.5 sweeping +X against a unit box at (10, 0, 0): its centre must
    // reach x = 9 − 0.5 = 8.5.
    const hit = narrowphase.castShape(Real, sphere(r_a), poseTranslated(v(10, 0, 0)), box(1, 1, 1), direction, 100).?;
    try expectHitInvariants(hit, direction);
    try testing.expectApproxEqAbs(@as(Real, 8.5), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    // The box carries no inflation, so its witness is on the core face itself.
    const p = hit.point.toArray();
    try testing.expectApproxEqAbs(@as(Real, 9), p[0], tol);
}

// ---------------------------------------------------------------------------
// Far-field conditioning (§1.11.4 bis)
// ---------------------------------------------------------------------------

/// The distance at which the scalar stops resolving the shape's geometry: one ulp of
/// the coordinate reaches the shape's radius. Beyond it a statement about the
/// normal's ORIENTATION is meaningless — the norm, being an invariant, is asserted
/// regardless (§1.11.4 bis). Same helper, same rule, as `raycast_test.zig`.
fn resolvesGeometryAt(distance: Real, radius: Real) bool {
    return std.math.floatEps(Real) * distance < radius;
}

test "an oblique cast in the far field keeps a unit normal" {
    // §1.11.4 bis is contraignante on this kernel and names the case that must be
    // exercised: an OBLIQUE sweep. An axis-aligned one proves exactly nothing, the
    // cancellation being identically zero there.
    //
    // Two unit-summing radii sweep along d̂ = (3,4,0)/5 with a perpendicular offset
    // of 0.5 on p̂ = (−4,3,0)/5. B's centre is `c = D·d̂ + 0.5·p̂`, so
    // `c · d̂ = D` and `|c|² = D² + 0.25`, giving
    //
    //     t = D − √(D² − D² − 0.25 + 1) = D − √0.75
    //
    // at EVERY distance, and the contact normal is
    // `−(√0.75·d̂ + 0.5·p̂)`, whose projection on d̂ is `−√0.75` — independent of D.
    // That D-independence is what makes the sweep a conditioning test rather than a
    // geometry test.
    const unit_d = v(3, 4, 0).normalize();
    const perp = v(-4, 3, 0).normalize();
    const want_cos = -@sqrt(@as(Real, 0.75));

    var checked_orientation: u32 = 0;
    for ([_]Real{ 1e2, 1e3, 1e4, 1e5, 1e6, 2e6, 1e7, 1e8 }) |distance| {
        const centre = unit_d.scale(distance).add(perp.scale(0.5));
        var diag: narrowphase.CastDiagnostics = undefined;
        const maybe = narrowphase.castShapeBounded(
            Real,
            sphere(0.5),
            poseTranslated(centre),
            sphere(0.5),
            unit_d,
            2 * distance,
            narrowphase.max_shapecast_iterations,
            &diag,
        );
        // Every configuration here is CONSTRUCTED to hit, so a miss is a false
        // negative and fails hard, naming the distance. A `continue` would let the
        // silent miss through the very test meant to detect it.
        if (maybe == null) {
            std.debug.print("false negative: constructed cast missed at distance {d} (exit {s})\n", .{ distance, @tagName(diag.exit) });
            return error.ConstructedCastMissed;
        }
        const hit = maybe.?;

        // THE NORM IS THE INVARIANT: asserted tight, at every distance, without
        // exception. A degenerate normal is always a defect and never an effect of
        // distance, because the kernel normalises rather than dividing by a radius.
        try testing.expectApproxEqAbs(@as(Real, 1), hit.normal.length(), unit_tol);
        try testing.expect(hit.normal.dot(unit_d) <= 0);
        // A structural bound on the parameter, valid at every scale: the sweep
        // travels at most to B's centre and at least to within `r_sum` of it.
        try testing.expect(hit.distance <= distance);
        try testing.expect(hit.distance >= distance - 1);

        // THE ORIENTATION is bounded only INSIDE the envelope where the scalar still
        // resolves the geometry, and the bound is a function of the distance. A
        // tolerance that grew without an upper limit would stop being an assertion.
        if (resolvesGeometryAt(distance, 1)) {
            try testing.expectApproxEqAbs(want_cos, hit.normal.dot(unit_d), std.math.floatEps(Real) * distance * 8);
            checked_orientation += 1;
        }
    }
    // The orientation envelope is not empty at either precision, so that half of the
    // assertion really ran.
    try testing.expect(checked_orientation >= 4);

    // The aligned contrast, at the same distance: exactly the closed form, because an
    // axis-aligned sweep has no cancellation at all. This is the case §1.11.4 bis
    // says proves nothing on its own — kept here only to show the contrast.
    const aligned = narrowphase.castShape(Real, sphere(0.5), poseTranslated(v(1e6, 0.5, 0)), sphere(0.5), v(1, 0, 0), 2e6).?;
    try testing.expectApproxEqAbs(@as(Real, 1), aligned.normal.length(), unit_tol);
    try testing.expect(aligned.normal.dot(v(1, 0, 0)) <= 0);
}

// ---------------------------------------------------------------------------
// M1.1.10 / E4 — the `BodyManager` adapters
// ---------------------------------------------------------------------------
//
// Four adapters resolve a BODY's pose and support shape through `store` and call the
// exact kernel: `castShapeBody`, `overlapShapeBody`, `containsPointBody`,
// `closestPointBody`. They mirror `raycastBody` / `gjkPair` / `collidePair`, take
// `*const BodyManager` — a query cannot wake anything, structurally, not by
// convention — and answer null on a stale HANDLE and on a stale SHAPE, which are two
// distinct ways to be gone.
//
// The query-level suites of the five entries are E6's; this section is the wiring.

const harness = @import("solver_test.zig");
const body_manager_mod = @import("../body_manager.zig");
const api = @import("weld_forge");
const shape_mod = @import("../shape.zig");
const query_mod = @import("../query/root.zig");

/// A body carrying a sphere at `centre`, static, so a scene can be built without the
/// solver moving anything. Both handles come back: the tests need the SHAPE id to
/// destroy it independently of the body, and `BodyManager` deliberately grows no
/// getter for it here — E4's scope is the four adapters.
const SphereBody = struct { id: api.BodyId, shape: api.ShapeId };

fn addSphereBody(gpa: std.mem.Allocator, world: *harness.World, centre: [3]f32, radius: f32) !SphereBody {
    const shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = radius } });
    const id = try world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(centre[0], centre[1], centre[2]),
        .body_type = .static,
        .entity = .{ .index = 0, .generation = 0 },
    });
    return .{ .id = id, .shape = shape };
}

test "the adapters call the kernel, bit for bit, and do not reimplement it" {
    // THE GUARD THAT IS MOST OFTEN MISSING HERE. An adapter that quietly grew its own
    // geometry would satisfy every value assertion in this file that was written from
    // the same wrong geometry. So the oracle is not a number: it is the KERNEL
    // ITSELF, called directly from the test on the same inputs, and compared BIT FOR
    // BIT — not to a tolerance, which would leave room for a near-miss reimplementation.
    //
    // The scene is arranged so the adapter's frame conversions are the IDENTITY — the
    // cast shape at the origin with identity rotation, the body unrotated — which is
    // what makes bit-equality the right assertion rather than an optimistic one. The
    // conversions themselves are exercised by the rotated scenes further down.
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const created = try addSphereBody(gpa, &world, .{ 10, 0, 0 }, 2);
    const body = created.id;
    const body_shape = shape_mod.supportShape(world.store.get(created.shape).?);

    // (1) castShapeBody against castShape.
    {
        const cast_shape = sphere(1);
        const relpose = RP.init(Vec3r.zero, Quatr.identity, v(10, 0, 0), Quatr.identity);
        const direct = narrowphase.castShape(Real, cast_shape, relpose, body_shape, v(1, 0, 0), 100).?;
        const through = world.bm.castShapeBody(&world.store, body, cast_shape, Vec3r.zero, Quatr.identity, v(1, 0, 0), 100).?;
        try testing.expectEqual(direct.distance, through.distance);
        inline for (0..3) |i| {
            try testing.expectEqual(direct.point.toArray()[i], through.position.toArray()[i]);
            try testing.expectEqual(direct.normal.toArray()[i], through.normal.toArray()[i]);
        }
        // …and the closed form the geometry gives independently: a unit sphere
        // sweeping +X onto a radius-2 sphere at x = 10 touches at 10 − 3 = 7.
        try testing.expectApproxEqAbs(@as(Real, 7), through.distance, tol);
    }

    // (2) overlapShapeBody against gjk's own regime test.
    {
        const probe = sphere(1);
        for ([_]Real{ 8, 12.9, 13.5 }) |x| {
            const direct = narrowphase.gjk(Real, probe, v(x, 0, 0), Quatr.identity, body_shape, v(10, 0, 0), Quatr.identity);
            const through = world.bm.overlapShapeBody(&world.store, body, probe, v(x, 0, 0), Quatr.identity).?;
            try testing.expectEqual(direct.status != .separated, through);
        }
    }

    // (3) containsPointBody against containsPoint in the body's local frame.
    {
        for ([_]Vec3r{ v(10, 0, 0), v(12, 0, 0), v(12.001, 0, 0), v(10, 1.5, 0) }) |p| {
            const direct = narrowphase.containsPoint(Real, body_shape, p.sub(v(10, 0, 0)));
            const through = world.bm.containsPointBody(&world.store, body, p).?;
            try testing.expectEqual(direct, through);
        }
    }

    // (4) closestPointBody against the §1.11.13 derivation applied to gjk's output.
    {
        const p = v(20, 5, 0);
        const probe: SS = .{ .core = .point, .radius = 0 };
        const direct = narrowphase.gjk(Real, probe, p, Quatr.identity, body_shape, v(10, 0, 0), Quatr.identity);
        const through = world.bm.closestPointBody(&world.store, body, p).?;
        try testing.expectEqual(@max(0, direct.distance - 2), through.distance);
        // A point core's closest point on a sphere core is the sphere's centre, so
        // the surface projection is the whole of the geometry here and it is exact:
        // |(20,5,0) − (10,0,0)| = √125, so the surface distance is √125 − 2 and the
        // surface point is the centre plus 2 along the unit offset.
        const offset = p.sub(v(10, 0, 0));
        try testing.expectApproxEqAbs(@sqrt(@as(Real, 125)) - 2, through.distance, tol);
        try testing.expect(through.position.approxEql(v(10, 0, 0).add(offset.normalize().scale(2)), tol));
    }
}

test "the adapters honour a rotated body pose" {
    // The identity-frame test above cannot see a dropped or transposed rotation. This
    // one can: a 3×1×1 box rotated 90° about +Z has its long axis along world Y, so
    // its −X face sits at x = 10 − 1 = 9 and NOT at 10 − 3 = 7.
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(3, 1, 1) } });
    const rot = math.Quatf.fromAxisAngle(harness.av3(0, 0, 1), std.math.pi / 2.0);
    const body = try world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(10, 0, 0),
        .rotation = rot,
        .body_type = .static,
        .entity = .{ .index = 0, .generation = 0 },
    });

    // A unit sphere sweeping +X from the origin reaches x = 9 − 1 = 8.
    const hit = world.bm.castShapeBody(&world.store, body, sphere(1), Vec3r.zero, Quatr.identity, v(1, 0, 0), 100).?;
    try testing.expectApproxEqAbs(@as(Real, 8), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    try testing.expectApproxEqAbs(@as(Real, 9), hit.position.toArray()[0], tol);

    // Membership follows the rotation too: (10, 2.5, 0) is inside the rotated box
    // (its half-extent along world Y is 3) and (12.5, 0, 0) is outside (its
    // half-extent along world X is 1). Both would answer the opposite unrotated.
    try testing.expect(world.bm.containsPointBody(&world.store, body, v(10, 2.5, 0)).?);
    try testing.expect(!world.bm.containsPointBody(&world.store, body, v(12.5, 0, 0)).?);

    // And so does the closest point: from (14, 0, 0) the nearest surface point is on
    // the −X…+X face pair at x = 11, so the distance is 3.
    const closest = world.bm.closestPointBody(&world.store, body, v(14, 0, 0)).?;
    try testing.expectApproxEqAbs(@as(Real, 3), closest.distance, tol);
    try testing.expectApproxEqAbs(@as(Real, 11), closest.position.toArray()[0], tol);
}

test "a rotated cast frame is transported, not ignored" {
    // The cast shape's own rotation must reach the kernel and come back out. A
    // capsule is the discriminating shape: its core is a Y segment, so rotating it
    // 90° about +Z lays it along world X and changes what it sweeps with.
    //
    // Upright (half-height 2, radius 0.5) sweeping +X onto a unit box at (10, 0, 0):
    // the segment is at x = 0, the box's −X face at x = 9, so the core gap closes to
    // r_sum = 0.5 at t = 8.5. Laid along X, the segment's leading end starts at
    // x = +2, so the same contact happens 2 earlier, at t = 6.5.
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(1, 1, 1) } });
    const body = try world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(10, 0, 0),
        .body_type = .static,
        .entity = .{ .index = 0, .generation = 0 },
    });

    const upright = world.bm.castShapeBody(&world.store, body, capsule(2, 0.5), Vec3r.zero, Quatr.identity, v(1, 0, 0), 100).?;
    try testing.expectApproxEqAbs(@as(Real, 8.5), upright.distance, tol);

    // A CAST rotation is at the solver scalar (`Quatr`), unlike a descriptor rotation
    // which is `f32` by design (§1.11.8). The two coincide at f32 and do not at f64,
    // so building this one with `Quatf` compiles in one leg and not the other.
    const laid = Quatr.fromAxisAngle(v(0, 0, 1), -std.math.pi / 2.0);
    const along = world.bm.castShapeBody(&world.store, body, capsule(2, 0.5), Vec3r.zero, laid, v(1, 0, 0), 100).?;
    try testing.expectApproxEqAbs(@as(Real, 6.5), along.distance, tol);
    // A cast origin offset moves the answer by exactly that offset, the sweep being a
    // pure translation.
    const offset = world.bm.castShapeBody(&world.store, body, capsule(2, 0.5), v(1, 0, 0), laid, v(1, 0, 0), 100).?;
    try testing.expectApproxEqAbs(@as(Real, 5.5), offset.distance, tol);
}

test "every adapter answers null on a stale handle and on a stale shape" {
    // TWO distinct ways to be gone, checked separately — a body whose handle is still
    // live but whose SHAPE has been destroyed is not the same failure as a removed
    // body, and an adapter that only validated the handle would read a freed shape.
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    const doomed_body = try addSphereBody(gpa, &world, .{ 10, 0, 0 }, 2);
    const doomed = doomed_body.id;
    const survivor = (try addSphereBody(gpa, &world, .{ 30, 0, 0 }, 2)).id;

    // Everything answers while both are live — otherwise "null afterwards" would
    // prove nothing.
    try testing.expect(world.bm.castShapeBody(&world.store, doomed, sphere(1), Vec3r.zero, Quatr.identity, v(1, 0, 0), 100) != null);
    try testing.expect(world.bm.overlapShapeBody(&world.store, doomed, sphere(1), v(10, 0, 0), Quatr.identity) != null);
    try testing.expect(world.bm.containsPointBody(&world.store, doomed, v(10, 0, 0)) != null);
    try testing.expect(world.bm.closestPointBody(&world.store, doomed, v(20, 0, 0)) != null);

    // (a) STALE SHAPE, live handle: destroy the shape and leave the body alone.
    world.store.destroyShape(doomed_body.shape);
    try testing.expect(world.bm.isValid(doomed)); // the handle really is still live
    try testing.expect(world.bm.castShapeBody(&world.store, doomed, sphere(1), Vec3r.zero, Quatr.identity, v(1, 0, 0), 100) == null);
    try testing.expect(world.bm.overlapShapeBody(&world.store, doomed, sphere(1), v(10, 0, 0), Quatr.identity) == null);
    try testing.expect(world.bm.containsPointBody(&world.store, doomed, v(10, 0, 0)) == null);
    try testing.expect(world.bm.closestPointBody(&world.store, doomed, v(20, 0, 0)) == null);

    // (b) STALE HANDLE, on a body whose shape is untouched.
    world.removeBody(survivor);
    try testing.expect(!world.bm.isValid(survivor));
    try testing.expect(world.bm.castShapeBody(&world.store, survivor, sphere(1), Vec3r.zero, Quatr.identity, v(1, 0, 0), 100) == null);
    try testing.expect(world.bm.overlapShapeBody(&world.store, survivor, sphere(1), v(30, 0, 0), Quatr.identity) == null);
    try testing.expect(world.bm.containsPointBody(&world.store, survivor, v(30, 0, 0)) == null);
    try testing.expect(world.bm.closestPointBody(&world.store, survivor, v(40, 0, 0)) == null);
}

test "a sleeping body answers every adapter and stays asleep" {
    // The PUBLISHED harness with sleeping ENABLED — a genuinely sleeping island, not
    // a flag set by hand. A query takes `*const BodyManager`, so it cannot wake
    // anything even in principle; this drives the whole cycle to sleep anyway and
    // checks `isSleeping` before AND after each of the four adapters, because a
    // structural argument that is never observed is still only an argument.
    const gpa = std.testing.allocator;
    var world = harness.World.init(harness.vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(20, 0.5, 20) } });
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(0.5, 0.5, 0.5) } });
    _ = try world.addBody(gpa, .{
        .shape = ground_shape,
        .body_type = .static,
        .restitution = 0,
        .entity = .{ .index = 0, .generation = 0 },
    });
    const sleeper = try world.addBody(gpa, .{
        .shape = box_shape,
        .position = harness.av3(0, 1, 0),
        .body_type = .dynamic,
        .mass = 1,
        .restitution = 0,
        .entity = .{ .index = 1, .generation = 0 },
    });

    // Drive until the island is asleep: the constraint array empties after having
    // been non-empty, the normative observable of §1.8.6.
    var had_contact = false;
    var t: u32 = 0;
    const asleep = while (t < 600) : (t += 1) {
        try world.step(gpa);
        if (world.constraints.items.len > 0) {
            had_contact = true;
        } else if (had_contact) break true;
    } else false;
    try testing.expect(asleep);
    try testing.expect(world.bm.isSleeping(sleeper).?);

    // The settled box's top face sits near y = 1; its centre is wherever the solver
    // left it, so every oracle below is written against the body's OWN pose rather
    // than a predicted one — this test is about answering and not waking, not about
    // where the box came to rest.
    const centre = world.bm.position(sleeper).?;

    // (1) A cast from above reaches the sleeper: a unit sphere dropped along −Y from
    // 10 m up must stop at or before its centre.
    const cast_origin = v(centre.toArray()[0], 10, centre.toArray()[2]);
    const hit = world.bm.castShapeBody(&world.store, sleeper, sphere(0.25), cast_origin, Quatr.identity, v(0, -1, 0), 100).?;
    try testing.expect(hit.distance > 0 and hit.distance < 10 - centre.toArray()[1]);
    try testing.expect(world.bm.isSleeping(sleeper).?);

    // (2) A probe sphere centred on the sleeper overlaps it.
    try testing.expect(world.bm.overlapShapeBody(&world.store, sleeper, sphere(0.25), centre, Quatr.identity).?);
    try testing.expect(world.bm.isSleeping(sleeper).?);

    // (3) Its own centre is inside it.
    try testing.expect(world.bm.containsPointBody(&world.store, sleeper, centre).?);
    try testing.expect(world.bm.isSleeping(sleeper).?);

    // (4) …so the closest point to that centre is the centre itself, at distance 0;
    // and a point 5 m to the side is at a positive distance.
    const inside = world.bm.closestPointBody(&world.store, sleeper, centre).?;
    try testing.expectEqual(@as(Real, 0), inside.distance);
    const outside = world.bm.closestPointBody(&world.store, sleeper, centre.add(v(5, 0, 0))).?;
    try testing.expect(outside.distance > 4 and outside.distance < 5);
    try testing.expect(world.bm.isSleeping(sleeper).?);

    // Still asleep after all four, and the island really did stay down: one more tick
    // must not resurrect it either.
    try world.step(gpa);
    try testing.expect(world.bm.isSleeping(sleeper).?);
}

// ---------------------------------------------------------------------------
// M1.1.10 / E5 — the `shapeCast` entry
// ---------------------------------------------------------------------------

test "shapeCast returns the nearest body along the sweep" {
    // The strict minimum so the body does not ship bare; the full acceptance matrix
    // is E6's. Three unit spheres on +X at 10, 20 and 30, inserted NEAREST-LAST so
    // the answer cannot come from insertion order. A unit sphere swept from the
    // origin along +X first touches the one at 10 when its centre reaches
    // 10 − (1 + 1) = 8.
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = (try addSphereBody(gpa, &world, .{ 30, 0, 0 }, 1)).id;
    _ = (try addSphereBody(gpa, &world, .{ 20, 0, 0 }, 1)).id;
    const near = (try addSphereBody(gpa, &world, .{ 10, 0, 0 }, 1)).id;

    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const q = query_mod.CastQuery{
        .shape = probe,
        .origin = Vec3r.zero,
        .direction = v(1, 0, 0),
        .max_distance = 100,
    };
    const hit = query_mod.shapeCast(&world.bp, &world.bm, &world.store, q).?;
    try testing.expectEqual(near, hit.body);
    try testing.expectApproxEqAbs(@as(Real, 8), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    // The witness is on the HIT body's surface, at x = 10 − 1 = 9.
    try testing.expect(hit.position.approxEql(v(9, 0, 0), tol));

    // A sweep pointing away hits nothing, and a bound short of the contact refuses
    // it — the bound being CLOSED, exactly 8 still answers.
    var away = q;
    away.direction = v(-1, 0, 0);
    try testing.expect(query_mod.shapeCast(&world.bp, &world.bm, &world.store, away) == null);
    var short = q;
    short.max_distance = 7.9;
    try testing.expect(query_mod.shapeCast(&world.bp, &world.bm, &world.store, short) == null);
    var exact = q;
    exact.max_distance = 8;
    try testing.expect(query_mod.shapeCast(&world.bp, &world.bm, &world.store, exact) != null);

    // A zero direction is degenerate and empty, the ray family's guard reused.
    var still = q;
    still.direction = Vec3r.zero;
    try testing.expect(query_mod.shapeCast(&world.bp, &world.bm, &world.store, still) == null);
}

// ---------------------------------------------------------------------------
// M1.1.10 / E6 — the `shapeCast` acceptance suite
// ---------------------------------------------------------------------------
//
// The iteration ceiling is NOT re-tested here: it is pinned in the E3 section above
// (`the iteration ceiling returns a hit at the current parameter`), with the
// discrimination guard proving the cap actually bound. Doubling it would add a
// second control over one behaviour and dilute which one is load-bearing.

/// A static body carrying a box of the given half-extents, on `entity_index`.
fn addBoxBody(gpa: std.mem.Allocator, world: *harness.World, centre: [3]f32, he: [3]f32, entity_index: u32, layer: u8) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(he[0], he[1], he[2]) } });
    return world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(centre[0], centre[1], centre[2]),
        .body_type = .static,
        .collision_layer = layer,
        .entity = .{ .index = entity_index, .generation = 0 },
    });
}

test "the normal at the time of impact is the outward normal of the hit body" {
    // The SIGN is the claim, and it is pinned by a closed-form oracle rather than
    // transcribed: at the contact, B's outward normal points from B's witness back
    // toward the swept A, so for two spheres it is `−(c − t·d̂)/r_sum`. Casting the
    // SAME pair from four different directions walks that vector around the sphere,
    // so a sign error cannot hide behind one lucky axis.
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // A radius-2 sphere at the origin; the probe is a unit sphere started 10 away in
    // each direction and swept back toward it, so `t = 10 − 3 = 7` every time.
    const body = (try addSphereBody(gpa, &world, .{ 0, 0, 0 }, 2)).id;
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });

    const dirs = [_]Vec3r{ v(1, 0, 0), v(0, -1, 0), v(0, 0, 1), v(3, 4, 0).normalize() };
    for (dirs) |unit_d| {
        const start = unit_d.scale(-10);
        const hit = query_mod.shapeCast(&world.bp, &world.bm, &world.store, .{
            .shape = probe,
            .origin = start,
            .direction = unit_d,
            .max_distance = 100,
        }).?;
        try testing.expectEqual(body, hit.body);
        try testing.expectApproxEqAbs(@as(Real, 7), hit.distance, tol);

        // Unit, TIGHT — a degenerate normal is a defect, never an effect of the pose.
        try testing.expectApproxEqAbs(@as(Real, 1), hit.normal.length(), unit_tol);
        // And opposing the sweep, on every hit.
        try testing.expect(hit.normal.dot(unit_d) <= 0);
        // The closed form: A's centre ends at `start + 7·d̂`, three units from the
        // origin, and B's outward normal there points from B's centre toward it —
        // which for this construction is exactly `−d̂`.
        const a_centre = start.add(unit_d.scale(7));
        const want = Vec3r.zero.sub(a_centre).scale(1 / a_centre.length()).neg();
        try testing.expect(hit.normal.approxEql(want, tol));
        try testing.expect(hit.normal.approxEql(unit_d.neg(), tol));
        // The witness sits on B's surface, two units from its centre.
        try testing.expectApproxEqAbs(@as(Real, 2), hit.position.length(), tol);
    }
}

test "initial contact returns a witness on the hit body" {
    // Two shapes ALREADY intersecting at the start pose: distance 0, and the witness
    // lies on or inside the HIT body — which the cast shape's own origin need not.
    //
    // The scene is built so that origin-versus-witness is a real distinction and not
    // a coincidence: the cast shape is a long bar centred at the world origin,
    // spanning x ∈ [−5, 5], and the hit body is a unit box at x = 4.5 spanning
    // [3.5, 5.5]. They overlap over [3.5, 5], so the contact is genuine — and the
    // bar's CENTRE, the cast origin, is at x = 0, nowhere near the body. Both facts
    // are asserted; without the second the test could not tell the rule §1.11.11
    // states from the one it refutes (returning `cast.origin`).
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = try addBoxBody(gpa, &world, .{ 4.5, 0, 0 }, .{ 1, 1, 1 }, 0, 0);
    const bar = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(5, 0.5, 0.5) } });

    const cast_origin = Vec3r.zero;
    // PRECONDITION — the cast origin is DEMONSTRABLY outside the hit body.
    try testing.expect(!world.bm.containsPointBody(&world.store, body, cast_origin).?);
    // …and the two really do overlap at the start pose, so this is an initial
    // contact and not a short sweep.
    try testing.expect(world.bm.overlapShapeBody(
        &world.store,
        body,
        shape_mod.supportShape(world.store.get(bar).?),
        cast_origin,
        Quatr.identity,
    ).?);

    const hit = query_mod.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = bar,
        .origin = cast_origin,
        .direction = v(1, 0, 0),
        .max_distance = 100,
    }).?;
    try testing.expectEqual(body, hit.body);
    try testing.expectEqual(@as(Real, 0), hit.distance);
    // THE CLAIM: the witness is a point OF THE HIT BODY, boundary included.
    try testing.expect(world.bm.containsPointBody(&world.store, body, hit.position).?);
    // …and it is therefore NOT the cast origin, which the assertion above placed
    // outside. Stated separately so the two cannot be confused for one another.
    try testing.expect(!hit.position.approxEql(cast_origin, tol));
    try testing.expectApproxEqAbs(@as(Real, 1), hit.normal.length(), unit_tol);
    try testing.expect(hit.normal.dot(v(1, 0, 0)) <= 0);
}

test "shapeCast honours the object mask and the exclusion list" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // Two unit spheres on +X: the near one on layer 3, the far one on layer 7.
    const near = try addBoxBody(gpa, &world, .{ 10, 0, 0 }, .{ 1, 1, 1 }, 0, 3);
    const far = try addBoxBody(gpa, &world, .{ 20, 0, 0 }, .{ 1, 1, 1 }, 1, 7);
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });

    const base = query_mod.CastQuery{
        .shape = probe,
        .origin = Vec3r.zero,
        .direction = v(1, 0, 0),
        .max_distance = 100,
    };
    // The FULL mask sees the near one.
    try testing.expectEqual(near, query_mod.shapeCast(&world.bp, &world.bm, &world.store, base).?.body);
    // A mask naming only layer 7 skips it and answers the far one.
    var only_far = base;
    only_far.filter = .{ .layer_mask = @as(u32, 1) << 7 };
    try testing.expectEqual(far, query_mod.shapeCast(&world.bp, &world.bm, &world.store, only_far).?.body);
    // The EMPTY mask sees nothing at all.
    var none = base;
    none.filter = .{ .layer_mask = 0 };
    try testing.expect(query_mod.shapeCast(&world.bp, &world.bm, &world.store, none) == null);
    // Exclusions are tested on the body, upstream of the kernel.
    var without_near = base;
    without_near.filter = .{ .exclude = &.{near} };
    try testing.expectEqual(far, query_mod.shapeCast(&world.bp, &world.bm, &world.store, without_near).?.body);
    var without_both = base;
    without_both.filter = .{ .exclude = &.{ near, far } };
    try testing.expect(query_mod.shapeCast(&world.bp, &world.bm, &world.store, without_both) == null);
}

test "shapeCast answers a sleeping body and leaves it asleep" {
    const gpa = std.testing.allocator;
    var world = harness.World.init(harness.vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const sleeper = try sleepingBox(gpa, &world);
    const centre = world.bm.position(sleeper).?;
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.25 } });

    const hit = query_mod.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .origin = v(centre.toArray()[0], 10, centre.toArray()[2]),
        .direction = v(0, -1, 0),
        .max_distance = 100,
    }).?;
    try testing.expectEqual(sleeper, hit.body);
    try testing.expect(world.bm.isSleeping(sleeper).?);
}

test "shapeCast is invariant under creation-order permutation and bit-identical twice" {
    const gpa = std.testing.allocator;
    // Four unit boxes on +X, built in six orders. The answer must name the same
    // ENTITY every time — the identity that survives a permutation — and be
    // bit-identical in distance, position and normal.
    const centres = [4][3]f32{ .{ 12, 0, 0 }, .{ 25, 0, 0 }, .{ 33, 0, 0 }, .{ 41, 0, 0 } };
    const orders = [6][4]usize{
        .{ 0, 1, 2, 3 }, .{ 3, 2, 1, 0 }, .{ 1, 3, 0, 2 },
        .{ 2, 0, 3, 1 }, .{ 0, 3, 1, 2 }, .{ 3, 0, 2, 1 },
    };
    var reference: ?query_mod.CastHit = null;
    for (orders) |order| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        for (order) |which| _ = try addBoxBody(gpa, &world, centres[which], .{ 1, 1, 1 }, @intCast(which), 0);
        const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
        const q = query_mod.CastQuery{
            .shape = probe,
            .origin = Vec3r.zero,
            .direction = v(1, 0, 0),
            .max_distance = 100,
        };

        const hit = query_mod.shapeCast(&world.bp, &world.bm, &world.store, q).?;
        // Two identical runs in the same world are bit-identical.
        const again = query_mod.shapeCast(&world.bp, &world.bm, &world.store, q).?;
        try expectCastBitIdentical(hit, again);

        // The ENTITY, not the `BodyId`: the latter follows creation order by
        // construction and is not what invariance is about.
        try testing.expectEqual(@as(u32, 0), hit.entity.index);
        if (reference) |ref| {
            try testing.expectEqual(ref.entity, hit.entity);
            try expectCastGeometryIdentical(ref, hit);
        } else {
            reference = hit;
            // 12 − 1 (the box's face) − 1 (the probe's radius) = 10.
            try testing.expectApproxEqAbs(@as(Real, 10), hit.distance, tol);
        }
    }
}

/// Field-by-field exact comparison of two cast hits, identity included.
fn expectCastBitIdentical(x: query_mod.CastHit, y: query_mod.CastHit) !void {
    try testing.expectEqual(x.body, y.body);
    try testing.expectEqual(x.entity, y.entity);
    try testing.expectEqual(x.subshape_id, y.subshape_id);
    try testing.expectEqual(x.cast_subshape_id, y.cast_subshape_id);
    try expectCastGeometryIdentical(x, y);
}

/// The geometry alone — used across worlds, where the `BodyId` legitimately differs.
fn expectCastGeometryIdentical(x: query_mod.CastHit, y: query_mod.CastHit) !void {
    try testing.expectEqual(x.distance, y.distance);
    inline for (0..3) |i| {
        try testing.expectEqual(x.position.toArray()[i], y.position.toArray()[i]);
        try testing.expectEqual(x.normal.toArray()[i], y.normal.toArray()[i]);
    }
}

/// Drive the published harness until a box falls asleep on the ground, and return it.
/// Shared by the per-entry sleeping tests: a query takes `*const BodyManager` and so
/// cannot wake anything even in principle, but a structural argument never observed
/// is still only an argument.
pub fn sleepingBox(gpa: std.mem.Allocator, world: *harness.World) !api.BodyId {
    const ground_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(20, 0.5, 20) } });
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(0.5, 0.5, 0.5) } });
    _ = try world.addBody(gpa, .{
        .shape = ground_shape,
        .body_type = .static,
        .restitution = 0,
        .entity = .{ .index = 0, .generation = 0 },
    });
    const sleeper = try world.addBody(gpa, .{
        .shape = box_shape,
        .position = harness.av3(0, 1, 0),
        .body_type = .dynamic,
        .mass = 1,
        .restitution = 0,
        .entity = .{ .index = 1, .generation = 0 },
    });
    var had_contact = false;
    var t: u32 = 0;
    const asleep = while (t < 600) : (t += 1) {
        try world.step(gpa);
        if (world.constraints.items.len > 0) {
            had_contact = true;
        } else if (had_contact) break true;
    } else false;
    try testing.expect(asleep);
    try testing.expect(world.bm.isSleeping(sleeper).?);
    return sleeper;
}
