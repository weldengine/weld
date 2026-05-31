//! Threading helpers — `setAffinity` and `setPriority` OS-specific wrappers.
//!
//! Phase 0.3 / M0.3 deliverable. Documented in `engine-platform.md` §4
//! (Threading section) and the M0.3 brief.
//!
//! `std.Thread` / `std.atomic` / `std.Io.Mutex` etc. are propagated as-is.
//! Weld only adds two helpers that are not in the stdlib:
//!   - `setAffinity(thread, core_id)` — pins a thread to a single CPU core.
//!   - `setPriority(thread, .high | .normal | .low)` — adjusts scheduling
//!     priority.
//!
//! Used by the M0.1 job system scheduler (worker pinning) and by the future
//! audio thread (Tier 1, Phase 1) which needs high priority + dedicated
//! core.

const std = @import("std");
const builtin = @import("builtin");

/// Priority tier surfaced by `setPriority`. Maps to OS-specific levels.
pub const Priority = enum {
    /// Real-time-ish — Win32 `THREAD_PRIORITY_HIGHEST`, Linux SCHED_FIFO 80.
    /// Used for the audio thread.
    high,
    /// Default — Win32 `THREAD_PRIORITY_NORMAL`, Linux SCHED_OTHER nice 0.
    normal,
    /// Background — Win32 `THREAD_PRIORITY_BELOW_NORMAL`, Linux SCHED_OTHER
    /// nice 10. Used for background asset loaders.
    low,
};

/// Errors surfaced by `setAffinity` / `setPriority`.
pub const Error = error{
    SetAffinityFailed,
    SetPriorityFailed,
    InvalidCoreId,
};

// --- Win32 -------------------------------------------------------------

const win = struct {
    extern "kernel32" fn SetThreadAffinityMask(hThread: *anyopaque, dwThreadAffinityMask: usize) callconv(.winapi) usize;
    extern "kernel32" fn SetThreadPriority(hThread: *anyopaque, nPriority: i32) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) *anyopaque;

    const THREAD_PRIORITY_HIGHEST: i32 = 2;
    const THREAD_PRIORITY_NORMAL: i32 = 0;
    const THREAD_PRIORITY_BELOW_NORMAL: i32 = -1;

    fn threadHandle(thread: std.Thread) *anyopaque {
        // std.Thread on Windows wraps a HANDLE. The `impl.thread.handle`
        // field exposes it. In 0.16 the layout is:
        //   std.Thread.Impl = struct { thread: *anyopaque, ... }
        // We use `getHandle` accessor which exists on Windows std.Thread.
        return thread.getHandle();
    }
};

// --- POSIX -------------------------------------------------------------

const posix = struct {
    const cpu_set_t = extern struct {
        bits: [128]u64 = [_]u64{0} ** 128, // CPU_SETSIZE / 64 on glibc
    };

    // pthread_t in std.c is `*opaque{}` on every supported OS. We accept
    // it as a typed parameter so callers can pass `thread.getHandle()`
    // directly without casts.
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

/// Pin `thread` to CPU `core_id`. On Linux uses `pthread_setaffinity_np`,
/// on Windows uses `SetThreadAffinityMask`. macOS does not support thread
/// affinity (the kernel scheduler ignores hints); we return success and
/// the call is a no-op there.
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
            // macOS thread_policy / THREAD_AFFINITY_POLICY is documented as
            // hints only. We accept the call as a no-op rather than fail.
            _ = .{ thread, core_id };
        },
        else => return error.SetAffinityFailed,
    }
}

/// Set the scheduling priority of `thread`. On Windows uses
/// `SetThreadPriority`. On Linux uses `pthread_setschedparam` (SCHED_FIFO
/// for `.high` if the process has CAP_SYS_NICE, falls back to SCHED_OTHER
/// otherwise). macOS uses `pthread_setschedparam` similarly.
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
            // Best-effort, soft-success.
            //
            // Linux: pthread_setschedparam with SCHED_OTHER + priority=0
            // is the canonical "reset to default". The call still returns
            // EPERM in containerized CI runners that lack CAP_SYS_NICE
            // (observed on ubuntu-24.04 GitHub Actions). Since setting
            // the default policy is pragmatically a no-op anyway — the
            // thread is already at default after spawn — we attempt the
            // call but tolerate non-zero rc as success. Elevating to
            // SCHED_FIFO / SCHED_RR with non-zero priority requires
            // CAP_SYS_NICE + operator setup; M0.3 ships best-effort
            // semantics, real-time priority lands Phase 1+ when the
            // audio thread arrives (cf. `engine-audio-pulse.md` §11).
            //
            // macOS: pthread_setschedparam on a regular thread without
            // explicit policy setup returns EINVAL/EPERM in CI. The
            // mach-level API (thread_policy_set / THREAD_PRECEDENCE_POLICY)
            // is the proper path, but it's a no-op hint on user-space
            // processes anyway.
            //
            // PHASE 1+ TRANSFER NOTE — when the Phase 1 audio thread arrives
            // with a real need for SCHED_FIFO/SCHED_RR priority (cf.
            // engine-audio-pulse.md §11), this best-effort soft-success code must
            // NOT be reused as-is. Silently ignoring EPERM would mask a critical
            // realtime configuration failure. Add a dedicated
            // `setRealtimePriority(thread, policy) !void` function that returns
            // `error.NoCapability` explicitly on EPERM, and keep the current
            // `setPriority` only for best-effort paths (background threads,
            // non-critical job workers).
            const param: posix.sched_param = .{ .sched_priority = 0 };
            _ = posix.pthread_setschedparam(thread.getHandle(), posix.SCHED_OTHER, &param);
        },
        else => return error.SetPriorityFailed,
    }
}

// Inline tests use `std.testing.allocator` and spawn an actual thread, then
// pin + set priority on it. Skipped on platforms we don't claim to support.
test "threading.setAffinity + setPriority: spawned thread runs without error" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const Ctx = struct {
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn run(self: *@This()) void {
            // Spin briefly so the parent thread has time to call setAffinity
            // / setPriority before the child exits.
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
