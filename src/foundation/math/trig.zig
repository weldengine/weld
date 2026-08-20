//! `foundation/math/trig.zig` — the engine's DETERMINISTIC trigonometry.
//!
//! `ARCH-031` rule 4 forbids a system-libm transcendental on any path whose
//! output is compared: two C libraries disagree by an ULP, and a constant
//! derived from one of them is divergent engine state. The substitute is an
//! in-house implementation at a FIXED operation order, added **function by
//! function on demonstrated need** — never as a replacement libm. This file
//! carries exactly one function, and M1.1.14 added it for exactly one call
//! site: the `max_slope` conversion of the kinematic character controller
//! (`engine-physics-queries.md` §1.12.5), whose result is STORED engine state
//! and therefore sits in the compared bits from frame 0.
//!
//! `@sqrt` is deliberately absent from this file and stays a builtin: IEEE-754
//! requires it correctly rounded and it lowers to a hardware instruction
//! (`ARCH-031` rule 4, last sentence).
//!
//! **What makes the result reproducible**, in three parts, none of which is a
//! preference:
//!
//! 1. **Fixed operation order.** Every expression below is written out; no
//!    reassociation is admitted, and `.strict` — the language default, never
//!    disabled here — is what forbids the backend from finding one. There is
//!    no `@mulAdd`: a contraction would change the result by an ULP on the
//!    ISA that has the instruction and not on the one that does not, which is
//!    precisely the divergence this file exists to remove (`ARCH-031` rule 2).
//! 2. **No external symbol.** `+`, `-`, `*` and `@abs` only. In particular
//!    neither `@floor` nor `@round` appears: on a baseline x86_64 target
//!    (no SSE4.1) `@floor` lowers to an external `floor`, and while `floor`
//!    is exactly specified by IEEE-754 and would therefore not diverge, an
//!    external libm symbol on this path would still have to be argued about
//!    at every future assembly inventory. The integer part is extracted by
//!    the magic-constant add instead (below).
//! 3. **A rounding mode that is installed, not assumed.** The reduction's
//!    `roundToNearestEven` step IS the magic-constant add `(v + 2^52) - 2^52`,
//!    which computes round-to-nearest-even only BECAUSE the FPU is in that
//!    mode. Under round-toward-zero the same expression returns the truncation
//!    and this function silently returns a different number. That is not a
//!    weakness of the trick — it is the reason `foundation/math/float_env.zig`
//!    installs the mode at thread creation and every deterministic module
//!    asserts it at its entry point (`ARCH-031` rule 5). The two deliverables
//!    of this milestone hold each other up.

const std = @import("std");

/// The largest argument magnitude `cos` accepts, `2^20 · π/2` ≈ `1.647e6` rad.
///
/// The bound is the exactness limit of the argument reduction, not a taste: the
/// first Cody-Waite constant carries 33 significant bits, so the product
/// `n · pio2_hi` is EXACT while `|n| < 2^(53−33) = 2^20`, and `|n|` is
/// `|x| · 2/π` rounded. Past it the product rounds, the reduced argument stops
/// being the true remainder, and far past it the reduced argument is not even
/// small — so the polynomial would be evaluated far outside the interval it was
/// fitted on and could leave `[−1, 1]` entirely.
///
/// Serving a larger domain correctly needs Payne-Hanek — a multi-hundred-bit
/// table of `2/π` — which is the "replacement libm" `ARCH-031` rule 4 names as
/// an abuse of its own clause. The bound is declared and asserted instead. It
/// is `262144` full turns; the one call site authors a slope angle in `[0, π/2]`.
pub const max_argument: f64 = 1048576.0 * @as(f64, std.math.pi) / 2.0;

