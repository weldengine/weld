//! `forge_3d/pipeline/narrowphase/manifold.zig` — the contact manifold types and
//! (M1.1.3/E3) the supporting-face clipping generator.
//!
//! M1.1.3/E1 landed the FROZEN `ContactManifold(T)` / `ContactPoint(T)` types and
//! the normal / depth / feature-id convention. E3 adds the single-shot generator
//! and the `collide` entry that drives both regimes.
//!
//! **The generator runs in A's frame (brief Notes, Guy's E3 kickoff).** It takes
//! a WORLD contact normal (shallow: `normalize(closest_b − closest_a)`; deep:
//! `EpaResult.normal`), converts it ONCE to A's frame (`conj(rot_a)·n`, a unit
//! vector rotation), takes `supportingFace(+n_a)` on A and `supportingFace(−n_a)`
//! on B (mapped to A's frame by `supportingFaceB`), picks the reference face (the
//! one whose outward normal is most aligned with the contact axis — a
//! non-polygon feature counts as 0-aligned; tie → A), clips the incident feature
//! against the reference's side planes (Sutherland-Hodgman), keeps the
//! penetrating points, reduces to ≤ 4, applies the inflation radii, and maps the
//! final normal + points to WORLD once. No clipping in world space — that would
//! reintroduce the large-coordinate cancellation the frame-of-A choice (M1.1.14)
//! avoids.
//!
//! **Per-point penetration (both regimes, continuous).** `r_sum − s`, where `s`
//! is the incident core point's signed distance from the reference face plane:
//! deep (`s < 0`) → `r_sum + |s|`, shallow (`s > 0`) → `r_sum − s`. A point-core
//! contact (a sphere, or an end-on capsule → 1 vertex) yields a single point from
//! the GJK/EPA closest points.
//!
//! **Order-independence (FROZEN hard requirement + F5).** `collide` computes the
//! pair in a caller-independent CANONICAL order (a deterministic key on
//! shape+pose) and negates the normal for the swapped caller, so `collide(A,B)`
//! and `collide(B,A)` give the same points/depths with negated normals. Ratified
//! exception (brief RD-4): two shapes with bit-identical pose AND geometry have no
//! geometric A→B axis (measure-zero), so `collide` returns the SAME arbitrary
//! normal in both orders there rather than a negated pair; `BodyManager.collidePair`
//! restores full order-independence for real bodies via a canonical body-id order.
//!
//! **Dependency discipline (brief Notes).** Imports `foundation` (math) and the
//! sibling `support.zig` / `gjk.zig` / `epa.zig` ONLY — never `weld_forge`,
//! `body*.zig`, `config.zig`, or `broadphase.zig`. The scalar is the comptime
//! `T`; `forge_3d` instantiates it at `config.Real`.

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");
const gjk_mod = @import("gjk.zig");
const epa_mod = @import("epa.zig");
const fast_paths = @import("fast_paths.zig");

/// The contact manifold between two shapes: a shared world-space contact
/// `normal` (A→B) plus up to 4 `ContactPoint`s. FROZEN convention (brief Notes);
/// produced by the M1.1.3/E3 supporting-face clipper.
pub fn ContactManifold(comptime T: type) type {
    return struct {
        /// Unit, world-space, points from A to B — the axis along which to
        /// translate B to reduce penetration.
        normal: math.Vec(3, T),
        /// Up to 4 contact points (box face-face max after reduction).
        points: [4]ContactPoint(T),
        /// Valid entries in `points`, 1..4.
        count: u8,
    };
}

/// One contact point of a `ContactManifold`. FROZEN convention (brief Notes).
pub fn ContactPoint(comptime T: type) type {
    return struct {
        /// World-space point on the contact plane (midpoint of the two
        /// surface points at this contact).
        position: math.Vec(3, T),
        /// Surface penetration along `normal`, >= 0 when overlapping.
        penetration: T,
        /// Deterministic per-contact identity for M1.1.6 warm-starting:
        /// `(reference-feature id << 16) | incident-feature id`, each 16-bit half
        /// class-tagged in its top 2 bits so the contact kinds occupy DISJOINT id
        /// ranges — kept vertex `(class_a, class_a)`, edge×plane crossing
        /// `(class_edge, class_edge)`, reference corner `(class_c, class_c)`, and
        /// single witness `(class_a, class_c)` — with each half carrying its REAL
        /// sub-feature (box vertex sign-pattern, box face `axis·2+sign`, segment
        /// endpoint, side-plane pair). FRAME-STABLE only through
        /// `BodyManager.collidePair` (fixed body-id order); the bare `collide`
        /// entry is POSE-canonical, so reference/incident ownership flips at a
        /// pose-order boundary and the id is NOT inter-frame stable there.
        /// Populated now; consumed at M1.1.6. Packing is an impl detail.
        feature_id: u32,
    };
}

/// Full narrowphase for a convex pair at their world poses: GJK, then the
/// contact manifold. Returns null when the pair is separated. The regimes wire
/// through one generator — `.shallow` supplies the normal from the GJK closest
/// points, `.deep` from EPA. Order-independence is guaranteed by computing the
/// pair in a caller-independent canonical POSE order and negating the normal for
/// the swapped caller (with the ratified RD-4 exception for bit-identical
/// pose+geometry). Because the canonical order is by POSE, the `feature_id`
/// reference/incident ownership flips at a pose-order boundary — a caller that
/// needs a FRAME-STABLE `feature_id` (M1.1.6 warm-starting) must drive the fixed
/// `collideOrdered` in a stable external order instead; `BodyManager.collidePair`
/// does this by body id.
pub fn collide(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) ?ContactManifold(T) {
    if (poseAfter(T, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b)) {
        // Caller order is the reverse of canonical: compute canonically (B,A),
        // then negate the normal so it points along the caller's A→B.
        var m = collideOrdered(T, shape_b, pos_b, rot_b, shape_a, pos_a, rot_a) orelse return null;
        m.normal = m.normal.neg();
        return m;
    }
    return collideOrdered(T, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b);
}

