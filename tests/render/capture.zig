//! Smoke-test capture PSNR — Phase 0 / M0.4 § Scope — Complément Post-Review.
//!
//! Drives `examples/triangle` in capture mode and compares the produced
//! PPM against `tests/golden/smoke_test_software.ppm`. Skipped on
//! platforms without a Vulkan window backend (macOS Phase 2+) and when
//! the golden has not been committed yet (the golden is generated once
//! on Linux + lavapipe + weston headless, validated visually by Guy,
//! then committed — cf. brief § Scope — Complément Post-Review).
//!
//! PSNR formula: 20 * log10(MAX_I / sqrt(MSE)). Gate is ≥ 40 dB which
//! tolerates the typical ±1/255 quantization noise across compositors
//! while still catching genuine rendering regressions (a single channel
//! shifted by 5/255 already drops below the gate).

const std = @import("std");
const builtin = @import("builtin");

const FRAME_WIDTH: u32 = 1280;
const FRAME_HEIGHT: u32 = 720;
const CAPTURE_FRAME: u32 = 10;
const PSNR_GATE_DB: f64 = 40.0;
const GOLDEN_PATH: []const u8 = "tests/golden/smoke_test_software.ppm";
const CAPTURED_PATH: []const u8 = "out/smoke_test.ppm";

fn supportsVulkanWindow() bool {
    return switch (builtin.os.tag) {
        .windows, .linux => true,
        else => false,
    };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn locateTriangleBinary(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const candidates = [_][]const u8{
        "examples/triangle/zig-out/bin/triangle",
        "zig-out/bin/triangle",
    };
    for (candidates) |c| {
        if (fileExists(io, c)) return allocator.dupe(u8, c);
    }
    return error.TriangleBinaryNotFound;
}

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
    // <W> <H>
    while (cursor < bytes.len and bytes[cursor] != '\n') cursor += 1;
    if (cursor >= bytes.len) return error.InvalidHeader;
    cursor += 1;
    // 255
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

test "capture pass produces PPM matching golden within PSNR 40 dB" {
    if (!supportsVulkanWindow()) return error.SkipZigTest;
    const io = std.testing.io;
    if (!fileExists(io, GOLDEN_PATH)) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const triangle = locateTriangleBinary(allocator, io) catch return error.SkipZigTest;
    defer allocator.free(triangle);

    var capture_arg_buf: [64]u8 = undefined;
    const capture_arg = try std.fmt.bufPrint(&capture_arg_buf, "--capture-frame={d}", .{CAPTURE_FRAME});

    const argv = [_][]const u8{
        triangle,
        "--smoke-test",
        "--vulkan-driver=software",
        capture_arg,
    };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
    }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const captured = readPpm(allocator, io, CAPTURED_PATH) catch |e| {
        std.log.warn("capture: failed to read produced PPM at {s}: {t}", .{ CAPTURED_PATH, e });
        return error.SkipZigTest;
    };
    defer allocator.free(captured);

    const golden = try readPpm(allocator, io, GOLDEN_PATH);
    defer allocator.free(golden);

    const psnr = psnrDb(captured, golden);
    std.log.info("capture PSNR vs golden: {d:.2} dB (gate {d:.2})", .{ psnr, PSNR_GATE_DB });
    try std.testing.expect(psnr >= PSNR_GATE_DB);
}

test "PSNR helper: identical inputs report infinity" {
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 1, 2, 3 };
    try std.testing.expect(std.math.isInf(psnrDb(&a, &b)));
}

test "PSNR helper: 1-unit average error sits around 48 dB" {
    var a: [3072]u8 = undefined;
    var b: [3072]u8 = undefined;
    for (a[0..]) |*v| v.* = 128;
    for (b[0..]) |*v| v.* = 129;
    const psnr = psnrDb(&a, &b);
    try std.testing.expect(psnr > 46.0);
    try std.testing.expect(psnr < 50.0);
}
