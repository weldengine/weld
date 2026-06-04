//! Asset Pipeline `importers/` namespace — source → intermediate.
//!
//! Each importer decodes a source file (via the E3 codecs) and produces an
//! `Import` = intermediate `AssetDoc` + referenced binary blob. M0.6: PNG
//! (texture), glTF (static mesh), WAV (audio).

/// Shared importer output (`Import` = document arena + blob).
pub const common = @import("common.zig");
/// `Import` result type.
pub const Import = common.Import;

/// PNG importer (→ `Texture2D`).
pub const png = @import("png.zig");
/// glTF importer (→ `StaticMesh`).
pub const gltf = @import("gltf.zig");
/// WAV importer + RIFF PCM decode (→ `AudioClip`).
pub const wav = @import("wav.zig");

comptime {
    _ = common;
    _ = png;
    _ = gltf;
    _ = wav;
}
