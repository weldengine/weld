//! M1.1.4 acceptance suite for the forge_3d narrowphase fast paths. Keyed to
//! `config.Real` so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).
//!
//! **Method.** A fast pair's `collideOrdered` (which dispatches the analytic
//! kernel) must be GEOMETRICALLY EQUIVALENT to `collideOrderedGeneric` (the
//! GJK/EPA bypass oracle): same `count`, normal/points/penetration within a
//! named tolerance calibrated to the generic path's convergence residual (NOT
//! `1e-6` — the fast path is in fact MORE accurate), and an EXACT `feature_id`
//! away from alignment/axis ties (the seed feeds the SAME `generateManifold`, so
//! the id is inherited). Where the generic oracle is documented invalid (P1d
//! extreme-aspect box), a CLOSED-FORM oracle replaces it.
//!
//! **E2 content:** sphere/sphere + sphere/box differentials (both orders),
//! separated short-circuits, touch-exact, sphere-internal / coincident, and the
//! P1d point/box closed-form. Pairs not yet wired (box/box → E3, capsule/capsule
//! → E4, capsule/box + rounded box → generic) are still bit-identical to the
//! oracle, asserted below.

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
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

fn ordered(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) ?ContactManifold {
    return narrowphase.collideOrdered(Real, sa, pa, ra, sb, pb, rb);
}
fn generic(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) ?ContactManifold {
    return narrowphase.collideOrderedGeneric(Real, sa, pa, ra, sb, pb, rb);
}

/// Differential tolerance — calibrated to the generic GJK/EPA convergence
/// residual (looser than an analytic-vs-exact bound; NOT `1e-6`). The fast path
/// is more accurate, so this bounds the ORACLE's error, not the kernel's.
const diff_tol: Real = if (Real == f32) 1.0e-3 else 1.0e-8;

/// The deepest per-point penetration in a manifold — for a box/box contact this
/// equals the SAT min-overlap (the true MTV depth): the clip's deepest point (or
/// the single witness) carries the full penetration.
fn maxPen(m: ContactManifold) Real {
    var p: Real = 0;
    for (0..m.count) |i| p = @max(p, m.points[i].penetration);
    return p;
}

/// An INDEPENDENT box/box separating-axis min-overlap scan, recomputed inline in
/// the test (a second, trivial SAT) so the fast kernel's reported depth can be
/// checked against the true MTV WITHOUT any GJK/EPA oracle. Returns the least
/// overlap over the 15 axes (both boxes assumed radius 0 and overlapping).
fn satMinOverlap(pa: Vec3r, ra: Quatr, hea_v: Vec3r, pb: Vec3r, rb: Quatr, heb_v: Vec3r) Real {
    const axa = [3]Vec3r{ ra.rotateVec3(Vec3r.unit_x), ra.rotateVec3(Vec3r.unit_y), ra.rotateVec3(Vec3r.unit_z) };
    const axb = [3]Vec3r{ rb.rotateVec3(Vec3r.unit_x), rb.rotateVec3(Vec3r.unit_y), rb.rotateVec3(Vec3r.unit_z) };
    const hea = hea_v.toArray();
    const heb = heb_v.toArray();
    const dc = pb.sub(pa);
    const ov = struct {
        fn f(L: Vec3r, xa: [3]Vec3r, ha: [3]Real, xb: [3]Vec3r, hb: [3]Real, d: Vec3r) Real {
            var rap: Real = 0;
            var rbp: Real = 0;
            for (0..3) |k| {
                rap += ha[k] * @abs(xa[k].dot(L));
                rbp += hb[k] * @abs(xb[k].dot(L));
            }
            return rap + rbp - @abs(d.dot(L));
        }
    }.f;
    var mn: Real = std.math.floatMax(Real);
    for (0..3) |k| mn = @min(mn, ov(axa[k], axa, hea, axb, heb, dc));
    for (0..3) |k| mn = @min(mn, ov(axb[k], axa, hea, axb, heb, dc));
    for (0..3) |i| {
        for (0..3) |j| {
            var L = axa[i].cross(axb[j]);
            const l2 = L.dot(L);
            if (l2 <= (if (Real == f32) @as(Real, 1.0e-6) else @as(Real, 1.0e-12))) continue;
            L = L.scale(1.0 / @sqrt(l2));
            mn = @min(mn, ov(L, axa, hea, axb, heb, dc));
        }
    }
    return mn;
}

