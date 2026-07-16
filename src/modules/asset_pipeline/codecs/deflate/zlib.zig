//! zlib (RFC 1950) wrapper around the RFC 1951 inflate.
//!
//! Parses the 2-byte zlib header, inflates the DEFLATE body, and verifies
//! the 4-byte big-endian ADLER32 trailer using the `foundation/simd`
//! `adler32` kernel — the first real consumer of that kernel.

const std = @import("std");
const inflate_mod = @import("inflate.zig");
const simd = @import("foundation").simd;

/// Errors raised by `decompress` (inflate errors plus the zlib-frame ones).
pub const Error = inflate_mod.Error || error{
    /// Header too short, bad compression method, bad window size, failed
    /// header checksum, or an unsupported preset dictionary.
    BadZlibHeader,
    /// The decoded data's ADLER32 did not match the stored trailer.
    BadChecksum,
};

/// Decompress a zlib stream into a freshly allocated, caller-owned slice.
/// Validates the header and the ADLER32 trailer. `max_out` bounds the inflated
/// size (R3, M1.1.1-HF3): production beyond it is `error.OutputLimitExceeded`
/// and the buffer never exceeds it — the decompression-bomb guard. The caller
/// supplies the exact expected size (the PNG codec derives it from IHDR).
pub fn decompress(gpa: std.mem.Allocator, src: []const u8, max_out: usize) Error![]u8 {
    if (src.len < 6) return error.BadZlibHeader; // 2 header + ≥0 body + 4 trailer
    const cmf = src[0];
    const flg = src[1];
    if ((cmf & 0x0f) != 8) return error.BadZlibHeader; // CM must be 8 (deflate)
    if ((cmf >> 4) > 7) return error.BadZlibHeader; // CINFO: window ≤ 32 KiB
    if (((@as(u16, cmf) << 8) | flg) % 31 != 0) return error.BadZlibHeader; // FCHECK
    if ((flg & 0x20) != 0) return error.BadZlibHeader; // FDICT unsupported in M0.6

    const body = src[2 .. src.len - 4];
    const out = try inflate_mod.inflate(gpa, body, max_out);
    errdefer gpa.free(out);

    const stored = std.mem.readInt(u32, src[src.len - 4 ..][0..4], .big);
    if (simd.adler32(out) != stored) return error.BadChecksum;
    return out;
}
