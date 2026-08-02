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
const query = @import("../query/root.zig");
const harness = @import("solver_test.zig");
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

    // THREE variants exactly, since M1.1.11.1 brought the third category of §1.11.15.
    // The count is pinned so a fourth arrival is a deliberate act rather than a silent
    // widening; it fired on this line when the mesh landed, which is the whole reason
    // it is written this way. The pin is EXTENDED and not relaxed: the count moved 2 → 3
    // and the three variants are named, so a rename is caught as well as an addition.
    try testing.expectEqual(@as(usize, 3), @typeInfo(ShapeClass).@"enum".fields.len);
    try testing.expectEqual(ShapeClass.convex, @as(ShapeClass, @enumFromInt(0)));
    try testing.expectEqual(ShapeClass.half_space, @as(ShapeClass, @enumFromInt(1)));
    try testing.expectEqual(ShapeClass.triangle_soup, @as(ShapeClass, @enumFromInt(2)));
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

    store.destroyShape(gpa, b);
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
    // The §1.11.4 bis obligation, and §1.11.15 states how it decomposes DIFFERENTLY for
    // a half-space. There the normal is RECONSTRUCTED, so only its length is invariant
    // with distance. Here it is the STORED `n` returned VERBATIM, with no intermediate
    // arithmetic at all — so length AND orientation are exact at any range, and the
    // assertion is BIT EQUALITY rather than a bound. Which is why this suite asserts the
    // normal tight and everywhere, and reserves the scale-relative bound for the scalar
    // alone.
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
    // PARALLEL to the boundary, from outside — and §1.11.15 is explicit about what this
    // composition does: **a true-zero guard is exact in the frame it is evaluated in, and
    // that does not compose.** A rigid transform does not preserve EXACT orthogonality:
    // this ray is parallel in WORLD, but `raycastBody` transports it into the body's
    // local frame through a quaternion built in floating point, and the transported dot
    // product arrives about one ULP from zero rather than at zero. The guard does not
    // fire, and the kernel reports — correctly — a crossing at `sep / |n·dir|`.
    //
    // The corollary §1.11.15 draws is the one this test obeys: **a test that expects
    // `null` from a ray parallel in WORLD is testing a property the model does not
    // promise.** The exactly-parallel case, where the guard does fire, is exercised at
    // KERNEL grain in local coordinates, in the raycast test above.
    //
    // MEASURED, in the build, at both precisions — and the two quantities are separated
    // because only one of them is exact:
    //
    //   leg   transported n·dir        ratio to floatEps   returned t
    //   f32   −1.1920929e-7            1.000000000         8.388612e7
    //   f64   −2.220446049250313e-16   1.000000000         4.503599627370497e16
    //
    // The dot product is EXACTLY `−floatEps(Real)` on both legs, which is why `t` is of
    // order `sep / floatEps(Real)`. It is not exactly `10 / floatEps(Real)`
    // (8.388608e7 and 4.503599627370496e16): the excess is `sep`'s own rounding, the
    // transported signed distance being 10 m only to the precision the same rotation
    // carries. Both figures recompute from the table.
    //
    // What rejects such a ray is the QUERY entry's finite `max_distance`, which §1.11.4
    // requires to be finite — not the kernel, which has no bound of its own and no
    // business inventing a geometric epsilon to fabricate one. The EXACTLY-parallel
    // case, where the guard does fire, is the kernel-level test above.
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

// ---------------------------------------------------------------------------
// E5 — the eight query entries, at ENTRY grain, with a plane in the scene
// ---------------------------------------------------------------------------
//
// Unblocked by the harness learning the half-space: until E5 a plane body could not be
// added to a `harness.World` at all, `addBody` calling `bodyAabb` to build a broadphase
// proxy. Now it goes into the layer's unbounded list instead, and the entries can be
// exercised where a caller actually meets them.
//
// The scene is a GROUND plane — local `{ y <= 0 }` at identity pose, so the world
// half-space is the same `{ y <= 0 }` — plus, where a second body is needed, a unit
// sphere centred at `(0, 3, 0)` whose lowest point is `y = 2`. Every closed form below
// reads off those two.

/// Add the ground plane `{ y <= 0 }` to `world` as a static body.
fn addGround(gpa: std.mem.Allocator, world: *harness.World, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = 0 } });
    return world.addBody(gpa, .{
        .shape = shape,
        .body_type = .static,
        .entity = .{ .index = entity_index, .generation = 0 },
    });
}

/// Add a unit sphere at `centre`, static so nothing has to be stepped.
fn addUnitSphere(gpa: std.mem.Allocator, world: *harness.World, centre: [3]f32, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    return world.addBody(gpa, .{
        .shape = shape,
        .body_type = .static,
        .position = av3(centre[0], centre[1], centre[2]),
        .entity = .{ .index = entity_index, .generation = 0 },
    });
}

