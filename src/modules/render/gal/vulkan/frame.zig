//! Cycle frame Vulkan — Phase 0 / M0.4.
//!
//! Absorbe le rôle du spike `vk_frame.zig` (suppression brief §Suppressions).
//! Phase 0 expose un helper de submission (`submit`) qui prend un
//! CommandEncoder finalisé et une sync pair (wait/signal semaphore + fence)
//! et soumet à la queue graphics.
//!
//! Le render loop côté caller compose les briques :
//! 1. `acquireNextImage(swapchain, image_ready)` → image_index
//! 2. `createCommandEncoder()` → record
//! 3. `submit(encoder, .{ wait = image_ready, signal = render_done, fence = inflight })`
//! 4. `present(swapchain, image_index, &.{ render_done })`
//! 5. `waitFence(inflight)` (sur la frame suivante, pour pipeline 2-deep)
//!
//! Phase 1+ : helper haut-niveau `drawFrame(graph: *RenderGraph)` qui orchestre
//! l'ensemble depuis le render graph.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const cmd_mod = @import("command_encoder.zig");

/// Sync pair pour la submission d'une frame.
pub const SubmitSync = struct {
    /// Sémaphore à attendre avant exécution (typiquement `image_ready` depuis
    /// `acquireNextImage`).
    wait_semaphore: ?types.SemaphoreHandle = null,
    /// Stage(s) auxquels le wait s'applique (par défaut color attachment).
    wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output = true },
    /// Sémaphore à signaler en fin d'exécution (typiquement `render_done` à
    /// passer à `present`).
    signal_semaphore: ?types.SemaphoreHandle = null,
    /// Fence signalée quand la GPU a fini cette submission.
    fence: ?types.FenceHandle = null,
};

/// Soumet un CommandEncoder finalisé à la queue graphics.
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

/// Helper one-shot : alloue un command buffer, le body est appelé pour
/// enregistrer dedans, soumet et attend la fin. Phase 0 utile pour les
/// transferts de staging (e.g. upload de vertex buffer).
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
