//! `foundation/math/exact.zig` — the exact integer cross product of a triangle.
//!
//! A float cross product fails on inputs the format itself admits, and five rounds of
//! power-of-two rescaling established that no arrangement of scale factors closes the class: where
//! a reduction is forced against overflow it must scale DOWN, and scaling down is exactly what
//! loses a component expressible only at the input magnitude. What DOES close it is leaving the
//! float format for the decision. Every finite float is an integer mantissa times a power of two,
//! so each of the cross's three 2×2 determinants is an exact integer expression, and the only
//! question is how wide.
//!
//! **The answer needs no `f128`, which is the point.** `f128` is software-emulated on most targets
//! and buys an exponent range that is still finite. Integers give an exact verdict and an exact
//! direction, and a DIRECTION IS SCALE-FREE — so the answer always fits back into `T` after one
//! common shift, whatever the inputs' exponent spread. Only shifts and additions are performed at
//! the wide width; the multiplications happen at `i128` at most. That matters concretely: wide
//! division and wide integer-to-float are LLVM library calls that do not exist at these widths and
//! fail to compile, while shifts and adds lower to inline loops.
//!
//! This is the COLD path by construction. `Vec.triangleCross` reaches it only when the plain float
//! cross and the per-lane repair have both failed, which a well-conditioned mesh never does.

const std = @import("std");
const vec = @import("vec.zig");

/// One exact value `m · 2^e`, with `m` an integer. A product of two float mantissas needs at most
/// `2 · (mantissa bits + 1)` — 48 for `f32`, 106 for `f64` — so `i128` holds every term.
const Term = struct { m: i128, e: i32 };

/// Accumulator width for one determinant.
///
/// Sized for the WORST case, in which every one of the eight terms must be retained and the
/// alignment spans the format's entire exponent range: about 650 bits for `f32` and about 4 400 for
/// `f64`. Only shifts and additions run at this width.
fn Acc(comptime T: type) type {
    return if (T == f32) i1024 else i8192;
}

/// Number of significant bits of `|m|`, computed by shifting rather than with `@clz`, which is a
/// library call at these widths.
fn bitLen(comptime I: type, m: I) u32 {
    if (m == 0) return 0;
    var a: I = if (m < 0) -m else m;
    var n: u32 = 0;
    while (a != 0) : (n += 1) a >>= 1;
    return n;
}

/// `x` written exactly as `m · 2^e` with `m` an integer. Zero maps to `(0, 0)`. `x` must be finite.
fn decompose(comptime T: type, x: T) Term {
    if (x == 0) return .{ .m = 0, .e = 0 };
    std.debug.assert(std.math.isFinite(x));
    const bits = std.math.floatMantissaBits(T) + 1;
    const f = std.math.frexp(x);
    return .{
        .m = @intFromFloat(std.math.ldexp(f.significand, bits)),
        .e = f.exponent - @as(i32, @intCast(bits)),
    };
}

fn mulTerm(a: Term, b: Term, negate: bool) Term {
    const m = a.m * b.m;
    return .{ .m = if (negate) -m else m, .e = a.e + b.e };
}

/// The eight products of `(a₁−a₀)(d₁−d₀) − (b₁−b₀)(c₁−c₀)`, expanded so that every factor is an
/// ORIGINAL vertex component. Expanding rather than subtracting first is what keeps the edge
/// subtraction — which can overflow on its own — out of the arithmetic entirely.
fn laneTerms(
    comptime T: type,
    a1: T,
    a0: T,
    d1: T,
    d0: T,
    b1: T,
    b0: T,
    c1: T,
    c0: T,
) [8]Term {
    const ta1 = decompose(T, a1);
    const ta0 = decompose(T, a0);
    const td1 = decompose(T, d1);
    const td0 = decompose(T, d0);
    const tb1 = decompose(T, b1);
    const tb0 = decompose(T, b0);
    const tc1 = decompose(T, c1);
    const tc0 = decompose(T, c0);
    return .{
        mulTerm(ta1, td1, false),
        mulTerm(ta1, td0, true),
        mulTerm(ta0, td1, true),
        mulTerm(ta0, td0, false),
        mulTerm(tb1, tc1, true),
        mulTerm(tb1, tc0, false),
        mulTerm(tb0, tc1, false),
        mulTerm(tb0, tc0, true),
    };
}

