//! `forge_3d/pipeline/narrowphase/shapecast.zig` — the GJK shape-cast kernel
//! (M1.1.10).
//!
//! **A cast is a raycast against the Minkowski difference of the two cores,
//! inflated by `r_a + r_b`** (`engine-physics-forge.md` §1.11.11). Shape A swept
//! along `d` touches B at parameter `t` exactly when some core points `a ∈ A`,
//! `b ∈ B` satisfy `a + t·d = b` up to the inflation; equivalently, when the ray
//! from the CONFIGURATION-SPACE ORIGIN along `−d` reaches the set
//! `C = core_A ⊖ core_B` inflated by `r_sum`. The whole cast is therefore one ray
//! march through a FIXED convex set, and the set is fixed because a sweep is a pure
//! translation: neither core rotates during it.
//!
//! That is the core + inflation-radius convention of §1.11.3, never a second one,
//! and it has a structural consequence worth stating: a sphere cast against a box is
//! a ray against a ROUNDED box, precisely the shape `raycast.zig` rejects with
//! `error.UnsupportedShape`. A cast is not expressible over the ray kernels — hence
//! this file. And because a support map covers every BOUNDED convex, this kernel has
//! no shape to reject and so **no error channel at all**: the frozen signature
//! carrying none is evidence for the design, not a constraint on it.
//!
//! A cast is **not CCD**. It interrogates the current state of the world along a
//! given translation, advances no body, and appears in no step of the tick cycle
//! (§1.11.1).
//!
//! **Everything is in A's frame**, the frozen narrowphase discipline: `shape_a` is
//! untransformed, B arrives through a `RelativePose`, and the returned witness and
//! normal are A-frame vectors the caller rotates to world (E4's `castShapeBody`, the
//! mirror of `raycastBody`). A is the CAST shape, so its frame is a constant of the
//! whole query rather than something that changes per candidate body.
//!
//! **Termination is normative, not an implementation choice.** §1.11.11 carries the
//! table and `CastExit` is that table — one variant per row, so no row is
//! unobservable and therefore none is untestable. The parameter starts at zero,
//! increases, and is at every step a LOWER BOUND of the true time of impact, because
//! an advance only ever moves the ray point onto a SUPPORTING PLANE of `C`, and `C`
//! lies entirely behind it. Two exits are a miss; every other exit returns a hit AT
//! THE CURRENT PARAMETER. Returning a miss on exhaustion would fabricate a false
//! negative, hence tunnelling; returning the current parameter fabricates a contact
//! announced EARLY, never a missed one, which is the safe failure direction for the
//! character controller of M1.1.12.
//!
//! **Threshold discipline.** The "no longer approaching" guard is at TRUE ZERO — the
//! reference's absolute `-1.0e-18f` is deliberately not reproduced and the argument
//! is written at the guard. Convergence is an EXACT geometric comparison against
//! `r_sum` plus a numerical-noise floor of the form `k · floatEps(T) · coordScale`,
//! the same shape and the same `noise_k` as `gjk.zig`'s `degenerateOriginReached`.
//! No geometric epsilon appears anywhere, and every normalisation goes through
//! `unitOf`, which is safe at both ends of the float range.
//!
//! **Conditioning (§1.11.4 bis).** The returned normal is NORMALISED rather than
//! divided by a radius, so its LENGTH is a structural invariant at any distance and
//! a degenerate normal is always a defect, never an effect of distance; only its
//! orientation carries the far-field residue. The witness is a barycentric
//! combination of support points that are all of the shapes' own scale, so no large
//! near-equal quantities are subtracted to obtain it.
//!
//! **Dependency discipline.** Imports `foundation` (math) + the sibling
//! `support.zig` / `gjk.zig` ONLY — never `manifold.zig`, `epa.zig`, `weld_forge`,
//! `body*.zig`, `config.zig` or `broadphase.zig`, and never `gjk.zig`'s LOOP:
//! `gjk()` is not called here. `gjk.zig` is imported for `Simplex(T)`'s Voronoi
//! closest-origin solver alone — exactly the dependency `epa.zig` already declares,
//! and for the same reason: a simplex solver is not a GJK descent.

const std = @import("std");
const math = @import("foundation").math;
const support = @import("support.zig");
const gjk_mod = @import("gjk.zig");