/// `collide` for a FIXED shape order — no pose canonicalization. The manifold's
/// normal is A→B and its `feature_id` reference/incident ownership follows the
/// given `(a, b)` order. Callers that own a stable external key (e.g. body ids)
/// use this directly so the feature_id stays frame-stable across a pose change
/// that would flip `collide`'s pose-based order (Codex P1b); `BodyManager`'s
/// `collidePair` drives it in a canonical body-id order.
///
/// M1.1.4: an analytic fast path is dispatched first (`fast_paths.fastSeed`).
/// `.not_handled` falls through to the generic GJK/EPA oracle
/// (`collideOrderedGeneric`); `.separated` returns `null`; `.contact` feeds the
/// seed to the SAME `generateManifold` the generic path uses — so the manifold
/// producers, clipping, reduction, order-independence, and frame-stability are
/// inherited identically. The dispatch is a pure function of the shape cores, so
/// a fast pair always takes its fast path (never alternates across frames).
pub fn collideOrdered(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) ?ContactManifold(T) {
    switch (fast_paths.fastSeed(T, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b)) {
        .not_handled => return collideOrderedGeneric(T, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b),
        .separated => return null,
        .contact => |seed| {
            const relpose = support.RelativePose(T).init(pos_a, rot_a, pos_b, rot_b);
            return generateManifold(T, shape_a, pos_a, rot_a, relpose, shape_b, seed.normal, seed.closest_a, seed.closest_b, seed.base_penetration);
        },
    }
}

/// `collideOrdered` with the fast-path dispatcher BYPASSED — always the generic
/// GJK → shallow/deep → `generateManifold` path. This is the differential ORACLE
/// the M1.1.4 fast-path tests compare against (and the bench baseline): a fast
/// pair's `collideOrdered` must be geometrically equivalent to its
/// `collideOrderedGeneric` (within a named tolerance on normal/points/depth,
/// exact `count`/`feature_id` away from documented topological-flip bands). It
/// computes the seed — `(normal, closest points, base penetration)` — from GJK
/// (shallow) or EPA (deep), exactly what a fast kernel reproduces analytically.
pub fn collideOrderedGeneric(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) ?ContactManifold(T) {
    const Vec3T = math.Vec(3, T);
    const g = gjk_mod.gjk(T, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b);
    if (g.status == .separated) return null;

    const relpose = support.RelativePose(T).init(pos_a, rot_a, pos_b, rot_b);
    const r_sum = shape_a.radius + shape_b.radius;

    var n_world: Vec3T = undefined;
    var closest_a: Vec3T = undefined;
    var closest_b: Vec3T = undefined;
    var base_penetration: T = undefined;
    if (g.status == .deep) {
        const e = epa_mod.epa(T, shape_a, pos_a, rot_a, relpose, shape_b, g);
        n_world = e.normal;
        closest_a = e.closest_a;
        closest_b = e.closest_b;
        base_penetration = e.depth + r_sum; // deep: core overlap + inflation
    } else { // shallow — cores disjoint, penetration from inflation only
        closest_a = g.closest_a;
        closest_b = g.closest_b;
        const sep = closest_b.sub(closest_a);
        const sep_len_sq = sep.dot(sep);
        // n = normalize(closest_b − closest_a); `normalize` is scale-equivariant,
        // so the only guard needed is 0/0 — fall back to the centre-to-centre
        // direction ONLY at true coincidence (`|sep|² ≤ floatMin`, the underflow
        // floor, never a geometric scale) — E8 class A.
        n_world = if (sep_len_sq > std.math.floatMin(T)) sep.scale(1.0 / @sqrt(sep_len_sq)) else fallbackNormal(T, pos_a, pos_b);
        base_penetration = r_sum - g.distance;
    }

    return generateManifold(T, shape_a, pos_a, rot_a, relpose, shape_b, n_world, closest_a, closest_b, base_penetration);
}

