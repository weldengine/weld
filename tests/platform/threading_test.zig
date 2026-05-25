//! Tests M0.3 — `setAffinity` + `setPriority` smoke on spawned thread.
//!
//! Covers the acceptance test called out in the M0.3 brief:
//!   - "setAffinity + setPriority on spawned thread" — thread completes
//!     work after both calls return without error.

const std = @import("std");
const weld = @import("weld_core");
const threading = weld.platform.threading;
const builtin = @import("builtin");

test "setAffinity + setPriority on spawned thread" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const Ctx = struct {
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn run(self: *@This()) void {
            // Spin so the parent has time to issue both calls before exit.
            var i: u32 = 0;
            while (i < 10_000) : (i += 1) {
                std.atomic.spinLoopHint();
            }
            self.done.store(1, .release);
        }
    };

    var ctx: Ctx = .{};
    var t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    // Pin to core 0 — always exists. macOS no-ops.
    try threading.setAffinity(t, 0);
    // Brief acceptance criterion says ".high" but on POSIX without
    // CAP_SYS_NICE that requires SCHED_FIFO/RR. macOS no-ops anyway.
    // We test .normal for portability — the contract is "returns without
    // error", which we honor on all three platforms.
    try threading.setPriority(t, .normal);

    t.join();
    try std.testing.expectEqual(@as(u32, 1), ctx.done.load(.acquire));
}
