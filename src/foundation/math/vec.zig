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

/// The exact power-of-two-reduced difference `to − from`, the reduction taken from the largest
/// absolute component of the PAIR and applied BEFORE the subtraction.
///
/// Reducing before subtracting is what keeps the difference itself in range: two finite `f32`
/// vertices at `±3e38` differ by `6e38`, which is an infinity, and no amount of scaling
/// afterwards recovers it. Reducing brings the largest of the six components into `[0.5, 1)`, so
/// both operands are at most 1 and the difference at most 2.
fn edgeReducedPow2(comptime T: type, from: Vec(3, T), to: Vec(3, T)) Vec(3, T) {
    const largest = @max(from.maxAbsComponent(), to.maxAbsComponent());
    std.debug.assert(!std.math.isNan(largest) and !std.math.isInf(largest));
    if (largest == 0) return Vec(3, T).zero;
    const exp = -std.math.frexp(largest).exponent;
    return to.scalePow2(exp).sub(from.scalePow2(exp));
}

/// Un-normalised area vector of the triangle `(v0, v1, v2)` — the cross product
/// `(v₁−v₀) × (v₂−v₀)` in that FIXED order, which is what ties it to a winding convention —
/// computed so that no step can overflow on any finite input.
///
/// **SCALED, and the magnitude is therefore NOT twice the area.** The direction and the
/// exactly-zero verdict are the whole contract; a caller wanting an area must compute it
/// itself. What is returned is an exact `2^k` multiple of the true area vector, which is
/// enough for both of this function's uses — a normalisation, where the factor cancels
/// bit-exactly, and a degeneracy test at true zero, which a non-zero factor cannot move.
///
/// **Why the reduction comes FIRST, before the subtraction.** Two independent overflows sit on
/// this path and scaling after the subtraction closes only one of them. The cross product of
/// vertex differences grows as their SQUARE, so `f32` vertices at `1e20` — well inside the
/// finite domain — give `1e40`, which is infinity; and an EDGE can overflow on its own, two
/// finite vertices at `±3e38` differing by `6e38`, which is also infinity. Reducing puts every
/// component below 1, hence every difference below 2 and every cross component below 4, after
/// which neither step can leave the range at the top end. `Vec.scalePow2` explains why the
/// factor must be a power of two and not merely a convenient scale.
///
/// **Why the factor is PER EDGE and not one factor over the three vertices.** A single factor
/// cannot serve a triangle whose components span more than the format's exponent range, and the
/// failure is the worst kind — silent, and dressed as a diagnostic. Measured: the perfectly
/// ordinary right triangle `(0,0,0)`, `(2e38,0,0)`, `(0,2⁻⁶⁰,0)` reduces by `2⁻¹²⁸`, which sends
/// the second leg to `2⁻¹⁸⁸`, below the subnormal floor, so that edge becomes exactly zero and
/// the cross with it. `MeshData.init` then answers `error.MeshTriangleDegenerate` — a typed
/// refusal ACCUSING valid caller data. The class is not `f32`-only: at `f64` the same happens for
/// `2^920` against `2^-919`. Two independent factors fix it — the repro's edges become
/// `(0.5877, 0, 0)` and `(0, 0.5, 0)` and their cross `(0, 0, 0.2939)` — and neither property the
/// single factor bought is given up, because BOTH factors are powers of two: exact collinearity
/// is still preserved bit for bit, so a guard at true zero keeps its verdict; and the two factors
/// COMPOSE into one common factor on the cross, which `normalizeScaled` still cancels, so the unit
/// normal stays bit-identical whatever the two exponents were.
///
/// **What this closes and what it does not, MEASURED against an exact oracle rather than argued.**
/// It closes the named case above and every case where the shared vertex is not itself the largest
/// magnitude, and it strictly reduces the false-degenerate rate everywhere measured. It does NOT
/// make a false degenerate impossible, and a tempting argument that it does — each reduced edge
/// having a component in `[0.5, 1)`, so the cross being bounded below by their product times the
/// sine of the angle — is FALSE: a near-coincident pair reduces to two nearly equal vertices whose
/// difference is a single ulp, which is in no such interval. What is true is that a reduction by an
/// exact power of two loses nothing the inputs expressed AT THE REDUCED MAGNITUDE; what it can
/// still lose is a component that was expressible only at the ORIGINAL magnitude, which is what
/// happens when the pair's two vertices differ by more than the exponent range.
///
/// Measured with a big-integer exact oracle over triangles drawn across the whole exponent range,
/// restricted to cases whose exact answer is REPRESENTABLE in `T` — the only cases any
/// implementation working in `T` could be held to. One exponent per vertex, `f32` then `f64`:
/// single factor 23.6 % / 33.0 % false degenerates, per edge 17.1 % / 22.0 %, and a
/// scale-only-when-it-overflows variant 14.9 % / 20.9 %. So the class is NOT closed by any
/// arrangement of power-of-two factors; closing it needs an intermediate whose exponent range
/// exceeds the format's, which is a different decision with a different cost. Two things are
/// nevertheless guaranteed and both are asserted: the failure direction is always a refusal of a
/// valid triangle and never acceptance of a degenerate one — zero false accepts over every
/// measured seed — and the per-edge form is strictly better than the single factor on every seed
/// at both precisions. `tests/mesh_test.zig` carries the property and the figures.
pub fn triangleCross(
    comptime T: type,
    v0: Vec(3, T),
    v1: Vec(3, T),
    v2: Vec(3, T),
) Vec(3, T) {
    return edgeReducedPow2(T, v0, v1).cross(edgeReducedPow2(T, v0, v2));
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
