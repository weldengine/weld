//! `forge_3d/pipeline/narrowphase/triangle.zig` — the analytic ray↔triangle kernel and
//! the back-face predicate (M1.1.11.1, `engine-physics-forge.md` §1.11.17).
//!
//! **Why one kernel and not four families.** A triangle is a BOUNDED convex whose support
//! map is the max of three dot products, and that is the only property GJK, EPA, the
//! manifold generator and the M1.1.10 cast kernel require — so those four serve a mesh
//! through `SupportShape.Core.triangle` unchanged. Only the RAY gains an arm, for the
//! reason §1.11.3 gives ray kernels their existence: a configuration-space march against
//! a FLAT core is ill-conditioned where ray↔triangle has a closed form.
//!
//! **A triangle is a SURFACE.** It has no interior, so there is no membership case and no
//! distance-zero-from-inside case: every hit is a real crossing. That is the categorical
//! rule of §1.11.17 applied at the grain of one triangle, and it is why this kernel is
//! shorter than any of its siblings rather than longer.
//!
//! **Facing is geometry; culling is policy.** The kernel reports WHICH SIDE was met and
//! never decides whether that side answers: the mode lives on the query
//! (`api.BackFaceMode`), which this file may not import. `localHit` applies the one part
//! of the policy that is an invariant rather than a choice — the normal is FLIPPED on a
//! back-face hit, because §1.11.4 declares `normal · direction <= 0` on every hit and the
//! `−direction` choice at distance zero draws its justification from that same invariant.
//!
//! **Threshold discipline.** Every guard is at TRUE ZERO: the parallel test, and nothing
//! else needs one. No geometric epsilon appears. A near-parallel ray whose determinant is
//! subnormal yields a distance that overflows to infinity, which the query entry's FINITE
//! `max_distance` rejects — the same resolution §1.11.15 records for a half-space, and for
//! the same reason: a kernel has no range of its own, and inventing one would make the
//! answer depend on a constant.
//!
//! **Dependency discipline.** Imports `foundation` (math) and the sibling `support.zig`
//! ONLY — never `manifold.zig`, `gjk.zig`, `epa.zig`, `raycast.zig`, `weld_forge`,
//! `body*.zig`, `config.zig` or `broadphase.zig`. Identical to `plane.zig`; the scalar is
//! the comptime `T` and `forge_3d` instantiates it at `config.Real`.

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");

/// Slack allowed on the unit-direction domain assert, in ULPs of 1 — the same constant
/// and the same role as `raycast.zig`'s. The comparison is against 1, so it is float
/// noise at scale 1 and not a geometric tolerance.
const unit_k: comptime_int = 16;

/// A ray hit on ONE triangle, in the triangle's frame.
///
/// Distinct from `support.LocalHit` on purpose: it carries the FACING, which a `LocalHit`
/// does not, and its `normal` is the OUTWARD one, never flipped. `localHit` is the
/// conversion, and it is where the flip happens.
pub fn TriangleHit(comptime T: type) type {
    return struct {
        /// Distance along the (unit) direction, `>= 0`.
        distance: T,
        /// OUTWARD unit normal of the triangle — `normalize((v₁−v₀) × (v₂−v₀))`, never
        /// flipped, whichever side was met.
        normal: math.Vec(3, T),
        /// Whether the ray met the triangle from BEHIND, i.e. `normal · direction > 0`.
        back_face: bool,
    };
}

/// Whether a hit whose triangle normal is `normal` was met from BEHIND by a ray or a
/// sweep travelling along `direction`.
///
/// Written ONCE and shared: the ray kernel below decides with it, and so will the sweep
/// (§1.11.17 states the rule for both in one sentence, `n · direction > 0`). Two copies
/// of a one-line predicate is how the two families come to disagree.
///
/// Strict `>`: a ray exactly parallel to the plane grazes it and is neither side's, and
/// the kernel's parallel guard has already rejected it before this is asked.
pub fn isBackFace(comptime T: type, normal: math.Vec(3, T), direction: math.Vec(3, T)) bool {
    return normal.dot(direction) > 0;
}

