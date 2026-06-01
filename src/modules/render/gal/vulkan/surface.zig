//! Window → `vk.SurfaceKHR` helper — M0.4 § Scope — Post-Review Complement.
//!
//! Bridges the Tier 0 `platform.window.Window` (M0.3) to a Vulkan
//! `SurfaceKHR`. Lives under `gal/vulkan/` so the lint rule
//! `no_device_dispatch_outside_gal` keeps holding (instance-level
//! dispatch is used, not `device_dispatch.*`, but the helper still
//! belongs inside the backend module by construction).
//!
//! Dispatch is comptime per platform:
//!     - Windows  → `Instance.createWin32SurfaceKHR` consuming
//!                  `(HINSTANCE, HWND)` from the Win32 backend.
//!     - Linux    → `Instance.createWaylandSurfaceKHR` consuming
//!                  `(*wl_display, *wl_surface)` from the Wayland
//!                  backend.
//!     - others   → `error.Unsupported` (macOS path lands when the
//!                  Metal backend ships in Phase 2).
//!
//! The instance must have been created with the matching
//! `VK_KHR_{win32,wayland}_surface` extension enabled — already done
//! by `device.zig:createInstance` based on `builtin.os.tag`.
//!
//! Lifecycle: the surface is owned by whoever called `createFromWindow`
//! and must be destroyed with `destroy(instance, surface)` (or by the
//! `Device.deinit` which already calls `destroySurfaceKHR` when its
//! `surface` field is non-null).

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const window_mod = weld_core.platform.window;
const types = @import("../types.zig");

const log = std.log.scoped(.gal_vk_surface);

/// Create a Vulkan surface from an already-open Tier 0 window. Returns
/// `error.Unsupported` on platforms without a Vulkan WSI integration
/// committed yet (macOS, web, …).
pub fn createFromWindow(
    instance: *vk.Instance,
    window: *const window_mod.Window,
) types.Error!vk.SurfaceKHR {
    const native = window.nativeHandles();
    return switch (builtin.os.tag) {
        .windows => createWin32(instance, native),
        .linux => createWayland(instance, native),
        else => error.Unsupported,
    };
}

/// Destroy a surface previously returned by `createFromWindow`. No-op
/// on the null sentinel so the call is safe in teardown paths even
/// when the surface was never allocated.
pub fn destroy(instance: *vk.Instance, surface: vk.SurfaceKHR) void {
    if (surface != .null) instance.destroySurfaceKHR(surface, null);
}

fn createWin32(
    instance: *vk.Instance,
    native: window_mod.NativeHandles,
) types.Error!vk.SurfaceKHR {
    if (comptime builtin.os.tag != .windows) {
        @compileError("createWin32 only compiles on Windows targets");
    }
    const ci: vk.Win32SurfaceCreateInfoKHR = .{
        .flags = .empty,
        .hinstance = @ptrCast(native.hinstance),
        .hwnd = @ptrCast(native.hwnd),
    };
    return instance.createWin32SurfaceKHR(&ci, null) catch |e| {
        log.debug("createWin32SurfaceKHR failed: {t}", .{e});
        return mapVkError(e);
    };
}

fn createWayland(
    instance: *vk.Instance,
    native: window_mod.NativeHandles,
) types.Error!vk.SurfaceKHR {
    if (comptime builtin.os.tag != .linux) {
        @compileError("createWayland only compiles on Linux targets");
    }
    const ci: vk.WaylandSurfaceCreateInfoKHR = .{
        .flags = .empty,
        .display = @ptrCast(native.display),
        .surface = @ptrCast(native.surface),
    };
    return instance.createWaylandSurfaceKHR(&ci, null) catch |e| {
        log.debug("createWaylandSurfaceKHR failed: {t}", .{e});
        return mapVkError(e);
    };
}

/// Translate a `vk.Error` raised by the WSI calls into the unified
/// `types.Error` consumed by the GAL surface. Mirrors the shape of
/// `conv.errorFromResult` but operates on the wrapper's already-mapped
/// error set instead of the raw `vk.Result`.
fn mapVkError(e: vk.Error) types.Error {
    return switch (e) {
        error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.SurfaceLost => error.SurfaceLost,
        error.ExtensionNotPresent, error.FeatureNotPresent => error.Unsupported,
        error.InitializationFailed => error.NotInitialized,
        else => error.BackendInternal,
    };
}

// Runtime tests live in `tests/render/gal_vulkan_offline.zig` so they
// are exercised by the test target that already roots the Vulkan path.
// Inline `test` blocks here would be silently skipped under the Zig 0.16
// lazy-analysis rules (cf. engine-zig-conventions.md §13).
