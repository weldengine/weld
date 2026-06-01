//! Queue Vulkan — Phase 0 / M0.4.
//!
//! Phase 0: a single queue (graphics + compute + transfer + present
//! fused), inherited from the queue family selection in `device.zig`. The
//! handle exposed on the GAL side is a direct cast of the `*vk.Queue` pointer.
//!
//! Phase 1+: dedicated compute/transfer queues if the corresponding queue
//! family exists on the selected device — useful for async compute
//! (V-Buffer culling parallel to the depth prepass, for example).

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Retrieves the Vulkan queue associated with the requested type. Phase 0:
/// always returns the Device's single fused graphics+compute+transfer queue.
pub fn get(device: *Device, queue_type: types.QueueType) types.Error!types.QueueHandle {
    _ = queue_type;
    return @ptrCast(device.vk_queue);
}

/// Reverse conversion `QueueHandle` → `*vk.Queue` — used by the helpers
/// that must submit work to the native queue.
pub fn fromHandle(handle: types.QueueHandle) *vk.Queue {
    return @ptrCast(@alignCast(handle));
}
