//! `foundation/math/mat4.zig` — generic column-major 4×4 matrix `Mat4(T)`.
//!
//! Column-major, right-multiplied: `M.mulPoint(v) == M * (v, 1)`
//! (`engine-coordinate-system.md` §2). Element (row `r`, column `c`) lives at
//! `m[c * 4 + r]`, so columns 0..2 are the images of the basis axes and column
//! 3 is the translation.
//!
//! **STORAGE DIVERGES FROM `Mat3(T)`, AND THE REASON IS A FROZEN TWIN.**
//! `Mat3(T)` stores `cols: [3]Vec(3, T)`, which is `@Vector`-backed and
//! therefore has no language-defined byte layout. `Mat4f` cannot afford that:
//! it is the reflected `.mat4` field kind of the RTTI builder and it mirrors
//! `WeldMat4` on the plugin C surface, both of which need a C-compatible
//! layout that a `@Vector` does not give. Hence `extern struct { m: [16]T }`,
//! flat — 64 bytes at `f32`, identity by default, and byte-identical to the
//! declaration `src/core/rtti/type_info.zig` used to carry. A reader who
//! "harmonises" this onto the `Mat3` shape by symmetry breaks the C twin and
//! silently reclassifies every reflected `Mat4` field as `.nested_struct`,
//! because the builder matches on type IDENTITY and not on shape.
//!
//! **`ARCH-031` rule 3 applies to every reduction here.** The animation frame
//! pipeline is inside the compared-output perimeter by extension, and matrix
//! products are sums of four terms: each is written as an explicit left fold
//! in source. No `@reduce`, no `@Vector` accumulation, no transcendental.

const std = @import("std");
const vec = @import("vec.zig");
const quat = @import("quat.zig");

