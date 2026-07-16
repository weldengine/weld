//! Native PNG decoder → RGBA8.
//!
//! Parses IHDR/PLTE/tRNS/IDAT/IEND, inflates the IDAT zlib stream (E2
//! `codecs/deflate`), reverses the five line filters (Paeth via the
//! `foundation/simd` `paeth_filter_decode` kernel), handles palette + tRNS
//! alpha and bit depths 1/2/4/8 and Adam7 interlace, and expands every
//! pixel to RGBA8 (the M0.6 cooked-texture payload).
//!
//! Out of scope (M0.6, brief §Out-of-scope): 16-bit channels, grayscale/RGB
//! colour-key tRNS, mipmaps, GPU compression. Chunk CRC32 is parsed past but
//! not verified (the IDAT ADLER32 already guards the pixel stream); a
//! CRC32 check is deferred.

const std = @import("std");
const zlib = @import("../deflate/zlib.zig");
const simd = @import("foundation").simd;

/// Errors raised by `decode`.
pub const Error = error{
    /// Missing or wrong 8-byte PNG signature.
    BadSignature,
    /// A chunk or the pixel stream ended early.
    Truncated,
    /// Malformed IHDR or an inconsistent palette index, or an image-size
    /// computation that overflowed `usize` (R3, M1.1.1-HF3 — checked arithmetic).
    BadHeader,
    /// IHDR width or height exceeds `max_dimension` (R3, M1.1.1-HF3): a hostile
    /// dimension is rejected before any allocation, so a size product can never
    /// wrap `usize` into an undersized buffer.
    DimensionsTooLarge,
    /// Colour type not one of 0/2/3/4/6.
    UnsupportedColorType,
    /// Bit depth invalid for the colour type, or 16-bit (out of scope).
    UnsupportedBitDepth,
    /// Interlace method other than 0 (none) or 1 (Adam7).
    UnsupportedInterlace,
    /// Indexed image without a PLTE chunk.
    MissingPalette,
    /// Unknown scanline filter type.
    BadFilter,
    /// Allocation failed.
    OutOfMemory,
} || zlib.Error;

/// A decoded image as tightly-packed RGBA8, row-major.
pub const Image = struct {
    /// Pixel width.
    width: u32,
    /// Pixel height.
    height: u32,
    /// `width * height * 4` bytes, R,G,B,A per pixel. Caller-owned.
    pixels: []u8,

    /// Free the pixel buffer and poison `self`.
    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// Maximum accepted image dimension, per axis (R3, M1.1.1-HF3). Aligned with a
/// common Vulkan `maxImageDimension2D` (16384). Capping `width`/`height` here is
/// what makes every downstream size product (`width × height × channels`, per-
/// scanline bytes, the inflate budget) provably non-overflowing — a
/// `0xFFFFFFFF × 0xFFFFFFFF × 4` wrap into an undersized allocation is impossible.
const max_dimension: u32 = 16384;

/// Checked `a * b`; overflow → `error.BadHeader` (R3 — never a bare `*` on a
/// file-controlled quantity, even one that cannot overflow post-cap).
fn mulSize(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.BadHeader;
}

/// Checked `a + b`; overflow → `error.BadHeader`.
fn addSize(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.BadHeader;
}

/// Adam7 interlace passes (`xs`/`ys` start, `xstep`/`ystep` stride). Shared by
/// `expectedRawSize` and `deinterlaceAdam7` so the pre-inflation size budget and
/// the raw-stream walk agree by construction.
const Adam7Pass = struct { xs: u32, ys: u32, xstep: u32, ystep: u32 };
const adam7_passes = [7]Adam7Pass{
    .{ .xs = 0, .ys = 0, .xstep = 8, .ystep = 8 },
    .{ .xs = 4, .ys = 0, .xstep = 8, .ystep = 8 },
    .{ .xs = 0, .ys = 4, .xstep = 4, .ystep = 8 },
    .{ .xs = 2, .ys = 0, .xstep = 4, .ystep = 4 },
    .{ .xs = 0, .ys = 2, .xstep = 2, .ystep = 4 },
    .{ .xs = 1, .ys = 0, .xstep = 2, .ystep = 2 },
    .{ .xs = 0, .ys = 1, .xstep = 1, .ystep = 2 },
};

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlace: u8,
};

