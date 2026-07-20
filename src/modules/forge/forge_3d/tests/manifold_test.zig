//! M1.1.3/E3 acceptance suite for the forge_3d contact-manifold generator
//! (`collide`: GJK → supporting-face clipping, both regimes). Keyed to
//! `config.Real` so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const math = @import("foundation").math;
const api = @import("weld_forge");
const bm_mod = @import("../body_manager.zig");
const shape_mod = @import("../shape.zig");
const broadphase = @import("../pipeline/broadphase.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const BodyManager = bm_mod.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const Broadphase = broadphase.Broadphase(Real);
const BodyId = api.BodyId;
const ApiVec3 = math.Vec3;
const testing = std.testing;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}
fn sphereShape(radius: Real) SupportShape {
    return .{ .core = .point, .radius = radius };
}
fn capsuleShape(half_height: Real, radius: Real) SupportShape {
    return .{ .core = .{ .segment = half_height }, .radius = radius };
}
fn boxShape(hx: Real, hy: Real, hz: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = 0 };
}
fn roundedBoxShape(hx: Real, hy: Real, hz: Real, radius: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = radius };
}

const tol: Real = 1.0e-3;

fn finite3(v: Vec3r) bool {
    const a = v.toArray();
    return std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(a[2]);
}

fn collide(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) ?ContactManifold {
    return narrowphase.collide(Real, sa, pa, ra, sb, pb, rb);
}

test "box-box face contact yields a multi-point manifold" {
    // A unit box at the origin, another stacked 1.5 above ⇒ overlap 0.5 along Y.
    // Face-face contact: 4 points on the contact plane (y = 0.75), each
    // penetration 0.5, normal +Y (A→B).
    const box = boxShape(1, 1, 1);
    const m = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.5, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m.count);
    try testing.expect(m.normal.approxEql(vr(0, 1, 0), tol));
    for (0..m.count) |i| {
        try testing.expectApproxEqAbs(@as(Real, 0.5), m.points[i].penetration, tol);
        try testing.expect(finite3(m.points[i].position));
        // On the contact plane midway between the two faces (y = 0.75).
        try testing.expectApproxEqAbs(@as(Real, 0.75), m.points[i].position.toArray()[1], tol);
    }

    // Same overlap under an oblique global transform ⇒ depth invariant, normal
    // rotated, still 4 points.
    const g = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7);
    const t = vr(-4, 7, 2);
    const m2 = collide(box, g.rotateVec3(vr(0, 0, 0)).add(t), g, box, g.rotateVec3(vr(0, 1.5, 0)).add(t), g).?;
    try testing.expectEqual(@as(u8, 4), m2.count);
    try testing.expect(m2.normal.approxEql(g.rotateVec3(vr(0, 1, 0)), tol));
    for (0..m2.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.5), m2.points[i].penetration, tol);
}

test "manifold feature matrix" {
    // sphere/* ⇒ exactly 1 point.
    {
        // sphere/box: sphere centre 0.6 inside the +Z face ⇒ pen 0.6 + r_sum.
        const m = collide(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(0, 0, 0.4), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), m.count);
        try testing.expect(m.normal.approxEql(vr(0, 0, 1), tol));
        try testing.expectApproxEqAbs(@as(Real, 0.6 + 0.5), m.points[0].penetration, tol);
    }
    {
        // sphere/sphere overlapping (cores 1.2 apart, r_sum 2) ⇒ 1 point, pen 0.8.
        const m = collide(sphereShape(1), vr(0, 0, 0), Quatr.identity, sphereShape(1), vr(1.2, 0, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), m.count);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
        try testing.expectApproxEqAbs(@as(Real, 0.8), m.points[0].penetration, tol);
    }
    // capsule/capsule parallel side overlap ⇒ 1-2 points (segment feature).
    {
        // Two Y-axis capsules, cores 0.3 apart in X, r_sum 1 ⇒ shallow line contact.
        const m = collide(capsuleShape(1, 0.5), vr(0, 0, 0), Quatr.identity, capsuleShape(1, 0.5), vr(0.8, 0, 0), Quatr.identity).?;
        try testing.expect(m.count >= 1 and m.count <= 2);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
        for (0..m.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.2), m.points[i].penetration, tol);
    }
    // box/capsule side ⇒ 1-2 points.
    {
        // A Y-capsule whose segment lies just past the box +X face.
        const m = collide(boxShape(1, 1, 1), vr(0, 0, 0), Quatr.identity, capsuleShape(0.5, 0.5), vr(1.3, 0, 0), Quatr.identity).?;
        try testing.expect(m.count >= 1 and m.count <= 2);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
    }
}

