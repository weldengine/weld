//! `forge_3d/pipeline/narrowphase/epa.zig` — EPA (Expanding Polytope Algorithm):
//! the penetration axis + core depth of a `.deep` pair.
//!
//! Runs on the convex **cores** in A's frame (radius excluded, same Minkowski
//! support as GJK — reuses `support.minkowskiSupport`), seeded off the GJK
//! terminal `.deep` simplex. The polytope is a fixed-capacity face list expanded
//! toward the origin-closest face until a support in that face's normal no longer
//! advances the surface; the closest face then gives the penetration normal, the
//! core depth, and (via the terminal face barycentrics, exactly like GJK) the
//! world closest points. Depth/normal here are on the CORES; the inflation radii
//! and per-point depth are applied downstream by the manifold generator.
//!
//! **Frame of A + world mapping (brief Notes).** EPA computes in A's frame, then
//! maps the normal and closest points to world via `rot_a` / `pos_a` (the GJK
//! closest-point pattern, `gjk.zig`). The signature therefore carries `pos_a` /
//! `rot_a` in addition to the frozen `relpose` (see the brief RD-2): the frozen
//! `EpaResult` fields are documented world-space "mapped via rot_a", which is not
//! expressible without them.
//!
//! **Low-dimensional seeds (brief flag-6 contract).** A `simplex_count < 4` seed
//! (coincident cores, point-on-segment, crossing segments) is tetra-expanded to a
//! non-degenerate origin-enclosing tetrahedron before the loop. When the
//! Minkowski difference is genuinely < 3-D (the cores touch along a point / line /
//! plane — a zero core penetration), no tetra exists; EPA returns the best
//! lower-dimensional feature: a unit separation normal and depth 0 (the deep↔
//! shallow boundary; the manifold's deep depth is then `0 + r_sum`).
//!
//! **Dependency discipline (brief Notes).** Imports `foundation` (math) + the
//! sibling `support.zig` / `gjk.zig` ONLY. Determinism by construction: no hash
//! containers, no trigonometry (dot/cross only), fixed face-evaluation order,
//! bounded iterations (`max_epa_iterations`), every division guarded (never a NaN;
//! `normalize` in `foundation/math` is unguarded — all divisions here are guarded).

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");
const gjk_mod = @import("gjk.zig");

/// Named iteration ceiling for the EPA expansion (brief Notes, anticipates the
/// M1.1.14 determinism freeze): the loop always terminates within this many
/// support queries. A well-formed penetration converges in a handful; the bound
/// backstops adversarial near-tangent configurations.
pub const max_epa_iterations: u32 = 32;

/// EPA outcome — the penetration on the **cores**, world space:
///  - `normal`: unit, world, A→B (the axis to translate B along to separate).
///  - `depth`: core penetration ≥ 0 (origin-to-closest-face distance on the
///    Minkowski difference of the cores; the inflation `r_sum` is added by the
///    manifold generator, not here).
///  - `closest_a` / `closest_b`: the closest points on A's / B's cores, world
///    space, reconstructed from the terminal face barycentrics (as GJK does).
pub fn EpaResult(comptime T: type) type {
    return struct {
        normal: math.Vec(3, T),
        depth: T,
        closest_a: math.Vec(3, T),
        closest_b: math.Vec(3, T),
    };
}

/// Optional diagnostics for a single `epa()` call (brief E2(g)) — a test/tooling
/// seam, NOT part of the frozen `EpaResult` contract. Written only when a non-null
/// pointer is passed; `epa` holds no retained state otherwise (M1.1.14
/// no-hidden-state / M1.1.8 island-parallel-safe). The production call site
/// (`collideOrderedGeneric`) passes `null`.
pub const EpaDiagnostics = struct {
    /// How the expansion terminated.
    pub const Exit = enum {
        /// A face proved convergence (its support did not advance past its plane).
        converged,
        /// `max_epa_iterations` reached; returned the best non-skipped face.
        iteration_cap,
        /// Every face was skipped; returned the realizable fallback candidate.
        fallback_exhausted,
        /// A `< 3-D` Minkowski difference (`expandToTetra`/initial-tetra failed).
        degenerate_low_dim,
        /// The defensive non-`.deep` seed path (`simplex_count == 0`).
        defensive_non_deep_seed,
    };
    exit: Exit,
    /// Expansion loop iterations executed.
    iterations: u32,
    /// Number of skip events (a face excluded from selection for non-convergence).
    faces_skipped: u32,
    /// Whether the exhaustion fallback (not any face's distance) produced the result.
    fallback_used: bool,
};

/// One polytope face over the Minkowski difference of the cores: three vertex
/// indices (CCW as seen from outside), the outward unit normal (away from the
/// enclosed origin), and the origin-to-plane distance (`normal · vertex`, ≥ 0).
fn Face(comptime T: type) type {
    return struct {
        a: u32,
        b: u32,
        c: u32,
        normal: math.Vec(3, T),
        dist: T,
    };
}

// Fixed capacities (allocation-free, determinism by construction). A closed
// triangulated convex polytope has F = 2V − 4 faces; each iteration adds one
// vertex, so V ≤ 4 + iterations and F ≤ 2V − 4. The buffers are sized generously
// above those bounds to absorb transient counts during re-triangulation.
const max_verts: usize = 4 + max_epa_iterations; // 36
const max_faces: usize = 4 * max_epa_iterations; // 128 (> 2·36 − 4 = 68)
const max_silhouette: usize = 4 * max_epa_iterations; // 128

// Coplanar-tolerance factor for `expandPolytope` visibility (brief E2(a)). A
// support within `vis_k · floatEps(T) · loop_scale` of a face's plane counts as
// beyond it — so a support COPLANAR-within-noise with faces it should replace
// removes them instead of stranding stale interior faces (the S1 depth-0
// corruption). Bounds only float noise at the polytope coordinate scale; a
// distinct constant from the surface-convergence tolerance `rel`, matching the
// gjk.zig `conv_k` magnitude.
const vis_k = 16;

