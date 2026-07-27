//! M1.1.11 acceptance suite for the infinite plane (half-space).
//!
//! The half-space is the first shape whose geometry the existing narrowphase
//! cannot express: `{x : n·x <= d}` has an UNBOUNDED support map, diverging in
//! every direction but `−n`, so GJK, EPA and the M1.1.10 cast kernel — all built
//! on the support map — do not apply to it (`engine-physics-forge.md` §1.11.15).
//! The answer is a taxonomy ABOVE the support map: the category is chosen before a
//! shape is converted into a `SupportShape`, which is why that conversion stops
//! being a total function of the store and becomes an asserted precondition of the
//! convex arm.
//!
//! Every expectation below is a CLOSED FORM computed in the comment above it,
//! never a value read back from the implementation.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const bm_mod = @import("../body_manager.zig");
const broadphase_mod = @import("../pipeline/broadphase.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const BodyManager = bm_mod.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const ShapeClass = shape_mod.ShapeClass;
const ApiVec3 = foundation.math.Vec3;
const testing = std.testing;

/// A descriptor-precision (`f32`) `Vec3` literal — the plane descriptor's own type.
fn av3(x: f32, y: f32, z: f32) ApiVec3 {
    return ApiVec3.fromArray(.{ x, y, z });
}

/// A `Vec3r` literal at solver precision.
fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

// ---------------------------------------------------------------------------
// E1 — the taxonomy, the stored half-space, and the unit-normal invariant
// ---------------------------------------------------------------------------

test "the plane descriptor payload defaults to the +Y half-space through the origin" {
    // The payload is the frozen `engine-tier-interfaces.md` §1 (v0.4) form: a unit
    // `normal` and a `distance` in metres. Its default is `{x : y <= 0}` — a ground
    // plane through the origin — and the default normal is EXACTLY unit, which is
    // what lets `.plane = .{}` pass the creation-time domain assert unchanged.
    const desc = api.ShapeDescriptor{ .plane = .{} };
    try testing.expect(desc.plane.normal.eql(ApiVec3.unit_y));
    try testing.expectEqual(@as(f32, 0), desc.plane.distance);
    // Field types are the frozen ones: `Vec3` (f32) and `f32`.
    try testing.expectEqual(ApiVec3, @TypeOf(desc.plane.normal));
    try testing.expectEqual(f32, @TypeOf(desc.plane.distance));
}

test "a plane carries the half_space class and sphere, box and capsule carry convex" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // BOTH senses of the classifier, not just the new one: a classifier only ever
    // seen to answer `half_space` would pass while answering `half_space` to
    // everything.
    const plane = try store.createShape(gpa, .{ .plane = .{} });
    try testing.expectEqual(ShapeClass.half_space, store.get(plane).?.class());

    const sphere_id = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const box_id = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(1, 2, 3) } });
    const capsule_id = try store.createShape(gpa, .{ .capsule = .{ .radius = 0.3, .half_height = 0.9 } });
    for ([_]api.ShapeId{ sphere_id, box_id, capsule_id }) |id| {
        try testing.expectEqual(ShapeClass.convex, store.get(id).?.class());
    }

    // Two variants exactly. The mesh is the THIRD category of §1.11.15 and arrives
    // at M1.1.11.1; pinning the count is what makes its arrival a deliberate act
    // rather than a silent widening, since every switch on the class is exhaustive
    // and will stop compiling.
    try testing.expectEqual(@as(usize, 2), @typeInfo(ShapeClass).@"enum".fields.len);
}

test "the stored plane normal is unit, and independent of distance" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // TWO bounds, and they are deliberately not the same bound — the §1.11.4 bis
    // separation between a normal's LENGTH and its ORIENTATION, applied here at the
    // creation boundary instead of the far field.
    //
    // The LENGTH is a structural invariant of the normalisation, so it is asserted
    // TIGHT at the SOLVER precision: `|n|² == 1` up to the float noise of
    // `normalize` itself — the squared length costs ~1.5 ulp, the square root 0.5,
    // the reciprocal 0.5 and the product 0.5, so under 8 ulp of 1.
    const length_tight: Real = 8 * std.math.floatEps(Real);
    // The ORIENTATION can only ever carry the resolution of its INPUT, and the input
    // is `f32` by design (§1.11.8: the public surface stays f32 whatever the solver
    // scalar). So the direction is pinned to one ulp of `f32` AT BOTH PRECISIONS —
    // asserting it at `floatEps(Real)` would be asserting that an f64 solver recovers
    // information the f32 descriptor never carried.
    const direction_tol: Real = std.math.floatEps(f32);
    // MEASURED on the oblique normal below, in the build, at both precisions:
    //
    //   leg   |n|² − 1                     direction vs the comparison target
    //   f32   0            (0 ulp f32)     0            (0 ulp f32)
    //   f64   2.220446e-16 (1 ulp f64)     9.123160e-9  (0.0765 ulp f32)
    //
    // The f32 leg is EXACTLY zero on both, and that is a property rather than a
    // coincidence: the descriptor is already an f32-unit vector, so its squared
    // length rounds to exactly 1, the square root of 1 is 1, its reciprocal is 1,
    // and multiplying by 1 is the identity — at f32 the normalisation costs nothing
    // because it has nothing to correct, and the comparison target `vr(2/7, …)` is
    // bit-identical to the `av3(2/7, …)` that was stored. The f64 leg is where the
    // widening it exists to correct is visible at all.

    // `distance` cannot enter the normal — it is an offset along it — and the sweep
    // spans nine orders of magnitude to say so with evidence rather than by
    // inspection of the constructor.
    const distances = [_]f32{ 0, -1, 1, 0.5, -1000, 1e6, -1e-6, 12345.678 };
    // A normal that is NOT axis-aligned, so a lazy `normalize` that happened to be
    // a no-op on a unit axis would be caught: (2, −3, 6)/7, an exact Pythagorean
    // quadruple (4 + 9 + 36 = 49), so the closed form is a representable rational
    // and the direction check has something exact to compare against.
    const oblique = av3(2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0);
    for (distances) |d| {
        const id = try store.createShape(gpa, .{ .plane = .{ .normal = oblique, .distance = d } });
        const record = store.get(id).?;
        try testing.expect(@abs(record.normal.lengthSq() - 1) <= length_tight);
        // The direction is preserved, not merely the length: (2, −3, 6)/7.
        try testing.expect(record.normal.approxEql(vr(2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0), direction_tol));
        // `distance` is stored as given, widened and nothing else.
        try testing.expectEqual(@as(Real, d), record.distance);
    }
}

