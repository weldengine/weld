//! Sync primitives Vulkan — Fence + Semaphore — Phase 0 / M0.4.
//!
//! Direct GAL handle ↔ Vulkan handle mapping via `@intFromEnum` /
//! `@enumFromInt`. No internal registry needed — freeing a
//! Fence/Semaphore only requires a `destroyX(vk_handle)` call.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Creates a `vk.Fence` (CPU↔GPU sync). `signaled = true` makes it
/// initially signaled — useful for fences associated with the first
/// frame of an N-deep pipeline.
pub fn createFence(device: *Device, signaled: bool) types.Error!types.FenceHandle {
    const ci: vk.FenceCreateInfo = .{
        .flags = if (signaled) .{ .signaled = true } else .empty,
    };
    const f = device.vk_device.createFence(&ci, null) catch return error.BackendInternal;
    return .{ .inner = @intFromEnum(f) };
}

/// Frees a Fence. No-op if `handle.inner == 0`.
pub fn destroyFence(device: *Device, handle: types.FenceHandle) void {
    if (handle.inner == 0) return;
    device.vk_device.destroyFence(@enumFromInt(handle.inner), null);
}

/// Blocks until the Fence is signaled (or timeout in ns).
pub fn waitFence(device: *Device, handle: types.FenceHandle, timeout_ns: u64) types.Error!void {
    if (handle.inner == 0) return error.InvalidArgument;
    const f: vk.Fence = @enumFromInt(handle.inner);
    device.vk_device.waitForFences(&.{f}, 1, timeout_ns) catch return error.BackendInternal;
}

/// Resets a Fence (unsignaled state) for reuse on the next frame.
pub fn resetFence(device: *Device, handle: types.FenceHandle) types.Error!void {
    if (handle.inner == 0) return error.InvalidArgument;
    const f: vk.Fence = @enumFromInt(handle.inner);
    device.vk_device.resetFences(&.{f}) catch return error.BackendInternal;
}

/// Creates a binary semaphore (GPU↔GPU sync, typically for the swapchain
/// wait/signal).
pub fn createSemaphore(device: *Device) types.Error!types.SemaphoreHandle {
    const ci: vk.SemaphoreCreateInfo = .{ .flags = .empty };
    const s = device.vk_device.createSemaphore(&ci, null) catch return error.BackendInternal;
    return .{ .inner = @intFromEnum(s) };
}

/// Frees a semaphore. No-op if `handle.inner == 0`.
pub fn destroySemaphore(device: *Device, handle: types.SemaphoreHandle) void {
    if (handle.inner == 0) return;
    device.vk_device.destroySemaphore(@enumFromInt(handle.inner), null);
}
