//! `foundation/math/vec.zig` — generic `Vec(N, T)` backed by `@Vector(N, T)`.
//!
//! One value at a time, method-chained (`a.add(b).scale(s)`); the batched
//! SIMD kernels live in `foundation/simd/` and this submodule never imports
//! them (sister-module rule, `engine-directory-structure.md` §620). The f32
//! aliases `Vec2`/`Vec3`/`Vec4` are the common surface; other scalars come
//! from instantiating the generic (`Vec(3, f64)`). Right-handed, Y-up,
//! −Z-forward (`engine-coordinate-system.md`): `cross(unit_x, unit_y) ==
//! unit_z`, and rotating (1,0,0) by +90° about +Y yields (0,0,−1).

const std = @import("std");

/// Column vector of `N` components of scalar type `T`, backed by a
/// `@Vector(N, T)` so the elementwise operations lower to SIMD. `N` is 2..4.
pub fn Vec(comptime N: usize, comptime T: type) type {
    comptime {
        if (N < 2 or N > 4) @compileError("Vec supports N in 2..4");
    }
    return struct {
        const Self = @This();
        const Simd = @Vector(N, T);

        /// Packed SIMD storage; lanes 0..N are x, y, z, w in order.
        data: Simd,

        /// Vector with every component set to `s`.
        pub fn splat(s: T) Self {
            return .{ .data = @as(Simd, @splat(s)) };
        }

        /// The zero vector.
        pub const zero: Self = .{ .data = @as(Simd, @splat(0)) };

        /// The all-ones vector.
        pub const one: Self = .{ .data = @as(Simd, @splat(1)) };

        /// Unit vector along +X (lane 0).
        pub const unit_x: Self = unitAxis(0);
        /// Unit vector along +Y (lane 1).
        pub const unit_y: Self = unitAxis(1);
        /// Unit vector along +Z (lane 2). Requires `N >= 3`.
        pub const unit_z: Self = unitAxis(2);

        /// Basis vector with a 1 in lane `i` (comptime-checked in range).
        fn unitAxis(comptime i: usize) Self {
            comptime {
                if (i >= N) @compileError("unit axis index exceeds Vec dimension");
            }
            var a = [_]T{0} ** N;
            a[i] = 1;
            return .{ .data = a };
        }

        /// Componentwise sum `self + other`.
        pub fn add(self: Self, other: Self) Self {
            return .{ .data = self.data + other.data };
        }
        /// Componentwise difference `self - other`.
        pub fn sub(self: Self, other: Self) Self {
            return .{ .data = self.data - other.data };
        }
        /// Negation `-self`.
        pub fn neg(self: Self) Self {
            return .{ .data = -self.data };
        }
        /// Scalar multiple `self * s`.
        pub fn scale(self: Self, s: T) Self {
            return .{ .data = self.data * @as(Simd, @splat(s)) };
        }
        /// Componentwise (Hadamard) product `self ∘ other`.
        pub fn mul(self: Self, other: Self) Self {
            return .{ .data = self.data * other.data };
        }
        /// Dot product `self · other`.
        pub fn dot(self: Self, other: Self) T {
            return @reduce(.Add, self.data * other.data);
        }
        /// Cross product `self × other` (right-handed, `N == 3` only).
        pub fn cross(self: Self, other: Self) Self {
            comptime {
                if (N != 3) @compileError("cross requires N == 3");
            }
            const a = self.data;
            const b = other.data;
            return .{ .data = .{
                a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0],
            } };
        }
        /// Squared length `self · self` (no square root).
        pub fn lengthSq(self: Self) T {
            return @reduce(.Add, self.data * self.data);
        }
        /// Euclidean length `sqrt(self · self)`.
        pub fn length(self: Self) T {
            return @sqrt(self.lengthSq());
        }
        /// Unit vector along `self` (undefined for the zero vector).
        pub fn normalize(self: Self) Self {
            return self.scale(1.0 / self.length());
        }

        /// Unit vector in the same direction, or `null` when `self` is EXACTLY zero.
        ///
        /// **The overflow-safe form, and `normalize` above is not it.** The vector is reduced
        /// by its LARGEST ABSOLUTE COMPONENT before anything is squared, which is what keeps
        /// both ends of the float range usable: `(1e20, 0, 0)` is perfectly finite yet its
        /// squared length overflows to infinity at `f32`, so `normalize` divides by infinity and
        /// answers the ZERO VECTOR; and a vector so small that its square underflows would read
        /// as zero although it normalises exactly. After the reduction every component is in
        /// `[0, 1]`, so the squared length lies in `[1, N]` and can do neither.
        ///
        /// The reduction is a component-wise DIVISION, deliberately not a multiplication by
        /// `1 / scale`: for a denormal input that reciprocal overflows to infinity and the
        /// defect reappears at the other end of the range. The `== 0` test is at TRUE ZERO —
        /// the largest absolute component is zero exactly when every component is.
        ///
        /// **Why it lives here.** Three consumers need it and each arrived at it separately:
        /// the query family's direction normalisation, which introduced the form at M1.1.9 for
        /// exactly this overflow; a mesh triangle's face normal, which is a cross product of
        /// vertex differences and reaches `1e20` from vertices at `1e10`; and the ray↔triangle
        /// kernel, which normalises the same cross product. Same placement rule as
        /// `surfaceArea`, `rayInterval`, `inflate` and `overlapsHalfSpace` — pure vector
        /// arithmetic, no threshold, no physical semantics.
        pub fn normalizeScaled(self: Self) ?Self {
            const largest = @reduce(.Max, @abs(self.data));
            if (largest == 0) return null;
            const reduced: Self = .{ .data = self.data / @as(Simd, @splat(largest)) };
            return reduced.scale(1 / reduced.length());
        }

        /// Largest absolute component. Zero exactly when every component is zero.
        pub fn maxAbsComponent(self: Self) T {
            return @reduce(.Max, @abs(self.data));
        }

        /// Multiply every component by `2^exp`, EXACTLY.
        ///
        /// Power-of-two scaling rewrites only the exponent field and never a mantissa, so the
        /// result is exact wherever it is representable. Three consequences the callers depend
        /// on, and the reason an arbitrary scale factor will not do: points that are exactly
        /// collinear stay exactly collinear, so a guard sitting at TRUE ZERO keeps its verdict;
        /// a quantity derived from scaled inputs is the exact `2^k` multiple of the same
        /// quantity derived from the originals; and because `normalizeScaled` divides by a
        /// component of its own input, that common factor cancels and the unit vector it
        /// answers is BIT-IDENTICAL whatever `exp` a caller chose.
        ///
        /// The factor is applied in TWO halves rather than materialised once, because the
        /// exponent a caller legitimately needs can fall outside the representable range while
        /// the result does not: reducing `f32` `3.4e38` below 1 asks for `2^-128`, and lifting
        /// the denormal `1e-45` asks for `2^148`, which overflows to infinity and would answer
        /// `inf` for the whole vector. Halving keeps each factor a normal number, and since
        /// both halves carry the sign of `exp`, every intermediate lies between the input
        /// magnitude and the target and is therefore in range too.
        pub fn scalePow2(self: Self, exp: i32) Self {
            const half = @divTrunc(exp, 2);
            const rest = exp - half;
            const f_half = std.math.ldexp(@as(T, 1), half);
            const f_rest = std.math.ldexp(@as(T, 1), rest);
            std.debug.assert(std.math.isFinite(f_half) and f_half != 0);
            std.debug.assert(std.math.isFinite(f_rest) and f_rest != 0);
            const once: Simd = self.data * @as(Simd, @splat(f_half));
            return .{ .data = once * @as(Simd, @splat(f_rest)) };
        }
        /// Linear interpolation `self + (other - self) * t`.
        pub fn lerp(self: Self, other: Self, t: T) Self {
            return .{ .data = self.data + (other.data - self.data) * @as(Simd, @splat(t)) };
        }
        /// Componentwise minimum.
        pub fn min(self: Self, other: Self) Self {
            return .{ .data = @min(self.data, other.data) };
        }
        /// Componentwise maximum.
        pub fn max(self: Self, other: Self) Self {
            return .{ .data = @max(self.data, other.data) };
        }
        /// Componentwise absolute value.
        pub fn abs(self: Self) Self {
            return .{ .data = @abs(self.data) };
        }
        /// Exact componentwise equality.
        pub fn eql(self: Self, other: Self) bool {
            return @reduce(.And, self.data == other.data);
        }
        /// Componentwise equality within `tolerance` (inclusive).
        pub fn approxEql(self: Self, other: Self, tolerance: T) bool {
            const diff = @abs(self.data - other.data);
            return @reduce(.And, diff <= @as(Simd, @splat(tolerance)));
        }
        /// Build a vector from a fixed array of `N` components.
        pub fn fromArray(arr: [N]T) Self {
            return .{ .data = arr };
        }
        /// Copy the components out into a fixed array of `N` elements.
        pub fn toArray(self: Self) [N]T {
            return self.data;
        }
    };
}