/// Whether the first `count` manifold points are pairwise distinct.
fn pointsDistinct(m: ContactManifold) bool {
    for (0..m.count) |i| {
        for (i + 1..m.count) |j| {
            if (m.points[i].position.approxEql(m.points[j].position, 1.0e-4)) return false;
        }
    }
    return true;
}

test "box-box rotated face reduces to four distinct points" {
    // Adversarial-review regime (finding F): a yawed box makes the incident face
    // clip to an OCTAGON (8 coplanar points), which the reduction must collapse to
    // four DISTINCT spread points — not a degenerate set with a duplicated corner.
    // Unit box A at origin; unit box B 1.9 above, yawed 45° about Y ⇒ overlap 0.1.
    const box = boxShape(1, 1, 1);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0);
    const m = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.9, 0), yaw).?;
    try testing.expectEqual(@as(u8, 4), m.count);
    try testing.expect(pointsDistinct(m)); // no duplicated corner (finding F)
    try testing.expect(m.normal.approxEql(vr(0, 1, 0), tol));
    for (0..m.count) |i| {
        try testing.expectApproxEqAbs(@as(Real, 0.1), m.points[i].penetration, tol);
        try testing.expectApproxEqAbs(@as(Real, 0.95), m.points[i].position.toArray()[1], tol); // contact plane
    }
}

test "staggered capsule segment clips without a duplicate point" {
    // Adversarial-review regime (finding E): two parallel Y-capsules staggered
    // along their axis so B's segment straddles A's endpoint plane. The segment
    // clip must yield two DISTINCT points, not a doubled crossing point.
    const cap = capsuleShape(1, 0.5);
    const m = collide(cap, vr(0, 0, 0), Quatr.identity, cap, vr(0, 0.5, 0.8), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 2), m.count);
    try testing.expect(pointsDistinct(m));
    try testing.expect(m.normal.approxEql(vr(0, 0, 1), tol));
    for (0..m.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.2), m.points[i].penetration, tol); // r_sum(1) − dist(0.8)
}

test "intersection feature ids are unique among simultaneous contacts" {
    // Codex P1a repro: two unit boxes, B offset into a corner with a small yaw so
    // the manifold points are edge×plane intersections. The old `@min(edge)` key
    // aliased distinct box edges (a vertex is on 3 edges) → two contacts shared
    // 0x800e8002; the sorted-pair key makes every simultaneous contact distinct.
    const box = boxShape(1, 1, 1);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_y, 0.05);
    const m = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(-0.9, 1.9, -0.9), yaw).?;
    try testing.expect(m.count >= 2);
    for (0..m.count) |i| {
        for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
    }
}

/// Feature-id set of a manifold (up to 4), for set comparison.
fn fidSet(m: ContactManifold) [4]u32 {
    var s: [4]u32 = .{ 0, 0, 0, 0 };
    for (0..m.count) |i| s[i] = m.points[i].feature_id;
    return s;
}

/// Whether every one of `a`'s first `n` ids appears in `b`'s first `n`.
fn fidSetEq(a: [4]u32, b: [4]u32, n: u8) bool {
    for (0..n) |i| {
        var found = false;
        for (0..n) |j| {
            if (a[i] == b[j]) found = true;
        }
        if (!found) return false;
    }
    return true;
}

/// The feature_id of a reference-corner contact (reference half in the `class_c`
/// range, top two bits `0b10`), or null if the manifold has none.
fn refCornerFid(m: ContactManifold) ?u32 {
    for (0..m.count) |i| {
        const fid = m.points[i].feature_id;
        if ((fid >> 16) & 0xc000 == 0x8000) return fid;
    }
    return null;
}

/// Whether every id of `m` carries a valid class pair — one of the four
/// producers: kept vertex (a,a), edge crossing (edge,edge), reference corner
/// (c,c), single witness contact (a,c).
fn validClassPairs(m: ContactManifold) bool {
    for (0..m.count) |i| {
        const fid = m.points[i].feature_id;
        const r = (fid >> 16) & 0xc000;
        const c = fid & 0xc000;
        const ok = (r == 0x0000 and c == 0x0000) // kept vertex
            or (r == 0x4000 and c == 0x4000) // edge × ref-edge
            or (r == 0x8000 and c == 0x8000) // reference corner
            or (r == 0x0000 and c == 0x8000); // single witness contact
        if (!ok) return false;
    }
    return true;
}

