//! `forge_3d/pipeline/narrowphase/raycast.zig` — the analytic ray↔shape kernels
//! (M1.1.9).
//!
//! **Cores + inflation radius, the same convention and never a second one.** A
//! sphere is a point of radius `r`, a capsule a Y-segment of radius `r`, a box
//! the box itself of radius 0 — exactly the `SupportShape(T).Core` split GJK/EPA
//! and the fast paths already run on (`engine-physics-forge.md` §1.11.3). A
//! rounded box (`radius > 0` on a box core) is **rejected**, never silently
//! approximated: it FAILS LOUD with `error.UnsupportedShape` rather than miss a
//! hit quietly, the same invariant `createShape` enforces. A core this file does
//! not know cannot exist silently either — the `switch` is exhaustive, so a
//! future `Core` case is a compile error here, which is fail-loud at the earliest
//! possible moment.
//!
//! **Everything is in the shape's LOCAL frame.** The caller transports the ray
//! by the inverse pose and rotates the returned normal back to world (that is
//! `BodyManager.raycastBody`'s job, E4). Local framing keeps the algebra centred
//! on the shape, which is where the precision is, and mirrors the narrowphase's
//! frame-of-A discipline.
//!
//! **Hit semantics (§1.11.4).** The direction is UNIT, so the returned parameter
//! IS a distance and never a fraction. Convexes are SOLID: an origin inside —
//! boundary included, the body being closed — is a hit at distance zero whose
//! normal is `−direction`, the only choice that preserves `normal · direction
//! <= 0` on every hit. There is no `max_distance` here: the kernel reports the
//! nearest entry at or beyond zero and the caller intersects that with its own
//! window, so one kernel serves the closest / any / all collectors unchanged.
//!
//! **Threshold discipline.** Every guard is at TRUE ZERO — the zero direction
//! component in the box slabs, the zero radial speed of a capsule-axis-parallel
//! ray, the degenerate zero radius. No geometric epsilon appears anywhere: the
//! reference's sphere and cylinder kernels carry none either (§1.11.3). The one
//! named tolerance is the unit-direction domain assert, which is compared
//! against 1 and is therefore pure float noise, `k · floatEps(T)`.
//!
//! **Dependency discipline.** Imports `foundation` (math) and the sibling
//! `support.zig` ONLY — never `manifold.zig`, `gjk.zig`, `epa.zig`,
//! `weld_forge`, `body*.zig`, `config.zig` or `broadphase.zig`. Identical to
//! `fast_paths.zig`; the scalar is the comptime `T` and `forge_3d` instantiates
//! it at `config.Real`.

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");

/// A ray hit on one shape, in that shape's local frame.
pub fn LocalHit(comptime T: type) type {
    return struct {
        /// Distance along the (unit) direction, `>= 0`. Zero when the origin is
        /// inside the solid shape.
        distance: T,
        /// Outward unit surface normal at the hit point, local frame. At distance
        /// zero it is `−direction` (§1.11.4).
        normal: math.Vec(3, T),
    };
}

/// Slack allowed on the unit-direction domain assert, in ULPs of 1. The caller
/// normalises, then a quaternion inverse-rotation into the local frame costs a
/// handful of ULPs on the norm; the comparison is against 1, so this is float
/// noise at scale 1 and not a geometric tolerance.
const unit_k: comptime_int = 16;

/// Nearest ray↔shape intersection, or `null` when the ray misses.
///
/// `origin` and `direction` are in `shape`'s local frame and `direction` must be
/// unit (asserted). A rounded box returns `error.UnsupportedShape` — see the file
/// header on why that is an error and not an approximation.
pub fn rayShape(
    comptime T: type,
    shape: support.SupportShape(T),
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) error{UnsupportedShape}!?LocalHit(T) {
    std.debug.assert(@abs(direction.lengthSq() - 1) <= unit_k * std.math.floatEps(T));

    // Solid convex: inside — boundary included — is a hit at distance zero, and
    // the normal is `−direction` because no surface normal is defined there
    // (§1.11.4). Testing membership up front also removes every negative-root
    // special case from the kernels below, which may then assume the origin is
    // strictly outside.
    if (containsPoint(T, shape, origin)) {
        return .{ .distance = 0, .normal = direction.neg() };
    }

    switch (shape.core) {
        .point => return raySphere(T, shape.radius, origin, direction),
        .box => |half_extents| {
            // A rounded box is out of this milestone's shape set. Fail loud.
            if (shape.radius != 0) return error.UnsupportedShape;
            return rayBox(T, half_extents, origin, direction);
        },
        .segment => |half_height| return rayCapsule(T, half_height, shape.radius, origin, direction),
    }
}

