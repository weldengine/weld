//! Vulkan frame cycle — Phase 0 / M0.4.
//!
//! Absorbs the role of the `vk_frame.zig` spike (removed, brief §Removals).
//! Phase 0 exposes a submission helper (`submit`) that takes a finished
//! CommandEncoder and a sync pair (wait/signal semaphore + fence) and
//! submits to the graphics queue.
//!
//! The render loop on the caller side composes the building blocks:
//! 1. `acquireNextImage(swapchain, image_ready)` → image_index
//! 2. `createCommandEncoder()` → record
//! 3. `submit(encoder, .{ wait = image_ready, signal = render_done, fence = inflight })`
//! 4. `present(swapchain, image_index, &.{ render_done })`
//! 5. `waitFence(inflight)` (on the next frame, for a 2-deep pipeline)
//!
//! Phase 1+: high-level `drawFrame(graph: *RenderGraph)` helper that orchestrates
//! the whole thing from the render graph.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const cmd_mod = @import("command_encoder.zig");

/// Sync pair for a frame submission.
pub const SubmitSync = struct {
    /// Semaphore to wait on before execution (typically `image_ready` from
    /// `acquireNextImage`).
    wait_semaphore: ?types.SemaphoreHandle = null,
    /// Stage(s) the wait applies to (color attachment by default).
    wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output = true },
    /// Semaphore to signal at end of execution (typically `render_done` to
    /// pass to `present`).
    signal_semaphore: ?types.SemaphoreHandle = null,
    /// Fence signaled when the GPU has finished this submission.
    fence: ?types.FenceHandle = null,
};

/// Submits a finished CommandEncoder to the graphics queue.
pub fn submit(
    device: *Device,
    encoder: *cmd_mod.CommandEncoder,
    sync: SubmitSync,
) types.Error!void {
    if (!encoder.finished) return error.InvalidArgument;

    var wait_sems: [1]vk.Semaphore = .{.null};
    var signal_sems: [1]vk.Semaphore = .{.null};
    var wait_stage: vk.PipelineStageFlags = sync.wait_stage;

    var n_wait: u32 = 0;
    var n_signal: u32 = 0;

    if (sync.wait_semaphore) |s| {
        wait_sems[0] = @enumFromInt(s.inner);
        n_wait = 1;
    }
    if (sync.signal_semaphore) |s| {
        signal_sems[0] = @enumFromInt(s.inner);
        n_signal = 1;
    }

    const cbs: [1]*vk.CommandBuffer = .{encoder.cb};
    const submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = n_wait,
        .p_wait_semaphores = if (n_wait > 0) @ptrCast(&wait_sems) else undefined,
        .p_wait_dst_stage_mask = if (n_wait > 0) @ptrCast(&wait_stage) else undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cbs),
        .signal_semaphore_count = n_signal,
        .p_signal_semaphores = if (n_signal > 0) @ptrCast(&signal_sems) else undefined,
    };
    const fence_vk: vk.Fence = if (sync.fence) |f| @enumFromInt(f.inner) else .null;
    device.vk_queue.submit(&.{submit_info}, fence_vk) catch return error.BackendInternal;
}

/// One-shot helper: allocates a command buffer, the body is called to
/// record into it, submits and waits for completion. Phase 0 useful for
/// staging transfers (e.g. vertex buffer upload).
pub fn oneShot(
    device: *Device,
    body: anytype,
    args: anytype,
) types.Error!void {
    const enc = try cmd_mod.create(device, "oneshot");
    defer cmd_mod.destroy(device, enc);

    @call(.auto, body, .{enc} ++ args);
    enc.finish();

    try submit(device, enc, .{});
    device.vk_queue.waitIdle() catch return error.BackendInternal;
}