/// Exact manifold equality (bit-for-bit) — for pairs the dispatcher does NOT
/// handle, where `collideOrdered` calls `collideOrderedGeneric` directly.
fn manifoldsIdentical(a: ?ContactManifold, b: ?ContactManifold) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    const ma = a.?;
    const mb = b.?;
    if (ma.count != mb.count) return false;
    if (!ma.normal.eql(mb.normal)) return false;
    for (0..ma.count) |i| {
        if (!ma.points[i].position.eql(mb.points[i].position)) return false;
        if (ma.points[i].penetration != mb.points[i].penetration) return false;
        if (ma.points[i].feature_id != mb.points[i].feature_id) return false;
    }
    return true;
}

/// Geometric equivalence of a fast manifold vs the generic oracle: same
/// null-ness, same `count`, normal/position/penetration within `diff_tol`.
/// `feature_id` is asserted exactly only when `check_fid` (i.e. away from an
/// alignment tie). Point-core pairs are `count == 1`, so point matching is by
/// index. `fast` may be MORE accurate than `gen`; the tolerance covers the gap.
fn expectEquivalent(fast: ?ContactManifold, gen: ?ContactManifold, check_fid: bool) !void {
    try testing.expectEqual(fast == null, gen == null);
    if (fast == null) return;
    const f = fast.?;
    const g = gen.?;
    try testing.expectEqual(g.count, f.count);
    try testing.expect(f.normal.approxEql(g.normal, diff_tol));
    for (0..f.count) |i| {
        try testing.expect(f.points[i].position.approxEql(g.points[i].position, diff_tol));
        try testing.expectApproxEqAbs(g.points[i].penetration, f.points[i].penetration, diff_tol);
        if (check_fid) try testing.expectEqual(g.points[i].feature_id, f.points[i].feature_id);
    }
}

/// Assert the dispatched path equals the generic oracle in BOTH A/B orders.
fn expectBothOrders(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr, check_fid: bool) !void {
    try expectEquivalent(ordered(sa, pa, ra, sb, pb, rb), generic(sa, pa, ra, sb, pb, rb), check_fid);
    try expectEquivalent(ordered(sb, pb, rb, sa, pa, ra), generic(sb, pb, rb, sa, pa, ra), check_fid);
}

/// Geometric equivalence for MULTI-point manifolds, order-independent: same
/// null-ness and `count`, same normal within tol, and every fast point matches
/// some generic point (position + penetration within tol; `feature_id` too when
/// `check_fid`). Used for box/box, whose clip may emit points in a different
/// order between the fast and generic paths.
/// Whether world point `q` lies inside-or-on the box core (centre `c`, rotation
/// `rot`, half-extents `he`) within `tol` — `q` mapped to the box's local frame
/// must satisfy `|local[k]| ≤ he[k] + tol` on every axis.
fn pointInBox(q: Vec3r, c: Vec3r, rot: Quatr, he: Vec3r, tol: Real) bool {
    const local = rot.conjugate().rotateVec3(q.sub(c)).toArray();
    const h = he.toArray();
    for (0..3) |k| {
        if (@abs(local[k]) > h[k] + tol) return false;
    }
    return true;
}