/// Decode `src` (a complete PNG file) to an RGBA8 `Image`.
pub fn decode(gpa: std.mem.Allocator, src: []const u8) Error!Image {
    if (src.len < signature.len or !std.mem.eql(u8, src[0..signature.len], &signature)) {
        return error.BadSignature;
    }

    var header: ?Header = null;
    var palette: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var pos: usize = signature.len;
    while (pos + 8 <= src.len) {
        const len = std.mem.readInt(u32, src[pos..][0..4], .big);
        const ctype = src[pos + 4 ..][0..4];
        const data_start = pos + 8;
        if (data_start + len + 4 > src.len) return error.Truncated;
        const data = src[data_start .. data_start + len];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        pos = data_start + len + 4; // skip data + CRC
    }

    const h = header orelse return error.BadHeader;
    const channels = try channelsOf(h.color_type);

    // R3: the exact inflated size is known from IHDR before inflation. It bounds
    // the inflater's output (a decompression bomb trips `OutputLimitExceeded`
    // instead of exhausting memory); the produced stream must then match it
    // exactly (short → `Truncated`).
    const expected_raw = try expectedRawSize(h, channels);
    const raw = try zlib.decompress(gpa, idat.items, expected_raw);
    defer gpa.free(raw);
    if (raw.len != expected_raw) return error.Truncated;

    const sample_count = try mulSize(try mulSize(h.width, h.height), channels);
    const samples = try gpa.alloc(u8, sample_count);
    defer gpa.free(samples);

    if (h.interlace == 0) {
        try deinterlaceNone(gpa, h, channels, raw, samples);
    } else {
        try deinterlaceAdam7(gpa, h, channels, raw, samples);
    }

    const pixels = try gpa.alloc(u8, try mulSize(try mulSize(h.width, h.height), 4));
    errdefer gpa.free(pixels);
    try convertToRgba(samples, h, channels, palette, trns, pixels);

    return .{ .width = h.width, .height = h.height, .pixels = pixels };
}

fn parseHeader(data: []const u8) Error!Header {
    if (data.len < 13) return error.BadHeader;
    const h = Header{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .bit_depth = data[8],
        .color_type = data[9],
        .interlace = data[12],
    };
    if (h.width == 0 or h.height == 0) return error.BadHeader;
    // R3: reject a hostile dimension BEFORE any size product or allocation.
    if (h.width > max_dimension or h.height > max_dimension) return error.DimensionsTooLarge;
    if (data[10] != 0) return error.BadHeader; // compression method
    if (data[11] != 0) return error.BadHeader; // filter method
    if (h.interlace > 1) return error.UnsupportedInterlace;
    if (h.bit_depth == 16) return error.UnsupportedBitDepth;
    try validateDepth(h.color_type, h.bit_depth);
    return h;
}

fn channelsOf(color_type: u8) Error!u8 {
    return switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // RGB
        3 => 1, // indexed
        4 => 2, // grayscale + alpha
        6 => 4, // RGBA
        else => error.UnsupportedColorType,
    };
}

fn validateDepth(color_type: u8, bit_depth: u8) Error!void {
    const ok = switch (color_type) {
        0, 3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        2, 4, 6 => bit_depth == 8,
        else => return error.UnsupportedColorType,
    };
    if (!ok) return error.UnsupportedBitDepth;
}

/// Bytes per scanline row = ceil(width × channels × bit_depth / 8), all products
/// checked (R3). Post-cap these cannot overflow, but the checked form is the
/// contract the per-gate review verifies on file-controlled quantities.
fn bytesPerRow(width: u32, channels: u8, bit_depth: u8) Error!usize {
    const bits = try addSize(try mulSize(try mulSize(width, channels), bit_depth), 7);
    return bits / 8;
}

/// The exact expected inflated raw-stream size, computed from IHDR BEFORE
/// inflation (R3). Per scanline: 1 filter byte + `bytesPerRow`. Non-interlaced:
/// `height × (1 + bytesPerRow)`. Adam7: the sum over the 7 passes, an empty pass
/// (zero width or height) contributing 0. This is the `max_out` budget handed to
/// the inflater and the exact length the produced stream must equal.
fn expectedRawSize(h: Header, channels: u8) Error!usize {
    if (h.interlace == 0) {
        const stride = try addSize(1, try bytesPerRow(h.width, channels, h.bit_depth));
        return try mulSize(h.height, stride);
    }
    var total: usize = 0;
    for (adam7_passes) |p| {
        const pw: u32 = if (h.width > p.xs) (h.width - p.xs + p.xstep - 1) / p.xstep else 0;
        const ph: u32 = if (h.height > p.ys) (h.height - p.ys + p.ystep - 1) / p.ystep else 0;
        if (pw == 0 or ph == 0) continue;
        const stride = try addSize(1, try bytesPerRow(pw, channels, h.bit_depth));
        total = try addSize(total, try mulSize(ph, stride));
    }
    return total;
}

