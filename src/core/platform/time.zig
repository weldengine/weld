//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! `sleepPrecise` and a monotonic `nowNanos`. This layer sits BELOW `std.Io`, so it
//! calls `nanosleep` / `QueryPerformanceCounter` directly rather than the std wrapper.
//!
//! On Win32 a bare `Sleep(1)` rounds to ~15.6 ms, so `sleepPrecise` raises the
//! multimedia timer period once per process and never lowers it again.

const std = @import("std");
const builtin = @import("builtin");
const once_mod = @import("once.zig");

/// Lazy activation of the Win32 multimedia timer period.
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
    // The `CLOCK_MONOTONIC` constant differs between Linux and macOS.
    const CLOCK_MONOTONIC: c_int = switch (builtin.os.tag) {
        .linux => 1,
        .macos => 6,
        else => 1,
    };
};

fn activateWin32Period() anyerror!void {
    if (comptime builtin.os.tag != .windows) return;
    const rc = winmm.timeBeginPeriod(1);
    // Any non-zero return means the requested period was refused.
    if (rc != 0) return error.WinMMTimeBeginPeriodFailed;
}

/// Sleep for AT LEAST `nanoseconds`.
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
            // Loop on EINTR: `nanosleep` returns early on a signal with the remainder.
            var req = ts;
            var rem: posix_c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            while (posix_c.nanosleep(&req, &rem) != 0) {
                req = rem;
            }
        },
        else => {},
    }
}

/// Monotonic nanoseconds since an arbitrary epoch.
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
    // A ceiling loose enough for a loaded CI runner; the bench measures precision.
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
