//! `foundation/math/aabb.zig` — generic axis-aligned bounding box `Aabb(T)`.
//!
//! Stored as its minimum and maximum corners over 3-vectors. Face contact
//! counts as overlap / containment (inclusive `<=`), the convention broadphase
//! wants — and `rayInterval`, the slab test the ray traversal descends on,
//! follows the same inclusive convention.

const std = @import("std");
const vec = @import("vec.zig");

/// Axis-aligned bounding box over 3-vectors of scalar `T`, stored as its
/// minimum and maximum corners.
pub fn Aabb(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = vec.Vec(3, T);

        /// Minimum corner (componentwise smallest).
        min: Vec3T,
        /// Maximum corner (componentwise largest).
        max: Vec3T,

        /// Box from explicit min/max corners.
        pub fn fromMinMax(min_corner: Vec3T, max_corner: Vec3T) Self {
            return .{ .min = min_corner, .max = max_corner };
        }

        /// Box from a center and (non-negative) half-extents.
        pub fn fromCenterHalfExtents(center_point: Vec3T, half_extents: Vec3T) Self {
            return .{ .min = center_point.sub(half_extents), .max = center_point.add(half_extents) };
        }

        /// Smallest box containing both `self` and `other`.
        pub fn merge(self: Self, other: Self) Self {
            return .{ .min = self.min.min(other.min), .max = self.max.max(other.max) };
        }

        /// Box grown to include `point`.
        pub fn expand(self: Self, point: Vec3T) Self {
            return .{ .min = self.min.min(point), .max = self.max.max(point) };
        }

        /// Box grown by `half_extents` on every axis: `min − e`, `max + e`.
        ///
        /// This is the Minkowski sum of `self` with the box `[−e, e]`, and therefore
        /// the exact set of CENTRES at which a box of half-extents `e` overlaps
        /// `self` — the sum of two boxes being a box. That equivalence is what makes
        /// the swept-volume traversal of `engine-physics-forge.md` §1.11.10 an exact
        /// ray test against inflated nodes rather than an approximation of one, and
        /// the inline test below pins it in both directions.
        ///
        /// An ADDITION, not a threshold: no constant appears, and `half_extents` is
        /// a geometric quantity the caller measured. Distinct verb from
        /// `merge`/`expand`, which grow to CONTAIN something; this grows BY a given
        /// amount. `half_extents` is expected non-negative (the same doc-level
        /// expectation as `fromCenterHalfExtents`); a negative component shrinks the
        /// box and can invert it.
        ///
        /// At a zero `half_extents` the result COMPARES equal to `self` on all six
        /// bounds, though it is not necessarily bit-identical: `max + 0` maps a
        /// `−0.0` bound to `+0.0`. Nothing downstream distinguishes the two zeros
        /// (see `broadphase.queryRay`, which rests on exactly this).
        pub fn inflate(self: Self, half_extents: Vec3T) Self {
            return .{ .min = self.min.sub(half_extents), .max = self.max.add(half_extents) };
        }

        /// Whether `point` lies inside (inclusive of the faces).
        pub fn contains(self: Self, point: Vec3T) bool {
            return @reduce(.And, self.min.data <= point.data) and
                @reduce(.And, point.data <= self.max.data);
        }

        /// Whether `self` and `other` intersect (touching faces count).
        pub fn overlaps(self: Self, other: Self) bool {
            return @reduce(.And, self.min.data <= other.max.data) and
                @reduce(.And, other.min.data <= self.max.data);
        }

        /// Geometric center.
        pub fn center(self: Self) Vec3T {
            return self.min.add(self.max).scale(0.5);
        }

        /// Half the size along each axis.
        pub fn halfExtents(self: Self) Vec3T {
            return self.max.sub(self.min).scale(0.5);
        }

        /// Surface area `2·(dx·dy + dy·dz + dz·dx)` where `d = max - min`.
        /// The SAH cost metric the broadphase BVH descends on. A degenerate
        /// (zero-extent) box returns 0.
        pub fn surfaceArea(self: Self) T {
            const d = self.max.sub(self.min).toArray();
            return 2 * (d[0] * d[1] + d[1] * d[2] + d[2] * d[0]);
        }

        /// Parametric hit interval of a ray over a box, returned by
        /// `rayInterval`.
        pub const RayInterval = struct {
            /// Ray parameter at which the box is entered. Negative when the
            /// origin is already inside.
            enter: T,
            /// Ray parameter at which the box is left.
            exit: T,
        };

        /// Slab test of the ray `origin + t·direction` against this box,
        /// returning the parametric interval it spans, or `null` when the ray
        /// misses (an empty interval).
        ///
        /// `inv_dir` is the componentwise reciprocal of the direction and
        /// `dir_is_zero` marks the direction components that are **exactly** zero.
        /// The masked lanes still take part in the product below and their result is
        /// discarded, so any DEFINED value is legal there — `undefined` is not. The
        /// natural caller value is what `1 / 0` yields, an infinity.
        ///
        /// Preconditions: `origin` and both box corners are finite, and every lane of
        /// `inv_dir` not marked in `dir_is_zero` is non-zero (equivalently: the
        /// direction is finite). They are what makes the NaN repair below exact —
        /// `0 · inf` is then the only NaN reachable, and the exact quotient of an
        /// exactly-zero numerator is zero. `inf · 0`, whose repair to zero would be
        /// wrong, is excluded by these preconditions.
        ///
        /// Nothing here is clamped: `enter` may be negative when the origin lies
        /// inside the box, and the caller intersects the interval with its own
        /// `[0, max_distance]` window. Face contact is a hit — `enter == exit`
        /// counts — matching the inclusive convention of `overlaps` and
        /// `contains`.
        pub fn rayInterval(
            self: Self,
            origin: Vec3T,
            inv_dir: Vec3T,
            dir_is_zero: @Vector(3, bool),
        ) ?RayInterval {
            const Simd = @Vector(3, T);
            const o = origin.data;
            const lo = self.min.data;
            const hi = self.max.data;

            // Domain assertion at the entry, the shape of `sleep.assertDomain`
            // and `assertPositionDomain`: a finite origin, and a reciprocal that
            // is neither zero nor NaN on every lane the mask does not cover
            // (equivalently, a finite direction — `1 / NaN` is NaN and `1 / inf`
            // is zero, so both non-finite directions are caught). This is what
            // excludes `inf · 0` and so makes the NaN repair below exact. An
            // INFINITE reciprocal is legal and must stay so: it is the subnormal
            // direction component, the very case the repair exists for. The box
            // corners stay covered by the doc comment alone — they are
            // engine-produced, and an assert per visited node would cost for
            // nothing.
            std.debug.assert(@reduce(.And, @abs(o) < @as(Simd, @splat(std.math.inf(T)))));
            std.debug.assert(@reduce(.And, dir_is_zero |
                ((inv_dir.data != @as(Simd, @splat(0))) & (inv_dir.data == inv_dir.data))));

            // A direction component that is EXACTLY zero makes the ray parallel
            // to that pair of slab planes. The axis leaves the product and is
            // replaced by the face-inclusive containment test of the origin in
            // that slab: parallel and inside constrains nothing, parallel and
            // outside is a miss on its own.
            //
            // The guard is at TRUE ZERO and carries no epsilon. Its purpose is
            // to keep `0 · inf` out of the product, and the exact-zero branch
            // achieves that without introducing a geometric constant — the
            // reference's absolute `1.0e-20f` parallel guard is deliberately
            // not reproduced (`engine-physics-forge.md` §1.11.2).
            const outside_slab = (o < lo) | (o > hi);
            if (@reduce(.Or, dir_is_zero & outside_slab)) return null;

            const t_lo = (lo - o) * inv_dir.data;
            const t_hi = (hi - o) * inv_dir.data;

            // `0 · inf` is the one NaN this product can produce, and the mask
            // above does not cover every way in: a direction component small
            // enough that its reciprocal overflows to infinity is NOT exactly
            // zero, and an origin sitting exactly on that axis' face plane makes
            // the numerator exactly zero. Repairing that NaN to zero is not a
            // tolerance — the numerator IS zero, so the exact quotient is zero.
            // Left unrepaired, `@min`/`@max` return the other operand and the
            // lane silently loses the box.
            const zeros: Simd = @splat(0);
            const a = @select(T, t_lo != t_lo, zeros, t_lo);
            const b = @select(T, t_hi != t_hi, zeros, t_hi);

            // The parallel axes are neutralised by an unbounded interval, so the
            // reductions below see only the axes that actually constrain.
            const unbounded_lo: Simd = @splat(-std.math.inf(T));
            const unbounded_hi: Simd = @splat(std.math.inf(T));
            const near = @select(T, dir_is_zero, unbounded_lo, @min(a, b));
            const far = @select(T, dir_is_zero, unbounded_hi, @max(a, b));

            const enter = @reduce(.Max, near);
            const exit = @reduce(.Min, far);
            // Strict `>`: `enter == exit` is a single-parameter graze, a hit
            // under the same inclusive convention as `overlaps`/`contains`.
            if (enter > exit) return null;
            return .{ .enter = enter, .exit = exit };
        }
    };
}