/// Build the contact manifold from a resolved world contact normal (`n_world`,
/// A→B) and the two shapes/poses, working in A's frame (see the file header).
/// `closest_a`/`closest_b` (world core witness points) and `base_penetration`
/// feed the single-point (point-core) path; the multi-point path derives per-
/// point penetration from the clip.
///
/// File-`pub` (M1.1.4): consumed by `collideOrdered`'s fast-path arm as well as
/// the generic arm, so a fast kernel's seed produces a manifold identical to the
/// generic one. NOT re-exported by the package facade — it stays package-internal.
pub fn generateManifold(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    relpose: support.RelativePose(T),
    shape_b: support.SupportShape(T),
    n_world: math.Vec(3, T),
    closest_a: math.Vec(3, T),
    closest_b: math.Vec(3, T),
    base_penetration: T,
) ContactManifold(T) {
    const Vec3T = math.Vec(3, T);
    const r_a = shape_a.radius;
    const r_b = shape_b.radius;
    const r_sum = r_a + r_b;

    // Contact normal into A's frame (unit vector rotation — safe).
    const n_a = rot_a.conjugate().rotateVec3(n_world);

    // Supporting features, both in A's frame.
    const face_a = shape_a.supportingFace(n_a);
    const face_b = relpose.supportingFaceB(shape_b, n_a.neg());

    // Point-core contact (a sphere, or an end-on capsule → 1 vertex): a single
    // contact straight from the GJK/EPA witness points, mapped to the surfaces.
    if (face_a.count == 1 or face_b.count == 1) {
        return pointCoreContact(T, n_world, closest_a, closest_b, r_a, r_b, base_penetration, singleContactFid(T, face_a, face_b));
    }

    // Segment × segment (M1.1.4): a NON-parallel (crossed) segment/segment pair
    // is an edge-edge contact → a SINGLE witness contact along the EPA/GJK axis,
    // NOT a 2-point clip. A segment reference forces `rn = n_a` (`faceNormalA`
    // returns the axis for a count-2 feature), so FIX-1's `|rn·n_a|` test never
    // trips, and `clipSegment` against a segment reference — whose two side
    // planes constrain only along the reference's OWN axis — can retain both
    // endpoints of a non-parallel incident segment (two geometrically wrong
    // points). The 2-point manifold stays RESERVED to the parallel-projection
    // overlap regime (two side-by-side capsules); a degenerate zero-length
    // segment (a `half_height == 0` capsule) is a point, never that regime.
    if (face_a.count == 2 and face_b.count == 2 and !segmentsParallel(T, face_a, face_b)) {
        return pointCoreContact(T, n_world, closest_a, closest_b, r_a, r_b, base_penetration, singleContactFid(T, face_a, face_b));
    }

    // Reference/incident by alignment with the contact axis (non-polygon → 0; tie A).
    const n_a_face = faceNormalA(T, face_a, n_a); // ≈ +n_a
    const n_b_face = faceNormalA(T, face_b, n_a.neg()); // ≈ −n_a
    const align_a: T = if (face_a.count >= 3) @abs(n_a_face.dot(n_a)) else 0;
    const align_b: T = if (face_b.count >= 3) @abs(n_b_face.dot(n_a)) else 0;

    const a_is_ref = align_a >= align_b; // tie → A
    const ref = if (a_is_ref) face_a else face_b;
    const inc = if (a_is_ref) face_b else face_a;
    const rn = if (a_is_ref) n_a_face else n_b_face;
    const r_ref = if (a_is_ref) r_a else r_b;
    const r_inc = if (a_is_ref) r_b else r_a;
    const ref_pt = ref.verts[0];

    // FIX-1 (edge-edge): the reference face normal `rn` is the penetration axis
    // ONLY when it aligns with the contact axis `n_a` (a genuine face-face). For
    // an edge/vertex contact `n_a` is an edge-cross direction no box quad aligns
    // with, so measuring penetration along `rn` is wrong (it diverges from the EPA
    // depth). Detect it by `|rn · n_a|` and fall back to the witness-point single
    // contact, whose depth is along `n_a` (EPA / GJK-closest).
    const face_face_min: T = if (T == f32) 0.999 else 0.9999;
    if (@abs(rn.dot(n_a)) < face_face_min) {
        return pointCoreContact(T, n_world, closest_a, closest_b, r_a, r_b, base_penetration, singleContactFid(T, ref, inc));
    }

    // Clip the incident polygon/segment against the reference side planes,
    // carrying a stable feature id per point (FIX-2).
    var clip_buf: [max_clip]Vec3T = undefined;
    var fid_buf: [max_clip]u32 = undefined;
    const clipped = clipIncident(T, inc, ref, rn, &clip_buf, &fid_buf);

    // Keep penetrating points IN A'S FRAME (FIX-4): reduce/dedup in A's frame so
    // precision holds far from the world origin; map only the chosen ≤ 4 points to
    // world at the very end.
    var raw: [max_clip]Candidate(T) = undefined;
    var raw_n: usize = 0;
    for (clipped, 0..) |v, ci| {
        const s = v.sub(ref_pt).dot(rn);
        const pen = r_sum - s;
        // Keep points on the boundary within float noise; SCALE-RELATIVE (never an
        // absolute metric constant, E7): the rounding of `pen = r_sum − s` is
        // `~floatEps·(r_sum + |v − ref_pt|)`, so a point more negative than that is
        // genuinely outside and dropped.
        const keep_eps = 16 * std.math.floatEps(T) * (r_sum + v.sub(ref_pt).length());
        if (pen < -keep_eps) continue;
        // Surface points: reference face + r_ref outward; incident core − r_inc.
        const foot = v.sub(rn.scale(s));
        const pos_a_frame = foot.add(v).scale(0.5).add(rn.scale((r_ref - r_inc) * 0.5));
        raw[raw_n] = .{ .pos = pos_a_frame, .pen = @max(pen, 0), .fid = fid_buf[ci] };
        raw_n += 1;
    }

    if (raw_n == 0) {
        // Degenerate clip (an oblique feature that clipped empty): fall back to the
        // single witness-point contact so a genuine overlap is never lost.
        return pointCoreContact(T, n_world, closest_a, closest_b, r_a, r_b, base_penetration, singleContactFid(T, ref, inc));
    }

    // Reduce to ≤ 4 (A's frame, deepest + area-maximising), then map to world.
    var idx: [4]usize = undefined;
    const count = reduceToFour(T, raw[0..raw_n], n_a, &idx);
    var points: [4]ContactPoint(T) = undefined;
    for (0..count) |i| {
        const c = raw[idx[i]];
        points[i] = .{ .position = rot_a.rotateVec3(c.pos).add(pos_a), .penetration = c.pen, .feature_id = c.fid };
    }
    for (count..4) |i| points[i] = .{ .position = Vec3T.zero, .penetration = 0, .feature_id = 0 };
    return .{ .normal = n_world, .points = points, .count = @intCast(count) };
}

