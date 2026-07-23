//! M1.1.3-HF — generic EPA deep-path order-dependence: reproduction suite.
//!
//! This file pins the `collideOrderedGeneric` (GJK → EPA → generateManifold)
//! order-independence contract for deep, rotated convex pairs against
//! INDEPENDENT separating-axis oracles (no GJK/EPA in the oracle path). At the
//! E1 gate it is RED-first: the S1 (polytope corruption → wrong depth) and S3
//! (1-D Minkowski degenerate normal frame-dependence) pins fail, and the
//! order-equivalence sweep exposes the frame-dependence, BEFORE any epa.zig fix
//! lands (E2/E3). The assertions target the ORACLE, never a recon transcript
//! (engine-physics-forge.md §3 Order-independence; brief E1).
//!
//! Oracles:
//!  - box/box: the shared 15-axis SAT `fast_paths_test.satBoxBox` (depth + axis
//!    + tie-band count).
//!  - segment⊖box (capsule/box): the exact 6-axis zonotope SAT `satSegBox`
//!    below (3 box face axes + 3 box-axis×segment-axis crosses).

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const fast_paths_test = @import("fast_paths_test.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const GjkResult = narrowphase.GjkResult(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const RelativePose = narrowphase.RelativePose(Real);
const EpaDiagnostics = narrowphase.EpaDiagnostics;
const testing = std.testing;

const satBoxBox = fast_paths_test.satBoxBox;
const sat_tie_k = fast_paths_test.sat_tie_k;
const sat_dir_colinear = fast_paths_test.sat_dir_colinear;

// Depth tolerance at unit scale — the generic EPA depth carries the full
// convergence residual of the descent + polytope expansion (the class
// fast_paths_test.diff_tol bounds), looser than an analytic bound. The sweep
// scales it by the config scale (depths scale, so does the f32 residual).
const depth_tol: Real = if (Real == f32) 5.0e-3 else 1.0e-7;
// Normal tolerance — component-wise; a unit normal is scale-independent, so this
// is NOT scaled. ~0.3° in f32; the exact-negation S3 claim uses `.eql`, not this.
const normal_tol: Real = if (Real == f32) 5.0e-3 else 1.0e-6;

// RED-first gates (M1.1.3-HF). Each defect pin below is RED until its fix lands;
// it skips (`error.SkipZigTest`) so the pre-push `zig build test` stays green
// while the branch carries the reproduction suite for gate-by-gate review — no
// hook bypass. The observed RED values are journaled in the brief (E1). Flip to
// false per gate as the fix turns each green: s1 → E2 (epa.zig Fix A), s3 → E3
// (intrinsic degenerate normal), sweep → E4 (full order-equivalence).
const red_gate_s1 = false; // un-gated at E2: epa.zig Fix A lands (S1 green both orders)
const red_gate_s3 = false; // un-gated at E3: intrinsic point⊖segment normal (bit-negated)
const red_gate_rd4 = false; // un-gated at E4: RD-4 gjk.zig deep-band fix (C′) lands

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn boxShape(hx: Real, hy: Real, hz: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = 0 };
}

fn sphereShape(radius: Real) SupportShape {
    return .{ .core = .point, .radius = radius };
}

fn capsuleShape(half_height: Real, radius: Real) SupportShape {
    return .{ .core = .{ .segment = half_height }, .radius = radius };
}

/// The deepest per-point penetration of a manifold — the true MTV depth for a
/// deep contact (mirror of fast_paths_test.maxPen).
fn maxPen(m: ContactManifold) Real {
    var p: Real = 0;
    for (0..m.count) |i| p = @max(p, m.points[i].penetration);
    return p;
}

// ---------------------------------------------------------------------------
// segment⊖box zonotope SAT oracle (E1(a))
// ---------------------------------------------------------------------------

const SegBoxSatResult = struct {
    depth: Real,
    axis: Vec3r,
    tie_count: u32,
};

