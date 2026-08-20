//! Minimal reproducer — `stage2_x86_64` does not honour the specified order of
//! a floating-point `@reduce`. Prepared at M1.1.14, NOT yet filed upstream.
//!
//! The langref states that `@reduce` performs "a sequential horizontal reduction
//! of its elements", and that on floating point types "the operation
//! associativity is preserved, unless the float mode is set to `Optimized`".
//! The sequential fold of a 3-lane vector is `(v₀ + v₁) + v₂`.
//!
//! Build both ways and disassemble `probe`:
//!
//!   zig build-obj repro.zig -target x86_64-linux-gnu -mcpu=baseline -O Debug -fllvm
//!   zig build-obj repro.zig -target x86_64-linux-gnu -mcpu=baseline -O Debug -fno-llvm
//!
//! LLVM emits `(v₀ + v₁) + v₂`:
//!   movaps seeds v₀ ; shufps $0x55 → v₁ ; addss ; unpckhpd → v₂ ; addss
//!
//! `stage2_x86_64` emits `v₁ + (v₂ + v₀)`:
//!   movhlps → v₂ ; addss v₀ ; shufps $0x1 → v₁ ; addss
//!
//! That is a permutation AND a reassociation, so it contradicts both halves of
//! the specified sentence. Identical output under the default float mode and
//! under the explicit `@setFloatMode(.strict)` below, at `-O Debug`,
//! `ReleaseSafe` and `ReleaseFast` — six listings, instruction for instruction.
//!
//! Observable consequence, since float addition is not associative: the two
//! orders disagree on 313816 of 1000000 random f32 triples drawn uniformly from
//! `[-50, 50]`, by one ULP. First witness `(-12.127813, 21.12078, -40.04462)`:
//! `(v₀+v₁)+v₂` = `0xC1F869C9`, `v₁+(v₂+v₀)` = `0xC1F869C8`.
//!
//! Measured with Zig 0.16.0 on an `aarch64-macos` host, cross-compiling.

/// The reduction under test. `@setFloatMode(.strict)` is explicit so the
/// specified "unless Optimized" escape cannot account for the difference.
export fn probe(a: *const [3]f32, b: *const [3]f32) f32 {
    @setFloatMode(.strict);
    const va: @Vector(3, f32) = a.*;
    const vb: @Vector(3, f32) = b.*;
    return @reduce(.Add, va * vb);
}

/// The sequential fold the language specifies, for comparison in the same object.
export fn expected(a: *const [3]f32, b: *const [3]f32) f32 {
    @setFloatMode(.strict);
    const p: @Vector(3, f32) = @as(@Vector(3, f32), a.*) * @as(@Vector(3, f32), b.*);
    return (p[0] + p[1]) + p[2];
}
