//! `forge_3d/pipeline/narrowphase/support.zig` — the shared geometry base of
//! the narrowphase package: the convex support shapes, the frame-of-A relative
//! pose, the Minkowski-difference support sample, and (M1.1.3) the supporting
//! feature used by the contact-manifold clipper.
//!
//! Relocated verbatim from the single-file `narrowphase.zig` at M1.1.3/E1
//! (`SupportShape(T)`, `RelativePose(T)`, and the `minkowskiSupport` free
//! function — promoted to `pub` here because the GJK loop, EPA, and the manifold
//! generator all consume it). GJK's own machinery (`Simplex`, the descent loop,
//! `GjkResult`) lives in the sibling `gjk.zig`.
//!
//! **Dependency discipline (brief Notes).** This file imports `foundation`
//! (math) ONLY — never `weld_forge`, never `body*.zig`, never `config.zig`,
//! never `broadphase.zig`. The scalar arrives as the comptime parameter `T`;
//! `forge_3d` instantiates it at `config.Real`. The `Shape → SupportShape`
//! conversion lives on the forge_3d side (`shape.zig`).
//!
//! **Cores + inflation radius (Jolt convex-radius architecture).** GJK/EPA never
//! see a curved surface: a sphere is a point, a capsule a segment, a box the
//! full box (radius 0). Support functions run on the convex **core**; the
//! inflation `radius` is applied downstream (touch test in `gjk.zig`; contact
//! point placement in `manifold.zig`).
//!
//! **Computation in the frame of A (brief Notes).** B is pre-transformed
//! relative to A once per pair (`RelativePose`); A's support runs untransformed.
//! Better precision far from the world origin and half the per-iteration
//! transforms. Frozen (M1.1.14): changing the computation frame would break
//! validated bit-exactness.

const std = @import("std");
const math = @import("foundation").math;

/// One support sample on the Minkowski difference of the two cores: the
/// difference point `w = support_a − support_b` together with the two supports
/// it came from (all in A's frame). Storing all three — rather than just `w` —
/// lets a consumer reconstruct the closest points on A and B from barycentric
/// weights (`closest_a = Σ λ_i · support_a_i`, likewise for B). The GJK simplex
/// (`gjk.zig`) and the EPA polytope (`epa.zig`) are both built from these;
/// `Simplex(T).Vertex` and `GjkResult(T).Vertex` alias this type.
pub fn Vertex(comptime T: type) type {
    return struct {
        /// Minkowski-difference point `support_a − support_b` (A's frame).
        w: math.Vec(3, T),
        /// Support point on A's core (A's frame).
        support_a: math.Vec(3, T),
        /// Support point on B's core (A's frame).
        support_b: math.Vec(3, T),
    };
}

/// A convex support shape: a convex **core** (point / segment / box) plus an
/// inflation `radius` around it (the Jolt convex-radius architecture). GJK/EPA
/// run on the core alone and never see the inflated surface. `radius` is 0 for a
/// box in M1.1.2/3. Future shapes (cylinder, convex hull) are new `Core` cases,
/// purely additive.
pub fn SupportShape(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = math.Vec(3, T);

        /// The convex core geometry, in the shape's own local frame.
        core: Core,
        /// Inflation radius around the core (0 for box in M1.1.2/3).
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

/// Shape B's pose relative to shape A, precomputed once per pair so GJK/EPA run
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

/// Support point of the Minkowski difference of the two cores in direction
/// `dir` (A's frame): `support_A(dir) − support_B(−dir)`, keeping both supports
/// so the closest points on A and B stay reconstructible. `pub` because both the
/// GJK descent (`gjk.zig`) and the EPA / manifold generators (M1.1.3) consume it.
pub fn minkowskiSupport(
    comptime T: type,
    shape_a: SupportShape(T),
    relpose: RelativePose(T),
    shape_b: SupportShape(T),
    dir: math.Vec(3, T),
) Vertex(T) {
    const sa = shape_a.support(dir);
    const sb = relpose.supportB(shape_b, dir.neg());
    return .{ .w = sa.sub(sb), .support_a = sa, .support_b = sb };
}