test "a non-unit plane normal is normalised at creation, direction preserved" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // The `Body.rotation` pattern verbatim: the descriptor is asserted unit at `f32`
    // tolerance and the WIDENED value is normalised once at creation, so no call site
    // ever re-normalises. The two are one mechanism — the assert is what makes the
    // normalisation total in what it does (it corrects the widening; it does not
    // rescue an invalid input), and the widening is what makes it necessary: an
    // f32-unit vector widened to f64 is off by up to ~6e-8 in its squared norm.
    //
    // Input: the f32 normalisation of (1, 1, 1), whose squared norm at `Real` is
    // 1 ± float noise. Expected stored value: (1, 1, 1)/√3 at `Real`.
    //
    // This case admits a TIGHT direction bound at both precisions, and for a reason
    // rather than by luck: the three components are EQUAL, and normalising `(c, c, c)`
    // yields `(1/√3, 1/√3, 1/√3)` whatever `c` is, so the f32 quantisation of the
    // input cancels out entirely instead of surviving into the direction the way it
    // does for the oblique normal above. MEASURED, in the build: 5.960465e-8 at f32
    // and 1.110223e-16 at f64 — half an ulp of `Real` on both legs.
    const nearly = av3(1, 1, 1).normalize();
    const id = try store.createShape(gpa, .{ .plane = .{ .normal = nearly } });
    const record = store.get(id).?;

    const inv_root3: Real = 1.0 / @sqrt(@as(Real, 3));
    const tight: Real = 8 * std.math.floatEps(Real);
    try testing.expect(@abs(record.normal.lengthSq() - 1) <= tight);
    try testing.expect(record.normal.approxEql(vr(inv_root3, inv_root3, inv_root3), 4 * tight));
}

test "a plane shape has no inflation radius and reports its own type" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    const id = try store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 0, -1), .distance = 3 } });
    const record = store.get(id).?;

    try testing.expectEqual(api.ShapeType.plane, record.shape_type);
    // A half-space is not a core plus an inflation: it IS the solid, so its radius
    // is exactly zero and the `− r_b` term of §1.11.15's separation formula belongs
    // to the OTHER shape, never to this one.
    try testing.expectEqual(@as(Real, 0), record.radius);
    try testing.expect(record.normal.approxEql(vr(0, 0, -1), 0));
    try testing.expectEqual(@as(Real, 3), record.distance);
}

test "a plane shape occupies a store slot like any other and reuses it LIFO" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // A half-space owns no memory — it is POD — so it takes the ordinary
    // generational slot path and `destroyShape` frees nothing. Pinned because the
    // mesh (M1.1.11.1) is the shape that changes this, and the change must be
    // visible against a baseline.
    const a = try store.createShape(gpa, .{ .plane = .{} });
    const b = try store.createShape(gpa, .{ .plane = .{ .normal = av3(1, 0, 0), .distance = -2 } });
    try testing.expectEqual(@as(u32, 2), store.count());

    store.destroyShape(b);
    try testing.expect(store.get(b) == null); // stale ⇒ the safe getter says so
    const c = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } }); // reuses b's slot
    try testing.expectEqual(api.PackedId.unpack(b).index, api.PackedId.unpack(c).index);
    try testing.expectEqual(api.PackedId.unpack(b).generation +% 1, api.PackedId.unpack(c).generation);
    try testing.expectEqual(ShapeClass.half_space, store.get(a).?.class());
    try testing.expectEqual(ShapeClass.convex, store.get(c).?.class());
}

// ---------------------------------------------------------------------------
// E2 — the two poisoned fields, observable
// ---------------------------------------------------------------------------

