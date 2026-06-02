//! Audio module entry — Phase 0.3 / M0.3.
//!
//! Phase 0 ships only the Dummy backend (cf. `engine-audio-pulse.md` §1.1).
//! Real backends (ALSA, WASAPI, PipeWire, PulseAudio, CoreAudio) land in
//! Phase 1. Until then, the entry-point exposes the Dummy as the default
//! and only choice.
//!
//! When Phase 1 introduces the strategy selection from `weld.toml`
//! (`audio = "alsa" | "wasapi" | "dummy" | …`), this file will branch on
//! the resolved configuration and instantiate the matching backend behind
//! the same `AudioModule(Impl)` comptime wrapper.

const std = @import("std");

/// Audio Dummy backend module — the only backend shipped in Phase 0.
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
/// `core/ecs` properly (deferred to Phase 1).
pub const EntityId = dummy.EntityId;

/// Default backend Phase 0 = Dummy. Phase 1 onward, this alias resolves
/// to the strategy selected in `weld.toml`.
pub const Backend = dummy.Dummy;

comptime {
    // Pin dummy.zig so inline tests are picked up by `zig build test`.
    _ = dummy;
}
