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
//! **E1 status.** The foundation only: `ContactSeed`, `FastResult`, and a
//! dispatcher that returns `.not_handled` for every pair (no kernel yet). The
//! sphere/sphere + sphere/box (E2), box/box SAT (E3), and capsule/capsule (E4)
//! kernels are added behind this same three-state contract.
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
/// same fixed `(a, b)` order as `collideOrdered`.
///
/// E1: no kernel is wired yet — every pair returns `.not_handled`. E2–E4 add the
/// four frozen fast paths (sphere/sphere, sphere/box, capsule/capsule, box/box),
/// each gated on a box core having `radius == 0`.
pub fn fastSeed(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) FastResult(T) {
    // E1 foundation: the dispatcher is a pure no-op. `collideOrdered` therefore
    // behaves exactly as `collideOrderedGeneric` until the kernels land (E2–E4).
    _ = shape_a;
    _ = pos_a;
    _ = rot_a;
    _ = shape_b;
    _ = pos_b;
    _ = rot_b;
    return .not_handled;
}

const testing = std.testing;

test "fastSeed is a no-op at E1 (every pair falls through)" {
    const T = f32;
    const V = math.Vec(3, T);
    const Q = math.Quat(T);
    const SS = support.SupportShape(T);
    const shapes = [_]SS{
        .{ .core = .point, .radius = 0.5 },
        .{ .core = .{ .segment = 1 }, .radius = 0.3 },
        .{ .core = .{ .box = V.fromArray(.{ 1, 1, 1 }) }, .radius = 0 },
        .{ .core = .{ .box = V.fromArray(.{ 0.5, 0.5, 0.5 }) }, .radius = 1 }, // rounded box
    };
    for (shapes) |sa| {
        for (shapes) |sb| {
            const r = fastSeed(T, sa, V.zero, Q.identity, sb, V.fromArray(.{ 0.4, 0, 0 }), Q.identity);
            try testing.expect(r == .not_handled);
        }
    }
}
