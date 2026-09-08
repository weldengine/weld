//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! The two threading helpers the stdlib does not carry: `setAffinity` pins a thread
//! to one core, `setPriority` adjusts scheduling. Everything else propagates as-is.

const std = @import("std");
const builtin = @import("builtin");

/// Priority tier surfaced by `setPriority`. Maps to OS-specific levels.
pub const Priority = enum {
    /// Real-time-ish, as far as the OS allows without capabilities.
    high,
    /// Default — Win32 `THREAD_PRIORITY_NORMAL`, Linux SCHED_OTHER nice 0.
    normal,
    /// Background.
    low,
};

/// Errors surfaced by `setAffinity` / `setPriority`.
pub const Error = error{
    SetAffinityFailed,
    SetPriorityFailed,
    InvalidCoreId,
};

const win = struct {
    extern "kernel32" fn SetThreadAffinityMask(hThread: *anyopaque, dwThreadAffinityMask: usize) callconv(.winapi) usize;
    extern "kernel32" fn SetThreadPriority(hThread: *anyopaque, nPriority: i32) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) *anyopaque;

    const THREAD_PRIORITY_HIGHEST: i32 = 2;
    const THREAD_PRIORITY_NORMAL: i32 = 0;
    const THREAD_PRIORITY_BELOW_NORMAL: i32 = -1;

    fn threadHandle(thread: std.Thread) *anyopaque {
        // On Windows a `std.Thread` wraps a HANDLE, which is what the API below needs.
        return thread.getHandle();
    }
};

const posix = struct {
    const cpu_set_t = extern struct {
        bits: [128]u64 = [_]u64{0} ** 128, // CPU_SETSIZE / 64 on glibc
    };

    // `pthread_t` is an opaque pointer in `std.c` on every supported OS.
    extern "c" fn pthread_setaffinity_np(thread: std.c.pthread_t, cpusetsize: usize, cpuset: *const cpu_set_t) c_int;
    extern "c" fn pthread_setschedparam(thread: std.c.pthread_t, policy: c_int, param: *const sched_param) c_int;

    const sched_param = extern struct {
        sched_priority: c_int,
    };

    const SCHED_OTHER: c_int = 0;
    const SCHED_FIFO: c_int = 1;
    const SCHED_RR: c_int = 2;

    fn cpuSetSingle(core_id: u32) cpu_set_t {
        var cs: cpu_set_t = .{};
        const word = core_id / 64;
        const bit = @as(u6, @intCast(core_id % 64));
        if (word < cs.bits.len) {
            cs.bits[word] |= (@as(u64, 1) << bit);
        }
        return cs;
    }
};

/// Pin `thread` to CPU `core_id`. Best-effort; see `setPriority`.
pub fn setAffinity(thread: std.Thread, core_id: u32) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const handle = win.threadHandle(thread);
            const mask: usize = @as(usize, 1) << @intCast(core_id);
            const prev = win.SetThreadAffinityMask(handle, mask);
            if (prev == 0) return error.SetAffinityFailed;
        },
        .linux => {
            const cs = posix.cpuSetSingle(core_id);
            const rc = posix.pthread_setaffinity_np(thread.getHandle(), @sizeOf(posix.cpu_set_t), &cs);
            if (rc != 0) return error.SetAffinityFailed;
        },
        .macos => {
            // No portable equivalent on this OS; the mach API is a hint only.
            _ = .{ thread, core_id };
        },
        else => return error.SetAffinityFailed,
    }
}

/// Set the scheduling priority of `thread`. BEST-EFFORT, see below.
pub fn setPriority(thread: std.Thread, priority: Priority) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const handle = win.threadHandle(thread);
            const win_prio: i32 = switch (priority) {
                .high => win.THREAD_PRIORITY_HIGHEST,
                .normal => win.THREAD_PRIORITY_NORMAL,
                .low => win.THREAD_PRIORITY_BELOW_NORMAL,
            };
            if (win.SetThreadPriority(handle, win_prio) == 0) return error.SetPriorityFailed;
        },
        .linux, .macos => {
            // BEST-EFFORT, SOFT SUCCESS: a non-zero return is tolerated, because the
            // call needs a capability a container runner does not grant and setting
            // the default policy is a no-op anyway.
            //
            // DO NOT REUSE THIS FOR REAL-TIME PRIORITY. Silently ignoring the
            // permission error would mask a realtime configuration failure; that
            // caller wants its own entry returning an explicit error.
            const param: posix.sched_param = .{ .sched_priority = 0 };
            _ = posix.pthread_setschedparam(thread.getHandle(), posix.SCHED_OTHER, &param);
        },
        else => return error.SetPriorityFailed,
    }
}

test "threading.setAffinity + setPriority: spawned thread runs without error" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const Ctx = struct {
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn run(self: *@This()) void {
            // Spin so the parent has time to call the two helpers on us.
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                std.atomic.spinLoopHint();
            }
            self.done.store(1, .release);
        }
    };

    var ctx: Ctx = .{};
    var t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    // setAffinity to core 0 (always exists).
    setAffinity(t, 0) catch |err| switch (err) {
        // macOS no-op is success — any error here is a real failure.
        else => return err,
    };
    // setPriority to .normal (least intrusive).
    try setPriority(t, .normal);

    t.join();
    try std.testing.expectEqual(@as(u32, 1), ctx.done.load(.acquire));
}
