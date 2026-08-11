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
//! **A true-zero guard is exact IN THE FRAME IT IS EVALUATED IN, AND THAT DOES NOT
//! COMPOSE** (§1.11.15). The kernels below work in a local frame, and a rigid
//! transform does not preserve EXACT orthogonality: a ray parallel to the boundary in
//! WORLD, transported into the body's frame by a quaternion built in floating point,
//! arrives with a dot product about one ULP from zero rather than at zero. The guard
//! therefore does not fire, and the kernel reports — correctly — a crossing at
//! `sep / |n·dir|`, of the order of `sep / floatEps(T)`; measured for `sep = 10 m` at
//! 8.3886120e7 m in f32 and 4.5035996e16 m in f64.
//!
//! That is not a kernel defect and **it is not fixed with an epsilon.** The kernel has
//! no range of its own, and inventing one would make the answer depend on a constant —
//! the refusal §1.11.12 already states for the broadphase margin. What rejects such a
//! ray is the query entry's FINITE `max_distance`, which §1.11.4 requires to be finite
//! anyway.
//!
//! **A half-space's conditioning does NOT decompose the way §1.11.4 bis does**
//! (§1.11.15). There the normal is reconstructed and only its length is invariant with
//! distance. Here the contact normal is the STORED `n` returned VERBATIM, with no
//! intermediate arithmetic at all: length AND orientation are exact at any range, and
//! they are asserted as BIT EQUALITY rather than through a bound. The far-field residue
//! therefore moves entirely into the scalar `signedDistance = n·p − d`, a difference of
//! two quantities that both grow with distance from the origin, whose absolute error
//! grows like `floatEps(T)·|p|`. That is the same structural worldspace limit
//! `-Dphysics_f64` answers, characterised and not hidden — so an acceptance suite on
//! this shape asserts the normal TIGHT AND EVERYWHERE, and reserves the scale-relative
//! bound for the scalar alone.
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

        /// Domain assertion: the normal is UNIT and the distance is FINITE. Renamed from
        /// `assertUnit` at M1.1.11/E7-J2, when the second half was added — a name that
        /// promised one check while performing two would be worse than either.
        ///
        /// Neither half is cosmetic. Every kernel treats the normal as unit when it
        /// divides by `n·dir`, projects along it, or returns it as a contact normal, and a
        /// non-unit normal would scale `signedDistance` silently.
        ///
        /// A non-finite `distance` is worse, because it produces TWO silent behaviours
        /// that CONTRADICT each other. MEASURED with `distance = NaN`, identically at both
        /// precisions:
        ///
        ///   - `signedDistance` is NaN, so `sep > 0` is FALSE, so the generator's
        ///     `if (sep > 0) continue;` does not fire and a contact is emitted — for a
        ///     unit sphere 1000 m OUTSIDE the solid, `collidePlane` returned a manifold
        ///     with one point. The plane reports contact with everything.
        ///   - every comparison in `Aabb.overlapsHalfSpace` is FALSE against a NaN bound,
        ///     so the predicate answers false for a box at the origin AND for a box 5000 m
        ///     deep inside. The plane meets nothing and vanishes from the broadphase.
        ///
        /// One malformed input, and the narrowphase says "touching everything" while the
        /// broadphase says "touching nothing". Neither is an error the caller can see.
        pub fn assertDomain(self: Self) void {
            std.debug.assert(@abs(self.normal.lengthSq() - 1) <= unit_k * std.math.floatEps(T));
            std.debug.assert(std.math.isFinite(self.distance));
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
    plane.assertDomain();
    // B's core support in the direction that digs INTO the solid, expressed in A's
    // frame. One support call: that is the whole cost of this kernel.
    const deepest_core = relpose.supportB(shape_b, plane.normal.neg());
    return plane.signedDistance(deepest_core) - shape_b.radius;
}

