const std = @import("std");
const weld_core = @import("weld_core");
const process = weld_core.platform.process;
const time = weld_core.platform.time;

/// Polls of 10 ms a child is given to exit before it is killed: no loaded
/// runner reaches it, and it stays inside the runner's per-test deadline.
pub const exit_polls: usize = 6_000;

/// `proc`'s exit code, or null once `exit_polls` have passed and it has been
/// killed.
pub fn waitExit(proc: *process.Process) !?i32 {
    var attempts: usize = 0;
    while (attempts < exit_polls) : (attempts += 1) {
        if (try process.waitNonblock(proc)) |code| return code;
        time.sleepPrecise(std.testing.io, 10 * std.time.ns_per_ms) catch {};
    }
    process.kill(proc) catch {};
    return null;
}
