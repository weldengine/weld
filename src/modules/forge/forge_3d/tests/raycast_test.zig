//! Acceptance suite for the raycast query (M1.1.9).
//!
//! Grows gate by gate: E3 covers the analytic ray↔core kernels of
//! `pipeline/narrowphase/raycast.zig` against closed-form oracles, in the shape's
//! local frame. E6 adds the query-level suite — selection modes, filtering,
//! tie-break, sleeping bodies, determinism — on top of `forge_3d/query.zig`.
//!
//! Every expectation here is a CLOSED FORM computed by hand in the comment above
//! it, never a value read back from the implementation.

const std = @import("std");
const math = @import("foundation").math;
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const config = @import("../config.zig");

const testing = std.testing;

/// The kernels are exercised at the solver's own scalar so `-Dphysics_f64`
/// covers them, matching the M1.1.1 precedent for the `BodyManager` gate.
const Real = config.Real;
const Vec3r = config.Vec3r;
const SupportShapeR = narrowphase.SupportShape(Real);

/// Absolute tolerance for a distance or a coordinate: float noise at the scale
/// these tests work at (unit-to-ten geometry), not a geometric slack.
const tol: Real = if (Real == f32) 1e-5 else 1e-12;

fn v(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// Unit direction from an arbitrary vector — the kernels require `|d| == 1`.
fn dir(x: Real, y: Real, z: Real) Vec3r {
    return v(x, y, z).normalize();
}

/// Assert the hit invariants that hold for EVERY hit, whatever the shape: a
/// non-negative distance, a unit normal, and a normal that opposes the ray
/// (§1.11.4). Called by every kernel test so no case escapes them.
fn expectHitInvariants(hit: narrowphase.LocalHit(Real), ray_dir: Vec3r) !void {
    try testing.expect(hit.distance >= 0);
    try testing.expectApproxEqAbs(@as(Real, 1), hit.normal.length(), tol);
    try testing.expect(hit.normal.dot(ray_dir) <= 0);
}

test "ray hits a sphere at the closed-form point and normal" {
    const sphere = SupportShapeR{ .core = .point, .radius = 2 };

    // Head-on along +X from x = −10: the surface is at x = −2, so t = 8 and the
    // outward normal is −X.
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, sphere, v(-10, 0, 0), d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(@as(Real, 8), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    }

    // Oblique: from (−10, 1, 0) along +X. The chord solves 1 + x² = 4, so
    // x = −√3 at entry, t = 10 − √3, and the normal is (−√3, 1, 0)/2.
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, sphere, v(-10, 1, 0), d)).?;
        try expectHitInvariants(hit, d);
        const root3: Real = @sqrt(@as(Real, 3));
        try testing.expectApproxEqAbs(10 - root3, hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-root3 / 2, 0.5, 0), tol));
        // The hit point is ON the surface: |p| == r.
        const p = v(-10, 1, 0).add(d.scale(hit.distance));
        try testing.expectApproxEqAbs(sphere.radius, p.length(), tol);
    }

    // Grazing tangent: from (−10, 2, 0) along +X touches at exactly one point,
    // x = 0, t = 10, normal +Y.
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, sphere, v(-10, 2, 0), d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(@as(Real, 10), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(0, 1, 0), tol));
    }

    // A non-axis-aligned DIRECTION, still hand-computable: from (−3, −3, 0) along
    // (1, 1, 0)/√2, the line y = x runs through the centre. The entry is then at
    // `|o| − r = 3√2 − 2` and the surface point is `−r/√2 · (1, 1, 0)`, giving the
    // normal (−1, −1, 0)/√2.
    {
        const o = v(-3, -3, 0);
        const d = dir(1, 1, 0);
        const inv_root2: Real = 1 / @sqrt(@as(Real, 2));
        const hit = (try narrowphase.rayShape(Real, sphere, o, d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(3 * @sqrt(@as(Real, 2)) - sphere.radius, hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-inv_root2, -inv_root2, 0), tol));
        const p = o.add(d.scale(hit.distance));
        try testing.expectApproxEqAbs(sphere.radius, p.length(), tol);
    }

    // A genuine miss with a non-axis-aligned direction, to show the discriminant
    // branch is reached and not merely the silhouette test: from (−6, 0, 0) along
    // (1, 1, 0)/√2 the closest approach is 6/√2 ≈ 4.24, well past r = 2.
    try testing.expect((try narrowphase.rayShape(Real, sphere, v(-6, 0, 0), dir(1, 1, 0))) == null);

    // Misses: past the silhouette, and pointing away from a sphere in front.
    {
        try testing.expect((try narrowphase.rayShape(Real, sphere, v(-10, 2.001, 0), dir(1, 0, 0))) == null);
        try testing.expect((try narrowphase.rayShape(Real, sphere, v(-10, 0, 0), dir(-1, 0, 0))) == null);
    }
}

