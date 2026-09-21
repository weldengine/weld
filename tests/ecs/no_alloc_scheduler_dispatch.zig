//! Zero-allocation contract of ONE `jobs.Scheduler.dispatch` cycle, where
//! `no_alloc_in_simulation_test.zig` covers a 1000-iteration loop. The snapshot
//! is taken after the one-time `init` allocations, so what is measured is the
//! cycle alone: waking from `work_available`, pushing a share into the local
//! deques, running the trampoline body, signalling `work_completed` as the wave
//! drains, and parking again.

const std = @import("std");
const weld_core = @import("weld_core");
const watchdog = @import("test_watchdog");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Chunk = weld_core.ecs.world.Chunk;
const Scheduler = weld_core.jobs.scheduler.Scheduler;
const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;

fn nopBody(chunk: *Chunk) void {
    _ = chunk;
}

test "scheduler.dispatch does zero allocations across a full dispatch cycle" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    const io = std.testing.io;

    // Watchdog armed OUTSIDE the measured no-allocation region below: it uses
    // `io` (not the counting allocator `gpa`), and both arm and the deferred
    // disarm run before/after the `counting.snapshot()` window, so they do not
    // perturb the measured delta.
    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "scheduler.dispatch does zero allocations across a full dispatch cycle");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    // Several chunks' worth, so the dispatch really crosses the work-stealing
    // path instead of resolving on one worker.
    const N: u32 = 1_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);
    wd.setScheduler(&sched);

    var query = try world.query(gpa);
    defer query.deinit(gpa);

    // The first dispatch carries first-touch effects the contract does not
    // cover; every later one must be allocation-free.
    try sched.dispatch(&query, nopBody, .{});

    // Give workers time to park before the measured dispatch.
    std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};

    const before = counting.snapshot();
    try sched.dispatch(&query, nopBody, .{});
    const after = counting.snapshot();
    const delta = CountingAllocator.delta(after, before);

    try std.testing.expectEqual(@as(u64, 0), delta.alloc_count);
    try std.testing.expectEqual(@as(u64, 0), delta.free_count);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_freed);
}
