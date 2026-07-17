//! `forge_3d/pipeline/narrowphase.zig` — distance-based GJK convex detection.
//!
//! Delivered gate by gate across M1.1.2: **E1–E3 (present)** — E1 the support
//! shapes + support functions + relative-pose precompute; E2 the Voronoi-region
//! simplex solver (`Simplex(T)`); E3 the bounded GJK descent loop (`gjk`) and
//! its three-regime `GjkResult(T)`. E4 adds the forge_3d integration
//! (`Shape → SupportShape`, `gjkPair`). EPA, penetration depth, contact normal,
//! and the fast paths are later sub-milestones (M1.1.3/4).
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

/// The GJK simplex machinery: the triplet `Vertex` and the origin-closest-point
/// solver over point / segment / triangle / tetrahedron. The four `closestOrigin*`
/// functions are pure, Ericson-style (RTCD §5.1) Voronoi-region case analyses
/// specialized to the query point being the **origin** (GJK runs on the
/// Minkowski difference, whose closest approach to the origin is the separation).
/// Each returns the closest point, the surviving sub-feature, and its barycentric
/// weights — the data the E3 GJK loop needs to shrink the simplex, reconstruct
/// closest points on A and B, and steer the next search direction.
///
/// Determinism (brief Notes, anticipates M1.1.14): regions are evaluated in a
/// fixed order and the first match wins; every division is guarded so degenerate
/// inputs (duplicated vertices, collinear triangle, coplanar tetrahedron) fall
/// back to a lower feature rather than producing a NaN.
pub fn Simplex(comptime T: type) type {
    return struct {
        const Vec3T = math.Vec(3, T);

        /// One simplex vertex: a point `w` on the Minkowski difference of the two
        /// cores together with the two supports it came from. Storing all three
        /// (rather than just `w = support_a − support_b`) lets the GJK loop
        /// reconstruct the closest points on A and B from the barycentric weights
        /// (E3): `closest_a = Σ λ_i · support_a_i`, likewise for B.
        pub const Vertex = struct {
            /// Minkowski-difference point `support_a − support_b` (A's frame).
            w: Vec3T,
            /// Support point on A's core (A's frame).
            support_a: Vec3T,
            /// Support point on B's core (A's frame).
            support_b: Vec3T,
        };

        /// The reduced simplex a `closestOrigin*` call resolves to: the point on
        /// the simplex closest to the origin, the surviving input-vertex indices
        /// (`indices[0..count]`; set-valued, order not guaranteed for the
        /// degenerate fall-backs), and their barycentric weights
        /// (`bary[0..count]`, aligned to `indices`, summing to 1).
        pub const Result = struct {
            /// Closest point to the origin on the simplex.
            closest: Vec3T,
            /// Number of surviving vertices (the reduced feature size), 1..4.
            count: u8,
            /// Surviving input-vertex indices; only `[0..count]` is meaningful.
            indices: [4]u8,
            /// Barycentric weight per surviving vertex, aligned to `indices`;
            /// only `[0..count]` is meaningful and it sums to 1.
            bary: [4]T,
        };

        /// Closest point to the origin on a 0-simplex (a single vertex): the
        /// vertex itself.
        pub fn closestOriginPoint(a: Vec3T) Result {
            return vertexResult(a, 0);
        }

        /// Closest point to the origin on the segment `a`–`b`. Resolves to
        /// vertex `a` (`t <= 0`), vertex `b` (`t >= 1`), or the interior point
        /// `a + t·(b − a)`. A degenerate segment (`a == b`) resolves to `a`.
        pub fn closestOriginSegment(a: Vec3T, b: Vec3T) Result {
            const ab = b.sub(a);
            const denom = ab.dot(ab); // |ab|²
            if (denom <= 0) return vertexResult(a, 0); // a == b
            const t = a.neg().dot(ab) / denom; // (origin − a)·ab / |ab|²
            if (t <= 0) return vertexResult(a, 0);
            if (t >= 1) return vertexResult(b, 1);
            return edgeResult(a.add(ab.scale(t)), 0, 1, 1 - t, t);
        }

        /// Closest point to the origin on the triangle `a`–`b`–`c` (Ericson
        /// RTCD §5.1.5, P = origin): vertex, edge, or face region, evaluated in
        /// the fixed order A, B, AB, C, AC, BC, face. Every edge denominator is a
        /// squared edge length (guarded `> 0`); a degenerate (collinear) triangle
        /// that reaches the face branch falls back to the closest of the three
        /// edges — no division by zero.
        pub fn closestOriginTriangle(a: Vec3T, b: Vec3T, c: Vec3T) Result {
            const ab = b.sub(a);
            const ac = c.sub(a);
            const ap = a.neg(); // origin − a
            const d1 = ab.dot(ap);
            const d2 = ac.dot(ap);
            if (d1 <= 0 and d2 <= 0) return vertexResult(a, 0); // region A

            const bp = b.neg();
            const d3 = ab.dot(bp);
            const d4 = ac.dot(bp);
            if (d3 >= 0 and d4 <= d3) return vertexResult(b, 1); // region B

            const vc = d1 * d4 - d3 * d2;
            if (vc <= 0 and d1 >= 0 and d3 <= 0) { // region AB
                const denom = d1 - d3; // = |ab|²
                if (denom > 0) {
                    const v = d1 / denom;
                    return edgeResult(a.add(ab.scale(v)), 0, 1, 1 - v, v);
                }
                return vertexResult(a, 0); // a == b
            }

            const cp = c.neg();
            const d5 = ab.dot(cp);
            const d6 = ac.dot(cp);
            if (d6 >= 0 and d5 <= d6) return vertexResult(c, 2); // region C

            const vb = d5 * d2 - d1 * d6;
            if (vb <= 0 and d2 >= 0 and d6 <= 0) { // region AC
                const denom = d2 - d6; // = |ac|²
                if (denom > 0) {
                    const w = d2 / denom;
                    return edgeResult(a.add(ac.scale(w)), 0, 2, 1 - w, w);
                }
                return vertexResult(a, 0); // a == c
            }

            const va = d3 * d6 - d5 * d4;
            if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) { // region BC
                const denom = (d4 - d3) + (d5 - d6); // = |bc|²
                if (denom > 0) {
                    const w = (d4 - d3) / denom;
                    return edgeResult(b.add(c.sub(b).scale(w)), 1, 2, 1 - w, w);
                }
                return vertexResult(b, 1); // b == c
            }

            // Face region.
            const denom_sum = va + vb + vc;
            if (!(denom_sum > 0)) return minOverEdges3(a, b, c); // degenerate triangle
            const inv = 1.0 / denom_sum;
            const v = vb * inv;
            const w = vc * inv;
            return faceResult(a.add(ab.scale(v)).add(ac.scale(w)), 0, 1, 2, 1 - v - w, v, w);
        }

        /// Closest point to the origin on the tetrahedron `a`–`b`–`c`–`d`
        /// (Ericson RTCD §5.1.6, P = origin). Each face the origin lies outside
        /// of is reduced via `closestOriginTriangle` and the nearest kept (fixed
        /// face order, strict `<` so the first wins on ties). If the origin is
        /// inside every face it is inside the tetrahedron → closest is the origin
        /// and all four vertices survive (the GJK "deep" signal). A degenerate
        /// (coplanar) tetrahedron that reaches the interior branch falls back to
        /// the closest of its four faces.
        pub fn closestOriginTetra(a: Vec3T, b: Vec3T, c: Vec3T, d: Vec3T) Result {
            const verts = [4]Vec3T{ a, b, c, d };
            var best: ?Result = null;
            var best_sq: T = undefined;
            inline for (tetra_faces) |f| {
                const v0 = verts[f.tri[0]];
                const v1 = verts[f.tri[1]];
                const v2 = verts[f.tri[2]];
                if (pointOutsidePlane(v0, v1, v2, verts[f.ref])) {
                    const r = remap(closestOriginTriangle(v0, v1, v2), f.tri);
                    const sq = r.closest.dot(r.closest);
                    if (best == null or sq < best_sq) {
                        best = r;
                        best_sq = sq;
                    }
                }
            }
            if (best) |br| return br;

            // Origin inside every face ⇒ inside the tetrahedron.
            const bary_det = tripleProduct(b.sub(a), c.sub(a), d.sub(a));
            // Relative degeneracy: `bary_det` = 6·signed volume (length³). A
            // near-flat tetrahedron falls back to its faces (count ≤ 3, so it
            // never yields a spurious `.deep`). Compared squared to avoid a
            // sqrt: `|bary_det|² ≤ deg_rel² · (max squared edge)³`.
            const deg_rel: T = if (T == f32) 1.0e-4 else 1.0e-9;
            const mes = maxEdgeSq(a, b, c, d);
            if (bary_det * bary_det <= deg_rel * deg_rel * mes * mes * mes) return minOverFaces4(verts);
            const inv = 1.0 / bary_det;
            return .{
                .closest = Vec3T.zero,
                .count = 4,
                .indices = .{ 0, 1, 2, 3 },
                .bary = .{
                    tripleProduct(b, c, d) * inv,
                    tripleProduct(a.neg(), c.sub(a), d.sub(a)) * inv,
                    tripleProduct(b.sub(a), a.neg(), d.sub(a)) * inv,
                    tripleProduct(b.sub(a), c.sub(a), a.neg()) * inv,
                },
            };
        }

        // --- internal helpers ---

        /// The four faces of a tetrahedron `(a,b,c,d)` as `{ triangle vertices,
        /// opposite reference vertex }`, indices into `{a,b,c,d}` — Ericson's
        /// winding (RTCD §5.1.6).
        const tetra_faces = [4]struct { tri: [3]u8, ref: u8 }{
            .{ .tri = .{ 0, 1, 2 }, .ref = 3 },
            .{ .tri = .{ 0, 2, 3 }, .ref = 1 },
            .{ .tri = .{ 0, 3, 1 }, .ref = 2 },
            .{ .tri = .{ 1, 3, 2 }, .ref = 0 },
        };

        /// Whether the origin lies on the opposite side of plane `(a,b,c)` from
        /// the reference vertex `ref` (i.e. outside that tetra face). Sign-product
        /// test, orientation-independent; a coplanar reference (`signd == 0`)
        /// reports "not outside" and is handled by the caller's fall-back.
        fn pointOutsidePlane(a: Vec3T, b: Vec3T, c: Vec3T, ref: Vec3T) bool {
            const n = b.sub(a).cross(c.sub(a));
            const signp = a.neg().dot(n); // (origin − a)·n
            const signd = ref.sub(a).dot(n);
            return signp * signd < 0;
        }

        /// Scalar triple product `u · (v × w)` = det[u v w].
        fn tripleProduct(u: Vec3T, v: Vec3T, w: Vec3T) T {
            return u.dot(v.cross(w));
        }

        /// Largest squared edge length of the tetrahedron `(a,b,c,d)` — the
        /// characteristic length² used to make the degeneracy test scale-relative.
        fn maxEdgeSq(a: Vec3T, b: Vec3T, c: Vec3T, d: Vec3T) T {
            const edges = [_]Vec3T{ b.sub(a), c.sub(a), d.sub(a), c.sub(b), d.sub(b), d.sub(c) };
            var m: T = 0;
            for (edges) |e| m = @max(m, e.dot(e));
            return m;
        }

        /// Closest of the three edges of a degenerate triangle to the origin
        /// (fixed order AB, BC, CA; strict `<` — first wins). Indices remapped
        /// to the triangle's own `{0,1,2}`.
        fn minOverEdges3(a: Vec3T, b: Vec3T, c: Vec3T) Result {
            var best = remap(closestOriginSegment(a, b), .{ 0, 1, 0 });
            var best_sq = best.closest.dot(best.closest);
            const bc = remap(closestOriginSegment(b, c), .{ 1, 2, 0 });
            const bc_sq = bc.closest.dot(bc.closest);
            if (bc_sq < best_sq) {
                best = bc;
                best_sq = bc_sq;
            }
            const ca = remap(closestOriginSegment(c, a), .{ 2, 0, 0 });
            if (ca.closest.dot(ca.closest) < best_sq) best = ca;
            return best;
        }

        /// Closest of the four faces of a degenerate tetrahedron to the origin
        /// (fixed face order, strict `<`). Indices remapped to `{0,1,2,3}`.
        fn minOverFaces4(verts: [4]Vec3T) Result {
            var best: ?Result = null;
            var best_sq: T = undefined;
            inline for (tetra_faces) |f| {
                const r = remap(closestOriginTriangle(verts[f.tri[0]], verts[f.tri[1]], verts[f.tri[2]]), f.tri);
                const sq = r.closest.dot(r.closest);
                if (best == null or sq < best_sq) {
                    best = r;
                    best_sq = sq;
                }
            }
            return best.?;
        }

        /// Remap a sub-result's surviving indices through `map` (source index →
        /// parent index). Closest / count / bary are unchanged.
        fn remap(r: Result, map: [3]u8) Result {
            var out = r;
            for (0..r.count) |i| out.indices[i] = map[r.indices[i]];
            return out;
        }

        fn vertexResult(p: Vec3T, i: u8) Result {
            return .{ .closest = p, .count = 1, .indices = .{ i, 0, 0, 0 }, .bary = .{ 1, 0, 0, 0 } };
        }

        fn edgeResult(p: Vec3T, ia: u8, ib: u8, wa: T, wb: T) Result {
            return .{ .closest = p, .count = 2, .indices = .{ ia, ib, 0, 0 }, .bary = .{ wa, wb, 0, 0 } };
        }

        fn faceResult(p: Vec3T, ia: u8, ib: u8, ic: u8, wa: T, wb: T, wc: T) Result {
            return .{ .closest = p, .count = 3, .indices = .{ ia, ib, ic, 0 }, .bary = .{ wa, wb, wc, 0 } };
        }
    };
}

