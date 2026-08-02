//! `forge_3d/pipeline/narrowphase/fast_paths.zig` — the analytic per-pair
//! narrowphase fast paths (M1.1.4).
//!
//! **Seed architecture (Guy-approved, brief Scope).** A fast path NEVER
//! re-implements manifold assembly. Each kernel computes only the `ContactSeed`
//! the generic path's GJK/EPA block already computes — `(normal, closest_a,
//! closest_b, base_penetration)` — and feeds the UNCHANGED `generateManifold`.
//! The five `feature_id` producers, the supporting-face clipping, the ≤ 4
//! reduction, the per-point penetration, order-independence, and frame-stability
//! are therefore all inherited by construction; the only fast-vs-generic
//! difference is the seed. The speedup is the skipped GJK descent + EPA polytope
//! expansion — `generateManifold`'s clip is cheap and analytic.
//!
//! **Dispatch.** `fastSeed` is a three-state dispatcher: `.not_handled` (no
//! kernel for this pair — the caller falls through to the generic oracle),
//! `.separated` (analytically disjoint — no contact), or `.contact` (a
//! `ContactSeed` for `generateManifold`). It is called from `collideOrdered`
//! (fixed order), so `collide`'s pose canonicalization and `collidePair`'s
//! BodyId order wrap the fast paths identically to the generic path.
//!
//! **Status.** E1 laid the foundation (`ContactSeed`, `FastResult`, a no-op
//! dispatcher). E2 wired the point-core pairs — **sphere/sphere** and
//! **sphere/box** (both orders). E3 added **box/box** via a separating-axis test
//! (15 candidate axes → the least-overlap axis → seed). E4 added
//! **capsule/capsule** via closest-segment analytics. capsule/box and
//! sphere/capsule stay on the generic path; a rounded box returns `.not_handled`.
//!
//! **Classification parity with the generic oracle.** The `separated` decision
//! mirrors `gjk.zig` exactly — `dist − r_sum > conv_k · floatEps(T) ·
//! coord_scale` with `conv_k = 16` and `coord_scale = |Δcentres| +
//! coreExtent(a) + coreExtent(b)` (point → 0, box → `|half_extents|`) — so an
//! exact inflated touch stays a contact and the fast/generic boundary agrees
//! (up to the documented flip band).
//!
//! **Box radius invariant.** A box core in a fast pair must have `radius == 0`
//! (the forge_3d box invariant). A rounded box (`radius > 0`) returns
//! `.not_handled` so it stays on the generic path (the SAT/clamp kernels are
//! radius-0-box only).
//!
//! **Dependency discipline (brief Notes).** Imports `foundation` (math) and the
//! sibling `support.zig` ONLY — never `manifold.zig` (that would be a cycle:
//! `manifold.zig` imports THIS file, never the reverse), never `weld_forge`,
//! `body*.zig`, `config.zig`, or `broadphase.zig`. The scalar is the comptime
//! `T`; `forge_3d` instantiates it at `config.Real`.

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");

/// The contact seed a fast path hands to `manifold.generateManifold` — exactly
/// the quantities the generic path's GJK/EPA block produces, so the generated
/// manifold is identical up to the analytic-vs-iterative accuracy of the seed.
///
///  - `normal`: unit, world-space, A→B (the axis to translate B along to reduce
///    penetration), the same convention as `EpaResult.normal` and the shallow
///    `normalize(closest_b − closest_a)`.
///  - `closest_a` / `closest_b`: the world-space closest points on the two
///    CORES (radius excluded) — the witness points `generateManifold` maps to
///    the inflated surfaces.
///  - `base_penetration`: the point-core penetration along `normal` — shallow
///    `r_sum − dist`, deep `depth + r_sum` — continuous across the boundary.
pub fn ContactSeed(comptime T: type) type {
    return struct {
        normal: math.Vec(3, T),
        closest_a: math.Vec(3, T),
        closest_b: math.Vec(3, T),
        base_penetration: T,
    };
}