test "all eight query entries answer a half-space body" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground = try addGround(gpa, &world, 0);

    // (1) raycast — from (0, 5, 0) straight down: the boundary is at y = 0, so t = 5,
    // the hit point is the origin and the normal is +Y.
    const hit = query.raycast(&world.bp, &world.bm, &world.store, .{
        .origin = vr(0, 5, 0),
        .direction = vr(0, -1, 0),
        .max_distance = 100,
    }).?;
    try testing.expectEqual(ground, hit.body);
    try testing.expectApproxEqAbs(@as(Real, 5), hit.distance, tol);
    try testing.expect(hit.position.approxEql(Vec3r.zero, tol));
    try testing.expect(hit.normal.approxEql(Vec3r.unit_y, tol));

    // (2) raycastAny — the same ray, as a boolean.
    try testing.expect(query.raycastAny(&world.bp, &world.bm, &world.store, .{
        .origin = vr(0, 5, 0),
        .direction = vr(0, -1, 0),
        .max_distance = 100,
    }));
    // …and a ray pointing away answers false, so the entry is not answering true
    // unconditionally now that an unbounded shape is offered to every collector.
    try testing.expect(!query.raycastAny(&world.bp, &world.bm, &world.store, .{
        .origin = vr(0, 5, 0),
        .direction = vr(0, 1, 0),
        .max_distance = 100,
    }));

    // (3) raycastAll — with a sphere at (0, 3, 0) the same downward ray meets its top at
    // y = 4 (t = 1) and then the plane at y = 0 (t = 5), in that order.
    const sphere_body = try addUnitSphere(gpa, &world, .{ 0, 3, 0 }, 1);
    var hits: [4]query.RayHit = undefined;
    const n = query.raycastAll(&world.bp, &world.bm, &world.store, .{
        .origin = vr(0, 5, 0),
        .direction = vr(0, -1, 0),
        .max_distance = 100,
    }, &hits);
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(sphere_body, hits[0].body);
    try testing.expectApproxEqAbs(@as(Real, 1), hits[0].distance, tol);
    try testing.expectEqual(ground, hits[1].body);
    try testing.expectApproxEqAbs(@as(Real, 5), hits[1].distance, tol);

    // (4) shapeCast — a sphere probe of radius 0.5 from (0, 5, 0) downward: its surface
    // is at y = 4.5, so it travels 4.5 to touch the boundary, witness at the origin. The
    // sphere body at (0, 3, 0) is nearer, so aim past it in X to isolate the plane.
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const cast = (try query.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .origin = vr(20, 5, 0),
        .direction = vr(0, -1, 0),
        .max_distance = 100,
    })).?;
    try testing.expectEqual(ground, cast.body);
    try testing.expectApproxEqAbs(@as(Real, 4.5), cast.distance, tol);
    try testing.expect(cast.position.approxEql(vr(20, 0, 0), tol));
    try testing.expect(cast.normal.approxEql(Vec3r.unit_y, tol));

    // (5) overlapShape — a unit-sphere probe centred at (20, 0.5, 0) reaches y = −0.5,
    // inside the solid; at (20, 1.5, 0) it reaches y = 0.5 and does not.
    var bodies: [4]api.BodyId = undefined;
    const probe_unit = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    try testing.expectEqual(@as(u32, 1), try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe_unit,
        .position = vr(20, 0.5, 0),
    }, &bodies));
    try testing.expectEqual(ground, bodies[0]);
    try testing.expectEqual(@as(u32, 0), try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe_unit,
        .position = vr(20, 1.5, 0),
    }, &bodies));

    // (6) overlapAabb — THE OBLIGATION DEFERRED FROM E2. Its collector used to call
    // `bodyAabb` on every candidate, which asserts on a half-space; it goes through
    // `aabbOverlapsBody` now, whose half-space arm is the corner predicate. A box
    // straddling y = 0 meets the solid; one entirely above does not.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, vr(19, -1, -1), vr(21, 1, 1), .{}, &bodies));
    try testing.expectEqual(ground, bodies[0]);
    try testing.expectEqual(@as(u32, 0), query.overlapAabb(&world.bp, &world.bm, &world.store, vr(19, 1, -1), vr(21, 2, 1), .{}, &bodies));
    // A box exactly touching the boundary from above counts — the half-space is CLOSED.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(&world.bp, &world.bm, &world.store, vr(19, 0, -1), vr(21, 2, 1), .{}, &bodies));

    // (7) pointQuery — solid, boundary included.
    try testing.expectEqual(@as(u32, 1), query.pointQuery(&world.bp, &world.bm, &world.store, vr(20, -1, 0), .{}, &bodies));
    try testing.expectEqual(ground, bodies[0]);
    try testing.expectEqual(@as(u32, 1), query.pointQuery(&world.bp, &world.bm, &world.store, vr(20, 0, 0), .{}, &bodies));
    try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, vr(20, 1, 0), .{}, &bodies));

    // (8) closestPoint — from (20, 5, 0) the nearest solid point is (20, 0, 0), 5 m away.
    const closest = query.closestPoint(&world.bp, &world.bm, &world.store, vr(20, 5, 0), 10, .{}).?;
    try testing.expectEqual(ground, closest.body);
    try testing.expectApproxEqAbs(@as(Real, 5), closest.distance, tol);
    try testing.expect(closest.position.approxEql(vr(20, 0, 0), tol));
    // Outside the radius: nothing.
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, vr(20, 5, 0), 4, .{}) == null);
}

test "the object mask and the exclusions filter a half-space body" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const shape = try world.store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = 0 } });
    const ground = try world.bm.addBody(gpa, &world.store, .{
        .shape = shape,
        .body_type = .static,
        .collision_layer = 3,
        .entity = .{ .index = 0, .generation = 0 },
    });
    const world_plane = shape_mod.halfSpace(world.store.get(shape).?)
        .transformed(world.bm.rotation(ground).?, world.bm.position(ground).?);
    _ = try world.bp.insertUnbounded(gpa, .static, .{ .normal = world_plane.normal, .distance = world_plane.distance }, ground);

    const down = query.RayQuery{ .origin = vr(0, 5, 0), .direction = vr(0, -1, 0), .max_distance = 100 };
    // The full mask sees it; a mask naming only layer 3 sees it; one naming only layer 4
    // does not — so the mask is read from the body and not ignored for an unbounded one.
    try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, down) != null);
    var only_3 = down;
    only_3.filter.layer_mask = @as(u32, 1) << 3;
    try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, only_3) != null);
    var only_4 = down;
    only_4.filter.layer_mask = @as(u32, 1) << 4;
    try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, only_4) == null);

    // Excluding the body itself removes it, on every entry that takes a filter.
    var excluded = down;
    const exclude_list = [_]api.BodyId{ground};
    excluded.filter.exclude = &exclude_list;
    try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, excluded) == null);
    try testing.expect(!query.raycastAny(&world.bp, &world.bm, &world.store, excluded));
    var bodies: [4]api.BodyId = undefined;
    try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, vr(0, -1, 0), .{ .exclude = &exclude_list }, &bodies));
    try testing.expectEqual(@as(u32, 0), query.overlapAabb(&world.bp, &world.bm, &world.store, vr(-1, -1, -1), vr(1, 1, 1), .{ .exclude = &exclude_list }, &bodies));
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, vr(0, 5, 0), 10, .{ .exclude = &exclude_list }) == null);
}