test "ray hits a rotated box on the correct face" {
    // The kernel works in the box's LOCAL frame, so "rotated" is expressed by
    // rotating the RAY into that frame — which is exactly what the pose transport
    // of `raycastBody` does. A ray that is oblique in world space is an oblique
    // local ray here, and the face oracle is per local axis.
    const he = v(1, 2, 3);
    const box = SupportShapeR{ .core = .{ .box = he }, .radius = 0 };

    // Each of the six faces, hit head-on from outside along its own axis: the
    // distance is `start − half_extent` and the normal is the face normal.
    const cases = [_]struct { origin: Vec3r, d: Vec3r, distance: Real, normal: Vec3r }{
        .{ .origin = v(-10, 0, 0), .d = dir(1, 0, 0), .distance = 9, .normal = v(-1, 0, 0) },
        .{ .origin = v(10, 0, 0), .d = dir(-1, 0, 0), .distance = 9, .normal = v(1, 0, 0) },
        .{ .origin = v(0, -10, 0), .d = dir(0, 1, 0), .distance = 8, .normal = v(0, -1, 0) },
        .{ .origin = v(0, 10, 0), .d = dir(0, -1, 0), .distance = 8, .normal = v(0, 1, 0) },
        .{ .origin = v(0, 0, -10), .d = dir(0, 0, 1), .distance = 7, .normal = v(0, 0, -1) },
        .{ .origin = v(0, 0, 10), .d = dir(0, 0, -1), .distance = 7, .normal = v(0, 0, 1) },
    };
    for (cases) |case| {
        const hit = (try narrowphase.rayShape(Real, box, case.origin, case.d)).?;
        try expectHitInvariants(hit, case.d);
        try testing.expectApproxEqAbs(case.distance, hit.distance, tol);
        try testing.expect(hit.normal.approxEql(case.normal, tol));
    }

    // Oblique entry through the +X face: from (5, 0, 0) along (−1, 0.25, 0)/|·|.
    // The +X face is at x = 1, reached after Δx = −4, i.e. t = 4/|dx| with
    // dx = −1/√(1.0625). At that t, y = 0.25·4 = 1 < 2, so the entry really is
    // the +X face and not the +Y one.
    {
        const o = v(5, 0, 0);
        const raw = v(-1, 0.25, 0);
        const d = raw.normalize();
        const t = 4 / @abs(d.toArray()[0]);
        const hit = (try narrowphase.rayShape(Real, box, o, d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(t, hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(1, 0, 0), tol));
        const p = o.add(d.scale(hit.distance));
        try testing.expectApproxEqAbs(@as(Real, 1), p.toArray()[0], tol);
        try testing.expect(@abs(p.toArray()[1]) <= he.toArray()[1]);
    }

    // A ray parallel to a face plane, exactly on it: the −Z face plane at
    // z = −3, travelling +X. Face-inclusive, so the origin at z = −3 outside the
    // box in x still enters at x = −1, and the entry axis is X.
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, box, v(-10, 0, -3), d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    }

    // Misses: beside the box, and behind the ray.
    try testing.expect((try narrowphase.rayShape(Real, box, v(-10, 5, 0), dir(1, 0, 0))) == null);
    try testing.expect((try narrowphase.rayShape(Real, box, v(-10, 0, 0), dir(-1, 0, 0))) == null);
}

test "an exact edge entry resolves to the first axis" {
    // The box kernel documents a fixed tie-break — the FIRST axis wins an exact
    // tie — and a documented tie-break with no discriminating test is a claim,
    // not a behaviour. A cube plus a direction whose X and Y components are the
    // same value makes the two entry parameters bit-identical, which is the
    // precondition this test asserts BEFORE asserting the winner: without it the
    // test would merely be reporting whichever parameter happened to be larger.
    const box = SupportShapeR{ .core = .{ .box = v(1, 1, 1) }, .radius = 0 };
    const o = v(-2, -2, 0);
    const d = dir(1, 1, 0);
    const da = d.toArray();
    try testing.expectEqual(da[0], da[1]); // symmetric by construction

    const t_x = (-1 - o.toArray()[0]) / da[0];
    const t_y = (-1 - o.toArray()[1]) / da[1];
    try testing.expectEqual(t_x, t_y); // the tie is EXACT, not approximate

    const hit = (try narrowphase.rayShape(Real, box, o, d)).?;
    try expectHitInvariants(hit, d);
    try testing.expectApproxEqAbs(t_x, hit.distance, tol);
    // X is axis 0, so the −X face wins; a last-axis-wins tie-break would report
    // (0, −1, 0) here.
    try testing.expect(hit.normal.eql(v(-1, 0, 0)));
}