fn filterBpp(channels: u8, bit_depth: u8) u8 {
    const bits = @as(usize, channels) * bit_depth;
    return @intCast(@max(1, bits / 8));
}

fn unfilterRow(filter_type: u8, row: []u8, prev: []const u8, bpp: u8) Error!void {
    switch (filter_type) {
        0 => {},
        1 => { // Sub
            var i: usize = bpp;
            while (i < row.len) : (i += 1) row[i] +%= row[i - bpp];
        },
        2 => { // Up
            for (row, 0..) |*x, i| x.* +%= prev[i];
        },
        3 => { // Average
            for (row, 0..) |*x, i| {
                const a: u16 = if (i >= bpp) row[i - bpp] else 0;
                const b: u16 = prev[i];
                x.* +%= @intCast((a + b) / 2);
            }
        },
        4 => simd.paeth_filter_decode(prev, row, bpp), // Paeth (foundation/simd)
        else => return error.BadFilter,
    }
}

fn unpackRow(packed_row: []const u8, width: u32, bit_depth: u8, out: []u8) void {
    if (bit_depth == 8) {
        // `out.len == width * channels`; the byte stream copies straight over.
        @memcpy(out, packed_row[0..out.len]);
        return;
    }
    // bit_depth < 8 implies channels == 1 (grayscale or indexed). MSB-first.
    const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
    var bit: usize = 0;
    var px: usize = 0;
    while (px < width) : (px += 1) {
        const byte = packed_row[bit / 8];
        const shift: u3 = @intCast(8 - bit_depth - (bit % 8));
        out[px] = (byte >> shift) & mask;
        bit += bit_depth;
    }
}

/// Non-interlaced: unfilter each row in place, then unpack into `samples`.
fn deinterlaceNone(gpa: std.mem.Allocator, h: Header, channels: u8, raw: []u8, samples: []u8) Error!void {
    const row_bytes = try bytesPerRow(h.width, channels, h.bit_depth);
    const bpp = filterBpp(channels, h.bit_depth);
    const stride = 1 + row_bytes;
    if (raw.len < @as(usize, h.height) * stride) return error.Truncated;

    const zero = try gpa.alloc(u8, row_bytes);
    defer gpa.free(zero);
    @memset(zero, 0);

    var y: usize = 0;
    while (y < h.height) : (y += 1) {
        const base = y * stride;
        const row = raw[base + 1 ..][0..row_bytes];
        const prev = if (y == 0) zero else raw[(y - 1) * stride + 1 ..][0..row_bytes];
        try unfilterRow(raw[base], row, prev, bpp);
    }
    y = 0;
    const row_samples = @as(usize, h.width) * channels;
    while (y < h.height) : (y += 1) {
        const row = raw[y * stride + 1 ..][0..row_bytes];
        unpackRow(row, h.width, h.bit_depth, samples[y * row_samples ..][0..row_samples]);
    }
}