/// The three-state outcome of the fast-path dispatcher:
///  - `not_handled`: no analytic kernel for this shape pair (or a rounded box) —
///    the caller runs the generic GJK/EPA oracle.
///  - `separated`: the pair is analytically disjoint — no contact (`null`).
///  - `contact`: a `ContactSeed` to feed `generateManifold`.
pub fn FastResult(comptime T: type) type {
    return union(enum) {
        not_handled,
        separated,
        contact: ContactSeed(T),
    };
}

/// Analytic per-pair narrowphase dispatcher: returns a `ContactSeed` (or
/// `separated`) for a supported shape pair, else `not_handled` so the caller
/// falls through to the generic GJK/EPA oracle. Runs on the world poses, in the
/// same fixed `(a, b)` order as `collideOrdered` — the seed's normal (A→B) and
/// closest-point ownership follow that order, so `generateManifold`'s feature_id
/// halves swap with the order exactly as on the generic path.
///
/// Wired: sphere/sphere, sphere/box (E2), box/box SAT (E3), and capsule/capsule
/// (E4), all orders. `.not_handled` for capsule/box + sphere/capsule (stay
/// generic), and any box core with `radius > 0` (a rounded box — the kernels are
/// radius-0-box only).
pub fn fastSeed(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) FastResult(T) {
    switch (shape_a.core) {
        .point => switch (shape_b.core) {
            // sphere/sphere.
            .point => return sphereSphere(T, pos_a, shape_a.radius, pos_b, shape_b.radius),
            // sphere (A) / box (B).
            .box => |he_b| return sphereBox(T, pos_a, shape_a.radius, pos_b, rot_b, he_b, shape_b.radius, .sphere_is_a),
            .segment => return .not_handled, // sphere/capsule stays generic
            .triangle => return .not_handled, // sphere/triangle stays generic
        },
        .box => |he_a| switch (shape_b.core) {
            // box (A) / sphere (B).
            .point => return sphereBox(T, pos_b, shape_b.radius, pos_a, rot_a, he_a, shape_a.radius, .box_is_a),
            // box/box — SAT (both cores must be radius-0).
            .box => |he_b| {
                if (shape_a.radius != 0 or shape_b.radius != 0) return .not_handled; // rounded box → generic
                return boxBox(T, pos_a, rot_a, he_a, pos_b, rot_b, he_b);
            },
            .segment => return .not_handled, // box/capsule stays generic
            .triangle => return .not_handled, // box/triangle stays generic
        },
        .segment => |ha| switch (shape_b.core) {
            // capsule/capsule.
            .segment => |hb| return capsuleCapsule(T, pos_a, rot_a, ha, shape_a.radius, pos_b, rot_b, hb, shape_b.radius),
            // The three remaining pairs, each stated EXPLICITLY like the fifteen others of
            // this function. They carried an `else` until M1.1.11.1, and the answer was
            // right but it had not been DECIDED — `.segment × .triangle` passed through it
            // without anyone choosing, which is exactly the failure mode the no-`else` rule
            // exists to prevent. The outer switch caught the case anyway; that is luck, not
            // the mechanism.
            .point => return .not_handled, // capsule/sphere stays generic
            .box => return .not_handled, // capsule/box stays generic
            .triangle => return .not_handled, // capsule/triangle stays generic
        },
        // NO analytic fast path against a triangle, in either position. The generic
        // GJK/EPA path serves it exactly, which is the whole return on making the triangle
        // a core rather than a family of kernels; a swept or contact fast path against one
        // would owe a geometric-equivalence proof against that generic path, which is the
        // M1.1.4 pattern and not this milestone's work.
        .triangle => return .not_handled,
    }
}

/// A box's core extent (`|half_extents|`) — the box term of the `separated`
/// margin's `coord_scale`; a point (sphere) contributes 0. Mirrors
/// `gjk.coreExtent` so the fast/generic separated boundary agrees.
fn boxExtent(comptime T: type, he: math.Vec(3, T)) T {
    return he.length();
}

/// The `separated` contact margin — `conv_k · floatEps(T) · coord_scale`,
/// `conv_k = 16`, identical to `gjk.zig`'s so a fast pair and its generic oracle
/// classify the touch/separated boundary the same way (up to the flip band).
fn contactMargin(comptime T: type, coord_scale: T) T {
    const conv_k: T = 16;
    return conv_k * std.math.floatEps(T) * coord_scale;
}