test "the capsule wall and cap agree exactly on the frontier" {
    // At `|y| == half_height` the cylinder wall and the cap sphere touch, so both
    // branches of the `|y| <= half_height` test describe the same surface point
    // with the same normal. This pins that continuity — which is also why the
    // `<=`-vs-`<` choice at the frontier is unobservable rather than a hidden
    // behaviour: the two paths coincide there, and diverge only away from it
    // (covered by the wall and cap cases above).
    const r: Real = 1;
    const h: Real = 3;
    const capsule = SupportShapeR{ .core = .{ .segment = h }, .radius = r };
    const d = dir(1, 0, 0);

    // Entry exactly at y == h: the wall gives x = −r, the top cap sphere centred
    // (0, h, 0) also gives x = −r, and both normals are (−1, 0, 0).
    const hit = (try narrowphase.rayShape(Real, capsule, v(-10, h, 0), d)).?;
    try expectHitInvariants(hit, d);
    try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
}

test "a zero-half-height capsule is a sphere and the cap tie is harmless" {
    // With `half_height == 0` the two cap spheres coincide, which is the only way
    // the cap tie-break in `capEntry` is reachable at all — and there both
    // candidates carry the same distance AND the same normal, so the tie-break
    // cannot be observed. Recorded rather than claimed: the branch is defensive.
    const capsule = SupportShapeR{ .core = .{ .segment = 0 }, .radius = 2 };
    const d = dir(0, -1, 0);
    const hit = (try narrowphase.rayShape(Real, capsule, v(0, 10, 0), d)).?;
    try expectHitInvariants(hit, d);
    try testing.expectApproxEqAbs(@as(Real, 8), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(0, 1, 0), tol));

    // And it behaves as the sphere of the same radius would, off-axis too. The
    // direction is built by AIMING at an interior point, so the case cannot
    // silently degenerate into a miss comparison.
    const sphere = SupportShapeR{ .core = .point, .radius = 2 };
    const from = v(-8, 1, 0.5);
    const target = v(0.5, 0.5, 0); // inside both shapes
    const oblique = target.sub(from).normalize();
    const as_capsule = (try narrowphase.rayShape(Real, capsule, from, oblique)).?;
    const as_sphere = (try narrowphase.rayShape(Real, sphere, from, oblique)).?;
    try testing.expectApproxEqAbs(as_sphere.distance, as_capsule.distance, tol);
    try testing.expect(as_sphere.normal.approxEql(as_capsule.normal, tol));
}

test "the box kernel and Aabb.rayInterval agree on the interval" {
    // `rayBox` runs its own slab pass because it needs the entry AXIS, which
    // `rayInterval` does not report. That duplication is only safe if the two
    // agree, so it is pinned rather than asserted in a comment.
    const he = v(1, 2, 3);
    const box = SupportShapeR{ .core = .{ .box = he }, .radius = 0 };
    const aabb = math.Aabb(Real).fromCenterHalfExtents(Vec3r.zero, he);

    var prng = std.Random.DefaultPrng.init(0xB0FF_1E5A);
    const rng = prng.random();

    var checked: usize = 0;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const o = v(
            (rng.float(f32) * 20 - 10),
            (rng.float(f32) * 20 - 10),
            (rng.float(f32) * 20 - 10),
        );
        // Half the rays are AIMED at a random point of the box, so real entry
        // intervals dominate the sample; the other half are free directions,
        // including axis-aligned ones (zero lanes) on purpose, and are mostly
        // misses. Both halves are compared — the aim only decides the mix.
        const raw = switch (i % 4) {
            0 => v(1, 0, 0),
            1 => v(0, 1, 0),
            2 => v(0, 0, 1),
            else => v(
                (rng.float(f32) * 2 - 1) * he.toArray()[0],
                (rng.float(f32) * 2 - 1) * he.toArray()[1],
                (rng.float(f32) * 2 - 1) * he.toArray()[2],
            ).sub(o),
        };
        if (raw.lengthSq() == 0) continue;
        const d = raw.normalize();

        const inv = Vec3r{ .data = @as(@Vector(3, Real), @splat(1)) / d.data };
        const zero_mask = d.data == @as(@Vector(3, Real), @splat(0));
        const interval = aabb.rayInterval(o, inv, zero_mask);
        const hit = try narrowphase.rayShape(Real, box, o, d);

        if (interval) |iv| {
            if (iv.exit < 0) {
                try testing.expect(hit == null); // box behind the origin
            } else if (iv.enter < 0) {
                // The origin is inside the box: distance zero by the solid rule.
                try testing.expectEqual(@as(Real, 0), hit.?.distance);
            } else {
                try testing.expectApproxEqAbs(iv.enter, hit.?.distance, tol);
                checked += 1;
            }
        } else {
            try testing.expect(hit == null);
        }
    }
    // The comparison must actually have happened on real entries.
    try testing.expect(checked > 100);
}

