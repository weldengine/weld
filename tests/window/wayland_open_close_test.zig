//! Mirrors the Win32 50× open/close gate, on the Wayland leg. Needs a Linux
//! host and a compositor (`test_env`).

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");
const window = weld_core.platform.window;
const test_env = @import("test_env");

test "wayland backend opens and closes 50 windows without leaking" {
    if (builtin.os.tag != .linux) return test_env.absent("a Linux host");

    const gpa = std.testing.allocator;

    // Probe first, so a missing compositor is reported as one and not as a
    // failure of the loop.
    {
        var probe = window.Window.create(gpa, .{
            .title = "Weld S2 — probe",
            .width = 320,
            .height = 240,
        }) catch |err| switch (err) {
            error.UnsupportedPlatform, error.BackendInitFailed => return test_env.absent("a Wayland compositor"),
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