test "a sleeping body answers and stays asleep with a plane in the scene" {
    const gpa = testing.allocator;
    var world = harness.World.init(vr(0, -9.81, 0), 1.0 / 60.0); // sleeping ENABLED
    defer world.deinit(gpa);

    // The plane is added LAST, on purpose and twice over: it is the pairing direction a
    // naive suite omits, and adding a body must not wake anyone — insertion touches no
    // other body, and the wake fixpoint lives in `build`, which is not run here.
    const box = try harness.groundAndBox(gpa, &world, 1.0, 0);
    var ticks: u32 = 0;
    while (ticks < 400 and !(world.bm.isSleeping(box) orelse false)) : (ticks += 1) {
        try world.step(gpa);
    }
    try testing.expect(world.bm.isSleeping(box).?);

    const ground = try addGround(gpa, &world, 9);
    try testing.expect(world.bm.isSleeping(box).?); // adding the plane woke nobody

    // Both answer, and the sleeper is still asleep afterwards: a query takes
    // `*const BodyManager`, so it cannot wake anything — structurally, not by
    // convention.
    var bodies: [8]api.BodyId = undefined;
    const found = query.overlapAabb(&world.bp, &world.bm, &world.store, vr(-10, -10, -10), vr(10, 10, 10), .{}, &bodies);
    try testing.expect(found >= 2);
    var saw_plane = false;
    var saw_sleeper = false;
    for (bodies[0..found]) |b| {
        if (b == ground) saw_plane = true;
        if (b == box) saw_sleeper = true;
    }
    try testing.expect(saw_plane and saw_sleeper);
    try testing.expect(world.bm.isSleeping(box).?);
}

test "the answer is invariant under creation-order permutation, and two runs are bit-identical" {
    const gpa = testing.allocator;

    // The SAME scene built in two orders — plane first, then plane last — must give the
    // same answer, identities included. That is §1.11.6's invariance, and here it also
    // exercises BOTH pairing directions at entry grain: with the plane first the bodies'
    // own insertions cross it, with the plane last only the unbounded-insertion path can.
    const Answer = struct { body: api.BodyId, entity: u32, distance: Real, position: [3]Real };
    var answers: [2]Answer = undefined;
    for (0..2) |order| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        if (order == 0) {
            _ = try addGround(gpa, &world, 0);
            _ = try addUnitSphere(gpa, &world, .{ 0, 3, 0 }, 1);
        } else {
            _ = try addUnitSphere(gpa, &world, .{ 0, 3, 0 }, 1);
            _ = try addGround(gpa, &world, 0);
        }
        // Aim past the sphere so the plane is the answer, and the answer's ENTITY is what
        // is compared — `BodyId` is a slot index and encodes creation order, which is
        // exactly what must not leak into the result (§1.11.14).
        const hit = query.raycast(&world.bp, &world.bm, &world.store, .{
            .origin = vr(20, 5, 0),
            .direction = vr(0, -1, 0),
            .max_distance = 100,
        }).?;
        answers[order] = .{
            .body = hit.body,
            .entity = world.bm.entity(hit.body).?.index,
            .distance = hit.distance,
            .position = hit.position.toArray(),
        };
    }
    // The ENTITY is identical across the two orders, and so are the geometric answers —
    // bit-identically, no tolerance: the same arithmetic ran on the same inputs.
    try testing.expectEqual(@as(u32, 0), answers[0].entity);
    try testing.expectEqual(answers[0].entity, answers[1].entity);
    try testing.expectEqual(answers[0].distance, answers[1].distance);
    inline for (0..3) |i| try testing.expectEqual(answers[0].position[i], answers[1].position[i]);

    // And two identical runs in one world are bit-identical.
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try addGround(gpa, &world, 0);
    const q = query.RayQuery{ .origin = vr(20, 5, 0), .direction = vr(0, -1, 0), .max_distance = 100 };
    const first = query.raycast(&world.bp, &world.bm, &world.store, q).?;
    const again = query.raycast(&world.bp, &world.bm, &world.store, q).?;
    try testing.expectEqual(first.body, again.body);
    try testing.expectEqual(first.distance, again.distance);
    inline for (0..3) |i| try testing.expectEqual(first.position.toArray()[i], again.position.toArray()[i]);
    inline for (0..3) |i| try testing.expectEqual(first.normal.toArray()[i], again.normal.toArray()[i]);
}

// ---------------------------------------------------------------------------
// E6 — the contact path
// ---------------------------------------------------------------------------

/// A static plane body carrying the LOCAL half-space `(normal, distance)` at the
/// origin, added through the harness (so it lands in the layer's unbounded list).
fn addPlaneBody(gpa: std.mem.Allocator, world: *harness.World, normal: ApiVec3, distance: f32, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .plane = .{ .normal = normal, .distance = distance } });
    return world.addBody(gpa, .{
        .shape = shape,
        .body_type = .static,
        .entity = .{ .index = entity_index, .generation = 0 },
    });
}