test "ray hits a capsule on the cylinder and on each cap" {
    const r: Real = 1;
    const h: Real = 3;
    const capsule = SupportShapeR{ .core = .{ .segment = h }, .radius = r };

    // Cylinder wall, head-on at mid-height: from (−10, 0, 0) along +X the wall
    // is at x = −1, so t = 9 and the normal is −X (purely radial, zero in Y).
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, capsule, v(-10, 0, 0), d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
        try testing.expectEqual(@as(Real, 0), hit.normal.toArray()[1]);
    }

    // Cylinder wall just BELOW the top cap plane (y = 2.9 < h): still the wall.
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, capsule, v(-10, 2.9, 0), d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    }

    // Top cap: from (−10, 3.5, 0) along +X. The cap sphere is centred (0, 3, 0)
    // with r = 1; at y = 3.5 the chord solves x² + 0.25 = 1, so x = −√0.75 and
    // t = 10 − √0.75. The normal is (−√0.75, 0.5, 0).
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, capsule, v(-10, 3.5, 0), d)).?;
        try expectHitInvariants(hit, d);
        const x: Real = @sqrt(@as(Real, 0.75));
        try testing.expectApproxEqAbs(10 - x, hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-x, 0.5, 0), tol));
        // A cap normal has a NON-zero Y component — that is what distinguishes
        // it from a wall hit, so the two regimes are told apart, not just hit.
        try testing.expect(@abs(hit.normal.toArray()[1]) > 0.1);
    }

    // Bottom cap, mirrored: from (−10, −3.5, 0) along +X.
    {
        const d = dir(1, 0, 0);
        const hit = (try narrowphase.rayShape(Real, capsule, v(-10, -3.5, 0), d)).?;
        try expectHitInvariants(hit, d);
        const x: Real = @sqrt(@as(Real, 0.75));
        try testing.expectApproxEqAbs(10 - x, hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(-x, -0.5, 0), tol));
    }

    // Cap dome from straight above: from (0, 10, 0) along −Y hits the top of the
    // top cap at y = h + r = 4, so t = 6 and the normal is +Y.
    {
        const d = dir(0, -1, 0);
        const hit = (try narrowphase.rayShape(Real, capsule, v(0, 10, 0), d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectApproxEqAbs(@as(Real, 6), hit.distance, tol);
        try testing.expect(hit.normal.approxEql(v(0, 1, 0), tol));
    }

    // The wall/cap boundary crossed in BOTH directions, one ulp either side of
    // y = h: below it the normal is purely radial, above it the Y component is
    // non-zero. This is the frontier the `|y| <= half_height` slab decides.
    {
        const d = dir(1, 0, 0);
        const below = (try narrowphase.rayShape(Real, capsule, v(-10, nextBelow(h), 0), d)).?;
        try testing.expectEqual(@as(Real, 0), below.normal.toArray()[1]);
        try testing.expectApproxEqAbs(@as(Real, 9), below.distance, tol);

        const above = (try narrowphase.rayShape(Real, capsule, v(-10, nextAbove(h), 0), d)).?;
        try testing.expect(above.normal.toArray()[1] != 0);
        // Just past the cap plane the cap is all but tangent to the wall, so the
        // distance is continuous across the frontier.
        try testing.expectApproxEqAbs(below.distance, above.distance, tol);
    }

    // A ray exactly parallel to the capsule axis (zero radial speed, the true-zero
    // branch): inside the cylinder radius it hits the cap dome, outside it misses
    // however long it runs.
    {
        const d = dir(0, -1, 0);
        const inside = (try narrowphase.rayShape(Real, capsule, v(0.5, 10, 0), d)).?;
        try expectHitInvariants(inside, d);
        // Cap sphere centred (0, 3, 0), r = 1, at x = 0.5 → y = 3 + √0.75.
        try testing.expectApproxEqAbs(10 - (3 + @sqrt(@as(Real, 0.75))), inside.distance, tol);

        try testing.expect((try narrowphase.rayShape(Real, capsule, v(1.5, 10, 0), d)) == null);
    }

    // Misses: past the silhouette, and pointing away.
    try testing.expect((try narrowphase.rayShape(Real, capsule, v(-10, 4.001, 0), dir(1, 0, 0))) == null);
    try testing.expect((try narrowphase.rayShape(Real, capsule, v(-10, 0, 0), dir(-1, 0, 0))) == null);
}

/// The next representable value below `x` — used to straddle an exact frontier
/// without inventing a tolerance.
fn nextBelow(x: Real) Real {
    return std.math.nextAfter(Real, x, -std.math.inf(Real));
}

/// The next representable value above `x`.
fn nextAbove(x: Real) Real {
    return std.math.nextAfter(Real, x, std.math.inf(Real));
}

test "an origin inside a shape hits at distance zero with the negated direction" {
    const d = dir(1, 2, -3);
    const shapes = [_]SupportShapeR{
        .{ .core = .point, .radius = 2 },
        .{ .core = .{ .box = v(1, 2, 3) }, .radius = 0 },
        .{ .core = .{ .segment = 3 }, .radius = 1 },
    };
    for (shapes) |shape| {
        const hit = (try narrowphase.rayShape(Real, shape, Vec3r.zero, d)).?;
        try expectHitInvariants(hit, d);
        try testing.expectEqual(@as(Real, 0), hit.distance);
        try testing.expect(hit.normal.eql(d.neg())); // exactly, not approximately
    }

    // The BOUNDARY counts as inside — the solid body is closed. A sphere origin
    // exactly on the surface, a box origin exactly on a face, a capsule origin
    // exactly on the cap pole.
    const on_surface = [_]struct { shape: SupportShapeR, origin: Vec3r }{
        .{ .shape = shapes[0], .origin = v(2, 0, 0) },
        .{ .shape = shapes[1], .origin = v(1, 0, 0) },
        .{ .shape = shapes[2], .origin = v(0, 4, 0) },
    };
    for (on_surface) |case| {
        const hit = (try narrowphase.rayShape(Real, case.shape, case.origin, d)).?;
        try testing.expectEqual(@as(Real, 0), hit.distance);
        try testing.expect(hit.normal.eql(d.neg()));
    }
}

test "a rounded box fails loud instead of missing silently" {
    // A box core with a non-zero inflation radius is outside this milestone's
    // shape set. It must be an error, never a null (which would read as "no hit")
    // and never a plain box (which would under-report the surface).
    const rounded = SupportShapeR{ .core = .{ .box = v(1, 1, 1) }, .radius = 0.25 };

    // The DISCRIMINATING case: an origin INSIDE the core. It is the only one that
    // tells a rejection carried by the SHAPE from a rejection carried by the
    // trajectory — with the check placed after the solid-membership test, this
    // input returned a distance-zero hit and never reached the rejection at all,
    // while the exterior case below passed for an apparent reason that did not
    // cover it. No mutation of the kernels could have surfaced that: mutation
    // tests the code against the tests present, never the tests against the
    // inputs absent.
    try testing.expectError(
        error.UnsupportedShape,
        narrowphase.rayShape(Real, rounded, Vec3r.zero, dir(1, 0, 0)),
    );
    // On a face of the core, likewise inside for the membership test.
    try testing.expectError(
        error.UnsupportedShape,
        narrowphase.rayShape(Real, rounded, v(1, 0, 0), dir(1, 0, 0)),
    );
    // The exterior origin stays — it costs nothing and covers the ordinary path.
    try testing.expectError(
        error.UnsupportedShape,
        narrowphase.rayShape(Real, rounded, v(-10, 0, 0), dir(1, 0, 0)),
    );
    // A radius-0 box on the same geometry is fine — so the error is about the
    // radius and not about the box.
    const plain = SupportShapeR{ .core = .{ .box = v(1, 1, 1) }, .radius = 0 };
    try testing.expect((try narrowphase.rayShape(Real, plain, v(-10, 0, 0), dir(1, 0, 0))) != null);
}

test "a degenerate zero radius never divides by zero" {
    // Nothing validates a zero radius at shape creation yet (descriptor
    // validation is a later milestone), so the kernels must stay defined on it.
    // A zero-radius sphere is a point and a zero-radius capsule a bare segment:
    // the hit is measure-zero, but when it happens the normal must still satisfy
    // the invariants rather than come out NaN.
    const point_sphere = SupportShapeR{ .core = .point, .radius = 0 };
    const d = dir(1, 0, 0);
    const through_centre = (try narrowphase.rayShape(Real, point_sphere, v(-10, 0, 0), d)).?;
    try expectHitInvariants(through_centre, d);
    try testing.expectApproxEqAbs(@as(Real, 10), through_centre.distance, tol);

    const bare_segment = SupportShapeR{ .core = .{ .segment = 3 }, .radius = 0 };
    const at_axis = (try narrowphase.rayShape(Real, bare_segment, v(-10, 1, 0), d)).?;
    try expectHitInvariants(at_axis, d);
    try testing.expectApproxEqAbs(@as(Real, 10), at_axis.distance, tol);
}

test "containsPoint is the solid membership the zero-distance rule rests on" {
    const sphere = SupportShapeR{ .core = .point, .radius = 2 };
    try testing.expect(narrowphase.containsPoint(Real, sphere, Vec3r.zero));
    try testing.expect(narrowphase.containsPoint(Real, sphere, v(2, 0, 0))); // boundary
    try testing.expect(!narrowphase.containsPoint(Real, sphere, v(2.001, 0, 0)));

    const box = SupportShapeR{ .core = .{ .box = v(1, 2, 3) }, .radius = 0 };
    try testing.expect(narrowphase.containsPoint(Real, box, v(1, 2, 3))); // corner
    try testing.expect(!narrowphase.containsPoint(Real, box, v(1.001, 0, 0)));

    const capsule = SupportShapeR{ .core = .{ .segment = 3 }, .radius = 1 };
    try testing.expect(narrowphase.containsPoint(Real, capsule, v(0, 3.999, 0)));
    try testing.expect(narrowphase.containsPoint(Real, capsule, v(1, 0, 0))); // wall boundary
    try testing.expect(!narrowphase.containsPoint(Real, capsule, v(0, 4.001, 0)));
    try testing.expect(!narrowphase.containsPoint(Real, capsule, v(0.8, 3.8, 0))); // outside the cap dome
}

// ---------------------------------------------------------------------------
// M1.1.9 / E4 — the `Real`-bound query entries over a real broadphase
// ---------------------------------------------------------------------------
//
// The harness is NOT duplicated: `World` comes from `tests/solver_test.zig`, the
// same published harness the solver, position-solver and sleep suites drive. It
// owns the `(store, bm, bp)` triple the query entries take, and its `addBody`
// inserts the broadphase proxy with `user_data == BodyId`, which is exactly the
// identity `query.zig` unpacks.
//
// This section is the EMPIRICAL CONSUMER the surface-coverage rule asks for
// (`engine-zig-conventions.md` §13): a compile-green proves the signatures agree
// with their call sites, never that the bodies are right. The full acceptance
// matrix — selection modes over a scene sweep, filtering cases, the `BodyId`
// tie-break with its bit-identical precondition, sleeping bodies, the closed
// `max_distance`, creation-order invariance — is E6's.

const harness = @import("solver_test.zig");
const query = @import("../query.zig");
const body_manager_mod = @import("../body_manager.zig");
const broadphase_mod = @import("../pipeline/broadphase.zig");
const api = @import("weld_forge");
const foundation_math = @import("foundation").math;

/// A unit-radius sphere body at `centre`, dynamic, on collision layer `layer`.
fn addSphere(gpa: std.mem.Allocator, world: *harness.World, centre: Vec3r, layer: u8) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    return world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(@floatCast(centre.data[0]), @floatCast(centre.data[1]), @floatCast(centre.data[2])),
        .body_type = .dynamic,
        .collision_layer = layer,
        .entity = .{ .index = 0, .generation = 0 },
    });
}