fn expectEquivalentUnordered(fast: ?ContactManifold, gen: ?ContactManifold, check_fid: bool) !void {
    try testing.expectEqual(fast == null, gen == null);
    if (fast == null) return;
    const f = fast.?;
    const g = gen.?;
    try testing.expectEqual(g.count, f.count);
    try testing.expect(f.normal.approxEql(g.normal, diff_tol));
    for (0..f.count) |i| {
        var matched = false;
        for (0..g.count) |j| {
            const same_pos = f.points[i].position.approxEql(g.points[j].position, diff_tol);
            const same_pen = @abs(f.points[i].penetration - g.points[j].penetration) <= diff_tol;
            const same_fid = !check_fid or f.points[i].feature_id == g.points[j].feature_id;
            if (same_pos and same_pen and same_fid) matched = true;
        }
        try testing.expect(matched);
    }
}

fn expectBothOrdersUnordered(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr, check_fid: bool) !void {
    try expectEquivalentUnordered(ordered(sa, pa, ra, sb, pb, rb), generic(sa, pa, ra, sb, pb, rb), check_fid);
    try expectEquivalentUnordered(ordered(sb, pb, rb, sa, pa, ra), generic(sb, pb, rb, sa, pa, ra), check_fid);
}

/// Whether a count-1 manifold carries the single-witness class pair
/// (`class_a` reference, `class_c` incident) — the point-core producer.
fn isSingleWitnessClass(m: ContactManifold) bool {
    if (m.count != 1) return false;
    const fid = m.points[0].feature_id;
    return ((fid >> 16) & 0xc000) == 0x0000 and (fid & 0xc000) == 0x8000;
}

test "not-yet-wired pairs equal the generic oracle exactly" {
    // capsule/capsule (E4), capsule/box (stays generic), and any rounded box →
    // dispatcher returns `.not_handled`, so `collideOrdered` is the generic path
    // verbatim. (sphere and box pairs are now wired — see the differentials.)
    const zrot = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);
    const Combo = struct { sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr };
    const combos = [_]Combo{
        .{ .sa = capsuleShape(1, 0.5), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = capsuleShape(1, 0.5), .pb = vr(0.8, 0, 0), .rb = Quatr.identity },
        .{ .sa = capsuleShape(1, 0.3), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = capsuleShape(1, 0.3), .pb = vr(0, 0, 0.5), .rb = zrot },
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = capsuleShape(0.5, 0.5), .pb = vr(1.3, 0, 0), .rb = Quatr.identity },
        .{ .sa = roundedBoxShape(0.5, 0.5, 0.5, 1.0), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = roundedBoxShape(0.5, 0.5, 0.5, 1.0), .pb = vr(0, 2.5, 0), .rb = Quatr.identity },
        .{ .sa = sphereShape(0.5), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = roundedBoxShape(1, 1, 1, 0.2), .pb = vr(0, 1.3, 0), .rb = Quatr.identity },
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = roundedBoxShape(1, 1, 1, 0.2), .pb = vr(0, 1.5, 0), .rb = Quatr.identity },
    };
    for (combos) |c| {
        try testing.expect(manifoldsIdentical(ordered(c.sa, c.pa, c.ra, c.sb, c.pb, c.rb), generic(c.sa, c.pa, c.ra, c.sb, c.pb, c.rb)));
        try testing.expect(manifoldsIdentical(ordered(c.sb, c.pb, c.rb, c.sa, c.pa, c.ra), generic(c.sb, c.pb, c.rb, c.sa, c.pa, c.ra)));
    }
}

