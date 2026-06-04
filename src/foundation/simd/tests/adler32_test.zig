//! ADLER32 kernel tests (brief §Acceptance ▸ Tests).
//!
//! - `test "adler32 portable equals reference"` — the dispatched `@Vector`
//!   path matches the scalar oracle on a large, varied corpus.
//! - `test "adler32 known vectors"` — both paths match published ADLER32
//!   values, pinning the kernel to the RFC 1950 definition (not just to
//!   internal self-consistency).

const std = @import("std");
const simd = @import("foundation").simd;

const reference = simd.kernels.adler32.reference;
const vectorized = simd.kernels.adler32.vectorized;

test "adler32 portable equals reference" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0AD1E32);
    const rand = prng.random();

    // Span several NMAX blocks plus odd tails to exercise the block seam and
    // the scalar tail of the vector loop.
    const sizes = [_]usize{ 0, 1, 7, 16, 100, 5552, 5553, 16_384, 100_000 };
    for (sizes) |n| {
        const buf = try gpa.alloc(u8, n);
        defer gpa.free(buf);
        rand.bytes(buf);
        const want = reference(buf);
        try std.testing.expectEqual(want, vectorized(buf));
        // The public dispatched entry point must agree too.
        try std.testing.expectEqual(want, simd.adler32(buf));
    }
}

test "adler32 known vectors" {
    const Case = struct { in: []const u8, want: u32 };
    const cases = [_]Case{
        .{ .in = "", .want = 0x0000_0001 },
        .{ .in = "a", .want = 0x0062_0062 },
        .{ .in = "abc", .want = 0x024D_0127 },
        .{ .in = "Wikipedia", .want = 0x11E6_0398 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, reference(c.in));
        try std.testing.expectEqual(c.want, vectorized(c.in));
        try std.testing.expectEqual(c.want, simd.adler32(c.in));
    }
}