/// f32 2-vector.
pub const Vec2 = Vec(2, f32);
/// f32 3-vector — the common spatial type; 16 bytes / 16-aligned so arrays of
/// it share the `core.ecs.components.Transform.pos` bulk-copy stride.
pub const Vec3 = Vec(3, f32);
/// f32 4-vector.
pub const Vec4 = Vec(4, f32);

comptime {
    // The padded @Vector(3, f32) layout (12 bytes of data rounded to a 16-byte
    // lane) is what makes a `[]Vec3` bulk-sync-compatible with the ECS
    // `Transform.pos` column (M1.1.15). If a target ever breaks this, the
    // assert fires loudly — do NOT remove it (brief Notes decision 8).
    std.debug.assert(@sizeOf(Vec3) == 16);
    std.debug.assert(@alignOf(Vec3) == 16);
}

/// The power-of-two exponent that brings every component of all three points strictly below
/// 1 in absolute value, i.e. the `exp` to hand `Vec.scalePow2`. `null` when all nine
/// components are exactly zero, there being no magnitude to reduce.
///
/// `frexp` writes the largest magnitude as `m · 2^e` with `m` in `[0.5, 1)`, so scaling by
/// `2^-e` maps it to `m` and every smaller component below that. All three points must be
/// FINITE: `frexp` leaves its exponent undefined for an infinity or a NaN, which is asserted
/// rather than handled, every caller here validating its geometry upstream.
///
/// **This is a COMMON factor and `triangleCross` deliberately no longer uses it** — the two want
/// different things and the difference is not stylistic. A Möller–Trumbore chain compares `u` and
/// `v` against `det`, all three homogeneous of degree 2 in ONE scale, so the comparisons are only
/// meaningful if every quantity was reduced by the same factor; that is what this function is for.
/// A cross product needs only a direction and a non-zero verdict, so it can afford two independent
/// factors — and it MUST, since a single factor over points spanning more than the exponent range
/// annihilates the smallest of them (closure finding F6).
pub fn pow2ReductionExponent(
    comptime T: type,
    v0: Vec(3, T),
    v1: Vec(3, T),
    v2: Vec(3, T),
) ?i32 {
    const largest = @max(v0.maxAbsComponent(), @max(v1.maxAbsComponent(), v2.maxAbsComponent()));
    std.debug.assert(!std.math.isNan(largest) and !std.math.isInf(largest));
    if (largest == 0) return null;
    return -std.math.frexp(largest).exponent;
}

