//! Ordered lane reductions — the sanctioned form for FLOAT vectors, and the
//! reason `@reduce` may not be used on them.
//!
//! `ARCH-031` rule 3 fixes the reduction order of every float reduction on a
//! compared path, and `@reduce` does not carry it TODAY — not because the
//! builtin is underspecified, but because one of the two code generators Weld
//! builds with does not honour what it specifies.
//!
//! THE LANGUAGE IS ON OUR SIDE, and this was checked rather than assumed. The
//! langref's `@reduce` entry reads "performing a sequential horizontal reduction
//! of its elements", and: "when applied on floating point types the operation
//! associativity is preserved, unless the float mode is set to `Optimized`."
//! That is an order, stated. (Read at tag `0.15.2`; `0.16.0` carries no public
//! tag on `ziglang/zig`, so the exact 0.16 wording is not citable and this is
//! the nearest tagged text.)
//!
//! WHAT ONE BACKEND DOES WITH IT — measured at M1.1.14 by disassembling both at
//! `-mcpu=baseline`, `x86_64-linux`, on a 3-lane f32 `@reduce(.Add, …)` whose
//! product vector is `p`:
//!
//!   - LLVM (`stage2_llvm`), at BOTH `-O Debug` and `-O ReleaseSafe`:
//!     `movaps` seeds `p₀`, `shufps $0x55` brings `p₁`, `unpckhpd` brings `p₂`.
//!     That is `(p₀ + p₁) + p₂`.
//!   - The self-hosted backend (`stage2_x86_64`, which serves `x86_64-linux`
//!     in Debug): `movhlps` extracts `p₂`, `addss` adds `p₀`, `shufps $0x1`
//!     extracts `p₁`, `addss`. That is `p₁ + (p₂ + p₀)`.
//!
//! Float addition is not associative, so those are two different functions:
//! they disagree on 313816 of 1000000 random f32 triples in `[-50, 50]`
//! — 31.4%, by one ULP. In the determinism harness that showed up as the
//! continuous state diverging at frame 1 and amplifying to 2.53e-3 m by frame
//! 38 of a 60-frame window.
//!
//! `p₁ + (p₂ + p₀)` is neither sequential in lane order nor an
//! associativity-preserving rendering of the sequential fold, so it contradicts
//! both halves of the specified sentence. It is emitted identically under the
//! DEFAULT float mode and under an explicit `@setFloatMode(.strict)`, at `-O
//! Debug`, `ReleaseSafe` and `ReleaseFast` — instruction for instruction, all
//! six listings. **That is a Zig compiler defect, and it is owed upstream.**
//!
//! WHY THE FOLD SHIPS ANYWAY, and this is the whole point rather than a
//! consolation: bit-exactness must not rest on a compiler fix, including one
//! that arrives. A source-level fold is the same function under every backend,
//! every version and every float mode, and it stops being a question the day it
//! is written. `@reduce` would put the engine's determinism back under someone
//! else's release schedule.
//!
//! **ORDERED IS NOT THE PROPERTY.** `p₁ + (p₂ + p₀)` is perfectly ordered, and
//! it is not the total reduction (`faddv`, `haddps`) one would think to watch
//! for. The property is THE SAME ORDER EVERYWHERE, which only a fold written in
//! source can carry. A pair-wise instruction remains perfectly admissible when
//! it REALISES that source fold — `faddp` on AArch64 does — because adding two
//! lanes with one instruction is the same IEEE addition as adding them with two.
//! What is inadmissible is leaving the choice to the code generator.
//!
//! The f64 half of that measurement is the control, and it is why the harness
//! did not diverge at f64: there both backends produce `(p₀ + p₁) + p₂`, LLVM
//! by `mulpd`+`unpckhpd` and the self-hosted backend by a sequential `addsd`
//! loop over memory. Same order, same bits, 1000 frames — the agreement was an
//! accident of two independent choices, never a guarantee.
//!
//! These folds are ASCENDING BY LANE INDEX, left-associated. The order is
//! arbitrary in the sense that any fixed order would serve; it is not arbitrary
//! in the sense that it is now the engine's, and changing it invalidates every
//! committed determinism witness.
//!
//! `.Min` and `.Max` are here for a second reason on top of order: `@reduce`
//! leaves NaN propagation to the backend as well, whereas `@max`/`@min` are
//! specified by the language to return the non-NaN operand. A fold of `@max` is
//! therefore NaN-ignoring BY SPECIFICATION rather than by observed lowering —
//! which matters, because `triangleCross` depends on that behaviour to select
//! its tiers.
//!
//! Integer and boolean reductions are NOT covered and need no helper: integer
//! addition is associative and exact, and `.And`/`.Or`/`.Xor` are order-free.
//! `@reduce` stays the right tool there, and the lint rule `no_float_reduce`
//! recognises such a site by the `WELD_INTEGER_LANES` marker it must carry.

