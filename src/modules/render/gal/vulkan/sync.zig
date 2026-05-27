//! Sync primitives Vulkan — Fence + Semaphore — Phase 0 / M0.4.
//!
//! Mapping direct GAL handle ↔ Vulkan handle via `@intFromEnum` /
//! `@enumFromInt`. Aucun registry interne nécessaire — la libération
//! d'une Fence/Semaphore ne demande qu'un appel `destroyX(vk_handle)`.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Crée une `vk.Fence` (sync CPU↔GPU). `signaled = true` la rend
/// initialement signalée — utile pour les fences associées à la première
/// frame d'une pipeline N-deep.
pub fn createFence(device: *Device, signaled: bool) types.Error!types.FenceHandle {
    const ci: vk.FenceCreateInfo = .{
        .flags = if (signaled) .{ .signaled = true } else .empty,
    };
    const f = device.vk_device.createFence(&ci, null) catch return error.BackendInternal;
    return .{ .inner = @intFromEnum(f) };
}

/// Libère une Fence. No-op si `handle.inner == 0`.
pub fn destroyFence(device: *Device, handle: types.FenceHandle) void {
    if (handle.inner == 0) return;
    device.vk_device.destroyFence(@enumFromInt(handle.inner), null);
}

/// Bloque jusqu'à signalement de la Fence (ou timeout en ns).
pub fn waitFence(device: *Device, handle: types.FenceHandle, timeout_ns: u64) types.Error!void {
    if (handle.inner == 0) return error.InvalidArgument;
    const f: vk.Fence = @enumFromInt(handle.inner);
    device.vk_device.waitForFences(&.{f}, 1, timeout_ns) catch return error.BackendInternal;
}

/// Reset une Fence (état unsignaled) pour réutilisation à la frame suivante.
pub fn resetFence(device: *Device, handle: types.FenceHandle) types.Error!void {
    if (handle.inner == 0) return error.InvalidArgument;
    const f: vk.Fence = @enumFromInt(handle.inner);
    device.vk_device.resetFences(&.{f}) catch return error.BackendInternal;
}

/// Crée un sémaphore binaire (sync GPU↔GPU, typiquement pour le wait/signal
/// de la swapchain).
pub fn createSemaphore(device: *Device) types.Error!types.SemaphoreHandle {
    const ci: vk.SemaphoreCreateInfo = .{ .flags = .empty };
    const s = device.vk_device.createSemaphore(&ci, null) catch return error.BackendInternal;
    return .{ .inner = @intFromEnum(s) };
}

/// Libère un sémaphore. No-op si `handle.inner == 0`.
pub fn destroySemaphore(device: *Device, handle: types.SemaphoreHandle) void {
    if (handle.inner == 0) return;
    device.vk_device.destroySemaphore(@enumFromInt(handle.inner), null);
}