/// The sphere/sphere seed: cores are the two centres (radius excluded). Shallow
/// for any non-zero centre distance (points are 0-D, never "deep" unless
/// coincident); `.separated` past the inflated margin; a deterministic +X
/// fallback normal ONLY at true coincidence.
fn sphereSphere(comptime T: type, ca: math.Vec(3, T), ra: T, cb: math.Vec(3, T), rb: T) FastResult(T) {
    const d = cb.sub(ca);
    const dist_sq = d.dot(d);
    const dist = @sqrt(dist_sq);
    const r_sum = ra + rb;
    if (dist - r_sum > contactMargin(T, dist)) return .separated;
    // `normalize(d)` is scale-EQUIVARIANT, so the only thing to guard is 0/0. The
    // fallback fires ONLY at true coincidence (`dist² ≤ floatMin` — the type's
    // underflow floor, NOT a geometric scale): translation- and scale-invariant by
    // construction (E8, class A).
    const normal = if (dist_sq > std.math.floatMin(T)) d.scale(1.0 / dist) else math.Vec(3, T).unit_x;
    return .{ .contact = .{
        .normal = normal,
        .closest_a = ca,
        .closest_b = cb,
        .base_penetration = r_sum - dist,
    } };
}

/// Which member of a sphere/box pair is shape A (fixes the seed's A→B normal and
/// closest-point ownership to the caller's order).
const SphereBoxOwner = enum { sphere_is_a, box_is_a };

/// The sphere/box seed (box core radius must be 0). Clamps the sphere centre to
/// the box core: outside → the closest box-surface point + `normalize(centre −
/// surface)` (shallow); inside → the least-penetration face (deep, closed-form,
/// robust at ANY aspect ratio — this is the P1d fix). The box→sphere normal and
/// witness are computed canonically, then oriented + ownership-assigned to the
/// caller's A/B order. A rounded box (`r_box != 0`) is `.not_handled`.
fn sphereBox(
    comptime T: type,
    sphere_c: math.Vec(3, T),
    r_sphere: T,
    box_c: math.Vec(3, T),
    box_rot: math.Quat(T),
    box_he: math.Vec(3, T),
    r_box: T,
    owner: SphereBoxOwner,
) FastResult(T) {
    const Vec3T = math.Vec(3, T);
    if (r_box != 0) return .not_handled; // rounded box stays on the generic path
    const r_sum = r_sphere + r_box;

    // Sphere centre in the box's local frame; clamp per axis to the box core.
    const c_local = box_rot.conjugate().rotateVec3(sphere_c.sub(box_c));
    const cl = c_local.toArray();
    const he = box_he.toArray();
    var q: [3]T = undefined;
    var inside = true;
    for (0..3) |i| {
        q[i] = std.math.clamp(cl[i], -he[i], he[i]);
        if (@abs(cl[i]) > he[i]) inside = false;
    }

    var cp_box_local: Vec3T = undefined; // closest point on the box core (local)
    var n_bs: Vec3T = undefined; // box → sphere normal (world)
    var base_penetration: T = undefined;

    if (!inside) {
        // Shallow: the clamped point is the closest box-core point to the sphere.
        cp_box_local = Vec3T.fromArray(q);
        const delta = c_local.sub(cp_box_local); // box surface → sphere centre (local)
        const dist_sq = delta.dot(delta);
        const dist = @sqrt(dist_sq);
        const coord_scale = sphere_c.sub(box_c).length() + boxExtent(T, box_he);
        if (dist - r_sum > contactMargin(T, coord_scale)) return .separated;
        // Normal from the box surface toward the sphere centre; on the surface
        // (dist ≈ 0, the shallow↔deep seam) fall back to the least-penetration
        // face axis. `normalize(delta)` is scale-equivariant, so the fallback fires
        // ONLY at true coincidence (`dist² ≤ floatMin`, E8 class A).
        const n_local = if (dist_sq > std.math.floatMin(T)) delta.scale(1.0 / dist) else fallbackLocalNormal(T, c_local);
        n_bs = box_rot.rotateVec3(n_local);
        base_penetration = r_sum - dist;
    } else {
        // Deep: the sphere centre is inside the box core. The least-penetration
        // face (first-index tie-break) gives the exit axis, depth, and witness —
        // closed-form, so it is correct at any aspect ratio (P1d).
        var i_star: usize = 0;
        var best_pen: T = he[0] - @abs(cl[0]);
        for (1..3) |i| {
            const pen = he[i] - @abs(cl[i]);
            if (pen < best_pen) {
                best_pen = pen;
                i_star = i;
            }
        }
        const s: T = if (cl[i_star] >= 0) 1 else -1;
        var cpl = cl;
        cpl[i_star] = s * he[i_star];
        cp_box_local = Vec3T.fromArray(cpl);
        var axis = [3]T{ 0, 0, 0 };
        axis[i_star] = s;
        n_bs = box_rot.rotateVec3(Vec3T.fromArray(axis));
        base_penetration = best_pen + r_sum;
    }

    const cp_box_world = box_c.add(box_rot.rotateVec3(cp_box_local));
    return switch (owner) {
        // A = box: normal box→sphere, witness_a on the box, witness_b the sphere.
        .box_is_a => .{ .contact = .{
            .normal = n_bs,
            .closest_a = cp_box_world,
            .closest_b = sphere_c,
            .base_penetration = base_penetration,
        } },
        // A = sphere: negate (A→B = sphere→box) and swap witness ownership.
        .sphere_is_a => .{ .contact = .{
            .normal = n_bs.neg(),
            .closest_a = sphere_c,
            .closest_b = cp_box_world,
            .base_penetration = base_penetration,
        } },
    };
}