/// f32 axis-aligned bounding box.
pub const Aabbf = Aabb(f32);

const testing = std.testing;
const Vec3 = vec.Vec3;

test "merge contains overlaps truth table" {
    const a = Aabbf.fromMinMax(Vec3.zero, Vec3.one);
    const disjoint = Aabbf.fromMinMax(Vec3.splat(2), Vec3.splat(3));
    const touching = Aabbf.fromMinMax(Vec3.one, Vec3.splat(2)); // shares corner (1,1,1)
    const nested = Aabbf.fromMinMax(Vec3.splat(0.25), Vec3.splat(0.75));

    try testing.expect(!a.overlaps(disjoint));
    try testing.expect(a.overlaps(touching)); // inclusive faces
    try testing.expect(a.overlaps(nested));
    try testing.expect(nested.overlaps(a));

    try testing.expect(a.contains(Vec3.splat(0.5)));
    try testing.expect(a.contains(Vec3.zero)); // face-inclusive
    try testing.expect(!a.contains(Vec3.splat(1.5)));

    const m = a.merge(disjoint);
    try testing.expect(m.min.approxEql(Vec3.zero, 1e-6));
    try testing.expect(m.max.approxEql(Vec3.splat(3), 1e-6));
}

test "center halfExtents and fromCenterHalfExtents" {
    const box = Aabbf.fromCenterHalfExtents(Vec3.fromArray(.{ 1, 2, 3 }), Vec3.splat(0.5));
    try testing.expect(box.center().approxEql(Vec3.fromArray(.{ 1, 2, 3 }), 1e-6));
    try testing.expect(box.halfExtents().approxEql(Vec3.splat(0.5), 1e-6));
    try testing.expect(box.min.approxEql(Vec3.fromArray(.{ 0.5, 1.5, 2.5 }), 1e-6));
    try testing.expect(box.max.approxEql(Vec3.fromArray(.{ 1.5, 2.5, 3.5 }), 1e-6));
}

