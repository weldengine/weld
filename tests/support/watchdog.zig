//! Arm on a test's first line and `defer disarm()` at once, so the disarm runs
//! last, after `Scheduler.deinit`'s worker join, which it must cover:
//!
//!     var wd: watchdog.Watchdog = .{};
//!     try wd.arm(io, watchdog.default_timeout_ns, "test name");
//!     defer wd.disarm();
//!     var sched = try Scheduler.init(gpa, io);
//!     defer sched.deinit(gpa);
//!     wd.setScheduler(&sched);

const std = @import("std");
const weld_core = @import("weld_core");

const Scheduler = weld_core.jobs.scheduler.Scheduler;

/// Under the runner's 180 s per-test deadline, so the dump is written before the
/// runner kills the test.
pub const default_timeout_ns: i96 = 150 * std.time.ns_per_s;

/// A side-thread watchdog. Runs concurrently with the test on the calling
/// thread; if the test does not `disarm()` within `timeout_ns`, it dumps the
/// scheduler state (if registered) and aborts the process with exit code 2.
pub const Watchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    sched: std.atomic.Value(?*const Scheduler) = .init(null),
    thread: ?std.Thread = null,
    io: std.Io = undefined,
    timeout_ns: i96 = default_timeout_ns,
    label: []const u8 = "",

    /// Spawn the watcher thread. Call as the first line of the test, paired
    /// with `defer disarm()` so disarm is the LAST defer (runs after the
    /// scheduler's deinit-join — the site this watchdog must cover).
    pub fn arm(self: *Watchdog, io: std.Io, timeout_ns: i96, label: []const u8) !void {
        self.done = .init(false);
        self.sched = .init(null);
        self.io = io;
        self.timeout_ns = timeout_ns;
        self.label = label;
        self.thread = try std.Thread.spawn(.{}, watcher, .{self});
    }

    /// Register the scheduler so the timeout dump includes its state. Optional
    /// — tests that drive raw deques / threading primitives skip it and get a
    /// plain timeout message.
    pub fn setScheduler(self: *Watchdog, sched: *const Scheduler) void {
        self.sched.store(sched, .release);
    }

    /// Signal completion and join the watcher. Idempotent; a no-op if `arm`
    /// was never called.
    pub fn disarm(self: *Watchdog) void {
        self.done.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn watcher(self: *Watchdog) void {
        const start = std.Io.Clock.now(.awake, self.io);
        while (!self.done.load(.acquire)) {
            const now = std.Io.Clock.now(.awake, self.io);
            if (start.durationTo(now).nanoseconds > self.timeout_ns) {
                var buf: [8192]u8 = undefined;
                var w = std.Io.File.stderr().writer(self.io, &buf);
                const out = &w.interface;
                const secs: u64 = @intCast(@divTrunc(self.timeout_ns, std.time.ns_per_s));
                out.print(
                    "\n=== test watchdog: '{s}' did not finish within {d}s — deadlock/livelock (covers scheduler.deinit join) ===\n",
                    .{ self.label, secs },
                ) catch {};
                if (self.sched.load(.acquire)) |sched| {
                    sched.dumpStateTo(out) catch {};
                }
                out.flush() catch {};
                // The test's threads and workers are stuck, so joining would
                // hang too. Abort with code 2 — the SchedulerLivelock signal
                // the stress harness counts hangs by.
                std.process.exit(2);
            }
            std.Io.sleep(self.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
        }
    }
};
