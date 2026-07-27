//! `forge_3d/pipeline/narrowphase/plane.zig` — the analytic half-space kernels
//! (M1.1.11).
//!
//! A `Plane` is the **solid half-space** `{ x : n·x <= d }`, `n` unit and `d` in
//! metres (`engine-physics-forge.md` §1.11.15). It is not a bounded convex: its
//! support map diverges in every direction but `−n`, so it traverses neither GJK,
//! nor EPA, nor the M1.1.10 cast kernel, and it is never converted into a
//! `SupportShape`. The category is chosen upstream, by `Shape.class()`.
//!
//! **Closed forms, and therefore CHEAPER than GJK rather than costlier.** Every
//! kernel below is one support call and a division at most — no descent, no
//! simplex, no restart, no iteration ceiling. That is the compensation for the
//! taxonomy: the shape that does not fit the general machinery is the one that
//! needs none of it.
//!
//! **The sign of the separation IS the classification.** Exactly, with nothing to
//! absorb: there is no accumulated rounding here, no simplex to converge, so §3's
//! three-band `separated` / `shallow` / `deep` regime does not apply and must not
//! be copied in. `sep > 0` is disjoint, `sep <= 0` is penetrating by `−sep`.
//!
//! **Threshold discipline — exactly TWO guards, both at TRUE ZERO**, and both on
//! `n·dir`: one on the ray, one on the cast. No geometric epsilon appears anywhere
//! in this file. A ray or a sweep parallel to the boundary is a miss when it starts
//! outside, and when it starts inside solid membership has already answered before
//! the division is reached. The only named tolerances are the unit-domain asserts,
//! compared against 1, which are float noise and not geometry.
//!
//! **Conditioning.** The contact normal is the STORED `n`, returned verbatim: its
//! norm is exactly that of a value normalised once at shape creation, at any
//! distance from the world origin, with no arithmetic in between. So unlike the
//! ray kernels of §1.11.4 bis — where the normal is reconstructed and only its
//! length is invariant — here BOTH the length and the orientation are exact. What
//! carries the far-field residue instead is the scalar `signedDistance`, which is
//! `n·p − d`, a difference of two quantities that both grow with distance from the
//! origin; its absolute error therefore grows like `floatEps(T)·|p|`. That is the
//! same structural worldspace limit `-Dphysics_f64` answers, characterised and not
//! hidden.
//!
//! **Dependency discipline.** Imports `foundation` (math) and the sibling
//! `support.zig` ONLY — never `gjk.zig`, `epa.zig`, `manifold.zig`, `raycast.zig`,
//! `shapecast.zig`, `weld_forge`, `body*.zig`, `config.zig` or `broadphase.zig`.
//! Identical to `raycast.zig` and `shapecast.zig`; the scalar is the comptime `T`
//! and `forge_3d` instantiates it at `config.Real`. The shared `LocalHit` and
//! `CastHit` live in `support.zig` for exactly this reason: the adapter that
//! dispatches between a convex and a half-space by shape class must return ONE
//! type.

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");

/// Slack on a unit-norm domain assert, in ULPs of 1. The comparison is against 1,
/// so this is pure float noise — same constant and same role as `raycast.zig`'s
/// `unit_k` and `shapecast.zig`'s `unit_dir_k`. A half-space transported into
/// another frame by a quaternion rotation costs a handful of ULPs on the norm,
/// which is exactly what this budgets and nothing more.
const unit_k: comptime_int = 16;

/// A solid half-space `{ x : normal·x <= distance }`, expressed in some frame.
///
/// Which frame is the CALLER's statement: every kernel below takes the half-space
/// and its other geometric argument in the SAME frame, and `transformed` is how a
/// caller moves one. `ShapeStore` holds the local-frame form, `n` normalised once
/// at creation so no consumer re-normalises.
pub fn HalfSpace(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = math.Vec(3, T);
        const QuatT = math.Quat(T);

        /// Outward unit normal — the solid lies on the `normal·x <= distance` side.
        normal: Vec3T,
        /// Offset along `normal` (metres). The boundary plane is `normal·x = distance`.
        distance: T,

        /// This half-space expressed in the frame a pose maps INTO: a point `x` of the
        /// current frame sits at `rotation·x + translation` in the target one.
        ///
        /// `{ x : n·x <= d }` becomes `{ y : (q·n)·y <= d + (q·n)·t }`. The derivation
        /// is one substitution — `x = conj(q)·(y − t)`, and a rotation preserves the dot
        /// product, so `n · conj(q)·v == (q·n) · v` — and it is exact in the sense that
        /// matters: the normal is only ROTATED, so it stays unit to the few ULPs the
        /// rotation costs, and the offset picks up one dot product. There is no
        /// alternative form that avoids that dot product: it IS the plane's distance to
        /// the new origin.
        pub fn transformed(self: Self, rotation: QuatT, translation: Vec3T) Self {
            const n = rotation.rotateVec3(self.normal);
            return .{ .normal = n, .distance = self.distance + n.dot(translation) };
        }

        /// `normal·p − distance`: strictly negative inside the solid, zero exactly on
        /// the boundary, positive outside. THE scalar of this shape — every kernel
        /// below is written on it, so the subtraction that carries the far-field
        /// residue happens in ONE place.
        pub fn signedDistance(self: Self, p: Vec3T) T {
            return self.normal.dot(p) - self.distance;
        }

        /// Domain assertion: the normal is unit. Not cosmetic — every kernel treats it
        /// as unit when it divides by `n·dir`, projects along it, or returns it as a
        /// contact normal, and a non-unit normal would scale `signedDistance` silently.
        pub fn assertUnit(self: Self) void {
            std.debug.assert(@abs(self.normal.lengthSq() - 1) <= unit_k * std.math.floatEps(T));
        }
    };
}

