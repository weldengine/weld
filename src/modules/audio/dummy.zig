//! Audio Dummy backend — no-op implementation of the Tier 0 `AudioModule`
//! interface (`engine-tier-interfaces.md` §2).
//!
//! Phase 0.3 / M0.3 deliverable. Cohérent avec `engine-audio-pulse.md`
//! §1.1 — Dummy = backend #1 in the implementation order, ~50 lines. The
//! real backends (WASAPI / PipeWire / PulseAudio / ALSA / CoreAudio) land
//! in Phase 1 (cf. `engine-phase-1-criteria.md` C1.3).
//!
//! Purpose: unblock CI headless tests for modules that will consume audio
//! in Phase 1+ (Sequencer, VFX, AI). The Dummy returns plausible neutral
//! values from every API entry point, never touches real audio hardware,
//! and never allocates beyond the small `Dummy` struct itself.
//!
//! ## Interface contract
//!
//! The `AudioModule(Impl)` comptime interface lives in
//! `engine-tier-interfaces.md` §2. M0.3 ships only the Dummy implementation;
//! the formal `AudioModule(Impl)` comptime wrapper is constructed in Phase 1
//! when the first real backend (ALSA) arrives. Until then, callers consume
//! Dummy directly via `@import("modules/audio/dummy.zig")`.

const std = @import("std");

/// Opaque handle for a playing voice. The Dummy hands out monotonically
/// increasing IDs; never recycles.
pub const VoiceId = u32;

/// Audio asset reference. The Dummy never inspects the value.
pub const AssetHandle = u64;

/// Attenuation model — kept for API parity with the real backends.
pub const AttenuationModel = enum {
    inverse_distance,
    linear,
    logarithmic,
    custom,
};

/// Attenuation parameters — kept for API parity with the real backends.
pub const AttenuationParams = struct {
    model: AttenuationModel = .inverse_distance,
    min_distance: f32 = 1.0,
    max_distance: f32 = 100.0,
    rolloff: f32 = 1.0,
};

/// Three-component vector. Matches the future `core.math.Vec3` layout
/// (extern struct of f32) so call sites won't have to translate.
pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

/// EntityId placeholder — the real type lives in `core/ecs`. Kept as
/// `u64` here to avoid a tight import dependency from the audio module
/// back into the ECS during early Phase 0.
pub const EntityId = u64;

/// The Dummy backend itself. Held by the `AudioModule` wrapper or
/// consumed directly. Zero runtime state beyond the monotonic counter.
pub const Dummy = struct {
    next_voice_id: VoiceId = 1,

    /// Construct. Does nothing — no allocation, no OS handles.
    pub fn init() Dummy {
        return .{};
    }

    /// Tear down. No-op.
    pub fn deinit(self: *Dummy) void {
        self.* = undefined;
    }

    /// Per-frame update — no-op.
    pub fn update(self: *Dummy) void {
        _ = self;
    }

    // ----------- Playback ---------------------------------------------

    /// Start playing `clip` for `entity` on `bus`. Returns a fresh
    /// VoiceId; the Dummy never reaches a real device.
    pub fn play(self: *Dummy, entity: EntityId, clip: AssetHandle, bus: []const u8) VoiceId {
        _ = .{ entity, clip, bus };
        const id = self.next_voice_id;
        self.next_voice_id += 1;
        return id;
    }

    pub fn stop(self: *Dummy, voice: VoiceId) void {
        _ = .{ self, voice };
    }

    pub fn stopAll(self: *Dummy, entity: EntityId) void {
        _ = .{ self, entity };
    }

    pub fn setVolume(self: *Dummy, voice: VoiceId, volume: f32) void {
        _ = .{ self, voice, volume };
    }

    pub fn setPitch(self: *Dummy, voice: VoiceId, pitch: f32) void {
        _ = .{ self, voice, pitch };
    }

    pub fn setPause(self: *Dummy, voice: VoiceId, paused: bool) void {
        _ = .{ self, voice, paused };
    }

    // ----------- Listener ----------------------------------------------

    pub fn setListenerTransform(self: *Dummy, position: Vec3, forward: Vec3, up: Vec3) void {
        _ = .{ self, position, forward, up };
    }

    // ----------- Bus ---------------------------------------------------

    pub fn setBusVolume(self: *Dummy, bus: []const u8, volume: f32) void {
        _ = .{ self, bus, volume };
    }

    pub fn setBusMute(self: *Dummy, bus: []const u8, muted: bool) void {
        _ = .{ self, bus, muted };
    }

    // ----------- Spatialisation ----------------------------------------

    pub fn setSourceTransform(self: *Dummy, voice: VoiceId, position: Vec3) void {
        _ = .{ self, voice, position };
    }

    pub fn setAttenuation(self: *Dummy, voice: VoiceId, params: AttenuationParams) void {
        _ = .{ self, voice, params };
    }
};

test "audio.Dummy: init / play / stop / deinit cycle" {
    var d = Dummy.init();
    defer d.deinit();

    const v1 = d.play(42, 0xCAFE, "sfx");
    const v2 = d.play(42, 0xBEEF, "music");
    try std.testing.expect(v1 != v2);
    try std.testing.expect(v1 > 0);

    d.stop(v1);
    d.stopAll(42);

    d.setVolume(v2, 0.5);
    d.setPitch(v2, 1.2);
    d.setPause(v2, true);

    d.setListenerTransform(.{}, .{ .z = -1 }, .{ .y = 1 });
    d.setBusVolume("master", -3.0);
    d.setBusMute("ambient", false);
    d.setSourceTransform(v2, .{ .x = 10 });
    d.setAttenuation(v2, .{});

    d.update();
}
