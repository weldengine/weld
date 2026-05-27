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
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try Args.parse(allocator, raw_args);

    log.info("triangle: smoke={any} capture={any} gpu={any} driver={any}", .{
        args.smoke_test, args.capture_frame, args.gpu_preference, args.vulkan_driver,
    });

    if (supportsVulkanWindow()) {
        runVulkan(allocator, args) catch |e| {
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

fn runVulkan(allocator: std.mem.Allocator, args: Args) !void {
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

        const t_norm: f32 = @as(f32, @floatFromInt(frame % 180)) / 180.0;
        const two_pi: f32 = 6.2831853;
        const clear_color: gal.types.ColorClear = .{
            .r = 0.5 + 0.5 * @sin(t_norm * two_pi),
            .g = 0.5 + 0.5 * @sin(t_norm * two_pi + 2.094),
            .b = 0.5 + 0.5 * @sin(t_norm * two_pi + 4.188),
            .a = 1.0,
        };

        var pass = try enc.beginRenderPass(.{
            .label = "frame.clear",
            .color_attachments = &.{.{
                .view = color_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = clear_color,
            }},
        });
        pass.setViewport(0, 0, @floatFromInt(FRAME_WIDTH), @floatFromInt(FRAME_HEIGHT), 0, 1);
        pass.setScissor(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
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
