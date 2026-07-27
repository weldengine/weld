//! `forge_3d/pipeline/narrowphase/raycast.zig` — the analytic ray↔shape kernels
//! (M1.1.9).
//!
//! **Cores + inflation radius, the same convention and never a second one.** A
//! sphere is a point of radius `r`, a capsule a Y-segment of radius `r`, a box
//! the box itself of radius 0 — exactly the `SupportShape(T).Core` split GJK/EPA
//! and the fast paths already run on (`engine-physics-forge.md` §1.11.3). A
//! rounded box (`radius > 0` on a box core) is outside this kernel's shape set: it
//! is an ASSERTED PRECONDITION (`raySupportsShape`), never silently approximated.
//! The typed refusal lives where a CALLER can provoke one, at the two query entries
//! taking a caller-supplied shape handle (§1.11.7, M1.1.11) — through this kernel
//! the error was reachable by no path at all, every stored box converting with
//! `radius = 0`. A core this file does not know cannot exist silently either — the
//! `switch` is exhaustive, so a future `Core` case is a compile error here, which is
//! fail-loud at the earliest possible moment.
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

/// A ray hit on one shape, in that shape's local frame. Defined in `support.zig`
/// since M1.1.11: `plane.zig` produces the same type for the half-space, and the
/// `BodyId`-level adapter that dispatches between the two by shape class returns one
/// type rather than two identical ones.
const LocalHit = support.LocalHit;

/// Slack allowed on the unit-direction domain assert, in ULPs of 1. The caller
/// normalises, then a quaternion inverse-rotation into the local frame costs a
/// handful of ULPs on the norm; the comparison is against 1, so this is float
/// noise at scale 1 and not a geometric tolerance.
const unit_k: comptime_int = 16;

/// Whether the ray kernels cover `shape`: every core, EXCEPT a box carrying a
/// non-zero inflation radius. A rounded box's inflated surface is measured by no arm
/// below — the box arm would under-report it by the radius — so it is not part of
/// this kernel's shape set.
///
/// **The PRECONDITION of `rayShape`, exposed as a predicate** (M1.1.11). Two things
/// it makes structural rather than merely tested: it takes no origin, so the
/// rejection provably belongs to the SHAPE and not to the trajectory; and the two
/// callers that need to decide admissibility ahead of a call test the same condition
/// the assert tests, instead of restating it.
pub fn raySupportsShape(comptime T: type, shape: support.SupportShape(T)) bool {
    return !(shape.core == .box and shape.radius != 0);
}

/// Nearest ray↔shape intersection, or `null` when the ray misses.
///
/// `origin` and `direction` are in `shape`'s local frame and `direction` must be
/// unit (asserted).
///
/// **PRECONDITION: `raySupportsShape(T, shape)`.** It was a typed
/// `error.UnsupportedShape` until M1.1.11, and the error was reachable through no
/// path at all: `shape.supportShape` gives every box `radius = 0` unconditionally, so
/// no `SupportShape` built from a stored shape can be a rounded box, and a control
/// that has never been seen to fire is a comment with syntax rather than a check
/// (§1.11.3). The typed refusal moved to where a CALLER can cause it — the two query
/// entries taking a caller-supplied shape handle (§1.11.7) — and what stays here is
/// the assert. If Weld ever gives boxes a convex radius, as the reference does, this
/// kernel gains the CASE; it does not regain an error.
pub fn rayShape(
    comptime T: type,
    shape: support.SupportShape(T),
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) ?LocalHit(T) {
    std.debug.assert(@abs(direction.lengthSq() - 1) <= unit_k * std.math.floatEps(T));

    // The shape precondition comes FIRST, before anything looks at the origin: a
    // rounded box is unsupported as a SHAPE, and that answer cannot depend on
    // where the ray starts. When this was a typed error placed AFTER the membership
    // test below, an origin inside the core returned a distance-zero hit and never
    // reached the check — the exact silent miss this file promises not to allow.
    //
    // The placement is now REDUNDANTLY protected, and the redundancy is the point:
    // `containsPoint`'s box arm carries its own unconditional `assert(r == 0)`, taken
    // for ANY point, so moving this line below the membership test would not
    // reintroduce a silent miss — it would panic one frame deeper, at every origin.
    // That is a structural guarantee rather than a sampled one. It is also why
    // `containsPoint`'s assert must not be deleted as redundant: it is what makes
    // THIS line's position unable to fail silently.
    std.debug.assert(raySupportsShape(T, shape));

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
            // Defensive: the hoisted check above already rejected a rounded box,
            // so this cannot fire — it is kept so a future edit that moves the
            // rejection breaks here loudly instead of silently approximating.
            std.debug.assert(shape.radius == 0);
            return rayBox(T, half_extents, origin, direction);
        },
        .segment => |half_height| return rayCapsule(T, half_height, shape.radius, origin, direction),
    }
}