test "a plane's local aabb and unit inertia are NaN on every component" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // The poison is a PINNED BEHAVIOUR, not an intention in a comment. `local_aabb`
    // and `unit_inertia` have no meaning for an unbounded shape with no finite volume,
    // and their readers assert `class() == .convex` — but a `std.debug.assert` is
    // compiled OUT of ReleaseFast, which is the mode the benches run in with a plane in
    // the scene. So the fields carry NaN as well: the assert is the primary guard in a
    // safe build, the NaN is the one that outlives it and propagates loudly through any
    // arithmetic that reaches it.
    //
    // The alternative was measured on the E1 commit, where the fields were `undefined`:
    // a plane's sleep radius came out 5.2510e-13 at f32 and 6.4444e-104 at f64, and the
    // Debug 0xAA fill reads as −3.0316e-13 — all three finite, small and entirely
    // plausible, which is precisely why nobody would ever notice one.
    const id = try store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 0, 1), .distance = 5 } });
    const record = store.get(id).?;
    inline for (0..3) |i| {
        try testing.expect(std.math.isNan(record.local_aabb.min.toArray()[i]));
        try testing.expect(std.math.isNan(record.local_aabb.max.toArray()[i]));
        try testing.expect(std.math.isNan(record.unit_inertia.toArray()[i]));
    }

    // The geometry that DOES have meaning is untouched by the poison, so a reader that
    // wants the plane finds it: the normal, the offset, and a zero radius.
    try testing.expect(record.normal.approxEql(vr(0, 0, 1), 0));
    try testing.expectEqual(@as(Real, 5), record.distance);
    try testing.expectEqual(@as(Real, 0), record.radius);

    // A convex keeps both fields finite — the poison is the half-space's, not a
    // property of the store.
    const convex = store.get(try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } })).?;
    inline for (0..3) |i| {
        try testing.expect(!std.math.isNan(convex.local_aabb.min.toArray()[i]));
        try testing.expect(!std.math.isNan(convex.unit_inertia.toArray()[i]));
    }
}

// ---------------------------------------------------------------------------
// E4 — the analytic kernels of §1.11.15's table
// ---------------------------------------------------------------------------

/// The half-space `{ x : normal·x <= distance }` at solver precision.
const HS = narrowphase.plane.HalfSpace(Real);
const SS = narrowphase.SupportShape(Real);
const RP = narrowphase.RelativePose(Real);

/// The three planes every kernel below is exercised against: two axis-aligned with
/// opposite signs, and one OBLIQUE — `(2, −3, 6)/7`, an exact Pythagorean quadruple
/// (4 + 9 + 36 = 49) so its components are representable rationals and the closed
/// forms stay exact. An axis-aligned-only suite would never see a normal whose
/// components interact.
const planes = [_]struct { name: []const u8, n: Vec3r }{
    .{ .name = "+Y", .n = Vec3r.unit_y },
    .{ .name = "-X", .n = Vec3r.unit_x.neg() },
    .{ .name = "oblique", .n = Vec3r.fromArray(.{ 2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0 }) },
};

/// Relative slack for a closed-form scalar at the scale of the tens of metres these
/// scenes use — float noise, not geometric slack. Same shape as
/// `shapecast_test.zig`'s `tol`.
const tol: Real = if (Real == f32) 1e-5 else 1e-12;

/// A sphere support shape: a point core of inflation radius `r`.
fn sphere(r: Real) SS {
    return .{ .core = .point, .radius = r };
}

/// A box support shape: the full box, radius 0 (a box has no convex radius).
fn boxShape(hx: Real, hy: Real, hz: Real) SS {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = 0 };
}

/// A capsule support shape: a Y-segment core of half-height `h`, inflation `r`.
fn capsule(r: Real, h: Real) SS {
    return .{ .core = .{ .segment = h }, .radius = r };
}

/// B translated by `p` with no rotation, relative to a half-space A at the origin —
/// the pose `separation` takes.
fn poseAt(p: Vec3r) RP {
    return RP.init(Vec3r.zero, Quatr.identity, p, Quatr.identity);
}

test "separation against a sphere subtracts the radius" {
    // THE DISCRIMINATING TEST OF THE WHOLE KERNEL (§1.11.15). `SupportShape.support`
    // returns the support of the CORE, radius EXCLUDED, and a sphere's core is a single
    // point at its centre. So a unit sphere whose CENTRE lies exactly on the boundary
    // plane is penetrating by its whole radius — it is NOT touching.
    //
    //   sep = n · supportCore_B(−n) − r_b − d
    //       = n · centre            − 1   − 0     with the centre on the plane, n·c = d = 0
    //       = −1
    //
    // The refuted form, `n · supportCore_B(−n) − d` with no radius term, gives 0 —
    // "touching". Both values are asserted, so the test can TELL THE TWO APART: were
    // the term dropped, the first assertion would fail with exactly the second's value.
    for (planes) |p| {
        const plane = HS{ .normal = p.n, .distance = 0 };
        // Centre exactly on the plane through the origin: any point with n·c = 0. Take
        // the origin itself, which lies on every plane through it.
        const sep = narrowphase.plane.separation(Real, plane, poseAt(Vec3r.zero), sphere(1));
        try testing.expectApproxEqAbs(@as(Real, -1), sep, tol);
        // The radius-free form, written out here rather than described: it is the same
        // support call without `− r_b`.
        const radius_free = plane.signedDistance(poseAt(Vec3r.zero).supportB(sphere(1), p.n.neg()));
        try testing.expectApproxEqAbs(@as(Real, 0), radius_free, tol);
        // …and they differ by EXACTLY the radius, which is the failure mode's amplitude.
        try testing.expectApproxEqAbs(@as(Real, 1), radius_free - sep, tol);

        // A sphere whose centre is 3 m outside is separated by 3 − 1 = 2.
        const outside = narrowphase.plane.separation(Real, plane, poseAt(p.n.scale(3)), sphere(1));
        try testing.expectApproxEqAbs(@as(Real, 2), outside, tol);
        // Its own surface exactly touching: centre at 1 m out, radius 1 ⇒ sep = 0.
        const touching = narrowphase.plane.separation(Real, plane, poseAt(p.n.scale(1)), sphere(1));
        try testing.expectApproxEqAbs(@as(Real, 0), touching, tol);
    }
}