/// Whether an overlap PROBE lies ENTIRELY in the rear half-space of a triangle's plane —
/// the back-face predicate for the overlap family, the sibling of `isBackFace`
/// (`engine-physics-forge.md` §1.11.17).
///
/// `support_core` is the probe's CORE support point in direction `normal`, expressed in the
/// TRIANGLE's frame, and `probe_radius` its inflation radius. The caller owns the frame
/// conversion, which is why the support point arrives computed rather than the probe
/// itself: this file may not import `RelativePose`'s consumers, and pushing the conversion
/// out keeps the predicate a pure arithmetic statement.
///
/// **The radius EXTENDS the probe toward the front, so it is added.** The probe's furthest
/// reach along `normal` is `normal · support_core + radius`, since `support` returns the
/// CORE and the inflated surface stands `radius` beyond it; the probe is entirely behind
/// exactly when that reach falls short of the plane. Written WITHOUT the radius term the
/// predicate is right for a box and wrong for a sphere and a capsule by exactly the
/// radius — which is the failure the term exists to prevent.
///
/// **RECORDED DEVIATION on the sign.** §1.11.17 and the milestone brief both write this as
/// `n · support_probe(n) − r_probe < n · v₀`, with the radius SUBTRACTED. That contradicts
/// their own normative sentence one line later — "a probe straddling the plane touches from
/// the front and counts in both modes" — and the contradiction is decidable on the case
/// they name: a unit sphere centred exactly ON the plane has `n · support_core = n · v₀`,
/// so the subtracted form yields `n·v₀ − 1 < n·v₀`, TRUE, and discards a probe the same
/// paragraph requires to count. The added form yields `n·v₀ + 1 < n·v₀`, FALSE, and keeps
/// it. The straddling test is therefore the discriminator, and it is written.
pub fn probeIsBehind(
    comptime T: type,
    normal: math.Vec(3, T),
    v0: math.Vec(3, T),
    support_core: math.Vec(3, T),
    probe_radius: T,
) bool {
    return normal.dot(support_core) + probe_radius < normal.dot(v0);
}

/// The `LocalHit` a query returns for a triangle hit, carrying its `subshape_id`.
///
/// **The normal is FLIPPED on a back-face hit**, and that is an invariant rather than a
/// preference: §1.11.4 declares `normal · direction <= 0` on EVERY hit, and it is from
/// that invariant that the `−direction` choice at distance zero takes its justification.
/// A back-face hit returning the outward normal unchanged would satisfy
/// `normal · direction > 0` and puncture it. Assumed divergence from the reference, which
/// returns it unchanged and leaves the caller to cope; nothing is lost, since the caller
/// asked for that mode and the real side stays reachable through `subshape_id`.
pub fn localHit(comptime T: type, hit: TriangleHit(T), subshape_id: u32) support.LocalHit(T) {
    return .{
        .distance = hit.distance,
        .normal = if (hit.back_face) hit.normal.neg() else hit.normal,
        .subshape_id = subshape_id,
    };
}