/// A dynamic box of half-extents `he` at `centre`.
fn addBox(gpa: std.mem.Allocator, world: *harness.World, he: [3]f32, centre: [3]f32, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(he[0], he[1], he[2]) } });
    return world.addBody(gpa, .{
        .shape = shape,
        .body_type = .dynamic,
        .position = av3(centre[0], centre[1], centre[2]),
        .entity = .{ .index = entity_index, .generation = 0 },
    });
}

test "a plane manifold puts a box on four contacts" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // Ground `{ y <= 0 }` and a unit box (half-extents 0.5) centred at y = 0.375, so its
    // bottom face sits at y = −0.125. CLOSED FORMS, all four identical by symmetry:
    //
    //   surface point of the box    y = −0.125      ⇒ sep = −0.125
    //   penetration                 −sep = 0.125
    //   contact position            midpoint of y = −0.125 and its projection y = 0
    //                                              ⇒ y = −0.0625, x = ±0.5, z = ±0.5
    //   normal (A→B, plane→box)     +Y
    //
    // **Every literal here is a dyadic rational — 3/8, 1/2, 1/8, 1/16 — exactly
    // representable at `f32` AND at `f64`.** That is deliberate and it is not decoration:
    // a body's position comes from an `f32` DESCRIPTOR (§1.11.8 keeps the public surface
    // f32 whatever the solver scalar), so a centre of 0.4 is stored as 0.4000000059604645
    // and the penetration is not 0.1 but 0.09999999403953552 — which passes at f32, where
    // the tolerance is coarse, and fails at f64, where it is not. Choosing exact inputs
    // removes the quantisation instead of widening a bound to tolerate it.
    const ground = try addPlaneBody(gpa, &world, av3(0, 1, 0), 0, 0);
    const box = try addBox(gpa, &world, .{ 0.5, 0.5, 0.5 }, .{ 0, 0.375, 0 }, 1);

    const m = world.bm.collidePair(&world.store, ground, box).?;
    try testing.expectEqual(@as(u8, 4), m.count);
    try testing.expect(m.normal.approxEql(Vec3r.unit_y, tol));

    var seen_ids: [4]u32 = undefined;
    for (0..4) |i| {
        const p = m.points[i];
        try testing.expectApproxEqAbs(@as(Real, 0.125), p.penetration, tol);
        try testing.expectApproxEqAbs(@as(Real, -0.0625), p.position.toArray()[1], tol);
        // The four are the bottom face's corners: |x| = |z| = 0.5.
        try testing.expectApproxEqAbs(@as(Real, 0.5), @abs(p.position.toArray()[0]), tol);
        try testing.expectApproxEqAbs(@as(Real, 0.5), @abs(p.position.toArray()[2]), tol);
        seen_ids[i] = p.feature_id;
    }
    // The four ids are DISTINCT — the warm-start cache keys on them, so two contacts of
    // one manifold sharing an id would collapse into a single cached impulse.
    for (0..4) |i| {
        for (i + 1..4) |j| try testing.expect(seen_ids[i] != seen_ids[j]);
    }

    // …and the two anchors §3 defines reconstruct exactly, which is what makes the NGS
    // position pass need no case for this shape: `position + ½·pen·n` is the PLANE's
    // surface point (y = 0) and `position − ½·pen·n` is the BOX's (y = −0.1).
    for (0..4) |i| {
        const p = m.points[i];
        const surface_a = p.position.add(m.normal.scale(p.penetration * 0.5));
        const surface_b = p.position.sub(m.normal.scale(p.penetration * 0.5));
        try testing.expectApproxEqAbs(@as(Real, 0), surface_a.toArray()[1], tol);
        try testing.expectApproxEqAbs(@as(Real, -0.125), surface_b.toArray()[1], tol);
    }

    // Order-independence: the swapped call negates the normal and leaves the positions
    // and penetrations alone (§3's contract, inherited here rather than re-derived).
    const swapped = world.bm.collidePair(&world.store, box, ground).?;
    try testing.expectEqual(m.count, swapped.count);
    try testing.expect(swapped.normal.approxEql(Vec3r.unit_y.neg(), tol));
    for (0..4) |i| {
        try testing.expectApproxEqAbs(m.points[i].penetration, swapped.points[i].penetration, tol);
        try testing.expect(m.points[i].position.approxEql(swapped.points[i].position, tol));
    }
}

test "the half-space feature-id class is disjoint from every other producer, by mask" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground = try addPlaneBody(gpa, &world, av3(0, 1, 0), 0, 0);
    const box = try addBox(gpa, &world, .{ 0.5, 0.5, 0.5 }, .{ 0, 0.375, 0 }, 1);

    // BY CONSTRUCTION, on the MASK — not by enumerating which of the existing pairs
    // happen to be taken. `class_plane` is a FOURTH value of the 2-bit class field, and
    // `manifold.zig`'s comptime block asserts the four tags are pairwise distinct and
    // each exactly a class value. So a producer that ORs one of the other three into its
    // reference half cannot emit this one, whatever pair of halves it chooses — and the
    // pair `(class_a, class_c)` was already the single-witness producer's, which is why a
    // free pair would not have been free.
    const m = world.bm.collidePair(&world.store, ground, box).?;
    for (0..m.count) |i| {
        const reference_half: u16 = @intCast(m.points[i].feature_id >> 16);
        try testing.expectEqual(narrowphase.feature_class_plane, reference_half & narrowphase.feature_class_mask);
    }

    // A convex pair through the SAME entry never carries that class in its reference
    // half — the other side of the disjointness, measured rather than assumed.
    const other = try addBox(gpa, &world, .{ 0.5, 0.5, 0.5 }, .{ 0, 1.25, 0 }, 2);
    const convex = world.bm.collidePair(&world.store, box, other).?;
    for (0..convex.count) |i| {
        const reference_half: u16 = @intCast(convex.points[i].feature_id >> 16);
        try testing.expect(reference_half & narrowphase.feature_class_mask != narrowphase.feature_class_plane);
    }
}