/// The shared single-contact path (point core, edge/vertex contact, or a
/// degenerate empty clip): one contact from the GJK/EPA witness points, on the
/// contact plane midway between the two inflated surfaces, depth along `n_world`.
fn pointCoreContact(comptime T: type, n_world: math.Vec(3, T), closest_a: math.Vec(3, T), closest_b: math.Vec(3, T), r_a: T, r_b: T, base_penetration: T, feature_id: u32) ContactManifold(T) {
    const sa = closest_a.add(n_world.scale(r_a)); // A's surface toward B
    const sb = closest_b.sub(n_world.scale(r_b)); // B's surface toward A
    return oneContact(T, n_world, sa.add(sb).scale(0.5), @max(base_penetration, 0), feature_id);
}

// --- Internal helpers ---

/// Largest number of points the incident clip can transiently hold: an incident
/// quad (4) clipped against up to 4 reference side planes yields ≤ 8.
const max_clip: usize = 8;

/// A candidate contact before reduction: its A-frame position, penetration, and
/// stable feature id (FIX-2/FIX-4).
fn Candidate(comptime T: type) type {
    return struct { pos: math.Vec(3, T), pen: T, fid: u32 };
}

/// A single-point manifold with the tail zeroed.
fn oneContact(comptime T: type, normal: math.Vec(3, T), position: math.Vec(3, T), penetration: T, feature_id: u32) ContactManifold(T) {
    const Vec3T = math.Vec(3, T);
    const zero = ContactPoint(T){ .position = Vec3T.zero, .penetration = 0, .feature_id = 0 };
    return .{
        .normal = normal,
        .points = .{ .{ .position = position, .penetration = penetration, .feature_id = feature_id }, zero, zero, zero },
        .count = 1,
    };
}

/// The feature id of a SINGLE witness contact (point core, edge/vertex fallback,
/// or degenerate empty clip): the reference side (`class_a`) high, the incident
/// side (`class_c`) low. Each side encodes its REAL sub-feature — a count-1
/// feature (a sphere point, or an end-on capsule endpoint) is a VERTEX (its
/// `vert_id`), otherwise a FACE (its `face_id`) — so a capsule's `+Y` (vert 0)
/// and `−Y` (vert 1) endpoints, and an end-on endpoint (here) vs a side segment
/// (`clipSegment`), get distinct ids (Codex FIX-12). The `(class_a, class_c)`
/// class pair is used by NO clip producer (kept vertex `(class_a, class_a)`, edge
/// crossing `(class_edge, class_edge)`, reference corner `(class_c, class_c)`,
/// `clipSegment` endpoints `(class_a, class_a)`), so a single-contact id can never
/// alias a clip id for a body pair. No untagged packer remains.
fn singleContactFid(comptime T: type, ref_face: support.Face(T), inc_face: support.Face(T)) u32 {
    const feat_ref: u16 = if (ref_face.count == 1) ref_face.vert_ids[0] else ref_face.face_id;
    const feat_inc: u16 = if (inc_face.count == 1) inc_face.vert_ids[0] else inc_face.face_id;
    return featureId(class_a | (feat_ref & id_mask), class_c | (feat_inc & id_mask));
}

/// Whether two count-2 segment features are PARALLEL, non-degenerate line
/// segments — the sole regime where a 2-point segment clip is a correct manifold
/// (parallel-projection overlap, e.g. two side-by-side capsules). A zero-length
/// segment (a `half_height == 0` capsule → a point) or a non-parallel (crossed)
/// pair returns false, so the caller takes the single-witness path (M1.1.4).
///
/// Threshold: `sin²θ = |u×v|² / (|u|²·|v|²) ≤ parallel_rel`, the same relative
/// float-noise form as `support.supportingFace`'s end-on `aligned_rel` (not a
/// magic geometric angle). Symmetric under an A/B swap by construction — both
/// `|u×v|²` and `|u|²·|v|²` are invariant when `u` and `v` are exchanged.
fn segmentsParallel(comptime T: type, fa: support.Face(T), fb: support.Face(T)) bool {
    const u = fa.verts[1].sub(fa.verts[0]);
    const v = fb.verts[1].sub(fb.verts[0]);
    const uu = u.dot(u);
    const vv = v.dot(v);
    // A degenerate (zero-length) segment is a point, never a parallel line pair
    // (NaN-safe: a non-finite length also falls through to the single witness).
    if (!(uu > 0) or !(vv > 0)) return false;
    const cr = u.cross(v);
    const parallel_rel: T = if (T == f32) 1.0e-6 else 1.0e-12;
    return cr.dot(cr) <= parallel_rel * uu * vv;
}

/// Outward normal of a face in A's frame: the polygon normal oriented toward
/// `expected_axis` for a real face (≥ 3 verts); the axis itself as a proxy for a
/// point / segment feature (which has no face normal).
fn faceNormalA(comptime T: type, face: support.Face(T), expected_axis: math.Vec(3, T)) math.Vec(3, T) {
    if (face.count < 3) return expected_axis;
    var n = face.verts[1].sub(face.verts[0]).cross(face.verts[2].sub(face.verts[0]));
    const l2 = n.dot(n);
    if (!(l2 > 0)) return expected_axis;
    n = n.scale(1.0 / @sqrt(l2));
    return if (n.dot(expected_axis) < 0) n.neg() else n;
}

// Feature-id classes, per 16-bit half (top two bits). A contact's `feature_id`
// is `(reference_feature << 16) | incident_feature`; the class bits keep the
// three contact kinds in DISTINCT id ranges so they never alias (Codex FIX-9):
//   reference half: face (`class_a`), side plane / edge (`class_edge`), vertex /
//     corner (`class_c`);  incident half: vertex (`class_a`), edge (`class_edge`),
//     face (`class_c`).
const class_a: u16 = 0x0000; // reference face / incident vertex
const class_edge: u16 = 0x4000; // reference side plane / incident edge
const class_c: u16 = 0x8000; // reference vertex (corner) / incident face
const class_mask: u16 = 0xc000;
const id_mask: u16 = 0x3fff;