/// Nearest ray↔triangle intersection, or `null` on a miss. `origin` and `direction` are
/// in the triangle's frame and `direction` must be unit (asserted), so the returned
/// parameter IS a distance and never a fraction (§1.11.4).
///
/// Möller–Trumbore, in its signed-determinant (non-culling) form, because the kernel
/// reports facing rather than filtering on it. Two properties of that form matter here:
///
///   - **The determinant IS the facing.** `det = e₀ · (d × e₁) = −d · (e₀ × e₁) = −d · n`,
///     so `det > 0` is a front-face hit and `det < 0` a back-face one. No extra dot
///     product, and no second convention to keep in step with `isBackFace`.
///   - **ONE division, at the end.** The barycentric tests are carried out against
///     `|det|` rather than against 1 after a multiplication by `1/det`. That is not
///     stylistic: for a subnormal determinant `1/det` overflows to infinity, and
///     `0 · inf` is NaN, which passes BOTH `u < 0` and `u > 1` and would let a NaN
///     distance out. Against `|det|` every comparison is between finite products.
///
/// **Conditioning, and the ratio that actually governs it** (§1.11.17). The normal comes
/// from a cross product of VERTEX DIFFERENCES, so its cancellation is bounded by the EDGE
/// LENGTH and not by the distance to the world origin: the orientation error follows
/// `floatEps(T) · |v| / edge_length`, where `|v|` is the vertex magnitude in the SHAPE's
/// LOCAL frame. The unfavourable regime is therefore a mesh whose triangles are small
/// against their own offset from that local origin — not a mesh far from the world
/// origin, which the body pose absorbs. The length is then made exact by normalising, so
/// it is a structural invariant at any range and only the orientation carries the residue,
/// exactly as §1.11.4 bis has it for the convex kernels.
pub fn rayTriangle(
    comptime T: type,
    verts: [3]math.Vec(3, T),
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
) ?TriangleHit(T) {
    std.debug.assert(@abs(direction.lengthSq() - 1) <= unit_k * std.math.floatEps(T));

    // **The chain is attempted in a POWER-OF-TWO-REDUCED space, because it overflows on its own
    // on descriptors the domain admits — measured, not feared.** At `f32`, legs of `1e20` give
    // `det = 1e40`, i.e. infinity; `u` and `v` reach infinity too and PASS their bounds, `inf >
    // inf` being false; and `t_num` then multiplies an infinity by an exact zero, so the NaN this
    // file's doc comment credits the `|det|` form with preventing arrives anyway, from the other
    // side, and leaves as a NaN DISTANCE. Vertices spanning `±0.9 · floatMax` overflow one step
    // earlier still, in the edge subtraction, and THAT one is precision-independent: it
    // reproduces at `f64`.
    //
    // Reducing the vertices AND the origin by one common power of two puts every coordinate
    // below 1, hence every difference below 2, `pvec` and `rvec` under a handful and `det`, `u`,
    // `v`, `t_num` under a few dozen — nothing in the chain can leave the range at either end.
    // It costs nothing in meaning because the factor is an exact power of two: `det`, `u`, `v`
    // and `abs_det` are all homogeneous of DEGREE 2 in the scale, so every comparison between
    // them, the `det == 0` test at true zero included, is bit-for-bit the comparison the
    // unreduced form made; the parameter is homogeneous of degree 1 and is lifted back by the
    // same exact power of two.
    //
    // **TWO exact scales, the INPUT's own attempted FIRST — and that ordering was measured, not
    // assumed.** Reducing unconditionally is correct but strictly worse on both axes that matter.
    // On COST: the reduction is nine absolute values, a `frexp` and eight vector multiplies per
    // triangle per ray, and the mesh bench measured it at `+38.7 % / +22.8 % / +37.8 %` on the
    // raycast column at 1 000 / 4 000 / 16 000 triangles. On ACCURACY: a very negative exponent
    // pushes the origin's small components into the SUBNORMAL range, where the mantissa really is
    // truncated, so reducing loses low bits it had no need to touch — measured over a leg × height
    // sweep, reducing first answered `9.99979261261345e19` where the input's own scale answers
    // `1.0000000200408773e20` for a true `1e20`, and two further rows likewise. So this is not
    // speed traded against exactness; the ordering is better at both, and the reduced scale is
    // what rescues the configurations the input's own scale cannot express.
    //
    // The retry is entered on a STRUCTURAL signal and never on a tolerance: an exactly zero
    // determinant, or an intermediate outside the float range. Both orderings were compared on
    // every extreme case at both precisions and agree exactly — same verdicts, same distances, no
    // NaN — so the ordering gives nothing away in the regime the reduction exists for.
    switch (attempt(T, verts, origin, direction, 0)) {
        .hit => |h| return h,
        .miss => return null,
        // A genuinely degenerate triangle is degenerate at every scale and answers `.degenerate`
        // again below; an unrepresentable intermediate is exactly what the reduction fixes.
        .degenerate, .unrepresentable => {},
    }

    // The reduced scale. The ORIGIN is reduced together with the vertices, which is what stops
    // `qvec = origin − v₀` from overflowing; a larger magnitude gives a larger `frexp` exponent
    // hence a smaller reduction exponent, so the one bringing all four below 1 is the MINIMUM.
    // A zero exponent has nothing to offer — the first attempt already ran at that scale.
    const exp = @min(
        math.pow2ReductionExponent(T, verts[0], verts[1], verts[2]) orelse 0,
        math.pow2ReductionExponent(T, origin, origin, origin) orelse 0,
    );
    if (exp == 0) return null;
    return switch (attempt(T, verts, origin, direction, exp)) {
        .hit => |h| h,
        // Not expressible at either scale: a MISS, never a NaN and never a false hit. Such a
        // configuration spans more of the float range than the format holds, which §1.11.4 bis
        // already records as a limit of the inputs rather than of the kernel.
        .miss, .degenerate, .unrepresentable => null,
    };
}

