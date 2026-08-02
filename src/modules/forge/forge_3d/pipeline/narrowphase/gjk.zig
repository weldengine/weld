//! `forge_3d/pipeline/narrowphase/gjk.zig` — distance-based GJK convex detection.
//!
//! Delivered across M1.1.2: the Voronoi-region simplex solver (`Simplex(T)`),
//! the bounded GJK descent loop (`gjk`), and its three-regime `GjkResult(T)`.
//! The support shapes, relative pose, and `minkowskiSupport` this file consumes
//! live in the sibling `support.zig`; EPA (`epa.zig`) seeds off the `.deep`
//! terminal simplex `GjkResult` carries (M1.1.3).
//!
//! **Dependency discipline (brief Notes).** This file imports `foundation`
//! (math) and the sibling `support.zig` ONLY — never `weld_forge`, never
//! `body*.zig`, never `config.zig`, never `broadphase.zig`. The scalar arrives
//! as the comptime parameter `T`; `forge_3d` instantiates it at `config.Real`.
//! The `Shape → SupportShape` conversion and the `BodyId`-level `gjkPair` adapter
//! live on the forge_3d side, mirroring the broadphase `user_data` discipline.
//!
//! **Cores + inflation radius (Jolt convex-radius architecture).** GJK never
//! sees a curved surface: a sphere is a point, a capsule a segment, a box the
//! full box (radius 0). Support functions therefore run on the convex **core**
//! (`support.zig`); the inflation `radius` is applied only in the touch test
//! (`dist(cores) <= r_a + r_b`). Fast convergence, no simplex degeneracy near
//! contact.
//!
//! **Computation in the frame of A (brief Notes).** B is pre-transformed
//! relative to A once per pair (`support.RelativePose`); A's support runs
//! untransformed. Better precision far from the world origin (avoids
//! large-coordinate cancellation) and half the per-iteration transforms. Frozen
//! now: changing the computation frame after the M1.1.14 determinism freeze
//! would break validated bit-exactness.
//!
//! **Determinism by construction (anticipates M1.1.14).** No hash containers,
//! no trigonometry (dot/cross only), fixed support tie-breaks (see
//! `support.SupportShape.support`).

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");

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

        /// One simplex vertex: a support sample on the Minkowski difference of
        /// the two cores (`w`, `support_a`, `support_b`). Aliases the shared
        /// `support.Vertex(T)` — storing all three (rather than just
        /// `w = support_a − support_b`) lets the GJK loop reconstruct the closest
        /// points on A and B from the barycentric weights:
        /// `closest_a = Σ λ_i · support_a_i`, likewise for B.
        pub const Vertex = support.Vertex(T);

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
            const ab = b.sub(a);
            const ac = c.sub(a);
            const ad = d.sub(a);
            const bary_det = tripleProduct(ab, ac, ad); // 6·signed volume (length³)
            // DIMENSIONLESS degeneracy: `bary_det² / (|ab|²·|ac|²·|ad|²)` is the
            // squared normalized volume (≈ sin² of the solid angle at the
            // reference vertex) — scale- AND aspect-ratio-invariant, so a
            // well-formed but elongated (anisotropic) tetrahedron stays
            // non-degenerate. A `maxEdgeSq³` normalization instead rejected valid
            // anisotropic tetra, making a sharp box's interior read `.separated`
            // (P1d). A genuinely near-flat tetra still falls back to its faces
            // (count ≤ 3, never a spurious `.deep`). Squared form, no sqrt.
            const deg_rel: T = if (T == f32) 1.0e-4 else 1.0e-9;
            const edge_prod = ab.dot(ab) * ac.dot(ac) * ad.dot(ad);
            if (bary_det * bary_det <= deg_rel * deg_rel * edge_prod) return minOverFaces4(verts);
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
///  - `.deep`: `simplex[0..simplex_count]` is the terminal simplex — either an
///    origin-ENCLOSING simplex, OR (M1.1.3-HF RD-4) a terminal within the
///    accumulated-rounding band of the origin (a Minkowski witness at noise
///    distance from the origin, NOT necessarily enclosing) — the EPA seed;
///    `distance` is 0 and the closest points are unspecified. No depth / normal is
///    computed here (that is M1.1.3 / EPA).
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
        /// Terminal `.deep` simplex — origin-enclosing OR the RD-4 rounding-band
        /// terminal (not necessarily enclosing); entries `[0..simplex_count]`.
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
/// `.deep` iff `dist ≤ the contact margin` (the RD-4 witness band, m1.1.3-hf — a
/// Minkowski point at noise distance from the origin; the terminal is NOT
/// necessarily enclosing), `.separated` iff `dist − (r_a + r_b)` exceeds it, else
/// `.shallow`. The contact margin is an absolute float-noise bound
/// `conv_k · floatEps(T) · coordScale` (see the tolerance block). An exact inflated
/// touch (`dist == r_a + r_b`) stays shallow iff `r_sum > contact_margin` — the
/// RD-4 band is evaluated FIRST, so a sub-noise inflation radius
/// (`0 < r_sum <= contact_margin`) classifies deep; benign either way: EPA clamps
/// depth to ~0 and the manifold penetration is ~`r_sum` in both regimes. For hard
/// cores (`r_sum == 0`) the shallow band is empty — an exact touch (`dist == 0`) is
/// the RD-4 deep band.
pub fn gjk(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) GjkResult(T) {
    const Vec3T = math.Vec(3, T);
    const VertexT = Simplex(T).Vertex;
    const Res = GjkResult(T);

    // Named tolerances. `rel_tolerance`: the squared-distance progress test,
    // relative to the closest-point magnitude. `dup_rel_sq`: a support
    // duplicates an existing simplex vertex (anti-cycling), relative to the
    // simplex magnitude².
    //
    // The classification thresholds absorb ONLY floating-point rounding noise —
    // no decision depends on a geometric quantity (radius, shape size, or
    // `w`-vertex magnitude). Both are of the form `k · floatEps(T) · coordScale`,
    // where `coordScale` is the cores' coordinate scale (the ABSOLUTE support
    // magnitude — the scale of the `w = support_a − support_b` rounding error),
    // NEVER `r_sum` nor the `w` magnitude:
    //   - `mach_eps` = `noise_k · floatEps(T)` is the NUMERICAL-NOISE floor for
    //     the degenerate-origin test (`degenerateOriginReached`, floor
    //     `mach_eps² · maxSupportMagSq`). It only catches genuinely degenerate
    //     Minkowski configs (coincident / collinear cores that cannot form a
    //     tetrahedron) whose closest point sits at the origin up to rounding.
    //     `.deep` proper rests on geometric ENCLOSURE (`res.count == 4`, a
    //     non-degenerate origin-containing tetra), never on this floor.
    //   - `conv_k` scales the shallow/separated contact margin below — a
    //     conservative bound on the ACCUMULATED rounding of the GJK pipeline
    //     (quaternion rotate-by-conjugate + Voronoi tetrahedron solve + final
    //     sqrt) on the reported `dist` at the coordinate scale.
    // `noise_k` and `conv_k` are DISTINCT and must not be aligned: `noise_k ≈ 2`
    // ULP is the tight POINT-noise floor (widening it recreates a proximity-as-
    // deep false positive); `conv_k = 16` ULP covers the pipeline's accumulated
    // rounding — an exact tangency's `dist − r_sum` can reach a few ULP × scale
    // with zero convergence residue, which 2 ULP under-dimensions. 16 ULP stays
    // at the noise level (~2e-6 relative in f32) and swallows no discernible
    // separation.
    const rel_tolerance: T = if (T == f32) 1.0e-5 else 1.0e-10;
    const dup_rel_sq: T = if (T == f32) 1.0e-10 else 1.0e-20;
    const noise_k: T = 2;
    const conv_k: T = 16;
    const mach_eps: T = noise_k * std.math.floatEps(T);

    const relpose = support.RelativePose(T).init(pos_a, rot_a, pos_b, rot_b);

    // Seed the search from the relative position; fixed fallback if degenerate
    // (coincident origins) — a fixed fallback keeps the walk deterministic.
    var dir = relpose.pos_rel;
    if (dir.dot(dir) <= 0) dir = Vec3T.unit_x;

    var verts: [4]VertexT = undefined;
    verts[0] = support.minkowskiSupport(T, shape_a, relpose, shape_b, dir);
    var count: usize = 1;
    var closest = verts[0].w;
    var bary: [4]T = .{ 1, 0, 0, 0 };

    var iter: u32 = 0;
    while (iter < max_gjk_iterations) : (iter += 1) {
        // A degenerate Minkowski config whose origin is genuinely reached (e.g.
        // coincident cores whose simplex cannot grow into a tetrahedron) ⇒ deep.
        // This is the numerical-noise early-out, NOT a geometric proximity test.
        if (degenerateOriginReached(T, verts[0..count], closest, mach_eps)) return deepResult(T, verts, count);

        const w = support.minkowskiSupport(T, shape_a, relpose, shape_b, closest.neg());

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

        // Deep by geometric ENCLOSURE: a non-degenerate tetrahedron containing
        // the origin (`res.count == 4`, degeneracy guarded in `closestOriginTetra`)
        // — no distance threshold on this path. The noise early-out additionally
        // covers a degenerate lower feature that reached the origin exactly
        // (coincident / collinear cores that never tetrahedralize).
        //
        // LIMITATION (radius-0 box cores of EXTREME aspect ratio, >~50:1). Sharp,
        // very anisotropic box cores are GJK's worst case in f32: `.deep` for an
        // interior point can be missed (false `.separated`) by two mechanisms —
        // (1) the tetrahedron degeneracy test still trips at extreme anisotropy
        // (P1d makes it dimensionless, robust to moderate ~30:1 anisotropy, not
        // extreme), and (2) the anti-cycling guard above can `break` on a
        // duplicate support before the enclosing tetrahedron forms (near-parallel
        // search directions repeat a corner on a flat box). Reliable to a
        // moderate aspect ratio; beyond it, exact box `.deep` is the domain of the
        // M1.1.4 analytic box/box + point/box fast paths and M1.1.3 EPA. Deferred
        // by scope decision — not chased with generic f32 GJK here (diminishing
        // returns, overlaps EPA, still imperfect in f32).
        if (res.count == 4 or degenerateOriginReached(T, verts[0..count], closest, mach_eps)) return deepResult(T, verts, count);
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
    const dist = @sqrt(closest.dot(closest));
    // Contact-margin boundary: `.separated` only when the core distance exceeds
    // `r_a + r_b` by more than GJK's accumulated rounding on `dist`. The margin is
    // ABSOLUTE — `conv_k · floatEps(T) · coord_scale` — never a fraction of the
    // radius: a radius-proportional margin grows without bound and is a collision
    // margin beyond the core radius, out of scope (§32).
    //
    // `coord_scale` is a SYMMETRIC bound on the coordinate scale the `w = sa − sb`
    // rounding accumulates over: the relative-centre distance plus each core's
    // own extent (radius excluded). It is symmetric under an A/B swap BY
    // CONSTRUCTION (all three terms are), so the classification is order-
    // independent — unlike the terminal simplex's A-frame support magnitude,
    // which after cancellation reflects only who is A and made a tangency read
    // `.separated` in one order and `.shallow` in the other (P1c). The comparison
    // is additive on the already-computed `dist`. It is reached only after the
    // RD-4 band below (`dist <= contact_margin`) did not fire, so the frozen
    // convention keeps an exact inflated touch (`dist == r_sum`) shallow exactly
    // when `r_sum > contact_margin` — a sub-noise `r_sum` is caught deep above.
    const r_sum = shape_a.radius + shape_b.radius;
    const coord_scale = pos_b.sub(pos_a).length() + coreExtent(T, shape_a) + coreExtent(T, shape_b);
    const contact_margin = conv_k * std.math.floatEps(T) * coord_scale;
    // RD-4 — deep band (m1.1.3-hf, C′). A terminal within `contact_margin` of the
    // ORIGIN is a POSITIVE witness of enclosure: a Minkowski point at noise
    // distance from the origin ⇒ the cores touch to measurement precision ⇒ the
    // deep regime by definition. This holds at EVERY loop exit — the progress-test
    // break, the anti-cycling duplicate break, and the iteration bound — so a
    // single post-loop test covers all three (a convergence stall can leave a
    // NON-enclosing terminal ~2.66·floatEps·scale from the origin, above the
    // `degenerateOriginReached` noise floor, which then read `.shallow` at dist ≈ 0
    // on a genuinely-deep overlap: the arm64 f32-unit / f64-×0.01 stall). The
    // margin REUSES `contact_margin` in its existing role — the accumulated
    // `dist`-rounding bound — applied to the origin-side boundary of the SAME
    // classification; `noise_k` (the distinct in-loop point-noise floor) is
    // UNTOUCHED, so the P1b/P2 calibration is preserved. `coord_scale` is symmetric
    // under an A/B swap by construction (see above), so the band is
    // order-independent. Three bands result: `[0, m]` deep, `(m, r_sum + m]`
    // shallow, beyond `r_sum + m` separated — the inflated touch `dist == r_sum`
    // stays shallow IFF `r_sum > m` (the `[0, m]` deep band is checked FIRST, so a
    // sub-noise radius `0 < r_sum <= m` lands the touch in the deep band); for
    // `r_sum == 0` the `[0, m]` band absorbs `dist == 0` (hard cores want EPA's MTV,
    // not a pen ≈ 0 witness). Benign either way — EPA clamps depth to ≈ 0 and the
    // manifold penetration is ≈ r_sum in both regimes. A false-deep on a true
    // near-touch (`dist ∈ (0, m]`, cores actually disjoint) seeds EPA from a
    // non-enclosing terminal → depth clamps to 0 → manifold penetration
    // `r_sum − 0`, the former shallow result to within ε — safe.
    if (dist <= contact_margin) return deepResult(T, verts, count);
    return .{
        .status = if (dist - r_sum > contact_margin) Res.Status.separated else Res.Status.shallow,
        .distance = dist,
        .closest_a = rot_a.rotateVec3(ca).add(pos_a),
        .closest_b = rot_a.rotateVec3(cb).add(pos_a),
        .simplex = emptySimplex(T),
        .simplex_count = 0,
    };
}

// --- GJK internal helpers ---

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
/// anti-cycling duplicate test normalizes against (the Minkowski points are
/// compared to one another, so their own magnitude is the right scale).
fn maxVertexMagSq(comptime T: type, verts: []const Simplex(T).Vertex) T {
    var m: T = 0;
    for (verts) |v| m = @max(m, v.w.dot(v.w));
    return m;
}

/// A core's maximal local support magnitude, radius EXCLUDED: 0 for a point
/// (sphere), the half-height for a segment (capsule), `|half_extents|` for a
/// box. Summed over both cores plus the relative-centre distance, it forms the
/// SYMMETRIC coordinate-scale bound for the contact margin (`gjk`), so the
/// shallow/separated decision is invariant under an A/B swap.
fn coreExtent(comptime T: type, shape: support.SupportShape(T)) T {
    return switch (shape.core) {
        .point => 0,
        .segment => |half_height| half_height,
        .box => |half_extents| half_extents.length(),
        // A triangle's core extent is its furthest vertex from the local origin — the same
        // quantity as a box's `|half_extents|`, read off three explicit points instead of
        // a symmetry. Note it is NOT the edge length: what this bounds is the coordinate
        // scale of the support subtraction, which a triangle far from its own local origin
        // has regardless of how small it is.
        .triangle => |verts| @max(@max(verts[0].length(), verts[1].length()), verts[2].length()),
    };
}

/// Largest squared ABSOLUTE support magnitude across the current simplex — the
/// coordinate scale of the `w = support_a − support_b` subtraction, hence the
/// scale of its floating-point rounding error. This is the scale the
/// numerical-noise deep test normalizes against — deliberately NOT
/// `maxVertexMagSq` (the `w` magnitude): a large shape whose face is far from
/// the origin has a large `w` magnitude, so a `w`-relative threshold would
/// mistake mere proximity to that distant face for an enclosure (the residual
/// Fix 3b removes).
fn maxSupportMagSq(comptime T: type, verts: []const Simplex(T).Vertex) T {
    var m: T = 0;
    for (verts) |v| {
        m = @max(m, v.support_a.dot(v.support_a));
        m = @max(m, v.support_b.dot(v.support_b));
    }
    return m;
}

/// Whether the origin is reached on the current simplex to within numerical
/// NOISE (≈ machine epsilon scaled by the absolute support magnitude) — the
/// scale-robust signal for a degenerate Minkowski config that cannot be
/// tetrahedralized yet does contain the origin (coincident / collinear cores).
/// This is deliberately NOT a geometric tolerance: genuine intersection is
/// decided by enclosure (`res.count == 4`), never by this test. When every
/// support sits at the origin the scale is 0, so the test then requires
/// `closest` to be exactly the origin.
fn degenerateOriginReached(comptime T: type, verts: []const Simplex(T).Vertex, closest: math.Vec(3, T), mach_eps: T) bool {
    const scale_sq = maxSupportMagSq(T, verts);
    return closest.dot(closest) <= mach_eps * mach_eps * scale_sq;
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
