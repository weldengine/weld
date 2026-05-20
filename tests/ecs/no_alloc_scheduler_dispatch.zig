//! M0.1 / E5a — dedicated zero-allocation test for
//! `jobs.Scheduler.dispatch` (D-S1-6 absorption).
//!
//! Wraps the world's allocator in a `CountingAllocator`, performs the
//! one-time `init` allocations (workers + chunks slice + worker
//! threads), takes a snapshot, then runs a full dispatch cycle
//! through the new sleep/wake scheduler. The cycle covers: workers
//! waking from `work_available.waitUncancelable`, pushing their
//! share into local deques, executing the trampoline body, signaling
//! `work_completed` when the wave drains, and parking back on the
//! condition variable.
//!
//! Assert: the dispatch cycle allocates zero bytes. Distinct from
//! the broader `no_alloc_in_simulation_test.zig` which exercises a
//! 1000-iteration loop — this one is targeted at the single-cycle
//! contract on the scheduler itself.

const std = @import("std");
const weld_core = @import("weld_core");

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

    var world = World.init();
    defer world.deinit(gpa);

    // Spawn a couple of chunks worth of entities so the dispatch
    // actually exercises the work-stealing path across multiple
    // workers.
    const N: u32 = 1_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);

    var query = try world.query(gpa);
    defer query.deinit(gpa);

    // Warm up — first dispatch may incur first-touch effects that
    // are not the steady-state contract. Subsequent dispatches must
    // be alloc-free.
    sched.dispatch(&query, nopBody, .{});

    // Give workers time to park before the measured dispatch.
    std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};

    // Now run one fully-instrumented dispatch cycle.
    const before = counting.snapshot();
    sched.dispatch(&query, nopBody, .{});
    const after = counting.snapshot();
    const delta = CountingAllocator.delta(after, before);

    try std.testing.expectEqual(@as(u64, 0), delta.alloc_count);
    try std.testing.expectEqual(@as(u64, 0), delta.free_count);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_freed);
}