/// `to − from`, computed UNSCALED unless that subtraction leaves the float range.
///
/// The unscaled difference is the arithmetically exact answer whenever it is representable —
/// correctly rounded, and exact by Sterbenz whenever the two operands are within a factor of two —
/// so scaling it is a repair and not an improvement. The one way it fails is OVERFLOW: two finite
/// `f32` vertices at `±3e38` differ by `6e38`, which is an infinity, and no scaling afterwards
/// recovers it. `isFinite` on the result is the complete trigger, because the difference has no
/// underflow failure to speak of — it is zero only when the two operands are equal, exactly.
///
/// The repair reduces the PAIR by one exact power of two before subtracting. That direction is
/// forced: an overflowing difference means both operands sit near the top of the range, so there is
/// nothing to scale up.
fn edgeUnlessOverflow(comptime T: type, from: Vec(3, T), to: Vec(3, T)) Vec(3, T) {
    const raw = to.sub(from);
    if (std.math.isFinite(raw.maxAbsComponent())) return raw;

    const largest = @max(from.maxAbsComponent(), to.maxAbsComponent());
    std.debug.assert(std.math.isFinite(largest) and largest != 0);
    const exp = -std.math.frexp(largest).exponent;
    return to.scalePow2(exp).sub(from.scalePow2(exp));
}

/// Each vector brought into `[0.5, 1)` by its OWN exact power of two, or left alone when it is
/// exactly zero. Used only on the cross's repair path.
fn toUnitBinade(comptime T: type, v: Vec(3, T)) Vec(3, T) {
    const largest = v.maxAbsComponent();
    if (largest == 0 or !std.math.isFinite(largest)) return v;
    return v.scalePow2(-std.math.frexp(largest).exponent);
}