const SupportShape = support.SupportShape;
const RelativePose = support.RelativePose;
const minkowskiSupport = support.minkowskiSupport;

/// Named iteration ceiling for the cast march, sibling of `max_gjk_iterations` and
/// `max_epa_iterations`. **Obligatory, not a tuning knob**: the reference's
/// `CastRay` has no ceiling at all (`for (;;)`), which the M1.1.14 determinism
/// freeze forbids. Its semantics are normative — exhaustion returns a hit at the
/// current parameter (§1.11.11) — and `castShapeBounded` exists so that semantics is
/// OBSERVED by a test rather than asserted by a comment.
pub const max_shapecast_iterations: u32 = 32;

/// Slack on the unit-direction assert, in ULPs of 1. The comparison is against 1, so
/// this is pure float noise and not a geometric tolerance — same constant and same
/// role as `raycast.zig`'s.
const unit_dir_k: comptime_int = 16;

/// Numerical-noise floor multiplier for the convergence test, in ULPs. Identical in
/// value and role to `gjk.zig`'s `noise_k`: a floor on the SQUARED closest-point
/// magnitude, scaled by the absolute coordinate magnitude the arithmetic actually
/// sees. It absorbs float rounding and nothing else — widening it would turn a
/// proximity into a contact.
const noise_k: comptime_int = 2;

/// One cast hit, in A's frame.
pub fn CastHit(comptime T: type) type {
    return struct {
        /// Distance along the (unit) cast direction at first touch, in
        /// `[0, max_distance]`. Zero when the shapes already overlap at the start
        /// pose.
        distance: T,
        /// Witness point on B — the HIT body — on its INFLATED surface, A's frame.
        /// Reconstructed from the terminal simplex's barycentric weights over B's
        /// support points plus the `r_b` offset along the outward normal; no EPA is
        /// involved. Beyond a zero distance this is also the witness on the moved A,
        /// the two coinciding exactly (see `terminal`).
        point: math.Vec(3, T),
        /// Outward unit normal of the HIT body at the witness, A's frame. Satisfies
        /// `normal · direction <= 0` on every hit.
        normal: math.Vec(3, T),
    };
}

/// How the march terminated — one variant per row of §1.11.11's termination table.
/// Mirrors `epa.zig`'s `EpaDiagnostics.Exit`.
pub const CastExit = enum {
    /// The direction was EXACTLY zero — a degenerate query, empty result. Not a
    /// termination row: it belongs to §1.11.11's DOMAIN table and fires before the
    /// march begins. Kept distinct precisely so the seven variants below stay a
    /// faithful mirror of the termination table, neither padded nor short.
    degenerate_direction,
    /// The current axis and the direction no longer approach → **miss**.
    receding,
    /// The parameter passed `max_distance` → **miss**.
    beyond_bound,
    /// The closest point converged within the inflated surface → hit.
    converged,
    /// The simplex became full, the origin enclosed → hit.
    simplex_full,
    /// The parameter stopped progressing → hit.
    no_progress,
    /// A repeated support point after the one authorised restart → hit.
    restart_exhausted,
    /// `max_shapecast_iterations` reached → hit at the current parameter.
    iteration_cap,
};

/// Optional observability channel, on `epa.zig`'s `EpaDiagnostics` model. It is what
/// turns a seven-row normative table into seven pinned behaviours instead of one.
pub const CastDiagnostics = struct {
    /// Which row of §1.11.11's table ended the march.
    exit: CastExit,
    /// Iterations executed.
    iterations: u32,
    /// Parameter advances performed (an advance is where the axis is recorded).
    advances: u32,
    /// Simplex restarts performed. The budget is one per ray point (see the
    /// advance branch), so this counts bases at which a repeated support point was
    /// absorbed — not failures.
    restarts: u32,
};

