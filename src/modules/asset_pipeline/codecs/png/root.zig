//! PNG decode codec namespace (`codecs/png/`).
//!
//! Native in-tree PNG → RGBA8 decoder. Decode-only in M0.6 (no encoder).

const decode_mod = @import("decode.zig");

/// Decode a PNG file to an RGBA8 `Image`.
pub const decode = decode_mod.decode;
/// Decoded RGBA8 image.
pub const Image = decode_mod.Image;
/// Error set raised by `decode`.
pub const Error = decode_mod.Error;

comptime {
    _ = decode_mod;
}