/// Whether `p` lies in the solid shape, boundary INCLUDED (the body is closed,
/// and this matches the face-inclusive convention of `Aabb.contains`).
///
/// Precondition: a box core carries `radius == 0`. A rounded box is not part of
/// this shape set and its inflated volume is NOT what the box arm measures, so
/// asking this function about one is a programming error — asserted here rather
/// than left to the caller's protection, since this is `pub` and reachable
/// directly through the package facade. Same shape of invariant as `supportShape`
/// and `worldAabb`, which carry theirs explicitly instead of tacitly.
pub fn containsPoint(comptime T: type, shape: support.SupportShape(T), p: math.Vec(3, T)) bool {
    const r = shape.radius;
    switch (shape.core) {
        .point => return p.lengthSq() <= r * r,
        .box => |half_extents| {
            // A rounded box is outside this shape set: the test below measures the
            // CORE, so it would under-report the inflated volume by the radius.
            //
            // **DO NOT DELETE THIS AS REDUNDANT.** It is unconditional and taken for
            // ANY point, which is precisely what makes `rayShape`'s precondition
            // unable to fail silently if a future edit moves it below the membership
            // test: the failure would land here, at every origin, instead of becoming
            // a distance-zero hit. The two asserts are one mechanism.
            std.debug.assert(r == 0);
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
    const entry = sphereEntryFromOutside(T, r, origin, direction) orelse return null;
    return .{ .distance = entry.t, .normal = sphereNormal(T, r, entry.offset, direction) };
}

/// Entry of the sphere of radius `r` centred on the origin of `rel_origin`'s
/// frame, assuming `rel_origin` is strictly outside it: the parameter `t` and the
/// hit point's offset FROM THE CENTRE.
///
/// Both roots share the sign of their product `|o|² − r² > 0`, so a negative near
/// root means the whole sphere is behind the ray — no separate far-root branch is
/// needed.
///
/// Neither output is computed by subtracting large near-equal quantities, and that
/// is the whole point of this shape:
///
///   - the discriminant is `r² − |w|²` where `w = o − (o · d)·d` is the
///     PERPENDICULAR offset, not `b² − c`. The two are equal algebraically — with
///     `d` unit, `|w|² = |o|² − b²` — but `b²` and `c` are both of order `|o|²`
///     and their difference is of order `r²`, so the subtraction cancels
///     catastrophically far from the shape. At f32, a radius-1 sphere 5 000 m away
///     gives `b² = c = 2.5e7` after rounding, hence `disc = 0`: an entry short by
///     exactly the radius.
///   - the hit offset is `w − √disc · d`, not `o + t·d`. The latter adds a large
///     `t` to a large `o` to land on a point of magnitude `r`, losing the absolute
///     precision of the large operands; both terms of the former are bounded by
///     `r`. This one matters for the NORMAL, which is that offset over `r` — the
///     same cancellation as the discriminant, one step later, and found by the
///     test written for the first.
fn sphereEntryFromOutside(
    comptime T: type,
    r: T,
    rel_origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) ?struct { t: T, offset: math.Vec(3, T) } {
    const b = rel_origin.dot(direction);
    const w = rel_origin.sub(direction.scale(b));
    const disc = r * r - w.lengthSq();
    if (disc < 0) return null;
    const root = @sqrt(disc);
    const t = -b - root;
    if (t < 0) return null; // sphere entirely behind the origin
    return .{ .t = t, .offset = w.sub(direction.scale(root)) };
}

/// Outward normal of the sphere of radius `r` from the hit point's `offset`
/// relative to the sphere centre.
///
/// The vector is NORMALISED, not merely divided by `r`. That makes the returned
/// length a structural invariant — exactly unit to a few ulp at ANY distance,
/// §1.11.4 bis — instead of a quantity that drifts with range: `|offset|` is only
/// `r` to the precision of the coordinates it was built from, so `offset / r`
/// inherited that drift and measured 0.8557 at 2e6 radii. What the conditioning
/// cannot recover is the ORIENTATION, and separating the two is the point: a
/// degenerate or short normal is now always a defect and never an effect of
/// distance. The cost is one `sqrt` per ACCEPTED hit, not per candidate.
fn sphereNormal(comptime T: type, r: T, offset: math.Vec(3, T), direction: math.Vec(3, T)) math.Vec(3, T) {
    // Guard at TRUE ZERO, not at an epsilon: `r == 0` is a degenerate
    // point-sphere, whose surface point IS its centre, so there is no outward
    // direction to report. `−direction` is the same choice §1.11.4 makes for the
    // distance-zero case, it keeps `normal · direction <= 0` true here too, and it
    // is already unit — so it bypasses the normalisation rather than dividing by a
    // zero-length offset.
    if (r == 0) return direction.neg();
    return offset.normalize();
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
    // `c` survives only for the axis-parallel branch below, where the radial
    // offset is bounded by the ray's own distance from the axis — small by
    // construction — so it carries none of the far-field cancellation the
    // discriminant had.
    const c = o[0] * o[0] + o[2] * o[2] - r * r;

    // TRUE ZERO, no epsilon: zero radial speed means the ray runs parallel to
    // the capsule axis, the radial distance never changes, and the quadratic
    // degenerates. Outside the cylinder it can never enter; inside it, the entry
    // is necessarily on a cap.
    if (a == 0) {
        if (c > 0) return null;
        return capEntry(T, half_height, r, origin, direction);
    }

    // Same cancellation-free form as the sphere, in the two radial axes: at the
    // parameter of closest radial approach `t_ca = −b/a`, the radial offset is
    // `w`, and `a·(r² − |w|²) == b² − a·c` algebraically while squaring only small
    // quantities. Verified as an identity before being written, and the f32
    // far-field failure of the `b² − a·c` form is the same one the sphere had.
    const t_ca = -b / a;
    const wx = o[0] + t_ca * d[0];
    const wz = o[2] + t_ca * d[2];
    const disc = a * (r * r - (wx * wx + wz * wz));
    // The capsule is contained in its infinite cylinder (both caps have radial
    // extent `r`), so missing the cylinder misses the capsule.
    if (disc < 0) return null;

    const root = @sqrt(disc);
    const t_cyl = (-b - root) / a;
    if (t_cyl >= 0) {
        const y = o[1] + t_cyl * d[1];
        if (@abs(y) <= half_height) {
            // Radial offset built the same cancellation-free way as the sphere's:
            // `w_xz − (√disc / a)·d_xz`, both terms bounded by `r`, rather than
            // `o_xz + t·d_xz`, which lands on a point of magnitude `r` by
            // subtracting two quantities of magnitude `|o_xz|`.
            const step = root / a;
            const offset_x = wx - step * d[0];
            const offset_z = wz - step * d[2];
            return .{
                .distance = t_cyl,
                .normal = capsuleRadialNormal(T, r, offset_x, offset_z, direction),
            };
        }
    }
    // Either the cylinder entry is behind the origin, or it lies beyond a cap
    // plane: what remains of the capsule is the caps.
    return capEntry(T, half_height, r, origin, direction);
}

/// Radial outward normal of the capsule wall from the hit point's radial offset
/// from the axis. The Y component is zero on the cylindrical part.
///
/// Normalised for the same reason as `sphereNormal`: the length is an invariant,
/// only the orientation carries the far-field residue (§1.11.4 bis).
fn capsuleRadialNormal(comptime T: type, r: T, offset_x: T, offset_z: T, direction: math.Vec(3, T)) math.Vec(3, T) {
    // TRUE ZERO guard, same reasoning as `sphereNormal`: `r == 0` is a bare
    // segment with no wall to carry a normal, and `−direction` is already unit.
    if (r == 0) return direction.neg();
    return math.Vec(3, T).fromArray(.{ offset_x, 0, offset_z }).normalize();
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

    const hit_top = sphereEntryFromOutside(T, r, origin.sub(top), direction);
    const hit_bottom = sphereEntryFromOutside(T, r, origin.sub(bottom), direction);

    // Fixed tie-break on an exact tie: the `+Y` cap, mirroring `support`'s
    // `dir.y >= 0` choice.
    const chosen = if (hit_top) |ht| blk: {
        if (hit_bottom) |hb| {
            break :blk if (hb.t < ht.t) hb else ht;
        }
        break :blk ht;
    } else if (hit_bottom) |hb| hb else return null;

    // The offset is already relative to the chosen cap's centre and free of the
    // far-field cancellation, so the normal needs no world point at all.
    return .{ .distance = chosen.t, .normal = sphereNormal(T, r, chosen.offset, direction) };
}