test "expand grows the box to include a point" {
    var box = Aabbf.fromMinMax(Vec3.zero, Vec3.one);
    box = box.expand(Vec3.fromArray(.{ -1, 2, 0.5 }));
    try testing.expect(box.min.approxEql(Vec3.fromArray(.{ -1, 0, 0 }), 1e-6));
    try testing.expect(box.max.approxEql(Vec3.fromArray(.{ 1, 2, 1 }), 1e-6));
}

test "inflate grows every axis and is exact at zero" {
    // 2×3×4 box with its min at the origin, grown by (1, 2, 3): each axis loses `e`
    // at the min and gains `e` at the max, so min = (−1, −2, −3) and
    // max = (2+1, 3+2, 4+3) = (3, 5, 7).
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.fromArray(.{ 2, 3, 4 }));
    const grown = box.inflate(Vec3.fromArray(.{ 1, 2, 3 }));
    try testing.expect(grown.min.approxEql(Vec3.fromArray(.{ -1, -2, -3 }), 0));
    try testing.expect(grown.max.approxEql(Vec3.fromArray(.{ 3, 5, 7 }), 0));

    // A zero extent COMPARES equal on all six bounds. Compared, not bit-compared:
    // `max + 0` maps a `−0.0` bound to `+0.0` and the two compare equal, which is
    // precisely what lets `broadphase.queryRay` be `queryCast` at a zero extent
    // without changing behaviour.
    const same = box.inflate(Vec3.zero);
    inline for (0..3) |i| {
        try testing.expectEqual(box.min.toArray()[i], same.min.toArray()[i]);
        try testing.expectEqual(box.max.toArray()[i], same.max.toArray()[i]);
    }

    // And the `−0.0` case itself, stated rather than assumed: the max bound changes
    // its sign of zero, the min bound keeps it, and both still compare equal.
    const signed = Aabbf.fromMinMax(Vec3.fromArray(.{ -0.0, 0, 0 }), Vec3.fromArray(.{ -0.0, 1, 1 }));
    const signed_same = signed.inflate(Vec3.zero);
    try testing.expectEqual(@as(f32, -0.0), signed_same.min.toArray()[0]);
    try testing.expect(std.math.signbit(signed_same.min.toArray()[0]));
    try testing.expectEqual(@as(f32, -0.0), signed_same.max.toArray()[0]); // compares equal…
    try testing.expect(!std.math.signbit(signed_same.max.toArray()[0])); // …but is now +0.0
}

