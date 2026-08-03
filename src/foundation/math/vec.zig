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
const exact = @import("exact.zig");

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

/// One lane of a cross product, `a·d − b·c`, as a value TOGETHER WITH its own power-of-two exponent.
///
/// **A cross is three INDEPENDENT 2×2 determinants, and a lane that leaves the range has no business
/// dragging the other two down with it.** That was the defect in every earlier form: the repair was
/// global where the failure is local. Measured, a triangle whose `z` lane overflows while `x` and
/// `y` compute exactly had its `x` and `y` destroyed by a global reduction that pushed them below
/// the subnormal floor; repairing per lane took the adversarial false-degenerate rate from 15.7 % to
/// 4.8 % at `f32` and from 21.3 % to 5.9 % at `f64`.
///
/// A repaired lane cannot always come back to the input scale — its true value may not be
/// representable at all — so the exponent travels with the value and the caller reconciles the three
/// lanes onto one common scale, which is what keeps the DIRECTION right.
const Lane = struct { v: f64, e: i32 };

fn laneUnlessOverflow(comptime T: type, a: T, b: T, c: T, d: T) Lane {
    const raw = a * d - b * c;
    if (raw == raw and std.math.isFinite(raw)) return .{ .v = @floatCast(raw), .e = 0 };

    const largest = @max(@max(@abs(a), @abs(b)), @max(@abs(c), @abs(d)));
    if (largest == 0 or !std.math.isFinite(largest)) return .{ .v = 0, .e = 0 };
    const k = -std.math.frexp(largest).exponent;
    const scaled = std.math.ldexp(a, k) * std.math.ldexp(d, k) -
        std.math.ldexp(b, k) * std.math.ldexp(c, k);
    if (!(scaled == scaled) or !std.math.isFinite(scaled)) return .{ .v = 0, .e = 0 };
    // Every operand was scaled by `2^k`, so the products — and the lane — carry `2^(2k)`.
    return .{ .v = @floatCast(scaled), .e = -2 * k };
}

/// What `triangleCross` can conclude.
///
/// **THE TWO OUTCOMES ARE NOT SYMMETRIC, and that asymmetry is the whole contract.** `.degenerate`
/// is reached ONLY after the exact integer tier has answered zero, so it IS a reliable verdict of
/// flatness. `.direction` proves nothing of the kind: it is returned by the first FLOAT tier that
/// forms a finite non-zero vector, and on three exactly proportional points that vector can be a
/// rounding RESIDUE — a good-looking direction for a triangle whose true area is zero.
///
/// **So `triangleCross` IS NOT A CLASSIFIER.**
/// The contract is deliberately narrow, and the narrowing is a correction: the function returns a
/// direction from the first float tier that produces a finite non-zero one, and on three exactly
/// proportional points that can be a rounding RESIDUE — a perfectly good-looking direction for a
/// triangle whose true area is zero. So `.degenerate` means only "no float tier could form a
/// direction", never "the area is zero".
///
/// The classifier is `math.triangleIsFlat`, which decides in integer arithmetic with no float step
/// anywhere and cannot be wrong about a zero. Callers that must not admit a flat triangle ask THAT;
/// `triangleCross` is for callers that need a direction on geometry already admitted. Keeping the
/// two apart is what makes the cheap tiers usable at all — routing this function through the exact
/// path would put integer arithmetic on the ray kernel's hot path and collapse the verdict/direction
/// separation that `engine-physics-forge.md` §1.11.17 now makes normative.
pub fn CrossOutcome(comptime T: type) type {
    return union(enum) {
        /// A non-zero vector whose direction is that of the true area vector, up to the float
        /// error of whichever tier produced it. The magnitude carries no meaning.
        direction: Vec(3, T),
        /// No tier could form a direction. On geometry a caller has already had classified by
        /// `math.triangleIsFlat` this means the triangle is flat; on arbitrary input it means only
        /// that, not that the exact area is zero.
        degenerate,
    };
}

