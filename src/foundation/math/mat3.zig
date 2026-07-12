//! `foundation/math/mat3.zig` — generic column-major 3×3 matrix `Mat3(T)`.
//!
//! Column-major, right-multiplied: `M.mulVec(v) == M * v`
//! (`engine-coordinate-system.md` §2). `fromQuat` agrees with
//! `Quat.rotateVec3`; for an orthonormal rotation matrix `transpose == inverse`.

const std = @import("std");
const vec = @import("vec.zig");
const quat = @import("quat.zig");

/// A 3×3 matrix over scalar `T`, stored as three column vectors. Column `c`
/// is the image of the `c`-th basis axis.
pub fn Mat3(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = vec.Vec(3, T);
        const QuatT = quat.Quat(T);

        /// The three columns (column-major storage).
        cols: [3]Vec3T,

        /// The identity matrix.
        pub const identity: Self = .{ .cols = .{
            Vec3T.fromArray(.{ 1, 0, 0 }),
            Vec3T.fromArray(.{ 0, 1, 0 }),
            Vec3T.fromArray(.{ 0, 0, 1 }),
        } };

        /// Diagonal matrix carrying `d`'s components on the diagonal.
        pub fn fromDiagonal(d: Vec3T) Self {
            return .{ .cols = .{
                Vec3T.fromArray(.{ d.data[0], 0, 0 }),
                Vec3T.fromArray(.{ 0, d.data[1], 0 }),
                Vec3T.fromArray(.{ 0, 0, d.data[2] }),
            } };
        }

        /// Rotation matrix equivalent to unit quaternion `q`
        /// (`fromQuat(q).mulVec(v) == q.rotateVec3(v)`).
        pub fn fromQuat(q: QuatT) Self {
            const xx = q.x * q.x;
            const yy = q.y * q.y;
            const zz = q.z * q.z;
            const xy = q.x * q.y;
            const xz = q.x * q.z;
            const yz = q.y * q.z;
            const wx = q.w * q.x;
            const wy = q.w * q.y;
            const wz = q.w * q.z;
            return .{ .cols = .{
                Vec3T.fromArray(.{ 1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy) }),
                Vec3T.fromArray(.{ 2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx) }),
                Vec3T.fromArray(.{ 2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy) }),
            } };
        }

        /// Matrix-vector product `self * v`.
        pub fn mulVec(self: Self, v: Vec3T) Vec3T {
            return self.cols[0].scale(v.data[0])
                .add(self.cols[1].scale(v.data[1]))
                .add(self.cols[2].scale(v.data[2]));
        }

        /// Matrix-matrix product `self * other`.
        pub fn mul(self: Self, other: Self) Self {
            return .{ .cols = .{
                self.mulVec(other.cols[0]),
                self.mulVec(other.cols[1]),
                self.mulVec(other.cols[2]),
            } };
        }

        /// Transpose (rows ↔ columns).
        pub fn transpose(self: Self) Self {
            const c = self.cols;
            return .{ .cols = .{
                Vec3T.fromArray(.{ c[0].data[0], c[1].data[0], c[2].data[0] }),
                Vec3T.fromArray(.{ c[0].data[1], c[1].data[1], c[2].data[1] }),
                Vec3T.fromArray(.{ c[0].data[2], c[1].data[2], c[2].data[2] }),
            } };
        }

        /// Determinant (scalar triple product of the columns).
        pub fn determinant(self: Self) T {
            return self.cols[0].dot(self.cols[1].cross(self.cols[2]));
        }

        /// Scalar multiple `self * s` (every element).
        pub fn scale(self: Self, s: T) Self {
            return .{ .cols = .{
                self.cols[0].scale(s),
                self.cols[1].scale(s),
                self.cols[2].scale(s),
            } };
        }

        /// Inverse matrix (undefined when the determinant is zero).
        pub fn inverse(self: Self) Self {
            const c = self.cols;
            const r0 = c[1].cross(c[2]);
            const r1 = c[2].cross(c[0]);
            const r2 = c[0].cross(c[1]);
            const det = c[0].dot(r0);
            const inv_det = 1.0 / det;
            const cofactors = Self{ .cols = .{ r0, r1, r2 } };
            return cofactors.transpose().scale(inv_det);
        }
    };
}

/// f32 3×3 matrix.
pub const Mat3f = Mat3(f32);

const testing = std.testing;
const Vec3 = vec.Vec3;
const Quatf = quat.Quatf;

/// Test helper: columnwise approximate matrix equality.
fn matApproxEql(a: Mat3f, b: Mat3f, tol: f32) bool {
    return a.cols[0].approxEql(b.cols[0], tol) and
        a.cols[1].approxEql(b.cols[1], tol) and
        a.cols[2].approxEql(b.cols[2], tol);
}

test "fromQuat parity with Quat.rotateVec3" {
    const cases = [_]Quatf{
        Quatf.fromAxisAngle(Vec3.unit_y, std.math.pi / 2.0),
        Quatf.fromAxisAngle(Vec3.unit_x, 0.4),
        Quatf.fromAxisAngle(Vec3.fromArray(.{ 1, 1, 0 }).normalize(), 1.1),
    };
    const vs = [_]Vec3{
        Vec3.unit_x,
        Vec3.fromArray(.{ 1, 2, 3 }),
        Vec3.fromArray(.{ -2, 0.5, 1 }),
    };
    for (cases) |q| {
        const m = Mat3f.fromQuat(q);
        for (vs) |v| {
            try testing.expect(m.mulVec(v).approxEql(q.rotateVec3(v), 1e-5));
        }
    }
}

test "inverse times matrix is identity" {
    const m = Mat3f{ .cols = .{
        Vec3.fromArray(.{ 2, 0, 1 }),
        Vec3.fromArray(.{ 1, 3, 0 }),
        Vec3.fromArray(.{ 0, 1, 2 }),
    } };
    try testing.expect(matApproxEql(m.inverse().mul(m), Mat3f.identity, 1e-4));
    try testing.expect(matApproxEql(m.mul(m.inverse()), Mat3f.identity, 1e-4));
}

test "transpose of orthonormal equals inverse" {
    const q = Quatf.fromAxisAngle(Vec3.fromArray(.{ 0.3, 1, 0.2 }).normalize(), 0.9);
    const m = Mat3f.fromQuat(q);
    try testing.expect(matApproxEql(m.transpose(), m.inverse(), 1e-5));
    try testing.expectApproxEqAbs(@as(f32, 1), m.determinant(), 1e-5);
}

test "fromDiagonal and identity mulVec" {
    const d = Mat3f.fromDiagonal(Vec3.fromArray(.{ 2, 3, 4 }));
    try testing.expect(d.mulVec(Vec3.one).approxEql(Vec3.fromArray(.{ 2, 3, 4 }), 1e-6));
    const v = Vec3.fromArray(.{ 5, -6, 7 });
    try testing.expect(Mat3f.identity.mulVec(v).approxEql(v, 1e-6));
    try testing.expectApproxEqAbs(@as(f32, 1), Mat3f.identity.determinant(), 1e-6);
}

test "generic Mat3 f64 instantiation compiles" {
    const M = Mat3(f64);
    const V = vec.Vec(3, f64);
    const d = M.fromDiagonal(V.fromArray(.{ 2, 2, 2 }));
    try testing.expectApproxEqAbs(@as(f64, 8), d.determinant(), 1e-12);
}
