//! M0.6 / E2 — DEFLATE/zlib inflate known-vector acceptance tests.
//!
//! Vectors were produced by Python's `zlib` (the reference encoder) at
//! authoring time and embedded verbatim; M0.6 ships no encoder, so inflate
//! is validated bit-exact against an independent compressor. The fixed and
//! dynamic streams were selected by inspecting the first block's BTYPE bits
//! (01 = fixed, 10 = dynamic).
//!
//! Brief §Acceptance ▸ Tests: `test "inflate fixed huffman"`,
//! `test "inflate dynamic huffman"`.

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const inflate = assets.codecs.deflate.inflate;
const zlib = assets.codecs.deflate.zlib;

// --- vectors (Python zlib, raw deflate wbits=-15 unless noted) ---------------

const fixed_compressed = [_]u8{ 0x4b, 0x4c, 0x04, 0x01, 0x00 };
const fixed_expected = [_]u8{ 0x61, 0x61, 0x61, 0x61, 0x61, 0x61 }; // "aaaaaa"

const dynamic_compressed = [_]u8{ 0xed, 0xcb, 0xc9, 0x15, 0x80, 0x20, 0x10, 0x04, 0xd1, 0x54, 0x3a, 0x02, 0x63, 0xf1, 0x60, 0x02, 0x2e, 0x6c, 0x0a, 0x8c, 0xb2, 0x0a, 0xd1, 0x3b, 0x31, 0x78, 0xf4, 0x79, 0xae, 0x5f, 0x93, 0x16, 0xb8, 0xb2, 0x59, 0x0f, 0x2c, 0x81, 0xaa, 0x87, 0xa4, 0x1b, 0x7b, 0x76, 0x67, 0x04, 0x15, 0x11, 0x90, 0x38, 0xdb, 0xb9, 0x37, 0x6c, 0xa4, 0x06, 0x4c, 0x3f, 0x7e, 0x8b, 0xc7, 0x99, 0x9d, 0x6b, 0x58, 0x18, 0x55, 0x93, 0x34, 0xa4, 0x29, 0x82, 0x53, 0x17, 0x1e, 0xd6, 0x5c, 0x99, 0x02, 0xbf, 0x2a, 0x7e, 0x0c, 0x3e };
const dynamic_expected = "The quick brown fox jumps over the lazy dog. " ** 8 ++ "Pack my box with five dozen liquor jugs. " ** 6;

const stored_compressed = [_]u8{ 0x01, 0x29, 0x00, 0xd6, 0xff, 0x57, 0x65, 0x6c, 0x64, 0x20, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x64, 0x20, 0x62, 0x6c, 0x6f, 0x63, 0x6b, 0x20, 0x74, 0x65, 0x73, 0x74, 0x20, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64, 0x20, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39 };
const stored_expected = "Weld stored block test payload 0123456789";

const zlib_compressed = [_]u8{ 0x78, 0xda, 0x0b, 0x4f, 0xcd, 0x49, 0x51, 0xa8, 0xca, 0xc9, 0x4c, 0x52, 0x28, 0x2f, 0x4a, 0x2c, 0x28, 0x48, 0x2d, 0x52, 0x28, 0xca, 0x2f, 0xcd, 0x4b, 0xd1, 0x2d, 0x29, 0xca, 0x2c, 0x50, 0x28, 0xcf, 0x2c, 0xc9, 0x50, 0x70, 0x74, 0xf1, 0x71, 0x0d, 0x32, 0x36, 0x52, 0x28, 0x29, 0x4a, 0xcc, 0xcc, 0x01, 0xca, 0x97, 0xa5, 0x16, 0x65, 0xa6, 0x65, 0x26, 0x27, 0x96, 0x64, 0xe6, 0xe7, 0xe9, 0x01, 0x00, 0xdd, 0xd3, 0x16, 0xe0 };
const zlib_expected = "Weld zlib wrapper round-trip with ADLER32 trailer verification.";

// -----------------------------------------------------------------------------

test "inflate fixed huffman" {
    const gpa = std.testing.allocator;
    const got = try inflate(gpa, &fixed_compressed);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, &fixed_expected, got);
}

test "inflate dynamic huffman" {
    const gpa = std.testing.allocator;
    const got = try inflate(gpa, &dynamic_compressed);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, dynamic_expected, got);
}

test "inflate stored block" {
    const gpa = std.testing.allocator;
    const got = try inflate(gpa, &stored_compressed);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, stored_expected, got);
}

test "zlib decompress verifies the adler32 trailer" {
    const gpa = std.testing.allocator;
    const got = try zlib.decompress(gpa, &zlib_compressed);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, zlib_expected, got);
}

test "zlib decompress rejects a corrupted adler32 trailer" {
    const gpa = std.testing.allocator;
    var corrupt = zlib_compressed;
    corrupt[corrupt.len - 1] ^= 0xff; // flip the last trailer byte
    try std.testing.expectError(error.BadChecksum, zlib.decompress(gpa, &corrupt));
}

// --- Negative vectors: one per inflate guard (hand-built, LSB-first). -------

// Stored block with LEN=3 but NLEN=0xFFFF (≠ ~3), violating LEN == ~NLEN.
const v_bad_stored_length = [_]u8{ 0x01, 0x03, 0x00, 0xff, 0xff, 0x61, 0x62, 0x63 };

// Fixed block: literal/length symbol 257 (length 3) + distance symbol 0
// (distance 1) with no output yet — distance reaches before the buffer start.
const v_distance_too_far = [_]u8{ 0x03, 0x02 };

// Dynamic block whose code-length table defines only symbol 16 at length 1
// (an incomplete table); the next code-length symbol reads a `1` bit, which
// matches no code.
const v_bad_huffman_code = [_]u8{ 0x05, 0x00, 0x02, 0x20 };

test "inflate rejects a stored block with bad LEN/NLEN" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadStoredLength, inflate(gpa, &v_bad_stored_length));
}

test "inflate rejects a back-reference distance past the output start" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DistanceTooFar, inflate(gpa, &v_distance_too_far));
}

test "inflate rejects a bit pattern matching no Huffman code" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadHuffmanCode, inflate(gpa, &v_bad_huffman_code));
}