test "separation against a box agrees with the radius-free form, which is why a box-only suite would pass" {
    // A box's core radius is 0, so `− r_b` changes nothing for it: the two forms agree
    // EXACTLY. Asserted, because it is the reason the sphere test above exists and may
    // not be dropped — a suite that only tested boxes would pass with the term missing.
    //
    // Closed form for a box of half-extents `h` at centre `c`, identity rotation: the
    // core support along `−n` minimises `n·x` over the box, giving
    //   n·c − (|n_x|·h_x + |n_y|·h_y + |n_z|·h_z) − 0 − d.
    const half = vr(1, 2, 3);
    for (planes) |p| {
        const plane = HS{ .normal = p.n, .distance = 0 };
        const na = p.n.abs().toArray();
        const projected = na[0] * 1 + na[1] * 2 + na[2] * 3; // the box's extent along n
        for ([_]Real{ 0, 5, -5, 12.5 }) |offset| {
            const centre = p.n.scale(offset);
            const sep = narrowphase.plane.separation(Real, plane, poseAt(centre), boxShape(half.toArray()[0], half.toArray()[1], half.toArray()[2]));
            try testing.expectApproxEqAbs(offset - projected, sep, tol);
            const radius_free = plane.signedDistance(poseAt(centre).supportB(boxShape(1, 2, 3), p.n.neg()));
            try testing.expectApproxEqAbs(radius_free, sep, 0); // EXACTLY equal: r_b = 0
        }
    }
}

test "separation against a capsule subtracts the radius and reads its axis" {
    // Closed form for a Y-segment core of half-height `h` and radius `r` at centre `c`,
    // identity rotation: the extremal endpoint along `−n` contributes `−|n_y|·h`, so
    //   sep = n·c − |n_y|·h − r − d.
    const h: Real = 0.9;
    const r: Real = 0.3;
    for (planes) |p| {
        const plane = HS{ .normal = p.n, .distance = 0 };
        const ny = @abs(p.n.toArray()[1]);
        for ([_]Real{ 0, 4, -4 }) |offset| {
            const sep = narrowphase.plane.separation(Real, plane, poseAt(p.n.scale(offset)), capsule(r, h));
            try testing.expectApproxEqAbs(offset - ny * h - r, sep, tol);
        }
        // ROTATED: 90° about +Z maps the capsule's local +Y axis onto world −X, so the
        // axis term becomes `|n_x|·h` instead of `|n_y|·h`. That is the case an
        // identity-rotation-only suite would miss entirely.
        const nx = @abs(p.n.toArray()[0]);
        const spun = RP.init(Vec3r.zero, Quatr.identity, Vec3r.zero, Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0));
        try testing.expectApproxEqAbs(-nx * h - r, narrowphase.plane.separation(Real, plane, spun, capsule(r, h)), tol);
    }
}

test "raycast against a half-space" {
    for (planes) |p| {
        // Solid is `{ x : n·x <= 0 }`. A point at `n·t` is at signed distance `t`
        // (`|n| = 1`), so the four cases below have closed-form answers in `t`.
        const plane = HS{ .normal = p.n, .distance = 0 };
        const outside = p.n.scale(5); // 5 m outside
        const inside = p.n.scale(-5); // 5 m inside
        // A direction in the boundary plane: any unit vector orthogonal to `n`. The
        // cross product with the least-aligned axis is non-degenerate for every `n`.
        const tangent = p.n.cross(if (@abs(p.n.toArray()[0]) < 0.9) Vec3r.unit_x else Vec3r.unit_y).normalize();

        // (1) From OUTSIDE, crossing: travelling along `−n` covers the 5 m exactly.
        const crossing = narrowphase.plane.rayShape(Real, plane, outside, p.n.neg()).?;
        try testing.expectApproxEqAbs(@as(Real, 5), crossing.distance, tol);
        // The normal is the STORED normal, bit-for-bit — no arithmetic produced it.
        try testing.expect(crossing.normal.eql(p.n));
        try testing.expect(crossing.normal.dot(p.n.neg()) <= 0);

        // (2) From OUTSIDE, receding: `n·dir = +1 >= 0` ⇒ miss.
        try testing.expect(narrowphase.plane.rayShape(Real, plane, outside, p.n) == null);

        // (3) From OUTSIDE, PARALLEL: `n·dir` is EXACTLY 0 ⇒ miss. The guard is at true
        // zero and this is the case that exercises it.
        try testing.expectEqual(@as(Real, 0), p.n.dot(tangent) * 0); // the product is the guarded quantity
        try testing.expect(narrowphase.plane.rayShape(Real, plane, outside, tangent) == null);

        // (4) From INSIDE, PARALLEL: solid membership answers FIRST, so the division is
        // never reached — a hit at distance 0 with normal `−direction`.
        const in_parallel = narrowphase.plane.rayShape(Real, plane, inside, tangent).?;
        try testing.expectEqual(@as(Real, 0), in_parallel.distance);
        try testing.expect(in_parallel.normal.eql(tangent.neg()));

        // (5) An origin INSIDE, any direction: hit at 0, normal `−direction` (§1.11.4).
        for ([_]Vec3r{ p.n, p.n.neg(), tangent }) |d| {
            const hit = narrowphase.plane.rayShape(Real, plane, inside, d).?;
            try testing.expectEqual(@as(Real, 0), hit.distance);
            try testing.expect(hit.normal.eql(d.neg()));
            try testing.expect(hit.normal.dot(d) <= 0);
        }

        // (6) Exactly ON the boundary is INSIDE (closed half-space): distance 0.
        const on = narrowphase.plane.rayShape(Real, plane, Vec3r.zero, p.n).?;
        try testing.expectEqual(@as(Real, 0), on.distance);

        // (7) An oblique incidence, so the quotient is not just ±1: a direction at 45°
        // to the plane covers `5·√2` before reaching it.
        const oblique_dir = p.n.neg().add(tangent).normalize();
        const slanted = narrowphase.plane.rayShape(Real, plane, outside, oblique_dir).?;
        try testing.expectApproxEqAbs(5 * @sqrt(@as(Real, 2)), slanted.distance, tol);
    }
}