/// Exact segment⊖box separating-axis oracle (core MTV, radii excluded — matches
/// EPA core depth). The Minkowski difference of a segment core (capsule; a
/// half-length `half_height` segment on the shape's local Y) and a box core is a
/// 4-generator zonotope whose facet normals are the 3 box face axes plus the 3
/// `box_axis × segment_axis` crosses — 6 candidate axes. A cross that is
/// strictly zero (box axis ∥ segment axis) carries no information and is
/// skipped. Cores assumed overlapping.
fn satSegBox(seg_center: Vec3r, seg_rot: Quatr, half_height: Real, box_center: Vec3r, box_rot: Quatr, he_v: Vec3r) SegBoxSatResult {
    const s_axis = seg_rot.rotateVec3(Vec3r.unit_y);
    const bx = [3]Vec3r{
        box_rot.rotateVec3(Vec3r.unit_x),
        box_rot.rotateVec3(Vec3r.unit_y),
        box_rot.rotateVec3(Vec3r.unit_z),
    };
    const he = he_v.toArray();
    const dc = box_center.sub(seg_center);
    const ov = struct {
        fn f(L: Vec3r, s: Vec3r, hh: Real, b: [3]Vec3r, hb: [3]Real, d: Vec3r) Real {
            var rbp: Real = 0;
            for (0..3) |k| rbp += hb[k] * @abs(b[k].dot(L));
            const rsp = hh * @abs(s.dot(L));
            return rsp + rbp - @abs(d.dot(L));
        }
    }.f;

    var cand_axis: [6]Vec3r = undefined;
    var cand_ov: [6]Real = undefined;
    var n: usize = 0;
    for (0..3) |k| {
        cand_axis[n] = bx[k];
        cand_ov[n] = ov(bx[k], s_axis, half_height, bx, he, dc);
        n += 1;
    }
    for (0..3) |k| {
        const l_raw = bx[k].cross(s_axis);
        const l2 = l_raw.dot(l_raw);
        if (l2 <= 0) continue; // box axis k ∥ segment axis — degenerate cross, skipped
        const sq = @sqrt(l2);
        cand_axis[n] = l_raw.scale(1.0 / sq);
        cand_ov[n] = ov(l_raw, s_axis, half_height, bx, he, dc) / sq;
        n += 1;
    }

    var depth: Real = std.math.floatMax(Real);
    var axis: Vec3r = Vec3r.unit_x;
    for (0..n) |i| {
        if (cand_ov[i] < depth) {
            depth = cand_ov[i];
            axis = cand_axis[i];
        }
    }
    const coord_scale = dc.length() + half_height + he_v.length();
    const band = sat_tie_k * std.math.floatEps(Real) * coord_scale;
    // Count DISTINCT minimal-band directions (colinear slots merged, v/−v same); a
    // BILATERAL minimal direction (`|dc·axis| <= band`) counts twice — both signs
    // are equally-minimal MTV, so the generic normal may pick the same absolute
    // axis (not negated) across orders (Codex (a)).
    var seen: [6]Vec3r = undefined;
    var seen_count: usize = 0;
    var tie_count: u32 = 0;
    for (0..n) |i| {
        if (cand_ov[i] - depth > band) continue;
        var is_new = true;
        for (0..seen_count) |j| {
            if (@abs(cand_axis[i].dot(seen[j])) > sat_dir_colinear) {
                is_new = false;
                break;
            }
        }
        if (is_new) {
            seen[seen_count] = cand_axis[i];
            seen_count += 1;
            tie_count += if (@abs(dc.dot(cand_axis[i])) <= band) 2 else 1;
        }
    }
    return .{ .depth = depth, .axis = axis, .tie_count = tie_count };
}

test "segment-box zonotope sat oracle self-checks" {
    // Axis-aligned capsule (segment on +Y) whose lower endpoint dips into a unit
    // box's top face. Segment center (0,1.5,0), half_height 1 → segment y∈[0.5,2.5];
    // box [-1,1]^3. Overlap along +Y = 1 (he_y) + 1 (hh·|Y·Y|) − 1.5 (|dc·Y|) = 0.5,
    // the minimum; along ±X/±Z the segment (x=z=0) sits inside the box so overlap
    // is 1. The box-Y × segment-Y cross is exactly zero and MUST be skipped (else
    // a div-by-zero would poison the result) — a finite, correct 0.5 proves it.
    {
        const r = satSegBox(vr(0, 1.5, 0), Quatr.identity, 1, vr(0, 0, 0), Quatr.identity, vr(1, 1, 1));
        try testing.expectApproxEqAbs(@as(Real, 0.5), r.depth, 1.0e-6);
        try testing.expect(@abs(r.axis.dot(Vec3r.unit_y)) > 1 - 1.0e-6);
        try testing.expectEqual(@as(u32, 1), r.tie_count);
    }
    // The MTV is invariant under a rigid global transform: rotate + translate the
    // whole configuration and the depth is unchanged (the axis rotates with it).
    {
        const g = Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.83);
        const t = vr(-4, 7, 2.5);
        const seg_c = g.rotateVec3(vr(0, 1.5, 0)).add(t);
        const box_c = g.rotateVec3(vr(0, 0, 0)).add(t);
        const r = satSegBox(seg_c, g, 1, box_c, g, vr(1, 1, 1));
        try testing.expectApproxEqAbs(@as(Real, 0.5), r.depth, 1.0e-5);
    }
}

