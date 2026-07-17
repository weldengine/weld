//! `forge_3d/pipeline/narrowphase.zig` — distance-based GJK convex detection.
//!
//! Delivered gate by gate across M1.1.2: **E1 (this file so far)** the support
//! shapes + support functions + relative-pose precompute; E2 the Voronoi-region
//! simplex solver; E3 the GJK descent loop and `GjkResult`; E4 the forge_3d
//! integration (`Shape → SupportShape`, `gjkPair`). EPA, penetration depth,
//! contact normal, and the fast paths are later sub-milestones (M1.1.3/4).
//!
//! **Dependency discipline (brief Notes).** This file imports `foundation`
//! (math) ONLY — never `weld_forge`, never `body*.zig`, never `config.zig`,
//! never `broadphase.zig`. The scalar arrives as the comptime parameter `T`;
//! `forge_3d` instantiates it at `config.Real` (E4). The `Shape → SupportShape`
//! conversion and the `BodyId`-level `gjkPair` adapter live on the forge_3d
//! side, mirroring the broadphase `user_data` discipline.
//!
//! **Cores + inflation radius (Jolt convex-radius architecture).** GJK never
//! sees a curved surface: a sphere is a point, a capsule a segment, a box the
//! full box (radius 0). Support functions therefore run on the convex **core**;
//! the inflation `radius` is applied only in the touch test (`dist(cores) <=
//! r_a + r_b`, E3). Fast convergence, no simplex degeneracy near contact.
//!
//! **Computation in the frame of A (brief Notes).** B is pre-transformed
//! relative to A once per pair (`RelativePose`); A's support runs untransformed.
//! Better precision far from the world origin (avoids large-coordinate
//! cancellation) and half the per-iteration transforms. Frozen now: changing
//! the computation frame after the M1.1.14 determinism freeze would break
//! validated bit-exactness.
//!
//! **Determinism by construction (anticipates M1.1.14).** No hash containers,
//! no trigonometry (dot/cross only), fixed support tie-breaks (see `support`).

const std = @import("std");
const math = @import("foundation").math;

/// A convex support shape: a convex **core** (point / segment / box) plus an
/// inflation `radius` around it (the Jolt convex-radius architecture). GJK runs
/// on the core alone and never sees the inflated surface, so the milestone's
/// touch test is `distance(cores) <= r_a + r_b` (the contact interpretation is
/// M1.1.3). `radius` is 0 for a box in M1.1.2. Future shapes (cylinder, convex
/// hull) are new `Core` cases, purely additive.
pub fn SupportShape(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = math.Vec(3, T);

        /// The convex core geometry, in the shape's own local frame.
        core: Core,
        /// Inflation radius around the core (0 for box in M1.1.2).
        radius: T,

        /// The convex core of a support shape, in its local frame.
        pub const Core = union(enum) {
            /// Sphere core: the local origin.
            point,
            /// Capsule core: Y-axis segment, ±half_height.
            segment: T,
            /// Box core: half-extents (full box, no shrink).
            box: math.Vec(3, T),
        };

        /// Support point of the **core** (the inflation radius is excluded), in
        /// the local frame: the core point that maximizes `dir · p`. `dir` need
        /// not be normalized.
        ///
        /// Tie-breaks are fixed for determinism (brief Notes): a capsule
        /// direction with `dir.y == 0` selects the `+Y` endpoint; a box
        /// direction component `== 0` selects the `+half_extent` corner
        /// component. Both fall out of the `>= 0` comparisons below.
        pub fn support(self: Self, dir: Vec3T) Vec3T {
            switch (self.core) {
                .point => return Vec3T.zero,
                .segment => |half_height| {
                    // Segment lies on the Y axis; only the sign of dir.y counts.
                    const dy = dir.toArray()[1];
                    const y = if (dy >= 0) half_height else -half_height;
                    return Vec3T.fromArray(.{ 0, y, 0 });
                },
                .box => |half_extents| {
                    // Separable per axis: p_i = sign(dir_i) · half_extent_i.
                    const d = dir.toArray();
                    const he = half_extents.toArray();
                    return Vec3T.fromArray(.{
                        if (d[0] >= 0) he[0] else -he[0],
                        if (d[1] >= 0) he[1] else -he[1],
                        if (d[2] >= 0) he[2] else -he[2],
                    });
                },
            }
        }
    };
}

/// Shape B's pose relative to shape A, precomputed once per pair so GJK runs
/// entirely in A's frame (A's support is untransformed; only B's support pays a
/// transform). See the file header for why the frame of A is frozen.
pub fn RelativePose(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = math.Vec(3, T);
        const QuatT = math.Quat(T);
        const SupportShapeT = SupportShape(T);

        /// Orientation of B expressed in A's frame: `conj(rot_a) · rot_b`.
        rot_rel: QuatT,
        /// Origin of B expressed in A's frame: `conj(rot_a) · (pos_b − pos_a)`.
        pos_rel: Vec3T,

        /// Precompute B-relative-to-A from the two world poses. Uses the
        /// conjugate (the unit-quaternion inverse) throughout — never
        /// `inverse()`, which divides by the squared norm on the hot path
        /// (brief Notes).
        pub fn init(pos_a: Vec3T, rot_a: QuatT, pos_b: Vec3T, rot_b: QuatT) Self {
            const inv_a = rot_a.conjugate();
            return .{
                .rot_rel = inv_a.mul(rot_b),
                .pos_rel = inv_a.rotateVec3(pos_b.sub(pos_a)),
            };
        }

        /// Support point of shape B's core, expressed in A's frame, for a
        /// direction `dir` given in A's frame. The direction is inverse-rotated
        /// into B's local frame (`conj(rot_rel)`), B's local support is taken,
        /// then the result is mapped back into A's frame.
        pub fn supportB(self: Self, shape_b: SupportShapeT, dir: Vec3T) Vec3T {
            const local_dir = self.rot_rel.conjugate().rotateVec3(dir);
            const p_local = shape_b.support(local_dir);
            return self.rot_rel.rotateVec3(p_local).add(self.pos_rel);
        }
    };
}