test "capsule endpoint feature ids distinguish the two ends and the segment" {
    // Codex FIX-12: an end-on capsule endpoint must encode WHICH endpoint (its
    // vert id), not just the constant face_id 6 — else +Y and −Y ends share an
    // id, and an endpoint (point-core) is indistinguishable from a side segment.
    const cap = capsuleShape(1, 0.3);
    const sph = sphereShape(0.5);
    // Sphere beyond the +Y end vs the −Y end ⇒ the capsule presents its +Y (vert
    // 0) vs −Y (vert 1) endpoint — distinct ids.
    const id_plus = collide(cap, vr(0, 0, 0), Quatr.identity, sph, vr(0, 1.5, 0), Quatr.identity).?.points[0].feature_id;
    const id_minus = collide(cap, vr(0, 0, 0), Quatr.identity, sph, vr(0, -1.5, 0), Quatr.identity).?.points[0].feature_id;
    try testing.expect(id_plus != id_minus);
    // Sphere beside the capsule ⇒ the capsule presents its SEGMENT (a face) — a
    // different id from either endpoint (endpoint→segment changes the id).
    const id_side = collide(cap, vr(0, 0, 0), Quatr.identity, sph, vr(0.7, 0, 0), Quatr.identity).?.points[0].feature_id;
    try testing.expect(id_side != id_plus and id_side != id_minus);
    // All three are single-contact ids (the disjoint (class_a, class_c) pair).
    inline for (.{ id_plus, id_minus, id_side }) |fid| {
        try testing.expectEqual(@as(u32, 0x0000), (fid >> 16) & 0xc000);
        try testing.expectEqual(@as(u32, 0x8000), fid & 0xc000);
    }
}

test "pose sweep: capsule pairs have distinct well-classed feature ids" {
    // Extend the feature-id coverage to the capsule pairs (Codex FIX-12): every
    // config's manifold has pairwise-distinct ids, each carrying a valid class
    // pair, and no multi-point manifold carries the single-contact (a,c) pair.
    const cap = capsuleShape(1, 0.3);
    const cap2 = capsuleShape(0.6, 0.4);
    const box = boxShape(1, 1, 1);
    const sph = sphereShape(0.5);
    const zrot = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);
    const Combo = struct { a: SupportShape, pb: Vec3r, b: SupportShape, rb: Quatr };
    const combos = [_]Combo{
        .{ .a = cap, .pb = vr(1.1, 0, 0), .b = box, .rb = Quatr.identity }, // capsule side vs box (clipSegment)
        .{ .a = cap, .pb = vr(0, 1.6, 0), .b = box, .rb = Quatr.identity }, // capsule end-on vs box (point-core)
        .{ .a = cap, .pb = vr(0, 0, 0), .b = cap, .rb = zrot }, // crossing capsules
        .{ .a = cap, .pb = vr(0.4, 0.3, 0), .b = cap, .rb = Quatr.identity }, // parallel capsules
        .{ .a = cap, .pb = vr(0.6, 0, 0), .b = sph, .rb = Quatr.identity }, // capsule radial vs sphere
        .{ .a = cap, .pb = vr(0, 1.4, 0), .b = cap2, .rb = zrot }, // capsule end vs crossing capsule
    };
    const globals = [_]Quatr{ Quatr.identity, Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7) };
    for (combos) |c| {
        for (globals) |g| {
            const m = collide(c.a, g.rotateVec3(vr(0, 0, 0)), g, c.b, g.rotateVec3(c.pb), g.mul(c.rb)) orelse continue;
            try testing.expect(validClassPairs(m));
            for (0..m.count) |i| {
                for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
                if (m.count > 1) {
                    const fid = m.points[i].feature_id;
                    const is_fallback = ((fid >> 16) & 0xc000 == 0x0000) and (fid & 0xc000 == 0x8000);
                    try testing.expect(!is_fallback);
                }
            }
        }
    }
}