/// Adam7: 7 passes, each unfiltered + unpacked then scattered into the grid.
fn deinterlaceAdam7(gpa: std.mem.Allocator, h: Header, channels: u8, raw: []u8, samples: []u8) Error!void {
    const bpp = filterBpp(channels, h.bit_depth);

    const zero = try gpa.alloc(u8, try bytesPerRow(h.width, channels, h.bit_depth));
    defer gpa.free(zero);
    @memset(zero, 0);
    const pass_samples = try gpa.alloc(u8, try mulSize(h.width, channels));
    defer gpa.free(pass_samples);

    var cursor: usize = 0;
    for (adam7_passes) |p| {
        const pw: u32 = if (h.width > p.xs) (h.width - p.xs + p.xstep - 1) / p.xstep else 0;
        const ph: u32 = if (h.height > p.ys) (h.height - p.ys + p.ystep - 1) / p.ystep else 0;
        if (pw == 0 or ph == 0) continue;

        const row_bytes = try bytesPerRow(pw, channels, h.bit_depth);
        const stride = 1 + row_bytes;
        if (cursor + @as(usize, ph) * stride > raw.len) return error.Truncated;

        var yy: usize = 0;
        while (yy < ph) : (yy += 1) {
            const base = cursor + yy * stride;
            const row = raw[base + 1 ..][0..row_bytes];
            const prev = if (yy == 0) zero[0..row_bytes] else raw[cursor + (yy - 1) * stride + 1 ..][0..row_bytes];
            try unfilterRow(raw[base], row, prev, bpp);
        }
        yy = 0;
        while (yy < ph) : (yy += 1) {
            const row = raw[cursor + yy * stride + 1 ..][0..row_bytes];
            unpackRow(row, pw, h.bit_depth, pass_samples[0 .. @as(usize, pw) * channels]);
            const img_y = p.ys + yy * p.ystep;
            var xx: usize = 0;
            while (xx < pw) : (xx += 1) {
                const img_x = p.xs + xx * p.xstep;
                const dst = samples[(@as(usize, img_y) * h.width + img_x) * channels ..][0..channels];
                @memcpy(dst, pass_samples[xx * channels ..][0..channels]);
            }
        }
        cursor += @as(usize, ph) * stride;
    }
}

fn scale(sample: u8, bit_depth: u8) u8 {
    return switch (bit_depth) {
        8 => sample,
        4 => sample * 17,
        2 => sample * 85,
        1 => sample * 255,
        else => sample,
    };
}

fn convertToRgba(samples: []const u8, h: Header, channels: u8, palette: ?[]const u8, trns: ?[]const u8, out: []u8) Error!void {
    const total = @as(usize, h.width) * h.height;
    var px: usize = 0;
    while (px < total) : (px += 1) {
        const s = samples[px * channels ..][0..channels];
        const o = out[px * 4 ..][0..4];
        switch (h.color_type) {
            0 => {
                const g = scale(s[0], h.bit_depth);
                o.* = .{ g, g, g, 255 };
            },
            2 => o.* = .{ s[0], s[1], s[2], 255 },
            3 => {
                const pal = palette orelse return error.MissingPalette;
                const idx: usize = s[0];
                if (idx * 3 + 2 >= pal.len) return error.BadHeader;
                const a: u8 = if (trns) |t| (if (idx < t.len) t[idx] else 255) else 255;
                o.* = .{ pal[idx * 3], pal[idx * 3 + 1], pal[idx * 3 + 2], a };
            },
            4 => {
                const g = scale(s[0], h.bit_depth);
                o.* = .{ g, g, g, s[1] };
            },
            6 => o.* = .{ s[0], s[1], s[2], s[3] },
            else => return error.UnsupportedColorType,
        }
    }
}

// --- tests (vectors manually encoded, decode verified by Pillow) ------------

test "decode RGBA8 with all five scanline filters" {
    const gpa = std.testing.allocator;
    var img = try decode(gpa, &png_rgba_filters);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, png_rgba_filters_w), img.width);
    try std.testing.expectEqual(@as(u32, png_rgba_filters_h), img.height);
    try std.testing.expectEqualSlices(u8, &png_rgba_filters_expected, img.pixels);
}

test "decode 4-bit palette image with tRNS alpha" {
    const gpa = std.testing.allocator;
    var img = try decode(gpa, &png_palette);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, png_palette_w), img.width);
    try std.testing.expectEqualSlices(u8, &png_palette_expected, img.pixels);
}

test "decode Adam7 interlaced RGB image" {
    const gpa = std.testing.allocator;
    var img = try decode(gpa, &png_interlaced);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, png_interlaced_w), img.width);
    try std.testing.expectEqualSlices(u8, &png_interlaced_expected, img.pixels);
}

test "decode rejects a non-PNG buffer" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadSignature, decode(gpa, "not a png at all!!"));
}

test "oversized dimensions are rejected before inflation" {
    // IHDR width @16 (big-endian u32). Force it to 0xFFFFFFFF.
    var buf = png_rgba_filters;
    @memset(buf[16..20], 0xFF);
    // A FailingAllocator that fails on the very FIRST allocation. `parseHeader`
    // (run when the IHDR chunk is seen, before any IDAT accumulation or pixel
    // buffer) rejects the dimension without allocating — so `decode` returns
    // `DimensionsTooLarge`, not `OutOfMemory`. That proves no size-proportional
    // allocation is attempted for the claimed 4-billion-pixel image.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.DimensionsTooLarge, decode(fa.allocator(), &buf));
}