test "a sphere and a capsule on a plane get the contact count their supporting face returns" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground = try addPlaneBody(gpa, &world, av3(0, 1, 0), 0, 0);

    // A SPHERE's core is a single POINT, so its supporting face has ONE vertex whatever
    // the direction — one contact, not the several a curved surface might suggest.
    // Radius 1 centred at y = 0.875 (7/8, exact at both precisions — see the four-contact
    // test on why every literal here is dyadic): surface point y = −0.125, penetration
    // 0.125, contact at y = −0.0625 on the axis.
    const sphere_shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const ball = try world.addBody(gpa, .{
        .shape = sphere_shape,
        .body_type = .dynamic,
        .position = av3(0, 0.875, 0),
        .entity = .{ .index = 1, .generation = 0 },
    });
    const ms = world.bm.collidePair(&world.store, ground, ball).?;
    try testing.expectEqual(@as(u8, 1), ms.count);
    try testing.expectApproxEqAbs(@as(Real, 0.125), ms.points[0].penetration, tol);
    try testing.expect(ms.points[0].position.approxEql(vr(0, -0.0625, 0), tol));

    // A STANDING capsule is END-ON to `−n`, so `supportingFace` returns its single
    // extremal endpoint: ONE contact. Radius 0.25, half-height 0.875, centred at y = 1 ⇒
    // the lower cap's surface is at 1 − 0.875 − 0.25 = −0.125.
    const cap_shape = try world.store.createShape(gpa, .{ .capsule = .{ .radius = 0.25, .half_height = 0.875 } });
    const standing = try world.addBody(gpa, .{
        .shape = cap_shape,
        .body_type = .dynamic,
        .position = av3(4, 1, 0),
        .entity = .{ .index = 2, .generation = 0 },
    });
    const mc = world.bm.collidePair(&world.store, ground, standing).?;
    try testing.expectEqual(@as(u8, 1), mc.count);
    try testing.expectApproxEqAbs(@as(Real, 0.125), mc.points[0].penetration, tol);

    // A LYING capsule is PERPENDICULAR to `−n`, so the same feature is the whole
    // segment: TWO contacts, one per endpoint, 2·half_height apart. Rotated +90° about
    // +Z maps its local +Y axis onto world −X. Centred at y = 0.125 ⇒ the wall's surface
    // is at 0.125 − 0.25 = −0.125.
    const lying = try world.addBody(gpa, .{
        .shape = cap_shape,
        .body_type = .dynamic,
        .position = av3(8, 0.125, 0),
        .rotation = foundation.math.Quatf.fromAxisAngle(ApiVec3.unit_z, std.math.pi / 2.0),
        .entity = .{ .index = 3, .generation = 0 },
    });
    const ml = world.bm.collidePair(&world.store, ground, lying).?;
    try testing.expectEqual(@as(u8, 2), ml.count);
    for (0..2) |i| {
        try testing.expectApproxEqAbs(@as(Real, 0.125), ml.points[i].penetration, tol);
        try testing.expectApproxEqAbs(@as(Real, -0.0625), ml.points[i].position.toArray()[1], tol);
    }
    // …and they are 2·half_height = 1.75 m apart along the capsule's axis, world X here.
    const span = @abs(ml.points[0].position.toArray()[0] - ml.points[1].position.toArray()[0]);
    try testing.expectApproxEqAbs(@as(Real, 1.75), span, tol);
    // Distinct ids: the two endpoints carry `vert_id` 0 and 1.
    try testing.expect(ml.points[0].feature_id != ml.points[1].feature_id);
}

test "an oblique plane against a rotated box keeps the stored normal as the contact normal" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);

    // A plane whose normal is NOT axis-aligned — `(2, −3, 6)/7`, the exact Pythagorean
    // quadruple — and a box rotated off every axis. The contact normal must be the
    // STORED normal mapped to world, tight: it is returned with no arithmetic beyond one
    // rotation, so unlike a reconstructed normal it carries no residue of the geometry.
    const n = av3(2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0);
    const ground = try addPlaneBody(gpa, &world, n, 0, 0);

    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const spun = try world.addBody(gpa, .{
        .shape = box_shape,
        .body_type = .dynamic,
        // Placed just inside the solid along the normal, so contact is guaranteed
        // whatever face the rotation turns toward the plane.
        .position = av3(-0.2 * 2.0 / 7.0, 0.2 * 3.0 / 7.0, -0.2 * 6.0 / 7.0),
        .rotation = foundation.math.Quatf.fromAxisAngle(av3(1, 2, 3).normalize(), 0.7),
        .entity = .{ .index = 1, .generation = 0 },
    });

    const m = world.bm.collidePair(&world.store, ground, spun).?;
    try testing.expect(m.count >= 1);
    // TWO bounds again, and the SAME rule as the creation test above — see "the stored
    // plane normal is unit, and independent of distance" for the measurement.
    //
    // The NORM is tight at the SOLVER scalar: the plane body is at identity rotation, so
    // the returned normal is the stored unit value carried through one rotation and
    // nothing else.
    try testing.expectApproxEqAbs(@as(Real, 1), m.normal.length(), 8 * std.math.floatEps(Real));
    // The ORIENTATION is pinned at one ulp of `f32`, because that is the resolution its
    // INPUT had: `(2, −3, 6)/7` reached the store through an `f32` descriptor, and
    // comparing it against the exact `f64` rational at `floatEps(Real)` would be
    // asserting that an f64 solver recovers information the descriptor never carried.
    // Measured at 0.077 ulp of f32 on the f64 leg.
    try testing.expect(m.normal.approxEql(vr(2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0), std.math.floatEps(f32)));
    // Every contact is genuinely penetrating and its anchors straddle the boundary.
    const plane_world = narrowphase.plane.HalfSpace(Real){
        .normal = vr(2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0),
        .distance = 0,
    };
    for (0..m.count) |i| {
        const p = m.points[i];
        try testing.expect(p.penetration > 0);
        const surface_a = p.position.add(m.normal.scale(p.penetration * 0.5));
        // The oracle plane is built from the EXACT rational while the body's is the f32
        // descriptor's, so the residual is the descriptor's resolution at this scale —
        // the same budget as the orientation above, not `tol`.
        const budget: Real = 8 * std.math.floatEps(f32) * (1 + surface_a.length());
        try testing.expectApproxEqAbs(@as(Real, 0), plane_world.signedDistance(surface_a), @max(budget, tol));
    }
}

