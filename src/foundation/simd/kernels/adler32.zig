//! ADLER32 checksum — the inaugural `foundation/simd` kernel.
//!
//! Two implementations live here:
//! - `reference` — the simplest correct scalar form (mod every byte). It is
//!   the ground-truth oracle the portable path is validated against.
//! - `vectorized` — a portable `@Vector` form using the standard
//!   weighted-sum decomposition over NMAX-bounded blocks.
//!
//! Per the brief (§Notes — inaugural SIMD kernels): `@Vector` plus a scalar
//! reference, **no ISA-specific asm**, **no zlib-ng parity chasing**. The
//! point is to validate the `foundation/simd` infrastructure (scalar-vs-
//! `@Vector` test pattern, dispatch layering), not to be fast — ADLER32 runs
//! once at cook time, never on a runtime hot path.

const std = @import("std");

/// Largest prime smaller than 65536; the ADLER32 modulus.
pub const base: u32 = 65521;

/// Block length between modulo reductions. 5552 is the classic ADLER32
/// bound: the largest `n` for which `255*n*(n+1)/2 + (n+1)*(base-1)` stays
/// within a 32-bit accumulator. It is conservative for the u64 intermediates
/// used here (they would not overflow until far larger `n`); keeping 5552
/// matches every reference implementation and the scalar `reference`.
pub const nmax: usize = 5552;

/// Scalar reference implementation — the correctness oracle. Computes
/// ADLER32 of `data`, taking the modulo after every byte.
pub fn reference(data: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (data) |byte| {
        s1 = (s1 + byte) % base;
        s2 = (s2 + s1) % base;
    }
    return (s2 << 16) | s1;
}

/// Portable `@Vector` implementation. Splits `data` into NMAX-bounded
/// blocks and, per block, computes `Σ D[j]` and `Σ j·D[j]` with vector
/// horizontal reductions, then folds them into the running `(s1, s2)` via
/// the closed form `s2' = s2 + n·s1 + (n·ΣD − Σj·D)`.
pub fn vectorized(data: []const u8) u32 {
    const vlen = 16;
    const Vu32 = @Vector(vlen, u32);
    const lanes: Vu32 = std.simd.iota(u32, vlen);

    var s1: u32 = 1;
    var s2: u32 = 0;

    var pos: usize = 0;
    while (pos < data.len) {
        const block_len = @min(data.len - pos, nmax);
        const block = data[pos .. pos + block_len];

        var sum_d: u64 = 0; // Σ D[j] over the block
        var sum_jd: u64 = 0; // Σ j·D[j], j the block-local index

        var i: usize = 0;
        while (i + vlen <= block_len) : (i += vlen) {
            const bytes: @Vector(vlen, u8) = block[i..][0..vlen].*;
            const widened: Vu32 = bytes; // element-wise u8 → u32 widening
            const chunk_sum: u32 = @reduce(.Add, widened);
            const lane_weighted: u32 = @reduce(.Add, widened * lanes);
            // Global index j = i + lane, so Σ j·D = i·ΣD_chunk + Σ lane·D_chunk.
            sum_d += chunk_sum;
            sum_jd += @as(u64, i) * chunk_sum + lane_weighted;
        }
        while (i < block_len) : (i += 1) {
            const d = block[i];
            sum_d += d;
            sum_jd += @as(u64, i) * d;
        }

        const n: u64 = block_len;
        const a: u64 = s1;
        // b_final = b + n·a + Σ (n − j)·D[j] = b + n·a + (n·ΣD − Σj·D).
        const b_next: u64 = s2 + n * a + (n * sum_d - sum_jd);
        s1 = @intCast((a + sum_d) % base);
        s2 = @intCast(b_next % base);

        pos += block_len;
    }

    return (s2 << 16) | s1;
}

test "vectorized adler32 equals the scalar reference on assorted sizes" {
    const gpa = std.testing.allocator;
    // Edge sizes around the NMAX block boundary and the VLEN stride.
    const sizes = [_]usize{ 0, 1, 2, 15, 16, 17, 31, 32, 33, 255, 5551, 5552, 5553, 11104, 65535 };
    var prng = std.Random.DefaultPrng.init(0xA51E32);
    const rand = prng.random();
    for (sizes) |n| {
        const buf = try gpa.alloc(u8, n);
        defer gpa.free(buf);
        rand.bytes(buf);
        try std.testing.expectEqual(reference(buf), vectorized(buf));
    }
}
