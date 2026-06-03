//! Asset Pipeline `importers/` namespace.
//!
//! M0.6 / E3 ships the WAV decoder here (RIFF is trivial, brief §Notes). The
//! png / gltf source→intermediate import orchestration lands in E4.

/// WAV (RIFF PCM) decode.
pub const wav = @import("wav.zig");

comptime {
    _ = wav;
}
