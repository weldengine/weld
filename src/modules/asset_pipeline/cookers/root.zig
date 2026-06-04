//! Asset Pipeline `cookers/` namespace — intermediate → runtime `.<type>.bin`.
//!
//! Each cooker assembles the E1-frozen 40-byte header + a small metadata
//! section + the bulk payload. M0.6 payloads are raw (RGBA8 / f32 vertices /
//! PCM); compression and quantization are later phases.

/// Shared `.bin` assembly + cook `Error`.
pub const common = @import("common.zig");
/// Cook error set.
pub const Error = common.Error;

/// Cook a texture intermediate → `.texture.bin`.
pub const cookTexture = @import("texture.zig").cook;
/// Cook a mesh intermediate → `.mesh.bin`.
pub const cookMesh = @import("mesh.zig").cook;
/// Cook an audio intermediate → `.audio.bin`.
pub const cookAudio = @import("audio.zig").cook;

comptime {
    _ = common;
    _ = @import("texture.zig");
    _ = @import("mesh.zig");
    _ = @import("audio.zig");
}