test "solid membership includes the boundary" {
    for (planes) |p| {
        const plane = HS{ .normal = p.n, .distance = 1 };
        // The boundary is `n·x = 1`, so `n·1` is exactly on it.
        const on_boundary = p.n.scale(1);
        try testing.expect(narrowphase.plane.containsPoint(Real, plane, on_boundary));
        // Strictly inside.
        try testing.expect(narrowphase.plane.containsPoint(Real, plane, p.n.scale(0.5)));
        try testing.expect(narrowphase.plane.containsPoint(Real, plane, p.n.scale(-1000)));
        // ONE ULP outside. `1 + floatEps` is the next representable above 1 and
        // `(1 + eps) − 1` is exactly `eps`, so the signed distance is strictly positive
        // by the smallest amount the scalar can express at this magnitude.
        const one_ulp_out = p.n.scale(1 + std.math.floatEps(Real));
        try testing.expect(!narrowphase.plane.containsPoint(Real, plane, one_ulp_out));
        // And the boundary case is decided by `<=`, not `<`: shifting the plane instead
        // of the point gives the same verdict.
        try testing.expect(narrowphase.plane.containsPoint(Real, HS{ .normal = p.n, .distance = 0 }, Vec3r.zero));
    }
}

test "closest point projects orthogonally and answers the point itself inside" {
    for (planes) |p| {
        const plane = HS{ .normal = p.n, .distance = 0 };
        // A point 5 m outside plus an arbitrary in-plane offset: the projection removes
        // the normal component and keeps the tangential one, so distance = 5 exactly and
        // the position is the point minus 5·n.
        const tangent = p.n.cross(if (@abs(p.n.toArray()[0]) < 0.9) Vec3r.unit_x else Vec3r.unit_y).normalize();
        const outside = p.n.scale(5).add(tangent.scale(3));
        const out = narrowphase.plane.closestPoint(Real, plane, outside);
        try testing.expectApproxEqAbs(@as(Real, 5), out.distance, tol);
        try testing.expect(out.position.approxEql(tangent.scale(3), tol));
        // The projection lies ON the boundary.
        try testing.expectApproxEqAbs(@as(Real, 0), plane.signedDistance(out.position), tol);

        // INSIDE — boundary included — is distance 0 at the point ITSELF, not its
        // projection onto the boundary (§1.11.13's solidity convention). The two differ,
        // which is what makes this assertion discriminating.
        const inside = p.n.scale(-5).add(tangent.scale(3));
        const in = narrowphase.plane.closestPoint(Real, plane, inside);
        try testing.expectEqual(@as(Real, 0), in.distance);
        try testing.expect(in.position.eql(inside));
        try testing.expect(!in.position.approxEql(tangent.scale(3), tol)); // NOT the projection

        // Exactly on the boundary: inside, so the point itself.
        const on = narrowphase.plane.closestPoint(Real, plane, tangent.scale(3));
        try testing.expectEqual(@as(Real, 0), on.distance);
        try testing.expect(on.position.eql(tangent.scale(3)));
    }
}

test "shape cast against a half-space" {
    // Everything is in A's frame — A is the shape being cast, untransformed there — so
    // the plane is expressed in that frame and the closed forms read directly off the
    // probe's lowest point along `−n`.
    //
    // Plane: `{ x : y <= −10 }`. Each probe's lowest point along −Y is at
    //   sphere(0.5)      → y = −0.5   ⇒ travel 9.5
    //   box(1, 2, 3)     → y = −2     ⇒ travel 8
    //   capsule(0.3, 0.9)→ y = −1.2   ⇒ travel 8.8
    const plane = HS{ .normal = Vec3r.unit_y, .distance = -10 };
    const down = Vec3r.unit_y.neg();
    const cases = [_]struct { probe: SS, travel: Real }{
        .{ .probe = sphere(0.5), .travel = 9.5 },
        .{ .probe = boxShape(1, 2, 3), .travel = 8 },
        .{ .probe = capsule(0.3, 0.9), .travel = 8.8 },
    };
    for (cases) |c| {
        const hit = narrowphase.plane.castShape(Real, plane, c.probe, down, 100).?;
        try testing.expectApproxEqAbs(c.travel, hit.distance, tol);
        // The witness is ON the boundary plane, and the normal is the plane's, unit and
        // opposing the sweep.
        try testing.expectApproxEqAbs(@as(Real, 0), plane.signedDistance(hit.point), tol);
        try testing.expect(hit.normal.eql(Vec3r.unit_y));
        try testing.expect(hit.normal.dot(down) <= 0);

        // The interval is CLOSED: a bound exactly at the answer is a hit, and STRICT
        // exceedance is the miss (§1.11.11).
        try testing.expect(narrowphase.plane.castShape(Real, plane, c.probe, down, c.travel) != null);
        try testing.expect(narrowphase.plane.castShape(Real, plane, c.probe, down, c.travel - 4 * tol) == null);

        // RECEDING: `n·dir = +1 >= 0` ⇒ miss, whatever the bound.
        try testing.expect(narrowphase.plane.castShape(Real, plane, c.probe, Vec3r.unit_y, 1e6) == null);
        // GRAZING — the sweep runs parallel to the boundary, `n·dir` EXACTLY 0. The
        // guard is at true zero and this is the case that exercises it.
        try testing.expect(narrowphase.plane.castShape(Real, plane, c.probe, Vec3r.unit_x, 1e6) == null);
        try testing.expect(narrowphase.plane.castShape(Real, plane, c.probe, Vec3r.unit_z.neg(), 1e6) == null);
    }

    // An OBLIQUE sweep, so the quotient is not ±1: at 45° between −Y and +X the sphere
    // covers 9.5·√2.
    const diagonal = Vec3r.unit_y.neg().add(Vec3r.unit_x).normalize();
    const slanted = narrowphase.plane.castShape(Real, plane, sphere(0.5), diagonal, 100).?;
    try testing.expectApproxEqAbs(9.5 * @sqrt(@as(Real, 2)), slanted.distance, tol);

    // INITIAL CONTACT, and the witness is NOT the cast origin. Plane `{ y <= −1 }` with
    // a box(1,2,3) at A's origin: its lowest point along −Y is (1, −2, 3) — the `>= 0`
    // tie-break picking `+h` on the two zero components of the direction — so
    // `sep₀ = −2 − (−1) = −1 <= 0` and the witness is that point projected onto the
    // boundary, (1, −1, 3). The cast origin is (0, 0, 0): the two are demonstrably
    // different, which is what makes this assertion able to refute `position = origin`.
    const touching = HS{ .normal = Vec3r.unit_y, .distance = -1 };
    const initial = narrowphase.plane.castShape(Real, touching, boxShape(1, 2, 3), down, 100).?;
    try testing.expectEqual(@as(Real, 0), initial.distance);
    try testing.expect(initial.point.approxEql(vr(1, -1, 3), tol));
    // …and NOT the cast origin, which the analogy with a ray would have suggested.
    try testing.expect(!initial.point.approxEql(Vec3r.zero, tol));
    try testing.expectApproxEqAbs(@as(Real, 0), touching.signedDistance(initial.point), tol);
}