const std = @import("std");

/// The scalar a vector type's lanes hold.
fn Lane(comptime V: type) type {
    const info = @typeInfo(V);
    if (info != .vector) @compileError("expected a vector type, got " ++ @typeName(V));
    return info.vector.child;
}

/// How many lanes a vector type has.
fn lanes(comptime V: type) comptime_int {
    return @typeInfo(V).vector.len;
}

/// Compile-time refusal of anything but a float vector. These folds exist for
/// float determinism; an integer caller reaching them would pay a scalar chain
/// for an exactness it already had, and would hide from the lint rule the one
/// site where a reader should check the claim.
fn assertFloatVector(comptime V: type) void {
    const child = Lane(V);
    if (@typeInfo(child) != .float) {
        @compileError("foundation/math/reduce is for FLOAT vectors; " ++
            @typeName(child) ++ " lanes are exact under any order — use `@reduce` " ++
            "with a `WELD_INTEGER_LANES` marker");
    }
    if (lanes(V) == 0) @compileError("a zero-lane reduction has no value to return");
}

/// Sum of the lanes, folded left in ascending lane order: `((v₀ + v₁) + v₂) + …`.
pub fn foldAdd(v: anytype) Lane(@TypeOf(v)) {
    const V = @TypeOf(v);
    comptime assertFloatVector(V);
    var acc = v[0];
    comptime var i: usize = 1;
    inline while (i < lanes(V)) : (i += 1) acc += v[i];
    return acc;
}

/// Product of the lanes, folded left in ascending lane order: `((v₀ · v₁) · v₂) · …`.
pub fn foldMul(v: anytype) Lane(@TypeOf(v)) {
    const V = @TypeOf(v);
    comptime assertFloatVector(V);
    var acc = v[0];
    comptime var i: usize = 1;
    inline while (i < lanes(V)) : (i += 1) acc *= v[i];
    return acc;
}

/// Largest lane, folded left in ascending lane order. NaN lanes are IGNORED —
/// `@max` is specified to return the non-NaN operand — so the result is NaN only
/// if every lane is NaN.
pub fn foldMax(v: anytype) Lane(@TypeOf(v)) {
    const V = @TypeOf(v);
    comptime assertFloatVector(V);
    var acc = v[0];
    comptime var i: usize = 1;
    inline while (i < lanes(V)) : (i += 1) acc = @max(acc, v[i]);
    return acc;
}

