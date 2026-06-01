//! GAL Null backend smoke — Phase 0 / M0.4.
//!
//! Exercises the brief §Acceptance criteria > Tests pattern:
//! - `Null backend completes a frame without panic` — Device + Queue +
//!   BindGroup + RenderPipeline + 1 frame cycle without crash.
//! - `Null backend satisfies comptime interface check` — verification that
//!   `interface.checkBackend(Null) == void`.
//!
//! Acts as the **root file** to also run all the inline tests of the
//! `src/modules/render/gal/**/*.zig` files (cf. `engine-zig-conventions.md`
//! §13 — lazy analysis guard / mandatory module rooting). Without the
//! explicit pin via `comptime { _ = gal.X; }`, Zig 0.16 silently skips
//! the `test` blocks of modules not referenced from the root.

const std = @import("std");
const gal = @import("weld_render");

// ---------------------------------------------------------------------- Pins --
//
// Guarantee the analysis of the inline tests under `src/modules/render/gal/`.
// The `gal/main.zig` module already re-exports its sub-files via `pub const`,
// but we also pin explicitly to withstand a future refactor that would
// turn some re-exports private.

comptime {
    _ = gal.types;
    _ = gal.escape_hatches;
    _ = gal.interface;
    _ = gal.barriers;
    _ = gal.null_backend;
}

// ---------------------------------------------------------------------- Tests --

test "Null backend satisfies comptime interface check" {
    // If a method required by the interface is missing on the Null side, this
    // test does not even compile (cf. `gal/interface.zig`). The runtime is trivial.
    comptime gal.interface.checkBackend(gal.null_backend.Device);
    try std.testing.expect(true);
}