/// A 4×4 matrix over scalar `T`, stored as 16 elements in column-major order.
///
/// `T` must be a float: `affineInverse` divides by the determinant, and an
/// integer instantiation would truncate that division into a silently wrong
/// matrix rather than failing.
pub fn Mat4(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .float) @compileError("Mat4 requires a float scalar");
    }
    return extern struct {
        const Self = @This();
        const Vec3T = vec.Vec(3, T);
        const QuatT = quat.Quat(T);

        const identity_elements: [16]T = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };

        /// The sixteen elements, column-major: element (row `r`, column `c`)
        /// is `m[c * 4 + r]`. Defaults to the identity.
        m: [16]T = identity_elements,

        /// The identity matrix.
        pub const identity: Self = .{ .m = identity_elements };

        /// Element at (row `r`, column `c`). The index arithmetic lives here so
        /// no caller has to re-derive the column-major convention.
        pub fn at(self: Self, r: usize, c: usize) T {
            return self.m[c * 4 + r];
        }

        /// Column `c` as a 3-vector, dropping its fourth component.
        ///
        /// For an affine matrix columns 0..2 are the images of the basis axes
        /// and column 3 is the translation.
        pub fn axis(self: Self, c: usize) Vec3T {
            return Vec3T.fromArray(.{ self.m[c * 4 + 0], self.m[c * 4 + 1], self.m[c * 4 + 2] });
        }

        /// The translation column.
        pub fn translation(self: Self) Vec3T {
            return self.axis(3);
        }

        /// The matrix `T · R · S`, in that order: scale first, then rotate,
        /// then translate a point fed through `mulPoint`.
        ///
        /// `R · S` scales each COLUMN of the rotation by the matching scale
        /// component — scaling rows instead yields `S · R`, which differs
        /// under non-uniform scale and agrees under uniform scale, so a suite
        /// that only exercises uniform scale cannot tell the two apart.
        pub fn fromTrs(t: Vec3T, r: QuatT, s: Vec3T) Self {
            const xx = r.x * r.x;
            const yy = r.y * r.y;
            const zz = r.z * r.z;
            const xy = r.x * r.y;
            const xz = r.x * r.z;
            const yz = r.y * r.z;
            const wx = r.w * r.x;
            const wy = r.w * r.y;
            const wz = r.w * r.z;

            const sx = s.data[0];
            const sy = s.data[1];
            const sz = s.data[2];

            return .{ .m = .{
                (1 - 2 * (yy + zz)) * sx, (2 * (xy + wz)) * sx,     (2 * (xz - wy)) * sx,     0,
                (2 * (xy - wz)) * sy,     (1 - 2 * (xx + zz)) * sy, (2 * (yz + wx)) * sy,     0,
                (2 * (xz + wy)) * sz,     (2 * (yz - wx)) * sz,     (1 - 2 * (xx + yy)) * sz, 0,
                t.data[0],                t.data[1],                t.data[2],                1,
            } };
        }

        /// Matrix product `self * other`.
        ///
        /// Each element is a four-term sum written as an explicit left fold
        /// (`ARCH-031` rule 3): re-associating it changes the result by an ULP
        /// and puts two machines on different trajectories.
        pub fn mul(self: Self, other: Self) Self {
            var out: [16]T = undefined;
            for (0..4) |c| {
                for (0..4) |r| {
                    const t0 = self.m[0 * 4 + r] * other.m[c * 4 + 0];
                    const t1 = self.m[1 * 4 + r] * other.m[c * 4 + 1];
                    const t2 = self.m[2 * 4 + r] * other.m[c * 4 + 2];
                    const t3 = self.m[3 * 4 + r] * other.m[c * 4 + 3];
                    out[c * 4 + r] = ((t0 + t1) + t2) + t3;
                }
            }
            return .{ .m = out };
        }

        /// Transform a POINT: `v` is taken with `w == 1`, so the translation
        /// column applies.
        pub fn mulPoint(self: Self, v: Vec3T) Vec3T {
            const x = v.data[0];
            const y = v.data[1];
            const z = v.data[2];
            var out: [3]T = undefined;
            for (0..3) |r| {
                const t0 = self.m[0 * 4 + r] * x;
                const t1 = self.m[1 * 4 + r] * y;
                const t2 = self.m[2 * 4 + r] * z;
                out[r] = ((t0 + t1) + t2) + self.m[3 * 4 + r];
            }
            return Vec3T.fromArray(out);
        }

        /// Transform a DIRECTION: `v` is taken with `w == 0`, so the
        /// translation column does not apply. Under non-uniform scale this is
        /// not a normal transform — a normal needs the inverse transpose.
        pub fn mulDirection(self: Self, v: Vec3T) Vec3T {
            const x = v.data[0];
            const y = v.data[1];
            const z = v.data[2];
            var out: [3]T = undefined;
            for (0..3) |r| {
                const t0 = self.m[0 * 4 + r] * x;
                const t1 = self.m[1 * 4 + r] * y;
                const t2 = self.m[2 * 4 + r] * z;
                out[r] = (t0 + t1) + t2;
            }
            return Vec3T.fromArray(out);
        }

        /// Transpose (rows ↔ columns).
        pub fn transpose(self: Self) Self {
            var out: [16]T = undefined;
            for (0..4) |c| {
                for (0..4) |r| out[c * 4 + r] = self.m[r * 4 + c];
            }
            return .{ .m = out };
        }

        /// Inverse of an AFFINE matrix — one whose last row is (0, 0, 0, 1).
        ///
        /// Valid for any invertible upper-left 3×3, non-uniform scale and
        /// shear included; undefined when that block is singular. The caller's
        /// affine precondition is asserted rather than repaired: inverting a
        /// projective matrix this way returns a plausible-looking matrix that
        /// is wrong, which is worse than a refusal.
        pub fn affineInverse(self: Self) Self {
            std.debug.assert(self.m[3] == 0 and self.m[7] == 0 and self.m[11] == 0 and self.m[15] == 1);

            const c0 = self.axis(0);
            const c1 = self.axis(1);
            const c2 = self.axis(2);

            // Same construction as `Mat3.inverse`: the cofactor columns are
            // the pairwise crosses, the determinant is the scalar triple
            // product, and the adjugate is their transpose.
            const r0 = c1.cross(c2);
            const r1 = c2.cross(c0);
            const r2 = c0.cross(c1);
            const inv_det = 1.0 / c0.dot(r0);

            const a = r0.scale(inv_det);
            const b = r1.scale(inv_det);
            const c = r2.scale(inv_det);

            // `a`, `b`, `c` are the ROWS of the inverse block; the column-major
            // store below wants them transposed back into columns.
            //
            // The translation is `-A⁻¹ · t`, and each component is a ROW of the
            // inverse dotted with `t` — NOT a column. The two coincide for every
            // diagonal block, so a fixture whose scale is axis-aligned and whose
            // rotation is identity cannot tell them apart; this one carries both
            // a rotation and a non-uniform scale for that reason.
            const t = self.translation();
            const inv_t0 = a.dot(t);
            const inv_t1 = b.dot(t);
            const inv_t2 = c.dot(t);

            return .{ .m = .{
                a.data[0], b.data[0], c.data[0], 0,
                a.data[1], b.data[1], c.data[1], 0,
                a.data[2], b.data[2], c.data[2], 0,
                -inv_t0,   -inv_t1,   -inv_t2,   1,
            } };
        }

        /// Elementwise approximate equality within `tolerance`.
        ///
        /// **Written in the POSITIVE form, and the negation is not equivalent.**
        /// `@abs(x - y) > tolerance` is FALSE for a NaN difference, so the
        /// negated form accepts a matrix that is entirely NaN — and every
        /// assertion shaped `inverse.mul(m).approxEql(identity, eps)` then
        /// passes on a total failure of the inverse. The siblings in this
        /// submodule all use the positive form for the same reason.
        pub fn approxEql(self: Self, other: Self, tolerance: T) bool {
            for (self.m, other.m) |x, y| {
                if (!(@abs(x - y) <= tolerance)) return false;
            }
            return true;
        }
    };
}

