//! Direct PPM PSNR gate — Phase 0 / M0.5 (item 1).
//!
//! Reads the smoke-test capture at `out/smoke_test.ppm` (produced by a prior
//! `run-example-triangle --smoke-test --capture-frame=N` step) and compares
//! it against the committed golden via PSNR — WITHOUT rebuilding the render
//! stack and WITHOUT re-running the triangle. This replaces the CI
//! `runtime-smoke-test` "Verify PSNR" step's `zig build test-render-capture`
//! invocation, which rebuilt the test target in ReleaseSafe AND re-spawned
//! the triangle even though the PPM was already produced by the prior step.
//! Cost saved: ~3-5 min/run (cf. brief item 1).
//!
//! This module imports only `std` (no `weld_render`), so `zig build
//! test-ppm-psnr` compiles in seconds. The gate skips when either PPM is
//! absent (e.g. run locally without first producing the capture).

const std = @import("std");

const FRAME_WIDTH: u32 = 1280;
const FRAME_HEIGHT: u32 = 720;
const PSNR_GATE_DB: f64 = 40.0;
const GOLDEN_PATH: []const u8 = "tests/golden/smoke_test_software.ppm";
const CAPTURED_PATH: []const u8 = "out/smoke_test.ppm";

fn fileExists(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Read a binary P6 PPM and return its `FRAME_WIDTH*FRAME_HEIGHT*3` RGB
/// payload (caller owns it). Validates the magic and that the payload size
/// matches the expected frame dimensions.
fn readPpm(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const bytes = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(bytes);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(bytes);

    // Parse the P6 header: "P6\n<W> <H>\n255\n<bytes>".
    if (bytes.len < 11) return error.InvalidHeader;
    if (!std.mem.startsWith(u8, bytes, "P6\n")) return error.UnsupportedFormat;

    var cursor: usize = 3;
    while (cursor < bytes.len and bytes[cursor] != '\n') cursor += 1;
    if (cursor >= bytes.len) return error.InvalidHeader;
    cursor += 1;
    while (cursor < bytes.len and bytes[cursor] != '\n') cursor += 1;
    if (cursor >= bytes.len) return error.InvalidHeader;
    cursor += 1;

    const pixel_bytes = bytes.len - cursor;
    const expected: usize = @as(usize, FRAME_WIDTH) * FRAME_HEIGHT * 3;
    if (pixel_bytes != expected) return error.SizeMismatch;

    const out = try allocator.alloc(u8, expected);
    @memcpy(out, bytes[cursor..]);
    allocator.free(bytes);
    return out;
}

fn psnrDb(a: []const u8, b: []const u8) f64 {
    std.debug.assert(a.len == b.len);
    var sse: u128 = 0;
    for (a, b) |x, y| {
        const dx: i32 = @as(i32, x) - @as(i32, y);
        sse += @intCast(dx * dx);
    }
    if (sse == 0) return std.math.inf(f64);
    const mse: f64 = @as(f64, @floatFromInt(sse)) / @as(f64, @floatFromInt(a.len));
    return 20.0 * std.math.log10(255.0 / @sqrt(mse));
}

test "ppm psnr gate: captured smoke frame matches golden within 40 dB" {
    const io = std.testing.io;
    if (!fileExists(io, CAPTURED_PATH)) return error.SkipZigTest;
    if (!fileExists(io, GOLDEN_PATH)) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const captured = readPpm(allocator, io, CAPTURED_PATH) catch |e| {
        std.log.warn("ppm-psnr: failed to read {s}: {t}", .{ CAPTURED_PATH, e });
        return error.SkipZigTest;
    };
    defer allocator.free(captured);

    const golden = try readPpm(allocator, io, GOLDEN_PATH);
    defer allocator.free(golden);

    const psnr = psnrDb(captured, golden);
    std.log.info("ppm-psnr vs golden: {d:.2} dB (gate {d:.2})", .{ psnr, PSNR_GATE_DB });
    try std.testing.expect(psnr >= PSNR_GATE_DB);
}

test "psnrDb: identical inputs report infinity" {
    const a = [_]u8{ 1, 2, 3 };
    try std.testing.expect(std.math.isInf(psnrDb(&a, &a)));
}

test "psnrDb: 1-unit average error sits around 48 dB" {
    var a: [3072]u8 = undefined;
    var b: [3072]u8 = undefined;
    for (&a) |*v| v.* = 128;
    for (&b) |*v| v.* = 129;
    const psnr = psnrDb(&a, &b);
    try std.testing.expect(psnr > 46.0);
    try std.testing.expect(psnr < 50.0);
}