test "a full tick cycle runs with a plane body, and a falling box comes to rest on it" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);

    // THE RESIDUAL E5 NAMED, CLOSED. Until this gate `world.step()` panicked in
    // `collidePair` the moment the broadphase emitted a pair containing a plane body:
    // the plane reached `supportShape`, whose precondition is the convex class. A FULL
    // cycle now, all eleven steps, not a kernel call.
    const plane_body = try addPlaneBody(gpa, &world, av3(0, 1, 0), 0, 0);
    const box = try addBox(gpa, &world, .{ 0.5, 0.5, 0.5 }, .{ 0, 3, 0 }, 1);

    var ticks: u32 = 0;
    while (ticks < 400) : (ticks += 1) try world.step(gpa);

    // It fell, it stopped, and it stopped ON the plane. The resting centre is the box's
    // half-extent above the boundary, less the residual penetration the NGS pass leaves
    // at its fixed point — the slop, `SolverConfig.penetration_slop = 0.005`.
    //
    // MEASURED at 400 ticks, both legs:
    //
    //   leg   resting centre_y   penetration   vy
    //   f32   0.495073940        0.004926056   −3.7252903e-9
    //   f64   0.495074006        0.004925994    6.9388939e-18
    //
    // and the settled manifold carries FOUR contacts, one constraint. Worth recording:
    // it settles just BELOW the slop, where M1.1.7's RD-1 measured a box on a BOX
    // settling just above it (0.00500059 at f32). The difference is not a discrepancy —
    // the correction factor is 0.2, so the last step lands within one step of the fixed
    // point on either side — but the plane's `sep` is a dot product against a stored unit
    // normal with no clip behind it, so nothing pushes it to approach from one side.
    //
    // The bound is therefore stated on the slop and one correction step, not on an exact
    // zero and not as a loose window that would pass on a box halfway through its fall.
    const slop: Real = world.cfg.penetration_slop;
    const centre_y = world.bm.position(box).?.toArray()[1];
    const penetration = 0.5 - centre_y;
    try testing.expect(penetration > 0); // it IS resting on the plane, not hovering
    try testing.expect(penetration <= 2 * slop); // and it did NOT sink through
    const velocity_y = world.bm.linearVelocity(box).?.toArray()[1];
    try testing.expectApproxEqAbs(@as(Real, 0), velocity_y, 1e-6);
    // The settled contact is the FOUR-point face manifold, not a degenerate single point.
    try testing.expectEqual(@as(u8, 4), world.bm.collidePair(&world.store, plane_body, box).?.count);
    // Nothing became NaN on the way — the poison of E2 never entered an arithmetic path.
    for (world.bm.position(box).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
    for (world.bm.linearVelocity(box).?.toArray()) |v| try testing.expect(!std.math.isNan(v));
}

// ---------------------------------------------------------------------------
// E7 / I1 — the bit-agreement between the overlap predicate and the generator
// ---------------------------------------------------------------------------

test "overlapShapeBody and collidePlane agree to the bit on whether a pair touches" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground = try addPlaneBody(gpa, &world, av3(0, 1, 0), 0, 0);

    // E6 CLAIMED this agreement as a consequence of NOT copying the generic generator's
    // `keep_eps`: the query predicate is `separation(...) <= 0` and the generator's
    // per-vertex criterion is `sep <= 0`, both exact, so they cannot disagree. A claim
    // of agreement that is never exercised is a plea, so here it is exercised — on
    // configurations that BRACKET the contact, which is the only place a disagreement
    // could hide.
    //
    // For each shape the offsets place its lowest surface point above the boundary,
    // EXACTLY on it, and one ULP below. `nextAfter` walks the actual representable
    // neighbour rather than subtracting a made-up small number, so "one ulp" is one ulp.
    // `rest_y` is `f32`, not `Real`: it is a DESCRIPTOR height, and the whole point is to
    // step to f32's own representable neighbours — the precision the body's position is
    // actually stored in (§1.11.8), whatever the solver scalar.
    const Case = struct { name: []const u8, shape: api.ShapeDescriptor, rest_y: f32 };
    const cases = [_]Case{
        // A box of half-extent 1/2: its bottom face is at `centre − 0.5`, so a centre of
        // exactly 0.5 puts that face exactly on the boundary.
        .{ .name = "box", .shape = .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } }, .rest_y = 0.5 },
        // A sphere of radius 1: its lowest surface point is `centre − 1`.
        .{ .name = "sphere", .shape = .{ .sphere = .{ .radius = 1 } }, .rest_y = 1 },
        // A capsule r = 1/4, h = 7/8, standing: lowest point is `centre − 1.125`.
        .{ .name = "capsule", .shape = .{ .capsule = .{ .radius = 0.25, .half_height = 0.875 } }, .rest_y = 1.125 },
    };

    var agreements: u32 = 0;
    var touching: u32 = 0;
    var separated: u32 = 0;
    for (cases) |c| {
        const shape_id = try world.store.createShape(gpa, c.shape);
        const probe = shape_mod.supportShape(world.store.get(shape_id).?);
        // ABOVE, EXACTLY ON, and ONE ULP BELOW the resting height — plus a clearly
        // separated and a clearly penetrating control, so the sample is not all boundary.
        const heights = [_]f32{
            c.rest_y + 1,
            std.math.nextAfter(f32, c.rest_y, 1e30), // one ulp above ⇒ separated
            c.rest_y, // exactly on ⇒ touching, the half-space being closed
            std.math.nextAfter(f32, c.rest_y, -1e30), // one ulp below ⇒ touching
            c.rest_y - 0.25,
        };
        for (heights) |h| {
            const body = try world.addBody(gpa, .{
                .shape = shape_id,
                .body_type = .dynamic,
                .position = av3(0, h, 0),
                .entity = .{ .index = 1, .generation = 0 },
            });
            // THE TWO ANSWERS, on the same pose: the query predicate at the body grain,
            // and the generator's own verdict (a manifold, or null when separated).
            const by_overlap = world.bm.overlapShapeBody(
                &world.store,
                ground,
                probe,
                vr(0, h, 0),
                Quatr.identity,
            ).?;
            const by_manifold = world.bm.collidePair(&world.store, ground, body) != null;
            try testing.expectEqual(by_overlap, by_manifold);
            agreements += 1;
            if (by_overlap) touching += 1 else separated += 1;
            world.removeBody(body);
        }
    }
    // The sample really straddled the boundary — an all-touching or all-separated sweep
    // would satisfy the equality above while proving nothing.
    try testing.expectEqual(@as(u32, 15), agreements);
    try testing.expect(touching > 0 and separated > 0);
    // And each shape contributed both verdicts: 2 separated (above, one ulp above) and
    // 3 touching (exactly on, one ulp below, well below) per shape.
    try testing.expectEqual(@as(u32, 6), separated);
    try testing.expectEqual(@as(u32, 9), touching);
}

