//! `foundation/math/quat.zig` — generic unit-quaternion `Quat(T)`.
//!
//! Storage order (x, y, z, w), identity (0, 0, 0, 1) — matching
//! `core.ecs.components.Transform.rot`'s `[4]f32` layout. Rotations are
//! right-handed: `fromAxisAngle(+Y, π/2)` sends (1,0,0) to (0,0,−1). Trig is
//! `std.math`-grade (`@sin`/`@cos`); the deterministic trig forge_3d needs is
//! pinned later inside the solver (M1.1.14), not here.

const std = @import("std");
const vec = @import("vec.zig");

/// Quaternion over scalar `T`, stored `(x, y, z, w)`. Assumed unit-length for
/// the rotation operations; `normalize` restores that invariant after
/// accumulation.
pub fn Quat(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = vec.Vec(3, T);

        /// Imaginary i component.
        x: T,
        /// Imaginary j component.
        y: T,
        /// Imaginary k component.
        z: T,
        /// Real (scalar) component.
        w: T,

        /// The identity rotation (0, 0, 0, 1).
        pub const identity: Self = .{ .x = 0, .y = 0, .z = 0, .w = 1 };

        /// Rotation of `angle` radians about `axis` (right-hand rule); `axis`
        /// is normalized internally.
        pub fn fromAxisAngle(axis: Vec3T, angle: T) Self {
            const half = angle * 0.5;
            const s = @sin(half);
            const c = @cos(half);
            const n = axis.normalize();
            return .{ .x = n.data[0] * s, .y = n.data[1] * s, .z = n.data[2] * s, .w = c };
        }

        /// Hamilton product `self * other` — the rotation that applies `other`
        /// first, then `self`.
        pub fn mul(self: Self, other: Self) Self {
            const a = self;
            const b = other;
            return .{
                .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            };
        }

        /// Magnitude `sqrt(x² + y² + z² + w²)` — internal helper consumed by
        /// `normalize` (a public quaternion norm is not part of the E1 surface).
        fn length(self: Self) T {
            return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w);
        }

        /// Unit quaternion along `self`.
        pub fn normalize(self: Self) Self {
            const inv = 1.0 / self.length();
            return .{ .x = self.x * inv, .y = self.y * inv, .z = self.z * inv, .w = self.w * inv };
        }

        /// Conjugate `(−x, −y, −z, w)`.
        pub fn conjugate(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y, .z = -self.z, .w = self.w };
        }

        /// Inverse rotation. For a unit quaternion this equals the conjugate,
        /// which is what engine quaternions are kept as (`normalize`d).
        pub fn inverse(self: Self) Self {
            return self.conjugate();
        }

        /// Rotate a 3-vector by this (unit) quaternion.
        pub fn rotateVec3(self: Self, v: Vec3T) Vec3T {
            const u = Vec3T.fromArray(.{ self.x, self.y, self.z });
            const t = u.cross(v).scale(2);
            return v.add(t.scale(self.w)).add(u.cross(t));
        }

        /// Componentwise sum (for angular-velocity integration; the result is
        /// not generally unit — renormalize).
        pub fn add(self: Self, other: Self) Self {
            return .{
                .x = self.x + other.x,
                .y = self.y + other.y,
                .z = self.z + other.z,
                .w = self.w + other.w,
            };
        }

        /// Scalar multiple of every component.
        pub fn scale(self: Self, s: T) Self {
            return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s, .w = self.w * s };
        }

        /// Componentwise equality within `tolerance` (inclusive).
        pub fn approxEql(self: Self, other: Self, tolerance: T) bool {
            return @abs(self.x - other.x) <= tolerance and
                @abs(self.y - other.y) <= tolerance and
                @abs(self.z - other.z) <= tolerance and
                @abs(self.w - other.w) <= tolerance;
        }

        /// Build from a `[4]T` array in `(x, y, z, w)` order.
        pub fn fromArray(arr: [4]T) Self {
            return .{ .x = arr[0], .y = arr[1], .z = arr[2], .w = arr[3] };
        }

        /// Copy the components out in `(x, y, z, w)` order.
        pub fn toArray(self: Self) [4]T {
            return .{ self.x, self.y, self.z, self.w };
        }
    };
}

/// f32 quaternion.
pub const Quatf = Quat(f32);

const testing = std.testing;
const Vec3 = vec.Vec3;

test "fromAxisAngle rotates +X to -Z about +Y" {
    const q = Quatf.fromAxisAngle(Vec3.unit_y, std.math.pi / 2.0);
    const r = q.rotateVec3(Vec3.unit_x);
    try testing.expect(r.approxEql(Vec3.unit_z.neg(), 1e-6));
}

test "mul composition equals sequential rotation" {
    const qy = Quatf.fromAxisAngle(Vec3.unit_y, std.math.pi / 2.0);
    const qx = Quatf.fromAxisAngle(Vec3.unit_x, std.math.pi / 2.0);
    const v = Vec3.fromArray(.{ 1, 0.5, -2 });
    const sequential = qx.rotateVec3(qy.rotateVec3(v));
    const composed = qx.mul(qy).rotateVec3(v);
    try testing.expect(sequential.approxEql(composed, 1e-5));
}

test "normalize yields a unit quaternion" {
    const q = Quatf{ .x = 1, .y = 2, .z = 3, .w = 4 };
    try testing.expectApproxEqAbs(@as(f32, 1), q.normalize().length(), 1e-6);
}

test "conjugate inverse round-trip is identity" {
    const q = Quatf.fromAxisAngle(Vec3.fromArray(.{ 1, 2, 3 }).normalize(), 0.7);
    try testing.expect(q.mul(q.inverse()).approxEql(Quatf.identity, 1e-6));
    try testing.expect(q.inverse().approxEql(q.conjugate(), 1e-6));
}

test "identity leaves a vector unchanged" {
    const v = Vec3.fromArray(.{ 3, -1, 2 });
    try testing.expect(Quatf.identity.rotateVec3(v).approxEql(v, 1e-6));
}

test "generic Quat f64 instantiation compiles" {
    const Q = Quat(f64);
    const V = vec.Vec(3, f64);
    const q = Q.fromAxisAngle(V.unit_y, std.math.pi / 2.0);
    try testing.expect(q.rotateVec3(V.unit_x).approxEql(V.unit_z.neg(), 1e-12));
}