/// Pack a `feature_id` from a class-tagged reference half and incident half.
fn featureId(ref16: u16, inc16: u16) u32 {
    return (@as(u32, ref16) << 16) | @as(u32, inc16);
}

/// The stable feature id of a clip-intersection point crossed by reference side
/// plane `qid`, on the incident face `inc_face_id`. A segment whose two endpoints
/// share a reference plane `p` is a reference cut-edge, so the new point lies on
/// `p` AND `qid` — a REFERENCE CORNER (a ref vertex), whose incident feature is
/// the incident FACE (`class_c | inc_face_id` — carrying which incident face, so
/// a supporting-face flip inter-frame changes the id and warm-starting cannot
/// mis-match two corners at the same ref vertex on different faces; Codex FIX-10).
/// It must NOT inherit a neighbour's incident edge (Codex FIX-9: that aliased
/// distinct contacts). Otherwise the point is an incident-edge × ref-edge crossing.
fn intersectionFid(qid: u16, cur_fid: u32, nxt_fid: u32, inc_face_id: u16) u32 {
    const cur_ref: u16 = @intCast(cur_fid >> 16);
    const nxt_ref: u16 = @intCast(nxt_fid >> 16);
    if (commonRefPlane(cur_ref, nxt_ref)) |p| {
        return featureId(class_c | refVertexId(p, qid), class_c | (inc_face_id & id_mask));
    }
    const cur_inc: u16 = @intCast(cur_fid & 0xffff);
    const nxt_inc: u16 = @intCast(nxt_fid & 0xffff);
    return featureId(class_edge | (qid & id_mask), class_edge | incidentEdgeId(cur_inc, nxt_inc));
}

/// The incident-edge id (its two vertices, `lo·8 + hi`), carrying an existing
/// incident-edge provenance when an endpoint is already an incident-edge
/// intersection. A non-vertex endpoint — a reference corner (incident class
/// `class_c`), which the Sutherland-Hodgman topology should keep out of this
/// branch (a corner shares a plane with its neighbours, so `commonRefPlane`
/// catches it), but defend anyway — self-pairs the vertex endpoint (`v·8 + v`,
/// `lo == hi`) so it can NEVER alias a genuine two-vertex incident edge (`lo < hi`).
fn incidentEdgeId(a_inc: u16, b_inc: u16) u16 {
    if ((a_inc & class_mask) == class_edge) return a_inc & id_mask;
    if ((b_inc & class_mask) == class_edge) return b_inc & id_mask;
    const a_vert = (a_inc & class_mask) == class_a;
    const b_vert = (b_inc & class_mask) == class_a;
    const av = a_inc & id_mask;
    const bv = b_inc & id_mask;
    if (a_vert and b_vert) return @min(av, bv) * 8 + @max(av, bv);
    if (a_vert) return av * 8 + av;
    if (b_vert) return bv * 8 + bv;
    return 0;
}

/// The reference side planes an endpoint's reference feature lies on (0, 1, or 2),
/// written into `out`: a face lies on none, an edge on one, a corner on its two.
fn refPlaneSet(ref16: u16, out: *[2]u16) usize {
    return switch (ref16 & class_mask) {
        class_a => 0,
        class_edge => blk: {
            out[0] = ref16 & id_mask;
            break :blk 1;
        },
        else => blk: { // class_c: a ref vertex = the sorted pair of side planes
            const id = ref16 & id_mask;
            out[0] = id / 32;
            out[1] = id % 32;
            break :blk 2;
        },
    };
}

/// A reference side plane both endpoints lie on (the segment is a ref cut-edge),
/// or null.
fn commonRefPlane(cur_ref: u16, nxt_ref: u16) ?u16 {
    var ca: [2]u16 = undefined;
    var cb: [2]u16 = undefined;
    const na = refPlaneSet(cur_ref, &ca);
    const nb = refPlaneSet(nxt_ref, &cb);
    for (ca[0..na]) |a| {
        for (cb[0..nb]) |b| {
            if (a == b) return a;
        }
    }
    return null;
}

/// A reference vertex id: the sorted pair of the two side-plane ids meeting there
/// (`lo·32 + hi`; side-plane ids are ≤ ~23, so this stays inside `id_mask`).
fn refVertexId(p: u16, q: u16) u16 {
    return @min(p, q) * 32 + @max(p, q);
}