// ---------------------------------------------------------------------------
// E7 / J1 — `normal · direction <= 0` on EVERY hit, the four kernels agreeing
// ---------------------------------------------------------------------------

test "an outward cast from inside a half-space reports minus-direction, not the plane normal" {
    // THE TEST THAT DID NOT EXIST. `plane.castShape` returned `plane.normal` at initial
    // overlap whatever the sweep direction, so a cast aimed OUT of the solid — along `+n`,
    // to leave it — answered `normal · direction = +1`, breaking the invariant
    // `shapecast.zig`'s `terminal` states as "the only one keeping
    // `normal · direction <= 0` on every hit". The inward cases below always had
    // `normal · direction = −1` by luck of aim, which is why the existing suite passed
    // through the defect: changing the returned normal moved no test.
    const plane = HS{ .normal = Vec3r.unit_y, .distance = 0 }; // solid `y <= 0`
    // A sphere of radius 1/2 centred at y = −2: entirely inside, so `sep₀ < 0` on every
    // direction and every case below is an INITIAL OVERLAP.
    const probe = sphere(0.5);
    const inside_plane = HS{ .normal = Vec3r.unit_y, .distance = 2 }; // A's frame: origin is 2 m in

    for ([_]Vec3r{
        Vec3r.unit_y, // straight OUT — the case that was wrong
        Vec3r.unit_y.neg(), // straight in
        Vec3r.unit_x, // along the boundary
        Vec3r.unit_y.add(Vec3r.unit_x).normalize(), // obliquely out
        Vec3r.unit_y.neg().add(Vec3r.unit_z).normalize(), // obliquely in
    }) |d| {
        const hit = narrowphase.plane.castShape(Real, inside_plane, probe, d, 100).?;
        try testing.expectEqual(@as(Real, 0), hit.distance); // initial overlap
        // THE invariant, on every one of them.
        try testing.expect(hit.normal.dot(d) <= 0);
        // …and specifically `−direction`, which is what the other three kernels return at
        // a zero parameter.
        try testing.expect(hit.normal.eql(d.neg()));
        // The witness still lies ON the boundary — the geometry is unchanged, only the
        // normal's rule is.
        try testing.expectApproxEqAbs(@as(Real, 0), inside_plane.signedDistance(hit.point), tol);
    }

    // A cast that is NOT an initial overlap still reports the plane's normal, so the rule
    // above is confined to the degenerate case and has not swallowed the ordinary one.
    _ = plane;
    const above = HS{ .normal = Vec3r.unit_y, .distance = -10 }; // solid `y <= −10`
    const real_hit = narrowphase.plane.castShape(Real, above, probe, Vec3r.unit_y.neg(), 100).?;
    try testing.expect(real_hit.distance > 0);
    try testing.expect(real_hit.normal.eql(Vec3r.unit_y));
    try testing.expect(real_hit.normal.dot(Vec3r.unit_y.neg()) <= 0);
}