/// Cast `shape_a` along `direction` against `shape_b` — both cores plus inflation
/// radii, with B's pose relative to A given by `relpose`. Returns the first touch
/// within `[0, max_distance]` — a CLOSED interval, so a contact exactly at
/// `max_distance` counts — or `null` on a miss.
///
/// `direction` is in A's frame and need NOT be unit: it is reduced by its largest
/// absolute component and normalised once here, so the returned `distance` is a
/// distance and never a fraction. A direction that is EXACTLY zero is a degenerate
/// query and returns `null`; a denormal one is perfectly legitimate and is served
/// (§1.11.4, reused verbatim). `max_distance == 0` is legal and degenerates into an
/// overlap test at the start pose.
///
/// There is no error channel, by construction: a support map covers every bounded
/// convex, so this kernel has no shape to reject.
pub fn castShape(
    comptime T: type,
    shape_a: SupportShape(T),
    relpose: RelativePose(T),
    shape_b: SupportShape(T),
    direction: math.Vec(3, T),
    max_distance: T,
) ?CastHit(T) {
    return castShapeBounded(T, shape_a, relpose, shape_b, direction, max_distance, max_shapecast_iterations, null);
}

/// `castShape` with the iteration ceiling and the diagnostics channel exposed.
///
/// The ceiling is a parameter for ONE reason: the normative fallback of §1.11.11 —
/// exhaustion returns a hit at the current parameter — is unreachable in practice on
/// the three cores the store builds, which converge in a handful of iterations. A
/// guard never observed to fire is a comment with extra syntax, so a test drives a
/// small ceiling through the SAME code path and asserts both that the cap fired and
/// that what came back is a hit at a parameter at or below the true time of impact.
/// Only the constant differs between that run and production.
pub fn castShapeBounded(
    comptime T: type,
    shape_a: SupportShape(T),
    relpose: RelativePose(T),
    shape_b: SupportShape(T),
    direction: math.Vec(3, T),
    max_distance: T,
    ceiling: u32,
    diag: ?*CastDiagnostics,
) ?CastHit(T) {
    const Vec3T = math.Vec(3, T);
    const Simplex = gjk_mod.Simplex(T);
    const Vertex = support.Vertex(T);
    const Simd = @Vector(3, T);

    // Domain assert, the shape of `rayInterval`'s and of the solver passes
    // (§1.11.11): a finite direction, a finite non-negative bound. The rotation's
    // unit norm was established where `relpose` was built.
    std.debug.assert(std.math.isFinite(max_distance) and max_distance >= 0);
    std.debug.assert(@reduce(.And, @abs(direction.data) < @as(Simd, @splat(std.math.inf(T)))));
    std.debug.assert(ceiling > 0);

    // The direction, normalised once. `unitOf` returns null at EXACTLY zero, which
    // is the whole zero-direction guard.
    const d = unitOf(T, direction) orelse return finish(T, diag, .degenerate_direction, 0, 0, 0, null);
    std.debug.assert(@abs(d.lengthSq() - 1) <= unit_dir_k * std.math.floatEps(T));

    // The configuration-space ray direction. A swept along `+d` touching B is the ray
    // along `−d` from the origin reaching `C = core_A ⊖ core_B`, because
    // `a + t·d = b` ⟺ `−t·d = a − b ∈ C`. Working with `A ⊖ B` rather than `B ⊖ A`
    // is what lets `minkowskiSupport` and the `Vertex{w, support_a, support_b}`
    // semantics be reused exactly as the rest of the narrowphase has them.
    const r = d.neg();
    const r_sum = shape_a.radius + shape_b.radius;
    std.debug.assert(r_sum >= 0);

    var lambda: T = 0;
    var x = Vec3T.zero; // = r · lambda
    var verts: [4]Vertex = undefined;
    var weights: [4]T = undefined;
    var count: usize = 0;
    // The separating axis recorded at the last advance. Non-degenerate by
    // construction: an advance requires `v · w > r_sum · |v|`, which needs `v ≠ 0`.
    var advance_axis: ?Vec3T = null;
    var advances: u32 = 0;
    var restart_used = false;
    var restarts: u32 = 0;
    var max_mag_sq: T = 0;

    // Seed: one support sample along the ray direction. ANY support point yields a
    // valid supporting plane and hence a valid lower bound on the time of impact, so
    // the seed affects the iteration count and nothing else — including soundness of
    // the receding miss below. Deterministic: `support`'s tie-breaks are fixed.
    {
        const seed = minkowskiSupport(T, shape_a, relpose, shape_b, r);
        verts[0] = seed;
        weights[0] = 1;
        count = 1;
        max_mag_sq = seed.w.lengthSq();
    }
    var v = x.sub(verts[0].w);

    var iter: u32 = 0;
    while (iter < ceiling) : (iter += 1) {
        // The search direction for `C` is `v` itself: `v` points FROM `C` TOWARD the
        // ray point, so the point of `C` furthest along `v` carries the supporting
        // plane most likely to separate them.
        const sample = minkowskiSupport(T, shape_a, relpose, shape_b, v);
        const w = x.sub(sample.w);
        const v_dot_w = v.dot(w);
        const v_len_sq = v.lengthSq();

        // Is the ray point more than `r_sum` OUTSIDE the supporting plane at
        // `sample`? The signed distance is `(v · w) / |v|`, so the test is
        // `v · w > r_sum · |v|` — written in SQUARED form so the square root is paid
        // only on the advance path. Squaring is valid because both sides are
        // non-negative once `v · w > 0`, and a `v · w <= 0` can never exceed
        // `r_sum · |v| >= 0`.
        const separating = v_dot_w > 0 and v_dot_w * v_dot_w > r_sum * r_sum * v_len_sq;
        if (separating) {
            const v_dot_r = v.dot(r);
            // "No longer approaching", at TRUE ZERO. No `-1.0e-18f`: at true zero the
            // division below is never reached, and a DENORMAL denominator overflows
            // the step to infinity, hence the parameter past `max_distance`, hence a
            // miss through the bound test that follows — the same outcome the
            // reference's absolute guard buys, without introducing a constant. No NaN
            // is reachable either: the numerator is STRICTLY POSITIVE at this branch
            // (that is what `separating` means) and the denominator strictly positive
            // too, so the quotient is never `0 / 0`.
            //
            // The miss is EXACT, not heuristic, and does not depend on the seed: `v`
            // is a genuine separating direction of `C` and the ray recedes from it,
            // so no parameter can ever bring the ray point back across.
            if (v_dot_r >= 0) return finish(T, diag, .receding, iter + 1, advances, restarts, null);

            const numerator = v_dot_w - r_sum * @sqrt(v_len_sq); // > 0
            const denominator = -v_dot_r; // > 0
            const next = lambda + numerator / denominator;

            // The bound test is STRICT. `lambda` is a lower bound of the true time of
            // impact, so `> max_distance` proves the contact is out of range;
            // `== max_distance` proves nothing yet, and cutting there would refuse a
            // contact lying exactly AT the bound — which §1.11.11 declares counts,
            // the interval being closed. Left to run, such a case either converges at
            // `max_distance` (a hit) or advances strictly past it (a miss).
            if (next > max_distance) return finish(T, diag, .beyond_bound, iter + 1, advances, restarts, null);

            // The parameter stopped progressing: the increment rounded away. TRUE
            // ZERO on the increment, no epsilon.
            if (!(next > lambda)) {
                return finish(T, diag, .no_progress, iter + 1, advances, restarts, terminal(T, lambda, d, verts[0..count], weights[0..count], v, advance_axis, shape_b.radius));
            }

            lambda = next;
            x = r.scale(lambda);
            advance_axis = v;
            advances += 1;
            // The simplex is NOT cleared. Its vertices are stored as support points
            // of `C`, so re-basing them on the new ray point is just recomputing
            // `x − w` below.
            //
            // The restart budget is refreshed HERE, and that placement is load-bearing
            // rather than cosmetic. A repeated support point right after an advance is
            // not a failure at all: for a POINT core the Minkowski difference is a
            // single point, so EVERY sample repeats, and the march is then a perfectly
            // healthy plane-offset iteration converging on the inflated surface.
            // MEASURED: with the budget spent once per CALL, a sphere-against-sphere
            // cast whose closed-form answer is 7 exited `restart_exhausted` at
            // 6.952526 after two iterations. The budget is therefore per BASE — one
            // restart per ray point, the reference's semantics — and `restart_exhausted`
            // then fires only on a genuine stall: two repeats with no advance between
            // them, which is a descent that has stopped producing information.
            restart_used = false;
        }

        // Anti-cycling: an EXACT repeat of a stored support point with no intervening
        // advance means the descent has stopped producing information. One restart is
        // authorised per ray point (§1.11.11, "l'unique restart autorisé"); a second
        // repeat returns a hit at the current parameter, which is a contact announced
        // early and never a missed one.
        if (duplicateSupport(T, verts[0..count], sample.w)) {
            if (restart_used) {
                return finish(T, diag, .restart_exhausted, iter + 1, advances, restarts, terminal(T, lambda, d, verts[0..count], weights[0..count], v, advance_axis, shape_b.radius));
            }
            restart_used = true;
            restarts += 1;
            verts[0] = sample;
            weights[0] = 1;
            count = 1;
        } else {
            std.debug.assert(count < 4);
            verts[count] = sample;
            count += 1;
        }
        max_mag_sq = @max(max_mag_sq, @max(sample.w.lengthSq(), x.lengthSq()));

        // Closest point of the RE-BASED simplex to the ray point. Shifting is affine,
        // so the barycentric weights returned apply unchanged to the UNSHIFTED support
        // points — which is what makes the witness a pure combination of `support_b`.
        var shifted: [4]Vec3T = undefined;
        for (verts[0..count], 0..) |vert, i| shifted[i] = x.sub(vert.w);
        const res = switch (count) {
            1 => Simplex.closestOriginPoint(shifted[0]),
            2 => Simplex.closestOriginSegment(shifted[0], shifted[1]),
            3 => Simplex.closestOriginTriangle(shifted[0], shifted[1], shifted[2]),
            4 => Simplex.closestOriginTetra(shifted[0], shifted[1], shifted[2], shifted[3]),
            else => unreachable,
        };
        v = res.closest;

        // Reduce to the surviving feature, keeping the solver's reported order so its
        // weights stay aligned with the vertices they belong to.
        var kept: [4]Vertex = undefined;
        var kept_weights: [4]T = undefined;
        for (res.indices[0..res.count], 0..) |src, i| {
            kept[i] = verts[src];
            kept_weights[i] = res.bary[i];
        }
        const kept_count: usize = res.count;

        // The origin is enclosed by a full simplex: the ray point is inside `C`
        // itself, hence inside the inflated body a fortiori.
        if (res.count == 4) {
            return finish(T, diag, .simplex_full, iter + 1, advances, restarts, terminal(T, lambda, d, kept[0..kept_count], kept_weights[0..kept_count], v, advance_axis, shape_b.radius));
        }

        // Converged — two sufficient conditions, no threshold between them:
        //
        //   (1) `|v| <= r_sum`, EXACT and geometric. `v` is the closest point of a
        //       simplex CONTAINED in `C`, so `dist(x, C) <= |v|`: the ray point is
        //       provably within `r_sum` of the core difference, hence inside the
        //       inflated body. It can fire an iteration late (|v| overestimates the
        //       distance) and never early, which is the safe direction.
        //   (2) a NUMERICAL-NOISE floor for hard cores. At `r_sum == 0` condition (1)
        //       reads `v == 0` exactly, which float arithmetic may approach without
        //       reaching; the floor is `noise_k · floatEps(T)` on the squared
        //       magnitude, scaled by the absolute coordinate magnitude the arithmetic
        //       sees — the same shape and the same `noise_k` as `gjk.zig`'s
        //       `degenerateOriginReached`. It absorbs rounding and nothing else.
        const mach_eps = @as(T, noise_k) * std.math.floatEps(T);
        const new_v_len_sq = v.lengthSq();
        if (new_v_len_sq <= r_sum * r_sum or new_v_len_sq <= mach_eps * mach_eps * max_mag_sq) {
            return finish(T, diag, .converged, iter + 1, advances, restarts, terminal(T, lambda, d, kept[0..kept_count], kept_weights[0..kept_count], v, advance_axis, shape_b.radius));
        }

        @memcpy(verts[0..kept_count], kept[0..kept_count]);
        @memcpy(weights[0..kept_count], kept_weights[0..kept_count]);
        count = kept_count;
    }

    // Ceiling reached: a hit at the current parameter, never a miss (§1.11.11).
    return finish(T, diag, .iteration_cap, iter, advances, restarts, terminal(T, lambda, d, verts[0..count], weights[0..count], v, advance_axis, shape_b.radius));
}