test "single-contact fallback id never aliases a clip id" {
    // Codex FIX-11 threshold repro (the two Codex angles straddle `face_face_min`
    // at f32; the threshold is precision-dependent — 0.999 f32 / 0.9999 f64 — so
    // scan a small tilt range around them to find, at THIS build's precision, both
    // a clipped (multi-point) and a fallback (single-contact) box/box at the same
    // base pose). The fallback's feature_id must equal NONE of the clip ids — its
    // (class_a ref, class_c inc) class pair is disjoint from every clip-id class
    // pair (kept vertex (a,a), edge (edge,edge), corner (c,c)).
    const box = boxShape(1, 1, 1);
    const p = vr(0, 0.8, -1.8);
    var m_clip: ?ContactManifold = null;
    var m_fb: ?ContactManifold = null;
    // Tilt grows from 0 (identity ⇒ a clean face-face clip at any precision)
    // through the face-face↔fallback threshold into the edge/vertex regime.
    var a: Real = 0;
    while (a < 0.4) : (a += 0.0005) {
        const rot = Quatr.fromAxisAngle(Vec3r.unit_y, a).mul(Quatr.fromAxisAngle(Vec3r.unit_x, a));
        const m = collide(box, vr(0, 0, 0), Quatr.identity, box, p, rot) orelse continue;
        if (m.count >= 2 and m_clip == null) m_clip = m;
        if (m.count == 1 and m_fb == null) m_fb = m;
    }
    const mc = m_clip orelse return error.NoClippedManifold;
    const mf = m_fb orelse return error.NoFallbackManifold;
    const fb_id = mf.points[0].feature_id;
    // The fallback id carries the disjoint (class_a, class_c) class pair …
    try testing.expectEqual(@as(u32, 0x0000), (fb_id >> 16) & 0xc000);
    try testing.expectEqual(@as(u32, 0x8000), fb_id & 0xc000);
    // … and equals none of the clip ids.
    for (0..mc.count) |i| try testing.expect(fb_id != mc.points[i].feature_id);
}

test "reference corner feature id encodes the incident face" {
    // Codex FIX-10: a reference corner's incident half must carry which incident
    // face it lies on, not a constant — else two corners at the SAME reference
    // vertex on DIFFERENT incident faces (a supporting-face flip inter-frame)
    // share a feature_id and warm-starting mis-matches them.
    const box = boxShape(1, 1, 1);
    // Same staggered overlap; B upright vs B rolled 90° about X ⇒ the SAME
    // reference corner (a vertex of A's +Y face) but a DIFFERENT incident face.
    const m1 = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0.6, 1.5, 0.4), Quatr.identity).?;
    const roll = Quatr.fromAxisAngle(Vec3r.unit_x, std.math.pi / 2.0);
    const m2 = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0.6, 1.5, 0.4), roll).?;
    const c1 = refCornerFid(m1) orelse return error.NoReferenceCorner;
    const c2 = refCornerFid(m2) orelse return error.NoReferenceCorner;
    // Same reference vertex (high half) …
    try testing.expectEqual(c1 >> 16, c2 >> 16);
    // … but a different incident face (low half) ⇒ the face is encoded.
    try testing.expect((c1 & 0xffff) != (c2 & 0xffff));
    // The low half is a corner-face class (`class_c`) carrying a real face id 0..5.
    try testing.expectEqual(@as(u32, 0x8000), c1 & 0xc000);
    try testing.expect((c1 & 0x3fff) <= 5 and (c2 & 0x3fff) <= 5);
}

test "staggered box overlap yields a reference-corner contact with a unique id" {
    // Coverage of the reference-corner path (a clip point on TWO reference side
    // planes — an intersection whose endpoint is already an intersection, so it
    // exercises `incidentEdgeId`'s provenance-inheritance branch). Axis-aligned
    // unit boxes stacked in Y with a partial lateral offset ⇒ the overlap
    // rectangle's four corners are: one incident vertex, two edge×plane
    // intersections, and one REFERENCE corner (a corner of A's top face).
    const box = boxShape(1, 1, 1);
    const m = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0.6, 1.5, 0.4), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m.count);
    // All four feature_ids pairwise distinct (the reference corner must not alias
    // an edge×plane contact).
    for (0..m.count) |i| {
        for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
    }
    // Frame-stable under a tiny lateral shift (same physical corners → same ids).
    const s0 = fidSet(m);
    const m2 = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0.6001, 1.5, 0.3999), Quatr.identity).?;
    try testing.expectEqual(m.count, m2.count);
    try testing.expect(fidSetEq(s0, fidSet(m2), m.count));
    const m3 = collide(box, vr(0, 0, 0), Quatr.identity, box, vr(0.5999, 1.5, 0.4001), Quatr.identity).?;
    try testing.expectEqual(m.count, m3.count);
    try testing.expect(fidSetEq(s0, fidSet(m3), m.count));
}