/// The direction of `(v₁−v₀) × (v₂−v₀)` in that FIXED order — the order is what ties it to a winding
/// convention — or `.degenerate`.
///
/// **Three tiers, cheapest first, and each exists because the one before it was measured to fail on
/// inputs the format admits.**
///
///  1. The plain unscaled cross, which is the arithmetically most exact form available and the answer
///     for every well-conditioned mesh. One lane-wise test decides whether it stands.
///  2. PER-LANE repair. Each of the three determinants is retried with a power of two drawn from its
///     own four operands, carrying its own exponent, and the three are reconciled onto one common
///     scale. Lanes that were already fine are never touched.
///  3. The EXACT INTEGER fallback, `exact.triangleCrossDirection`. This is what closes the class:
///     five rounds established that no arrangement of power-of-two factors can, because a reduction
///     forced against overflow must scale DOWN and scaling down loses a component expressible only
///     at the input magnitude. Integers have no exponent range to run out of, and a DIRECTION IS
///     SCALE-FREE, so the answer always fits back into `T`. Measured: the adversarial
///     false-degenerate rate goes to **0.0 % at both precisions**, and the per-lane sign and
///     magnitude of all three determinants agree with an independent big-integer oracle over 27 000
///     lanes per precision.
///
/// The test that moves between tiers is `isFinite` and exact zero — STRUCTURAL, never a tolerance,
/// the same signal class the ray kernel reports as `.unrepresentable`. And it cannot be written on
/// the largest component: one lane can come out NaN from `inf − inf` while the other two stay finite
/// and non-zero — `(2.81e14, NaN, −2.81e14)` is measured — and `@reduce(.Max, @abs(…))` lowers to a
/// NaN-IGNORING maximum, so a largest-component guard would let that NaN through.
///
/// Tiers 2 and 3 are COLD by construction. Every vertex component must be finite.
pub fn triangleCross(
    comptime T: type,
    v0: Vec(3, T),
    v1: Vec(3, T),
    v2: Vec(3, T),
) CrossOutcome(T) {
    // TIER 1 — nothing scaled, one test.
    const raw = v1.sub(v0).cross(v2.sub(v0));
    const nan_free = @reduce(.And, raw.data == raw.data);
    const largest = raw.maxAbsComponent();
    if (nan_free and largest != 0 and std.math.isFinite(largest)) return .{ .direction = raw };

    // TIER 2 — per-lane repair. The edges are redone with a per-pair reduction first, since the
    // subtraction itself may be the step that left the range.
    {
        const r0 = edgeUnlessOverflow(T, v0, v1).toArray();
        const r1 = edgeUnlessOverflow(T, v0, v2).toArray();
        // `laneUnlessOverflow(a, b, c, d)` computes `a·d − b·c`, so the four arguments are the
        // determinant's rows in that order and NOT the two cross operands in index order — a
        // transposition here silently computes a different quantity, which is what the collinear
        // pins caught on the first attempt.
        const lanes = [3]Lane{
            laneUnlessOverflow(T, r0[1], r0[2], r1[1], r1[2]), // e0.y·e1.z − e0.z·e1.y
            laneUnlessOverflow(T, r0[2], r0[0], r1[2], r1[0]), // e0.z·e1.x − e0.x·e1.z
            laneUnlessOverflow(T, r0[0], r0[1], r1[0], r1[1]), // e0.x·e1.y − e0.y·e1.x
        };
        var top: i32 = std.math.minInt(i32);
        var any = false;
        for (lanes) |l| {
            if (l.v == 0) continue;
            const mag = std.math.frexp(l.v).exponent + l.e;
            if (!any or mag > top) top = mag;
            any = true;
        }
        if (any) {
            var out = [3]T{ 0, 0, 0 };
            for (lanes, 0..) |l, k| {
                if (l.v == 0) continue;
                out[k] = @floatCast(std.math.ldexp(l.v, l.e - top));
            }
            const repaired = Vec(3, T).fromArray(out);
            if (repaired.maxAbsComponent() != 0) return .{ .direction = repaired };
        }
    }

    // TIER 3 — exact, and the only tier entitled to answer `.degenerate` on its own authority.
    if (exact.triangleCrossDirection(T, v0, v1, v2)) |d| return .{ .direction = d };
    return .degenerate;
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
