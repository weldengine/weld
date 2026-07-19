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

/// The supporting **feature** of a core in a given direction: the polygon (or
/// edge / vertex) whose points maximize `dir · p` on the core, in the core's
/// local frame, radius excluded. Up to 4 vertices (a box face); `count` gives
/// the valid prefix (point → 1, segment → 1 or 2, box → 4). The contact-manifold
/// clipper (M1.1.3) takes `supportingFace(+n)` on A and `supportingFace(−n)` on
/// B — where `n` is the contact normal A→B — and clips one against the other.
///
/// `face_id` and `vert_ids` carry STABLE, translation-invariant local feature
/// identities (a box vertex id is its sign-pattern 0..7, a box face id is
/// `axis·2 + sign`) so the manifold's `feature_id` survives a small pose change
/// for M1.1.6 warm-starting (frame-stability is the point — a clip-buffer index
/// is not stable).
pub fn Face(comptime T: type) type {
    return struct {
        /// The feature vertices; only `[0..count]` is meaningful.
        verts: [4]math.Vec(3, T),
        /// Stable local id of each vertex (aligned to `verts`): a box corner's
        /// sign pattern 0..7; a segment endpoint 0 (+Y) / 1 (−Y); a point 0.
        vert_ids: [4]u8,
        /// Number of valid vertices (1..4).
        count: u8,
        /// Stable local id of the feature itself: box face `axis·2 + (sign<0)`
        /// (0..5); segment 6; point 7.
        face_id: u8,
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

        /// The supporting **feature** of the core in direction `dir` (local
        /// frame, radius excluded): the vertex / segment / quad whose points
        /// maximize `dir · p`. Contains `support(dir)`; the manifold clipper
        /// consumes it (see `Face`). `dir` need not be normalized.
        ///
        /// Per core: a point core is always the single origin vertex; a segment
        /// core is the single extremal endpoint when `dir` is essentially along
        /// its ±Y axis (`perp² ≤ aligned_rel · |dir|²`), else the whole segment
        /// (a line contact); a box core is the winning quad — the face on the
        /// dominant axis of `dir` (first-index tie-break, mirroring `support`'s
        /// `>= 0` sign choice), wound CCW around its outward normal.
        pub fn supportingFace(self: Self, dir: Vec3T) Face(T) {
            const zero = Vec3T.zero;
            switch (self.core) {
                .point => return .{ .verts = .{ zero, zero, zero, zero }, .vert_ids = .{ 0, 0, 0, 0 }, .count = 1, .face_id = 7 },
                .segment => |half_height| {
                    const d = dir.toArray();
                    const perp_sq = d[0] * d[0] + d[2] * d[2];
                    const total_sq = perp_sq + d[1] * d[1];
                    // Essentially end-on ⇒ the single extremal endpoint (like
                    // `support`, +Y on the `dir.y == 0` tie); else the segment.
                    const aligned_rel: T = if (T == f32) 1.0e-6 else 1.0e-12;
                    const plus = Vec3T.fromArray(.{ 0, half_height, 0 });
                    const minus = Vec3T.fromArray(.{ 0, -half_height, 0 });
                    if (perp_sq <= aligned_rel * total_sq) {
                        const plus_end = d[1] >= 0;
                        const endpoint = if (plus_end) plus else minus;
                        return .{ .verts = .{ endpoint, zero, zero, zero }, .vert_ids = .{ if (plus_end) 0 else 1, 0, 0, 0 }, .count = 1, .face_id = 6 };
                    }
                    return .{ .verts = .{ plus, minus, zero, zero }, .vert_ids = .{ 0, 1, 0, 0 }, .count = 2, .face_id = 6 };
                },
                .box => |half_extents| {
                    const d = dir.toArray();
                    const he = half_extents.toArray();
                    // Dominant axis of `dir` (first-index tie-break: strict `>`).
                    var k: usize = 0;
                    var best = @abs(d[0]);
                    if (@abs(d[1]) > best) {
                        k = 1;
                        best = @abs(d[1]);
                    }
                    if (@abs(d[2]) > best) k = 2;
                    // Face sign (`>= 0` tie to `+`, mirroring `support`).
                    const s: T = if (d[k] >= 0) 1 else -1;
                    const u = (k + 1) % 3;
                    const v = (k + 2) % 3;
                    // CCW winding around the outward normal `s·e_k`: for `s = +1`
                    // the in-plane loop (−u,−v)→(+u,−v)→(+u,+v)→(−u,+v) is CCW
                    // (since `e_u × e_v = e_k`); for `s = −1` the outward normal
                    // flips, so the loop is reversed.
                    const loop: [4][2]T = if (s >= 0)
                        .{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }
                    else
                        .{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, 1 }, .{ 1, -1 } };
                    var face: Face(T) = .{ .verts = undefined, .vert_ids = undefined, .count = 4, .face_id = @intCast(k * 2 + @intFromBool(s < 0)) };
                    for (loop, 0..) |o, i| {
                        var c: [3]T = undefined;
                        c[k] = s * he[k];
                        c[u] = o[0] * he[u];
                        c[v] = o[1] * he[v];
                        face.verts[i] = Vec3T.fromArray(c);
                        // Stable corner id: one bit per axis, set when the sign is +.
                        var sgn: [3]T = undefined;
                        sgn[k] = s;
                        sgn[u] = o[0];
                        sgn[v] = o[1];
                        face.vert_ids[i] = (@as(u8, @intFromBool(sgn[0] > 0))) | (@as(u8, @intFromBool(sgn[1] > 0)) << 1) | (@as(u8, @intFromBool(sgn[2] > 0)) << 2);
                    }
                    return face;
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

        /// Supporting **feature** of shape B's core, expressed in A's frame, for
        /// a direction `dir` given in A's frame (mirror of `supportB`, at the
        /// feature grain). The direction is inverse-rotated into B's local frame,
        /// B's local `supportingFace` is taken, then each vertex is mapped back
        /// into A's frame; the winding is preserved (a proper rotation).
        pub fn supportingFaceB(self: Self, shape_b: SupportShapeT, dir: Vec3T) Face(T) {
            const local_dir = self.rot_rel.conjugate().rotateVec3(dir);
            const face_local = shape_b.supportingFace(local_dir);
            // The rotation preserves feature identity, so `vert_ids`/`face_id`
            // carry through unchanged.
            var out: Face(T) = .{ .verts = .{ Vec3T.zero, Vec3T.zero, Vec3T.zero, Vec3T.zero }, .vert_ids = face_local.vert_ids, .count = face_local.count, .face_id = face_local.face_id };
            for (0..face_local.count) |i| {
                out.verts[i] = self.rot_rel.rotateVec3(face_local.verts[i]).add(self.pos_rel);
            }
            return out;
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

const testing = std.testing;

test "supporting face returns the correct feature per core" {
    const T = f32;
    const SS = SupportShape(T);
    const V = math.Vec(3, T);
    const Q = math.Quat(T);
    const tol: T = 1e-6;
    const vf = struct {
        fn f(x: T, y: T, z: T) V {
            return V.fromArray(.{ x, y, z });
        }
    }.f;
    // Whether `p` is among the face's first `count` vertices.
    const inFace = struct {
        fn f(face: Face(T), p: V) bool {
            for (0..face.count) |i| {
                if (face.verts[i].approxEql(p, tol)) return true;
            }
            return false;
        }
    }.f;

    // Point core → always the single origin vertex, any direction.
    const p = SS{ .core = .point, .radius = 0.5 };
    {
        const f = p.supportingFace(vf(1, 2, -3));
        try testing.expectEqual(@as(u8, 1), f.count);
        try testing.expect(f.verts[0].approxEql(V.zero, tol));
    }

    // Segment core: end-on (dir ≈ ±Y) → the single extremal endpoint; oblique
    // (a real perpendicular component) → the whole segment (line contact, 2).
    const seg = SS{ .core = .{ .segment = 0.9 }, .radius = 0.3 };
    {
        const up = seg.supportingFace(vf(0, 1, 0));
        try testing.expectEqual(@as(u8, 1), up.count);
        try testing.expect(up.verts[0].approxEql(vf(0, 0.9, 0), tol));

        const down = seg.supportingFace(vf(0, -1, 0));
        try testing.expectEqual(@as(u8, 1), down.count);
        try testing.expect(down.verts[0].approxEql(vf(0, -0.9, 0), tol));

        // A near-vertical direction is still end-on ⇒ single endpoint.
        const near = seg.supportingFace(vf(0.0001, 1, 0));
        try testing.expectEqual(@as(u8, 1), near.count);

        // Perpendicular and oblique ⇒ the whole segment.
        const side = seg.supportingFace(vf(1, 0, 0));
        try testing.expectEqual(@as(u8, 2), side.count);
        try testing.expect(inFace(side, vf(0, 0.9, 0)) and inFace(side, vf(0, -0.9, 0)));
        const obl = seg.supportingFace(vf(1, 0.2, -0.5));
        try testing.expectEqual(@as(u8, 2), obl.count);
        // The feature contains `support(dir)` (the +Y endpoint on the `dir.y == 0` tie).
        try testing.expect(inFace(seg.supportingFace(vf(1, 0, 0)), seg.support(vf(1, 0, 0))));
    }

    // Box core → the winning quad (4) on the dominant axis; support(dir) ∈ face;
    // all four verts share the dominant-axis coordinate (one face).
    const box = SS{ .core = .{ .box = vf(1, 2, 3) }, .radius = 0 };
    {
        const dirs = [_]V{ vf(1, 0, 0), vf(-1, 0, 0), vf(0, 1, 0), vf(0, 0, -1), vf(0.9, 0.1, -0.2), vf(1, 1, 0) };
        for (dirs) |d| {
            const f = box.supportingFace(d);
            try testing.expectEqual(@as(u8, 4), f.count);
            try testing.expect(inFace(f, box.support(d)));
            // The four verts are coplanar on the winning face: the dominant axis
            // coordinate is identical across all four.
            const da = d.toArray();
            var k: usize = 0;
            var m = @abs(da[0]);
            if (@abs(da[1]) > m) {
                k = 1;
                m = @abs(da[1]);
            }
            if (@abs(da[2]) > m) k = 2;
            const c0 = f.verts[0].toArray()[k];
            for (0..4) |i| try testing.expectApproxEqAbs(c0, f.verts[i].toArray()[k], tol);
        }
    }

    // Through a non-trivial relative rotation (supportingFaceB): B is `box`,
    // rotated +90° about +Z. For dir=+X in A's frame the count is preserved (4)
    // and the feature contains `supportB(box, +X)`.
    const rp = RelativePose(T).init(V.zero, Q.identity, V.zero, Q.fromAxisAngle(V.unit_z, std.math.pi / 2.0));
    {
        const f = rp.supportingFaceB(box, vf(1, 0, 0));
        try testing.expectEqual(@as(u8, 4), f.count);
        try testing.expect(inFace(f, rp.supportB(box, vf(1, 0, 0))));
        // Segment B through the same rotation: perpendicular dir ⇒ 2-vert segment.
        const seg_face = rp.supportingFaceB(seg, vf(0, 1, 0));
        try testing.expectEqual(@as(u8, 2), seg_face.count);
    }

    // Byte-stable across runs: pure sign/threshold selection, no float noise.
    try testing.expect(box.supportingFace(vf(0.9, 0.1, -0.2)).verts[2]
        .eql(box.supportingFace(vf(0.9, 0.1, -0.2)).verts[2]));
}