/// A deterministic box→sphere fallback normal for the measure-zero surface seam
/// (sphere centre exactly on the box surface, `dist ≈ 0`): the axis of the box's
/// least-penetration face for the centre, else +X. Kept local (box frame) — the
/// caller rotates it to world.
fn fallbackLocalNormal(comptime T: type, c_local: math.Vec(3, T)) math.Vec(3, T) {
    const cl = c_local.toArray();
    var i_star: usize = 0;
    var best: T = @abs(cl[0]);
    for (1..3) |i| {
        if (@abs(cl[i]) > best) {
            best = @abs(cl[i]);
            i_star = i;
        }
    }
    if (!(best > 0)) return math.Vec(3, T).unit_x;
    var axis = [3]T{ 0, 0, 0 };
    axis[i_star] = if (cl[i_star] >= 0) 1 else -1;
    return math.Vec(3, T).fromArray(axis);
}

/// The box/box separating-axis test → `ContactSeed` (both boxes radius 0). Tests
/// the 15 candidate axes — 3 A-face normals, 3 B-face normals, 9 edge×edge cross
/// products (degeneracy-guarded: a near-parallel edge pair is skipped, its
/// separation already covered by the face axes) — and returns `.separated` on
/// the first axis with no overlap. Otherwise the least-overlap axis is the
/// contact normal + depth (a FACE wins an exact face/edge tie — the stable
/// manifold — so the reported depth is always the true SAT min-overlap / MTV).
/// SAT has NO GJK degeneracy, so this is robust at ANY aspect ratio (the box/box
/// P1d fix) and order-independent by construction.
///
/// The seed feeds the unchanged `generateManifold`: a FACE axis (`n_a` aligned
/// with a box face) drives the supporting-face clip → the multi-point manifold
/// (closest points + `base_penetration` unused there); an EDGE axis drives the
/// FIX-1 single-witness fallback → the contact at the midpoint of the closest
/// points of the two contributing edges (computed here).
fn boxBox(
    comptime T: type,
    ca: math.Vec(3, T),
    ra: math.Quat(T),
    he_a: math.Vec(3, T),
    cb: math.Vec(3, T),
    rb: math.Quat(T),
    he_b: math.Vec(3, T),
) FastResult(T) {
    const Vec3T = math.Vec(3, T);
    const axa = [3]Vec3T{ ra.rotateVec3(Vec3T.unit_x), ra.rotateVec3(Vec3T.unit_y), ra.rotateVec3(Vec3T.unit_z) };
    const axb = [3]Vec3T{ rb.rotateVec3(Vec3T.unit_x), rb.rotateVec3(Vec3T.unit_y), rb.rotateVec3(Vec3T.unit_z) };
    const hea = he_a.toArray();
    const heb = he_b.toArray();
    const dc = cb.sub(ca);
    const scale = dc.length() + he_a.length() + he_b.length();
    const margin = contactMargin(T, scale);

    // Track the least-overlap FACE axis and least-overlap EDGE axis separately so
    // a small bias can prefer a face on a near-tie (edge cross products carry more
    // rounding, and face contacts are the stable manifold).
    var face_depth: T = std.math.floatMax(T);
    var face_axis = Vec3T.unit_x;
    var edge_depth: T = std.math.floatMax(T);
    var edge_axis = Vec3T.unit_x;
    var edge_i: usize = 0;
    var edge_j: usize = 0;
    var have_edge = false;

    // Face axes (already unit).
    for (0..6) |k| {
        const L = if (k < 3) axa[k] else axb[k - 3];
        const ov = boxOverlapOnAxis(T, L, axa, hea, axb, heb, dc);
        if (ov < -margin) return .separated;
        if (ov < face_depth) {
            face_depth = ov;
            face_axis = L;
        }
    }
    // Edge×edge axes. SEPARATION is tested on EVERY non-zero cross axis using the
    // NON-normalized `L_raw` (its overlap sign is preserved; the margin is scaled
    // by `|L_raw| = √l2`) — a near-parallel edge pair can still be THE separating
    // axis and must never be skipped for separation (P1-2). Only MTV CANDIDACY is
    // gated by a true numerical floor `mtv_floor` (NOT `1e-6`): below it the
    // normalized cross direction is numerical noise, and the parallel case's MTV
    // is carried by the face axes anyway.
    const mtv_floor: T = if (T == f32) 1.0e-10 else 1.0e-20;
    for (0..3) |i| {
        for (0..3) |j| {
            const l_raw = axa[i].cross(axb[j]);
            const l2 = l_raw.dot(l_raw);
            if (l2 <= 0) continue; // exactly parallel ⇒ the zero axis carries no info
            // Separation on the raw axis: `ov_raw = √l2 · true_overlap`, so
            // `ov_raw < −margin·√l2 ⇔ true_overlap < −margin`.
            const ov_raw = boxOverlapOnAxis(T, l_raw, axa, hea, axb, heb, dc);
            if (ov_raw < -margin * @sqrt(l2)) return .separated;
            if (l2 > mtv_floor) {
                const L = l_raw.scale(1.0 / @sqrt(l2));
                const ov = boxOverlapOnAxis(T, L, axa, hea, axb, heb, dc);
                if (!have_edge or ov < edge_depth) {
                    edge_depth = ov;
                    edge_axis = L;
                    edge_i = i;
                    edge_j = j;
                    have_edge = true;
                }
            }
        }
    }

    // Choose the least-overlap axis. Strict `<` makes a FACE win an exact face/
    // edge tie (the stable manifold, and deterministic); the reported depth is
    // therefore always the true SAT min-overlap (the MTV), never inflated by a
    // bias — the oracle-free depth test relies on this. Then orient the normal A→B.
    const use_edge = have_edge and (edge_depth < face_depth);
    var normal = if (use_edge) edge_axis else face_axis;
    const depth = if (use_edge) edge_depth else face_depth;
    if (dc.dot(normal) < 0) normal = normal.neg();

    if (use_edge) {
        // The two contributing edges: A's edge (parallel to axis edge_i) extremal
        // toward +normal, B's edge (parallel to edge_j) extremal toward −normal.
        const ea = contactEdge(T, ca, axa, hea, edge_i, normal);
        const eb = contactEdge(T, cb, axb, heb, edge_j, normal.neg());
        const cp = closestSegSeg(T, ea[0], ea[1], eb[0], eb[1]);
        return .{ .contact = .{
            .normal = normal,
            .closest_a = cp[0],
            .closest_b = cp[1],
            .base_penetration = depth,
        } };
    }
    // Face axis: the clip ignores the closest points, but supply sane support
    // points (A's deepest toward +normal, B's toward −normal) for robustness.
    return .{ .contact = .{
        .normal = normal,
        .closest_a = boxSupportPoint(T, ca, axa, hea, normal),
        .closest_b = boxSupportPoint(T, cb, axb, heb, normal.neg()),
        .base_penetration = depth,
    } };
}