test "edge-edge penetration is measured along the contact axis" {
    // Fix-1: for an oblique (edge/vertex) contact the EPA normal `n_a` is not a
    // box-face normal, so measuring depth along the reference face normal `rn`
    // diverges. The manifold depth must match the EPA depth along `n_a`.
    const box = boxShape(1, 1, 1);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 4.0);
    const pa = vr(0, 0, 0);
    const pb = vr(1.35, 1.35, 0); // corner overlap ⇒ oblique closest features
    // Reference EPA result.
    const g = narrowphase.gjk(Real, box, pa, Quatr.identity, box, pb, yaw);
    try testing.expectEqual(narrowphase.GjkResult(Real).Status.deep, g.status);
    const relpose = narrowphase.RelativePose(Real).init(pa, Quatr.identity, pb, yaw);
    const e = narrowphase.epa(Real, box, pa, Quatr.identity, relpose, box, g);
    // Confirm the contact axis is genuinely oblique (not a face normal) so this
    // exercises the edge path, not the face-face quad path.
    const na = e.normal.toArray();
    const max_comp = @max(@abs(na[0]), @max(@abs(na[1]), @abs(na[2])));
    try testing.expect(max_comp < 0.999);

    const m = collide(box, pa, Quatr.identity, box, pb, yaw).?;
    // Normal agrees with EPA (no canonical swap here: A's position sorts first).
    try testing.expect(m.normal.approxEql(e.normal, tol));
    // Depth along the contact axis matches EPA (r_sum = 0), not the ~rn-projected
    // value the old code produced.
    var max_pen: Real = 0;
    for (0..m.count) |i| max_pen = @max(max_pen, m.points[i].penetration);
    try testing.expectApproxEqAbs(e.depth, max_pen, tol);
}

test "manifold feature ids are frame-stable" {
    // Fix-2: feature_id must identify the physical feature, surviving a small pose
    // change (a clip-buffer index would reorder). A smaller incident box seated on
    // a larger reference face (so its four corners stay INSIDE the reference face
    // under a tiny lateral shift, i.e. the incident vertices remain the kept
    // features) translated ±0.0001 ⇒ the same set of feature_ids (same corners).
    const big = boxShape(1, 1, 1);
    const small = boxShape(0.5, 1, 0.5);
    const m1 = collide(big, vr(0, 0, 0), Quatr.identity, small, vr(0, 1.5, 0), Quatr.identity).?;
    const m2 = collide(big, vr(0, 0, 0), Quatr.identity, small, vr(0.0001, 1.5, -0.0001), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m1.count);
    try testing.expectEqual(m1.count, m2.count);
    // Every m1 feature_id appears in m2 (same physical corners → same ids).
    for (0..m1.count) |i| {
        var found = false;
        for (0..m2.count) |j| {
            if (m1.points[i].feature_id == m2.points[j].feature_id) found = true;
        }
        try testing.expect(found);
    }
    // The four ids are distinct (four distinct corners).
    for (0..m1.count) |i| {
        for (i + 1..m1.count) |j| try testing.expect(m1.points[i].feature_id != m1.points[j].feature_id);
    }
}

test "manifold reduction stays precise far from the origin" {
    // Fix-4: keep the reduction in A's frame. Two coincident tiny boxes at a large
    // world coordinate: the four A-frame contact corners (±0.001) are sub-ULP in
    // f32 world space (they round together → a world-frame dedup collapses to 1),
    // but are distinct in A's frame ⇒ a 4-point face manifold survives.
    const tiny = boxShape(0.001, 0.001, 0.001);
    const far = vr(100000, 100000, 100000);
    const m = collide(tiny, far, Quatr.identity, tiny, far, Quatr.identity).?;
    try testing.expectEqual(@as(u8, 4), m.count); // A-frame reduction keeps 4 (world-frame would collapse to 1)
    // The four ids are distinct (distinct A-frame corners); world positions round
    // together at f32 (that is exactly why the reduction must stay in A's frame).
    for (0..m.count) |i| {
        for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
        try testing.expectApproxEqAbs(@as(Real, 0.002), m.points[i].penetration, 1.0e-4); // full overlap 2·he
    }
}