/// Named iteration ceiling for the GJK descent (brief Notes, anticipates the
/// M1.1.14 determinism freeze): the loop always terminates within this many
/// support queries. 32 is generous — a well-formed pair converges in a handful;
/// the bound only backstops adversarial near-parallel configurations.
pub const max_gjk_iterations: u32 = 32;

/// The three-regime GJK outcome (`engine-physics-forge.md` §1). `status`
/// discriminates which fields are meaningful:
///  - `.separated` / `.shallow`: `distance` (core distance) and `closest_a` /
///    `closest_b` (the closest points on each core, **world** space) are valid;
///    `simplex_count` is 0.
///  - `.deep`: `simplex[0..simplex_count]` is the terminal origin-enclosing
///    simplex — the EPA seed for M1.1.3; `distance` is 0 and the closest points
///    are unspecified. No depth / normal is computed here (that is M1.1.3).
pub fn GjkResult(comptime T: type) type {
    return struct {
        const Vec3T = math.Vec(3, T);

        /// Which regime the pair is in (see the type doc). The plan's
        /// touch/no-touch is `status != .separated`.
        pub const Status = enum { separated, shallow, deep };
        /// The simplex-vertex triplet stored for the `.deep` EPA seed.
        pub const Vertex = Simplex(T).Vertex;

        /// The regime.
        status: Status,
        /// Core distance (`.separated`/`.shallow`); 0 for `.deep`.
        distance: T,
        /// Closest point on A's core, world space (`.separated`/`.shallow`).
        closest_a: Vec3T,
        /// Closest point on B's core, world space (`.separated`/`.shallow`).
        closest_b: Vec3T,
        /// Terminal origin-enclosing simplex (`.deep`; entries `[0..simplex_count]`).
        simplex: [4]Vertex,
        /// Number of valid `simplex` entries (`.deep`: 1..4; otherwise 0).
        simplex_count: u8,
    };
}