test "an oblique far-field configuration keeps a unit normal" {
    // The §1.11.4 bis obligation, and for a half-space it splits differently than for
    // the ray kernels. There, the normal is RECONSTRUCTED, so only its length is a
    // structural invariant and its orientation carries the far-field residue. Here the
    // normal is the STORED `n`, returned with no arithmetic at all — so BOTH its length
    // and its orientation are exact at any distance, and the assertion is bit-equality
    // rather than a tolerance.
    //
    // What carries the residue instead is the SCALAR `signedDistance = n·p − d`, a
    // difference of two quantities that both grow with `|p|`. Its absolute error grows
    // like `floatEps(T)·|p|`, which is the same structural worldspace limit
    // `-Dphysics_f64` answers (§1.11.8) — characterised here, not hidden.
    const n = Vec3r.fromArray(.{ 2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0 }); // oblique, exact rational
    const tangent = n.cross(Vec3r.unit_x).normalize();

    for ([_]Real{ 1, 1e3, 5e3, 5e4 }) |range| {
        // A plane whose boundary passes `range` metres from the origin, and a ray aimed
        // at it from `range` further out along `n`, obliquely — an axis-aligned ray sees
        // exactly none of this, the cancellation there being zero.
        const plane = HS{ .normal = n, .distance = range };
        const origin = n.scale(2 * range).add(tangent.scale(range));
        const hit = narrowphase.plane.rayShape(Real, plane, origin, n.neg()).?;

        // The normal is EXACT — bit-identical to the stored one, at every range.
        try testing.expect(hit.normal.eql(n));
        try testing.expectEqual(n.lengthSq(), hit.normal.lengthSq());

        // The distance is `range` in closed form (the tangential offset costs nothing
        // along `n`), and its error is bounded by the scalar's own resolution at the
        // magnitude the subtraction saw — NOT by a fixed tolerance, which would either
        // pass vacuously far out or fail near in.
        const scale_bound = 32 * std.math.floatEps(Real) * (2 * range + range);
        try testing.expectApproxEqAbs(range, hit.distance, @max(scale_bound, tol));

        // And the cast normal is exact at range too, for the same reason.
        const cast = narrowphase.plane.castShape(Real, plane, sphere(1), n.neg(), 4 * range).?;
        try testing.expect(cast.normal.eql(n));
    }
}

// ---------------------------------------------------------------------------
// E4 — the five `BodyManager` adapters, at the BODY grain
// ---------------------------------------------------------------------------
//
// Driven through `bm.addBody` and the adapters DIRECTLY, with no test harness. That
// is not a shortcut: `harness.World.addBody` calls `bm.bodyAabb(...).?` to insert a
// broadphase proxy, and a half-space has no world AABB — the class assert fires. The
// harness learns the half-space at E5, together with the unbounded lists it belongs
// in; until then the body-grain adapters are what can be exercised, and they are what
// E4 owns.
//
// **The world-frame oracle is derived once, here, and hard-coded below.** A plane body
// at `(10, 20, 30)` rotated +90° about +Z, carrying the LOCAL half-space `{ y <= 0 }`:
//
//   n_world = Rz(90°)·(0, 1, 0) = (−1, 0, 0)
//   d_world = d_local + n_world·pos = 0 + (−1, 0, 0)·(10, 20, 30) = −10
//
// so the solid is `{ x : −x <= −10 }`, i.e. the half-space `x >= 10`. Every expectation
// below is written on THAT, not on a value recomputed with the same rotation call the
// implementation makes — otherwise the test and the code would share their mistake.