/// Assemble the hit at the terminal state: the parameter, the witness on B, and B's
/// outward normal.
///
/// **The normal.** `v` points from `C` toward the ray point and `C = core_A ⊖ core_B`,
/// so `v` is A's outward normal at the contact and B's is its NEGATION — B being the
/// hit body, that negation is what the hit carries. When `v` has collapsed at
/// convergence (the hard-core case, `r_sum == 0`) the axis of the PREVIOUS iteration
/// is used, which is exactly the axis recorded at the last advance and is
/// non-degenerate by construction; failing even that — no advance ever happened —
/// the normal is `−direction`, the same choice `raycast.zig` makes at distance zero
/// and the only one keeping `normal · direction <= 0` on every hit.
///
/// **The witness.** `Σ λ_i · support_b_i` over the surviving vertices is the witness
/// on B's CORE; the point on its real surface is that plus `r_b` along B's outward
/// normal. At a non-zero parameter this is also the witness on the moved A: at the
/// contact `b − (a + t·d) = r_sum · v̂`, so `(a + t·d) + r_a·v̂` and `b − r_b·v̂` are
/// the same point. Only B's is computed — it carries fewer terms, hence less
/// rounding (§1.11.11). No EPA is involved anywhere.
fn terminal(
    comptime T: type,
    lambda: T,
    direction: math.Vec(3, T),
    verts: []const support.Vertex(T),
    weights: []const T,
    v: math.Vec(3, T),
    advance_axis: ?math.Vec(3, T),
    radius_b: T,
) CastHit(T) {
    const Vec3T = math.Vec(3, T);
    std.debug.assert(verts.len == weights.len and verts.len > 0);

    // Outward direction of `C`, preferring the terminal axis and falling back exactly
    // as documented above. Both selections are at TRUE ZERO, through `unitOf`, which
    // also refuses an axis whose reciprocal length would overflow.
    const outward: ?Vec3T = unitOf(T, v) orelse if (advance_axis) |axis| unitOf(T, axis) else null;
    const normal = if (outward) |unit| unit.neg() else direction.neg();

    var core_b = Vec3T.zero;
    for (verts, weights) |vert, weight| core_b = core_b.add(vert.support_b.scale(weight));

    return .{
        .distance = lambda,
        .point = core_b.add(normal.scale(radius_b)),
        .normal = normal,
    };
}

