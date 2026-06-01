//! GAL capture-helper surface coverage — Phase 0 / M0.5 (item 2, §13).
//!
//! Exercises the public `gal.capture` surface (`encodePpm` + the
//! `Device.captureFrameToPPM` method) so its bodies are analyzed by a real
//! consumer (cf. `engine-zig-conventions.md` §13 — a public GAL symbol must
//! be exercised by a test that calls it with realistic data and asserts the
//! result, not merely compiled). The full Vulkan readback path is covered
//! end-to-end on lavapipe CI by the triangle example + the PSNR gate
//! (`tests/render/ppm_psnr_compare.zig`); here we cover the backend-agnostic
//! core (PPM encoding) and the Null backend's clean `Unsupported`
//! propagation, both of which run on every platform incl. the macOS dev box.

const std = @import("std");
const gal = @import("weld_render").gal;

test "encodePpm: RGBA8 encodes to P6 with alpha stripped" {
    const gpa = std.testing.allocator;
    // 2x1 image: opaque red, half-alpha green. The encoder drops alpha.
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const ppm = try gal.capture.encodePpm(gpa, &rgba, 2, 1);
    defer gpa.free(ppm);

    const header = "P6\n2 1\n255\n";
    try std.testing.expect(std.mem.startsWith(u8, ppm, header));
    try std.testing.expectEqual(header.len + 2 * 3, ppm.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, ppm[header.len..]);
}

test "encodePpm: header carries the requested dimensions" {
    const gpa = std.testing.allocator;
    const rgba = [_]u8{0} ** (4 * 4 * 4);
    const ppm = try gal.capture.encodePpm(gpa, &rgba, 4, 4);
    defer gpa.free(ppm);
    try std.testing.expect(std.mem.startsWith(u8, ppm, "P6\n4 4\n255\n"));
}

test "captureFrameToPPM: Null backend surfaces Unsupported readback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var device = try gal.null_backend.Device.init(gpa, .{ .label = "capture-helper-test" });
    defer device.deinit();

    const tex = try device.createTexture(.{
        .format = .rgba8_unorm,
        .width = 4,
        .height = 4,
        .usage = .{ .color_attachment = true, .copy_src = true },
    });
    defer device.destroyTexture(tex);

    // The Null backend cannot map a host-visible buffer, so the readback
    // path must surface error.Unsupported cleanly — no leak, no file written.
    const result = device.captureFrameToPPM(gpa, io, tex, 4, 4, "out/__null_capture_unused.ppm");
    try std.testing.expectError(error.Unsupported, result);
}