// Coplanarity factor for `terminalFace` (brief E2 / Codex P3): a candidate face
// whose normal has `n·n_sel >= 1 - term_k·floatEps(T)` counts as on the SAME plane
// as the converged/selected face. Coplanar re-fan triangles differ only by
// per-triangle normalization noise (a few ULP), far inside this band; a genuinely
// distinct contact plane differs by a real angle and is rejected. Bounds float
// noise only.
const term_k = 64;

/// Realizable-fallback accumulator (brief E2(e)): the minimum-depth supporting
/// hyperplane seen across the expansion's support queries. Each recorded
/// candidate `(n, d = support(n)·n)` defines a supporting plane of the Minkowski
/// difference, so `d` is a conservative (≥ true) penetration depth along a valid
/// separation axis — never the S1 under-estimate of a corrupt interior face.
/// `consider` keeps the strict minimum, first-wins on ties (deterministic).
/// Extracted as a struct so E2(h) can unit-test the selection rule directly.
fn Fallback(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = math.Vec(3, T);
        have: bool = false,
        d: T = 0,
        n: Vec3T = Vec3T.unit_x,
        sa: Vec3T = Vec3T.zero,
        sb: Vec3T = Vec3T.zero,

        fn consider(self: *Self, d: T, n: Vec3T, sa: Vec3T, sb: Vec3T) void {
            if (!self.have or d < self.d) {
                self.have = true;
                self.d = d;
                self.n = n;
                self.sa = sa;
                self.sb = sb;
            }
        }
    };
}

/// EPA on the cores of `shape_a`/`shape_b` at their world poses, seeded from the
/// GJK terminal `.deep` simplex. Computes in A's frame (B via `relpose`), maps
/// the result to world via `rot_a`/`pos_a`. See the file header for the frame,
/// the low-dimensional-seed contract, and determinism. `rot_b` (B's world
/// rotation, exact input bits) is consumed ONLY by the point⊖segment degenerate
/// branch (E3): it derives the world normal intrinsically from the segment
/// owner's rotation so the two call orders bit-negate — a quantity `relpose`
/// (which folds in `conj(rot_a)`) cannot reproduce bit-exactly.
pub fn epa(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
    rot_b: math.Quat(T),
    seed: gjk_mod.GjkResult(T),
    diag: ?*EpaDiagnostics,
) EpaResult(T) {
    const Vec3T = math.Vec(3, T);
    const VertexT = support.Vertex(T);
    const FaceT = Face(T);

    // --- Seed vertices from the terminal simplex ---
    var verts: [max_verts]VertexT = undefined;
    var vcount: usize = seed.simplex_count;
    if (vcount == 0) {
        // Not a deep seed (defensive: `epa` is only called on `.deep`). Return a
        // zero-penetration result along a fixed axis rather than read undefined.
        writeDiag(diag, .defensive_non_deep_seed, 0, 0, false);
        return degenerateFixedAxis(T, shape_a, rot_a, pos_a, relpose, shape_b);
    }
    for (0..vcount) |i| verts[i] = seed.simplex[i];

    // Squared tolerance for the seed tetra-expansion (distinct / off-plane
    // vertex tests) — relative to the seed's coordinate scale (the absolute
    // support magnitude). The loop tolerances are recomputed post-expansion.
    const rel: T = if (T == f32) 1.0e-4 else 1.0e-10;
    const seed_tol = rel * polytopeScale(T, verts[0..vcount]);
    const tol_sq = seed_tol * seed_tol;

    // --- Expand a low-dimensional seed to a non-degenerate tetrahedron ---
    if (!expandToTetra(T, shape_a, relpose, shape_b, &verts, &vcount, tol_sq)) {
        writeDiag(diag, .degenerate_low_dim, 0, 0, false);
        return degenerateResult(T, shape_a, rot_a, pos_a, relpose, shape_b, rot_b, verts[0..vcount]);
    }

    // Interior reference point (the tetra centroid), strictly inside the
    // non-degenerate seed tetra — used to orient the four INITIAL faces outward
    // (see `makeFace`). Fan faces inherit their winding from the horizon instead,
    // so the interior is not consulted during expansion.
    var interior = Vec3T.zero;
    for (0..vcount) |i| interior = interior.add(verts[i].w);
    interior = interior.scale(1.0 / @as(T, @floatFromInt(vcount)));

    // Recompute the tolerances from the expanded polytope's coordinate scale
    // (the seed's scale can be 0 for an origin-coincident low-dim seed; the
    // expanded tetra always has real extent).
    const loop_scale = polytopeScale(T, verts[0..vcount]);
    const loop_tol = rel * loop_scale;
    const loop_tol_sq = loop_tol * loop_tol;
    // Coplanar-tolerant visibility margin (brief E2(a)); bounds float noise only.
    const vis_eps: T = vis_k * std.math.floatEps(T) * loop_scale;

    // --- Build the initial tetrahedron faces ---
    var faces: [max_faces]FaceT = undefined;
    var fcount: usize = 0;
    const tetra = [4][3]u32{ .{ 0, 1, 2 }, .{ 0, 1, 3 }, .{ 0, 2, 3 }, .{ 1, 2, 3 } };
    for (tetra) |t| {
        if (makeFace(T, &verts, t[0], t[1], t[2], interior)) |f| {
            faces[fcount] = f;
            fcount += 1;
        }
    }
    if (fcount < 4) {
        // A degenerate seed tetra (collinear/coplanar 4th vertex slipped through).
        writeDiag(diag, .degenerate_low_dim, 0, 0, false);
        return degenerateResult(T, shape_a, rot_a, pos_a, relpose, shape_b, rot_b, verts[0..vcount]);
    }

    // --- Expanding-polytope loop (brief E2(d)/(e)/(f)) ---
    // Convergence is tested FIRST and is the ONLY path that returns a face's
    // polytope distance as the depth. A face that hits a non-convergence event —
    // the support duplicates an existing vertex, the transactional expansion
    // fails, or `max_verts` is reached — is marked SKIPPED (excluded from
    // selection, topology untouched) and the loop retries the next-closest
    // non-skipped face; it NEVER returns that face's distance. A successful
    // expansion rebuilds the face list, so the index-keyed skip marks are REMAPPED
    // in lockstep with the compaction (a kept face keeps its flag). Every support
    // query records a realizable fallback candidate; on exhaustion
    // (no selectable face) the minimum-depth candidate is returned instead of any
    // rejected face's distance.
    var skipped: [max_faces]bool = undefined;
    @memset(skipped[0..fcount], false);
    var faces_skipped: u32 = 0;
    var fb: Fallback(T) = .{};

    var converged: ?FaceT = null;
    var iter: u32 = 0;
    while (iter < max_epa_iterations) : (iter += 1) {
        const sel = closestNonSkipped(T, faces[0..fcount], skipped[0..fcount]) orelse break;
        const best = faces[sel];

        const w = support.minkowskiSupport(T, shape_a, relpose, shape_b, best.normal);
        const d = w.w.dot(best.normal);
        // Realizable fallback candidate: {x · best.normal = d} is a supporting
        // hyperplane of the Minkowski difference, so `d` is a conservative depth.
        fb.consider(d, best.normal, w.support_a, w.support_b);

        // Converged: the support does not advance past the plane beyond noise.
        if (d - best.dist <= loop_tol) {
            converged = best;
            break;
        }
        // Non-convergence: this face cannot advance the polytope → skip it.
        if (duplicate(T, verts[0..vcount], w.w, loop_tol_sq) or vcount >= max_verts) {
            skipped[sel] = true;
            faces_skipped += 1;
            continue;
        }
        // Transactional expansion remaps the skip flags in lockstep with the face
        // compaction (kept faces keep their flag, new fan faces start fresh), so a
        // face that failed duplicate-progress STAYS skipped rather than being
        // resurrected to re-fail identically — its support/dist are unchanged since
        // vertices are only ever appended (Codex P2).
        if (!expandPolytope(T, &verts, &vcount, &faces, &fcount, skipped[0..], w, sel, vis_eps)) {
            skipped[sel] = true;
            faces_skipped += 1;
        }
    }

    if (converged) |sel| {
        writeDiag(diag, .converged, iter, faces_skipped, false);
        const term = terminalFace(T, verts[0..vcount], faces[0..fcount], skipped[0..fcount], sel, loop_tol);
        return reconstructFromFace(T, verts[0..vcount], term, rot_a, pos_a);
    }
    // Not converged: an iteration-cap exit (a non-skipped face still selectable)
    // returns the best terminal face on the selected plane; only true exhaustion
    // (all skipped) falls back.
    if (closestNonSkipped(T, faces[0..fcount], skipped[0..fcount])) |sel_i| {
        writeDiag(diag, .iteration_cap, iter, faces_skipped, false);
        const term = terminalFace(T, verts[0..vcount], faces[0..fcount], skipped[0..fcount], faces[sel_i], loop_tol);
        return reconstructFromFace(T, verts[0..vcount], term, rot_a, pos_a);
    }
    writeDiag(diag, .fallback_exhausted, iter, faces_skipped, true);
    if (fb.have) {
        return worldResult(T, rot_a, pos_a, fb.n, @max(fb.d, 0), fb.sa, fb.sb);
    }
    return worldResult(T, rot_a, pos_a, Vec3T.unit_x, 0, Vec3T.zero, Vec3T.zero);
}