/// Clip the incident feature against the reference face's side planes (planes
/// through each reference edge, perpendicular to the reference face, oriented
/// inward; a segment reference contributes its two endpoint planes). A polygon
/// incident (≥ 3 verts) is clipped by Sutherland-Hodgman; a segment incident
/// (2 verts) is clipped as an OPEN segment (Liang-Barsky) — a closed-polygon
/// clip would double-emit the crossing point (adversarial-review finding E).
/// Threads a stable feature id per surviving point into `fid_buf` (FIX-2).
/// Returns the surviving points as a slice into `buf`.
fn clipIncident(comptime T: type, inc: support.Face(T), ref: support.Face(T), rn: math.Vec(3, T), buf: *[max_clip]math.Vec(3, T), fid_buf: *[max_clip]u32) []math.Vec(3, T) {
    const Vec3T = math.Vec(3, T);
    // Build the reference side planes (point + inward normal + stable ref-edge id).
    var plane_p: [4]Vec3T = undefined;
    var plane_n: [4]Vec3T = undefined;
    var plane_ref: [4]u16 = undefined;
    var np: usize = 0;
    const centroid = faceCentroid(T, ref);
    if (ref.count >= 3) {
        for (0..ref.count) |i| {
            const a = ref.verts[i];
            const b = ref.verts[(i + 1) % ref.count];
            var pn = rn.cross(b.sub(a)); // ⟂ the face and the edge
            if (pn.dot(centroid.sub(a)) < 0) pn = pn.neg();
            if (pn.dot(pn) > 0) {
                plane_p[np] = a;
                plane_n[np] = pn;
                plane_ref[np] = @as(u16, ref.face_id) * 4 + @as(u16, @intCast(i)); // stable ref-edge id
                np += 1;
            }
        }
    } else { // segment reference: two endpoint planes ⟂ the segment axis
        const axis = ref.verts[1].sub(ref.verts[0]);
        const ends = [2]struct { p: Vec3T, pn: Vec3T, id: u16 }{
            .{ .p = ref.verts[0], .pn = axis, .id = ref.vert_ids[0] },
            .{ .p = ref.verts[1], .pn = axis.neg(), .id = ref.vert_ids[1] },
        };
        for (ends) |e| {
            var pn = e.pn;
            if (pn.dot(centroid.sub(e.p)) < 0) pn = pn.neg();
            if (pn.dot(pn) > 0) {
                plane_p[np] = e.p;
                plane_n[np] = pn;
                plane_ref[np] = e.id;
                np += 1;
            }
        }
    }

    // Initial incident feature ids: (reference face id) high, (incident vertex id) low.
    var inc_fids: [4]u32 = undefined;
    for (0..inc.count) |i| inc_fids[i] = (@as(u32, ref.face_id) << 16) | @as(u32, inc.vert_ids[i]);

    if (inc.count == 2) return clipSegment(T, inc.verts[0], inc.verts[1], inc_fids[0], inc_fids[1], plane_p[0..np], plane_n[0..np], plane_ref[0..np], inc.face_id, buf, fid_buf);
    return clipPolygon(T, inc, inc_fids, plane_p[0..np], plane_n[0..np], plane_ref[0..np], buf, fid_buf);
}

/// Sutherland-Hodgman clip of a polygon incident against the reference side
/// planes; ping-pongs two stack buffers, threading a parallel feature-id buffer.
fn clipPolygon(comptime T: type, inc: support.Face(T), inc_fids: [4]u32, plane_p: []const math.Vec(3, T), plane_n: []const math.Vec(3, T), plane_ref: []const u16, buf: *[max_clip]math.Vec(3, T), fid_buf: *[max_clip]u32) []math.Vec(3, T) {
    const Vec3T = math.Vec(3, T);
    var poly_a: [max_clip]Vec3T = undefined;
    var poly_b: [max_clip]Vec3T = undefined;
    var fa: [max_clip]u32 = undefined;
    var fb: [max_clip]u32 = undefined;
    var cur: []Vec3T = poly_a[0..inc.count];
    var cur_f: []u32 = fa[0..inc.count];
    for (0..inc.count) |i| {
        cur[i] = inc.verts[i];
        cur_f[i] = inc_fids[i];
    }
    for (plane_p, plane_n, plane_ref) |p, pn, pref| {
        const dest_is_b = (cur.ptr == &poly_a);
        const out_v: []Vec3T = if (dest_is_b) poly_b[0..] else poly_a[0..];
        const out_f: []u32 = if (dest_is_b) fb[0..] else fa[0..];
        const out_n = clipAgainstPlane(T, cur, cur_f, p, pn, pref, inc.face_id, out_v, out_f);
        cur = out_v[0..out_n];
        cur_f = out_f[0..out_n];
        if (out_n == 0) break;
    }
    for (0..cur.len) |i| {
        buf[i] = cur[i];
        fid_buf[i] = cur_f[i];
    }
    return buf[0..cur.len];
}

/// One Sutherland-Hodgman pass on a CLOSED polygon: keep the part on the inward
/// side of the plane (point `p`, inward normal `pn`), inserting edge crossings;
/// threads feature ids (kept vertex → its id, intersection → `intersectionFid`).
fn clipAgainstPlane(comptime T: type, poly: []const math.Vec(3, T), poly_f: []const u32, p: math.Vec(3, T), pn: math.Vec(3, T), plane_ref: u16, inc_face_id: u16, out_v: []math.Vec(3, T), out_f: []u32) usize {
    if (poly.len == 0) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < poly.len) : (i += 1) {
        const cur = poly[i];
        const nxt = poly[(i + 1) % poly.len];
        const dc = cur.sub(p).dot(pn); // ≥ 0 inside
        const dn = nxt.sub(p).dot(pn);
        if (dc >= 0) {
            if (n < out_v.len) {
                out_v[n] = cur;
                out_f[n] = poly_f[i];
                n += 1;
            }
        }
        if ((dc >= 0) != (dn >= 0)) { // edge crosses ⇒ insert the intersection
            const denom = dc - dn;
            if (denom != 0) {
                const t = dc / denom;
                if (n < out_v.len) {
                    out_v[n] = cur.add(nxt.sub(cur).scale(t));
                    out_f[n] = intersectionFid(plane_ref, poly_f[i], poly_f[(i + 1) % poly.len], inc_face_id);
                    n += 1;
                }
            }
        }
    }
    return n;
}