/// Un-normalised area vector of the triangle `(v0, v1, v2)` — the cross product
/// `(v₁−v₀) × (v₂−v₀)` in that FIXED order, which is what ties it to a winding convention.
///
/// **The magnitude is NOT a reliable multiple of twice the area.** The direction and the
/// exactly-zero verdict are the whole contract; a caller wanting an area must compute it itself.
/// On the common path the result IS twice the area vector exactly; on the repair path it is that
/// vector times some power of two, which changes neither the direction nor the verdict.
///
/// **The default path is UNSCALED, and that is the design rather than an omission.** Three rounds
/// on this function established that no arrangement of power-of-two factors closes the problem, and
/// for one reason: where a reduction is forced against overflow it must scale DOWN, and scaling
/// down is exactly what loses a component only expressible at the input magnitude. So the unscaled
/// form — the arithmetically most exact one available — runs first, and scaling becomes a repair
/// applied only where it actually fails, in whichever direction loses nothing.
///
/// Two failures are repaired, and each is detected STRUCTURALLY, with no threshold anywhere:
///
///   - **Overflow**, and it is NOT detectable on the largest component, which is the trap here and
///     was found by measurement rather than reasoning. `f32` vertices at `1e20` cross to `1e40`,
///     an infinity, and `normalizeScaled` then divides it by its own infinite largest component
///     and answers NaN — strictly worse than a zero vector, since a NaN propagates. But a single
///     LANE can also come out NaN from `inf − inf` while the other two stay finite and non-zero,
///     `(2.81e14, NaN, −2.81e14)` being a measured example, and `@reduce(.Max, @abs(…))` lowers to
///     a NaN-IGNORING maximum, so a guard written on the largest component sees a healthy `2.81e14`
///     and lets the NaN through. The test is therefore lane-wise: `x == x` over all three, plus
///     `isFinite` on the largest for the plain infinity. The edges are then brought into the unit
///     binade and the cross recomputed; that direction is DOWN and is the one place where a
///     component can be lost, which is the residual documented below.
///   - **Underflow to exactly zero**, caught by the zero test that the caller was going to apply
///     anyway. Two edges around `2⁻¹⁰⁰` have products around `2⁻²⁰⁰`, which is zero at `f32`, so a
///     perfectly ordinary small triangle reads as degenerate. Here the repair scales UP and loses
///     nothing at all.
///
/// Both repairs are the same operation and share one path. A zero that survives it is a zero the
/// format can defend.
///
/// **The power of two is load-bearing twice over.** It rewrites only the exponent field, so
/// exactly-collinear points stay exactly collinear and a guard sitting at TRUE ZERO keeps its
/// verdict, where an arbitrary divisor would round each division and could move it; and because
/// `normalizeScaled` divides by a component of its own input, any common factor CANCELS, so the
/// unit normal is bit-identical whatever exponents were chosen. `Vec.scalePow2` explains why the
/// factor is applied in two halves.
///
/// **What is guaranteed, and what is not.** GUARANTEED: no false ACCEPT, ever — an exactly
/// degenerate triangle is always reported degenerate, at both precisions, which is the
/// safety-critical direction since accepting one would fire `MeshData.faceNormal`'s
/// `orelse unreachable`. NOT guaranteed: agreement with exact arithmetic on a triangle whose
/// component exponents span more than the format's range. The intermediate then needs an exponent
/// range the format does not hold, and no power of two supplies one. The measured false-degenerate
/// rate under ADVERSARIAL sampling is reported in `briefs/M1.1.11.1-mesh-shape.md` beside the
/// caveat that must travel with it: that sampling is uniform over the whole exponent range and so
/// is dominated by triangles whose exponent spread is absurd, whereas a real mesh lives inside a
/// few orders of magnitude. It is a stress metric, never a field expectation.
pub fn triangleCross(
    comptime T: type,
    v0: Vec(3, T),
    v1: Vec(3, T),
    v2: Vec(3, T),
) Vec(3, T) {
    // The common path scales NOTHING and tests ONCE. An overflowing edge subtraction cannot hide
    // from this test either: an infinite edge makes the cross infinite or NaN, so the single check
    // below covers the edge step as well and the hot path pays for one reduction pair rather than
    // four. `x == x` is false exactly for a NaN, and that test is over LANES rather than over the
    // largest magnitude for the reason given above.
    const raw = v1.sub(v0).cross(v2.sub(v0));
    const nan_free = @reduce(.And, raw.data == raw.data);
    const largest = raw.maxAbsComponent();
    if (nan_free and largest != 0 and std.math.isFinite(largest)) return raw;

    // The repair, entered only on a structural failure. The differences are redone with a per-pair
    // reduction, since the subtraction may be the step that left range, and each edge is then
    // brought into the unit binade so the products cannot leave it again.
    const e0 = toUnitBinade(T, edgeUnlessOverflow(T, v0, v1));
    const e1 = toUnitBinade(T, edgeUnlessOverflow(T, v0, v2));
    return e0.cross(e1);
}