/// Write EPA diagnostics through a caller-owned pointer; a no-op on `null`
/// (brief E2(g) — no retained state when diagnostics are off).
fn writeDiag(diag: ?*EpaDiagnostics, exit: EpaDiagnostics.Exit, iterations: u32, faces_skipped: u32, fallback_used: bool) void {
    if (diag) |p| p.* = .{
        .exit = exit,
        .iterations = iterations,
        .faces_skipped = faces_skipped,
        .fallback_used = fallback_used,
    };
}

/// Squared distance from the origin to a face's triangle (its closest point).
fn triClosestSq(comptime T: type, verts: []const support.Vertex(T), f: Face(T)) T {
    const tri = gjk_mod.Simplex(T).closestOriginTriangle(verts[f.a].w, verts[f.b].w, verts[f.c].w);
    return tri.closest.dot(tri.closest);
}

/// The terminal face to reconstruct from, given the SELECTED converged / cap face
/// `sel`. Among NON-SKIPPED faces COPLANAR with `sel` (normal within
/// `term_k·floatEps(T)` of parallel AND plane distance within `tol` of `sel.dist`),
/// the one whose triangle is genuinely closest to the origin. A flat contact face
/// is split by the re-fan into coplanar triangles that all share the minimal
/// `dist`, but only the one containing the origin's projection yields the true
/// closest point, and picking first-by-index (as `closestNonSkipped` does for
/// expansion) can clamp the reconstructed point to the wrong sub-triangle.
/// Restricting to `sel`'s PLANE (not merely near-minimal distance) guarantees we
/// never adopt a DIFFERENT-normal face that was never proven converged, and never
/// move the depth (a coplanar face shares `sel.dist`). SKIPPED faces are excluded
/// (returning a skipped face's distance is the S1 form E2(d) forbids). Falls back
/// to `sel` when no coplanar candidate is closer (Codex P3). Deterministic (first
/// wins on ties).
fn terminalFace(comptime T: type, verts: []const support.Vertex(T), faces: []const Face(T), skipped: []const bool, sel: Face(T), tol: T) Face(T) {
    const coplanar_min: T = 1 - term_k * std.math.floatEps(T);
    var best = sel;
    var best_c2 = triClosestSq(T, verts, sel);
    for (faces, 0..) |f, i| {
        if (skipped[i]) continue;
        if (f.normal.dot(sel.normal) < coplanar_min) continue; // not coplanar with sel's plane
        if (@abs(f.dist - sel.dist) > tol) continue;
        const c2 = triClosestSq(T, verts, f);
        if (c2 < best_c2) {
            best_c2 = c2;
            best = f;
        }
    }
    return best;
}

