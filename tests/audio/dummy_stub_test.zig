//! Tests M0.3 — Audio Dummy stub round-trip.
//!
//! Covers the acceptance test from the M0.3 brief:
//!   - "Dummy backend init/deinit + play_sound + stop" — init backend,
//!     play_sound returns valid VoiceId, stop with that VoiceId without
//!     crash, deinit clean.

const std = @import("std");
const weld_audio = @import("weld_audio");

test "Dummy backend init/deinit + play_sound + stop" {
    var d = weld_audio.Backend.init();
    defer d.deinit();

    // play returns a valid (non-zero) VoiceId.
    const voice = d.play(@as(u64, 1234), @as(u64, 0xCAFE_BABE), "sfx");
    try std.testing.expect(voice > 0);

    // Subsequent operations on that VoiceId do not crash.
    d.setVolume(voice, 0.8);
    d.setPitch(voice, 1.5);
    d.setPause(voice, false);
    d.stop(voice);

    // Stop with a never-issued VoiceId should also not crash.
    d.stop(99_999);

    // Bus / spatial / listener operations.
    d.setBusVolume("master", 0.0);
    d.setBusMute("music", true);
    d.setListenerTransform(.{}, .{ .z = -1 }, .{ .y = 1 });
    d.setSourceTransform(voice, .{ .x = 10, .y = 0, .z = 0 });
    d.setAttenuation(voice, .{});

    // Update + stopAll for an entity that may or may not have voices.
    d.update();
    d.stopAll(1234);
}

test "Dummy backend: VoiceId monotonically increases per play" {
    var d = weld_audio.Backend.init();
    defer d.deinit();

    const v1 = d.play(1, 0, "sfx");
    const v2 = d.play(1, 0, "sfx");
    const v3 = d.play(2, 0, "music");

    try std.testing.expect(v1 < v2);
    try std.testing.expect(v2 < v3);
}