/// One Möller–Trumbore evaluation at a single exact power-of-two scale. Two outcomes are reported
/// apart from `.miss` because only they are worth retrying at another scale, and conflating either
/// with a miss is what let a NaN distance out before: `.degenerate` means the determinant was
/// exactly zero, which at a reduced scale can be the reduction's doing rather than the geometry's,
/// and `.unrepresentable` means an intermediate left the float range, so no comparison downstream
/// of it means anything.
fn Attempt(comptime T: type) type {
    return union(enum) { hit: TriangleHit(T), miss, degenerate, unrepresentable };
}

fn attempt(
    comptime T: type,
    verts: [3]math.Vec(3, T),
    origin: math.Vec(3, T),
    direction: math.Vec(3, T),
    exp: i32,
) Attempt(T) {
    const p0 = verts[0].scalePow2(exp);
    const p1 = verts[1].scalePow2(exp);
    const p2 = verts[2].scalePow2(exp);
    const e0 = p1.sub(p0);
    const e1 = p2.sub(p0);
    const pvec = direction.cross(e1);
    const det = e0.dot(pvec);

    // TRUE ZERO, no epsilon: an exactly zero determinant means the ray runs parallel to
    // the triangle's plane, which a surface of zero thickness cannot be entered through.
    // A merely SMALL determinant is a legitimate grazing hit and is served — the distance
    // may then overflow to infinity, which the entry's finite `max_distance` rejects
    // (§1.11.15's resolution, applied here for the same reason).
    // Representability BEFORE anything is compared against `det`. A non-finite determinant is what
    // an enormous triangle produces, and every bound below then reads `inf > inf`, which is false,
    // so the chain would run to completion on quantities that mean nothing.
    if (!std.math.isFinite(det)) return .unrepresentable;
    if (det == 0) return .degenerate;

    // Work against `|det|` with the sign carried separately, so the three barycentric
    // tests read identically for both facings and no reciprocal is formed.
    const sign: T = if (det < 0) -1 else 1;
    const abs_det = sign * det;

    const qvec = origin.scalePow2(exp).sub(p0);
    const u = sign * qvec.dot(pvec);
    // A NaN passes BOTH comparisons — `NaN < 0` and `NaN > abs_det` are each false — which is
    // precisely how one used to reach the returned distance. It arises from `inf · 0`, when an
    // offset that does not fit meets a zero lane of `pvec`.
    if (std.math.isNan(u)) return .unrepresentable;
    if (u < 0 or u > abs_det) return .miss;

    const rvec = qvec.cross(e0);
    const v = sign * direction.dot(rvec);
    if (std.math.isNan(v)) return .unrepresentable;
    // Boundary INCLUDED on all three edges (`>= 0` and `u + v <= |det|`), the
    // face-inclusive convention of `Aabb.contains` and of every other kernel here. A ray
    // through a shared edge of a closed mesh therefore hits both triangles, and the
    // nearest-triangle selection above the kernel picks one by a fixed tie-break.
    if (v < 0 or u + v > abs_det) return .miss;

    const t_num = sign * e1.dot(rvec);
    if (std.math.isNan(t_num)) return .unrepresentable;
    if (t_num < 0) return .miss; // the triangle is behind the origin

    // The normal comes from the SHARED form, not from a local cross product, so the geometry
    // this kernel reports is the geometry `MeshData.init` validated and `MeshData.faceNormal`
    // describes — the reason that matters is at `isDegenerate`. It is fed the ALREADY-REDUCED
    // points rather than `verts`, which is not an optimisation with a caveat but exactly
    // equivalent: `scalePow2` documents that a common power of two cancels inside
    // `normalizeScaled`, so both calls answer the same bits. Never empty here — a determinant of
    // exactly zero already returned above, and a non-zero determinant means a non-zero cross.
    const normal = math.triangleCross(T, p0, p1, p2).normalizeScaled() orelse unreachable;

    // Lifted out of the reduced space by the SAME exact power of two, the parameter being
    // homogeneous of degree 1 in the scale. A grazing hit whose true distance is not representable
    // becomes an INFINITY here, which is a legitimate answer the entry's finite `max_distance`
    // rejects (§1.11.15's resolution, unchanged); a NaN is not, and is reported as such.
    const distance = std.math.ldexp(t_num / abs_det, -exp);
    if (std.math.isNan(distance)) return .unrepresentable;

    return .{
        .hit = .{
            .distance = distance,
            .normal = normal,
            // Derived from the DETERMINANT rather than recomputed, and the identity is the
            // one in the doc comment: `det = −d · n`, so a negative determinant is exactly
            // `n · d > 0`. Asserted against the shared predicate below, so the two forms
            // cannot drift.
            .back_face = det < 0,
        },
    };
}

