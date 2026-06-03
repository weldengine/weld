//! Cross-variant correctness harness (engine-simd.md §6).
//!
//! Every kernel variant available for the current target must produce
//! bit-identical output to the scalar reference. M0.6 has only the portable
//! `@Vector` variant (no ISA asm), so this compares the dispatched entry
//! point and the explicit portable variant against the reference. When arch
//! variants land, they are added to the comparison list here and validated
//! by the same corpus.

const std = @import("std");
const simd = @import("foundation").simd;

const reference = simd.kernels.adler32.reference;

test "every available adler32 variant matches the scalar reference" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    const sizes = [_]usize{ 0, 1, 3, 16, 17, 64, 4096, 5552, 12_345 };
    for (sizes) |n| {
        const buf = try gpa.alloc(u8, n);
        defer gpa.free(buf);
        rand.bytes(buf);
        const want = reference(buf);
        // Variants available for the current target.
        try std.testing.expectEqual(want, simd.adler32(buf)); // dispatched
        try std.testing.expectEqual(want, simd.portable.adler32(buf)); // explicit portable
    }
}
