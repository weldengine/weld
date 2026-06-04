//! PNG Paeth-filter decode — the second `foundation/simd` kernel.
//!
//! Unfilters one PNG Paeth (filter type 4) scanline in place:
//! `curr[i] += PaethPredictor(curr[i-bpp], prev[i], prev[i-bpp])`, with bytes
//! before the start of a scanline treated as zero. `prev` is the
//! already-unfiltered previous scanline (all zeros for the first row);
//! `prev.len == curr.len`.
//!
//! Same discipline as `adler32` (brief §Notes — inaugural SIMD kernels):
//! scalar `reference` oracle + portable `@Vector` `vectorized`, **no
//! ISA-specific asm**, baseline only. The Paeth recurrence is sequential
//! along pixels (each pixel's left neighbour is a just-computed output), so
//! the `@Vector` form parallelizes across the `bpp` channels of one pixel,
//! not across pixels. Purpose: validate the multi-kernel dispatch pattern,
//! not performance (decode runs once at cook time).

const std = @import("std");

/// Scalar reference — the correctness oracle. Unfilters one Paeth scanline.
pub fn reference(prev: []const u8, curr: []u8, bpp: u8) void {
    var i: usize = 0;
    while (i < curr.len) : (i += 1) {
        const a: u8 = if (i >= bpp) curr[i - bpp] else 0;
        const b: u8 = if (i < prev.len) prev[i] else 0;
        const c: u8 = if (i >= bpp and i - bpp < prev.len) prev[i - bpp] else 0;
        curr[i] +%= predictor(a, b, c);
    }
}

/// Portable `@Vector` form — parallelizes the `bpp` channels of each pixel.
/// Falls back to `reference` for `bpp` outside 1..4 (M0.6 never exceeds 4).
pub fn vectorized(prev: []const u8, curr: []u8, bpp: u8) void {
    std.debug.assert(prev.len == curr.len);
    switch (bpp) {
        1 => vectorizedImpl(1, prev, curr),
        2 => vectorizedImpl(2, prev, curr),
        3 => vectorizedImpl(3, prev, curr),
        4 => vectorizedImpl(4, prev, curr),
        else => reference(prev, curr, bpp),
    }
}

fn vectorizedImpl(comptime bpp: usize, prev: []const u8, curr: []u8) void {
    const V = @Vector(bpp, i16);
    const n_px = curr.len / bpp;
    var a: V = @splat(0); // left pixel (already-unfiltered current scanline)
    var c: V = @splat(0); // up-left pixel (previous scanline)
    var px: usize = 0;
    while (px < n_px) : (px += 1) {
        const off = px * bpp;
        const b: V = load(bpp, prev[off..][0..bpp]);
        const cur: V = load(bpp, curr[off..][0..bpp]);
        const res = cur + paethVec(bpp, a, b, c);
        const masked = res & @as(V, @splat(0xff));
        store(bpp, curr[off..][0..bpp], masked);
        a = masked; // this pixel's unfiltered value becomes the next left
        c = b;
    }
    // Valid PNG scanlines are an exact multiple of bpp; nothing trails.
    std.debug.assert(n_px * bpp == curr.len);
}

fn load(comptime bpp: usize, src: *const [bpp]u8) @Vector(bpp, i16) {
    const bytes: @Vector(bpp, u8) = src.*;
    return bytes; // element-wise u8 → i16 widening
}

fn store(comptime bpp: usize, dst: *[bpp]u8, v: @Vector(bpp, i16)) void {
    const bytes: @Vector(bpp, u8) = @intCast(v);
    dst.* = bytes;
}

fn paethVec(comptime bpp: usize, a: @Vector(bpp, i16), b: @Vector(bpp, i16), c: @Vector(bpp, i16)) @Vector(bpp, i16) {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    const false_vec: @Vector(bpp, bool) = @splat(false);
    // pick_a = (pa <= pb) AND (pa <= pc), expressed via @select to avoid
    // relying on bool-vector bitwise ops.
    const pick_a = @select(bool, pa <= pb, pa <= pc, false_vec);
    const bc = @select(i16, pb <= pc, b, c);
    return @select(i16, pick_a, a, bc);
}

fn predictor(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "vectorized paeth equals the scalar reference on assorted bpp/widths" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9AE74);
    const rand = prng.random();
    const bpps = [_]u8{ 1, 2, 3, 4 };
    const widths = [_]usize{ 1, 2, 5, 8, 13, 64 };
    for (bpps) |bpp| {
        for (widths) |w| {
            const n = w * bpp;
            const prev = try gpa.alloc(u8, n);
            defer gpa.free(prev);
            const a = try gpa.alloc(u8, n);
            defer gpa.free(a);
            rand.bytes(prev);
            rand.bytes(a);
            const b = try gpa.dupe(u8, a);
            defer gpa.free(b);
            reference(prev, a, bpp);
            vectorized(prev, b, bpp);
            try std.testing.expectEqualSlices(u8, a, b);
        }
    }
}