test "inflate is the Minkowski sum: overlap equals containment of the centre" {
    // The decisive property of §1.11.10, pinned in BOTH directions: a box of
    // half-extents `e` centred at `c` overlaps `box` exactly when `c` lies in
    // `box.inflate(e)`. Swept over a lattice of centres straddling every face,
    // edge and corner of the reference box, so both a true and a false verdict
    // occur many times — the counters below prove the sweep is not one-sided.
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.fromArray(.{ 2, 3, 4 }));
    const e = Vec3.fromArray(.{ 0.5, 1, 1.5 });
    const grown = box.inflate(e);

    var overlaps: u32 = 0;
    var disjoint: u32 = 0;
    var c: [3]f32 = undefined;
    for (0..13) |ix| {
        c[0] = @as(f32, @floatFromInt(ix)) * 0.5 - 1.5;
        for (0..13) |iy| {
            c[1] = @as(f32, @floatFromInt(iy)) * 0.5 - 1.5;
            for (0..13) |iz| {
                c[2] = @as(f32, @floatFromInt(iz)) * 0.5 - 1.5;
                const centre = Vec3.fromArray(c);
                const moving = Aabbf.fromCenterHalfExtents(centre, e);
                const by_overlap = box.overlaps(moving);
                const by_containment = grown.contains(centre);
                try testing.expectEqual(by_overlap, by_containment);
                if (by_overlap) overlaps += 1 else disjoint += 1;
            }
        }
    }
    // Both verdicts really occurred: an all-true or all-false sweep would satisfy
    // the equality above while proving nothing.
    try testing.expect(overlaps > 0);
    try testing.expect(disjoint > 0);
}

test "generic Aabb f64 instantiation compiles" {
    const A = Aabb(f64);
    const V = vec.Vec(3, f64);
    const box = A.fromCenterHalfExtents(V.zero, V.splat(2));
    try testing.expect(box.contains(V.fromArray(.{ 1, -1, 2 })));
    try testing.expect(!box.contains(V.fromArray(.{ 3, 0, 0 })));
}

/// Ray parameters as `rayInterval` wants them: the reciprocal direction and the
/// exactly-zero mask, derived from a direction the way a caller does.
fn rayParams(comptime T: type, direction: vec.Vec(3, T)) struct { inv: vec.Vec(3, T), zero: @Vector(3, bool) } {
    const one_v: @Vector(3, T) = @splat(1);
    return .{
        .inv = .{ .data = one_v / direction.data },
        .zero = direction.data == @as(@Vector(3, T), @splat(0)),
    };
}

