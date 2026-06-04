//! Audio cooker — intermediate → `.audio.bin`.
//!
//! M0.6 payload is raw PCM (no Opus — the Opus keeper is not wired in M0.6,
//! brief §Out-of-scope). Metadata section: `sample_rate` u32,
//! `channels` u16, `bits_per_sample` u16 (LE).

const std = @import("std");
const format = @import("../format/root.zig");
const common = @import("common.zig");

/// Cook an audio intermediate (`doc` + PCM `blob`) into an `.audio.bin`.
/// Format fields are read from `doc.extracted`.
pub fn cook(gpa: std.mem.Allocator, doc: format.AssetDoc, blob: []const u8) common.Error![]u8 {
    const sample_rate = format.intermediate.fieldInt(doc.extracted, "sample_rate") orelse return error.MissingMetadata;
    const channels = format.intermediate.fieldInt(doc.extracted, "channels") orelse return error.MissingMetadata;
    const bits = format.intermediate.fieldInt(doc.extracted, "bits_per_sample") orelse return error.MissingMetadata;

    var meta: [8]u8 = undefined;
    std.mem.writeInt(u32, meta[0..4], @intCast(sample_rate), .little);
    std.mem.writeInt(u16, meta[4..6], @intCast(channels), .little);
    std.mem.writeInt(u16, meta[6..8], @intCast(bits), .little);

    return common.assemble(gpa, .audio, &meta, blob);
}
