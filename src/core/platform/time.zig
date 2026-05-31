//! Time primitives — `sleepPrecise(ns)` + monotonic `now()` for the Weld
//! platform layer.
//!
//! Phase 0.3 / M0.3 deliverable. Documented in `engine-platform.md` §4
//! (Time section) and the M0.3 brief.
//!
//! Zig 0.16's `std.time.Instant` and `std.time.sleep` were removed (sleep
//! moved to `std.Io.sleep`, monotonic timing moved to `Io.Clock`). Weld's
//! platform layer is OS-direct — it sits *below* `std.Io.Threaded` and
//! provides the primitives that the std-level sleep wraps. So we use
//! `Sleep`/`nanosleep` and `QueryPerformanceCounter`/`clock_gettime`
//! directly.
//!
//! ## sleepPrecise
//!
//! On Win32, `Sleep(1)` defaults to ~15.6 ms resolution unless the
//! multimedia timer minimum period has been raised. `sleepPrecise` calls
//! `timeBeginPeriod(1)` once per process via the shared `Once` primitive,
//! then issues `Sleep`. The once-init never deactivates the high-res
//! timer for the lifetime of the process (negligible system-wide cost on
//! modern Windows — the API is informational only since Windows 10 2004).
//!
//! On Linux/macOS, `nanosleep` is already precise so the wrapper is a
//! direct call.

const std = @import("std");
const builtin = @import("builtin");
const once_mod = @import("once.zig");

/// Win32 multimedia timer minimum period activation. Lazy — runs at most
/// once per process. Consistent with the pattern documented in the
/// M0.3 brief § "std.once verification for Zig 0.16".
var win32_period_once: once_mod.Once = .{};

const winmm = struct {
    extern "winmm" fn timeBeginPeriod(uPeriod: u32) callconv(.winapi) u32;
};

const kernel32 = struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) i32;
};

const posix_c = struct {
    const timespec = extern struct {
        tv_sec: i64,
        tv_nsec: i64,
    };
    extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
    extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
    // Linux: CLOCK_MONOTONIC = 1. macOS: CLOCK_MONOTONIC = 6 (mach_absolute_time
    // wrapper). Both expose the constant via `<time.h>`.
    const CLOCK_MONOTONIC: c_int = switch (builtin.os.tag) {
        .linux => 1,
        .macos => 6,
        else => 1,
    };
};

fn activateWin32Period() anyerror!void {
    if (comptime builtin.os.tag != .windows) return;
    const rc = winmm.timeBeginPeriod(1);
    // TIMERR_NOERROR == 0. Any non-zero indicates the requested period is
    // out of range (we always pass 1ms which is supported on every Windows
    // ≥ 2000).
    if (rc != 0) return error.WinMMTimeBeginPeriodFailed;
}

/// Sleep for at least `nanoseconds`. On Win32, ensures `timeBeginPeriod(1)`
/// has been called so the scheduler quantum is 1 ms.
///
/// `io` is required to drive the once-init's futex wait path; pass the
/// engine-level `std.Io` (typically `init.io` from Juicy Main).
pub fn sleepPrecise(io: std.Io, nanoseconds: u64) !void {
    switch (builtin.os.tag) {
        .windows => {
            try win32_period_once.call(io, activateWin32Period);
            const ms: u32 = @intCast(@min((nanoseconds + 999_999) / 1_000_000, std.math.maxInt(u32)));
            kernel32.Sleep(ms);
        },
        .linux, .macos => {
            const ts: posix_c.timespec = .{
                .tv_sec = @intCast(nanoseconds / 1_000_000_000),
                .tv_nsec = @intCast(nanoseconds % 1_000_000_000),
            };
            // Loop on EINTR — nanosleep can be interrupted by signals; we
            // restart with the remaining time so the total slept duration
            // is at least the requested amount.
            var req = ts;
            var rem: posix_c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            while (posix_c.nanosleep(&req, &rem) != 0) {
                req = rem;
            }
        },
        else => {},
    }
}

/// Read the monotonic clock as a u64 of nanoseconds since an arbitrary
/// origin. Suitable for measuring elapsed time, not for wall-clock dates.
///
/// Win32: `QueryPerformanceCounter` scaled to nanoseconds via
/// `QueryPerformanceFrequency` (cached on first call).
/// POSIX: `clock_gettime(CLOCK_MONOTONIC, ...)`.
pub fn nowNanos() u64 {
    switch (builtin.os.tag) {
        .windows => {
            const State = struct {
                var freq: i64 = 0;
            };
            if (State.freq == 0) {
                _ = kernel32.QueryPerformanceFrequency(&State.freq);
            }
            var counter: i64 = 0;
            _ = kernel32.QueryPerformanceCounter(&counter);
            // ns = counter * 1e9 / freq. Compute as u128 to avoid overflow.
            const big = @as(u128, @intCast(counter)) * 1_000_000_000;
            return @intCast(big / @as(u128, @intCast(State.freq)));
        },
        .linux, .macos => {
            var ts: posix_c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            _ = posix_c.clock_gettime(posix_c.CLOCK_MONOTONIC, &ts);
            return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
        },
        else => return 0,
    }
}

test "time.sleepPrecise: 1 ms accuracy" {
    const io = std.testing.io;
    const start = nowNanos();
    try sleepPrecise(io, 1_000_000); // 1 ms
    const elapsed_ns = nowNanos() - start;
    // Tolerance: 50 ms ceiling for slow CI. The dedicated bench test in
    // tests/platform/time_test.zig enforces the tighter brief gate
    // (< 2 ms Win32 / < 1 ms Linux).
    try std.testing.expect(elapsed_ns >= 1_000_000);
    try std.testing.expect(elapsed_ns < 50_000_000);
}

test "time.nowNanos: monotonic and non-decreasing" {
    const a = nowNanos();
    // Busy-loop briefly so the second sample is strictly later.
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        std.atomic.spinLoopHint();
    }
    const b = nowNanos();
    try std.testing.expect(b >= a);
}