// --- Argument reduction constants -------------------------------------------
//
// A three-part split of π/2. `pio2_hi` and `pio2_mid` are the leading 33 and 33
// bits of π/2 with their low mantissa bits zeroed, so `n · pio2_hi` and
// `n · pio2_mid` are EXACT products for the `|n| < 2^20` this file admits; the
// residue lives in `pio2_lo`. The three terms are subtracted in decreasing
// magnitude, which is what keeps the cancellation benign: `x − n · pio2_hi` is
// a difference of two nearly equal quantities and is therefore exact by
// Sterbenz, and each following term only refines it.
//
// All three terms are applied UNCONDITIONALLY. A refinement loop that stops
// early on a "good enough" test would make the operation count a function of
// the input, which is a shape this file does not want on a compared path even
// though it would be deterministic.
const pio2_hi: f64 = 1.57079632673412561417e+00;
const pio2_mid: f64 = 6.07710050650619224932e-11;
const pio2_lo: f64 = 2.02226624879595063154e-21;

/// `2/π`, rounded to nearest. Only ever consumed to pick the quadrant index, so
/// its own rounding error is absorbed by the reduction that follows.
const two_over_pi: f64 = 6.36619772367581382433e-01;

/// `2^52` — the magic constant whose add-then-subtract rounds an `f64` of
/// magnitude below `2^52` to the nearest integer, ties to even, in the current
/// rounding mode. See the file header, point 3.
const magic: f64 = 4503599627370496.0;

// --- Kernel polynomials ------------------------------------------------------
//
// Minimax coefficients for the two kernels on `|r| <= π/4`, the classical
// degree-13 sine and degree-14 cosine fits (Sun's fdlibm lineage, the same
// numbers every serious libm carries — they are the fit, not an implementation
// choice). Both kernels are well inside `f64` here: the sine residual is below
// `2⁻⁶¹` and the cosine's below `2⁻⁶³` on the interval, so the error budget of
// `cos` is dominated by the reduction, not by these.
//
// Evaluated by Horner, innermost coefficient first, in the written order.

const s1: f64 = -1.66666666666666324348e-01;
const s2: f64 = 8.33333333332248946124e-03;
const s3: f64 = -1.98412698298579493134e-04;
const s4: f64 = 2.75573137070700676789e-06;
const s5: f64 = -2.50507602534068634195e-08;
const s6: f64 = 1.58969099521155010221e-10;

const c1: f64 = 4.16666666666666019037e-02;
const c2: f64 = -1.38888888888741095749e-03;
const c3: f64 = 2.48015872894767294178e-05;
const c4: f64 = -2.75573143513906633035e-07;
const c5: f64 = 2.08757232129817482790e-09;
const c6: f64 = -1.13596475577881948265e-11;

/// `sin(r)` for `|r| <= π/4`, as `r + r·z·P(z)` with `z = r²`.
///
/// The leading `r` is kept OUT of the polynomial rather than folded into it:
/// for a small `r` — a denormal included — `z` underflows to zero, the whole
/// correction vanishes exactly, and the function returns `r` itself. A fit that
/// produced `r` from the polynomial would round it instead.
fn kernelSin(r: f64) f64 {
    const z = r * r;
    const p = s1 + z * (s2 + z * (s3 + z * (s4 + z * (s5 + z * s6))));
    return r + r * z * p;
}

/// `cos(r)` for `|r| <= π/4`, as `1 − (0.5·z − z²·P(z))` with `z = r²`.
///
/// The grouping is what keeps it accurate at the top of the interval: at
/// `r = π/4`, `0.5·z ≈ 0.308` against a result of `≈ 0.707`, so the subtraction
/// from `1` loses no leading bit. Written flat, `1 − 0.5·z + …` would round the
/// same way here but would stop saying why.
fn kernelCos(r: f64) f64 {
    const z = r * r;
    const p = c1 + z * (c2 + z * (c3 + z * (c4 + z * (c5 + z * c6))));
    return 1.0 - (0.5 * z - z * z * p);
}