/// Smallest lane, folded left in ascending lane order. NaN lanes are IGNORED,
/// mirror of `foldMax`.
pub fn foldMin(v: anytype) Lane(@TypeOf(v)) {
    const V = @TypeOf(v);
    comptime assertFloatVector(V);
    var acc = v[0];
    comptime var i: usize = 1;
    inline while (i < lanes(V)) : (i += 1) acc = @min(acc, v[i]);
    return acc;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "foldAdd is the left fold, and the test can tell the two orders apart" {
    // The discriminating triple: the two orders the two backends were measured
    // to emit disagree here by exactly one ULP. A test written on a triple where
    // they agree would pass against either implementation and prove nothing, so
    // the guard below asserts the triple discriminates BEFORE the claim is made.
    const p: @Vector(3, f32) = .{ -12.127813, 21.12078, -40.04462 };
    const left: f32 = (p[0] + p[1]) + p[2];
    const other: f32 = p[1] + (p[2] + p[0]);
    try std.testing.expect(@as(u32, @bitCast(left)) != @as(u32, @bitCast(other)));

    try std.testing.expectEqual(@as(u32, @bitCast(left)), @as(u32, @bitCast(foldAdd(p))));
}

test "foldAdd folds ascending for four lanes too" {
    // `1e17` has an ULP of 16 at f64, so a partial sum of 2 vanishes into it and
    // the two ones survive or not depending purely on WHEN they are added.
    // Left: ((1 + 1) + 1e17) − 1e17 = 0, the pair absorbed before the cancellation.
    // Right: 1 + (1 + (1e17 − 1e17)) = 2, the cancellation happening first.
    const p: @Vector(4, f64) = .{ 1.0, 1.0, 1e17, -1e17 };
    const expected: f64 = ((p[0] + p[1]) + p[2]) + p[3];
    const right: f64 = p[0] + (p[1] + (p[2] + p[3]));
    // Non-vacuity FIRST: a quadruple on which the two folds agree would pass
    // against a right-folding implementation and prove nothing. The first
    // quadruple written here was exactly that, and this guard is what caught it.
    try std.testing.expect(@as(u64, @bitCast(right)) != @as(u64, @bitCast(expected)));
    try std.testing.expectEqual(@as(f64, 0.0), expected);
    try std.testing.expectEqual(@as(f64, 2.0), right);

    try std.testing.expectEqual(
        @as(u64, @bitCast(expected)),
        @as(u64, @bitCast(foldAdd(p))),
    );
}

test "foldMul is the left fold, on a product that rounds" {
    const p: @Vector(3, f32) = .{ 1.0000001, 3.0000002, 7.0000005 };
    const left: f32 = (p[0] * p[1]) * p[2];
    try std.testing.expectEqual(@as(u32, @bitCast(left)), @as(u32, @bitCast(foldMul(p))));
}

test "foldMax and foldMin agree with the scalar answer" {
    const p: @Vector(4, f32) = .{ -3.5, 12.25, 0.0, -40.0 };
    try std.testing.expectEqual(@as(f32, 12.25), foldMax(p));
    try std.testing.expectEqual(@as(f32, -40.0), foldMin(p));
}

test "foldMax ignores NaN lanes unless every lane is NaN" {
    const nan = std.math.nan(f32);
    // The case `triangleCross` depends on: one lane NaN from `inf − inf`, the
    // other two finite and non-zero. The largest must be the finite maximum.
    const mixed: @Vector(3, f32) = .{ 2.81e14, nan, -2.81e14 };
    try std.testing.expectEqual(@as(f32, 2.81e14), foldMax(mixed));
    try std.testing.expectEqual(@as(f32, -2.81e14), foldMin(mixed));

    // A NaN in the FIRST lane seeds the accumulator, so this direction is the
    // one an implementation seeded with `v[0]` could get wrong.
    const leading: @Vector(3, f32) = .{ nan, 5.0, -5.0 };
    try std.testing.expectEqual(@as(f32, 5.0), foldMax(leading));
    try std.testing.expectEqual(@as(f32, -5.0), foldMin(leading));

    const all_nan: @Vector(3, f32) = .{ nan, nan, nan };
    try std.testing.expect(std.math.isNan(foldMax(all_nan)));
    try std.testing.expect(std.math.isNan(foldMin(all_nan)));
}

test "the folds are comptime-evaluable" {
    const p: @Vector(3, f64) = .{ 1.0, 2.0, 4.0 };
    const sum = comptime foldAdd(p);
    const prod = comptime foldMul(p);
    try std.testing.expectEqual(@as(f64, 7.0), sum);
    try std.testing.expectEqual(@as(f64, 8.0), prod);
}

test "a single-lane vector folds to its only lane" {
    const p: @Vector(1, f32) = .{-7.5};
    try std.testing.expectEqual(@as(f32, -7.5), foldAdd(p));
    try std.testing.expectEqual(@as(f32, -7.5), foldMul(p));
    try std.testing.expectEqual(@as(f32, -7.5), foldMax(p));
    try std.testing.expectEqual(@as(f32, -7.5), foldMin(p));
}
