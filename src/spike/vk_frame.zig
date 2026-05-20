//! Per-frame rendering for the S2 spike. Throwaway with the rest of
//! `src/spike/`. Acquire / record / submit / present, with swapchain
//! recreation on `error_out_of_date_khr` or `suboptimal_khr`.
//!
//! Returns true if a frame was successfully presented; false if the
//! caller should call `recreateSwapchain` and try again next iteration.
//! Errors propagate upstream.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const setup = @import("vk_setup.zig");

/// Submit one frame through the S2 spike's swapchain: wait the
/// fence, acquire, record commands, submit, present. Returns `false`
/// when the swapchain is out-of-date (caller should rebuild it).
pub fn drawFrame(r: *setup.Renderer) vk.Error!bool {
    const frame = r.current_frame;

    // Wait for the GPU to finish the previous frame using this slot.
    try r.device.waitForFences(&.{r.in_flight[frame]}, 1, std.math.maxInt(u64));

    // Acquire the next swapchain image. We catch SUBOPTIMAL / OUT_OF_DATE
    // here so the caller can drive a swapchain rebuild without bringing
    // down the whole renderer.
    var image_index: u32 = 0;
    const acquire_result = vk.device_dispatch.vkAcquireNextImageKHR(
        r.device,
        r.swapchain,
        std.math.maxInt(u64),
        r.image_available[frame],
        .null,
        &image_index,
    );
    switch (acquire_result) {
        .success, .suboptimal_khr => {},
        .error_out_of_date_khr => {
            r.swapchain_dirty = true;
            return false;
        },
        else => try vk.checkResult(acquire_result),
    }

    // Reset the fence only after we are sure we will submit work.
    try r.device.resetFences(&.{r.in_flight[frame]});

    const cb = r.command_buffers[frame];
    try cb.resetCommandBuffer(.empty);
    try recordCommandBuffer(r, cb, image_index);

    const wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output = true };
    const submit_buffers: [1]*vk.CommandBuffer = .{cb};
    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&r.image_available[frame]),
        .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&submit_buffers),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&r.render_finished[frame]),
    };
    try r.queue.submit(&.{submit}, r.in_flight[frame]);

    var present_result: vk.Result = .success;
    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&r.render_finished[frame]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&r.swapchain),
        .p_image_indices = @ptrCast(&image_index),
        .p_results = @ptrCast(&present_result),
    };
    // Direct dispatch call — the idiomatic wrapper folds `.suboptimal_khr`
    // into success via `checkResult`, but we need to observe it to drive
    // the swapchain rebuild path.
    const present_call = vk.device_dispatch.vkQueuePresentKHR(r.queue, &present_info);
    switch (present_call) {
        // `.suboptimal_khr` still presents the frame (just with scaling),
        // so the swapchain image contents are valid for the PPM capture
        // path. `.error_out_of_date_khr` did *not* present — leaving
        // `last_presented_image` untouched here avoids the field
        // indexing into a stale `swapchain_images` slice after the
        // upcoming rebuild.
        .success, .suboptimal_khr => r.last_presented_image = image_index,
        .error_out_of_date_khr => r.swapchain_dirty = true,
        else => try vk.checkResult(present_call),
    }

    r.current_frame = (r.current_frame + 1) % setup.max_frames_in_flight;
    return true;
}

fn recordCommandBuffer(r: *setup.Renderer, cb: *vk.CommandBuffer, image_index: u32) !void {
    const begin: vk.CommandBufferBeginInfo = .{
        .flags = .empty,
        .p_inheritance_info = null,
    };
    try cb.beginCommandBuffer(&begin);

    const clear: vk.ClearValue = .{ .color = .{ .float32 = .{ 0.05, 0.05, 0.08, 1.0 } } };
    const rp_begin: vk.RenderPassBeginInfo = .{
        .render_pass = r.render_pass,
        .framebuffer = r.framebuffers[image_index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = r.swapchain_extent,
        },
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&clear),
    };
    cb.cmdBeginRenderPass(&rp_begin, .@"inline");

    cb.cmdBindPipeline(.graphics, r.pipeline);

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(r.swapchain_extent.width),
        .height = @floatFromInt(r.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    cb.cmdSetViewport(0, &.{viewport});
    const scissor: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = r.swapchain_extent,
    };
    cb.cmdSetScissor(0, &.{scissor});

    const offset: vk.DeviceSize = 0;
    cb.cmdBindVertexBuffers(0, &.{r.vertex_buffer}, &.{offset});
    cb.cmdDraw(3, 1, 0, 0);
    cb.cmdEndRenderPass();
    try cb.endCommandBuffer();
}
