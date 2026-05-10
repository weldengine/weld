//! PPM (P6 binary) capture of a swapchain image for the S2 smoke-test.
//!
//! Path of the capture:
//!     `vkDeviceWaitIdle` → copy `swapchain_images[last_presented_image]`
//!     into a host-visible staging buffer via a one-shot command buffer →
//!     convert BGRA → RGB on the CPU → write the P6 header + raw bytes.
//!
//! The validation layers may flag the copy as "image owned by the
//! presentation engine"; that is accepted for the spike. Phase 0.4's GAL
//! eliminates the path entirely by routing captures through an offscreen
//! intermediate target.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const setup = @import("vk_setup.zig");

pub const Error = error{
    NoPresentedImage,
    NoCompatibleMemory,
    CaptureWriteFailed,
} || setup.SetupError;

/// Capture `r.swapchain_images[r.last_presented_image]` into `path`.
/// Caller must have stood up `r` successfully and presented at least
/// one frame. Performs its own `vkDeviceWaitIdle` so callers do not
/// have to.
pub fn capture(
    r: *setup.Renderer,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) Error!void {
    const image_index = r.last_presented_image orelse return error.NoPresentedImage;
    const image = r.swapchain_images[image_index];
    const width = r.swapchain_extent.width;
    const height = r.swapchain_extent.height;
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const total_bytes: vk.DeviceSize = @as(vk.DeviceSize, pixel_count) * 4; // B8G8R8A8

    try r.device.waitIdle();

    // ---- Staging buffer (host-visible, host-coherent) ----
    var buf_usage: vk.BufferUsageFlags = .empty;
    buf_usage.transfer_dst = true;
    const buf_ci: vk.BufferCreateInfo = .{
        .flags = .empty,
        .size = total_bytes,
        .usage = buf_usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    const staging = try r.device.createBuffer(&buf_ci, null);
    defer r.device.destroyBuffer(staging, null);

    const reqs = r.device.getBufferMemoryRequirements(staging);
    const mem_props = r.physical_device.getPhysicalDeviceMemoryProperties();
    const type_index = pickMemoryType(mem_props, reqs.memory_type_bits, .{ .host_visible = true, .host_coherent = true }) orelse return error.NoCompatibleMemory;
    const mem_ai: vk.MemoryAllocateInfo = .{
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    };
    const memory = try r.device.allocateMemory(&mem_ai, null);
    defer r.device.freeMemory(memory, null);
    try r.device.bindBufferMemory(staging, memory, 0);

    // ---- One-shot command buffer ----
    const pool_ci: vk.CommandPoolCreateInfo = .{
        .flags = .{ .transient = true },
        .queue_family_index = r.queue_family_index,
    };
    const pool = try r.device.createCommandPool(&pool_ci, null);
    defer r.device.destroyCommandPool(pool, null);

    const alloc_ci: vk.CommandBufferAllocateInfo = .{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var bufs: [1]*vk.CommandBuffer = undefined;
    try r.device.allocateCommandBuffers(&alloc_ci, &bufs);
    const cb = bufs[0];

    const begin: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit = true },
        .p_inheritance_info = null,
    };
    try cb.beginCommandBuffer(&begin);

    // Transition: PRESENT_SRC_KHR → TRANSFER_SRC_OPTIMAL.
    const to_src: vk.ImageMemoryBarrier = .{
        .src_access_mask = .empty,
        .dst_access_mask = .{ .transfer_read = true },
        .old_layout = .present_src_khr,
        .new_layout = .transfer_src_optimal,
        .src_queue_family_index = ~@as(u32, 0), // VK_QUEUE_FAMILY_IGNORED
        .dst_queue_family_index = ~@as(u32, 0),
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    cb.cmdPipelineBarrier(
        .{ .bottom_of_pipe = true },
        .{ .transfer = true },
        .empty,
        &.{},
        &.{},
        &.{to_src},
    );

    // Copy image → buffer.
    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    cb.cmdCopyImageToBuffer(image, .transfer_src_optimal, staging, &.{region});

    // Transition back to PRESENT_SRC_KHR (cosmetic — we're about to exit).
    const to_present: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{ .transfer_read = true },
        .dst_access_mask = .empty,
        .old_layout = .transfer_src_optimal,
        .new_layout = .present_src_khr,
        .src_queue_family_index = ~@as(u32, 0),
        .dst_queue_family_index = ~@as(u32, 0),
        .image = image,
        .subresource_range = to_src.subresource_range,
    };
    cb.cmdPipelineBarrier(
        .{ .transfer = true },
        .{ .bottom_of_pipe = true },
        .empty,
        &.{},
        &.{},
        &.{to_present},
    );

    try cb.endCommandBuffer();

    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&bufs),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try r.queue.submit(&.{submit}, .null);
    try r.queue.waitIdle();

    // ---- Read pixels + convert BGRA→RGB ----
    const mapped_opt = try r.device.mapMemory(memory, 0, total_bytes, .empty);
    const mapped = mapped_opt orelse return error.NoCompatibleMemory;
    defer r.device.unmapMemory(memory);

    const bgra: [*]u8 = @ptrCast(mapped);
    const rgb = try gpa.alloc(u8, pixel_count * 3);
    defer gpa.free(rgb);

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        rgb[i * 3 + 0] = bgra[i * 4 + 2]; // R from BGRA's index 2
        rgb[i * 3 + 1] = bgra[i * 4 + 1]; // G
        rgb[i * 3 + 2] = bgra[i * 4 + 0]; // B
    }

    // ---- Write file ----
    var file = dir.createFile(io, path, .{}) catch return error.CaptureWriteFailed;
    defer file.close(io);

    var write_buf: [16 * 1024]u8 = undefined;
    var w = file.writer(io, &write_buf);
    // P6 header: magic, width height, max value, newline. The trailing
    // newline before the raw pixels is part of the format spec.
    w.interface.print("P6\n{d} {d}\n255\n", .{ width, height }) catch return error.CaptureWriteFailed;
    w.interface.writeAll(rgb) catch return error.CaptureWriteFailed;
    w.interface.flush() catch return error.CaptureWriteFailed;
}

fn pickMemoryType(props: vk.PhysicalDeviceMemoryProperties, type_bits: u32, want: vk.MemoryPropertyFlags) ?u32 {
    var i: u32 = 0;
    while (i < props.memory_type_count) : (i += 1) {
        const candidate = props.memory_types[i];
        const want_bits: u32 = @bitCast(want);
        const have_bits: u32 = @bitCast(candidate.property_flags);
        if ((type_bits & (@as(u32, 1) << @intCast(i))) != 0 and (have_bits & want_bits) == want_bits) {
            return i;
        }
    }
    return null;
}
