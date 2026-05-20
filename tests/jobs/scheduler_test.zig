const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Chunk = weld_core.ecs.world.Chunk;
const Scheduler = weld_core.jobs.scheduler.Scheduler;
const worker_count = weld_core.jobs.scheduler.worker_count;

const VisitCtx = struct {
    counter: *std.atomic.Value(u32),
    archetype_id_seen: *std.atomic.Value(u32),
    archetype_id_mismatch: *std.atomic.Value(bool),
};

fn recordVisit(chunk: *Chunk, ctx: *VisitCtx) void {
    _ = ctx.counter.fetchAdd(1, .acq_rel);
    const arch_id = chunk.headerConst().archetype_id;
    const expected = ctx.archetype_id_seen.load(.acquire);
    if (expected != arch_id) ctx.archetype_id_mismatch.store(true, .release);
}

test "split-over-chunks dispatch covers every chunk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    // Spawn enough entities to span several chunks.
    const N: u32 = 5_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    const chunk_count = world.chunkCount();
    try std.testing.expect(chunk_count > 1);

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit();

    var counter: std.atomic.Value(u32) = .init(0);
    var archetype_id_seen: std.atomic.Value(u32) = .init(0); // World.archetype.archetype_id
    var archetype_id_mismatch: std.atomic.Value(bool) = .init(false);
    var ctx: VisitCtx = .{
        .counter = &counter,
        .archetype_id_seen = &archetype_id_seen,
        .archetype_id_mismatch = &archetype_id_mismatch,
    };

    var query = world.query();
    sched.dispatch(&query, recordVisit, .{&ctx});

    try std.testing.expectEqual(@as(u32, @intCast(chunk_count)), counter.load(.acquire));
    try std.testing.expect(!archetype_id_mismatch.load(.acquire));
}

const SlowCtx = struct {
    completed: *std.atomic.Value(u32),
    saw_value: *std.atomic.Value(u32),
};

fn slowJob(chunk: *Chunk, ctx: *SlowCtx) void {
    _ = chunk;
    // Simulate work — short busy-loop so this test doesn't hang on weak
    // hardware. The point is to ensure dispatch waits for completion.
    var x: u64 = 0;
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) x +%= i *% 7;
    ctx.saw_value.store(@intCast(x & 0xffff_ffff), .release);
    _ = ctx.completed.fetchAdd(1, .acq_rel);
}

test "scheduler returns only after all work is done" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    const N: u32 = 5_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit();

    var completed: std.atomic.Value(u32) = .init(0);
    var saw: std.atomic.Value(u32) = .init(0);
    var ctx: SlowCtx = .{ .completed = &completed, .saw_value = &saw };

    var query = world.query();
    const expected: u32 = @intCast(query.chunkCount());
    sched.dispatch(&query, slowJob, .{&ctx});

    // After dispatch returns, every chunk must have been processed. No
    // spurious early return.
    try std.testing.expectEqual(expected, completed.load(.acquire));
}