/// The closest point on a half-space to a queried point, with the distance to the
/// SOLID (`closestPoint`).
pub fn Projection(comptime T: type) type {
    return struct {
        /// Distance from the queried point to the solid; 0 for a point inside it,
        /// boundary included.
        distance: T,
        /// The orthogonal projection on the boundary plane, or the queried point
        /// itself when that point is already inside the solid.
        position: math.Vec(3, T),
    };
}

/// **Separation between a half-space and a bounded convex B**, and the first row of
/// §1.11.15's kernel table:
///
/// ```
/// sep = n · supportCore_B(−n) − r_b − d
/// ```
///
/// `plane` is in A's frame — A being the half-space — and `relpose` carries B
/// relative to A, exactly as GJK takes them. The contact normal (A→B) is
/// `plane.normal` VERBATIM, and the penetration is `−sep` when `sep <= 0`; neither
/// needs a function, and inventing one would suggest there is a computation where
/// there is a field.
///
/// **The `− r_b` term is not a detail.** `SupportShape.support` returns the support
/// of the CORE, radius EXCLUDED — its own doc comment says so — so a sphere's core
/// is a single point at its centre and a capsule's is a segment on its axis.
/// Omitting the term places the contact at the sphere's CENTRE: a unit sphere whose
/// centre sits exactly on the boundary would read as touching, when it is
/// penetrating by its whole radius. That is precisely the error the core +
/// inflation-radius convention exists to make impossible, and a suite that only
/// tested boxes — whose core radius is 0 — would pass with the term missing.
pub fn separation(
    comptime T: type,
    plane: HalfSpace(T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
) T {
    plane.assertUnit();
    // B's core support in the direction that digs INTO the solid, expressed in A's
    // frame. One support call: that is the whole cost of this kernel.
    const deepest_core = relpose.supportB(shape_b, plane.normal.neg());
    return plane.signedDistance(deepest_core) - shape_b.radius;
}

/// Whether `p` lies in the solid half-space, boundary INCLUDED — the same solidity
/// convention as a ray origin inside a shape (§1.11.4) and the same predicate the
/// point query and `closestPoint` consult first (§1.11.12, §1.11.13).
pub fn containsPoint(comptime T: type, plane: HalfSpace(T), p: math.Vec(3, T)) bool {
    plane.assertUnit();
    return plane.signedDistance(p) <= 0;
}

/// Nearest ray↔half-space intersection, or `null` when the ray misses. `origin` and
/// `direction` are in the same frame as `plane`, and `direction` must be unit
/// (asserted).
///
/// Solid, boundary included: an origin inside is a hit at distance ZERO whose normal
/// is `−direction`, the only choice preserving `normal · direction <= 0` on every hit
/// (§1.11.4). Testing membership first is also what lets the division below assume
/// the origin is strictly outside.
///
/// **The single guard is at TRUE ZERO, and it covers two cases at once.** From
/// outside, the ray reaches the boundary only while closing on it, i.e. `n·dir < 0`;
/// so `n·dir >= 0` is a miss, and that one comparison rejects both the RECEDING ray
/// (`> 0`) and the PARALLEL one (`== 0`). No epsilon, and no separate branch for the
/// parallel case — which is why a ray parallel to the boundary from outside misses
/// while one parallel from inside was already answered above.
///
/// The returned normal is the boundary's outward normal, `plane.normal` verbatim: no
/// arithmetic, hence unit at any distance and with an exact orientation, which is
/// strictly stronger than the reconstructed normals of §1.11.4 bis.
pub fn rayShape(
    comptime T: type,
    plane: HalfSpace(T),
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) ?support.LocalHit(T) {
    plane.assertUnit();
    std.debug.assert(@abs(direction.lengthSq() - 1) <= unit_k * std.math.floatEps(T));

    const sep = plane.signedDistance(origin);
    if (sep <= 0) return .{ .distance = 0, .normal = direction.neg() };

    const closing = plane.normal.dot(direction);
    if (closing >= 0) return null; // receding, or parallel from outside

    // `sep > 0` and `closing < 0`, so the quotient is strictly positive and no NaN is
    // reachable. Written on `sep` rather than as `(d − n·o) / (n·dir)` so the one
    // subtraction that carries the far-field residue stays in `signedDistance`.
    return .{ .distance = -sep / closing, .normal = plane.normal };
}

/// Cast of the bounded convex `shape_a` along `direction` against the half-space,
/// returning the first touch within `[0, max_distance]` — a CLOSED interval — or
/// `null` on a miss.
///
/// Everything is in A's frame, A being the shape being cast: `shape_a` is
/// untransformed there, `plane` has been `transformed` into it by the caller, and
/// `direction` is A-frame too. That is the frozen narrowphase discipline and it is
/// also what makes this kernel a closed form — A's support in a FIXED direction
/// `−n` does not change during a pure translation, so one support call answers the
/// whole sweep.
///
/// ```
/// sep₀ = n · supportCore_A(−n) − r_a − d          (separation at the start pose)
/// t    = sep₀ / (−n·dir)                          (miss when n·dir >= 0)
/// ```
///
/// **Initial contact** (`sep₀ <= 0`, already overlapping at the start pose): distance
/// 0, and the witness is on the HIT BODY — the boundary plane — never the cast
/// origin. §1.11.11 is explicit that the ray analogy does not carry here: a ray's
/// origin necessarily belongs to the body it hit, whereas the centre of a cast shape
/// can be entirely outside it, so returning the origin would give a point that is
/// neither a contact point nor a point of the collider.
///
/// The guard on `n·dir` is the file's SECOND and last, at TRUE ZERO, and it rejects
/// the receding sweep and the parallel one together for the reason `rayShape` gives.
pub fn castShape(
    comptime T: type,
    plane: HalfSpace(T),
    shape_a: support.SupportShape(T),
    direction: math.Vec(3, T),
    max_distance: T,
) ?support.CastHit(T) {
    plane.assertUnit();
    std.debug.assert(@abs(direction.lengthSq() - 1) <= unit_k * std.math.floatEps(T));
    std.debug.assert(std.math.isFinite(max_distance) and max_distance >= 0);

    // A's deepest point ON ITS INFLATED SURFACE along the direction that digs into the
    // solid: the core support minus the radius offset. This is where the `− r_a` of the
    // separation formula lives, and it is also the point that first touches.
    const deepest = shape_a.support(plane.normal.neg()).sub(plane.normal.scale(shape_a.radius));
    const sep0 = plane.signedDistance(deepest);

    if (sep0 <= 0) {
        // Already overlapping: the witness is `deepest` projected onto the boundary.
        return .{
            .distance = 0,
            .point = deepest.sub(plane.normal.scale(sep0)),
            .normal = plane.normal,
        };
    }

    const closing = plane.normal.dot(direction);
    if (closing >= 0) return null; // receding, or parallel from outside

    const t = sep0 / -closing;
    // STRICT exceedance, per §1.11.11: the parameter is a lower bound of the true time
    // of impact, so passing the bound proves the contact is out of reach while reaching
    // it exactly proves nothing — and the interval is closed.
    if (t > max_distance) return null;

    // The touching point is `deepest` advanced by the sweep; it lies on the boundary by
    // construction, so no second projection is needed.
    return .{
        .distance = t,
        .point = deepest.add(direction.scale(t)),
        .normal = plane.normal,
    };
}

/// The closest point on the half-space to `p`, and the distance to the SOLID.
///
/// `distance = max(0, n·p − d)` and the position is the orthogonal projection —
/// except that a point INSIDE the solid, boundary included, is at distance 0 and its
/// closest point is ITSELF (§1.11.13's solidity convention, the same one
/// `containsPoint` implements). Projecting an interior point would answer a point on
/// the boundary, which is the closest point on the SURFACE and not on the solid.
///
/// No guard: there is no division. The projection subtracts `sep·n` from `p`, both
/// terms being of the caller's own scale.
pub fn closestPoint(comptime T: type, plane: HalfSpace(T), p: math.Vec(3, T)) Projection(T) {
    plane.assertUnit();
    const sep = plane.signedDistance(p);
    if (sep <= 0) return .{ .distance = 0, .position = p };
    return .{ .distance = sep, .position = p.sub(plane.normal.scale(sep)) };
}

/// Whether a world AABB meets the half-space — the broadphase role of an unbounded
/// shape, which is asked a PREDICATE and never a box of its own (§1.11.15).
///
/// The eight-branch corner selection itself is `Aabb.overlapsHalfSpace`, in
/// `foundation/math`: it is pure box geometry with no threshold and no physical
/// semantics, and the broadphase — which imports only `foundation` — needs the same
/// formula this table row does. Written twice, the two copies would drift; this row
/// therefore names the kernel and delegates to it. RD-1 of the milestone records the
/// placement.
pub fn aabbOverlaps(comptime T: type, plane: HalfSpace(T), box: math.Aabb(T)) bool {
    plane.assertUnit();
    return box.overlapsHalfSpace(plane.normal, plane.distance);
}
