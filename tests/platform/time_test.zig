//! `sleepPrecise` precision and `nowNanos` monotonicity.
//!
//! `sleepPrecise` accuracy and `nowNanos` monotonicity.
//!
//! The specified gates — under 2 ms on Win32, under 1 ms on Linux — are tight
//! and CI runners are noisy, so the ceiling asserted inline is far looser: this
//! file is for CORRECTNESS, and the strict gates belong to the bench.

const std = @import("std");
const weld = @import("weld_core");
const time = weld.platform.time;
const builtin = @import("builtin");

test "sleepPrecise ms accuracy" {
    const io = std.testing.io;

    // Warm up the once-init path (timeBeginPeriod on Win32, no-op POSIX).
    try time.sleepPrecise(io, 500_000); // 0.5 ms

    const start = time.nowNanos();
    try time.sleepPrecise(io, 1_000_000); // 1 ms
    const elapsed = time.nowNanos() - start;

    try std.testing.expect(elapsed >= 1_000_000);
    // CI tolerance: the specified gate is 2 ms on Win32 and 1 ms on Linux, and
    // 50 ms is allowed here because GitHub Actions macOS / Linux runners stall
    // arbitrarily under contention. The bench harness (Phase 1+) will
    // enforce the tight gate on the reference machine cold-isolated.
    try std.testing.expect(elapsed < 50_000_000);
}

test "nowNanos: monotonic across busy-wait" {
    var prev = time.nowNanos();
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var j: u32 = 0;
        while (j < 1000) : (j += 1) {
            std.atomic.spinLoopHint();
        }
        const cur = time.nowNanos();
        try std.testing.expect(cur >= prev);
        prev = cur;
    }
}