/// Clip the OPEN segment `a`–`b` against the reference side half-spaces
/// (Liang-Barsky over `t ∈ [0, 1]`). Emits the surviving segment's endpoints (2,
/// or 1 if it collapses); empty if fully clipped away. A clipped endpoint takes an
/// intersection feature id; an un-clipped one keeps its incident-vertex id.
fn clipSegment(comptime T: type, a: math.Vec(3, T), b: math.Vec(3, T), a_fid: u32, b_fid: u32, plane_p: []const math.Vec(3, T), plane_n: []const math.Vec(3, T), plane_ref: []const u16, inc_face_id: u16, buf: *[max_clip]math.Vec(3, T), fid_buf: *[max_clip]u32) []math.Vec(3, T) {
    const dir = b.sub(a);
    var t0: T = 0;
    var t1: T = 1;
    var f0 = a_fid;
    var f1 = b_fid;
    for (plane_p, plane_n, plane_ref) |p, pn, pref| {
        const num = a.sub(p).dot(pn); // value of (x−p)·pn at t = 0
        const den = dir.dot(pn); // d/dt of (x−p)·pn
        if (den == 0) {
            if (num < 0) return buf[0..0]; // parallel and outside ⇒ nothing survives
        } else {
            const t = -num / den; // (x−p)·pn = 0 at this t
            if (den > 0) {
                if (t > t0) {
                    t0 = t; // entering the half-space
                    f0 = intersectionFid(pref, a_fid, b_fid, inc_face_id);
                }
            } else {
                if (t < t1) {
                    t1 = t; // leaving it
                    f1 = intersectionFid(pref, a_fid, b_fid, inc_face_id);
                }
            }
            if (t0 > t1) return buf[0..0];
        }
    }
    buf[0] = a.add(dir.scale(t0));
    fid_buf[0] = f0;
    const eps: T = if (T == f32) 1.0e-6 else 1.0e-12;
    if (t1 - t0 <= eps) return buf[0..1];
    buf[1] = a.add(dir.scale(t1));
    fid_buf[1] = f1;
    return buf[0..2];
}

/// Centroid of a face's valid vertices (a reference interior point for inward
/// plane orientation).
fn faceCentroid(comptime T: type, face: support.Face(T)) math.Vec(3, T) {
    const Vec3T = math.Vec(3, T);
    var c = Vec3T.zero;
    for (0..face.count) |i| c = c.add(face.verts[i]);
    return c.scale(1.0 / @as(T, @floatFromInt(face.count)));
}

/// Reduce a contact set to ≤ 4 points. The contacts are coplanar (they lie on
/// the contact plane, normal `normal`), so the 4th point is chosen by SIGNED area
/// about the `k0`–`k1` axis — the two extreme points on each side of that axis —
/// not by distance from the (also-coplanar) `k0`,`k1`,`k2` triangle plane, which
/// is degenerate for a planar set (adversarial-review finding F). Coincident
/// points are deduplicated first. Deterministic tie-breaks (strict `>`; first
/// index wins). Writes the chosen `pts` indices into `idx`, returns the count.
fn reduceToFour(comptime T: type, pts: []const Candidate(T), normal: math.Vec(3, T), idx: *[4]usize) usize {
    // Coincidence tolerance for the dedup: PER-AXIS relative to that axis's own
    // A-frame coordinate scale (`eps[k] = 16·floatEps·max|pos[k]|`), NEVER an
    // isotropic scalar (E8, class B). An isotropic eps driven by a large axis
    // (e.g. a `he = (1.1e6, 1, 1)` box) would swamp a small axis and merge points
    // genuinely separated along it. Two points coincide ⟺ `|Δ[k]| ≤ eps[k]` for
    // ALL k — anisotropic-safe and coordinate-covariant. A-frame positions stay
    // small far from the world origin, preserving the M1.1.3 reduction.
    var coord_scale = [3]T{ 0, 0, 0 };
    for (pts) |c| {
        const p = c.pos.toArray();
        inline for (0..3) |k| coord_scale[k] = @max(coord_scale[k], @abs(p[k]));
    }
    var eps: [3]T = undefined;
    inline for (0..3) |k| eps[k] = 16 * std.math.floatEps(T) * coord_scale[k];
    // Deduplicate coincident contacts (indices into `pts`).
    var uniq: [max_clip]usize = undefined;
    var un: usize = 0;
    outer: for (pts, 0..) |c, i| {
        const cp = c.pos.toArray();
        for (0..un) |j| {
            const up = pts[uniq[j]].pos.toArray();
            var coincident = true;
            inline for (0..3) |k| {
                if (@abs(cp[k] - up[k]) > eps[k]) coincident = false;
            }
            if (coincident) continue :outer;
        }
        uniq[un] = i;
        un += 1;
    }
    if (un <= 4) {
        for (0..un) |i| idx[i] = uniq[i];
        return un;
    }

    // 1: deepest. 2: farthest from it.
    var k0 = uniq[0];
    for (uniq[0..un]) |i| {
        if (pts[i].pen > pts[k0].pen) k0 = i;
    }
    var k1 = uniq[0];
    var best_d: T = -1;
    for (uniq[0..un]) |i| {
        const d = pts[i].pos.sub(pts[k0].pos).lengthSq();
        if (d > best_d) {
            best_d = d;
            k1 = i;
        }
    }
    // 3 & 4: extreme signed area on each side of the k0–k1 axis (coplanar set).
    var k2 = k0;
    var k3 = k0;
    var best_pos: T = 0;
    var best_neg: T = 0;
    const axis = pts[k1].pos.sub(pts[k0].pos);
    for (uniq[0..un]) |i| {
        const area = pts[i].pos.sub(pts[k0].pos).cross(axis).dot(normal);
        if (area > best_pos) {
            best_pos = area;
            k2 = i;
        }
        if (area < best_neg) {
            best_neg = area;
            k3 = i;
        }
    }
    idx[0] = k0;
    idx[1] = k1;
    idx[2] = k2;
    idx[3] = k3;
    // Guard against a one-sided set leaving k2 or k3 latched onto k0.
    var out: usize = 0;
    var chosen: [4]usize = undefined;
    for (idx.*) |c| {
        var dup = false;
        for (0..out) |j| {
            if (chosen[j] == c) dup = true;
        }
        if (!dup) {
            chosen[out] = c;
            out += 1;
        }
    }
    for (0..out) |i| idx[i] = chosen[i];
    return out;
}