/// f32 4×4 matrix. **This is the type the RTTI reflection surface and the
/// plugin C ABI both name**, so its layout is not free: `extern struct`,
/// 64 bytes, column-major, identity default.
pub const Mat4f = Mat4(f32);

const testing = std.testing;
const Vec3 = vec.Vec3;
const Quatf = quat.Quatf;

test "the element index is column-major" {
    // A matrix whose elements are their own index: `at(r, c)` must read
    // `c * 4 + r`. The identity cannot discriminate the two conventions —
    // it is symmetric — so the fixture is deliberately asymmetric.
    var m: Mat4f = .identity;
    for (&m.m, 0..) |*e, i| e.* = @floatFromInt(i);
    try testing.expectEqual(@as(f32, 0), m.at(0, 0));
    try testing.expectEqual(@as(f32, 1), m.at(1, 0));
    try testing.expectEqual(@as(f32, 4), m.at(0, 1));
    try testing.expectEqual(@as(f32, 12), m.at(0, 3));
    try testing.expectEqual(@as(f32, 15), m.at(3, 3));
}

test "identity is neutral for mul and for mulPoint" {
    const v = Vec3.fromArray(.{ 3, -4, 5 });
    try testing.expect(Mat4f.identity.mulPoint(v).approxEql(v, 1e-6));
    const m = Mat4f.fromTrs(
        Vec3.fromArray(.{ 1, 2, 3 }),
        Quatf.fromAxisAngle(Vec3.unit_y, 0.7),
        Vec3.fromArray(.{ 2, 3, 4 }),
    );
    try testing.expect(m.mul(Mat4f.identity).approxEql(m, 1e-6));
    try testing.expect(Mat4f.identity.mul(m).approxEql(m, 1e-6));
}