// ---------------------------------------------------------------------------
// S1 — polytope corruption → wrong depth (RED at E1, GREEN at E2)
// ---------------------------------------------------------------------------

/// Drive one deep box/box pin in one A/B order: assert the SAT oracle sees a
/// unique minimum, that GJK classifies `.deep`, and that BOTH the raw EPA depth
/// and the generic manifold's max penetration match the oracle MTV (r_sum = 0
/// for radius-0 boxes), with the manifold normal colinear with the oracle axis.
fn checkDeepBoxPin(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) !void {
    const o = satBoxBox(pa, ra, sa.core.box, pb, rb, sb.core.box);
    try testing.expectEqual(@as(u32, 1), o.tie_count); // unique minimum (oracle sanity)

    const g = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    try testing.expectEqual(GjkResult.Status.deep, g.status);

    const relpose = RelativePose.init(pa, ra, pb, rb);
    const e = narrowphase.epa(Real, sa, pa, ra, relpose, sb, rb, g, null);
    try testing.expectApproxEqAbs(o.depth, e.depth, depth_tol);

    const m_opt = narrowphase.collideOrderedGeneric(Real, sa, pa, ra, sb, pb, rb);
    try testing.expect(m_opt != null);
    const m = m_opt.?;
    try testing.expectApproxEqAbs(o.depth, maxPen(m), depth_tol);
    try testing.expect(@abs(m.normal.dot(o.axis)) > 1 - normal_tol);
}

/// Run the deep box pin ONLY where this build classifies the pair `.deep`. Used
/// for the frozen (0.1,0.1,0.1) pitch-X config (iii), which GJK classifies
/// `.deep` on x86-64/Linux but `.shallow` on this arm64/macOS build — a
/// cross-platform float divergence on the deep/shallow boundary (RD-3; GJK is out
/// of scope). Skipping the assertion when `.shallow` (rather than failing) keeps
/// coverage on platforms that reach EPA, without falsely asserting deep here.
fn checkDeepBoxPinIfDeep(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) !void {
    const g = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    if (g.status != GjkResult.Status.deep) return; // not deep on this platform
    try checkDeepBoxPin(sa, pa, ra, sb, pb, rb);
}

test "deep rotated box pair matches sat in both orders" {
    if (red_gate_s1) return error.SkipZigTest; // RED at E1 (EPA depth 0.0 vs oracle 1.9); un-gate at E2
    const box = boxShape(1, 1, 1);
    const z = Vec3r.unit_z;
    const x = Vec3r.unit_x;

    // (i) roll 0.5 about Z, offset (0.2, 0.4, 0.1): MTV 1.9 along ±Z (next 1.957).
    {
        const rb = Quatr.fromAxisAngle(z, 0.5);
        try checkDeepBoxPin(box, vr(0, 0, 0), Quatr.identity, box, vr(0.2, 0.4, 0.1), rb);
        try checkDeepBoxPin(box, vr(0.2, 0.4, 0.1), rb, box, vr(0, 0, 0), Quatr.identity);
    }
    // (ii) roll 0.5 about Z, offset (0.1, 0.1, 0.1): MTV 1.9 along ±Z.
    {
        const rb = Quatr.fromAxisAngle(z, 0.5);
        try checkDeepBoxPin(box, vr(0, 0, 0), Quatr.identity, box, vr(0.1, 0.1, 0.1), rb);
        try checkDeepBoxPin(box, vr(0.1, 0.1, 0.1), rb, box, vr(0, 0, 0), Quatr.identity);
    }
    // (iii) pitch 0.4 about X. The FROZEN offset (0.1,0.1,0.1) is `.deep` on
    // x86-64/Linux but `.shallow` on this arm64/macOS build (RD-3) — run
    // conditionally on status so it covers platforms that reach EPA without
    // falsely asserting deep here. The retargeted (0.2,0.4,0.1) is `.deep` on both
    // and is the unconditional third pin. checkDeepBoxPin asserts against the SAT
    // oracle (unique minimum), not a hard-coded axis.
    {
        const rb = Quatr.fromAxisAngle(x, 0.4);
        try checkDeepBoxPinIfDeep(box, vr(0, 0, 0), Quatr.identity, box, vr(0.1, 0.1, 0.1), rb);
        try checkDeepBoxPinIfDeep(box, vr(0.1, 0.1, 0.1), rb, box, vr(0, 0, 0), Quatr.identity);
        try checkDeepBoxPin(box, vr(0, 0, 0), Quatr.identity, box, vr(0.2, 0.4, 0.1), rb);
        try checkDeepBoxPin(box, vr(0.2, 0.4, 0.1), rb, box, vr(0, 0, 0), Quatr.identity);
    }
}