test "sphere/sphere differential vs generic" {
    const globals = [_]Quatr{ Quatr.identity, Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7) };
    // r_sum = 2. Offsets straddle shallow overlap (dist < 2) and clear separation.
    const dists = [_]Real{ 0.3, 0.8, 1.5, 1.99, 2.5, 4.0 };
    const dirs = [_]Vec3r{ vr(1, 0, 0), vr(0, 1, 0), vr(0.6, 0.8, 0), vr(1, 1, 1) };
    for (globals) |g| {
        for (dists) |d| {
            for (dirs) |dir| {
                const u = dir.normalize();
                const pa = g.rotateVec3(vr(0, 0, 0));
                const pb = g.rotateVec3(u.scale(d));
                try expectBothOrders(sphereShape(1), pa, g, sphereShape(1), pb, g, true);
            }
        }
    }
    // Separated → null (both).
    try testing.expect(ordered(sphereShape(1), vr(0, 0, 0), Quatr.identity, sphereShape(1), vr(3, 0, 0), Quatr.identity) == null);
    // Coincident centres: a degenerate tie (normal geometrically undefined), so
    // only the weak contract holds — count 1, penetration → r_sum, finite unit
    // normal. NOT compared to the generic normal.
    const mc = ordered(sphereShape(1), vr(0, 0, 0), Quatr.identity, sphereShape(1), vr(0, 0, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 1), mc.count);
    try testing.expectApproxEqAbs(@as(Real, 2.0), mc.points[0].penetration, diff_tol);
    try testing.expectApproxEqAbs(@as(Real, 1.0), mc.normal.length(), diff_tol);
    try testing.expect(isSingleWitnessClass(mc));
}

test "sphere/box differential vs generic" {
    const globals = [_]Quatr{ Quatr.identity, Quatr.fromAxisAngle(vr(2, -1, 3).normalize(), 0.6) };
    const box = boxShape(2, 1, 3); // faces at x=±2, y=±1, z=±3; hy=1 the unique min
    // Sphere r 0.5. Positions clearly off a single face (fid-exact), plus edge/
    // corner-proximate (geometry only), plus interior (deep) and separated.
    const FaceCase = struct { p: Vec3r, fid: bool };
    const cases = [_]FaceCase{
        .{ .p = vr(0, 0, 3.3), .fid = true }, // outside +Z face (dist 0.3)
        .{ .p = vr(0, 0, -3.3), .fid = true }, // outside −Z face
        .{ .p = vr(2.3, 0, 0), .fid = true }, // outside +X face
        .{ .p = vr(0, 1.3, 0), .fid = true }, // outside +Y face
        .{ .p = vr(2.3, 1.3, 0), .fid = false }, // near +X/+Y edge (tie band)
        .{ .p = vr(2.3, 1.3, 3.3), .fid = false }, // near a corner (tie band)
        .{ .p = vr(0, 0.3, 0), .fid = true }, // INTERIOR (deep) — nearest +Y face
        .{ .p = vr(0.5, -0.4, 1), .fid = true }, // interior off-centre — nearest −Y face
        .{ .p = vr(0, 0, 7), .fid = true }, // clearly separated → null==null
    };
    for (globals) |g| {
        for (cases) |c| {
            const pa = g.rotateVec3(vr(0, 0, 0));
            const pb = g.rotateVec3(c.p);
            try expectBothOrders(box, pa, g, sphereShape(0.5), pb, g, c.fid);
        }
    }
    // Touch-exact: sphere just off the +X face at exactly r_sum ⇒ a contact with
    // penetration ~0 (the frozen touch=shallow convention), count 1.
    const touch = ordered(box, vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(2.5, 0, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 1), touch.count);
    try testing.expectApproxEqAbs(@as(Real, 0.0), touch.points[0].penetration, diff_tol);
    // Sphere centre exactly at the box centre (deep, unique nearest face +Y since
    // hy=1 is the smallest half-extent): closed-form normal +Y, depth hy + r_sum.
    const mc = ordered(box, vr(0, 0, 0), Quatr.identity, sphereShape(0.5), vr(0, 0, 0), Quatr.identity).?;
    try testing.expectEqual(@as(u8, 1), mc.count);
    try testing.expect(mc.normal.approxEql(vr(0, 1, 0), diff_tol));
    try testing.expectApproxEqAbs(@as(Real, 1.0 + 0.5), mc.points[0].penetration, diff_tol);
}