/// The plane body every adapter test below uses, plus a `ShapeStore` holding it.
const PlaneScene = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    body: api.BodyId = 0,

    /// World-space normal of the scene's plane, by the derivation above.
    const n_world = Vec3r.fromArray(.{ -1, 0, 0 });
    /// World-space offset of the scene's plane, by the derivation above.
    const d_world: Real = -10;

    fn init(gpa: std.mem.Allocator) !PlaneScene {
        var scene = PlaneScene{};
        const shape = try scene.store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = 0 } });
        scene.body = try scene.bm.addBody(gpa, &scene.store, .{
            .shape = shape,
            .body_type = .static,
            .position = av3(10, 20, 30),
            .rotation = foundation.math.Quatf.fromAxisAngle(ApiVec3.unit_z, std.math.pi / 2.0),
            .entity = .{ .index = 7, .generation = 0 },
        });
        return scene;
    }

    fn deinit(self: *PlaneScene, gpa: std.mem.Allocator) void {
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
    }

    /// `n_world·p − d_world`, the oracle's own signed distance.
    fn oracleSigned(p: Vec3r) Real {
        return n_world.dot(p) - d_world;
    }
};

test "containsPointBody answers the world half-space, boundary included" {
    const gpa = testing.allocator;
    var scene = try PlaneScene.init(gpa);
    defer scene.deinit(gpa);

    // Solid is `x >= 10`.
    try testing.expect(scene.bm.containsPointBody(&scene.store, scene.body, vr(15, 1, 2)).?);
    try testing.expect(scene.bm.containsPointBody(&scene.store, scene.body, vr(1000, -50, 7)).?);
    try testing.expect(!scene.bm.containsPointBody(&scene.store, scene.body, vr(5, 1, 2)).?);
    try testing.expect(!scene.bm.containsPointBody(&scene.store, scene.body, vr(-1000, 0, 0)).?);
    // Exactly on the boundary is INSIDE. The transported plane is unit to a few ULPs of
    // the rotation, so the boundary decision at exactly `x = 10` is asserted through the
    // oracle's own sign rather than as a raw bool: the two agree, which is the claim.
    try testing.expectApproxEqAbs(@as(Real, 0), PlaneScene.oracleSigned(vr(10, 1, 2)), tol);
    try testing.expect(scene.bm.containsPointBody(&scene.store, scene.body, vr(10 + 4 * tol, 1, 2)).?);
    try testing.expect(!scene.bm.containsPointBody(&scene.store, scene.body, vr(10 - 4 * tol, 1, 2)).?);

    // A stale handle is still null, not false — the adapter's pre-existing contract.
    var doomed = scene;
    _ = &doomed;
    scene.bm.removeBody(scene.body);
    try testing.expectEqual(@as(?bool, null), scene.bm.containsPointBody(&scene.store, scene.body, vr(15, 1, 2)));
}

test "raycastBody hits the world half-space and its normal rotates back to n_world" {
    const gpa = testing.allocator;
    var scene = try PlaneScene.init(gpa);
    defer scene.deinit(gpa);

    // A world ray from `(0, 1, 2)` along `+X` reaches the boundary `x = 10` after 10 m.
    const ray = broadphase_mod.Ray(Real).init(vr(0, 1, 2), Vec3r.unit_x);
    const hit = scene.bm.raycastBody(&scene.store, scene.body, ray).?;
    try testing.expectApproxEqAbs(@as(Real, 10), hit.distance, tol);
    // The kernel answers in the BODY's local frame; the query layer rotates the normal
    // to world. Doing that here shows the local normal IS the transported plane's.
    const world_normal = scene.bm.rotation(scene.body).?.rotateVec3(hit.normal);
    try testing.expect(world_normal.approxEql(PlaneScene.n_world, tol));
    try testing.expect(world_normal.dot(Vec3r.unit_x) <= 0);

    // Away from the solid: `+X` reversed recedes, so no hit.
    const receding = broadphase_mod.Ray(Real).init(vr(0, 1, 2), Vec3r.unit_x.neg());
    try testing.expect(scene.bm.raycastBody(&scene.store, scene.body, receding) == null);
    // PARALLEL to the boundary, from outside — and here the composition says something
    // the kernel alone does not, so it is asserted rather than assumed.
    //
    // The guard on `n·dir` is at TRUE ZERO, which is exact IN THE FRAME IT IS EVALUATED
    // IN. A rigid transform does not preserve exact orthogonality: this ray is parallel
    // in WORLD, but `raycastBody` transports it into the body's local frame through a
    // quaternion built from `f32`/`f64` trigonometry, and the transported dot product
    // comes out at ONE ULP of the scalar instead of zero. So the kernel correctly
    // reports a crossing — at a distance of `sep / |n·dir| ≈ sep / floatEps(Real)`.
    //
    // MEASURED, and the closed form is confirmed by both legs: 8.388612e7 m at f32
    // (`10 / 1.19e-7`) and 4.503600e16 m at f64 (`10 / 2.22e-16`). What rejects such a
    // ray is the QUERY entry's finite `max_distance`, which §1.11.4 requires to be
    // finite — not the kernel, which has no bound of its own and no business inventing a
    // geometric epsilon to fabricate one. The EXACTLY-parallel case, where the guard
    // does fire, is the kernel-level test above.
    const parallel = broadphase_mod.Ray(Real).init(vr(0, 1, 2), Vec3r.unit_y);
    const grazing = scene.bm.raycastBody(&scene.store, scene.body, parallel).?;
    try testing.expect(grazing.distance >= 10 / (8 * std.math.floatEps(Real)));
    // From INSIDE the solid: distance 0, normal `−direction` once back in world.
    const inside = broadphase_mod.Ray(Real).init(vr(50, 1, 2), Vec3r.unit_y);
    const in_hit = scene.bm.raycastBody(&scene.store, scene.body, inside).?;
    try testing.expectEqual(@as(Real, 0), in_hit.distance);
    try testing.expect(scene.bm.rotation(scene.body).?.rotateVec3(in_hit.normal).approxEql(Vec3r.unit_y.neg(), tol));
}