// ---------------------------------------------------------------------------
// S3 — 1-D Minkowski degenerate normal frame-dependence (RED at E1, GREEN at E3)
// ---------------------------------------------------------------------------

test "on-axis sphere-capsule normal is exactly negated across orders" {
    if (red_gate_s3) return error.SkipZigTest; // RED at E1 (normal not bit-negated across orders); un-gate at E3
    const sphere = sphereShape(0.7);
    const cap = capsuleShape(1.0, 0.5);
    const r_sum: Real = 1.2;
    // Sphere center exactly on the capsule axis: place both centers at the same
    // point (segment midpoint). point⊖segment is then 1-D — the degenerate EPA
    // path — with core distance 0 (penetration = r_sum).
    const center = vr(0.3, -0.2, 0.5);
    const rots = [_]Quatr{
        Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0),
        Quatr.fromAxisAngle(vr(1, 1, 0).normalize(), 0.7),
        Quatr.identity,
    };
    for (rots) |rc| {
        // Manifold-level: a single witness contact, penetration = r_sum, both orders.
        const ab = narrowphase.collideOrderedGeneric(Real, sphere, center, Quatr.identity, cap, center, rc);
        const ba = narrowphase.collideOrderedGeneric(Real, cap, center, rc, sphere, center, Quatr.identity);
        try testing.expect(ab != null and ba != null);
        try testing.expectEqual(@as(u8, 1), ab.?.count);
        try testing.expectEqual(@as(u8, 1), ba.?.count);
        try testing.expectApproxEqAbs(r_sum, maxPen(ab.?), depth_tol);
        try testing.expectApproxEqAbs(r_sum, maxPen(ba.?), depth_tol);

        // Manifold-level EXACT bit negation — the CONSUMER guarantee (M1.1.6
        // warm-start consumes manifolds, not EpaResults). On the count-1 point-core
        // path, generateManifold's A-frame rotation is used ONLY for supporting-face
        // selection; pointCoreContact returns `.normal = n_world` VERBATIM, so the
        // E3 EPA bit-negation propagates to the manifold unchanged (a pure copy,
        // platform-independent — no arithmetic on the normal between e.normal and
        // the manifold).
        try testing.expect(ab.?.normal.eql(ba.?.normal.neg()));

        // Complement — the same bit negation at its SOURCE, the raw epa() normal
        // (the E3 intrinsic point⊖segment derivation), documenting where it arises.
        const g_ab = narrowphase.gjk(Real, sphere, center, Quatr.identity, cap, center, rc);
        const g_ba = narrowphase.gjk(Real, cap, center, rc, sphere, center, Quatr.identity);
        try testing.expectEqual(GjkResult.Status.deep, g_ab.status);
        try testing.expectEqual(GjkResult.Status.deep, g_ba.status);
        const e_ab = narrowphase.epa(Real, sphere, center, Quatr.identity, RelativePose.init(center, Quatr.identity, center, rc), cap, rc, g_ab, null);
        const e_ba = narrowphase.epa(Real, cap, center, rc, RelativePose.init(center, rc, center, Quatr.identity), sphere, Quatr.identity, g_ba, null);
        try testing.expect(e_ab.normal.eql(e_ba.normal.neg()));
    }
}