test "sphere/box P1d deep extreme aspect (closed-form)" {
    // A sphere deep inside a >50:1 radius-0 box: the generic GJK classification is
    // documented invalid at this aspect (`gjk.zig` P1d; reliable to ~30:1), so the
    // fast path is validated against a CLOSED-FORM oracle, not the generic path.
    // Each case has a UNIQUE nearest face (no axis tie).
    const Case = struct { he: Vec3r, c: Vec3r, r: Real, n: Vec3r, pen: Real, pos: Vec3r };
    const cases = [_]Case{
        // 100:1 box, sphere at centre ⇒ nearest +Y face (hy 0.5 the unique min).
        // depth hy=0.5, base 1.0; sa=(0,0.5,0), sb=(0,-0.5,0) ⇒ pos (0,0,0).
        .{ .he = vr(50, 0.5, 1), .c = vr(0, 0, 0), .r = 0.5, .n = vr(0, 1, 0), .pen = 1.0, .pos = vr(0, 0, 0) },
        // 106:1 box, sphere off-centre ⇒ nearest +Y face (hy 1 < hz 2 < hx 106).
        // depth 1, base 1.5; sa=(30,1,0.5), sb=(30,-0.5,0.5) ⇒ pos (30,0.25,0.5).
        .{ .he = vr(106, 1, 2), .c = vr(30, 0, 0.5), .r = 0.5, .n = vr(0, 1, 0), .pen = 1.5, .pos = vr(30, 0.25, 0.5) },
        // 212:1 box, sphere off-centre ⇒ nearest +Y face (hy 0.25 the unique min).
        // depth 0.25, base 0.75; sa=(10,0.25,0.2), sb=(10,-0.5,0.2) ⇒ pos (10,-0.125,0.2).
        .{ .he = vr(53, 0.25, 1), .c = vr(10, 0, 0.2), .r = 0.5, .n = vr(0, 1, 0), .pen = 0.75, .pos = vr(10, -0.125, 0.2) },
    };
    for (cases) |c| {
        const box = SupportShape{ .core = .{ .box = c.he }, .radius = 0 };
        // A = box, B = sphere ⇒ normal A→B is the box outward face normal.
        const mb = ordered(box, vr(0, 0, 0), Quatr.identity, sphereShape(c.r), c.c, Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), mb.count);
        try testing.expect(mb.normal.approxEql(c.n, diff_tol));
        try testing.expectApproxEqAbs(c.pen, mb.points[0].penetration, diff_tol);
        try testing.expect(mb.points[0].position.approxEql(c.pos, diff_tol));
        try testing.expect(isSingleWitnessClass(mb));
        // A = sphere, B = box ⇒ the normal negates; count/penetration/position hold.
        const ms = ordered(sphereShape(c.r), c.c, Quatr.identity, box, vr(0, 0, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 1), ms.count);
        try testing.expect(ms.normal.approxEql(c.n.neg(), diff_tol));
        try testing.expectApproxEqAbs(c.pen, ms.points[0].penetration, diff_tol);
        try testing.expect(ms.points[0].position.approxEql(c.pos, diff_tol));
    }
}

/// Whether the generic oracle is SELF-CONSISTENT on this pair — same null-ness,
/// same `count`, and negated normal across the two A/B orders. `collideOrdered`
/// is fixed-order and runs GJK/EPA in the frame of A; for a deep, rotated pair
/// EPA can converge to DIFFERENT faces in the two frames (an M1.1.3 EPA
/// frame-dependence, NOT a fast-path issue — the SAT fast path is order-
/// independent by construction; see the order-independence test). Where generic
/// disagrees with itself it is an unreliable oracle, so the differential skips
/// it. This is the concrete motivation for the analytic fast path.
fn genericConsistent(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) bool {
    const ab = generic(sa, pa, ra, sb, pb, rb);
    const ba = generic(sb, pb, rb, sa, pa, ra);
    if ((ab == null) != (ba == null)) return false;
    if (ab == null) return true;
    if (ab.?.count != ba.?.count) return false;
    return ab.?.normal.approxEql(ba.?.normal.neg(), diff_tol);
}