test "the three query entries agree over a real broadphase" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // Three spheres on the +X axis at 10, 20, 30, inserted NEAREST-LAST so the
    // answer cannot come from insertion order.
    const far = try addSphere(gpa, &world, v(30, 0, 0), 0);
    const mid = try addSphere(gpa, &world, v(20, 0, 0), 0);
    const near = try addSphere(gpa, &world, v(10, 0, 0), 0);

    const q = query.RayQuery{ .origin = Vec3r.zero, .direction = v(1, 0, 0), .max_distance = 100 };

    // closest → the nearest of the three, at its closed-form surface distance.
    const hit = (try query.raycast(&world.bp, &world.bm, &world.store, q)).?;
    try testing.expectEqual(near, hit.body);
    try testing.expectApproxEqAbs(@as(Real, 9), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));
    try testing.expect(hit.position.approxEql(v(9, 0, 0), tol));

    // any → true, and it agrees with closest on existence.
    try testing.expect(try query.raycastAny(&world.bp, &world.bm, &world.store, q));

    // all → the three, sorted by distance.
    var buf: [8]query.RayHit = undefined;
    const n = try query.raycastAll(&world.bp, &world.bm, &world.store, q, &buf);
    try testing.expectEqual(@as(u32, 3), n);
    try testing.expectEqual(near, buf[0].body);
    try testing.expectEqual(mid, buf[1].body);
    try testing.expectEqual(far, buf[2].body);
    try testing.expect(buf[0].distance < buf[1].distance and buf[1].distance < buf[2].distance);

    // A ray pointing away hits nothing, in all three modes.
    const away = query.RayQuery{ .origin = Vec3r.zero, .direction = v(-1, 0, 0), .max_distance = 100 };
    try testing.expect((try query.raycast(&world.bp, &world.bm, &world.store, away)) == null);
    try testing.expect(!try query.raycastAny(&world.bp, &world.bm, &world.store, away));
    try testing.expectEqual(@as(u32, 0), try query.raycastAll(&world.bp, &world.bm, &world.store, away, &buf));
}