// ---------------------------------------------------------------------------
// Order-equivalence sweep with SAT classification (E1(e); GREEN at E4)
// ---------------------------------------------------------------------------

test "deep-boundary GJK stall classifies deep, not near-zero shallow (RD-4)" {
    if (red_gate_rd4) return error.SkipZigTest; // un-gated when the gjk.zig stall fix lands
    // The frozen pitch-X offset is a GJK deep/shallow-boundary stall: GJK converges
    // to a non-enclosing terminal ~2.66·floatEps·scale from the origin on a
    // genuinely-deep overlap, and (the noise floor being tighter) mis-reports
    // `.shallow` with dist≈0 — a pen-0-vs-MTV error of the S1 class, produced by the
    // GJK stage instead of EPA. It flips with scalar/scale/order (RD-4). The generic
    // manifold's max penetration must match the SAT oracle at every scale, both
    // orders — never the ~0 of the mis-classified shallow.
    const rb = Quatr.fromAxisAngle(Vec3r.unit_x, 0.4);
    const off_unit = vr(0.1, 0.1, 0.1);
    const scales = [_]Real{ 0.01, 1, 100 };
    for (scales) |k| {
        const box = boxShape(k, k, k);
        const off = off_unit.scale(k);
        const dtol = depth_tol * k;
        const o0 = satBoxBox(vr(0, 0, 0), Quatr.identity, box.core.box, off, rb, box.core.box);
        const m0 = narrowphase.collideOrderedGeneric(Real, box, vr(0, 0, 0), Quatr.identity, box, off, rb);
        try testing.expect(m0 != null);
        try testing.expectApproxEqAbs(o0.depth, maxPen(m0.?), dtol);
        const o1 = satBoxBox(off, rb, box.core.box, vr(0, 0, 0), Quatr.identity, box.core.box);
        const m1 = narrowphase.collideOrderedGeneric(Real, box, off, rb, box, vr(0, 0, 0), Quatr.identity);
        try testing.expect(m1 != null);
        try testing.expectApproxEqAbs(o1.depth, maxPen(m1.?), dtol);
    }
}

test "separated radius-0 boxes stay separated (RD-4 band lower boundary)" {
    // Two unit boxes with a small but REAL core gap (~145·contact_margin at unit
    // scale) must classify separated — the RD-4 deep band (`dist <= m`) must not
    // swallow a genuine separation just above it. collideOrderedGeneric → null.
    const box = boxShape(1, 1, 1);
    const gap: Real = 1.0e-3;
    try testing.expect(narrowphase.collideOrderedGeneric(Real, box, vr(0, 0, 0), Quatr.identity, box, vr(2 + gap, 0, 0), Quatr.identity) == null);
}

const PairKind = enum { box_box, cap_box, sph_cap };

fn pairShapes(pk: PairKind, k: Real) [2]SupportShape {
    return switch (pk) {
        .box_box => .{ boxShape(k, k, k), boxShape(k, k, k) },
        .cap_box => .{ capsuleShape(k, 0.5 * k), boxShape(k, k, k) },
        .sph_cap => .{ sphereShape(0.7 * k), capsuleShape(k, 0.5 * k) },
    };
}

/// SAT tie-band minimal-axis count for the pair, by core kind. box/box uses the
/// 15-axis SAT; capsule/box (either order) uses the 6-axis segment⊖box zonotope
/// SAT; anything else (sphere/capsule etc.) has no MTV oracle → 0, so an
/// unclassified divergence there is a genuine defect, never tie-excused.
fn satTieCount(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) u32 {
    switch (sa.core) {
        .box => |hea| switch (sb.core) {
            .box => |heb| return satBoxBox(pa, ra, hea, pb, rb, heb).tie_count,
            .segment => |hh| return satSegBox(pb, rb, hh, pa, ra, hea).tie_count,
            .point => return 0,
        },
        .segment => |hh| switch (sb.core) {
            .box => |heb| return satSegBox(pa, ra, hh, pb, rb, heb).tie_count,
            else => return 0,
        },
        .point => return 0,
    }
}

