//! Asset Pipeline `codecs/` namespace — low-level encode/decode.
//!
//! M0.6 ships `deflate` (E2). PNG and glTF static decode land in E3.

/// DEFLATE / zlib codec.
pub const deflate = @import("deflate/root.zig");

comptime {
    _ = deflate;
}
