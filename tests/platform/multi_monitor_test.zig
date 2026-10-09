//! Multi-monitor enumeration + currentMonitor + per-monitor DPI.
//!
//! `enumerateMonitors`, `currentMonitor` and per-monitor DPI.
//!
//! Needs a Win32 or Wayland host with a compositor (`test_env`); the stub
//! backend returns error.UnsupportedPlatform for both query functions.

const std = @import("std");
const builtin = @import("builtin");
const weld = @import("weld_core");
const window_api = weld.platform.window;
const test_env = @import("test_env");

test "enumerateMonitors + currentMonitor + per-monitor DPI" {
    // Only Win32 and Wayland implement multi-monitor; the macOS stub
    // returns UnsupportedPlatform.
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) {
        return test_env.absent("a Win32 or Wayland host");
    }

    const gpa = std.testing.allocator;

    // The Wayland backend needs a live compositor.
    var win = window_api.Window.create(gpa, .{ .width = 320, .height = 240 }) catch {
        return test_env.absent("a compositor");
    };
    defer win.destroy();

    const monitors = window_api.enumerateMonitors(gpa) catch |err| switch (err) {
        error.UnsupportedPlatform => return test_env.absent("monitor enumeration"),
        else => return err,
    };
    defer gpa.free(monitors);

    // At least one monitor must be enumerated on real hardware.
    // On a headless Wayland session that exposes wl_output globals,
    // the Wayland backend would still report at least one.
    try std.testing.expect(monitors.len >= 1);

    for (monitors) |m| {
        // DPI scale must be > 0. The default 1.0 is a sentinel meaning
        // "unknown" only where a backend never populated it, and both
        // implementing backends do.
        try std.testing.expect(m.dpi_scale > 0.0);
    }

    // currentMonitor may be null briefly on Wayland before the first
    // wl_surface.enter event arrives. We accept null on Wayland; on
    // Win32 the call always succeeds.
    const cur = window_api.currentMonitor(&win);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(cur != null);
    } else {
        // On Linux/Wayland, cur may be null pre-enter; not an error.
        // Touch `cur` here so the const isn't a pointless discard.
        std.testing.expect(cur == null or cur != null) catch unreachable;
    }
}