/// Exact value of one determinant as `(m, e)`, or `null` when it is EXACTLY zero.
///
/// **ALL EIGHT TERMS ARE ALWAYS RETAINED. There is no truncation window, and removing it is the
/// point.** An earlier version dropped terms it judged negligible, first against the largest term and
/// then — after that was measured wrong — against the accumulated sum. Both are unsound here, and the
/// second fails on exactly the case that matters most: three proportional points give a determinant
/// that is exactly zero, which is TOTAL cancellation, so the accumulated sum tends to zero and a
/// window calibrated on it has nothing left to calibrate against. The short-circuit then discards a
/// term the exact cancellation needed, and the answer comes back non-zero for a flat triangle — a
/// false ACCEPT, which is the one direction that must never fail.
///
/// The width was already sized for the worst case in which every term is retained, so the
/// short-circuit bought nothing but an opportunity to be wrong. This is a COLD path behind the
/// tier-1 test: it does not need to be fast, it needs to be exact. Shifts and additions only, no
/// wide division and no wide integer-to-float, both of which are LLVM library calls that do not
/// exist at these widths.
fn exactLane(comptime T: type, terms: [8]Term) ?struct { m: Acc(T), e: i32 } {
    var emin: i32 = std.math.maxInt(i32);
    var any = false;
    for (terms) |t| {
        if (t.m == 0) continue;
        if (t.e < emin) emin = t.e;
        any = true;
    }
    if (!any) return null;

    var sum: Acc(T) = 0;
    for (terms) |t| {
        if (t.m == 0) continue;
        sum += @as(Acc(T), t.m) << @intCast(t.e - emin);
    }
    if (sum == 0) return null;
    return .{ .m = sum, .e = emin };
}

/// Which lane of the cross reads which components: `x` is `(1,2)`, `y` is `(2,0)`, `z` is `(0,1)`.
const lane_indices = [3][2]usize{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } };

/// Whether the triangle is EXACTLY flat — the exact area vector is the zero vector — decided in
/// integer arithmetic with no tolerance and no float step anywhere in the decision.
///
/// **This is the only sound source of that verdict, and a float tier can never substitute for it.**
/// A float cross that comes out non-zero is not evidence: three exactly proportional points have
/// float products that need not cancel bit for bit, so the float answer is a rounding residue and
/// reads as a valid direction. That is exactly how a false ACCEPT reached the store — the cheap
/// tiers answered first and the exact tier was never consulted. So a caller that must not accept a
/// flat triangle asks HERE, and the tiered `Vec.triangleCross` is for callers that only need a
/// direction on geometry already validated.
pub fn triangleIsFlat(
    comptime T: type,
    v0: vec.Vec(3, T),
    v1: vec.Vec(3, T),
    v2: vec.Vec(3, T),
) bool {
    return triangleCrossDirection(T, v0, v1, v2) == null;
}