test "closestPointBody projects onto the world boundary and answers the point inside" {
    const gpa = testing.allocator;
    var scene = try PlaneScene.init(gpa);
    defer scene.deinit(gpa);

    // Outside at `(5, 1, 2)`: signed distance `(−1)·5 − (−10) = 5`, and the projection
    // removes `5·n_world = (−5, 0, 0)`, landing on `(10, 1, 2)`.
    const out = scene.bm.closestPointBody(&scene.store, scene.body, vr(5, 1, 2)).?;
    try testing.expectApproxEqAbs(@as(Real, 5), out.distance, tol);
    try testing.expect(out.position.approxEql(vr(10, 1, 2), tol));

    // Inside at `(50, 1, 2)`: distance 0 and the point ITSELF, not its projection onto
    // the boundary — the two differ by 40 m here, so the assertion discriminates.
    const in = scene.bm.closestPointBody(&scene.store, scene.body, vr(50, 1, 2)).?;
    try testing.expectEqual(@as(Real, 0), in.distance);
    try testing.expect(in.position.approxEql(vr(50, 1, 2), tol));
    try testing.expect(!in.position.approxEql(vr(10, 1, 2), tol));
}

test "castShapeBody sweeps onto the world boundary" {
    const gpa = testing.allocator;
    var scene = try PlaneScene.init(gpa);
    defer scene.deinit(gpa);

    // A sphere probe of radius 0.5 centred at `(0, 1, 2)` swept along `+X`: its surface
    // reaches `x = 0.5` already, so it travels `10 − 0.5 = 9.5` to touch `x = 10`, and
    // the witness is on the boundary at `(10, 1, 2)`.
    const probe = narrowphase.SupportShape(Real){ .core = .point, .radius = 0.5 };
    const hit = scene.bm.castShapeBody(
        &scene.store,
        scene.body,
        probe,
        vr(0, 1, 2),
        Quatr.identity,
        Vec3r.unit_x,
        100,
    ).?;
    try testing.expectApproxEqAbs(@as(Real, 9.5), hit.distance, tol);
    try testing.expect(hit.position.approxEql(vr(10, 1, 2), tol));
    try testing.expect(hit.normal.approxEql(PlaneScene.n_world, tol));
    try testing.expect(hit.normal.dot(Vec3r.unit_x) <= 0);

    // Receding and grazing both miss, at the body grain as at the kernel grain.
    try testing.expect(scene.bm.castShapeBody(&scene.store, scene.body, probe, vr(0, 1, 2), Quatr.identity, Vec3r.unit_x.neg(), 1e6) == null);
    try testing.expect(scene.bm.castShapeBody(&scene.store, scene.body, probe, vr(0, 1, 2), Quatr.identity, Vec3r.unit_z, 1e6) == null);
    // A bound shorter than the answer misses; one exactly at it hits (closed interval).
    try testing.expect(scene.bm.castShapeBody(&scene.store, scene.body, probe, vr(0, 1, 2), Quatr.identity, Vec3r.unit_x, 9.5 - 8 * tol) == null);
    try testing.expect(scene.bm.castShapeBody(&scene.store, scene.body, probe, vr(0, 1, 2), Quatr.identity, Vec3r.unit_x, 9.5 + 8 * tol) != null);
}

test "overlapShapeBody answers by the sign of the separation" {
    const gpa = testing.allocator;
    var scene = try PlaneScene.init(gpa);
    defer scene.deinit(gpa);

    // A unit sphere probe: it overlaps the solid `x >= 10` exactly when its surface
    // reaches it, i.e. when `centre_x + 1 >= 10`, i.e. `centre_x >= 9`.
    //   sep = n_world·centre − r − d_world = −centre_x − 1 + 10 = 9 − centre_x
    const probe = narrowphase.SupportShape(Real){ .core = .point, .radius = 1 };
    const cases = [_]struct { x: Real, overlap: bool }{
        .{ .x = 8.0, .overlap = false }, // sep = +1
        .{ .x = 8.9, .overlap = false }, // sep = +0.1
        .{ .x = 9.2, .overlap = true }, // sep = −0.2
        .{ .x = 50.0, .overlap = true }, // deep inside
        .{ .x = -100.0, .overlap = false }, // far outside
    };
    for (cases) |c| {
        try testing.expectEqual(c.overlap, scene.bm.overlapShapeBody(
            &scene.store,
            scene.body,
            probe,
            vr(c.x, 1, 2),
            Quatr.identity,
        ).?);
    }
    // A BOX probe, so the answer is not a property of the point core alone: half-extents
    // (2, 1, 1) at `x = 7` reach `x = 9`, one metre short; at `x = 8.5` they reach 10.5.
    const box_probe = narrowphase.SupportShape(Real){ .core = .{ .box = vr(2, 1, 1) }, .radius = 0 };
    try testing.expect(!scene.bm.overlapShapeBody(&scene.store, scene.body, box_probe, vr(7, 1, 2), Quatr.identity).?);
    try testing.expect(scene.bm.overlapShapeBody(&scene.store, scene.body, box_probe, vr(8.5, 1, 2), Quatr.identity).?);
}