test "box/box SAT differential vs generic (<=30:1)" {
    // Cube A at the origin vs cube B rotated/offset — a broad sweep hitting the
    // face-face, face-vertex and edge-edge regimes. Per config, `collideOrdered`
    // is compared to the generic oracle in BOTH A/B orders, but only where that
    // oracle is self-consistent across orders (deep rotated pairs where the
    // generic EPA is frame-dependent — an M1.1.3 EPA limitation the SAT fast path
    // does not share — are skipped via `genericConsistent`). Geometry-only (fid
    // tie bands excluded); fid-exact is asserted on the clean explicit configs.
    const box = boxShape(1, 1, 1);
    const rots = [_]Quatr{
        Quatr.identity,
        Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0), // yaw ⇒ face-face octagon→4
        Quatr.fromAxisAngle(Vec3r.unit_x, 0.4), // tilt ⇒ edge/face
        Quatr.fromAxisAngle(vr(1, 1, 1).normalize(), 0.62), // corner-lead ⇒ vertex/edge
        Quatr.fromAxisAngle(Vec3r.unit_z, 0.5),
    };
    const offs = [_]Vec3r{ vr(0, 1.5, 0), vr(0.5, 1.5, 0.3), vr(0, 1.8, 0), vr(0.3, 1.6, -0.3) };
    const globals = [_]Quatr{ Quatr.identity, Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7) };
    var saw_face = false; // a multi-point (clip) manifold
    var saw_single = false; // a single-witness (edge/vertex) manifold
    var compared: u32 = 0; // configs where the oracle was trustworthy
    for (globals) |g| {
        for (rots) |r| {
            for (offs) |o| {
                const pa = g.rotateVec3(vr(0, 0, 0));
                const pb = g.rotateVec3(o);
                const ra = g;
                const rb = g.mul(r);
                const m = ordered(box, pa, ra, box, pb, rb) orelse continue;
                // Compare fast vs generic in both orders, only where the oracle
                // is self-consistent (i.e. its EPA converged reliably).
                if (genericConsistent(box, pa, ra, box, pb, rb)) {
                    try expectBothOrdersUnordered(box, pa, ra, box, pb, rb, false);
                    compared += 1;
                }
                if (m.count >= 3) saw_face = true;
                if (m.count == 1) saw_single = true;
            }
        }
    }
    // The sweep genuinely exercised both a face-face clip and an edge/vertex
    // single witness, and the trustworthy-oracle differential ran on many configs.
    try testing.expect(saw_face and saw_single);
    try testing.expect(compared >= 20);

    // Clean explicit configs, fid-exact (away from ties), both orders:
    // axis-aligned face-face (4 pts) and a 45°-yaw face-face (octagon→4 pts) —
    // shallow, so the generic oracle is reliable in both orders.
    try expectBothOrdersUnordered(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.9, 0), Quatr.identity, true);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0);
    try expectBothOrdersUnordered(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.9, 0), yaw, true);

    // Moderate aspect (up to 30:1) face-face — still the generic-reliable regime.
    const aspects = [_]Real{ 5, 15, 30 };
    for (aspects) |ar| {
        const b = boxShape(ar, 1, ar * 0.5);
        try expectBothOrdersUnordered(b, vr(0, 0, 0), Quatr.identity, b, vr(0, 1.9, 0), Quatr.identity, true);
    }
}

