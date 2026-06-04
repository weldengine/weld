//! M0.6 / E4 — WAV import → cook → load round-trip (brief §Acceptance).

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const tone_wav = @embedFile("data/tone.wav");

test "wav import-cook-load round-trip" {
    const gpa = std.testing.allocator;

    // Oracle: the E3 RIFF PCM decoder.
    var audio = try assets.importers.wav.decode(gpa, tone_wav);
    defer audio.deinit(gpa);

    // Import → cook.
    var imp = try assets.importers.wav.import(gpa, "tone.wav", tone_wav, "0190b3f0-1c2d-7e4a-8b6c-665544332211");
    defer imp.deinit(gpa);
    try std.testing.expectEqualStrings("AudioClip", imp.doc.type_name);
    try std.testing.expectEqualStrings("0190b3f0-1c2d-7e4a-8b6c-665544332211", imp.doc.uuid);

    const bin = try assets.cookers.cookAudio(gpa, imp.doc, imp.blob);
    defer gpa.free(bin);

    // Load: header + metadata (sample rate, channels, bits) + PCM payload.
    const header = try assets.RuntimeHeader.read(bin);
    try std.testing.expectEqual(assets.AssetType.audio, header.assetType().?);

    const meta = bin[header.metadata_offset..][0..header.metadata_size];
    try std.testing.expectEqual(audio.sample_rate, std.mem.readInt(u32, meta[0..4], .little));
    try std.testing.expectEqual(audio.channels, std.mem.readInt(u16, meta[4..6], .little));
    try std.testing.expectEqual(audio.bits_per_sample, std.mem.readInt(u16, meta[6..8], .little));

    const payload = bin[header.data_offset..][0..header.data_size];
    try std.testing.expectEqualSlices(u8, audio.data, payload);
}
