//! glTF static-mesh decode codec namespace (`codecs/gltf/`).
//!
//! Native in-tree glTF 2.0 static decode (JSON via `std.json`). Static
//! Geometry only — no skinning, animation or morph.

const decode_mod = @import("decode.zig");

/// Decode a glTF 2.0 document into a static `Mesh`.
pub const decode = decode_mod.decode;
/// Decoded static mesh.
pub const Mesh = decode_mod.Mesh;
/// Error set raised by `decode`.
pub const Error = decode_mod.Error;

comptime {
    _ = decode_mod;
}