test "TRS composition matches the reference product" {
    // **ALL SIXTEEN ELEMENTS, twice, against two oracles — and the first
    // attempt at this test could not see two of the four columns.** The
    // image-of-three-points test below probes columns 0, 1 and 3 and touches
    // column 2 with nothing: verified by mutation, scaling `fromTrs`'s third
    // column left the whole suite green while the same mutation on column 0
    // reddened it. The replacement then used a quarter turn about +X, where the
    // diagonal terms of columns 1 and 2 are EXACTLY ZERO — so scaling them
    // changed nothing either, and the new test was blind to the same two
    // columns for a different reason. A fixture that cannot express an error
    // cannot detect it, and a rotation is a very effective way to hide one.

    // ORACLE ONE — hand-computable, and no element of the basis is zero. A half
    // turn about +X sends +Y to −Y and +Z to −Z, so with scale (2, 3, 4) the
    // basis columns are (2,0,0), (0,−3,0), (0,0,−4) and the fourth is the
    // translation. Every diagonal term is non-zero, which is what the quarter
    // turn cost.
    const half = Mat4f.fromTrs(
        Vec3.fromArray(.{ 1, 2, 3 }),
        Quatf.fromAxisAngle(Vec3.unit_x, std.math.pi),
        Vec3.fromArray(.{ 2, 3, 4 }),
    );
    const reference = [16]f32{
        2, 0,  0,  0,
        0, -3, 0,  0,
        0, 0,  -4, 0,
        1, 2,  3,  1,
    };
    for (half.m, reference, 0..) |got, want, i| {
        errdefer std.debug.print("element {d} (row {d}, column {d}) diverged\n", .{ i, i % 4, i / 4 });
        try testing.expectApproxEqAbs(want, got, 1e-6);
    }

    // ORACLE TWO — a GENERIC rotation, where every one of the nine basis terms
    // is non-zero, checked against the geometric definition of what a TRS
    // matrix IS: column `c` is the image, under the rotation, of the `c`-th
    // basis axis scaled by `s[c]`. The reference comes from `Quat.rotateVec3`,
    // a different function tested on its own against `Mat3.fromQuat` — so an
    // error in `fromTrs` cannot cancel itself here the way it does inside an
    // inverse round trip, which derives its second operand from the first.
    const t = Vec3.fromArray(.{ -5, 7, 0.25 });
    // Axis and angle chosen so the SMALLEST scaled basis term is 0.66, not by
    // taste: a rotation whose matrix carries a near-zero term is a rotation on
    // which scaling that term is unobservable, and the guard at the foot of
    // this test refuses such a fixture rather than letting it pass quietly.
    const q = Quatf.fromAxisAngle(Vec3.fromArray(.{ 1, 1, 1 }).normalize(), 1.1);
    const scale = Vec3.fromArray(.{ 2, 3, 4 });
    const m = Mat4f.fromTrs(t, q, scale);

    const axes = [3]Vec3{ Vec3.unit_x, Vec3.unit_y, Vec3.unit_z };
    // `@Vector` lanes are not indexable at run time; the scale is read once
    // into an array so the loop can take its components by a run-time index.
    const scale_parts = scale.toArray();
    var smallest: f32 = std.math.floatMax(f32);
    for (axes, scale_parts, 0..) |axis, s_c, c| {
        const want = q.rotateVec3(axis.scale(s_c)).toArray();
        for (want, 0..) |component, r| {
            errdefer std.debug.print("basis element (row {d}, column {d}) diverged\n", .{ r, c });
            try testing.expectApproxEqAbs(component, m.at(r, c), 1e-5);
            smallest = @min(smallest, @abs(component));
        }
        try testing.expectApproxEqAbs(@as(f32, 0), m.at(3, c), 1e-6);
    }
    try testing.expect(m.translation().approxEql(t, 1e-6));
    try testing.expectApproxEqAbs(@as(f32, 1), m.at(3, 3), 1e-6);

    // The discrimination guard this test owes itself: no basis element is near
    // zero, so scaling ANY of the nine is observable. Without it the fixture
    // could quietly drift back into the shape that hid two columns twice.
    try testing.expect(smallest > 0.1);
}