/// Distance-based GJK between the **cores** of `shape_a` and `shape_b` at their
/// world poses. Runs in the frame of A (B pre-transformed via `RelativePose`),
/// descending on the Minkowski difference `support_A(d) − support_B(−d)` toward
/// the origin with the E2 Voronoi solver. The search direction is never
/// normalized — squared distances throughout, a single `sqrt` for the reported
/// distance (brief Notes). See the file header for the cores + inflation model
/// and the frozen frame-of-A choice.
///
/// Classification (brief Notes): if the terminal simplex encloses the origin the
/// cores intersect → `.deep`; otherwise the converged core distance `dist` gives
/// `.separated` iff `dist² > (r_a + r_b)²` strictly, else `.shallow` (exact
/// inflated touch, `dist == r_a + r_b`, counts as shallow).
pub fn gjk(
    comptime T: type,
    shape_a: SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) GjkResult(T) {
    const Vec3T = math.Vec(3, T);
    const VertexT = Simplex(T).Vertex;
    const Res = GjkResult(T);

    // Named tolerances — all RELATIVE, no absolute distance threshold, so the
    // classification is scale-robust. `rel_tolerance`: the squared-distance
    // progress test. `dup_rel_sq`: a support duplicates an existing simplex
    // vertex (anti-cycling), relative to the simplex magnitude². `rel_deep`:
    // origin reached on the simplex ⇒ deep, relative to the simplex magnitude.
    // `contact_rel`: shallow/separated boundary margin — GJK distance is
    // approximate, so an exact tangency must not tip into `.separated` (the
    // frozen touch = shallow rule).
    const rel_tolerance: T = if (T == f32) 1.0e-5 else 1.0e-10;
    const dup_rel_sq: T = if (T == f32) 1.0e-10 else 1.0e-20;
    const rel_deep: T = if (T == f32) 1.0e-4 else 1.0e-7;
    const contact_rel: T = if (T == f32) 1.0e-4 else 1.0e-9;

    const relpose = RelativePose(T).init(pos_a, rot_a, pos_b, rot_b);

    // Seed the search from the relative position; fixed fallback if degenerate
    // (coincident origins) — a fixed fallback keeps the walk deterministic.
    var dir = relpose.pos_rel;
    if (dir.dot(dir) <= 0) dir = Vec3T.unit_x;

    var verts: [4]VertexT = undefined;
    verts[0] = minkowskiSupport(T, shape_a, relpose, shape_b, dir);
    var count: usize = 1;
    var closest = verts[0].w;
    var bary: [4]T = .{ 1, 0, 0, 0 };

    var iter: u32 = 0;
    while (iter < max_gjk_iterations) : (iter += 1) {
        // Origin reached on the current simplex (relative to its magnitude) ⇒
        // cores intersect ⇒ deep.
        if (originEnclosed(T, verts[0..count], closest, rel_deep)) return deepResult(T, verts, count);

        const w = minkowskiSupport(T, shape_a, relpose, shape_b, closest.neg());

        // Progress test (relative, squared distance): `vv − v·w ≥ 0` for the
        // closest point `v`; when it is negligible the support in direction −v
        // no longer pushes past the plane through v, so v is the closest point.
        const vv = closest.dot(closest);
        if (vv - closest.dot(w.w) <= rel_tolerance * vv) break;

        // Anti-cycling (standard GJK guard): a support duplicating a simplex
        // vertex — within a tolerance relative to the simplex magnitude — means
        // no further progress. Kills at the source the degenerate tetrahedra the
        // floating-point progress test alone can let through.
        if (duplicateSupport(T, verts[0..count], w.w, dup_rel_sq)) break;

        verts[count] = w;
        count += 1;

        const res = closestOnSimplex(T, verts[0..count]);
        closest = res.closest;
        // Reduce the simplex to the surviving feature, carrying the barycentrics.
        var reduced: [4]VertexT = undefined;
        for (0..res.count) |i| reduced[i] = verts[res.indices[i]];
        for (0..res.count) |i| {
            verts[i] = reduced[i];
            bary[i] = res.bary[i];
        }
        count = res.count;

        // Origin strictly inside the (non-degenerate, cf. `closestOriginTetra`)
        // tetrahedron, or reached on a lower feature (relative test) ⇒ deep.
        if (res.count == 4 or originEnclosed(T, verts[0..count], closest, rel_deep)) return deepResult(T, verts, count);
    }

    // Converged (or hit the iteration bound): reconstruct the closest point on
    // each core in A's frame from the barycentrics, then map to world. Distances
    // are preserved by the rigid map, so `|closest_a − closest_b| == dist`.
    var ca = Vec3T.zero;
    var cb = Vec3T.zero;
    for (0..count) |i| {
        ca = ca.add(verts[i].support_a.scale(bary[i]));
        cb = cb.add(verts[i].support_b.scale(bary[i]));
    }
    const dist_sq = closest.dot(closest);
    // Contact-margin boundary: `.separated` only when the core distance exceeds
    // `r_a + r_b` beyond the relative margin. GJK's distance carries a
    // convergence error, and the frozen convention makes an exact touch shallow.
    const r_sum = shape_a.radius + shape_b.radius;
    const boundary = r_sum * (1 + contact_rel);
    return .{
        .status = if (dist_sq > boundary * boundary) Res.Status.separated else Res.Status.shallow,
        .distance = @sqrt(dist_sq),
        .closest_a = rot_a.rotateVec3(ca).add(pos_a),
        .closest_b = rot_a.rotateVec3(cb).add(pos_a),
        .simplex = emptySimplex(T),
        .simplex_count = 0,
    };
}