/// Whether `p` lies in the solid shape, boundary INCLUDED (the body is closed,
/// and this matches the face-inclusive convention of `Aabb.contains`).
pub fn containsPoint(comptime T: type, shape: support.SupportShape(T), p: math.Vec(3, T)) bool {
    const r = shape.radius;
    switch (shape.core) {
        .point => return p.lengthSq() <= r * r,
        .box => |half_extents| {
            // The inflation radius of a box is 0 in this shape set; a rounded box
            // is rejected by `rayShape` before it can reach here.
            const a = p.abs();
            return @reduce(.And, a.data <= half_extents.data);
        },
        .segment => |half_height| {
            const q = closestPointOnAxis(T, half_height, p);
            return p.sub(q).lengthSq() <= r * r;
        },
    }
}

/// The point of the Y-axis segment `±half_height` closest to `p`.
fn closestPointOnAxis(comptime T: type, half_height: T, p: math.Vec(3, T)) math.Vec(3, T) {
    const y = std.math.clamp(p.toArray()[1], -half_height, half_height);
    return math.Vec(3, T).fromArray(.{ 0, y, 0 });
}

/// Ray against a sphere of radius `r` centred on the local origin, the origin
/// strictly outside. Roots of `|o + t·d|² = r²` with `|d| = 1`, so the quadratic
/// is monic: `t² + 2(o·d)·t + (|o|² − r²) = 0`.
fn raySphere(comptime T: type, r: T, origin: math.Vec(3, T), direction: math.Vec(3, T)) ?LocalHit(T) {
    const t = sphereEntryFromOutside(T, r, origin, direction) orelse return null;
    const p = origin.add(direction.scale(t));
    return .{ .distance = t, .normal = sphereNormal(T, r, p, direction) };
}

/// Nearest root `>= 0` of the sphere of radius `r` centred on the origin of
/// `rel_origin`'s frame, assuming `rel_origin` is strictly outside it.
///
/// Both roots then share the sign of their product `|o|² − r² > 0`, so a
/// negative near root means the whole sphere is behind the ray — no separate
/// far-root branch is needed.
fn sphereEntryFromOutside(comptime T: type, r: T, rel_origin: math.Vec(3, T), direction: math.Vec(3, T)) ?T {
    const b = rel_origin.dot(direction);
    const c = rel_origin.lengthSq() - r * r;
    const disc = b * b - c;
    if (disc < 0) return null;
    const t = -b - @sqrt(disc);
    if (t < 0) return null; // sphere entirely behind the origin
    return t;
}

/// Outward normal of the sphere of radius `r` at surface point `p` (sphere
/// centred on the local origin).
fn sphereNormal(comptime T: type, r: T, p: math.Vec(3, T), direction: math.Vec(3, T)) math.Vec(3, T) {
    // Guard at TRUE ZERO, not at an epsilon: `r == 0` is a degenerate
    // point-sphere, whose surface point IS its centre, so there is no outward
    // direction to report. `−direction` is the same choice §1.11.4 makes for the
    // distance-zero case, and it keeps `normal · direction <= 0` true here too.
    if (r == 0) return direction.neg();
    return p.scale(1 / r);
}

/// Ray against a box core of half-extents `he` (radius 0, centred on the local
/// origin), the origin strictly outside. Slab test carrying the entry AXIS,
/// which is what the face normal needs.
///
/// This does not call `Aabb.rayInterval`: that function deliberately returns the
/// interval alone, and recovering the entry axis from `enter` afterwards would
/// mean recomputing the per-axis parameters anyway. The two must agree, and a
/// test pins that agreement rather than a comment claiming it.
fn rayBox(comptime T: type, he: math.Vec(3, T), origin: math.Vec(3, T), direction: math.Vec(3, T)) ?LocalHit(T) {
    const o = origin.toArray();
    const d = direction.toArray();
    const h = he.toArray();

    var t_enter: T = -std.math.inf(T);
    var t_exit: T = std.math.inf(T);
    var axis: usize = 0;
    var normal_sign: T = 1;

    for (0..3) |i| {
        // TRUE ZERO, no epsilon: a component that is exactly zero makes the ray
        // parallel to that slab, so the axis leaves the product and is replaced
        // by containment of the origin in the slab — the same rule, and the same
        // justification, as `Aabb.rayInterval`.
        if (d[i] == 0) {
            if (o[i] < -h[i] or o[i] > h[i]) return null;
            continue;
        }
        const inv = 1 / d[i];
        var t1 = (-h[i] - o[i]) * inv;
        var t2 = (h[i] - o[i]) * inv;
        // `0 · inf` is the only NaN reachable here (an exactly-zero numerator
        // against a reciprocal that overflowed on a subnormal component) and its
        // exact quotient is zero — the same exact repair as `Aabb.rayInterval`,
        // never a tolerance.
        if (t1 != t1) t1 = 0;
        if (t2 != t2) t2 = 0;

        const near = @min(t1, t2);
        const far = @max(t1, t2);
        // Strict `>`: the FIRST axis wins an exact tie (a corner or edge entry),
        // the fixed tie-break convention of this package.
        if (near > t_enter) {
            t_enter = near;
            axis = i;
            // Entering along `+d` on this axis means crossing the face whose
            // outward normal opposes the ray.
            normal_sign = if (d[i] > 0) -1 else 1;
        }
        t_exit = @min(t_exit, far);
    }

    if (t_enter > t_exit) return null; // slabs do not meet
    if (t_exit < 0) return null; // box entirely behind the origin

    // The origin is outside (checked by `rayShape`), so the entry parameter is at
    // or beyond zero and at least one axis constrained it.
    var n = [3]T{ 0, 0, 0 };
    n[axis] = normal_sign;
    return .{ .distance = t_enter, .normal = math.Vec(3, T).fromArray(n) };
}