/// The core order-equivalence check: the two A/B orders of `collideOrderedGeneric`
/// must agree on null-ness and depth (depth is order-independent even at a tie),
/// and agree on count + negated normal EXCEPT inside a SAT-confirmed MTV tie
/// (≥ 2 minimal axes). Any divergence not classified as a tie fails.
/// Drive `epa()` with diagnostics on a deep config and assert the corrupt paths
/// never fire post-fix (E4(a)): no exhaustion fallback, and the exit is only
/// `converged` (the expanding path) or `degenerate_low_dim` (a genuine < 3-D
/// Minkowski, e.g. an on-axis point⊖segment). `iteration_cap` /
/// `fallback_exhausted` / `defensive_non_deep_seed` would signal a residual
/// non-convergence. A no-op on non-deep configs (epa is not called there).
fn assertEpaDiagClean(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) !void {
    const g = narrowphase.gjk(Real, sa, pa, ra, sb, pb, rb);
    if (g.status != GjkResult.Status.deep) return;
    const relpose = RelativePose.init(pa, ra, pb, rb);
    var diag: EpaDiagnostics = undefined;
    _ = narrowphase.epa(Real, sa, pa, ra, relpose, sb, rb, g, &diag);
    try testing.expect(!diag.fallback_used);
    try testing.expect(diag.exit == EpaDiagnostics.Exit.converged or diag.exit == EpaDiagnostics.Exit.degenerate_low_dim);
}

fn assertOrderEquivalent(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr, dtol: Real) !void {
    const ab = narrowphase.collideOrderedGeneric(Real, sa, pa, ra, sb, pb, rb);
    const ba = narrowphase.collideOrderedGeneric(Real, sb, pb, rb, sa, pa, ra);
    try testing.expectEqual(ab == null, ba == null);
    if (ab == null) return;
    const ma = ab.?;
    const mb = ba.?;
    try testing.expectApproxEqAbs(maxPen(ma), maxPen(mb), dtol);
    const count_ok = ma.count == mb.count;
    const normal_ok = ma.normal.approxEql(mb.normal.neg(), normal_tol);
    if (!count_ok or !normal_ok) {
        const tie = satTieCount(sa, pa, ra, sb, pb, rb) >= 2;
        try testing.expect(tie);
    }
}

test "generic deep path is order-equivalent over the sweep" {
    const rot_a_set = [_]Quatr{
        Quatr.identity,
        Quatr.fromAxisAngle(vr(3, 1, 2).normalize(), 0.9),
    };
    const rot_b_set = [_]Quatr{
        Quatr.fromAxisAngle(Vec3r.unit_x, 0.4),
        Quatr.fromAxisAngle(vr(1, 1, 1).normalize(), 0.62),
        Quatr.fromAxisAngle(Vec3r.unit_z, 0.5),
        Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7),
        Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0),
    };
    const offsets = [_]Vec3r{
        vr(0, 0.3, 0),         vr(0.2, 0.4, 0.1),    vr(0, 0.6, 0),
        vr(0.3, 0.2, -0.2),    vr(0, 0.9, 0),        vr(0.5, 0.5, 0.3),
        vr(0.1, 0.1, 0.1),     vr(0.15, 0.35, 0.25), vr(0.4, 0.1, 0.2),
        vr(0.25, 0.55, -0.15), vr(0.05, 0.25, 0.45), vr(0.33, 0.44, 0.11),
        vr(-0.2, 0.3, 0.4),
    };
    const scales = [_]Real{ 0.01, 1, 100 };
    const pairs = [_]PairKind{ .box_box, .cap_box, .sph_cap };

    for (scales) |k| {
        const dtol = depth_tol * k;
        for (pairs) |pk| {
            const s = pairShapes(pk, k);
            for (rot_a_set) |ra| {
                for (rot_b_set) |rb| {
                    for (offsets) |off| {
                        const pb = off.scale(k);
                        try assertOrderEquivalent(s[0], vr(0, 0, 0), ra, s[1], pb, rb, dtol);
                        // E4(a): the corrupt EPA paths (fallback / iteration-cap /
                        // defensive) must never fire post-fix, either order.
                        try assertEpaDiagClean(s[0], vr(0, 0, 0), ra, s[1], pb, rb);
                        try assertEpaDiagClean(s[1], pb, rb, s[0], vr(0, 0, 0), ra);
                    }
                }
            }
        }
    }
}