/// Reconstruct the world-space `EpaResult` from a terminal face: normal + core
/// depth from the face, closest points from the face barycentrics (as GJK does),
/// all mapped to world via `rot_a`/`pos_a`.
fn reconstructFromFace(comptime T: type, verts: []const support.Vertex(T), best: Face(T), rot_a: math.Quat(T), pos_a: math.Vec(3, T)) EpaResult(T) {
    const Vec3T = math.Vec(3, T);
    const va = verts[best.a];
    const vb = verts[best.b];
    const vc = verts[best.c];
    const tri = gjk_mod.Simplex(T).closestOriginTriangle(va.w, vb.w, vc.w);
    const face_verts = [3]support.Vertex(T){ va, vb, vc };
    var ca = Vec3T.zero;
    var cb = Vec3T.zero;
    for (0..tri.count) |i| {
        const fv = face_verts[tri.indices[i]];
        ca = ca.add(fv.support_a.scale(tri.bary[i]));
        cb = cb.add(fv.support_b.scale(tri.bary[i]));
    }
    return .{
        .normal = rot_a.rotateVec3(best.normal),
        .depth = @max(best.dist, 0),
        .closest_a = rot_a.rotateVec3(ca).add(pos_a),
        .closest_b = rot_a.rotateVec3(cb).add(pos_a),
    };
}

// --- Internal helpers ---

/// Largest absolute support magnitude across the seed — the polytope's coordinate
/// scale for the relative tolerances (the scale of the `w = sa − sb` rounding).
fn polytopeScale(comptime T: type, verts: []const support.Vertex(T)) T {
    var m: T = 0;
    for (verts) |v| {
        m = @max(m, v.support_a.dot(v.support_a));
        m = @max(m, v.support_b.dot(v.support_b));
    }
    return @sqrt(m);
}

/// Build a polytope face from three vertices, wound CCW as seen from outside
/// (outward normal away from the polytope `interior` reference point). Returns
/// null for a sliver (near-zero area) triangle. Orienting away from an interior
/// point — the polytope centroid — rather than away from the origin is what keeps
/// EPA correct when the origin is coplanar with a face (a low-dimensional GJK deep
/// seed, e.g. a point inside a box whose terminal simplex is a triangle through
/// the origin): the ambiguous origin-side test would pick the wrong outward
/// direction and stall on a zero-distance face. The winding is fixed so all faces
/// agree, which the silhouette extraction relies on.
fn makeFace(comptime T: type, verts: *const [max_verts]support.Vertex(T), ia: u32, ib0: u32, ic0: u32, interior: math.Vec(3, T)) ?Face(T) {
    const va = verts[ia].w;
    var ib = ib0;
    var ic = ic0;
    var vb = verts[ib].w;
    var vc = verts[ic].w;
    var n = vb.sub(va).cross(vc.sub(va));
    // Orient outward (away from the interior point); reverse winding to match.
    if (n.dot(va.sub(interior)) < 0) {
        const tmp = ib;
        ib = ic;
        ic = tmp;
        vb = verts[ib].w;
        vc = verts[ic].w;
        n = vb.sub(va).cross(vc.sub(va));
    }
    const len_sq = n.dot(n);
    if (!(len_sq > 0)) return null; // sliver / degenerate triangle
    const inv = 1.0 / @sqrt(len_sq);
    const normal = n.scale(inv);
    // Signed origin-to-plane distance (≥ 0 when the origin is on the interior
    // side, 0 when coplanar); the final depth clamps to ≥ 0.
    return .{ .a = ia, .b = ib, .c = ic, .normal = normal, .dist = normal.dot(va) };
}

/// Build a fan face — a silhouette edge `ia→ib` closed to the new vertex, whose
/// index will be `ic` and whose position is `cpos` (passed explicitly because the
/// transactional expansion validates ALL fan faces BEFORE the vertex is appended,
/// brief E2(c)). PRESERVES the inherited horizon winding: the silhouette edges
/// come from consistently outward-wound removed faces, so `(ia, ib, new)` is
/// already outward-CCW and the fan is winding-consistent with the kept neighbours
/// by construction — no interior sign test, which can flip for a face near-tangent
/// to the interior. Returns null for a sliver (near-collinear) triangle, which
/// aborts the transactional expansion with the polytope observably unmodified.
fn makeWoundFaceAt(comptime T: type, verts: *const [max_verts]support.Vertex(T), ia: u32, ib: u32, ic: u32, cpos: math.Vec(3, T)) ?Face(T) {
    const va = verts[ia].w;
    const n = verts[ib].w.sub(va).cross(cpos.sub(va));
    const len_sq = n.dot(n);
    if (!(len_sq > 0)) return null; // sliver / degenerate triangle
    const normal = n.scale(1.0 / @sqrt(len_sq));
    return .{ .a = ia, .b = ib, .c = ic, .normal = normal, .dist = normal.dot(va) };
}

/// Index of the closest NON-SKIPPED face (minimum `dist`; first wins on ties —
/// deterministic). Null when every face is skipped — the exhaustion signal that
/// drives the realizable fallback (brief E2(d)/(e)). A skipped face is never
/// selected.
fn closestNonSkipped(comptime T: type, faces: []const Face(T), skipped: []const bool) ?usize {
    var best: ?usize = null;
    var best_d: T = 0;
    for (faces, 0..) |f, i| {
        if (skipped[i]) continue;
        if (best == null or f.dist < best_d) {
            best = i;
            best_d = f.dist;
        }
    }
    return best;
}

