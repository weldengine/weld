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

/// EPA on the cores of `shape_a`/`shape_b` at their world poses, seeded from the
/// GJK terminal `.deep` simplex. Computes in A's frame (B via `relpose`), maps
/// the result to world via `rot_a`/`pos_a`. See the file header for the frame,
/// the low-dimensional-seed contract, and determinism.
pub fn epa(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
    seed: gjk_mod.GjkResult(T),
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
        return degenerateFixedAxis(T, shape_a, rot_a, pos_a, relpose, shape_b);
    }
    for (0..vcount) |i| verts[i] = seed.simplex[i];

    // Coordinate scale for the (relative) tolerances — the absolute support
    // magnitude, the scale of the `w = support_a − support_b` rounding.
    const scale = polytopeScale(T, verts[0..vcount]);
    const rel: T = if (T == f32) 1.0e-4 else 1.0e-10;
    const tol = rel * scale;
    const tol_sq = tol * tol;

    // --- Expand a low-dimensional seed to a non-degenerate tetrahedron ---
    if (!expandToTetra(T, shape_a, relpose, shape_b, &verts, &vcount, tol_sq)) {
        return degenerateResult(T, shape_a, rot_a, pos_a, relpose, shape_b, verts[0..vcount]);
    }

    // Interior reference point (the tetra centroid), strictly inside the
    // non-degenerate seed tetra — used to orient every face outward (see
    // `makeFace`). The polytope only grows, so this stays interior.
    var interior = Vec3T.zero;
    for (0..vcount) |i| interior = interior.add(verts[i].w);
    interior = interior.scale(1.0 / @as(T, @floatFromInt(vcount)));

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
        return degenerateResult(T, shape_a, rot_a, pos_a, relpose, shape_b, verts[0..vcount]);
    }

    // --- Expanding-polytope loop ---
    var best = faces[closestFaceIndex(T, faces[0..fcount])];
    var iter: u32 = 0;
    while (iter < max_epa_iterations) : (iter += 1) {
        const ci = closestFaceIndex(T, faces[0..fcount]);
        best = faces[ci];

        const w = support.minkowskiSupport(T, shape_a, relpose, shape_b, best.normal);
        const d = w.w.dot(best.normal);
        // Converged: the support in the closest face's normal does not advance
        // past its plane beyond float noise ⇒ the face is on the surface.
        if (d - best.dist <= tol) break;
        // Anti-cycling: the support duplicates an existing polytope vertex.
        if (duplicate(T, verts[0..vcount], w.w, tol_sq)) break;
        if (vcount >= max_verts) break;

        // Re-triangulate: remove faces visible from `w`, add `w`, connect the
        // silhouette. If the geometry degenerates, keep the current best face.
        if (!expandPolytope(T, &verts, &vcount, &faces, &fcount, w, interior)) break;
    }

    // --- Reconstruct closest points from the terminal face barycentrics ---
    const va = verts[best.a];
    const vb = verts[best.b];
    const vc = verts[best.c];
    const tri = gjk_mod.Simplex(T).closestOriginTriangle(va.w, vb.w, vc.w);
    const face_verts = [3]VertexT{ va, vb, vc };
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

/// Index of the face closest to the origin (minimum `dist`; first wins on ties —
/// deterministic).
fn closestFaceIndex(comptime T: type, faces: []const Face(T)) usize {
    var best: usize = 0;
    var best_d: T = faces[0].dist;
    for (faces, 0..) |f, i| {
        if (f.dist < best_d) {
            best_d = f.dist;
            best = i;
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

/// One EPA expansion step: append `w`, delete every face visible from it, and
/// re-triangulate the silhouette (each horizon edge → a new face to `w`). Returns
/// false if the step degenerates (no visible face, no silhouette, or every new
/// face is a sliver) — the caller then keeps the current best face.
fn expandPolytope(
    comptime T: type,
    verts: *[max_verts]support.Vertex(T),
    vcount: *usize,
    faces: *[max_faces]Face(T),
    fcount: *usize,
    w: support.Vertex(T),
    interior: math.Vec(3, T),
) bool {
    const FaceT = Face(T);
    var visible: [max_faces]bool = undefined;
    var any_visible = false;
    for (0..fcount.*) |fi| {
        const f = faces[fi];
        // Visible iff `w` is strictly beyond this face's plane.
        visible[fi] = w.w.sub(verts[f.a].w).dot(f.normal) > 0;
        if (visible[fi]) any_visible = true;
    }
    if (!any_visible) return false;

    // Collect the silhouette: a directed edge (i,j) of a visible face whose twin
    // (j,i) belongs to no other visible face (the horizon between removed and
    // kept faces). Consistent winding makes twins reversed.
    var sil: [max_silhouette][2]u32 = undefined;
    var scount: usize = 0;
    for (0..fcount.*) |fi| {
        if (!visible[fi]) continue;
        const f = faces[fi];
        const edges = [3][2]u32{ .{ f.a, f.b }, .{ f.b, f.c }, .{ f.c, f.a } };
        for (edges) |e| {
            if (!twinAmongVisible(FaceT, faces[0..fcount.*], visible[0..fcount.*], fi, e[1], e[0])) {
                if (scount >= max_silhouette) return false;
                sil[scount] = e;
                scount += 1;
            }
        }
    }
    if (scount == 0) return false;

    // Compact out the visible faces.
    var nf: usize = 0;
    for (0..fcount.*) |fi| {
        if (!visible[fi]) {
            faces[nf] = faces[fi];
            nf += 1;
        }
    }
    fcount.* = nf;

    // Append the new vertex.
    const wi: u32 = @intCast(vcount.*);
    verts[vcount.*] = w;
    vcount.* += 1;

    // Fan the silhouette to the new vertex.
    for (sil[0..scount]) |e| {
        if (makeFace(T, verts, e[0], e[1], wi, interior)) |f| {
            if (fcount.* >= max_faces) return false;
            faces[fcount.*] = f;
            fcount.* += 1;
        }
    }
    return fcount.* >= 4;
}

/// Whether directed edge (x,y) belongs to any visible face other than `skip`.
fn twinAmongVisible(comptime FaceT: type, faces: []const FaceT, visible: []const bool, skip: usize, x: u32, y: u32) bool {
    for (faces, 0..) |f, fi| {
        if (fi == skip or !visible[fi]) continue;
        if ((f.a == x and f.b == y) or (f.b == x and f.c == y) or (f.c == x and f.a == y)) return true;
    }
    return false;
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
    verts: []const support.Vertex(T),
) EpaResult(T) {
    const Vec3T = math.Vec(3, T);
    const S = gjk_mod.Simplex(T);
    _ = shape_a;
    _ = relpose;
    _ = shape_b;

    switch (verts.len) {
        1 => {
            // Point-like (coincident cores): fixed axis, depth 0.
            return worldResult(T, rot_a, pos_a, Vec3T.unit_x, 0, verts[0].support_a, verts[0].support_b);
        },
        2 => {
            // Segment-like: normal ⟂ the segment; closest on the segment.
            const seg = S.closestOriginSegment(verts[0].w, verts[1].w);
            const n = perpAxis(T, verts[1].w.sub(verts[0].w));
            var ca = Vec3T.zero;
            var cb = Vec3T.zero;
            for (0..seg.count) |i| {
                ca = ca.add(verts[seg.indices[i]].support_a.scale(seg.bary[i]));
                cb = cb.add(verts[seg.indices[i]].support_b.scale(seg.bary[i]));
            }
            return worldResult(T, rot_a, pos_a, n, @max(@sqrt(seg.closest.dot(seg.closest)), 0), ca, cb);
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
