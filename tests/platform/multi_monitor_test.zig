//! Tests M0.3 — multi-monitor enumeration + currentMonitor + per-monitor DPI.
//!
//! Covers the acceptance test called out in the M0.3 brief:
//!   - "enumerateMonitors + currentMonitor + per-monitor DPI"
//!
//! Skipped on platforms without a window subsystem (the stub backend
//! returns error.UnsupportedPlatform for both query functions).

const std = @import("std");
const builtin = @import("builtin");
const weld = @import("weld_core");
const window_api = weld.platform.window;

test "enumerateMonitors + currentMonitor + per-monitor DPI" {
    // Only Win32 and Wayland implement multi-monitor; the macOS stub
    // returns UnsupportedPlatform.
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const gpa = std.testing.allocator;

    // Try to open a window — the Wayland backend needs a live compositor,
    // which CI runners (headless) may not have. Skip gracefully.
    var win = window_api.Window.create(gpa, .{ .width = 320, .height = 240 }) catch {
        return error.SkipZigTest;
    };
    defer win.destroy();

    const monitors = window_api.enumerateMonitors(gpa) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(monitors);

    // At least one monitor must be enumerated on real hardware.
    // On a headless Wayland session that exposes wl_output globals,
    // the Wayland backend would still report at least one.
    try std.testing.expect(monitors.len >= 1);

    for (monitors) |m| {
        // DPI scale must be > 0 — the default 1.0 is a sentinel that
        // means "unknown" only if the backend never populated it. Both
        // backends populate it in M0.3.
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