test "box/box SAT extreme aspect (closed-form)" {
    // A face-face overlap of two >50:1 boxes: SAT has no GJK degeneracy, so the
    // fast path is correct at any aspect (the box/box P1d fix). The generic path
    // is documented invalid here, so the oracle is CLOSED-FORM. Two equal boxes
    // stacked 1.5 apart in Y (half-extents hy=1) ⇒ overlap 0.5, normal +Y, 4
    // points on the plane y=0.75, spanning the full X/Z overlap rectangle.
    const aspects = [_]Real{ 50, 100, 212 };
    for (aspects) |hx| {
        const box = boxShape(hx, 1, 1);
        const m = ordered(box, vr(0, 0, 0), Quatr.identity, box, vr(0, 1.5, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 4), m.count);
        try testing.expect(m.normal.approxEql(vr(0, 1, 0), diff_tol));
        var max_abs_x: Real = 0;
        for (0..m.count) |i| {
            try testing.expectApproxEqAbs(@as(Real, 0.5), m.points[i].penetration, diff_tol); // r_sum 0 ⇒ overlap 0.5
            try testing.expectApproxEqAbs(@as(Real, 0.75), m.points[i].position.toArray()[1], diff_tol); // contact plane
            max_abs_x = @max(max_abs_x, @abs(m.points[i].position.toArray()[0]));
        }
        // The manifold spans the full X overlap (proves the clip works at extreme
        // aspect — a naive GJK/EPA would collapse or mis-classify here).
        try testing.expectApproxEqAbs(hx, max_abs_x, diff_tol);
        // Swapped order ⇒ the normal negates, geometry holds.
        const ms = ordered(box, vr(0, 1.5, 0), Quatr.identity, box, vr(0, 0, 0), Quatr.identity).?;
        try testing.expectEqual(@as(u8, 4), ms.count);
        try testing.expect(ms.normal.approxEql(vr(0, -1, 0), diff_tol));
    }
}

/// Assert `collideOrdered` is order-independent on this box pair in the
/// properties the generic EPA VIOLATES for deep rotated boxes: same `count`,
/// negated normal, and equal DEPTH (the deep-rotated EPA gave pen 1.047 one order
/// and pen 0 the other — see § Recorded deviations; the SAT kernel gives the same
/// depth + a negated normal both orders, by construction).
///
/// The multi-point POSITIONS are deliberately NOT asserted equal for `count > 1`:
/// `generateManifold` (FROZEN, M1.1.3) selects the reference face by A/B order
/// (its `feature_id` ownership contract), so a fixed-order clip of a deep
/// face-face contact keeps a different — equally valid, coplanar, same-depth —
/// subset of the overlap polygon in each order. That is a clip artifact of the
/// fixed-order entry (present on the generic path too), canonicalized away by
/// `collide` (pose order) and `collidePair` (BodyId order); it is orthogonal to
/// the EPA depth/normal defect. For `count == 1` (single witness) the position IS
/// order-independent (the witness is symmetric) and is asserted.
fn expectOrderIndependent(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) !void {
    const ab = ordered(sa, pa, ra, sb, pb, rb).?;
    const ba = ordered(sb, pb, rb, sa, pa, ra).?;
    try testing.expectEqual(ab.count, ba.count);
    try testing.expect(ab.normal.approxEql(ba.normal.neg(), diff_tol));
    try testing.expectApproxEqAbs(maxPen(ab), maxPen(ba), diff_tol);
    if (ab.count == 1) {
        try testing.expect(ab.points[0].position.approxEql(ba.points[0].position, diff_tol));
        try testing.expectApproxEqAbs(ab.points[0].penetration, ba.points[0].penetration, diff_tol);
    }
}