test "raycastBody transports the ray by the inverse pose" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // A box at (10, 0, 0) rotated 90° about +Z: its local +X half-extent (1) now
    // points along world +Y, and the local +Y half-extent (3) along world −X. A
    // world ray along +X therefore enters the face whose LOCAL normal is +Y, and
    // the world normal comes back as −X after the rotation.
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(1, 3, 1) } });
    const rot = foundation_math.Quatf.fromAxisAngle(harness.av3(0, 0, 1), std.math.pi / 2.0);
    const id = try world.addBody(gpa, .{
        .shape = shape,
        .position = harness.av3(10, 0, 0),
        .rotation = rot,
        .body_type = .static,
        .entity = .{ .index = 0, .generation = 0 },
    });

    const ray = query.Ray.init(Vec3r.zero, v(1, 0, 0));
    const local = (try world.bm.raycastBody(&world.store, id, ray)).?;
    // World entry at x = 10 − 3 = 7 (the local +Y extent faces −X).
    try testing.expectApproxEqAbs(@as(Real, 7), local.distance, tol);
    // The LOCAL normal is +Y; rotating it by the body's rotation gives world −X.
    try testing.expect(local.normal.approxEql(v(0, 1, 0), tol));
    try testing.expect(world.bm.rotation(id).?.rotateVec3(local.normal).approxEql(v(-1, 0, 0), tol));

    // And the full query agrees, position included.
    const q = query.RayQuery{ .origin = Vec3r.zero, .direction = v(1, 0, 0), .max_distance = 100 };
    const hit = (try query.raycast(&world.bp, &world.bm, &world.store, q)).?;
    try testing.expectApproxEqAbs(@as(Real, 7), hit.distance, tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));

    // A stale handle answers null rather than reading garbage.
    world.removeBody(id);
    try testing.expect((try world.bm.raycastBody(&world.store, id, ray)) == null);
}

