//! DEFLATE / zlib codec namespace (`codecs/deflate/`).
//!
//! Native in-tree RFC 1951 inflate + RFC 1950 zlib wrapper. Decode-only in
//! M0.6; consumed by the PNG codec (E3) and, later, EXR.

const inflate_mod = @import("inflate.zig");

/// Inflate a raw DEFLATE (RFC 1951) stream → caller-owned slice.
pub const inflate = inflate_mod.inflate;
/// Error set raised by `inflate`.
pub const InflateError = inflate_mod.Error;

/// zlib (RFC 1950) wrapper: header parse + inflate + ADLER32 trailer check.
pub const zlib = @import("zlib.zig");

comptime {
    _ = inflate_mod;
    _ = zlib;
}
