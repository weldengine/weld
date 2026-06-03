//! Asset Pipeline `codecs/` namespace — low-level encode/decode.
//!
//! M0.6 ships `deflate` (E2). PNG and glTF static decode land in E3.

/// DEFLATE / zlib codec.
pub const deflate = @import("deflate/root.zig");

/// PNG → RGBA8 decode codec.
pub const png = @import("png/root.zig");

/// glTF 2.0 static-mesh decode codec.
pub const gltf = @import("gltf/root.zig");

comptime {
    _ = deflate;
    _ = png;
    _ = gltf;
}
