//! S6 process tests — `platform.process.spawn_process` + `wait_nonblock`
//! + `is_alive` against the real `/bin/true` and `/bin/sleep` binaries
//! (POSIX). Windows is `skipNow` because `CreateProcessW` is stubbed in
//! S6 (cf. `src/core/platform/process.zig`).

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const process = weld_core.platform.process;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

const timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn sleepMs(ms: u64) void {
    var ts = timespec{
        .tv_sec = @intCast(ms / 1_000),
        .tv_nsec = @intCast((ms % 1_000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

// `/bin/true` lives at `/usr/bin/true` on macOS (and is also at
// `/bin/true` on Linux). `/bin/sleep` is canonical on both.
const true_path = if (builtin.os.tag == .macos) "/usr/bin/true" else "/bin/true";

test "spawn true(1) and reap with wait_nonblock returns exit 0" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const argv = [_][]const u8{true_path};

    var proc = try process.spawn_process(gpa, true_path, &argv);

    // Poll up to ~1 s for the child to exit. /bin/true is near-
    // instant; the loop bound exists to keep the test from hanging
    // if the binary is missing or the spawn fails silently.
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try process.wait_nonblock(&proc)) |code| {
            try std.testing.expectEqual(@as(i32, 0), code);
            return;
        }
        sleepMs(10);
    }
    return error.ChildNeverExited;
}

extern "c" fn getpid() i32;

test "is_alive returns true for current pid, false for impossible pid" {
    if (!is_posix) return error.SkipZigTest;

    // The current process always passes — `kill(pid, 0)` is a no-op
    // for the calling process. Using `getpid()` avoids `is_alive(1)`
    // which raises `EPERM` on macOS (launchd is permission-gated).
    const self_pid = getpid();
    try std.testing.expect(process.is_alive(self_pid));
    // PID very high — kernel reserves the lower range. 999_999 is not
    // a valid live process on any sane developer machine.
    try std.testing.expect(!process.is_alive(999_999));
}

test "spawn-then-kill terminates a long-running child" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/sleep", "30" };

    var proc = try process.spawn_process(gpa, "/bin/sleep", &argv);
    // Give the child a moment to actually become alive in the kernel
    // table — without this, `kill(pid, SIGKILL)` can race against
    // the spawn returning before the child is reapable on macOS.
    sleepMs(20);
    // Don't actually wait 30 s — kill and reap.
    try process.kill(&proc);

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try process.wait_nonblock(&proc)) |_| return;
        sleepMs(10);
    }
    return error.ChildNeverDied;
}