test "manifold is order-independent" {
    const g = Quatr.fromAxisAngle(vr(2, -1, 3).normalize(), 0.8);
    const Combo = struct { sa: SupportShape, pa: Vec3r, sb: SupportShape, pb: Vec3r };
    const combos = [_]Combo{
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = boxShape(1, 1, 1), .pb = vr(0, 1.5, 0) }, // face-face
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .sb = sphereShape(0.5), .pb = vr(0, 0, 0.4) }, // sphere/box
        .{ .sa = sphereShape(1), .pa = vr(0, 0, 0), .sb = sphereShape(1), .pb = vr(1.2, 0, 0) }, // sphere/sphere
        .{ .sa = capsuleShape(1, 0.5), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.5), .pb = vr(0.8, 0, 0) }, // capsule/capsule
        .{ .sa = capsuleShape(1, 0.3), .pa = vr(0, 0, 0), .sb = capsuleShape(1, 0.3), .pb = vr(0, 0, 0) }, // degenerate crossing (F5)
        // Same position, equal |half_extents| but distinct extents — exercises
        // the canonical-order total-order tie-break on the box core parameters
        // (a `|he|`-only key would collide here and break order-independence).
        .{ .sa = boxShape(1, 2, 3), .pa = vr(0, 0, 0), .sb = boxShape(3, 2, 1), .pb = vr(0, 0, 0) },
    };
    const rot_z90 = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);
    for (combos, 0..) |c, ci| {
        // The crossing-capsule combo needs B rotated to actually cross A.
        const rb = if (ci == 4) rot_z90 else Quatr.identity;
        for ([_]Quatr{ Quatr.identity, g }) |ra| {
            const ab = collide(c.sa, c.pa, ra, c.sb, c.pb, ra.mul(rb)).?;
            const ba = collide(c.sb, c.pb, ra.mul(rb), c.sa, c.pa, ra).?;
            try testing.expectEqual(ab.count, ba.count);
            try testing.expect(ab.normal.approxEql(ba.normal.neg(), tol));
            // Same point set (order may differ) and same per-point penetration.
            for (0..ab.count) |i| {
                var matched = false;
                for (0..ba.count) |j| {
                    if (ab.points[i].position.approxEql(ba.points[j].position, tol) and
                        @abs(ab.points[i].penetration - ba.points[j].penetration) <= tol) matched = true;
                }
                try testing.expect(matched);
            }
        }
    }
}

test "shallow and deep manifolds are continuous" {
    // Sweep two unit-radius spheres from a shallow gap toward coincidence. The
    // per-point penetration r_sum − dist is continuous and monotone, the normal
    // stays +X (no flip) until coincidence.
    const rs = sphereShape(1);
    const ds = [_]Real{ 1.5, 1.0, 0.5, 0.1, 0.01 };
    var prev: Real = -1;
    for (ds) |d| {
        const m = collide(rs, vr(0, 0, 0), Quatr.identity, rs, vr(d, 0, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), m.count);
        try testing.expect(m.normal.approxEql(vr(1, 0, 0), tol));
        const pen = m.points[0].penetration;
        try testing.expectApproxEqAbs(@as(Real, 2.0) - d, pen, tol); // r_sum − dist
        try testing.expect(pen > prev); // monotone as d shrinks
        prev = pen;
    }
    // Coincident centres (deep, depth 0) ⇒ penetration → r_sum, continuous.
    const mc = collide(rs, vr(0, 0, 0), Quatr.identity, rs, vr(0, 0, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 1), mc.count);
    try testing.expectApproxEqAbs(@as(Real, 2.0), mc.points[0].penetration, tol);
    try testing.expect(finite3(mc.normal));
    try testing.expectApproxEqAbs(@as(Real, 1), mc.normal.length(), tol);

    // Separated ⇒ null.
    try testing.expect(collide(rs, vr(0, 0, 0), Quatr.identity, rs, vr(2.5, 0, 0), Quatr.identity) == null);

    // A rounded-box shallow overlap threads the box-core shallow path (radius-0
    // boxes cannot be shallow) and still produces a valid manifold.
    const rb = roundedBoxShape(0.5, 0.5, 0.5, 1.0);
    const m = collide(rb, vr(0, 0, 0), Quatr.identity, rb, vr(0, 2.5, 0), Quatr.identity).?;
    try testing.expect(m.count >= 1 and m.count <= 4);
    try testing.expect(m.normal.approxEql(vr(0, 1, 0), tol));
    for (0..m.count) |i| try testing.expectApproxEqAbs(@as(Real, 0.5), m.points[i].penetration, tol); // r_sum(2) − dist(1.5)
}

// --- E4: broadphase → collidePair integration ---

/// Add a `.dynamic` box body at (x,y,z). Descriptor positions are the f32 api Vec3.
fn addBoxBodyAt(gpa: std.mem.Allocator, bm: *BodyManager, store: *const ShapeStore, shape: api.ShapeId, entity_index: u32, x: f32, y: f32, z: f32) !BodyId {
    var d = api.BodyDescriptor{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    };
    d.position = ApiVec3.fromArray(.{ x, y, z });
    return bm.addBody(gpa, store, d);
}

/// Whether `p` is the unordered pair `{x, y}` (candidate pairs are canonical).
fn isPair(p: Broadphase.Pair, x: BodyId, y: BodyId) bool {
    return p.a == @min(x, y) and p.b == @max(x, y);
}

