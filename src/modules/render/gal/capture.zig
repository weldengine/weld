//! GAL frame-capture helper — Phase 0 / M0.5 (item 2).
//!
//! Reads back an already-rendered color texture into host memory and writes
//! it as a binary PPM (P6) file. Extracted from the M0.4 triangle example so
//! the staging-buffer readback + PPM-encoding boilerplate lives once on the
//! public GAL surface instead of being hand-rolled by every consumer
//! (cf. `engine-zig-conventions.md` §13 surface coverage — the triangle
//! example is the canonical empirical consumer of this path).
//!
//! The helper composes existing GAL primitives only (`createBuffer`,
//! `createCommandEncoder`, `copyTextureToBuffer`, `submit`, `waitFence`,
//! `mapBuffer`); it adds no backend-specific code, so a single generic
//! implementation serves every backend. Each backend `Device` exposes it as
//! the method `captureFrameToPPM` (a one-line delegation) and the interface
//! contract (`interface.required_methods`) lists it so every backend must
//! provide it.
//!
//! Caller contract: `texture` must already be rendered and left in a
//! transfer-source layout (e.g. a render pass with
//! `final_layout = .transfer_src`), and the rendering work must be complete
//! before the call (the caller waits its own render fence). The helper
//! performs its own copy submit + fence wait, then a CPU readback.

const std = @import("std");
const types = @import("types.zig");

/// Capture an already-rendered RGBA8 color `texture` of `width`×`height`
/// to a binary PPM (P6) file at `path`. Generic over the backend `Device`
/// (duck-typed on the GAL primitives it calls). The texture must be in a
/// transfer-source layout with its rendering already complete (cf. the
/// file-header caller contract).
///
/// Thread-safety: not thread-safe — issues a one-shot copy submit + fence
/// wait on the device. Intended for the debug / smoke-test capture path,
/// not the hot render loop.
///
/// Errors:
///   - `error.Unsupported` if the backend cannot map a host-visible buffer
///     (e.g. the Null backend), so portable callers can skip capture.
///   - any GAL error from the buffer / encoder / submit / fence operations.
///   - any I/O error from encoding or writing `path`.
pub fn captureFrameToPPM(
    device: anytype,
    gpa: std.mem.Allocator,
    io: std.Io,
    texture: types.TextureHandle,
    width: u32,
    height: u32,
    path: []const u8,
) !void {
    const staging_bytes: u64 = @as(u64, width) * height * 4;
    const staging = try device.createBuffer(.{
        .label = "gal.capture.staging",
        .size = staging_bytes,
        .usage = .{ .copy_dst = true },
        .host_visible = true,
    });
    defer device.destroyBuffer(staging);

    const fence = try device.createFence(false);
    defer device.destroyFence(fence);

    const enc = try device.createCommandEncoder("gal.capture");
    defer device.destroyCommandEncoder(enc);

    enc.copyTextureToBuffer(
        .{ .texture = texture, .aspect = .color },
        .{ .buffer = staging, .bytes_per_row = width * 4 },
        .{ .width = width, .height = height },
    );
    enc.finish();

    try device.submit(enc, .{ .fence = fence });
    try device.waitFence(fence, std.math.maxInt(u64));

    const rgba = try device.mapBuffer(staging);
    defer device.unmapBuffer(staging);

    try writePpm(gpa, io, path, rgba, width, height);
}

/// Write an RGBA8 pixel buffer as a binary PPM (P6) file at `path`, dropping
/// the alpha channel. The parent directory of `path` is created if missing.
/// `rgba.len` must be at least `width*height*4`.
///
/// Errors: any I/O error from creating the directory, the file, or writing.
pub fn writePpm(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rgba: []const u8,
    width: u32,
    height: u32,
) !void {
    const ppm = try encodePpm(gpa, rgba, width, height);
    defer gpa.free(ppm);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll(ppm);
    try w.flush();
}

/// Encode an RGBA8 pixel buffer as binary PPM (P6) bytes: the ASCII header
/// `"P6\n<W> <H>\n255\n"` followed by `width*height` RGB triplets (the alpha
/// byte of each source pixel is dropped). Caller owns the returned slice.
/// Pure function (no I/O, no device) — the unit-testable core of the capture
/// path. `rgba.len` must be at least `width*height*4`.
///
/// Errors: `error.OutOfMemory`.
pub fn encodePpm(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    const pixel_count = @as(usize, width) * height;
    std.debug.assert(rgba.len >= pixel_count * 4);

    var header_buf: [48]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch unreachable;

    const out = try gpa.alloc(u8, header.len + pixel_count * 3);
    @memcpy(out[0..header.len], header);

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        out[header.len + i * 3 + 0] = rgba[i * 4 + 0];
        out[header.len + i * 3 + 1] = rgba[i * 4 + 1];
        out[header.len + i * 3 + 2] = rgba[i * 4 + 2];
    }
    return out;
}