// --- GJK internal helpers ---

/// Support point of the Minkowski difference of the two cores in direction
/// `dir` (A's frame): `support_A(dir) − support_B(−dir)`, keeping both supports
/// so the closest points on A and B stay reconstructible.
fn minkowskiSupport(
    comptime T: type,
    shape_a: SupportShape(T),
    relpose: RelativePose(T),
    shape_b: SupportShape(T),
    dir: math.Vec(3, T),
) Simplex(T).Vertex {
    const sa = shape_a.support(dir);
    const sb = relpose.supportB(shape_b, dir.neg());
    return .{ .w = sa.sub(sb), .support_a = sa, .support_b = sb };
}

/// Dispatch the E2 Voronoi solver by simplex size. GJK maintains a 1..4-vertex
/// simplex by construction, so the `else` arm is exactly the tetrahedron.
fn closestOnSimplex(comptime T: type, verts: []const Simplex(T).Vertex) Simplex(T).Result {
    const S = Simplex(T);
    std.debug.assert(verts.len >= 1 and verts.len <= 4);
    return switch (verts.len) {
        1 => S.closestOriginPoint(verts[0].w),
        2 => S.closestOriginSegment(verts[0].w, verts[1].w),
        3 => S.closestOriginTriangle(verts[0].w, verts[1].w, verts[2].w),
        else => S.closestOriginTetra(verts[0].w, verts[1].w, verts[2].w, verts[3].w),
    };
}