/// Cosine of `x` radians at scalar `T` (`f32` or `f64`), computed WITHOUT any
/// libm call and at a fixed operation order.
///
/// The internal arithmetic is `f64` whatever `T` is. Widening an `f32` argument
/// is EXACT, so `cos(f32, x)` is `cos(f64, x)` narrowed once at the end — the
/// same discipline `engine-physics-queries.md` §1.12.6 states for the
/// displacement domain, and for the same reason: a verdict declared on what is
/// computed is only defined if the computation is.
///
/// Domain: `x` finite and `@abs(x) <= max_argument`. Asserted, not clamped — a
/// silent clamp would make a caller's fault look like a modelling choice, which
/// is the arbitration this module takes everywhere else
/// (`engine-physics-queries.md` §1.12.6, on a saturated displacement).
pub fn cos(comptime T: type, x: T) T {
    comptime std.debug.assert(T == f32 or T == f64);

    const wide: f64 = x;
    // `@abs(NaN) <= c` is false, so the finiteness half of the domain is
    // carried by the same comparison — the technique `query/root.zig` uses on
    // its own domain asserts.
    std.debug.assert(@abs(wide) <= max_argument);

    // Cosine is EVEN, so the sign folds away before anything else and the
    // reduction only ever sees a non-negative argument. This is not an
    // optimisation: it halves the number of paths the value table has to pin,
    // and it makes the quadrant index non-negative by construction.
    const a = @abs(wide);

    // Quadrant index. `magic` rounds to nearest-even (file header, point 3);
    // `n` is then exact and, inside the declared domain, at most `2^20 + 1`.
    const nf = (a * two_over_pi + magic) - magic;
    const n: i64 = @intFromFloat(nf);
    const quadrant: u2 = @intCast(n & 3);

    // Cody-Waite: `r = a − n·(π/2)` computed in three exact-then-refining
    // steps. Order fixed, no early exit.
    const r = ((a - nf * pio2_hi) - nf * pio2_mid) - nf * pio2_lo;

    const wide_result = switch (quadrant) {
        0 => kernelCos(r),
        1 => -kernelSin(r),
        2 => -kernelCos(r),
        3 => kernelSin(r),
    };

    return @floatCast(wide_result);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "cos: cos(0) is exactly one, at both scalars" {
    // The shortest path through the code: `nf = 0`, so the three reduction
    // terms are exact zeros and `r` is `0`. Its own block because it is a
    // different claim from evenness below — a reduction that broke at zero and
    // a sign fold that broke are two defects, and one verdict for both would
    // name neither.
    try testing.expectEqual(@as(f64, 1.0), cos(f64, 0.0));
    try testing.expectEqual(@as(f32, 1.0), cos(f32, 0.0));
}

test "cos: evenness is EXACT, not approximate" {
    // The sign is folded by `@abs` before any arithmetic runs, so the two calls
    // execute bit-identical instructions. A fit that carried the sign through
    // the polynomial would not give this, and the assertion is equality rather
    // than a tolerance for exactly that reason.
    const probes = [_]f64{ 0.3, 1.0, 2.0, 3.5, 100.25 };
    for (probes) |p| {
        errdefer std.debug.print("cos: evenness failed at x = {d}\n", .{p});
        try testing.expectEqual(cos(f64, p), cos(f64, -p));
        try testing.expectEqual(cos(f32, @floatCast(p)), cos(f32, @floatCast(-p)));
    }
}

test "cos: a denormal argument returns exactly one" {
    // The smallest positive `f64`. `z = r²` underflows to zero, the correction
    // vanishes EXACTLY, and `1 − (0 − 0)` is `1`. The true cosine of `5e-324`
    // differs from 1 by ~1e-647, far below the spacing of `f64` at 1, so `1` is
    // the nearest representable value. This is also the case that would break
    // first if the denormal were flushed to zero somewhere upstream, which is
    // why the float environment is a sibling deliverable.
    try testing.expectEqual(@as(f64, 1.0), cos(f64, std.math.floatTrueMin(f64)));
    try testing.expectEqual(@as(f32, 1.0), cos(f32, std.math.floatTrueMin(f32)));
}

test "cos: accuracy against the builtin, inside the declared domain" {
    // NON-VACUITY GUARD for the committed value table. A table of expected bits
    // proves the function is STABLE; it cannot prove it is a cosine — a
    // function returning a constant would pass it. This test is the other half,
    // and it is deliberately written against `@cos`, the very libm the module
    // exists to remove: as an ORACLE it is fine (a test is not a compared path),
    // and its own ULP-level platform variance is exactly why the tolerance here
    // is a few ULP and the bit-exactness lives in the table instead.
    //
    // The sweep is oblique to the period on purpose. A sweep on multiples of
    // π/2 would only ever exercise the quadrant boundaries, where the reduced
    // argument is near zero and every implementation agrees.
    const step: f64 = 0.31830988618379067; // 1/π — never lands on a quadrant edge
    var i: u32 = 0;
    var worst: f64 = 0;
    while (i < 4096) : (i += 1) {
        const x = @as(f64, @floatFromInt(i)) * step;
        const got = cos(f64, x);
        const want = @cos(x);
        const err = @abs(got - want);
        if (err > worst) worst = err;
    }
    // Absolute error, which for a function bounded by 1 is the meaningful
    // grain. MEASURED on this sweep: `1.110e-16`, half the spacing of `f64` at
    // unity.
    //
    // That is a measured maximum and NOT a claim of correct rounding, which it
    // could not establish: the image of `cos` crosses zero, and near a zero the
    // correctly rounded result demands an absolute error orders of magnitude
    // below this one. The far-domain test below measures ~9.6 ULP on the same
    // function, which would contradict such a claim outright. And accuracy is
    // not the contract here — BINARY IDENTITY BETWEEN PLATFORMS is, and its
    // oracle is the committed value table, compared bit for bit. At 1e-15 on a
    // slope threshold this function is a dozen orders past what its one caller
    // needs.
    //
    // The bound is set at 4 ULP rather than at the measurement because `@cos`
    // is the oracle and its OWN answer moves by about an ULP between C
    // libraries: a bound at the measured value would fail on a platform where
    // the oracle drifted and the function did not.
    try testing.expect(worst < 8.9e-16);
}

test "cos: accuracy holds at the far end of the declared domain" {
    // The reduction is what degrades with magnitude, so the accuracy claim is
    // re-measured where it is weakest — just inside `max_argument`, where `|n|`
    // is at its `2^20` exactness limit. Without this the accuracy test above
    // would only ever have spoken for small arguments.
    const near_max: f64 = max_argument - 0.5;
    var i: u32 = 0;
    var worst: f64 = 0;
    while (i < 256) : (i += 1) {
        const x = near_max - @as(f64, @floatFromInt(i)) * 0.37;
        const err = @abs(cos(f64, x) - @cos(x));
        if (err > worst) worst = err;
    }
    // MEASURED: `2.123e-15`, ~9.6 ULP of unity — a factor 19 worse than at
    // small arguments, which is the reduction's cost showing up exactly where
    // the doc comment says it does and nowhere else. The bound keeps a ~5×
    // margin over it.
    try testing.expect(worst < 1.0e-14);
}

test "cos: f32 result is the f64 result narrowed, not a separate computation" {
    // Pins the widening discipline of the doc comment. If someone ever adds an
    // `f32` fast path, this test is what refuses it — and refuses it for the
    // right reason: two arithmetics for one function is two things to keep
    // bit-identical across four platforms.
    const probes = [_]f32{ 0.0, 0.125, 0.7853981, 1.0471975, 1.5707963, 3.1415927, 12345.678, 1.0e6 };
    for (probes) |p| {
        try testing.expectEqual(@as(f32, @floatCast(cos(f64, @as(f64, p)))), cos(f32, p));
    }
}

test "cos: quadrant selection is right at and around every boundary" {
    // Each of the four quadrants, entered from both sides of its edge, with the
    // reference values written as literals rather than derived from `@cos` —
    // an oracle that shares the arithmetic it judges agrees with it (workflow
    // §5.5). The tolerance is loose because the point is the QUADRANT, not the
    // last bit: a swapped `kernelSin`/`kernelCos` or a rotated `switch` moves
    // the answer by whole units, never by an ULP.
    const half_pi: f64 = 1.5707963267948966;
    const cases = [_]struct { x: f64, want: f64 }{
        .{ .x = 0.0, .want = 1.0 },
        .{ .x = half_pi, .want = 0.0 },
        .{ .x = 2.0 * half_pi, .want = -1.0 },
        .{ .x = 3.0 * half_pi, .want = 0.0 },
        .{ .x = 4.0 * half_pi, .want = 1.0 },
        .{ .x = 0.5 * half_pi, .want = 0.7071067811865476 },
        .{ .x = 1.5 * half_pi, .want = -0.7071067811865475 },
        .{ .x = 2.5 * half_pi, .want = -0.7071067811865477 },
        .{ .x = 3.5 * half_pi, .want = 0.7071067811865474 },
    };
    for (cases) |c| {
        errdefer std.debug.print("cos: quadrant case failed at x = {d}\n", .{c.x});
        try testing.expectApproxEqAbs(c.want, cos(f64, c.x), 1.0e-15);
    }
}

test "cos: the range stays in [-1, 1] across the whole declared domain" {
    // A polynomial evaluated outside the interval it was fitted on leaves the
    // range long before it starts returning NaN, so this is the cheap detector
    // for a reduction that has quietly stopped reducing.
    var i: u32 = 0;
    while (i < 20000) : (i += 1) {
        // A stride that is not a rational multiple of π/2, walked to the domain
        // edge, so the sweep visits every quadrant many times over.
        const x = @as(f64, @floatFromInt(i)) * 82.35496;
        try testing.expect(@abs(cos(f64, x)) <= 1.0);
    }
}

// --- P1-2: the committed bit table, and an oracle that is not `@cos` ---------
//
// WHY THIS EXISTS. The test above compares against `@cos`, and its own comment
// concedes what that can and cannot establish: it proves the function is STABLE,
// it cannot prove the function is a COSINE. Two implementations of the same wrong
// idea agree. M1.1.14's review named this: the milestone's first behavioural
// change was replacing `@cos` at the `max_slope` conversion, and nothing pinned
// the VALUE that replacement produces.
//
// THE ORACLE IS ARBITRARY-PRECISION AND EXTERNAL, and the recipe is here rather
// than the tool, because this repository is Zig and `tools/` holds Zig — the same
// arbitrage as the float-environment site list, and for the same reason: a reader
// who can RE-DERIVE does not have to trust.
//
//   1. pi to 80 digits by an alternating arctan series in exact decimal
//      arithmetic — no floating point anywhere on the value path.
//   2. pi computed TWICE by different Machin-like formulas and required to agree
//      to 70 digits: `16·atan(1/5) − 4·atan(1/239)` and
//      `20·atan(1/7) + 8·atan(3/79)`. Two independent computations forced onto one
//      number, the control this milestone credits above every other.
//      Both give 3.14159265358979323846264338327950288419716939937510...
//   3. Each argument taken as its EXACT binary value — the f32 row is the cosine
//      of the f32-rounding of the literal, not of the literal — reduced modulo
//      2·pi by an exact integer quotient, then the Taylor series for cosine.
//   4. The result rounded to the nearest representable value by comparing BOTH
//      neighbours explicitly. A single `float()` conversion would inherit that
//      conversion's rounding, and a Decimal → f64 → f32 path can double-round.
//
// TWO COLUMNS, TWO CLAIMS, AND THEY ARE NOT THE SAME CLAIM. `oracle` is the
// correctly-rounded true cosine and carries CORRECTNESS. `engine` is what this
// implementation emits and carries REPRODUCIBILITY — the change detector that must
// hold on all twelve CI cells. Presenting the second as evidence for the first is
// the defect family this milestone spent two sessions on, so it is said plainly:
// the `engine` column is self-generated and validates nothing about accuracy.
//
// THE BOUND IS ABSOLUTE AND NOT IN ULP, and that is a measurement rather than a
// preference. At the f64 nearest pi/2 the true cosine is 6.12e-17 — near-total
// cancellation — and the implementation's error there is 1.6e11 ULP of that value
// while being 2.0e-21 in ABSOLUTE terms, the SMALLEST absolute error in the whole
// table. A ULP bound would fail there, spectacularly, on the most accurate row.
// Cosine is bounded by one, so an absolute bound is its natural accuracy
// statement.
const CosCase = struct {
    x: f64,
    oracle_f32: u32,
    oracle_f64: u64,
    engine_f64: u64,
};

/// Twelve arguments, each present for a reason stated beside it.
///
/// At **f32 the implementation is correctly rounded on all twelve** — measured,
/// so `oracle_f32` doubles as the reproducibility column there and no separate
/// engine column exists for it. At f64 nine of twelve agree exactly and three do
/// not; those three are what make the correctness bound do real work rather than
/// restate an equality (asserted below).
const cos_cases = [_]CosCase{
    .{ .x = 0.0, .oracle_f32 = 0x3F800000, .oracle_f64 = 0x3FF0000000000000, .engine_f64 = 0x3FF0000000000000 }, // `nf = 0`: the three reduction steps vanish
    .{ .x = 0.785, .oracle_f32 = 0x3F351765, .oracle_f64 = 0x3FE6A2ECB934B59A, .engine_f64 = 0x3FE6A2ECB934B59A }, // THE ENGINE'S OWN VALUE — `CharacterDescriptor.max_slope`'s default
    .{ .x = 0.5, .oracle_f32 = 0x3F60A940, .oracle_f64 = 0x3FEC1528065B7D50, .engine_f64 = 0x3FEC1528065B7D50 }, // quadrant 0, `kernelCos`, argument exact in both formats
    .{ .x = 2.0, .oracle_f32 = 0xBED51133, .oracle_f64 = 0xBFDAA22657537205, .engine_f64 = 0xBFDAA22657537205 }, // quadrant 1, `-kernelSin`
    .{ .x = 3.5, .oracle_f32 = 0xBF6FBBA0, .oracle_f64 = 0xBFEDF77403C11A5F, .engine_f64 = 0xBFEDF77403C11A5F }, // quadrant 2, `-kernelCos`
    .{ .x = 5.0, .oracle_f32 = 0x3E913C2C, .oracle_f64 = 0x3FD22785706B4AD9, .engine_f64 = 0x3FD22785706B4ADA }, // quadrant 3, `kernelSin` — 0.17 eps off
    .{ .x = -0.785, .oracle_f32 = 0x3F351765, .oracle_f64 = 0x3FE6A2ECB934B59A, .engine_f64 = 0x3FE6A2ECB934B59A }, // the evenness fold: identical to `+0.785`
    .{ .x = 1.5707963267948966, .oracle_f32 = 0xB33BBD2E, .oracle_f64 = 0x3C91A62633145C07, .engine_f64 = 0x3C91A64C66245C07 }, // f64 nearest pi/2: near-total cancellation, 2.0e-21 absolute
    .{ .x = 0.7853981633974483, .oracle_f32 = 0x3F3504F3, .oracle_f64 = 0x3FE6A09E667F3BCD, .engine_f64 = 0x3FE6A09E667F3BCD }, // f64 nearest pi/4: the kernel boundary
    .{ .x = 1000.0, .oracle_f32 = 0x3F0FF813, .oracle_f64 = 0x3FE1FF026793F1BB, .engine_f64 = 0x3FE1FF026793F1BB }, // Cody-Waite over 636 quadrants
    .{ .x = 100000.0, .oracle_f32 = 0xBF7FD61C, .oracle_f64 = 0xBFEFFAC3841B3DA7, .engine_f64 = 0xBFEFFAC3841B3DA7 }, // Cody-Waite over 63661 quadrants
    .{ .x = 1647099.0, .oracle_f32 = 0x3F724189, .oracle_f64 = 0x3FEE4831257A62DA, .engine_f64 = 0x3FEE4831257A62D4 }, // the largest integer under `max_argument` — 3.14 eps, the worst row
};

/// Absolute error budget, in units of `floatEps(f64)`. Measured worst case 3.14,
/// at the argument nearest `max_argument`, where Cody-Waite has the least left to
/// work with. Four, so the bound is not a re-statement of the measurement — and
/// not forty, which would admit a real regression.
const cos_abs_budget: f64 = 4.0;

test "cos: the committed bit table — reproducibility, on every cell" {
    // THE DETERMINISM CLAIM, and the one whose failure on ONE of twelve CI cells is
    // the finding this milestone exists to produce. Bit equality, no tolerance: a
    // deterministic function either emits the same bits everywhere or it does not.
    for (cos_cases) |c| {
        const got32: u32 = @bitCast(cos(f32, @floatCast(c.x)));
        errdefer std.debug.print("cos: f32 bits moved at x = {d}\n", .{c.x});
        try testing.expectEqual(c.oracle_f32, got32);

        const got64: u64 = @bitCast(cos(f64, c.x));
        errdefer std.debug.print("cos: f64 bits moved at x = {d}\n", .{c.x});
        try testing.expectEqual(c.engine_f64, got64);
    }
}

test "cos: it really is a cosine — against an oracle that never calls @cos" {
    // THE CORRECTNESS CLAIM. The reference values come from exact decimal
    // arithmetic outside this repository (recipe above); nothing on their path
    // touched `@cos`, libm or Zig.
    const eps = std.math.floatEps(f64);
    for (cos_cases) |c| {
        const want: f64 = @bitCast(c.oracle_f64);
        const got = cos(f64, c.x);
        const err = @abs(got - want);
        errdefer std.debug.print(
            "cos: at x = {d} the error is {d} eps, over the {d} eps budget\n",
            .{ c.x, err / eps, cos_abs_budget },
        );
        try testing.expect(err <= cos_abs_budget * eps);
    }

    // At f32 the claim is STRONGER and is asserted as such: correctly rounded, all
    // twelve. That is why the table needs no separate f32 engine column — and if
    // this ever fails while the f64 rows hold, the narrowing has moved, not the
    // kernel.
    for (cos_cases) |c| {
        const want32: f32 = @bitCast(c.oracle_f32);
        try testing.expectEqual(want32, cos(f32, @floatCast(c.x)));
    }
}

test "cos: the correctness bound is not a restatement of the bit table" {
    // ANTI-VACUITY, and it is due: if `engine` equalled `oracle` on every row, the
    // absolute bound above would be satisfied by construction and would measure
    // nothing. It does not — three f64 rows differ, and the worst is 3.14 eps,
    // which is 78% of the budget. So the bound is load-bearing on this table.
    //
    // Written as a property of the TABLE rather than as a count, so adding a row
    // cannot silently make it vacuous: what is required is that some row exercise
    // the bound, and that the worst row use a real fraction of it.
    const eps = std.math.floatEps(f64);
    var differing: usize = 0;
    var worst: f64 = 0;
    for (cos_cases) |c| {
        if (c.oracle_f64 != c.engine_f64) differing += 1;
        const want: f64 = @bitCast(c.oracle_f64);
        const err = @abs(cos(f64, c.x) - want) / eps;
        if (err > worst) worst = err;
    }
    try testing.expect(differing >= 1);
    try testing.expect(worst > 1.0);
    try testing.expect(worst <= cos_abs_budget);
}
