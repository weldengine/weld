//! Triangle example — Phase 0 / M0.4.
//!
//! Public GAL consumer. On Vulkan-capable platforms (Windows / Linux)
//! this opens a Tier 0 window, drives the Vulkan backend end-to-end
//! (device → surface → swapchain → render pass clear → present), and
//! exits on close or after the smoke-test budget. On platforms without
//! a Tier 0 windowing backend (macOS Phase 2+, stubs) the Null backend
//! path keeps the CI scaffold working.
//!
//! Flags supportés (brief §Comportement observable) :
//! - `--smoke-test`                — non-interactif, exit après 1 frame
//! - `--capture-frame=N`           — exit après la frame N (smoke-test only)
//! - `--gpu-prefer=<discrete|integrated|index:N>` — sélection hardware
//! - `--vulkan-driver=<auto|hardware|software>`   — sélection driver

const std = @import("std");
const builtin = @import("builtin");
const gal = @import("weld_render").gal;
const window_mod = @import("weld_core").platform.window;
const shaders = @import("shaders");

const log = std.log.scoped(.triangle);

const Args = struct {
    smoke_test: bool = false,
    capture_frame: ?u32 = null,
    gpu_preference: gal.types.GpuPreference = .auto,
    vulkan_driver: gal.types.VulkanDriver = .auto,

    fn parse(allocator: std.mem.Allocator, raw: []const [:0]const u8) !Args {
        _ = allocator;
        var args: Args = .{};
        for (raw[1..]) |a| {
            if (std.mem.eql(u8, a, "--smoke-test")) {
                args.smoke_test = true;
            } else if (std.mem.startsWith(u8, a, "--capture-frame=")) {
                args.capture_frame = try std.fmt.parseInt(u32, a[16..], 10);
            } else if (std.mem.startsWith(u8, a, "--gpu-prefer=")) {
                const v = a[13..];
                if (std.mem.eql(u8, v, "discrete")) args.gpu_preference = .discrete else if (std.mem.eql(u8, v, "integrated")) args.gpu_preference = .integrated else if (std.mem.startsWith(u8, v, "index:")) {
                    args.gpu_preference = .{ .index = try std.fmt.parseInt(u32, v[6..], 10) };
                }
            } else if (std.mem.startsWith(u8, a, "--vulkan-driver=")) {
                const v = a[16..];
                if (std.mem.eql(u8, v, "hardware")) args.vulkan_driver = .hardware else if (std.mem.eql(u8, v, "software")) args.vulkan_driver = .software;
            }
        }
        return args;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try Args.parse(allocator, raw_args);

    log.info("triangle: smoke={any} capture={any} gpu={any} driver={any}", .{
        args.smoke_test, args.capture_frame, args.gpu_preference, args.vulkan_driver,
    });

    if (supportsVulkanWindow()) {
        runVulkan(allocator, io, args) catch |e| {
            log.warn("vulkan path failed ({t}), falling back to null backend", .{e});
            try runNullBackend(allocator, args);
        };
    } else {
        try runNullBackend(allocator, args);
    }
}

fn supportsVulkanWindow() bool {
    return switch (builtin.os.tag) {
        .windows, .linux => true,
        else => false,
    };
}

const FRAME_WIDTH: u32 = 1280;
const FRAME_HEIGHT: u32 = 720;

const CAPTURE_PATH_DEFAULT: []const u8 = "out/smoke_test.ppm";

/// Triangle vertex layout: vec2 position (NDC) + vec3 color (RGB).
/// Matches `assets/shaders/triangle.vert.glsl` `in vec2 inPosition`
/// (location 0) + `in vec3 inColor` (location 1). Layed out as a packed
/// extern struct so the GAL vertex input descriptor reads the right
/// strides + offsets.
const TriangleVertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

/// RGB triangle in NDC clip space — bottom-left red, bottom-right green,
/// top blue. Patterns from S2 (`/tmp/s2-ref/src/spike/vk_setup.zig:triangle`).
const TRIANGLE_VERTICES = [_]TriangleVertex{
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
};

/// Bundle of GPU resources needed to draw the triangle. Created once at
/// init, reused across all frames + the capture pass, destroyed at
/// teardown. The clear color cycling lives on the render pass itself —
/// not on the pipeline — so the same pipeline draws the triangle on a
/// changing background.
const TrianglePipeline = struct {
    vert_module: gal.types.ShaderModuleHandle,
    frag_module: gal.types.ShaderModuleHandle,
    bgl: gal.types.BindGroupLayoutHandle,
    pipeline: gal.types.RenderPipelineHandle,
    vertex_buffer: gal.types.BufferHandle,

    fn init(device: *gal.vulkan_backend.Device, color_format: gal.types.TextureFormat) !TrianglePipeline {
        const vsm = try device.createShaderModule(.{
            .code = shaders.triangle_vert_spv,
            .label = "triangle.vs",
        });
        errdefer device.destroyShaderModule(vsm);
        const fsm = try device.createShaderModule(.{
            .code = shaders.triangle_frag_spv,
            .label = "triangle.fs",
        });
        errdefer device.destroyShaderModule(fsm);

        const bgl = try device.createBindGroupLayout(.{ .entries = &.{} });
        errdefer device.destroyBindGroupLayout(bgl);

        const pipeline = try device.createRenderPipeline(.{
            .label = "triangle.pso",
            .layout = &.{bgl},
            .vertex_module = vsm,
            .fragment_module = fsm,
            .color_targets = &.{.{ .format = color_format }},
            .vertex_buffers = &.{.{
                .stride = @sizeOf(TriangleVertex),
                .step_mode = .vertex,
                .attributes = &.{
                    .{ .location = 0, .format = .rg32_sfloat, .offset = @offsetOf(TriangleVertex, "pos") },
                    .{ .location = 1, .format = .rgb32_sfloat, .offset = @offsetOf(TriangleVertex, "color") },
                },
            }},
            .cull_mode = .none,
        });
        errdefer device.destroyRenderPipeline(pipeline);

        const vb = try device.createBuffer(.{
            .label = "triangle.vb",
            .size = @sizeOf(@TypeOf(TRIANGLE_VERTICES)),
            .usage = .{ .vertex = true, .copy_dst = true },
            // Phase 0 simplification: host-visible vertex buffer + map.
            // S2 uses a device-local buffer + staging upload; the GAL
            // path will gain a `device.writeBuffer` helper Phase 1+
            // that hides the staging dance. For now host-visible is
            // sufficient for 3 vertices.
            .host_visible = true,
        });
        errdefer device.destroyBuffer(vb);

        const mapped = try device.mapBuffer(vb);
        @memcpy(mapped[0..@sizeOf(@TypeOf(TRIANGLE_VERTICES))], std.mem.asBytes(&TRIANGLE_VERTICES));
        device.unmapBuffer(vb);

        return .{
            .vert_module = vsm,
            .frag_module = fsm,
            .bgl = bgl,
            .pipeline = pipeline,
            .vertex_buffer = vb,
        };
    }

    fn deinit(self: *TrianglePipeline, device: *gal.vulkan_backend.Device) void {
        device.destroyBuffer(self.vertex_buffer);
        device.destroyRenderPipeline(self.pipeline);
        device.destroyBindGroupLayout(self.bgl);
        device.destroyShaderModule(self.frag_module);
        device.destroyShaderModule(self.vert_module);
    }

    /// Bind pipeline + vertex buffer and draw 3 vertices. Caller owns
    /// the render pass scope. `pass` is duck-typed via `anytype` so the
    /// example does not depend on the backend-internal
    /// `RenderPassEncoder` type — the GAL public surface only exposes
    /// the methods we call here (`setPipeline`, `setVertexBuffer`,
    /// `draw`).
    fn draw(self: *const TrianglePipeline, pass: anytype) void {
        pass.setPipeline(self.pipeline);
        pass.setVertexBuffer(0, self.vertex_buffer, 0);
        pass.draw(3, 1, 0, 0);
    }
};

fn frameClearColor(frame: u32) gal.types.ColorClear {
    const t_norm: f32 = @as(f32, @floatFromInt(frame % 180)) / 180.0;
    const two_pi: f32 = 6.2831853;
    return .{
        .r = 0.5 + 0.5 * @sin(t_norm * two_pi),
        .g = 0.5 + 0.5 * @sin(t_norm * two_pi + 2.094),
        .b = 0.5 + 0.5 * @sin(t_norm * two_pi + 4.188),
        .a = 1.0,
    };
}

/// Render frame `frame_idx` into an offscreen R8G8B8A8_UNORM texture,
/// copy it through a staging buffer, and write the result as a binary
/// PPM (P6) to `path`. Used by the smoke-test capture path consumed by
/// `tests/render/capture.zig`. The `pipeline` argument is the same
/// triangle pipeline used in the interactive loop — drawn over the
/// clear-color background so the captured PPM exercises the full
/// forward path (vertex → rasterizer → fragment → blend), not just
/// a clear.
fn captureFrame(
    device: *gal.vulkan_backend.Device,
    pipeline: *const TrianglePipeline,
    allocator: std.mem.Allocator,
    io: std.Io,
    frame_idx: u32,
    path: []const u8,
) !void {
    const offscreen = try device.createTexture(.{
        .format = .rgba8_unorm,
        .width = FRAME_WIDTH,
        .height = FRAME_HEIGHT,
        .usage = .{ .color_attachment = true, .copy_src = true },
    });
    defer device.destroyTexture(offscreen);

    const offscreen_view = try device.createTextureView(offscreen, .{ .label = "capture.view" });
    defer device.destroyTextureView(offscreen_view);

    const staging_bytes: u64 = @as(u64, FRAME_WIDTH) * FRAME_HEIGHT * 4;
    const staging = try device.createBuffer(.{
        .label = "capture.staging",
        .size = staging_bytes,
        .usage = .{ .copy_dst = true },
        .host_visible = true,
    });
    defer device.destroyBuffer(staging);

    const fence = try device.createFence(false);
    defer device.destroyFence(fence);

    const enc = try device.createCommandEncoder("capture");
    defer device.destroyCommandEncoder(enc);

    var pass = try enc.beginRenderPass(.{
        .label = "capture.clear",
        .color_attachments = &.{.{
            .view = offscreen_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = frameClearColor(frame_idx),
            .final_layout = .transfer_src,
        }},
    });
    pass.setViewport(0, 0, @floatFromInt(FRAME_WIDTH), @floatFromInt(FRAME_HEIGHT), 0, 1);
    pass.setScissor(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
    pipeline.draw(&pass);
    pass.end();

    enc.copyTextureToBuffer(
        .{ .texture = offscreen, .aspect = .color },
        .{ .buffer = staging, .bytes_per_row = FRAME_WIDTH * 4 },
        .{ .width = FRAME_WIDTH, .height = FRAME_HEIGHT },
    );
    enc.finish();

    try device.submit(enc, .{ .fence = fence });
    try device.waitFence(fence, std.math.maxInt(u64));

    const rgba = try device.mapBuffer(staging);
    defer device.unmapBuffer(staging);

    try writePPM(allocator, io, path, rgba);
    log.info("captured frame {d} -> {s}", .{ frame_idx, path });
}

/// PPM P6 writer. Strips alpha from the RGBA8 source (drops every fourth
/// byte). `path`'s parent directory is created if missing. Binary P6 format:
/// "P6\n<W> <H>\n255\n" followed by W*H*3 bytes of RGB.
fn writePPM(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rgba: []const u8,
) !void {
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

    try w.print("P6\n{d} {d}\n255\n", .{ FRAME_WIDTH, FRAME_HEIGHT });

    const pixel_count = @as(usize, FRAME_WIDTH) * FRAME_HEIGHT;
    var rgb = try allocator.alloc(u8, pixel_count * 3);
    defer allocator.free(rgb);
    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        rgb[i * 3 + 0] = rgba[i * 4 + 0];
        rgb[i * 3 + 1] = rgba[i * 4 + 1];
        rgb[i * 3 + 2] = rgba[i * 4 + 2];
    }
    try w.writeAll(rgb);
    try w.flush();
}

fn runVulkan(allocator: std.mem.Allocator, io: std.Io, args: Args) !void {
    var window = try window_mod.Window.create(allocator, .{
        .title = "Weld Triangle (M0.4)",
        .width = FRAME_WIDTH,
        .height = FRAME_HEIGHT,
    });
    defer window.destroy();

    var device = try gal.vulkan_backend.Device.init(allocator, .{
        .label = "triangle",
        .gpu_preference = args.gpu_preference,
        .vulkan_driver = args.vulkan_driver,
        .enable_validation = builtin.mode == .Debug,
    });
    defer device.deinit();

    _ = try device.createSurfaceFromWindow(&window);

    const swap = try device.createSwapchain(.{
        .format = .bgra8_unorm,
        .width = FRAME_WIDTH,
        .height = FRAME_HEIGHT,
        .present_mode = .fifo,
    });
    defer device.destroySwapchain(swap);

    // Two triangle pipelines — Vulkan requires the pipeline's color
    // attachment format to match the render pass's, and our interactive
    // loop renders into a BGRA8_UNORM swapchain image while the capture
    // pass renders into an RGBA8_UNORM offscreen. Same shader modules
    // under the hood; the GAL rebuilds the pipeline state object per
    // descriptor. Pattern is cheap (3 vertices total, fixed pipeline)
    // and avoids the layout shenanigans of a single-pipeline / two-
    // format-coercion path.
    var triangle_swap = try TrianglePipeline.init(&device, .bgra8_unorm);
    defer triangle_swap.deinit(&device);
    var triangle_capture = try TrianglePipeline.init(&device, .rgba8_unorm);
    defer triangle_capture.deinit(&device);

    const image_ready = try device.createSemaphore();
    defer device.destroySemaphore(image_ready);
    const render_done = try device.createSemaphore();
    defer device.destroySemaphore(render_done);
    const in_flight = try device.createFence(false);
    defer device.destroyFence(in_flight);

    // Frame budget: smoke-test exits as soon as capture_frame (or 0) is
    // reached; interactive mode runs until window close.
    const capture_target: u32 = args.capture_frame orelse 0;
    const smoke_budget: u32 = capture_target + 1;

    var frame: u32 = 0;
    var should_close = false;

    while (true) : (frame += 1) {
        while (window.pollEvent()) |evt| switch (evt) {
            .close => should_close = true,
            else => {},
        };
        if (should_close) break;

        if (frame > 0) {
            device.waitFence(in_flight, std.math.maxInt(u64)) catch {};
            device.resetFence(in_flight) catch {};
        }

        const image_index = device.acquireNextImage(swap, image_ready, std.math.maxInt(u64)) catch |e| switch (e) {
            error.SwapchainOutOfDate => {
                log.warn("swapchain out of date, skipping frame", .{});
                continue;
            },
            else => return e,
        };
        const color_view = device.getSwapchainImageView(swap, image_index);

        const enc = try device.createCommandEncoder("frame");
        defer device.destroyCommandEncoder(enc);

        var pass = try enc.beginRenderPass(.{
            .label = "frame",
            .color_attachments = &.{.{
                .view = color_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = frameClearColor(frame),
            }},
        });
        pass.setViewport(0, 0, @floatFromInt(FRAME_WIDTH), @floatFromInt(FRAME_HEIGHT), 0, 1);
        pass.setScissor(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
        triangle_swap.draw(&pass);
        pass.end();
        enc.finish();

        try device.submit(enc, .{
            .wait_semaphore = image_ready,
            .signal_semaphore = render_done,
            .fence = in_flight,
        });
        device.present(swap, image_index, &.{render_done}) catch |e| switch (e) {
            error.SwapchainOutOfDate => log.warn("present hit out-of-date, continuing", .{}),
            else => return e,
        };

        if (args.capture_frame) |target| if (frame == target) {
            try captureFrame(&device, &triangle_capture, allocator, io, frame, CAPTURE_PATH_DEFAULT);
        };

        if (args.smoke_test and frame + 1 >= smoke_budget) break;
    }

    device.waitFence(in_flight, std.math.maxInt(u64)) catch {};

    log.info("triangle: rendered {d} frame(s) via vulkan", .{frame});
}

fn runNullBackend(allocator: std.mem.Allocator, args: Args) !void {
    var device = try gal.null_backend.Device.init(allocator, .{
        .label = "triangle",
        .gpu_preference = args.gpu_preference,
        .vulkan_driver = args.vulkan_driver,
    });
    defer device.deinit();

    const spv: [16]u8 align(4) = [_]u8{ 0x03, 0x02, 0x23, 0x07 } ** 4;
    const vsm = try device.createShaderModule(.{ .code = &spv, .label = "tri.vs" });
    defer device.destroyShaderModule(vsm);
    const fsm = try device.createShaderModule(.{ .code = &spv, .label = "tri.fs" });
    defer device.destroyShaderModule(fsm);

    const layout = try device.createBindGroupLayout(.{ .entries = &.{} });
    defer device.destroyBindGroupLayout(layout);

    const pipeline = try device.createRenderPipeline(.{
        .label = "tri.pso",
        .layout = &.{layout},
        .vertex_module = vsm,
        .fragment_module = fsm,
        .color_targets = &.{.{ .format = .bgra8_unorm }},
    });
    defer device.destroyRenderPipeline(pipeline);

    const swap = try device.createSwapchain(.{ .width = FRAME_WIDTH, .height = FRAME_HEIGHT });
    defer device.destroySwapchain(swap);
    const image_ready = try device.createSemaphore();
    defer device.destroySemaphore(image_ready);
    const render_done = try device.createSemaphore();
    defer device.destroySemaphore(render_done);
    const in_flight = try device.createFence(false);
    defer device.destroyFence(in_flight);

    const max_frames: u32 = if (args.smoke_test) 1 else 1;
    var frame: u32 = 0;
    while (frame < max_frames) : (frame += 1) {
        const image_index = try device.acquireNextImage(swap, image_ready, std.math.maxInt(u64));
        const color_view = device.getSwapchainImageView(swap, image_index);

        const enc = try device.createCommandEncoder("frame");
        defer device.destroyCommandEncoder(enc);

        var pass = enc.beginRenderPass(.{
            .color_attachments = &.{.{
                .view = color_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ .r = 0.05, .g = 0.05, .b = 0.08, .a = 1.0 },
            }},
        });
        pass.setPipeline(pipeline);
        pass.setViewport(0, 0, @floatFromInt(FRAME_WIDTH), @floatFromInt(FRAME_HEIGHT), 0, 1);
        pass.setScissor(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
        pass.draw(3, 1, 0, 0);
        pass.end();
        enc.finish();

        try device.submit(enc, .{
            .wait_semaphore = image_ready,
            .signal_semaphore = render_done,
            .fence = in_flight,
        });
        try device.present(swap, image_index, &.{render_done});
        try device.waitFence(in_flight, std.math.maxInt(u64));
    }

    log.info("triangle: completed {d} null-backend frame(s)", .{frame});
}