test "rayInterval: entry and exit on a centred box" {
    // Box [-1,1]×[-2,2]×[-3,3], ray from (-4,-4,-4) along (1,1,1):
    //   x slab [3, 5], y slab [2, 6], z slab [1, 7]
    //   → enter = max(3,2,1) = 3, exit = min(5,6,7) = 5.
    const box = Aabbf.fromMinMax(Vec3.fromArray(.{ -1, -2, -3 }), Vec3.fromArray(.{ 1, 2, 3 }));
    const origin = Vec3.splat(-4);
    const p = rayParams(f32, Vec3.one);

    const hit = box.rayInterval(origin, p.inv, p.zero) orelse return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 3), hit.enter);
    try testing.expectEqual(@as(f32, 5), hit.exit);

    // A ray pointing away from the box spans a negative interval, which is
    // still a valid (non-empty) interval — clamping to `[0, max_distance]` is
    // the caller's job, not this one's.
    const away = rayParams(f32, Vec3.one.neg());
    const behind = box.rayInterval(origin, away.inv, away.zero) orelse return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, -5), behind.enter);
    try testing.expectEqual(@as(f32, -3), behind.exit);

    // A ray that misses: parallel offsets aside, this one passes beside the box.
    const miss_origin = Vec3.fromArray(.{ -4, 10, -4 });
    try testing.expect(box.rayInterval(miss_origin, p.inv, p.zero) == null);
}

test "rayInterval: origin inside yields a negative entry" {
    // Unit box centred on the origin, ray from the centre along (1,2,3):
    //   x slab [-1, 1], y slab [-0.5, 0.5], z slab [-1/3, 1/3].
    const box = Aabbf.fromMinMax(Vec3.splat(-1), Vec3.one);
    const p = rayParams(f32, Vec3.fromArray(.{ 1, 2, 3 }));

    const hit = box.rayInterval(Vec3.zero, p.inv, p.zero) orelse return error.TestExpectedHit;
    try testing.expect(hit.enter < 0);
    try testing.expect(hit.exit > 0);
    try testing.expectApproxEqAbs(@as(f32, -1.0 / 3.0), hit.enter, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), hit.exit, 1e-6);
}

test "rayInterval: a zero direction component falls back to containment" {
    // Unit box [0,1]³, ray along +X only: the Y and Z axes are exactly parallel
    // to their slabs and leave the product, replaced by containment of the
    // origin in those slabs. No epsilon is involved on either side.
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.one);
    const p = rayParams(f32, Vec3.unit_x);
    try testing.expect(p.zero[1] and p.zero[2] and !p.zero[0]);

    // Origin inside both parallel slabs → hit, x slab [1, 2].
    const inside = box.rayInterval(Vec3.fromArray(.{ -1, 0.5, 0.5 }), p.inv, p.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 1), inside.enter);
    try testing.expectEqual(@as(f32, 2), inside.exit);

    // Origin outside one parallel slab → miss, whatever the other axes say.
    try testing.expect(box.rayInterval(Vec3.fromArray(.{ -1, 1.5, 0.5 }), p.inv, p.zero) == null);
    try testing.expect(box.rayInterval(Vec3.fromArray(.{ -1, 0.5, -0.001 }), p.inv, p.zero) == null);

    // Origin exactly ON a face plane of a parallel slab → hit (containment is
    // face-inclusive). This is the case the true-zero branch exists for: on the
    // reciprocal path the numerator is exactly zero and `inv` is infinite, so
    // the product would be NaN.
    const on_min = box.rayInterval(Vec3.fromArray(.{ -1, 0, 0.5 }), p.inv, p.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 1), on_min.enter);
    try testing.expectEqual(@as(f32, 2), on_min.exit);

    const on_max = box.rayInterval(Vec3.fromArray(.{ -1, 1, 0.5 }), p.inv, p.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 1), on_max.enter);
    try testing.expectEqual(@as(f32, 2), on_max.exit);
}