/// Signed overlap of the two OBBs projected onto unit axis `L`: `radius_a +
/// radius_b − |Δcentre · L|`. Negative ⇒ `L` is a separating axis.
fn boxOverlapOnAxis(comptime T: type, L: math.Vec(3, T), axa: [3]math.Vec(3, T), hea: [3]T, axb: [3]math.Vec(3, T), heb: [3]T, dc: math.Vec(3, T)) T {
    var ra_proj: T = 0;
    var rb_proj: T = 0;
    for (0..3) |k| {
        ra_proj += hea[k] * @abs(axa[k].dot(L));
        rb_proj += heb[k] * @abs(axb[k].dot(L));
    }
    return ra_proj + rb_proj - @abs(dc.dot(L));
}

/// The box corner (world) farthest along `dir`: `centre + Σ_k axis_k ·
/// sign(axis_k · dir) · he_k`.
fn boxSupportPoint(comptime T: type, c: math.Vec(3, T), ax: [3]math.Vec(3, T), he: [3]T, dir: math.Vec(3, T)) math.Vec(3, T) {
    var p = c;
    for (0..3) |k| {
        const s: T = if (ax[k].dot(dir) >= 0) 1 else -1;
        p = p.add(ax[k].scale(s * he[k]));
    }
    return p;
}