test "a zero direction returns an empty result in every mode" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try addSphere(gpa, &world, v(10, 0, 0), 0);

    // The guard is at TRUE ZERO on `d · d`, and a direction small enough to be
    // unusable underflows to exactly that at both precisions — so this covers the
    // denormal case without an epsilon.
    const tiny = std.math.floatTrueMin(Real);
    for ([_]Vec3r{ Vec3r.zero, v(tiny, 0, 0), v(tiny, tiny, tiny) }) |d| {
        const q = query.RayQuery{ .origin = Vec3r.zero, .direction = d, .max_distance = 100 };
        try testing.expectEqual(@as(Real, 0), d.lengthSq()); // the square really underflows
        try testing.expect((try query.raycast(&world.bp, &world.bm, &world.store, q)) == null);
        try testing.expect(!try query.raycastAny(&world.bp, &world.bm, &world.store, q));
        var buf: [4]query.RayHit = undefined;
        try testing.expectEqual(@as(u32, 0), try query.raycastAll(&world.bp, &world.bm, &world.store, q, &buf));
    }
}

test "no reachable shape makes a query fail, and the error channel is not dead code" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // RECORDED, because it changes what this milestone can claim: through
    // `BodyManager.raycastBody`, `error.UnsupportedShape` is currently
    // UNREACHABLE. `shape.supportShape` maps a box to `radius = 0`
    // unconditionally, and `ShapeStore` holds only sphere / box / capsule, so no
    // `SupportShape` reaching the kernel can be a rounded box. The error channel
    // is therefore structurally required — the kernel's signature carries it and
    // E3 pins it at the kernel level — but it cannot be exercised end-to-end
    // until a shape whose `SupportShape` can carry an unsupported combination
    // exists (Plane / MeshShape, M1.1.11). This test asserts what IS reachable:
    // every shape the store can build answers a query without error.
    const sphere = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const box = try world.store.createShape(gpa, .{ .box = .{ .half_extents = harness.av3(1, 1, 1) } });
    const capsule = try world.store.createShape(gpa, .{ .capsule = .{ .radius = 0.5, .half_height = 1 } });
    for ([_]api.ShapeId{ sphere, box, capsule }, 0..) |shape_id, i| {
        _ = try world.addBody(gpa, .{
            .shape = shape_id,
            .position = harness.av3(10 + @as(f32, @floatFromInt(i)) * 10, 0, 0),
            .body_type = .static,
            .entity = .{ .index = @intCast(i), .generation = 0 },
        });
    }

    const q = query.RayQuery{ .origin = Vec3r.zero, .direction = v(1, 0, 0), .max_distance = 100 };
    var buf: [8]query.RayHit = undefined;
    // No error, and all three bodies answer.
    try testing.expect((try query.raycast(&world.bp, &world.bm, &world.store, q)) != null);
    try testing.expect(try query.raycastAny(&world.bp, &world.bm, &world.store, q));
    try testing.expectEqual(@as(u32, 3), try query.raycastAll(&world.bp, &world.bm, &world.store, q, &buf));
}

