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
//! **sphere/box** (both orders) — each with a `separated` short-circuit (no
//! GJK). Box/box SAT (E3) and capsule/capsule (E4) follow behind this same
//! three-state contract. Anything not yet wired (capsule/*, box/box, a rounded
//! box) returns `.not_handled`.
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
/// Wired (E2): sphere/sphere and sphere/box (both orders). `.not_handled` for
/// everything else (box/box → E3, capsule/capsule → E4, capsule/box and
/// sphere/capsule stay generic), and for any box core with `radius > 0` (a
/// rounded box — the kernels are radius-0-box only).
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
        },
        .box => |he_a| switch (shape_b.core) {
            // box (A) / sphere (B).
            .point => return sphereBox(T, pos_b, shape_b.radius, pos_a, rot_a, he_a, shape_a.radius, .box_is_a),
            else => return .not_handled, // box/box → E3, box/capsule stays generic
        },
        .segment => return .not_handled, // capsule/capsule → E4, others stay generic
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
/// fallback normal at coincidence (matching the generic `fallbackNormal`, where
/// the A→B axis is geometrically undefined — a measure-zero tie).
fn sphereSphere(comptime T: type, ca: math.Vec(3, T), ra: T, cb: math.Vec(3, T), rb: T) FastResult(T) {
    const d = cb.sub(ca);
    const dist_sq = d.dot(d);
    const dist = @sqrt(dist_sq);
    const r_sum = ra + rb;
    if (dist - r_sum > contactMargin(T, dist)) return .separated;
    const coincidence: T = if (T == f32) 1.0e-12 else 1.0e-24;
    const normal = if (dist_sq > coincidence) d.scale(1.0 / dist) else math.Vec(3, T).unit_x;
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
        const coincidence: T = if (T == f32) 1.0e-12 else 1.0e-24;
        // Normal from the box surface toward the sphere centre; on the surface
        // (dist ≈ 0, the shallow↔deep seam) fall back to the centre direction.
        const n_local = if (dist_sq > coincidence) delta.scale(1.0 / dist) else fallbackLocalNormal(T, c_local);
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

const testing = std.testing;

test "fastSeed dispatch routing (E2 handles the point-core pairs)" {
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

    // Handled point-core pairs → contact (near) / separated (far).
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, sphere, near, Q.identity) == .contact);
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, sphere, far, Q.identity) == .separated);
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, box, near, Q.identity) == .contact);
    try testing.expect(fastSeed(T, box, V.zero, Q.identity, sphere, near, Q.identity) == .contact);
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, box, far, Q.identity) == .separated);

    // Not-yet-wired / unsupported pairs → not_handled (fall through to generic).
    try testing.expect(fastSeed(T, box, V.zero, Q.identity, box, near, Q.identity) == .not_handled); // E3
    try testing.expect(fastSeed(T, capsule, V.zero, Q.identity, capsule, near, Q.identity) == .not_handled); // E4
    try testing.expect(fastSeed(T, capsule, V.zero, Q.identity, box, near, Q.identity) == .not_handled); // generic
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, capsule, near, Q.identity) == .not_handled); // generic
    // Rounded box in a sphere/box pair → not_handled (kernels are radius-0-box only).
    try testing.expect(fastSeed(T, sphere, V.zero, Q.identity, rbox, near, Q.identity) == .not_handled);
    try testing.expect(fastSeed(T, rbox, V.zero, Q.identity, sphere, near, Q.identity) == .not_handled);
}