/// The box edge (world segment) parallel to local axis `dir_idx` and extremal
/// toward `toward`: the two axes perpendicular to `dir_idx` are pinned to the
/// corner farthest along `toward`; the edge spans `±he[dir_idx]` along its axis.
fn contactEdge(comptime T: type, c: math.Vec(3, T), ax: [3]math.Vec(3, T), he: [3]T, dir_idx: usize, toward: math.Vec(3, T)) [2]math.Vec(3, T) {
    var center = c;
    for (0..3) |k| {
        if (k == dir_idx) continue;
        const s: T = if (ax[k].dot(toward) >= 0) 1 else -1;
        center = center.add(ax[k].scale(s * he[k]));
    }
    const half = ax[dir_idx].scale(he[dir_idx]);
    return .{ center.sub(half), center.add(half) };
}

/// Closest points between two segments `p1`–`q1` and `p2`–`q2` (Ericson RTCD
/// §5.1.9, ALL degenerate branches). Returns `[closest_on_1, closest_on_2]`. A
/// segment of EXACTLY zero length (`a == 0` / `e == 0`) is treated as a POINT: if
/// both degenerate, `s = t = 0`; if only segment 1, `s = 0`, `t = clamp(f/e)`
/// (project its point onto segment 2); if only segment 2, `t = 0`, `s = clamp(−c/a)`
/// (project its point onto segment 1). The test is EXACT zero — never an absolute
/// metric floor — so a genuinely resolvable but tiny segment (e.g. `a = 6.4e-11`)
/// takes the general branch (E7); a `half_height == 0` capsule gives `a == 0`
/// exactly and takes the point branch. Every sub-branch's denominator is
/// guarded (`a > 0`, `e > 0`, `denom > 0`) + clamped.
fn closestSegSeg(comptime T: type, p1: math.Vec(3, T), q1: math.Vec(3, T), p2: math.Vec(3, T), q2: math.Vec(3, T)) [2]math.Vec(3, T) {
    const d1 = q1.sub(p1);
    const d2 = q2.sub(p2);
    const r = p1.sub(p2);
    const a = d1.dot(d1); // |seg1|²
    const e = d2.dot(d2); // |seg2|²
    const f = d2.dot(r);
    var s: T = 0;
    var t: T = 0;
    if (a <= 0 and e <= 0) {
        // Both segments are points (exact zero length).
        s = 0;
        t = 0;
    } else if (a <= 0) {
        // Segment 1 is a point ⇒ project it onto segment 2.
        s = 0;
        t = std.math.clamp(f / e, 0, 1);
    } else {
        const c = d1.dot(r);
        if (e <= 0) {
            // Segment 2 is a point ⇒ project it onto segment 1.
            t = 0;
            s = std.math.clamp(-c / a, 0, 1);
        } else {
            // General non-degenerate case.
            const b = d1.dot(d2);
            const denom = a * e - b * b;
            s = if (denom > 0) std.math.clamp((b * f - c * e) / denom, 0, 1) else 0;
            t = (b * s + f) / e;
            if (t < 0) {
                t = 0;
                s = std.math.clamp(-c / a, 0, 1);
            } else if (t > 1) {
                t = 1;
                s = std.math.clamp((b - c) / a, 0, 1);
            }
        }
    }
    return .{ p1.add(d1.scale(s)), p2.add(d2.scale(t)) };
}