/// Add a `.dynamic` box body at (x,y,z) with rotation `rot`.
fn addBoxBodyAtRot(gpa: std.mem.Allocator, bm: *BodyManager, store: *const ShapeStore, shape: api.ShapeId, entity_index: u32, x: f32, y: f32, z: f32, rot: math.Quatf) !BodyId {
    var d = api.BodyDescriptor{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    };
    d.position = ApiVec3.fromArray(.{ x, y, z });
    d.rotation = rot;
    return bm.addBody(gpa, store, d);
}

test "collidePair feature ids are stable across a pose-order boundary" {
    // Codex P1b: `collide` re-canonicalizes by pose, so the feature_id
    // reference/incident ownership flips when a coordinate crosses the
    // lexicographic order boundary (x = 0 here). `collidePair` drives a FIXED
    // body-id order, so a tiny shift crossing that boundary leaves the feature_ids
    // unchanged (same physical contacts).
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(1) } });
    const yaw = math.Quatf.fromAxisAngle(math.Vec3.unit_y, std.math.pi / 4.0);

    // A at the origin (identity); two B's yawed, straddling x = 0 by ±1e-4.
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);
    const id_neg = try addBoxBodyAtRot(gpa, &bm, &store, box, 1, -0.0001, 1.5, 0, yaw);
    const id_pos = try addBoxBodyAtRot(gpa, &bm, &store, box, 2, 0.0001, 1.5, 0, yaw);

    const m_neg = bm.collidePair(&store, id_a, id_neg).?;
    const m_pos = bm.collidePair(&store, id_a, id_pos).?;
    try testing.expectEqual(m_neg.count, m_pos.count);
    // Every feature_id from one appears in the other (body-id order is stable).
    for (0..m_neg.count) |i| {
        var found = false;
        for (0..m_pos.count) |j| {
            if (m_neg.points[i].feature_id == m_pos.points[j].feature_id) found = true;
        }
        try testing.expect(found);
    }
}

test "broadphase pairs to manifolds via collidePair" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var bp = Broadphase.init(.{});
    defer bp.deinit(gpa);

    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(0.5) } });

    // A–B: tight AABBs 0.15 apart (disjoint) but fat AABBs (margin 0.1) overlap ⇒
    // a broadphase fat-AABB false positive the narrowphase must reject (null).
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);
    const id_b = try addBoxBodyAt(gpa, &bm, &store, box, 1, 1.15, 0, 0);
    // C–D: boxes genuinely overlap (0.7 along X) ⇒ a real deep contact manifold.
    const id_c = try addBoxBodyAt(gpa, &bm, &store, box, 2, 10, 0, 0);
    const id_d = try addBoxBodyAt(gpa, &bm, &store, box, 3, 10.3, 0, 0);

    const ids = [_]BodyId{ id_a, id_b, id_c, id_d };
    for (ids) |id| _ = try bp.insert(gpa, .dynamic, bm.bodyAabb(&store, id).?, id);

    var pairs: std.ArrayListUnmanaged(Broadphase.Pair) = .empty;
    defer pairs.deinit(gpa);
    try bp.computePairs(gpa, &pairs);

    var found_false_positive = false;
    var found_overlap = false;
    for (pairs.items) |p| {
        const m = bm.collidePair(&store, p.a, p.b); // all four bodies still live
        if (isPair(p, id_a, id_b)) {
            found_false_positive = true;
            try testing.expect(m == null); // separated ⇒ no manifold
        } else if (isPair(p, id_c, id_d)) {
            found_overlap = true;
            const man = m.?;
            try testing.expect(man.count >= 1 and man.count <= 4);
            try testing.expectApproxEqAbs(@as(Real, 0.7), man.points[0].penetration, tol); // overlap along X
            try testing.expect(finite3(man.normal));
        }
    }
    // The broadphase surfaced the fat-AABB false positive (rejected as null) and
    // the genuine overlap (a valid manifold).
    try testing.expect(found_false_positive);
    try testing.expect(found_overlap);

    // Stale-handle pair ⇒ null.
    bm.removeBody(id_d);
    try testing.expect(bm.collidePair(&store, id_c, id_d) == null);
}

