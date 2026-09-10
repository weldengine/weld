//! Audio module entry.
//!
//! Only the Dummy backend exists (cf. `engine-audio-pulse.md` §1.1); the
//! real ones (ALSA, WASAPI, PipeWire, PulseAudio, CoreAudio) do not, so
//! the entry point exposes the Dummy as the default and only choice.
//!
//! When the strategy selection from `weld.toml` arrives
//! (`audio = "alsa" | "wasapi" | "dummy" | …`), this file branches on
//! the resolved configuration and instantiates the matching backend behind
//! the same `AudioModule(Impl)` comptime wrapper.

const std = @import("std");

/// Audio Dummy backend module — the only backend that exists.
pub const dummy = @import("dummy.zig");

/// Voice handle issued by `Backend.play`. Stable across backends.
pub const VoiceId = dummy.VoiceId;
/// Audio asset reference (opaque u64, resolved by the loader).
pub const AssetHandle = dummy.AssetHandle;
/// Distance attenuation model (linear, inverse_distance, …).
pub const AttenuationModel = dummy.AttenuationModel;
/// Attenuation params (min/max distance, rolloff, …).
pub const AttenuationParams = dummy.AttenuationParams;
/// Three-component vector — matches the future `core.math.Vec3`.
pub const Vec3 = dummy.Vec3;
/// Entity identifier — placeholder until the audio module imports
/// `core/ecs` properly.
pub const EntityId = dummy.EntityId;

/// Default backend: Dummy. Once strategy selection exists, this alias
/// resolves to what `weld.toml` selects.
pub const Backend = dummy.Dummy;

comptime {
    // Pin dummy.zig so inline tests are picked up by `zig build test`.
    _ = dummy;
}