/// The capsule/capsule seed: the two cores are Y-axis segments (`±half_height`
/// in each local frame). Their closest points (Ericson `closestSegSeg`) plus the
/// inflation radii give the seed; `.separated` past the inflated margin (mirrors
/// `gjk.zig`, `coord_scale = |Δcentres| + half_height_a + half_height_b`). The
/// THREE contact regimes are produced by the unchanged `generateManifold` from
/// the segments' supporting features — end-on (a count-1 endpoint → 1 point),
/// crossed / non-parallel (1 witness, via the E1 generator fix), and parallel
/// projection overlap (2 points via `clipSegment`) — so the kernel only supplies
/// `(normal, closest points, depth)`, skipping the GJK descent.
fn capsuleCapsule(
    comptime T: type,
    ca: math.Vec(3, T),
    ra: math.Quat(T),
    ha: T,
    r_a: T,
    cb: math.Vec(3, T),
    rb: math.Quat(T),
    hb: T,
    r_b: T,
) FastResult(T) {
    const Vec3T = math.Vec(3, T);
    const ay = ra.rotateVec3(Vec3T.unit_y);
    const by = rb.rotateVec3(Vec3T.unit_y);
    // Segment endpoints (a degenerate `half_height == 0` collapses to a point —
    // `closestSegSeg` guards the zero-length denominators).
    const cp = closestSegSeg(T, ca.sub(ay.scale(ha)), ca.add(ay.scale(ha)), cb.sub(by.scale(hb)), cb.add(by.scale(hb)));
    const d = cp[1].sub(cp[0]);
    const dist_sq = d.dot(d);
    const dist = @sqrt(dist_sq);
    const r_sum = r_a + r_b;
    const coord_scale = cb.sub(ca).length() + ha + hb;
    if (dist - r_sum > contactMargin(T, coord_scale)) return .separated;
    // `normalize(d)` is scale-equivariant ⇒ guard only 0/0: the fallback (radial /
    // mutual-perpendicular) fires ONLY at true coincidence (`dist² ≤ floatMin`,
    // e.g. collinear cores whose closest points coincide exactly) — E8 class A.
    const normal = if (dist_sq > std.math.floatMin(T)) d.scale(1.0 / dist) else capsuleFallbackNormal(T, ay, by, cb.sub(ca));
    return .{ .contact = .{
        .normal = normal,
        .closest_a = cp[0],
        .closest_b = cp[1],
        .base_penetration = r_sum - dist,
    } };
}

/// A deterministic separation normal for the measure-zero case of two segment
/// cores that touch (`dist ≈ 0`). For CROSSED axes the natural separation is the
/// mutual perpendicular `axis_a × axis_b`. For PARALLEL axes an axial normal is
/// WRONG (the capsules separate radially, not along their shared axis): take the
/// LATERAL (axis-perpendicular) component of `dcentre`; if that is zero too (a
/// pure collinear overlap), pick a deterministic perpendicular to the axis. Never
/// returns a component along the axis for a parallel pair (P1-3).
fn capsuleFallbackNormal(comptime T: type, axis_a: math.Vec(3, T), axis_b: math.Vec(3, T), dcentre: math.Vec(3, T)) math.Vec(3, T) {
    // `axis_a`, `axis_b` are UNIT, so `|axis_a × axis_b|² = sin²θ` is a
    // DIMENSIONLESS parallelism test — a constant floor is correct here.
    const sin2_floor: T = if (T == f32) 1.0e-12 else 1.0e-24;
    const cr = axis_a.cross(axis_b);
    const cr2 = cr.dot(cr);
    if (cr2 > sin2_floor) return cr.scale(1.0 / @sqrt(cr2)); // crossed ⇒ mutual perpendicular
    // Parallel axes: strip the axial component of `dcentre` → the radial direction.
    // Collinear ⟺ the lateral fraction `lat2/dc2 = sin²(∠(dcentre, axis))` is
    // negligible — a DIMENSIONLESS ratio (not an absolute length floor, E7). A
    // pure collinear or coincident pair (`lat2 == 0`) picks a fixed perpendicular.
    const lateral = dcentre.sub(axis_a.scale(dcentre.dot(axis_a)));
    const lat2 = lateral.dot(lateral);
    const dc2 = dcentre.dot(dcentre);
    if (lat2 > sin2_floor * dc2) return lateral.scale(1.0 / @sqrt(lat2));
    return perpendicularTo(T, axis_a); // pure collinear ⇒ any axis-perpendicular
}

