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
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
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

    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = av3(1, 2, 3) } });
    const capsule = try store.createShape(gpa, .{ .capsule = .{ .radius = 0.3, .half_height = 0.9 } });
    for ([_]api.ShapeId{ sphere, box, capsule }) |id| {
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
    const sphere = store.get(try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } })).?;
    inline for (0..3) |i| {
        try testing.expect(!std.math.isNan(sphere.local_aabb.min.toArray()[i]));
        try testing.expect(!std.math.isNan(sphere.unit_inertia.toArray()[i]));
    }
}