/// A deterministic separation normal for the shallow `dist ≈ 0` boundary — the
/// centre-to-centre direction, falling back to +X if the centres coincide.
fn fallbackNormal(comptime T: type, pos_a: math.Vec(3, T), pos_b: math.Vec(3, T)) math.Vec(3, T) {
    const Vec3T = math.Vec(3, T);
    const d = pos_b.sub(pos_a);
    const l2 = d.dot(d);
    return if (l2 > 0) d.scale(1.0 / @sqrt(l2)) else Vec3T.unit_x;
}

/// Whether pair `(a, b)` is the reverse of canonical order — i.e. `collide`
/// should compute `(b, a)` and negate. A strict, total, deterministic order on
/// (shape, pose): position, then rotation, then radius, then core kind + extents.
/// Two distinct shapes/poses always compare unequal, so the winner is caller-
/// independent — the basis of order-independence.
///
/// Degenerate exception (RATIFIED, brief RD-4 / `engine-physics-forge.md`
/// narrowphase §): two shapes with BIT-IDENTICAL pose AND geometry compare equal
/// (neither `poseAfter(a,b)` nor `poseAfter(b,a)` is true). Then both call orders
/// run the same `collideOrdered` and return the SAME normal — for coincident
/// identical shapes the A→B axis is geometrically undefined (measure-zero), so
/// the same deterministic-but-arbitrary unit vector in both orders is the ratified
/// contract, not a negated pair. `BodyManager`'s `collidePair` restores full
/// order-independence for real bodies via a canonical body-id order (distinct
/// bodies always break the tie).
fn poseAfter(
    comptime T: type,
    shape_a: support.SupportShape(T),
    pos_a: math.Vec(3, T),
    rot_a: math.Quat(T),
    shape_b: support.SupportShape(T),
    pos_b: math.Vec(3, T),
    rot_b: math.Quat(T),
) bool {
    const pa = pos_a.toArray();
    const pb = pos_b.toArray();
    inline for (0..3) |i| {
        if (pa[i] != pb[i]) return pa[i] > pb[i];
    }
    const ra = [4]T{ rot_a.x, rot_a.y, rot_a.z, rot_a.w };
    const rb = [4]T{ rot_b.x, rot_b.y, rot_b.z, rot_b.w };
    inline for (0..4) |i| {
        if (ra[i] != rb[i]) return ra[i] > rb[i];
    }
    if (shape_a.radius != shape_b.radius) return shape_a.radius > shape_b.radius;
    // Core kind (point < segment < box), then the core's full parameters
    // lexicographically — a strict total order (no distinct cores compare equal,
    // unlike a `|half_extents|`-only tag where e.g. (1,2,3) and (3,2,1) collide).
    const ka = coreKind(T, shape_a);
    const kb = coreKind(T, shape_b);
    if (ka != kb) return ka > kb;
    switch (shape_a.core) {
        .point => return false,
        .segment => |ha| return ha > shape_b.core.segment,
        .box => |hea| {
            const a = hea.toArray();
            const b = shape_b.core.box.toArray();
            inline for (0..3) |i| {
                if (a[i] != b[i]) return a[i] > b[i];
            }
            return false;
        },
    }
}

/// Core-kind rank for the canonical order: point < segment < box.
fn coreKind(comptime T: type, shape: support.SupportShape(T)) u8 {
    return switch (shape.core) {
        .point => 0,
        .segment => 1,
        .box => 2,
    };
}

const testing = std.testing;

test "manifold contact types round-trip" {
    const T = f32;
    const V = math.Vec(3, T);
    const M = ContactManifold(T);
    const P = ContactPoint(T);

    const zero_pt = P{ .position = V.zero, .penetration = 0, .feature_id = 0 };
    const m = M{
        .normal = V.unit_x,
        .points = .{
            P{ .position = V.fromArray(.{ 1, 2, 3 }), .penetration = 0.25, .feature_id = 0x0003_0007 },
            P{ .position = V.fromArray(.{ -1, 0, 4 }), .penetration = 0.5, .feature_id = 0x0002_0005 },
            zero_pt,
            zero_pt,
        },
        .count = 2,
    };

    try testing.expect(m.normal.approxEql(V.unit_x, 1e-6));
    try testing.expectEqual(@as(u8, 2), m.count);
    try testing.expect(m.points[0].position.approxEql(V.fromArray(.{ 1, 2, 3 }), 1e-6));
    try testing.expectEqual(@as(T, 0.25), m.points[0].penetration);
    try testing.expectEqual(@as(u32, 0x0003_0007), m.points[0].feature_id);
    try testing.expect(m.points[1].position.approxEql(V.fromArray(.{ -1, 0, 4 }), 1e-6));
    try testing.expectEqual(@as(T, 0.5), m.points[1].penetration);
    try testing.expectEqual(@as(u32, 0x0002_0005), m.points[1].feature_id);

    // Generic over the scalar: the same types instantiate at f64.
    const M64 = ContactManifold(f64);
    const V64 = math.Vec(3, f64);
    const m64 = M64{
        .normal = V64.unit_y,
        .points = .{
            ContactPoint(f64){ .position = V64.zero, .penetration = 1.5, .feature_id = 1 },
            ContactPoint(f64){ .position = V64.zero, .penetration = 0, .feature_id = 0 },
            ContactPoint(f64){ .position = V64.zero, .penetration = 0, .feature_id = 0 },
            ContactPoint(f64){ .position = V64.zero, .penetration = 0, .feature_id = 0 },
        },
        .count = 1,
    };
    try testing.expectEqual(@as(f64, 1.5), m64.points[0].penetration);
    try testing.expect(m64.normal.approxEql(V64.unit_y, 1e-12));
}