test "inflate output exceeding the expected size is rejected" {
    const gpa = std.testing.allocator;
    // png_rgba_filters is 8×5 RGBA → raw stream is 5 × (1 + 8×4) = 165 bytes.
    // IHDR height low byte is @23.
    // Claiming height 4 → expected 132 < 165: the inflater trips the budget.
    {
        var buf = png_rgba_filters;
        buf[23] = 4;
        try std.testing.expectError(error.OutputLimitExceeded, decode(gpa, &buf));
    }
    // Claiming height 6 → expected 198 > 165: the stream is short of the header.
    {
        var buf = png_rgba_filters;
        buf[23] = 6;
        try std.testing.expectError(error.Truncated, decode(gpa, &buf));
    }
}

test "Adam7 expected-size accounting is exact" {
    const gpa = std.testing.allocator;
    // The valid 5×5 interlaced fixture round-trips (exact per-pass accounting).
    var img = try decode(gpa, &png_interlaced);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, png_interlaced_h), img.height);
    // An off-by-one height (6) inflates the Adam7 pass total past the real
    // stream → rejected, never a partial/undersized decode.
    var buf = png_interlaced;
    buf[23] = 6;
    try std.testing.expectError(error.Truncated, decode(gpa, &buf));
}

const png_rgba_filters_w = 8;
const png_rgba_filters_h = 5;
const png_rgba_filters = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x05, 0x08, 0x06, 0x00, 0x00, 0x00, 0x78, 0x91, 0xad, 0x55, 0x00, 0x00, 0x00, 0x6a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x75, 0xcc, 0xad, 0x0e, 0x40, 0x60, 0x00, 0x46, 0xe1, 0xe3, 0x67, 0xd3, 0xcc, 0x6c, 0xc2, 0xb7, 0x7d, 0xc1, 0xa6, 0x69, 0x5c, 0x81, 0x4b, 0x11, 0x5c, 0x88, 0x4b, 0x71, 0x29, 0x9a, 0x28, 0x8a, 0x34, 0x51, 0x24, 0xd8, 0x78, 0x69, 0x82, 0xf0, 0xb4, 0xb3, 0x03, 0x70, 0xa5, 0xb0, 0x57, 0xb0, 0xd5, 0xb0, 0xb6, 0x30, 0x77, 0x30, 0xf5, 0x30, 0x2e, 0x30, 0x38, 0x94, 0x4f, 0x10, 0x1c, 0x7f, 0x5c, 0x05, 0x50, 0x06, 0x12, 0x4a, 0x22, 0x56, 0x32, 0xc9, 0xa5, 0xc0, 0xa3, 0xa1, 0x8d, 0x4c, 0x78, 0x46, 0x26, 0x96, 0x44, 0x8c, 0x58, 0x49, 0x25, 0x3b, 0xfd, 0xf7, 0x80, 0x0e, 0xe8, 0x80, 0x0e, 0xd8, 0x8f, 0x1b, 0xb0, 0xdf, 0x20, 0x61, 0x28, 0x30, 0x54, 0xec, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
const png_rgba_filters_expected = [_]u8{ 0x00, 0x00, 0x00, 0xff, 0x20, 0x00, 0x00, 0xf7, 0x40, 0x00, 0x00, 0xef, 0x60, 0x00, 0x00, 0xe7, 0x80, 0x00, 0x00, 0xdf, 0xa0, 0x00, 0x00, 0xd7, 0xc0, 0x00, 0x00, 0xcf, 0xe0, 0x00, 0x00, 0xc7, 0x00, 0x32, 0x00, 0xff, 0x20, 0x32, 0x07, 0xf7, 0x40, 0x32, 0x0e, 0xef, 0x60, 0x32, 0x15, 0xe7, 0x80, 0x32, 0x1c, 0xdf, 0xa0, 0x32, 0x23, 0xd7, 0xc0, 0x32, 0x2a, 0xcf, 0xe0, 0x32, 0x31, 0xc7, 0x00, 0x64, 0x00, 0xff, 0x20, 0x64, 0x0e, 0xf7, 0x40, 0x64, 0x1c, 0xef, 0x60, 0x64, 0x2a, 0xe7, 0x80, 0x64, 0x38, 0xdf, 0xa0, 0x64, 0x46, 0xd7, 0xc0, 0x64, 0x54, 0xcf, 0xe0, 0x64, 0x62, 0xc7, 0x00, 0x96, 0x00, 0xff, 0x20, 0x96, 0x15, 0xf7, 0x40, 0x96, 0x2a, 0xef, 0x60, 0x96, 0x3f, 0xe7, 0x80, 0x96, 0x54, 0xdf, 0xa0, 0x96, 0x69, 0xd7, 0xc0, 0x96, 0x7e, 0xcf, 0xe0, 0x96, 0x93, 0xc7, 0x00, 0xc8, 0x00, 0xff, 0x20, 0xc8, 0x1c, 0xf7, 0x40, 0xc8, 0x38, 0xef, 0x60, 0xc8, 0x54, 0xe7, 0x80, 0xc8, 0x70, 0xdf, 0xa0, 0xc8, 0x8c, 0xd7, 0xc0, 0xc8, 0xa8, 0xcf, 0xe0, 0xc8, 0xc4, 0xc7 };