test "the four kernels agree on the normal at a zero parameter" {
    // `raycast.zig` for an origin inside a convex, `plane.rayShape` for an origin inside
    // the half-space, `plane.castShape` at initial overlap, and `shapecast.zig` when its
    // own axis has collapsed — all four answer `−direction`, and the invariant
    // `normal · direction <= 0` holds on every hit of every one of them.
    const d = vr(2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0); // oblique unit direction

    // (1) convex ray kernel, origin inside a unit sphere.
    const ray_convex = narrowphase.rayShape(Real, sphere(1), Vec3r.zero, d).?;
    try testing.expectEqual(@as(Real, 0), ray_convex.distance);
    try testing.expect(ray_convex.normal.eql(d.neg()));
    try testing.expect(ray_convex.normal.dot(d) <= 0);

    // (2) half-space ray kernel, origin inside the solid.
    const inside = HS{ .normal = Vec3r.unit_y, .distance = 5 };
    const ray_plane = narrowphase.plane.rayShape(Real, inside, Vec3r.zero, d).?;
    try testing.expectEqual(@as(Real, 0), ray_plane.distance);
    try testing.expect(ray_plane.normal.eql(d.neg()));
    try testing.expect(ray_plane.normal.dot(d) <= 0);

    // (3) half-space cast kernel, initial overlap.
    const cast_plane = narrowphase.plane.castShape(Real, inside, sphere(0.5), d, 100).?;
    try testing.expectEqual(@as(Real, 0), cast_plane.distance);
    try testing.expect(cast_plane.normal.eql(d.neg()));
    try testing.expect(cast_plane.normal.dot(d) <= 0);

    // (4) the convex cast kernel, two coincident spheres — the hard-core collapse its
    // `terminal` documents. Whatever axis it settles on, the invariant holds.
    const cast_convex = narrowphase.castShape(
        Real,
        sphere(1),
        narrowphase.RelativePose(Real).init(Vec3r.zero, Quatr.identity, Vec3r.zero, Quatr.identity),
        sphere(1),
        d,
        100,
    ).?;
    try testing.expectEqual(@as(Real, 0), cast_convex.distance);
    try testing.expect(cast_convex.normal.dot(d) <= 0);
}

test "castShapeBody transports the normal without disturbing the invariant" {
    const gpa = testing.allocator;
    var scene = try PlaneScene.init(gpa);
    defer scene.deinit(gpa);

    // The adapter only ROTATES the kernel's normal into world. A rotation preserves the
    // dot product with the equally rotated direction, so the invariant is carried
    // exactly — which is why J1's fix is local to the kernel and needed no adapter change.
    // Asserted rather than argued: the scene's solid is `x >= 10`, so a probe at x = 50 is
    // deep inside it and every direction below is an initial overlap.
    const probe = narrowphase.SupportShape(Real){ .core = .point, .radius = 0.5 };
    for ([_]Vec3r{ Vec3r.unit_x, Vec3r.unit_x.neg(), Vec3r.unit_y, vr(1, 1, 1).normalize() }) |d| {
        const hit = scene.bm.castShapeBody(&scene.store, scene.body, probe, vr(50, 1, 2), Quatr.identity, d, 100).?;
        try testing.expectEqual(@as(Real, 0), hit.distance);
        try testing.expect(hit.normal.dot(d) <= 0);
        try testing.expect(hit.normal.approxEql(d.neg(), 8 * std.math.floatEps(Real)));
    }
}

// ---------------------------------------------------------------------------
// E7 / J2 — the `distance` domain
// ---------------------------------------------------------------------------

test "a non-finite plane distance is refused at creation, in both senses" {
    // THE PREDICATE both halves of the domain are tested through, exercised on accepted
    // and rejected inputs — a control never seen to fail is a comment with syntax.
    //
    // WHY it is a domain error and not an unusual value, MEASURED with `distance = NaN`,
    // identically at f32 and f64, and the two consequences CONTRADICT each other:
    //
    //   (a) `signedDistance` is NaN, so `sep > 0` is FALSE, so `collidePlane`'s
    //       `if (sep > 0) continue;` does not fire and a contact IS emitted. Measured:
    //       a unit sphere 1000 m OUTSIDE the solid produced a manifold with one point.
    //       The plane reports contact with everything.
    //   (b) every comparison in `Aabb.overlapsHalfSpace` is FALSE against a NaN bound.
    //       Measured: the predicate answered `false` for a box at the origin AND for a
    //       box 5000 m deep INSIDE the solid. The plane meets nothing and vanishes from
    //       the broadphase.
    //
    // One malformed input; the narrowphase says "touching everything" and the broadphase
    // says "touching nothing"; and neither is visible to the caller. That is why it is an
    // assert on the way in rather than a value the kernels tolerate.
    try testing.expect(std.math.isFinite(@as(f32, 0)));
    for ([_]f32{ 0, -1, 1e6, -12345.678, std.math.floatMin(f32), -std.math.floatMax(f32) }) |d| {
        try testing.expect(std.math.isFinite(d));
    }
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |d| {
        try testing.expect(!std.math.isFinite(d));
    }

    // The accepted values really are accepted, end to end: a plane at each of them
    // builds, and the stored distance round-trips.
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    for ([_]f32{ 0, -1, 1e6, -12345.678 }) |d| {
        const id = try store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = d } });
        try testing.expectEqual(@as(Real, d), store.get(id).?.distance);
    }

    // And the KERNEL-side half of the domain, `HalfSpace.assertDomain`, guards the
    // TRANSPORTED form too — the descriptor assert cannot, a transport being downstream
    // of it. Both halves of that assert are exercised as predicates here for the same
    // reason: `assertDomain` itself cannot be caught in a Zig test, and each half was
    // observed to fire by hand.
    const unit_ok = HS{ .normal = Vec3r.unit_y, .distance = 3 };
    try testing.expect(@abs(unit_ok.normal.lengthSq() - 1) <= 16 * std.math.floatEps(Real));
    try testing.expect(std.math.isFinite(unit_ok.distance));
    const bad_distance = HS{ .normal = Vec3r.unit_y, .distance = std.math.nan(Real) };
    try testing.expect(@abs(bad_distance.normal.lengthSq() - 1) <= 16 * std.math.floatEps(Real));
    try testing.expect(!std.math.isFinite(bad_distance.distance)); // the half that would fire
    const bad_normal = HS{ .normal = vr(0, 2, 0), .distance = 3 };
    try testing.expect(!(@abs(bad_normal.normal.lengthSq() - 1) <= 16 * std.math.floatEps(Real)));
    try testing.expect(std.math.isFinite(bad_normal.distance)); // the OTHER half is fine
}