/// Ray against a capsule core: the Y-axis segment `±half_height` inflated by
/// `r`, the origin strictly outside. Infinite cylinder of radius `r` first, then
/// — outside the `|y| <= half_height` slab — the two cap spheres. That is
/// literally the core + radius convention, and the same decomposition the
/// reference uses (`RayCylinder`, then `RaySphere` per cap).
fn rayCapsule(
    comptime T: type,
    half_height: T,
    r: T,
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) ?LocalHit(T) {
    const o = origin.toArray();
    const d = direction.toArray();

    // Radial (XZ) quadratic of the infinite cylinder.
    const a = d[0] * d[0] + d[2] * d[2];
    const b = o[0] * d[0] + o[2] * d[2];
    const c = o[0] * o[0] + o[2] * o[2] - r * r;

    // TRUE ZERO, no epsilon: zero radial speed means the ray runs parallel to
    // the capsule axis, the radial distance never changes, and the quadratic
    // degenerates. Outside the cylinder it can never enter; inside it, the entry
    // is necessarily on a cap.
    if (a == 0) {
        if (c > 0) return null;
        return capEntry(T, half_height, r, origin, direction);
    }

    const disc = b * b - a * c;
    // The capsule is contained in its infinite cylinder (both caps have radial
    // extent `r`), so missing the cylinder misses the capsule.
    if (disc < 0) return null;

    const t_cyl = (-b - @sqrt(disc)) / a;
    if (t_cyl >= 0) {
        const y = o[1] + t_cyl * d[1];
        if (@abs(y) <= half_height) {
            const p = origin.add(direction.scale(t_cyl));
            return .{ .distance = t_cyl, .normal = capsuleRadialNormal(T, r, p, direction) };
        }
    }
    // Either the cylinder entry is behind the origin, or it lies beyond a cap
    // plane: what remains of the capsule is the caps.
    return capEntry(T, half_height, r, origin, direction);
}

/// Radial outward normal of the capsule wall at surface point `p`: the XZ
/// component, the Y component being zero on the cylindrical part.
fn capsuleRadialNormal(comptime T: type, r: T, p: math.Vec(3, T), direction: math.Vec(3, T)) math.Vec(3, T) {
    // TRUE ZERO guard, same reasoning as `sphereNormal`: `r == 0` is a bare
    // segment with no wall to carry a normal.
    if (r == 0) return direction.neg();
    const pa = p.toArray();
    return math.Vec(3, T).fromArray(.{ pa[0] / r, 0, pa[2] / r });
}

/// Nearest entry on either cap sphere of the capsule, the origin being strictly
/// outside the capsule and therefore outside both caps.
fn capEntry(
    comptime T: type,
    half_height: T,
    r: T,
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) ?LocalHit(T) {
    const Vec3T = math.Vec(3, T);
    const top = Vec3T.fromArray(.{ 0, half_height, 0 });
    const bottom = Vec3T.fromArray(.{ 0, -half_height, 0 });

    const t_top = sphereEntryFromOutside(T, r, origin.sub(top), direction);
    const t_bottom = sphereEntryFromOutside(T, r, origin.sub(bottom), direction);

    // Fixed tie-break on an exact tie: the `+Y` cap, mirroring `support`'s
    // `dir.y >= 0` choice.
    var t: T = undefined;
    var centre: Vec3T = undefined;
    if (t_top) |tt| {
        if (t_bottom) |tb| {
            if (tb < tt) {
                t = tb;
                centre = bottom;
            } else {
                t = tt;
                centre = top;
            }
        } else {
            t = tt;
            centre = top;
        }
    } else if (t_bottom) |tb| {
        t = tb;
        centre = bottom;
    } else return null;

    const p = origin.add(direction.scale(t));
    return .{ .distance = t, .normal = sphereNormal(T, r, p.sub(centre), direction) };
}