const png_palette_w = 4;
const png_palette_h = 2;
const png_palette = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x04, 0x03, 0x00, 0x00, 0x00, 0x8d, 0x86, 0x60, 0x50, 0x00, 0x00, 0x00, 0x0c, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xfb, 0x00, 0x60, 0xf6, 0x00, 0x00, 0x00, 0x03, 0x74, 0x52, 0x4e, 0x53, 0x00, 0x80, 0xff, 0xec, 0xf7, 0xb3, 0x18, 0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x54, 0x66, 0x34, 0xba, 0x07, 0x00, 0x01, 0xdc, 0x01, 0x36, 0x27, 0x36, 0x5e, 0x16, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
const png_palette_expected = [_]u8{ 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x80, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0xff, 0xff, 0x00, 0xff, 0x00, 0x80, 0xff, 0x00, 0x00, 0x00 };

const png_interlaced_w = 5;
const png_interlaced_h = 5;
const png_interlaced = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x05, 0x08, 0x02, 0x00, 0x00, 0x01, 0x75, 0x0a, 0x81, 0x24, 0x00, 0x00, 0x00, 0x41, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x15, 0x87, 0x41, 0x11, 0x00, 0x31, 0x10, 0x83, 0x22, 0xa2, 0x22, 0x22, 0x62, 0x45, 0x20, 0x62, 0x45, 0x44, 0x44, 0x45, 0x44, 0xea, 0xf5, 0x78, 0x30, 0x20, 0x3d, 0x2a, 0x9e, 0x68, 0xff, 0xb0, 0x68, 0x24, 0x0c, 0x94, 0xbc, 0x3f, 0xd1, 0xc8, 0x4c, 0x58, 0xb9, 0x9b, 0x5e, 0xc9, 0xc7, 0x36, 0x9e, 0x98, 0x7a, 0xa5, 0x8c, 0x03, 0xd9, 0x24, 0xcd, 0xfd, 0x00, 0x8c, 0xb7, 0x17, 0x71, 0xb5, 0x93, 0x7d, 0x9c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
const png_interlaced_expected = [_]u8{ 0x00, 0x00, 0x00, 0xff, 0x28, 0x00, 0x14, 0xff, 0x50, 0x00, 0x28, 0xff, 0x78, 0x00, 0x3c, 0xff, 0xa0, 0x00, 0x50, 0xff, 0x00, 0x28, 0x14, 0xff, 0x28, 0x28, 0x28, 0xff, 0x50, 0x28, 0x3c, 0xff, 0x78, 0x28, 0x50, 0xff, 0xa0, 0x28, 0x64, 0xff, 0x00, 0x50, 0x28, 0xff, 0x28, 0x50, 0x3c, 0xff, 0x50, 0x50, 0x50, 0xff, 0x78, 0x50, 0x64, 0xff, 0xa0, 0x50, 0x78, 0xff, 0x00, 0x78, 0x3c, 0xff, 0x28, 0x78, 0x50, 0xff, 0x50, 0x78, 0x64, 0xff, 0x78, 0x78, 0x78, 0xff, 0xa0, 0x78, 0x8c, 0xff, 0x00, 0xa0, 0x50, 0xff, 0x28, 0xa0, 0x64, 0xff, 0x50, 0xa0, 0x78, 0xff, 0x78, 0xa0, 0x8c, 0xff, 0xa0, 0xa0, 0xa0, 0xff };
