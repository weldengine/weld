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