/// Whether `w` duplicates an existing polytope vertex within `tol_sq` (anti-
/// cycling). Squared distance, no sqrt.
fn duplicate(comptime T: type, verts: []const support.Vertex(T), w: math.Vec(3, T), tol_sq: T) bool {
    for (verts) |v| {
        const dsq = w.sub(v.w).dot(w.sub(v.w));
        if (dsq <= tol_sq) return true;
    }
    return false;
}

/// One EPA expansion step (brief E2(a)/(b)/(c)): re-triangulate so the new
/// support `w` becomes a vertex. COMMIT-ON-SUCCESS — every fan face is validated
/// in scratch first, and the polytope is mutated only if the whole expansion is
/// valid; on ANY failure it is observably UNMODIFIED, so the caller can skip this
/// face and retry another. Steps:
///  (a) visibility with a coplanar tolerance `vis_eps` — a support coplanar
///      within noise removes the face instead of stranding it (the S1 fix);
///  (b) restrict the removal set to the edge-connected component of visible faces
///      containing `closest` (visible by construction), so a relaxed visibility
///      cannot carve a disconnected region into multiple horizon loops (Jolt);
///  (c) fan the component's silhouette to `w`, validating all fan faces first.
/// Returns false (no mutation) when the closest face is not visible, the
/// silhouette is empty, a fan face is a sliver, or the buffers cannot hold it.
/// On commit, `skipped` is remapped in lockstep with the face compaction — a kept
/// face carries its flag to its new index, a new fan face starts unskipped — so a
/// face known to fail is not resurrected (Codex P2).
fn expandPolytope(
    comptime T: type,
    verts: *[max_verts]support.Vertex(T),
    vcount: *usize,
    faces: *[max_faces]Face(T),
    fcount: *usize,
    skipped: []bool,
    w: support.Vertex(T),
    closest: usize,
    vis_eps: T,
) bool {
    const FaceT = Face(T);
    const n = fcount.*;

    // (a) Coplanar-tolerant visibility: `w` at/beyond a face's plane within noise.
    var visible: [max_faces]bool = undefined;
    for (0..n) |fi| {
        const f = faces[fi];
        visible[fi] = w.w.sub(verts[f.a].w).dot(f.normal) >= -vis_eps;
    }
    if (!visible[closest]) return false; // closest is visible by construction; defensive

    // (b) Flood-fill the connected visible component containing `closest` across
    // shared (reversed-twin) edges. Only this component is removed.
    var remove: [max_faces]bool = undefined;
    @memset(remove[0..n], false);
    remove[closest] = true;
    var stack: [max_faces]usize = undefined;
    stack[0] = closest;
    var sp: usize = 1;
    while (sp > 0) {
        sp -= 1;
        const cur = stack[sp];
        const f = faces[cur];
        const edges = [3][2]u32{ .{ f.a, f.b }, .{ f.b, f.c }, .{ f.c, f.a } };
        for (edges) |e| {
            if (faceWithEdge(FaceT, faces[0..n], cur, e[1], e[0])) |nb| {
                if (visible[nb] and !remove[nb]) {
                    remove[nb] = true;
                    stack[sp] = nb;
                    sp += 1;
                }
            }
        }
    }

    // Silhouette: an edge of a removed face whose twin is not itself removed.
    var sil: [max_silhouette][2]u32 = undefined;
    var scount: usize = 0;
    var removed_count: usize = 0;
    for (0..n) |fi| {
        if (!remove[fi]) continue;
        removed_count += 1;
        const f = faces[fi];
        const edges = [3][2]u32{ .{ f.a, f.b }, .{ f.b, f.c }, .{ f.c, f.a } };
        for (edges) |e| {
            const twin = faceWithEdge(FaceT, faces[0..n], fi, e[1], e[0]);
            const twin_removed = if (twin) |ti| remove[ti] else false;
            if (!twin_removed) {
                if (scount >= max_silhouette) return false;
                sil[scount] = e;
                scount += 1;
            }
        }
    }
    if (scount == 0) return false;

    // (c) Validate the whole expansion in scratch BEFORE any mutation.
    if (vcount.* >= max_verts) return false;
    if ((n - removed_count) + scount > max_faces) return false;
    const wi: u32 = @intCast(vcount.*);
    var fan: [max_silhouette]FaceT = undefined;
    for (0..scount) |si| {
        fan[si] = makeWoundFaceAt(T, verts, sil[si][0], sil[si][1], wi, w.w) orelse return false;
    }

    // Commit: compact out removed faces (remapping `skipped` in lockstep — a kept
    // face carries its flag to its new index), append the vertex, append the fan
    // (new faces start unskipped). `nf <= fi` throughout, so the in-place remap
    // never overwrites an unread entry.
    var nf: usize = 0;
    for (0..n) |fi| {
        if (!remove[fi]) {
            faces[nf] = faces[fi];
            skipped[nf] = skipped[fi];
            nf += 1;
        }
    }
    fcount.* = nf;
    verts[vcount.*] = w;
    vcount.* += 1;
    for (0..scount) |si| {
        skipped[fcount.*] = false;
        faces[fcount.*] = fan[si];
        fcount.* += 1;
    }
    return fcount.* >= 4;
}

/// Index of the face containing directed edge `(x, y)`, other than `skip` (null
/// if none). Consistent winding makes an interior edge appear as `(x, y)` in one
/// face and `(y, x)` in its neighbour — so this finds both horizon adjacency
/// (flood-fill) and silhouette twins.
fn faceWithEdge(comptime FaceT: type, faces: []const FaceT, skip: usize, x: u32, y: u32) ?usize {
    for (faces, 0..) |f, fi| {
        if (fi == skip) continue;
        if ((f.a == x and f.b == y) or (f.b == x and f.c == y) or (f.c == x and f.a == y)) return fi;
    }
    return null;
}