/// Largest squared `w`-magnitude across the current simplex — the scale the
/// relative deep / duplicate tests normalize against.
fn maxVertexMagSq(comptime T: type, verts: []const Simplex(T).Vertex) T {
    var m: T = 0;
    for (verts) |v| m = @max(m, v.w.dot(v.w));
    return m;
}

/// Whether the origin lies on the current simplex to within a tolerance
/// relative to the simplex magnitude — the scale-robust "cores intersect"
/// signal. When every vertex is at the origin the threshold is 0, so `.deep`
/// then requires `closest` to be exactly the origin.
fn originEnclosed(comptime T: type, verts: []const Simplex(T).Vertex, closest: math.Vec(3, T), rel_deep: T) bool {
    const mag = maxVertexMagSq(T, verts);
    return closest.dot(closest) <= rel_deep * rel_deep * mag;
}

/// Whether `w` duplicates an existing simplex vertex to within a tolerance
/// relative to the simplex magnitude² — the anti-cycling test.
fn duplicateSupport(comptime T: type, verts: []const Simplex(T).Vertex, w: math.Vec(3, T), dup_rel_sq: T) bool {
    const mag = maxVertexMagSq(T, verts);
    var min_sq: T = std.math.floatMax(T);
    for (verts) |v| {
        const delta = w.sub(v.w);
        const dsq = delta.dot(delta);
        if (dsq < min_sq) min_sq = dsq;
    }
    return min_sq <= dup_rel_sq * mag;
}

/// A `.deep` result carrying the terminal simplex `verts[0..count]` (EPA seed).
/// The unused tail is zeroed so the returned value holds no `undefined`.
fn deepResult(comptime T: type, verts: [4]Simplex(T).Vertex, count: usize) GjkResult(T) {
    var s = emptySimplex(T);
    for (0..count) |i| s[i] = verts[i];
    return .{
        .status = .deep,
        .distance = 0,
        .closest_a = math.Vec(3, T).zero,
        .closest_b = math.Vec(3, T).zero,
        .simplex = s,
        .simplex_count = @intCast(count),
    };
}

/// Four zeroed simplex vertices — the placeholder for the unused `simplex` field
/// on non-deep results and the base for `deepResult`'s copy.
fn emptySimplex(comptime T: type) [4]Simplex(T).Vertex {
    const z = Simplex(T).Vertex{ .w = math.Vec(3, T).zero, .support_a = math.Vec(3, T).zero, .support_b = math.Vec(3, T).zero };
    return .{ z, z, z, z };
}