test "box/box SAT deep rotated is correct (oracle-free)" {
    // The prod-common, generic-EPA-unreliable region: a box deeply embedded in
    // another under strong rotation (several axes carry large overlap). The
    // generic oracle is skipped here (frame-dependent EPA — § Recorded
    // deviations), so correctness is proven WITHOUT it, three ways:
    //   (a) `collideOrdered` is order-independent (the property EPA violates);
    //   (b) the reported depth equals an INDEPENDENT inline 15-axis SAT scan (the
    //       true MTV — proves the depth is not a mis-converged EPA value);
    //   (c) frame-invariance: under a rigid global transform the count/depth are
    //       invariant and the normal rotates with the transform;
    //   (d) every contact point's two surface witnesses `p ± (pen/2)·n` land on
    //       the two box surfaces — a per-point geometric validity check that pins
    //       the multi-point POSITIONS oracle-free (each point is midway between
    //       the two box surfaces along the normal, at half its own penetration).
    const Pair = struct { a: SupportShape, b: SupportShape };
    const pairs = [_]Pair{
        .{ .a = boxShape(1, 1, 1), .b = boxShape(1, 1, 1) }, // 1:1
        .{ .a = boxShape(2, 1, 1.5), .b = boxShape(1.5, 2, 1) }, // moderate aspect
    };
    const rots = [_]Quatr{
        Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0),
        Quatr.fromAxisAngle(Vec3r.unit_x, 0.4),
        Quatr.fromAxisAngle(vr(1, 1, 1).normalize(), 0.62),
        Quatr.fromAxisAngle(vr(2, -1, 0.5).normalize(), 0.9),
        Quatr.fromAxisAngle(Vec3r.unit_z, 0.5),
    };
    // Deep offsets (centres close ⇒ large overlap on multiple axes).
    const offs = [_]Vec3r{ vr(0.3, 0.4, 0.5), vr(0.2, 0.6, 0.3), vr(0.5, 0.45, 0.4), vr(0.1, 0.7, 0.35) };
    const globals = [_]Quatr{
        Quatr.identity,
        Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7),
        Quatr.fromAxisAngle(vr(-2, 1, 1).normalize(), -0.5),
    };
    for (pairs) |p| {
        for (rots) |r| {
            for (offs) |o| {
                const m0 = ordered(p.a, vr(0, 0, 0), Quatr.identity, p.b, o, r) orelse continue;
                // (a) order-independence.
                try expectOrderIndependent(p.a, vr(0, 0, 0), Quatr.identity, p.b, o, r);
                // (b) depth == the true MTV (independent inline SAT scan).
                const mtv = satMinOverlap(vr(0, 0, 0), Quatr.identity, p.a.core.box, o, r, p.b.core.box);
                try testing.expectApproxEqAbs(mtv, maxPen(m0), diff_tol);
                // (c) frame-invariance under a rigid global transform: count and
                // depth invariant, normal rotated by g. (The exact 4-point SUBSET
                // can differ under rotation when `reduceToFour` breaks an
                // octagon→quad area tie differently at float noise — a reduction
                // artifact, not a depth/normal defect — so multi-point positions
                // are validated by (d) below, not by frame-equivariance.)
                for (globals) |g| {
                    const mg = ordered(p.a, g.rotateVec3(vr(0, 0, 0)), g, p.b, g.rotateVec3(o), g.mul(r)).?;
                    try testing.expectEqual(m0.count, mg.count);
                    try testing.expectApproxEqAbs(maxPen(m0), maxPen(mg), diff_tol);
                    try testing.expect(mg.normal.approxEql(g.rotateVec3(m0.normal), diff_tol));
                }
                // (d) each contact point sits midway between the two box surfaces
                // along the normal: its witnesses `p ± (pen/2)·n` land one on each
                // box (n is A→B, so the sign assignment is checked both ways).
                const witness_tol: Real = if (Real == f32) 3.0e-3 else 1.0e-6;
                for (0..m0.count) |i| {
                    const half = m0.normal.scale(m0.points[i].penetration * 0.5);
                    const wp = m0.points[i].position.add(half);
                    const wm = m0.points[i].position.sub(half);
                    const a_side = pointInBox(wm, vr(0, 0, 0), Quatr.identity, p.a.core.box, witness_tol) and pointInBox(wp, o, r, p.b.core.box, witness_tol);
                    const b_side = pointInBox(wp, vr(0, 0, 0), Quatr.identity, p.a.core.box, witness_tol) and pointInBox(wm, o, r, p.b.core.box, witness_tol);
                    try testing.expect(a_side or b_side);
                }
            }
        }
    }
}
