//! Mirrors the Win32 50× open/close gate, on the Wayland leg. Skips:
//!   * On non-Linux hosts (no Wayland backend in scope).
//!   * On Linux hosts without a running compositor (CI runners,
//!     `WAYLAND_DISPLAY` unset, or `wl_display_connect` returning null) —
//!     the actual hardware validation runs from a developer session via
//!     `--smoke-test`, not from `zig build test`.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");
const window = weld_core.platform.window;

test "wayland backend opens and closes 50 windows without leaking" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const gpa = std.testing.allocator;

    // Probe before the 50× loop so a missing compositor short-circuits
    // cleanly with `error.SkipZigTest` instead of failing the test.
    {
        var probe = window.Window.create(gpa, .{
            .title = "Weld S2 — probe",
            .width = 320,
            .height = 240,
        }) catch |err| switch (err) {
            error.UnsupportedPlatform, error.BackendInitFailed => return error.SkipZigTest,
            else => return err,
        };
        probe.destroy();
    }

    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var w = try window.Window.create(gpa, .{
            .title = "Weld S2 — open/close test",
            .width = 320,
            .height = 240,
        });
        defer w.destroy();

        // Drain any synchronous events delivered during the configure
        // round-trip. Bounded so a stuck queue does not freeze the test.
        var pumped: u32 = 0;
        while (pumped < 16) : (pumped += 1) {
            if (w.pollEvent() == null) break;
        }
    }
}
