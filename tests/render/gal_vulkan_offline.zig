//! GAL Vulkan backend, offline: Device init, `supports()`, `getQueue` and
//! teardown — and nothing else, a swapchain needing a real window and surface.
//! The smoke-test PPM in `examples/triangle/` is what covers the swapchain, on
//! the three GPU configurations.
//!
//! Needs the Vulkan loader and a device (`test_env`); macOS has neither.

const std = @import("std");
const builtin = @import("builtin");
const gal = @import("weld_render");
const vk = @import("weld_core").platform.vk;
const test_env = @import("test_env");

const VulkanAvailable = enum { yes, no };

/// Whether the Vulkan loader loads.
fn detectVulkan() VulkanAvailable {
    vk.loadLoader() catch return .no;
    return .yes;
}

test "Vulkan backend init and teardown over headless device" {
    if (builtin.os.tag == .macos) return test_env.absent("a Vulkan host (macOS has none)");
    if (detectVulkan() == .no) return test_env.absent("the Vulkan loader");

    var device = gal.vulkan_backend.Device.init(std.testing.allocator, .{
        .label = "offline_test",
        .vulkan_driver = .auto,
        .gpu_preference = .auto,
        .enable_validation = false,
    }) catch return test_env.absent("a Vulkan device");
    defer device.deinit();

    // Sanity : feature query without crash, getQueue returns a non-null handle.
    try std.testing.expect(!device.supports(.timeline_semaphore));
    const queue = try device.getQueue(.graphics);
    try std.testing.expect(@intFromPtr(queue) != 0);
}

test "Vulkan backend satisfies comptime interface check" {
    comptime gal.interface.checkBackend(gal.vulkan_backend.Device);
    try std.testing.expect(true);
}

test "Vulkan backend Device struct keeps allocator + selection" {
    if (builtin.os.tag == .macos) return test_env.absent("a Vulkan host (macOS has none)");
    if (detectVulkan() == .no) return test_env.absent("the Vulkan loader");

    var device = gal.vulkan_backend.Device.init(std.testing.allocator, .{}) catch return test_env.absent("a Vulkan device");
    defer device.deinit();

    // The device name is filled in (terminated by a null byte).
    var has_content = false;
    for (device.selection.physical_device_name) |b| if (b != 0) {
        has_content = true;
        break;
    };
    try std.testing.expect(has_content);
}

test "Vulkan backend exposes createSurfaceFromWindow on every target" {
    // Comptime pin: regardless of platform, the method must compile and
    // accept a Tier 0 window pointer. The runtime body is platform-
    // gated (Windows / Linux real surfaces, others → error.Unsupported).
    const window_mod = @import("weld_core").platform.window;
    const Method = @TypeOf(gal.vulkan_backend.Device.createSurfaceFromWindow);
    const fn_info = @typeInfo(Method).@"fn";
    try std.testing.expectEqual(@as(usize, 2), fn_info.params.len);
    try std.testing.expectEqual(*gal.vulkan_backend.Device, fn_info.params[0].type.?);
    try std.testing.expectEqual(*const window_mod.Window, fn_info.params[1].type.?);
}