/// Unit vector along `v`, or `null` when `v` is EXACTLY zero.
///
/// Reduced by its largest absolute component before anything is squared, the same
/// argument as the direction normalisation: squaring first overflows for a large
/// finite vector and underflows for a legitimately tiny one, and `foundation`'s
/// `normalize` is unguarded by design. The reduction is a component-wise DIVISION,
/// never a multiplication by `1 / scale`, whose reciprocal overflows for a denormal.
fn unitOf(comptime T: type, v: math.Vec(3, T)) ?math.Vec(3, T) {
    const Simd = @Vector(3, T);
    const scale = @reduce(.Max, @abs(v.data));
    if (scale == 0) return null;
    const reduced: math.Vec(3, T) = .{ .data = v.data / @as(Simd, @splat(scale)) };
    return reduced.scale(1 / reduced.length());
}

/// Record the exit and return the result. Centralised so no exit can forget to fill
/// the diagnostics, which is what keeps `CastExit` a faithful mirror of §1.11.11's
/// table rather than a best-effort label.
fn finish(
    comptime T: type,
    diag: ?*CastDiagnostics,
    exit: CastExit,
    iterations: u32,
    advances: u32,
    restarts: u32,
    hit: ?CastHit(T),
) ?CastHit(T) {
    if (diag) |out| out.* = .{
        .exit = exit,
        .iterations = iterations,
        .advances = advances,
        .restarts = restarts,
    };
    return hit;
}

/// Whether `w` EXACTLY repeats a stored support point. Exact, at true zero: a repeat
/// means the support map returned the same vertex for a new direction, which is
/// information-free whatever its magnitude, so no relative tolerance belongs here.
fn duplicateSupport(comptime T: type, verts: []const support.Vertex(T), w: math.Vec(3, T)) bool {
    for (verts) |vert| {
        if (@reduce(.And, vert.w.data == w.data)) return true;
    }
    return false;
}