/// Progressively add supports to reach a non-degenerate origin-enclosing
/// tetrahedron from a 1..4-vertex seed. Returns false when the Minkowski
/// difference is genuinely < 3-D (no tetra exists) — the caller then returns a
/// degenerate (zero-penetration) result. Blow-up directions are deterministic.
fn expandToTetra(
    comptime T: type,
    shape_a: support.SupportShape(T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
    verts: *[max_verts]support.Vertex(T),
    vcount: *usize,
    tol_sq: T,
) bool {
    const Vec3T = math.Vec(3, T);

    // 1 → 2: a distinct second vertex (a segment).
    if (vcount.* == 1) {
        const dirs = [_]Vec3T{ Vec3T.unit_x, Vec3T.unit_x.neg(), Vec3T.unit_y, Vec3T.unit_y.neg(), Vec3T.unit_z, Vec3T.unit_z.neg() };
        for (dirs) |dir| {
            const w = support.minkowskiSupport(T, shape_a, relpose, shape_b, dir);
            if (w.w.sub(verts[0].w).dot(w.w.sub(verts[0].w)) > tol_sq) {
                verts[1] = w;
                vcount.* = 2;
                break;
            }
        }
        if (vcount.* == 1) return false; // point-like difference
    }

    // 2 → 3: a third vertex off the segment line (a triangle).
    if (vcount.* == 2) {
        const ab = verts[1].w.sub(verts[0].w);
        // Six candidate directions perpendicular to the segment (a base
        // perpendicular and its rotations about the segment), deterministic.
        const p0 = perpAxis(T, ab);
        const p1 = ab.cross(p0); // second perpendicular (right-handed with p0, ab)
        const cands = [_]Vec3T{ p0, p0.neg(), p1, p1.neg(), p0.add(p1), p0.sub(p1) };
        for (cands) |dir| {
            const w = support.minkowskiSupport(T, shape_a, relpose, shape_b, dir);
            if (distToLineSq(T, w.w, verts[0].w, verts[1].w) > tol_sq) {
                verts[2] = w;
                vcount.* = 3;
                break;
            }
        }
        if (vcount.* == 2) return false; // segment-like (1-D) difference
    }

    // 3 → 4: a fourth vertex off the triangle plane (a tetra).
    if (vcount.* == 3) {
        var n = verts[1].w.sub(verts[0].w).cross(verts[2].w.sub(verts[0].w));
        const nl = n.dot(n);
        if (!(nl > 0)) return false; // degenerate seed triangle
        n = n.scale(1.0 / @sqrt(nl));
        inline for (.{ n, n.neg() }) |dir| {
            if (vcount.* == 3) {
                const w = support.minkowskiSupport(T, shape_a, relpose, shape_b, dir);
                const off = w.w.sub(verts[0].w).dot(n); // signed plane distance
                if (off * off > tol_sq) {
                    verts[3] = w;
                    vcount.* = 4;
                }
            }
        }
        if (vcount.* == 3) return false; // planar (2-D) difference
    }

    return vcount.* == 4;
}

/// A unit vector perpendicular to `v` (deterministic: cross with the least-aligned
/// basis axis). Falls back to `+X` for a near-zero `v`.
fn perpAxis(comptime T: type, v: math.Vec(3, T)) math.Vec(3, T) {
    const Vec3T = math.Vec(3, T);
    const a = v.toArray();
    const ax = @abs(a[0]);
    const ay = @abs(a[1]);
    const az = @abs(a[2]);
    const axis = if (ax <= ay and ax <= az) Vec3T.unit_x else if (ay <= az) Vec3T.unit_y else Vec3T.unit_z;
    const p = v.cross(axis);
    const l2 = p.dot(p);
    if (!(l2 > 0)) return Vec3T.unit_x;
    return p.scale(1.0 / @sqrt(l2));
}

/// Squared distance from point `p` to the line through `a`,`b`.
fn distToLineSq(comptime T: type, p: math.Vec(3, T), a: math.Vec(3, T), b: math.Vec(3, T)) T {
    const ab = b.sub(a);
    const ap = p.sub(a);
    const denom = ab.dot(ab);
    if (!(denom > 0)) return ap.dot(ap); // a == b
    const t = ap.dot(ab) / denom;
    const closest = a.add(ab.scale(t));
    return p.sub(closest).dot(p.sub(closest));
}

/// If exactly one core is a segment and the other a point, returns whether the
/// segment is `shape_a` (`true`) or `shape_b` (`false`); `null` otherwise. Drives
/// the E3 intrinsic world-space degenerate normal (point⊖segment only).
fn pointSegmentPair(comptime T: type, shape_a: support.SupportShape(T), shape_b: support.SupportShape(T)) ?bool {
    const Tag = std.meta.Tag(support.SupportShape(T).Core);
    const ta = std.meta.activeTag(shape_a.core);
    const tb = std.meta.activeTag(shape_b.core);
    if (ta == Tag.segment and tb == Tag.point) return true; // segment is shape_a
    if (ta == Tag.point and tb == Tag.segment) return false; // segment is shape_b
    return null;
}

/// Degenerate result for a < 3-D Minkowski difference (the cores touch along a
/// point / line / plane — zero core penetration). Returns a deterministic unit
/// separation normal and depth 0, with the closest points on the touching
/// feature (all mapped to world). This is the deep↔shallow boundary; the
/// manifold's deep depth is `0 + r_sum`.
fn degenerateResult(
    comptime T: type,
    shape_a: support.SupportShape(T),
    rot_a: math.Quat(T),
    pos_a: math.Vec(3, T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
    rot_b: math.Quat(T),
    verts: []const support.Vertex(T),
) EpaResult(T) {
    const Vec3T = math.Vec(3, T);
    const S = gjk_mod.Simplex(T);
    _ = relpose;

    switch (verts.len) {
        1 => {
            // Point-like (coincident cores): fixed axis, depth 0.
            return worldResult(T, rot_a, pos_a, Vec3T.unit_x, 0, verts[0].support_a, verts[0].support_b);
        },
        2 => {
            // Segment-like: closest on the segment; normal ⟂ the segment.
            const seg = S.closestOriginSegment(verts[0].w, verts[1].w);
            var ca = Vec3T.zero;
            var cb = Vec3T.zero;
            for (0..seg.count) |i| {
                ca = ca.add(verts[seg.indices[i]].support_a.scale(seg.bary[i]));
                cb = cb.add(verts[seg.indices[i]].support_b.scale(seg.bary[i]));
            }
            const depth = @max(@sqrt(seg.closest.dot(seg.closest)), 0);
            // E3 — point⊖segment (a 1-D Minkowski difference) derives its
            // perpendicular normal INTRINSICALLY in world from the segment-owning
            // shape's world rotation with EXACT input bits and an explicit
            // ownership sign, so `v_world(B,A) = −v_world(A,B)` and (perpAxis being
            // odd with a `|·|`-invariant axis) the two call orders return exact bit
            // negations. `n_world` is already world, so it bypasses the `worldResult`
            // `rot_a` mapping; closest points stay barycentric + `rot_a`-mapped.
            if (pointSegmentPair(T, shape_a, shape_b)) |seg_is_a| {
                const rot_seg = if (seg_is_a) rot_a else rot_b;
                const s: T = if (seg_is_a) 1 else -1;
                const v_world = rot_seg.rotateVec3(Vec3T.unit_y).scale(s);
                return .{
                    .normal = perpAxis(T, v_world),
                    .depth = depth,
                    .closest_a = rot_a.rotateVec3(ca).add(pos_a),
                    .closest_b = rot_a.rotateVec3(cb).add(pos_a),
                };
            }
            // Other 2-vertex cases (segment⊖segment collinear, …): the A-frame
            // segment direction, best-effort (no cross-order exactness claimed).
            const n = perpAxis(T, verts[1].w.sub(verts[0].w));
            return worldResult(T, rot_a, pos_a, n, depth, ca, cb);
        },
        else => {
            // Planar (≥ 3 verts): normal = the plane normal; closest on the triangle.
            const tri = S.closestOriginTriangle(verts[0].w, verts[1].w, verts[2].w);
            var n = verts[1].w.sub(verts[0].w).cross(verts[2].w.sub(verts[0].w));
            const nl = n.dot(n);
            n = if (nl > 0) n.scale(1.0 / @sqrt(nl)) else Vec3T.unit_x;
            const face_verts = [3]support.Vertex(T){ verts[0], verts[1], verts[2] };
            var ca = Vec3T.zero;
            var cb = Vec3T.zero;
            for (0..tri.count) |i| {
                ca = ca.add(face_verts[tri.indices[i]].support_a.scale(tri.bary[i]));
                cb = cb.add(face_verts[tri.indices[i]].support_b.scale(tri.bary[i]));
            }
            return worldResult(T, rot_a, pos_a, n, @max(@sqrt(tri.closest.dot(tri.closest)), 0), ca, cb);
        },
    }
}

/// Fully-degenerate fallback (a defensive path for a non-deep seed): fixed axis,
/// depth 0, coincident closest points at A's origin.
fn degenerateFixedAxis(
    comptime T: type,
    shape_a: support.SupportShape(T),
    rot_a: math.Quat(T),
    pos_a: math.Vec(3, T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
) EpaResult(T) {
    _ = shape_a;
    _ = relpose;
    _ = shape_b;
    const Vec3T = math.Vec(3, T);
    return worldResult(T, rot_a, pos_a, Vec3T.unit_x, 0, Vec3T.zero, Vec3T.zero);
}

/// Assemble an `EpaResult` from an A-frame normal + depth + A-frame closest
/// points, mapping normal and points to world via `rot_a`/`pos_a`.
fn worldResult(comptime T: type, rot_a: math.Quat(T), pos_a: math.Vec(3, T), normal_a: math.Vec(3, T), depth: T, ca: math.Vec(3, T), cb: math.Vec(3, T)) EpaResult(T) {
    return .{
        .normal = rot_a.rotateVec3(normal_a),
        .depth = depth,
        .closest_a = rot_a.rotateVec3(ca).add(pos_a),
        .closest_b = rot_a.rotateVec3(cb).add(pos_a),
    };
}

// --- In-file fallback / skip unit tests (brief E2(h)) ---

test "epa skipped faces are never selected" {
    const F = Face(f32);
    const nx = math.Vec(3, f32).unit_x;
    var faces = [_]F{
        .{ .a = 0, .b = 0, .c = 0, .normal = nx, .dist = 0.5 }, // closest
        .{ .a = 0, .b = 0, .c = 0, .normal = nx, .dist = 1.0 },
        .{ .a = 0, .b = 0, .c = 0, .normal = nx, .dist = 2.0 },
    };
    var skipped = [_]bool{ false, false, false };
    try std.testing.expectEqual(@as(?usize, 0), closestNonSkipped(f32, &faces, &skipped));
    skipped[0] = true; // the closest is now skipped and must never be selected
    try std.testing.expectEqual(@as(?usize, 1), closestNonSkipped(f32, &faces, &skipped));
    skipped[1] = true;
    try std.testing.expectEqual(@as(?usize, 2), closestNonSkipped(f32, &faces, &skipped));
    skipped[2] = true; // all skipped → exhaustion (null drives the fallback)
    try std.testing.expectEqual(@as(?usize, null), closestNonSkipped(f32, &faces, &skipped));
}

test "epa exhaustion fallback returns the minimal realizable candidate" {
    const V = math.Vec(3, f32);
    var fb: Fallback(f32) = .{};
    try std.testing.expect(!fb.have);
    fb.consider(2.0, V.unit_x, V.zero, V.zero);
    fb.consider(1.0, V.unit_y, V.zero, V.zero); // new minimum depth
    fb.consider(1.5, V.unit_z, V.zero, V.zero); // not the minimum
    try std.testing.expect(fb.have);
    try std.testing.expectEqual(@as(f32, 1.0), fb.d);
    try std.testing.expect(fb.n.eql(V.unit_y));
}

test "epa fallback selection is deterministic (first wins on ties)" {
    const V = math.Vec(3, f32);
    var fb: Fallback(f32) = .{};
    fb.consider(1.0, V.unit_x, V.zero, V.zero);
    fb.consider(1.0, V.unit_y, V.zero, V.zero); // equal depth must NOT replace (strict <)
    try std.testing.expect(fb.n.eql(V.unit_x));
}

test "epa terminalFace ignores a skipped coplanar face with a smaller closest" {
    const V = math.Vec(3, f32);
    const Vx = support.Vertex(f32);
    const z = V.zero;
    // sel (face 0): plane y = 1, a FAR triangle whose closest-to-origin (~4.4) is
    // clamped to its edge (projection outside it). Face 1: a COPLANAR sibling on
    // y = 1 containing the projection (closest 1.0), but SKIPPED. terminalFace must
    // return sel — a skipped face's distance is never adopted (E2(d)).
    const verts = [_]Vx{
        .{ .w = V.fromArray(.{ 3, 1, 3 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 4, 1, 3 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 3.5, 1, 4 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ -1, 1, -1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 1, 1, -1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 0, 1, 1 }), .support_a = z, .support_b = z },
    };
    const sel = Face(f32){ .a = 0, .b = 1, .c = 2, .normal = V.unit_y, .dist = 1.0 };
    const faces = [_]Face(f32){ sel, .{ .a = 3, .b = 4, .c = 5, .normal = V.unit_y, .dist = 1.0 } };
    const skipped = [_]bool{ false, true };
    const t = terminalFace(f32, &verts, &faces, &skipped, sel, 1.0e-4);
    try std.testing.expect(t.a == 0 and t.b == 1 and t.c == 2); // sel, not the skipped sibling
}

test "epa terminalFace rejects a different-normal face in the distance band" {
    const V = math.Vec(3, f32);
    const Vx = support.Vertex(f32);
    const z = V.zero;
    // sel (face 0): plane x = 1, closest-to-origin 1.0. Face 1: plane y = 0.7
    // (a DIFFERENT normal) within the distance band, whose closest 0.7 is smaller
    // — a plane-agnostic scan would adopt it, but its normal was never proven
    // converged, so terminalFace must reject it and keep sel's plane (Codex P3).
    const verts = [_]Vx{
        .{ .w = V.fromArray(.{ 1, -1, -1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 1, 1, -1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 1, 0, 1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ -1, 0.7, -1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 1, 0.7, -1 }), .support_a = z, .support_b = z },
        .{ .w = V.fromArray(.{ 0, 0.7, 1 }), .support_a = z, .support_b = z },
    };
    const sel = Face(f32){ .a = 0, .b = 1, .c = 2, .normal = V.unit_x, .dist = 1.0 };
    const faces = [_]Face(f32){ sel, .{ .a = 3, .b = 4, .c = 5, .normal = V.unit_y, .dist = 0.7 } };
    const skipped = [_]bool{ false, false };
    const t = terminalFace(f32, &verts, &faces, &skipped, sel, 0.5);
    try std.testing.expect(t.normal.eql(V.unit_x)); // kept sel's plane, rejected the +Y face
}

test "epa expandPolytope keeps a kept face's skip flag through a successful expansion" {
    const V = math.Vec(3, f32);
    const Vx = support.Vertex(f32);
    const z = V.zero;
    // A regular tetra around the origin; expand beyond face 0 only (faces 1-3 kept).
    // Mark kept face 1 skipped BEFORE the expansion — the lockstep remap must carry
    // the flag to its new compacted index (Codex P2: no resurrection).
    var verts: [max_verts]Vx = undefined;
    verts[0] = .{ .w = V.fromArray(.{ 1, 1, 1 }), .support_a = z, .support_b = z };
    verts[1] = .{ .w = V.fromArray(.{ 1, -1, -1 }), .support_a = z, .support_b = z };
    verts[2] = .{ .w = V.fromArray(.{ -1, 1, -1 }), .support_a = z, .support_b = z };
    verts[3] = .{ .w = V.fromArray(.{ -1, -1, 1 }), .support_a = z, .support_b = z };
    var vcount: usize = 4;
    var faces: [max_faces]Face(f32) = undefined;
    var fcount: usize = 0;
    const tetra = [4][3]u32{ .{ 0, 1, 2 }, .{ 0, 1, 3 }, .{ 0, 2, 3 }, .{ 1, 2, 3 } };
    for (tetra) |t| {
        faces[fcount] = makeFace(f32, &verts, t[0], t[1], t[2], V.zero).?;
        fcount += 1;
    }
    var skipped: [max_faces]bool = undefined;
    @memset(skipped[0..fcount], false);
    const kept = faces[1]; // a face NOT beyond `w` → kept
    skipped[1] = true;
    // `w` just past face 0's plane makes ONLY face 0 visible (the others sit behind).
    const w = Vx{ .w = faces[0].normal.scale(faces[0].dist + 1), .support_a = z, .support_b = z };
    try std.testing.expect(expandPolytope(f32, &verts, &vcount, &faces, &fcount, skipped[0..], w, 0, 1.0e-5));
    var found = false;
    for (0..fcount) |i| {
        if (faces[i].a == kept.a and faces[i].b == kept.b and faces[i].c == kept.c) {
            try std.testing.expect(skipped[i]); // flag survived the compaction
            found = true;
        }
    }
    try std.testing.expect(found);
}