// ---------------------------------------------------------------------------
// M1.1.9 / E5 — the frozen family and the collision-layer domain
// ---------------------------------------------------------------------------

test "a body on layer 32 or above is refused at creation" {
    const gpa = std.testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });

    // The last legal layer is accepted...
    const ok = try world.bm.addBody(gpa, &world.store, .{
        .shape = shape,
        .collision_layer = api.collision_layer_count - 1,
        .body_type = .static,
        .entity = .{ .index = 0, .generation = 0 },
    });
    try testing.expect(world.bm.isValid(ok));
    const count_before = world.bm.count();

    // ...and the first illegal one is a TYPED error, not a body no query could see.
    for ([_]u8{ api.collision_layer_count, 33, 200, 255 }) |layer| {
        try testing.expectError(error.InvalidCollisionLayer, world.bm.addBody(gpa, &world.store, .{
            .shape = shape,
            .collision_layer = layer,
            .body_type = .static,
            .entity = .{ .index = 1, .generation = 0 },
        }));
    }
    // Nothing was created on the way: the rejection precedes every mutation.
    try testing.expectEqual(count_before, world.bm.count());
}

test "the five deferred query entries carry their frozen signatures" {
    // A `@panic` body cannot be exercised by a test, by construction — so what is
    // pinned here is the SURFACE, at comptime: the exact signature each entry will
    // still have after the M1.1.15 freeze. This is the comptime-interface-check
    // pattern of `engine-zig-conventions.md` §13, which validates the signature and
    // explicitly not the body. The body is M1.1.10's, and it fails loud rather than
    // returning the `null` or `0` that these error-free return types would
    // otherwise force — "no hit" and "no entities" are not true.
    const BM = body_manager_mod.BodyManager;
    const SS = body_manager_mod.ShapeStore;
    const BP = broadphase_mod.Broadphase(Real);

    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, api.ShapeCastQuery) ?api.ShapeCastHit,
        @TypeOf(query.shapeCast),
    );
    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, api.OverlapQuery, []api.EntityId) u32,
        @TypeOf(query.overlapShape),
    );
    try testing.expectEqual(
        fn (*const BP, *const BM, Vec3r, Vec3r, api.PhysicsQueryFilter, []api.EntityId) u32,
        @TypeOf(query.overlapAabb),
    );
    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, Vec3r, api.PhysicsQueryFilter, []api.EntityId) u32,
        @TypeOf(query.pointQuery),
    );
    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, Vec3r, Real, api.PhysicsQueryFilter) ?api.ClosestPointResult,
        @TypeOf(query.closestPoint),
    );

    // The three raycast entries are NOT stubs: they are implemented at `Real` and
    // return the solver-side `RayHit`, with the error channel the kernel needs.
    // Their f32 public wrapper is the interface tier's (M1.1.15).
    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, query.RayQuery) query.Error!?query.RayHit,
        @TypeOf(query.raycast),
    );
    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, query.RayQuery) query.Error!bool,
        @TypeOf(query.raycastAny),
    );
    try testing.expectEqual(
        fn (*const BP, *const BM, *const SS, query.RayQuery, []query.RayHit) query.Error!u32,
        @TypeOf(query.raycastAll),
    );
}