test "fromTrs applies scale before rotation and translation last" {
    // Non-uniform scale on purpose: under uniform scale `R·S == S·R`, so a
    // uniform fixture passes whichever order the code applies.
    const t = Vec3.fromArray(.{ 10, 20, 30 });
    const r = Quatf.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0);
    const s = Vec3.fromArray(.{ 2, 5, 1 });
    const m = Mat4f.fromTrs(t, r, s);

    // +X scaled by 2, then rotated +90° about +Z onto +Y, then translated.
    try testing.expect(m.mulPoint(Vec3.unit_x).approxEql(Vec3.fromArray(.{ 10, 22, 30 }), 1e-5));
    // +Y scaled by 5, then rotated onto −X.
    try testing.expect(m.mulPoint(Vec3.unit_y).approxEql(Vec3.fromArray(.{ 5, 20, 30 }), 1e-5));
    // The translation column is the image of the origin.
    try testing.expect(m.mulPoint(Vec3.zero).approxEql(t, 1e-5));
    try testing.expect(m.translation().approxEql(t, 1e-5));
}

test "mulDirection applies the basis and ignores the translation column" {
    // **The basis half, and it needs a NON-IDENTITY basis to exist.** An
    // earlier form built the matrix with an identity rotation and a unit
    // scale, so the 3×3 block was the identity and transposing the index
    // arithmetic left the whole suite green: the test pinned only what its
    // title said, the excluded fourth column.
    const m = Mat4f.fromTrs(
        Vec3.fromArray(.{ 100, 200, 300 }),
        Quatf.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0),
        Vec3.fromArray(.{ 2, 5, 1 }),
    );

    // +X scaled by 2 then turned onto +Y — and the translation does not apply.
    try testing.expect(m.mulDirection(Vec3.unit_x).approxEql(Vec3.fromArray(.{ 0, 2, 0 }), 1e-5));
    // +Y scaled by 5 then turned onto −X.
    try testing.expect(m.mulDirection(Vec3.unit_y).approxEql(Vec3.fromArray(.{ -5, 0, 0 }), 1e-5));
    // The same vector as a POINT carries the translation on top.
    try testing.expect(m.mulPoint(Vec3.unit_x).approxEql(Vec3.fromArray(.{ 100, 202, 300 }), 1e-5));
    // And the two differ by exactly the translation column, for any vector.
    const v = Vec3.fromArray(.{ 3, -4, 7 });
    try testing.expect(m.mulPoint(v).sub(m.mulDirection(v)).approxEql(m.translation(), 1e-4));
}

test "affineInverse round-trips a non-uniformly scaled TRS matrix" {
    const m = Mat4f.fromTrs(
        Vec3.fromArray(.{ 1.5, -2.25, 0.75 }),
        Quatf.fromAxisAngle(Vec3.fromArray(.{ 0.3, 1, 0.2 }).normalize(), 0.9),
        Vec3.fromArray(.{ 2, 0.5, 3 }),
    );
    const inv = m.affineInverse();
    try testing.expect(inv.mul(m).approxEql(Mat4f.identity, 1e-4));
    try testing.expect(m.mul(inv).approxEql(Mat4f.identity, 1e-4));

    const p = Vec3.fromArray(.{ 4, -1, 2 });
    try testing.expect(inv.mulPoint(m.mulPoint(p)).approxEql(p, 1e-4));
}

test "transpose swaps rows and columns and is an involution" {
    var m: Mat4f = .identity;
    for (&m.m, 0..) |*e, i| e.* = @floatFromInt(i);
    const t = m.transpose();
    try testing.expectEqual(m.at(1, 0), t.at(0, 1));
    try testing.expectEqual(m.at(0, 3), t.at(3, 0));
    try testing.expect(t.transpose().approxEql(m, 0));
}

test "generic Mat4 f64 instantiation composes and inverts" {
    const M = Mat4(f64);
    const V = vec.Vec(3, f64);
    const Q = quat.Quat(f64);
    const m = M.fromTrs(
        V.fromArray(.{ 7, 8, 9 }),
        Q.fromAxisAngle(V.unit_x, 0.31),
        V.fromArray(.{ 1.25, 2.5, 0.5 }),
    );
    try testing.expect(m.affineInverse().mul(m).approxEql(M.identity, 1e-12));
}