/// A vector PARALLEL to the true area vector of `(v0, v1, v2)`, or `null` when that vector is
/// EXACTLY zero — which is to say when the triangle is exactly flat, with no tolerance anywhere in
/// the decision.
///
/// The magnitude carries no meaning: the three exact determinants are brought onto ONE common power
/// of two chosen so the largest keeps a full mantissa, which is all a direction needs and is why
/// this always fits back into `T`. Every vertex component must be finite.
pub fn triangleCrossDirection(
    comptime T: type,
    v0: vec.Vec(3, T),
    v1: vec.Vec(3, T),
    v2: vec.Vec(3, T),
) ?vec.Vec(3, T) {
    const p0 = v0.toArray();
    const p1 = v1.toArray();
    const p2 = v2.toArray();

    var mant: [3]Acc(T) = .{ 0, 0, 0 };
    var expo: [3]i32 = .{ 0, 0, 0 };
    var live = [3]bool{ false, false, false };
    for (lane_indices, 0..) |ij, k| {
        const i = ij[0];
        const j = ij[1];
        const terms = laneTerms(T, p1[i], p0[i], p2[j], p0[j], p1[j], p0[j], p2[i], p0[i]);
        if (exactLane(T, terms)) |r| {
            mant[k] = r.m;
            expo[k] = r.e;
            live[k] = true;
        }
    }

    var top: i32 = std.math.minInt(i32);
    var any = false;
    for (0..3) |k| {
        if (!live[k]) continue;
        const mag = expo[k] + @as(i32, @intCast(bitLen(Acc(T), mant[k])));
        if (!any or mag > top) top = mag;
        any = true;
    }
    if (!any) return null;

    // One COMMON shift: the dominant lane keeps a full mantissa and the others shrink in proportion.
    const keep: i32 = @intCast(std.math.floatMantissaBits(T) + 1);
    const common: i32 = top - keep;
    var out = [3]T{ 0, 0, 0 };
    for (0..3) |k| {
        if (!live[k]) continue;
        const shift: i32 = common - expo[k];
        var m = mant[k];
        if (shift >= 0) {
            if (shift >= @as(i32, @intCast(bitLen(Acc(T), m)))) continue; // below the common scale
            m >>= @intCast(shift);
        } else {
            m <<= @intCast(-shift);
        }
        if (m == 0) continue;
        // The output scale is `2^-keep`, NOT the true `2^common`, and that is deliberate: the true
        // magnitude is meaningless here by contract, and preserving it would UNDERFLOW the whole
        // vector to zero whenever the exact cross is tiny — a denormal triangle's cross sits near
        // `2^-294`, unrepresentable at `f32`, and the caller would then be handed a `.direction`
        // that normalises to nothing. Placing the dominant lane just under 1 cannot overflow or
        // underflow at either end.
        out[k] = std.math.ldexp(@as(T, @floatFromInt(@as(i64, @intCast(m)))), -keep);
    }
    return vec.Vec(3, T).fromArray(out);
}

const testing = std.testing;

test "the exact direction serves a triangle no float form can express" {
    const V = vec.Vec(3, f32);
    // Legs whose exponents differ by more than `f32` holds, so every power-of-two rescaling loses
    // one of them: the exact cross is `(0, 0, 2^126 · 2^-100)` and strictly non-zero.
    const v0 = V.fromArray(.{ 0, 0, 0 });
    const v1 = V.fromArray(.{ std.math.ldexp(@as(f32, 1), 126), 0, 0 });
    const v2 = V.fromArray(.{ 0, std.math.ldexp(@as(f32, 1), -100), 0 });
    const d = triangleCrossDirection(f32, v0, v1, v2).?;
    // Direction exactly `+Z`, and the normalisation is exact because the other lanes are zero.
    try testing.expect(d.normalizeScaled().?.eql(V.fromArray(.{ 0, 0, 1 })));
}

test "an exactly flat triangle is reported flat, with no tolerance" {
    const V = vec.Vec(3, f64);
    const v0 = V.fromArray(.{ 0, 0, 0 });
    const v1 = V.fromArray(.{ 1, 3, 7 });
    // An exact integer multiple, so the three points are exactly collinear.
    const v2 = V.fromArray(.{ 3, 9, 21 });
    try testing.expect(triangleCrossDirection(f64, v0, v1, v2) == null);
    // And collinear at MIXED magnitudes, where every float form fails one way or the other.
    const v1b = V.fromArray(.{ std.math.ldexp(@as(f64, 1), 300), 0, 0 });
    const v2b = V.fromArray(.{ std.math.ldexp(@as(f64, 1), -300), 0, 0 });
    try testing.expect(triangleCrossDirection(f64, v0, v1b, v2b) == null);
}
