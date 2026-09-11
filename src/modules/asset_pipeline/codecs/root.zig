//! Asset Pipeline `codecs/` namespace — low-level encode/decode.
//!
//! `deflate`, plus PNG and static-glTF decode.

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