/// Whether `p` lies in the solid half-space, boundary INCLUDED — the same solidity
/// convention as a ray origin inside a shape (§1.11.4) and the same predicate the
/// point query and `closestPoint` consult first (§1.11.12, §1.11.13).
pub fn containsPoint(comptime T: type, plane: HalfSpace(T), p: math.Vec(3, T)) bool {
    plane.assertDomain();
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
/// Exact IN THIS FRAME, and that does not compose: a ray parallel in WORLD arrives here
/// through a rigid transform about one ULP off orthogonal, so the guard does not fire
/// and the answer is a crossing at `sep / |n·dir|` (§1.11.15, and the file header). The
/// caller's finite `max_distance` is what rejects it; this kernel has no range of its
/// own and must not invent one.
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
    plane.assertDomain();
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
/// 0, the witness on the HIT BODY — the boundary plane — never the cast origin, and the
/// normal `−direction`.
///
/// The witness rule is §1.11.11's: a ray's origin necessarily belongs to the body it
/// hit, whereas the centre of a cast shape can be entirely outside it, so returning the
/// origin would give a point that is neither a contact point nor a point of the
/// collider.
///
/// **The normal is `−direction`, not `n`, and no information is lost by that.** All four
/// kernels say the same thing at a zero parameter — `raycast.zig` for an origin inside a
/// convex, `plane.rayShape` for an origin inside the half-space, and `shapecast.zig`,
/// whose `terminal` documents `−direction` as "the only one keeping
/// `normal · direction <= 0` on every hit". Returning `n` here broke that invariant
/// outright for a cast aimed OUT of the solid: sweeping along `+n` to leave the
/// half-space gave `normal · direction = +1`.
///
/// Nothing is lost because a cast does not measure penetration geometry. It answers WHEN
/// two shapes touch, and at an initial overlap there is no time of impact and no unique
/// separating axis to report — §1.11.11 says as much, deferring the deepest point at a
/// zero parameter to an EPA it deliberately does not run. The question `n` answers is the
/// MANIFOLD's, and `collidePlane` answers it exactly, with `n` and a penetration. And for
/// this shape specifically the caller can always recover `n`: it is a stored field of the
/// shape. The invariant, by contrast, is what every consumer relies on and cannot
/// reconstruct.
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
    plane.assertDomain();
    std.debug.assert(@abs(direction.lengthSq() - 1) <= unit_k * std.math.floatEps(T));
    std.debug.assert(std.math.isFinite(max_distance) and max_distance >= 0);

    // A's deepest point ON ITS INFLATED SURFACE along the direction that digs into the
    // solid: the core support minus the radius offset. This is where the `− r_a` of the
    // separation formula lives, and it is also the point that first touches.
    const deepest = shape_a.support(plane.normal.neg()).sub(plane.normal.scale(shape_a.radius));
    const sep0 = plane.signedDistance(deepest);

    if (sep0 <= 0) {
        // Already overlapping: the witness is `deepest` projected onto the boundary, and
        // the normal is `−direction` (see the doc comment). The two are along different
        // axes, which is the same shape of answer `shapecast.zig` gives when its own axis
        // has collapsed: a witness from the geometry, a normal from the invariant.
        return .{
            .distance = 0,
            .point = deepest.sub(plane.normal.scale(sep0)),
            .normal = direction.neg(),
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
    plane.assertDomain();
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
    plane.assertDomain();
    return box.overlapsHalfSpace(plane.normal, plane.distance);
}

/// Do two half-space SOLIDS meet? Analytic, no iteration, no threshold (M1.1.13).
///
/// Two half-spaces intersect ALWAYS, with one exception: their normals exactly opposite AND
/// their boundaries disjoint. The derivation is one line — with `A = {n·x <= d_a}` and
/// `B = {−n·x <= d_b} = {n·x >= −d_b}`, the intersection is non-empty iff `−d_b <= d_a`, i.e.
/// iff `d_a + d_b >= 0`.
///
/// **The antiparallel test is at TRUE ZERO and needs no epsilon**, which is a property of the
/// geometry rather than a discipline imposed on it: two half-spaces whose normals are merely
/// CLOSE to opposite still intersect, in a wedge that narrows as they approach. Only the
/// exactly-opposite case can be empty, so an epsilon here would answer "no overlap" for a pair
/// that genuinely overlaps.
///
/// Both normals are unit by the shape's creation invariant, so `b.normal == a.normal.neg()` is
/// the exact test.
pub fn halfSpacesOverlap(comptime T: type, a: HalfSpace(T), b: HalfSpace(T)) bool {
    a.assertDomain();
    b.assertDomain();
    if (!b.normal.eql(a.normal.neg())) return true;
    return a.distance + b.distance >= 0;
}

/// Does any point of a triangulated SURFACE lie in a half-space solid? (M1.1.13.)
///
/// **A vertex test is EXACT here, and that is a property of convexity rather than a
/// simplification.** A triangle is the convex hull of its three vertices and a half-space is a
/// convex set defined by a linear inequality, so `n·x − d` attains its minimum over the
/// triangle at a VERTEX. The surface therefore meets the solid if and only if some vertex of
/// some TRIANGLE does, and no edge or interior point can be inside while all three vertices
/// are outside.
///
/// **IT WALKS THE REFERENCED VERTICES, NOT THE STORED ARRAY, and the distinction is the whole
/// correctness of the entry.** `MeshData` validates that every index is within the vertex
/// array and never the converse, so an UNREFERENCED vertex is legal — an imported mesh may
/// carry them. The convexity argument above is about the vertices of a TRIANGLE, and the
/// stored array is not that set: walking it would answer "overlap" for a surface lying wholly
/// outside the solid that merely stores an orphan inside it.
///
/// That is a FALSE POSITIVE, and in a sensor a false positive is a phantom `TriggerEnter` —
/// not a conservative answer, a wrong one, and more visible in play than a miss. An earlier
/// version of this comment called the stored-array walk "conservative in the direction that
/// cannot produce a false negative", and that formulation is what let the defect through.
///
/// The walk stops at the first vertex on the solid side. `plane` must already be expressed in
/// the MESH's local frame: transporting one plane once is cheaper than transporting every
/// vertex, and it keeps the subtraction that carries the far-field residue inside
/// `signedDistance`, where §1.11.15 puts it.
pub fn halfSpaceMeetsMesh(
    comptime T: type,
    plane: HalfSpace(T),
    vertices: []const math.Vec(3, T),
    indices: []const u32,
) bool {
    plane.assertDomain();
    for (indices) |i| {
        if (plane.signedDistance(vertices[i]) <= 0) return true;
    }
    return false;
}