test "Null backend completes a frame without panic" {
    const allocator = std.testing.allocator;
    var device = try gal.null_backend.Device.init(allocator, .{ .label = "smoke" });
    defer device.deinit();

    // BindGroupLayout + BindGroup
    const layout = try device.createBindGroupLayout(.{
        .label = "uniforms",
        .entries = &.{
            .{ .binding = 0, .visibility = gal.types.ShaderStage.all_graphics, .binding_type = .uniform_buffer },
        },
    });
    defer device.destroyBindGroupLayout(layout);

    const ubo = try device.createBuffer(.{
        .label = "ubo",
        .size = 64,
        .usage = .{ .uniform = true, .copy_dst = true },
        .host_visible = false,
    });
    defer device.destroyBuffer(ubo);

    const group = try device.createBindGroup(.{
        .label = "uniforms",
        .layout = layout,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .handle = ubo } } },
        },
    });
    defer device.destroyBindGroup(group);

    // ShaderModule (4-byte aligned SPIR-V stub — Null does not dereference it)
    const spv: [16]u8 align(4) = [_]u8{ 0x03, 0x02, 0x23, 0x07 } ** 4;
    const vsm = try device.createShaderModule(.{ .label = "tri_vs", .code = &spv });
    defer device.destroyShaderModule(vsm);
    const fsm = try device.createShaderModule(.{ .label = "tri_fs", .code = &spv });
    defer device.destroyShaderModule(fsm);

    // RenderPipeline
    const pipeline = try device.createRenderPipeline(.{
        .label = "tri",
        .layout = &.{layout},
        .vertex_module = vsm,
        .fragment_module = fsm,
        .color_targets = &.{
            .{ .format = .bgra8_unorm },
        },
        .depth_format = .d32_sfloat,
        .depth_test_enabled = true,
        .depth_write_enabled = true,
    });
    defer device.destroyRenderPipeline(pipeline);

    // Swapchain + sync
    const swap = try device.createSwapchain(.{ .width = 1280, .height = 720 });
    defer device.destroySwapchain(swap);

    const image_ready = try device.createSemaphore();
    defer device.destroySemaphore(image_ready);
    const present_ready = try device.createSemaphore();
    defer device.destroySemaphore(present_ready);
    const in_flight = try device.createFence(false);
    defer device.destroyFence(in_flight);

    // Frame : acquire → encode → present
    const image_index = try device.acquireNextImage(swap, image_ready, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u32, 0), image_index);

    // M0.4 § Scope Post-Review extension : the swapchain image view
    // accessor returns a non-zero handle (Null stub uses a monotonic
    // counter — content is opaque, just `isValid()` matters).
    const swap_view = device.getSwapchainImageView(swap, image_index);
    try std.testing.expect(swap_view.isValid());

    const queue = try device.getQueue(.graphics);
    try std.testing.expect(@intFromPtr(queue) != 0);

    const enc = try device.createCommandEncoder("frame");
    defer device.destroyCommandEncoder(enc);

    // Target texture + view (Null backend, never resolved on the GPU side).
    const color = try device.createTexture(.{
        .format = .bgra8_unorm,
        .width = 1280,
        .height = 720,
        .usage = .{ .color_attachment = true },
    });
    defer device.destroyTexture(color);
    const color_view = try device.createTextureView(color, .{ .label = "frame.color" });
    defer device.destroyTextureView(color_view);

    const depth = try device.createTexture(.{
        .format = .d32_sfloat,
        .width = 1280,
        .height = 720,
        .usage = .{ .depth_stencil_attachment = true },
    });
    defer device.destroyTexture(depth);
    const depth_view = try device.createTextureView(depth, .{ .label = "frame.depth" });
    defer device.destroyTextureView(depth_view);

    var pass = enc.beginRenderPass(.{
        .label = "forward",
        .color_attachments = &.{
            .{ .view = color_view, .load_op = .clear, .store_op = .store },
        },
        .depth_stencil_attachment = .{
            .view = depth_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear = 1.0,
        },
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, group);
    pass.setViewport(0, 0, 1280, 720, 0, 1);
    pass.setScissor(0, 0, 1280, 720);
    pass.draw(3, 1, 0, 0);
    pass.end();

    // M0.4 § Scope Post-Review extension : copyTextureToBuffer is part of
    // the public CommandEncoder surface. The Null backend no-ops, but the
    // call must compile and accept the WebGPU-canonical struct triple.
    const staging = try device.createBuffer(.{
        .label = "smoke_staging",
        .size = 1280 * 720 * 4,
        .usage = .{ .copy_dst = true },
        .host_visible = true,
    });
    defer device.destroyBuffer(staging);
    enc.copyTextureToBuffer(
        .{ .texture = color, .aspect = .color },
        .{ .buffer = staging, .bytes_per_row = 1280 * 4 },
        .{ .width = 1280, .height = 720 },
    );

    enc.finish();

    try device.present(swap, image_index, &.{present_ready});
    try device.waitFence(in_flight, std.math.maxInt(u64));
}

test "Null backend reports no Phase 0 optional features" {
    const allocator = std.testing.allocator;
    var device = try gal.null_backend.Device.init(allocator, .{});
    defer device.deinit();
    // Phase 0 : no escape hatch is marked as supported by the Null.
    try std.testing.expect(!device.supports(.timeline_semaphore));
    try std.testing.expect(!device.supports(.descriptor_indexing));
    try std.testing.expect(!device.supports(.ray_tracing));
}

test "BarrierTracker integrates with GAL public types" {
    var tracker = gal.barriers.BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const tex = gal.types.TextureHandle{ .inner = 42 };

    // Pass A : depth prepass writes the texture as depth attachment.
    try tracker.trackTexture(tex, .{
        .stage = .{ .vertex = true, .fragment = true },
        .access = .{ .write = true, .depth_attachment = true },
        .layout = .depth_stencil_attachment,
    }, .undefined);

    // Pass B : forward pass reads the depth as sampled (depth test).
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .undefined);

    const barriers = tracker.consumeRecorded();
    try std.testing.expect(barriers.len >= 1);
}