/// Reinterpret a slice of `Vec3` as a flat `[]const f32` for the batched SIMD
/// kernels (`foundation/simd/`, `engine-directory-structure.md` §620). The
/// view spans the padded lanes — `items.len * 4` floats, where every 4th float
/// is the padding lane. Zero-copy: it aliases `items`.
pub fn asFloatSlice(items: []const Vec3) []const f32 {
    const lanes = @sizeOf(Vec3) / @sizeOf(f32); // 4 (3 data + 1 pad)
    const ptr: [*]const f32 = @ptrCast(items.ptr);
    return ptr[0 .. items.len * lanes];
}

const testing = std.testing;

test "dot and cross identities" {
    const a = Vec3.fromArray(.{ 1, 2, 3 });
    const b = Vec3.fromArray(.{ 4, -5, 6 });
    try testing.expectApproxEqAbs(@as(f32, 12), a.dot(b), 1e-6); // 4 - 10 + 18
    // Right-handed handedness pin.
    try testing.expect(Vec3.unit_x.cross(Vec3.unit_y).approxEql(Vec3.unit_z, 1e-6));
    // Anticommutativity and orthogonality.
    try testing.expect(a.cross(b).approxEql(b.cross(a).neg(), 1e-5));
    try testing.expectApproxEqAbs(@as(f32, 0), a.cross(b).dot(a), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), a.cross(b).dot(b), 1e-4);
}

test "normalize length and lerp endpoints" {
    const v = Vec3.fromArray(.{ 3, 4, 0 });
    try testing.expectApproxEqAbs(@as(f32, 25), v.lengthSq(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5), v.length(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), v.normalize().length(), 1e-6);

    const a = Vec3.zero;
    const b = Vec3.one;
    try testing.expect(a.lerp(b, 0).approxEql(a, 1e-6));
    try testing.expect(a.lerp(b, 1).approxEql(b, 1e-6));
    try testing.expect(a.lerp(b, 0.5).approxEql(Vec3.splat(0.5), 1e-6));
}

test "approxEql tolerance behavior" {
    const a = Vec3.fromArray(.{ 1, 1, 1 });
    const b = Vec3.fromArray(.{ 1.0005, 1, 1 });
    try testing.expect(a.approxEql(b, 1e-3));
    try testing.expect(!a.approxEql(b, 1e-5));
    try testing.expect(a.eql(a));
    try testing.expect(!a.eql(b));
}

test "min max abs and scale" {
    const a = Vec3.fromArray(.{ -1, 5, 2 });
    const b = Vec3.fromArray(.{ 3, -4, 2 });
    try testing.expect(a.min(b).approxEql(Vec3.fromArray(.{ -1, -4, 2 }), 1e-6));
    try testing.expect(a.max(b).approxEql(Vec3.fromArray(.{ 3, 5, 2 }), 1e-6));
    try testing.expect(a.abs().approxEql(Vec3.fromArray(.{ 1, 5, 2 }), 1e-6));
    try testing.expect(a.scale(2).approxEql(Vec3.fromArray(.{ -2, 10, 4 }), 1e-6));
    try testing.expect(a.add(b).approxEql(Vec3.fromArray(.{ 2, 1, 4 }), 1e-6));
    try testing.expect(a.sub(b).approxEql(Vec3.fromArray(.{ -4, 9, 0 }), 1e-6));
}

test "Vec3 layout pins" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Vec3));
    try testing.expectEqual(@as(usize, 16), @alignOf(Vec3));
}

test "fromArray toArray round-trip" {
    const arr = [3]f32{ 1.5, -2.5, 3.5 };
    const v = Vec3.fromArray(arr);
    try testing.expectEqual(arr, v.toArray());
}

test "asFloatSlice reinterprets padded lanes" {
    const items = [_]Vec3{
        Vec3.fromArray(.{ 1, 2, 3 }),
        Vec3.fromArray(.{ 4, 5, 6 }),
    };
    const floats = asFloatSlice(&items);
    try testing.expectEqual(@as(usize, 8), floats.len); // 2 * 4 padded lanes
    try testing.expectEqual(@as(f32, 1), floats[0]);
    try testing.expectEqual(@as(f32, 3), floats[2]);
    try testing.expectEqual(@as(f32, 4), floats[4]);
    try testing.expectEqual(@as(f32, 6), floats[6]);
}

test "generic Vec f64 instantiation compiles" {
    const V = Vec(3, f64);
    const a = V.fromArray(.{ 1, 2, 2 });
    try testing.expectApproxEqAbs(@as(f64, 3), a.length(), 1e-12);
    try testing.expect(V.unit_x.cross(V.unit_y).approxEql(V.unit_z, 1e-12));
}
