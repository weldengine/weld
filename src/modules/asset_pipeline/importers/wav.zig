//! WAV (RIFF PCM) decode.
//!
//! Lives in `importers/` rather than a `codecs/wav/` of its own — RIFF PCM
//! is trivial (brief §Notes — WAV location). M0.6 ships the decoder here;
//! the import → intermediate orchestration is added in E4.
//!
//! Supports linear PCM (`audio_format == 1`); compressed WAV is out of scope.

const std = @import("std");

/// Errors raised by `decode`.
pub const Error = error{
    /// Not a `RIFF` container.
    BadRiff,
    /// RIFF form type is not `WAVE`.
    NotWave,
    /// No `fmt ` subchunk.
    MissingFmt,
    /// No `data` subchunk.
    MissingData,
    /// `audio_format` is not 1 (linear PCM).
    UnsupportedFormat,
    /// A subchunk reached past the end of the buffer.
    Truncated,
    /// Allocation failed.
    OutOfMemory,
};

/// Decoded PCM audio. `data` is interleaved little-endian PCM, caller-owned.
pub const Audio = struct {
    /// Samples per second.
    sample_rate: u32,
    /// Channel count (interleaved in `data`).
    channels: u16,
    /// Bits per sample (8 or 16 in M0.6).
    bits_per_sample: u16,
    /// Raw interleaved PCM bytes.
    data: []u8,

    /// Number of sample frames (one frame = one sample per channel).
    pub fn frameCount(self: Audio) usize {
        const bytes_per_frame = @as(usize, self.channels) * (self.bits_per_sample / 8);
        if (bytes_per_frame == 0) return 0;
        return self.data.len / bytes_per_frame;
    }

    /// Free the PCM buffer and poison `self`.
    pub fn deinit(self: *Audio, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// Decode a WAV (RIFF PCM) file into `Audio`.
pub fn decode(gpa: std.mem.Allocator, src: []const u8) Error!Audio {
    if (src.len < 12 or !std.mem.eql(u8, src[0..4], "RIFF")) return error.BadRiff;
    if (!std.mem.eql(u8, src[8..12], "WAVE")) return error.NotWave;

    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var bits: u16 = 0;
    var have_fmt = false;
    var pcm: ?[]const u8 = null;

    var pos: usize = 12;
    while (pos + 8 <= src.len) {
        const id = src[pos..][0..4];
        const size = std.mem.readInt(u32, src[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        if (body_start + size > src.len) return error.Truncated;
        const body = src[body_start .. body_start + size];

        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.Truncated;
            const audio_format = std.mem.readInt(u16, body[0..2], .little);
            if (audio_format != 1) return error.UnsupportedFormat;
            channels = std.mem.readInt(u16, body[2..4], .little);
            sample_rate = std.mem.readInt(u32, body[4..8], .little);
            bits = std.mem.readInt(u16, body[14..16], .little);
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            pcm = body;
        }
        // Subchunks are padded to an even byte count.
        pos = body_start + size + (size & 1);
    }

    if (!have_fmt) return error.MissingFmt;
    const data = pcm orelse return error.MissingData;
    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .bits_per_sample = bits,
        .data = try gpa.dupe(u8, data),
    };
}

test "decode WAV PCM s16le extracts format and samples" {
    const gpa = std.testing.allocator;
    var audio = try decode(gpa, &wav_pcm);
    defer audio.deinit(gpa);
    try std.testing.expectEqual(@as(u32, wav_sample_rate), audio.sample_rate);
    try std.testing.expectEqual(@as(u16, wav_channels), audio.channels);
    try std.testing.expectEqual(@as(u16, wav_bits), audio.bits_per_sample);
    try std.testing.expectEqual(@as(usize, wav_frames), audio.frameCount());
    try std.testing.expectEqualSlices(u8, &wav_pcm_data, audio.data);
}

test "decode rejects a non-RIFF buffer" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadRiff, decode(gpa, "nope"));
}

const wav_sample_rate = 8000;
const wav_channels = 2;
const wav_bits = 16;
const wav_frames = 8;
const wav_pcm = [_]u8{ 0x52, 0x49, 0x46, 0x46, 0x44, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x40, 0x1f, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x04, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61, 0x20, 0x00, 0x00, 0x00, 0x68, 0xc5, 0x5c, 0xc7, 0x50, 0xc9, 0x44, 0xcb, 0x38, 0xcd, 0x2c, 0xcf, 0x20, 0xd1, 0x14, 0xd3, 0x08, 0xd5, 0xfc, 0xd6, 0xf0, 0xd8, 0xe4, 0xda, 0xd8, 0xdc, 0xcc, 0xde, 0xc0, 0xe0, 0xb4, 0xe2 };
const wav_pcm_data = [_]u8{ 0x68, 0xc5, 0x5c, 0xc7, 0x50, 0xc9, 0x44, 0xcb, 0x38, 0xcd, 0x2c, 0xcf, 0x20, 0xd1, 0x14, 0xd3, 0x08, 0xd5, 0xfc, 0xd6, 0xf0, 0xd8, 0xe4, 0xda, 0xd8, 0xdc, 0xcc, 0xde, 0xc0, 0xe0, 0xb4, 0xe2 };