test "rayInterval: face-grazing is inclusive" {
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.one);

    // A ray exactly along the +Y = 1 face plane, travelling +X: it grazes the
    // face for the whole crossing. Inclusive convention → hit.
    const along_face = rayParams(f32, Vec3.unit_x);
    const grazed = box.rayInterval(Vec3.fromArray(.{ -1, 1, 0.5 }), along_face.inv, along_face.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 1), grazed.enter);
    try testing.expectEqual(@as(f32, 2), grazed.exit);

    // A ray through the (1,1,·) edge touches the box on a single parameter:
    //   x slab [0, 1] from origin (0,2,0.5) along (1,-1,0), y slab [1, 2]
    //   → enter == exit == 1, a degenerate interval that still counts.
    const corner = rayParams(f32, Vec3.fromArray(.{ 1, -1, 0 }));
    const touch = box.rayInterval(Vec3.fromArray(.{ 0, 2, 0.5 }), corner.inv, corner.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 1), touch.enter);
    try testing.expectEqual(touch.enter, touch.exit);
}

test "rayInterval: a subnormal direction component on a face plane still hits" {
    // `dir_is_zero` covers the EXACTLY zero component. A component small enough
    // that its reciprocal overflows to infinity — but non-zero, so not masked —
    // reaches the reciprocal path, and an origin sitting exactly on that axis'
    // face plane makes the numerator exactly zero: `0 · inf = NaN`. The exact
    // quotient of an exactly-zero numerator is zero, and the box IS hit; a NaN
    // dropped by `@min`/`@max` would turn this into a silent miss.
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.one);
    const tiny = std.math.floatTrueMin(f32);
    const p = rayParams(f32, Vec3.fromArray(.{ 1, tiny, 0 }));
    try testing.expect(!p.zero[1]); // non-zero: the mask does not cover it
    try testing.expect(std.math.isInf(p.inv.data[1])); // yet the reciprocal is infinite

    const hit = box.rayInterval(Vec3.fromArray(.{ -1, 0, 0.5 }), p.inv, p.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f32, 1), hit.enter);
    try testing.expectEqual(@as(f32, 2), hit.exit);
}

test "rayInterval: f64 instantiation matches the f32 closed form" {
    const A = Aabb(f64);
    const V = vec.Vec(3, f64);
    const box = A.fromMinMax(V.fromArray(.{ -1, -2, -3 }), V.fromArray(.{ 1, 2, 3 }));
    const p = rayParams(f64, V.one);

    const hit = box.rayInterval(V.splat(-4), p.inv, p.zero) orelse return error.TestExpectedHit;
    try testing.expectEqual(@as(f64, 3), hit.enter);
    try testing.expectEqual(@as(f64, 5), hit.exit);

    // The zero-direction fallback and its face-inclusive edge, at f64.
    const unit = A.fromMinMax(V.zero, V.one);
    const axis = rayParams(f64, V.unit_x);
    const on_face = unit.rayInterval(V.fromArray(.{ -1, 0, 0.5 }), axis.inv, axis.zero) orelse
        return error.TestExpectedHit;
    try testing.expectEqual(@as(f64, 1), on_face.enter);
    try testing.expectEqual(@as(f64, 2), on_face.exit);
    try testing.expect(unit.rayInterval(V.fromArray(.{ -1, 1.5, 0.5 }), axis.inv, axis.zero) == null);
}

test "surfaceArea" {
    // 2 × 3 × 4 box → 2·(2·3 + 3·4 + 4·2) = 2·(6 + 12 + 8) = 52.
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.fromArray(.{ 2, 3, 4 }));
    try testing.expectApproxEqAbs(@as(f32, 52), box.surfaceArea(), 1e-4);
    // Offset from the origin must not change the extents.
    const shifted = Aabbf.fromMinMax(Vec3.fromArray(.{ 5, 5, 5 }), Vec3.fromArray(.{ 7, 8, 9 }));
    try testing.expectApproxEqAbs(@as(f32, 52), shifted.surfaceArea(), 1e-4);
    // Degenerate (zero-extent) box → 0.
    const point = Aabbf.fromMinMax(Vec3.one, Vec3.one);
    try testing.expectEqual(@as(f32, 0), point.surfaceArea());
    // A flat (zero-thickness) box has two faces of area dx·dz: 2·(2·0 + 0·4 + 4·2) = 16.
    const flat = Aabbf.fromMinMax(Vec3.zero, Vec3.fromArray(.{ 2, 0, 4 }));
    try testing.expectApproxEqAbs(@as(f32, 16), flat.surfaceArea(), 1e-4);
}