/// A deterministic unit vector perpendicular to `axis` (assumed unit): cross it
/// with the world basis vector least aligned with it (so the cross is well away
/// from zero), then normalize.
fn perpendicularTo(comptime T: type, axis: math.Vec(3, T)) math.Vec(3, T) {
    const Vec3T = math.Vec(3, T);
    const a = axis.toArray();
    const ax = @abs(a[0]);
    const ay = @abs(a[1]);
    const az = @abs(a[2]);
    const basis = if (ax <= ay and ax <= az) Vec3T.unit_x else if (ay <= az) Vec3T.unit_y else Vec3T.unit_z;
    const p = axis.cross(basis);
    return p.scale(1.0 / @sqrt(p.dot(p)));
}

const testing = std.testing;

test "fastSeed dispatch routing (E3 handles sphere and box pairs)" {
    const T = f32;
    const V = math.Vec(3, T);
    const Q = math.Quat(T);
    const SS = support.SupportShape(T);
    const sphere = SS{ .core = .point, .radius = 0.5 };
    const capsule = SS{ .core = .{ .segment = 1 }, .radius = 0.3 };
    const box = SS{ .core = .{ .box = V.fromArray(.{ 1, 1, 1 }) }, .radius = 0 };
    const rbox = SS{ .core = .{ .box = V.fromArray(.{ 1, 1, 1 }) }, .radius = 0.2 }; // rounded

    const near = V.fromArray(.{ 0.4, 0, 0 }); // overlapping
    const far = V.fromArray(.{ 9, 0, 0 }); // clearly separated

    // Handled pairs → contact (near) / separated (far).
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, sphere, near, Q.identity) == .contact);
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, sphere, far, Q.identity) == .separated);
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, box, near, Q.identity) == .contact);
    try testing.expect(fastSeed(T, box, V.zero, Q.identity, sphere, near, Q.identity) == .contact);
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, box, far, Q.identity) == .separated);
    try testing.expect(fastSeed(T, box, V.zero, Q.identity, box, near, Q.identity) == .contact); // box/box (E3)
    try testing.expect(fastSeed(T, box, V.zero, Q.identity, box, far, Q.identity) == .separated);
    try testing.expect(fastSeed(T, capsule, V.zero, Q.identity, capsule, near, Q.identity) == .contact); // capsule/capsule (E4)
    try testing.expect(fastSeed(T, capsule, V.zero, Q.identity, capsule, far, Q.identity) == .separated);

    // Unsupported pairs → not_handled (fall through to generic).
    try testing.expect(fastSeed(T, capsule, V.zero, Q.identity, box, near, Q.identity) == .not_handled); // capsule/box generic
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, capsule, near, Q.identity) == .not_handled); // sphere/capsule generic
    // Any rounded box → not_handled (kernels are radius-0-box only).
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, rbox, near, Q.identity) == .not_handled);
    try testing.expect(fastSeed(T, rbox, V.zero, Q.identity, sphere, near, Q.identity) == .not_handled);
    try testing.expect(fastSeed(T, box, V.zero, Q.identity, rbox, near, Q.identity) == .not_handled);
    try testing.expect(fastSeed(T, rbox, V.zero, Q.identity, rbox, near, Q.identity) == .not_handled);
}