const testing = std.testing;

test "the determinant sign and the shared back-face predicate agree" {
    const T = f32;
    const V = math.Vec(3, T);
    const vf = struct {
        fn f(x: T, y: T, z: T) V {
            return V.fromArray(.{ x, y, z });
        }
    }.f;

    // A triangle in the XY plane wound counter-clockwise seen from `+Z`:
    // `(v₁−v₀) × (v₂−v₀) = (1,0,0) × (0,1,0) = (0,0,1)`, so the outward normal is `+Z`.
    const tri = [3]V{ vf(0, 0, 0), vf(1, 0, 0), vf(0, 1, 0) };

    // FROM THE FRONT, straight down onto the interior point `(0.25, 0.25)`: the distance
    // is exactly 3, the outward normal exactly `+Z`, and `n · d = −1 < 0` — a front hit.
    const front = rayTriangle(T, tri, vf(0.25, 0.25, 3), vf(0, 0, -1)).?;
    try testing.expectEqual(@as(T, 3), front.distance);
    try testing.expect(front.normal.eql(vf(0, 0, 1)));
    try testing.expect(!front.back_face);
    try testing.expectEqual(front.back_face, isBackFace(T, front.normal, vf(0, 0, -1)));

    // FROM BEHIND, the same interior point from below: distance exactly 2, the SAME
    // outward normal — the kernel never flips it — and the facing flag set.
    const back = rayTriangle(T, tri, vf(0.25, 0.25, -2), vf(0, 0, 1)).?;
    try testing.expectEqual(@as(T, 2), back.distance);
    try testing.expect(back.normal.eql(vf(0, 0, 1)));
    try testing.expect(back.back_face);
    try testing.expectEqual(back.back_face, isBackFace(T, back.normal, vf(0, 0, 1)));

    // `localHit` is where the flip lives, and the invariant holds in BOTH modes: the
    // front hit keeps `+Z` against a `−Z` ray, the back hit returns `−Z` against a `+Z`
    // ray, and `normal · direction` is `−1` in both cases.
    const front_local = localHit(T, front, 7);
    try testing.expect(front_local.normal.eql(vf(0, 0, 1)));
    try testing.expectEqual(@as(u32, 7), front_local.subshape_id);
    try testing.expectEqual(@as(T, -1), front_local.normal.dot(vf(0, 0, -1)));
    const back_local = localHit(T, back, 9);
    try testing.expect(back_local.normal.eql(vf(0, 0, -1)));
    try testing.expectEqual(@as(u32, 9), back_local.subshape_id);
    try testing.expectEqual(@as(T, -1), back_local.normal.dot(vf(0, 0, 1)));

    // PARALLEL, exactly: the guard is at true zero and the answer is a miss, both in the
    // plane and out of it.
    try testing.expect(rayTriangle(T, tri, vf(-1, 0.25, 0), vf(1, 0, 0)) == null);
    try testing.expect(rayTriangle(T, tri, vf(-1, 0.25, 5), vf(1, 0, 0)) == null);

    // OUTSIDE each of the three edges, and inside once: the barycentric tests bound the
    // triangle rather than its plane. `(0.6, 0.6)` fails `u + v <= 1`, `(−0.1, 0.25)`
    // fails `u >= 0`, `(0.25, −0.1)` fails `v >= 0`.
    try testing.expect(rayTriangle(T, tri, vf(0.6, 0.6, 3), vf(0, 0, -1)) == null);
    try testing.expect(rayTriangle(T, tri, vf(-0.1, 0.25, 3), vf(0, 0, -1)) == null);
    try testing.expect(rayTriangle(T, tri, vf(0.25, -0.1, 3), vf(0, 0, -1)) == null);
    try testing.expect(rayTriangle(T, tri, vf(0.25, 0.25, 3), vf(0, 0, -1)) != null);

    // The BOUNDARY is included, on a vertex and on the middle of the hypotenuse.
    try testing.expect(rayTriangle(T, tri, vf(0, 0, 3), vf(0, 0, -1)) != null);
    try testing.expect(rayTriangle(T, tri, vf(0.5, 0.5, 3), vf(0, 0, -1)) != null);

    // BEHIND the origin: the plane is crossed at `t = −3`, and the kernel reports no hit
    // rather than a negative distance.
    try testing.expect(rayTriangle(T, tri, vf(0.25, 0.25, 3), vf(0, 0, 1)) == null);
}
