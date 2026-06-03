//! Paeth-filter-decode kernel tests (brief §Acceptance ▸ Tests:
//! `test "paeth portable equals reference"`).

const std = @import("std");
const simd = @import("foundation").simd;

const reference = simd.kernels.paeth.reference;
const vectorized = simd.kernels.paeth.vectorized;

test "paeth portable equals reference" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9AE7_4FED);
    const rand = prng.random();

    const bpps = [_]u8{ 1, 2, 3, 4 };
    const widths = [_]usize{ 1, 3, 4, 7, 16, 100 };
    for (bpps) |bpp| {
        for (widths) |w| {
            const n = w * bpp;
            const prev = try gpa.alloc(u8, n);
            defer gpa.free(prev);
            rand.bytes(prev);

            const ref_buf = try gpa.alloc(u8, n);
            defer gpa.free(ref_buf);
            rand.bytes(ref_buf);
            const vec_buf = try gpa.dupe(u8, ref_buf);
            defer gpa.free(vec_buf);
            const pub_buf = try gpa.dupe(u8, ref_buf);
            defer gpa.free(pub_buf);

            reference(prev, ref_buf, bpp);
            vectorized(prev, vec_buf, bpp);
            simd.paeth_filter_decode(prev, pub_buf, bpp); // dispatched public entry

            try std.testing.expectEqualSlices(u8, ref_buf, vec_buf);
            try std.testing.expectEqualSlices(u8, ref_buf, pub_buf);
        }
    }
}

test "paeth unfilters a known scanline (bpp=1)" {
    // First row has an all-zero previous scanline, so Paeth reduces to Sub:
    // curr[i] += curr[i-1] (predictor picks a=left when b=c=0).
    const zero_prev = [_]u8{ 0, 0, 0, 0 };
    var curr = [_]u8{ 5, 1, 1, 1 }; // filtered deltas
    reference(&zero_prev, &curr, 1);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, &curr);
}
