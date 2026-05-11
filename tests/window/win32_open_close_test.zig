//! Step (d) of the S2 brief: open + close a Win32 window 50× without
//! leaking. Runs unconditionally on the Windows leg of the CI matrix and
//! is skipped (no-op success) on every other host so `zig build test` on
//! macOS / Linux dev machines stays green.
//!
//! The leak gate uses `std.testing.allocator`, which fails the test if
//! any heap-allocated state survives the iteration.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");
const window = weld_core.platform.window;

test "win32 backend opens and closes 50 windows without leaking" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var w = try window.Window.create(gpa, .{
            .title = "Weld S2 — open/close test",
            .width = 320,
            .height = 240,
        });
        defer w.destroy();

        // Drain any synchronous events the OS dispatched during create
        // (WM_SIZE for the initial layout pass, WM_DPICHANGED on a
        // HiDPI-aware monitor). Iteration count is bounded so a stuck
        // queue does not freeze the test.
        var pumped: u32 = 0;
        while (pumped < 16) : (pumped += 1) {
            if (w.pollEvent() == null) break;
        }
    }
}