test "pose sweep: feature ids are distinct and frame-stable" {
    // The verification a single-point test cannot give (Codex FIX-9): a grid of
    // deep box/box contacts — yaw × a light second-axis tilt × lateral offsets ×
    // two Y overlaps, plus the two Codex repros — each checked for (a) pairwise-
    // distinct feature_ids and (b) frame-stability of the feature_id SET under a
    // ±1e-4 offset via `collidePair`'s body-id order.
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(1) } });
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);

    const yaws = [_]f32{ 0, 0.05, 0.125, 0.3, 0.6, 0.9 };
    const tilts = [_]f32{ 0, 0.07 };
    const offsets = [_][2]f32{ .{ -1, -1.9 }, .{ -0.9, -0.9 }, .{ -0.4, 0.3 }, .{ 0.5, -0.6 }, .{ 0.7, 0.4 } };
    const ys = [_]f32{ 1.5, 1.9 }; // deeper / shallower overlaps (both deep for r=0 boxes)

    var idx: u32 = 1;
    for (yaws) |yw| {
        for (tilts) |tl| {
            for (offsets) |off| {
                for (ys) |y| {
                    const rot = math.Quatf.fromAxisAngle(math.Vec3.unit_y, yw)
                        .mul(math.Quatf.fromAxisAngle(math.Vec3.unit_x, tl));
                    const id_b = try addBoxBodyAtRot(gpa, &bm, &store, box, idx, off[0], y, off[1], rot);
                    const id_s = try addBoxBodyAtRot(gpa, &bm, &store, box, idx + 1, off[0] + 0.0001, y, off[1] - 0.0001, rot);
                    idx += 2;
                    const m = bm.collidePair(&store, id_a, id_b) orelse continue;
                    // (a) pairwise-distinct feature ids.
                    for (0..m.count) |i| {
                        for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
                    }
                    // (a2, FIX-10) any reference corner carries an incident FACE in
                    // its low half (class_c + a real face id 0..5), not a constant.
                    // (a3, FIX-11) a multi-point (clipped) manifold never carries the
                    // single-contact fallback class pair (class_a ref, class_c inc),
                    // so a fallback id can never alias a clip id across the
                    // face-face↔fallback threshold for this body pair.
                    for (0..m.count) |i| {
                        const fid = m.points[i].feature_id;
                        if ((fid >> 16) & 0xc000 == 0x8000) {
                            try testing.expectEqual(@as(u32, 0x8000), fid & 0xc000);
                            try testing.expect((fid & 0x3fff) <= 5);
                        }
                        if (m.count > 1) {
                            const is_fallback_pair = ((fid >> 16) & 0xc000 == 0x0000) and (fid & 0xc000 == 0x8000);
                            try testing.expect(!is_fallback_pair);
                        }
                    }
                    // (b) frame-stable id SET under the tiny shift — asserted only
                    // when the shift keeps the topology, i.e. same count AND a
                    // stable contact normal. A tied min-penetration axis (equal
                    // overlaps on two axes) legitimately flips the normal (and thus
                    // the whole contact) under a 1e-4 nudge — that is a real
                    // geometric transition, not a feature_id instability.
                    if (bm.collidePair(&store, id_a, id_s)) |ms| {
                        if (ms.count == m.count and m.normal.approxEql(ms.normal, tol)) {
                            try testing.expect(fidSetEq(fidSet(m), fidSet(ms), m.count));
                        }
                    }
                }
            }
        }
    }

    // Explicit Codex repros (yaw about Y), asserted distinct.
    inline for (.{ .{ -1.0, 1.9, -1.9, 0.125 }, .{ -0.9, 1.9, -0.9, 0.05 } }) |c| {
        const rot = math.Quatf.fromAxisAngle(math.Vec3.unit_y, c[3]);
        const id_r = try addBoxBodyAtRot(gpa, &bm, &store, box, idx, c[0], c[1], c[2], rot);
        idx += 1;
        const m = bm.collidePair(&store, id_a, id_r).?;
        for (0..m.count) |i| {
            for (i + 1..m.count) |j| try testing.expect(m.points[i].feature_id != m.points[j].feature_id);
        }
    }
}

test "collidePair imposes a body-id order on identical geometry" {
    // Fix-3: two bodies with bit-identical shape AND pose overlap degenerately —
    // `collide`'s pose key cannot order them, so its normal is the same in both
    // call orders. `collidePair` breaks the tie by body id (min first) and negates
    // for the swapped caller, so the pair stays order-independent for real bodies.
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(0.5) } });
    const id_a = try addBoxBodyAt(gpa, &bm, &store, box, 0, 0, 0, 0);
    const id_b = try addBoxBodyAt(gpa, &bm, &store, box, 1, 0, 0, 0); // same pose as A

    const ab = bm.collidePair(&store, id_a, id_b).?;
    const ba = bm.collidePair(&store, id_b, id_a).?;
    try testing.expect(ab.normal.approxEql(ba.normal.neg(), tol)); // negated by body-id order
    try testing.expectEqual(ab.count, ba.count);
    try testing.expect(finite3(ab.normal));
}
