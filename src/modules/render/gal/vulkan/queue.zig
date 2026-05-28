//! Queue Vulkan — Phase 0 / M0.4.
//!
//! Phase 0 : une seule queue (graphics + compute + transfer + present
//! fused), héritée de la sélection de queue family de `device.zig`. Le
//! handle exposé côté GAL est un cast direct du pointeur `*vk.Queue`.
//!
//! Phase 1+ : queues compute/transfer dédiées si la queue family
//! correspondante existe sur le device sélectionné — utile pour async
//! compute (V-Buffer culling parallèle au depth prepass, par exemple).

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Récupère la queue Vulkan associée au type demandé. Phase 0 : retourne
/// toujours la queue unique fused graphics+compute+transfer du Device.
pub fn get(device: *Device, queue_type: types.QueueType) types.Error!types.QueueHandle {
    _ = queue_type;
    return @ptrCast(device.vk_queue);
}

/// Conversion inverse `QueueHandle` → `*vk.Queue` — utilisée par les
/// helpers qui doivent soumettre du travail à la queue native.
pub fn fromHandle(handle: types.QueueHandle) *vk.Queue {
    return @ptrCast(@alignCast(handle));
}
