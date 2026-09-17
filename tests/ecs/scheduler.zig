//! System scheduler acceptance tests: phase pipeline order, worker count
//! against CPU topology, and the park→wake cycle.
//!
//! The park test polls the scheduler's own stats and uses NO wall-clock window:
//! a fixed 40×50 ms wait flaked and hung under CI load. It proves the two
//! halves separately — `Σ parks_entered > Σ parks_completed` means a worker is
//! parked RIGHT NOW, and `Σ parks_completed` growing after the next dispatch
//! means one returned from `waitUncancelable`.

const std = @import("std");
const weld_core = @import("weld_core");
const watchdog = @import("test_watchdog");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Chunk = weld_core.ecs.world.Chunk;

const jobs_sched_mod = weld_core.jobs.scheduler;
const Scheduler = jobs_sched_mod.Scheduler;

const sys_sched_mod = weld_core.ecs.scheduler;
const Phase = sys_sched_mod.Phase;
const SystemScheduler = sys_sched_mod.SystemScheduler;
const SystemContext = sys_sched_mod.SystemContext;
const SystemContextOf = weld_core.ecs.SystemContextOf;
const Access = weld_core.ecs.Access;

const VisitEntry = struct {
    phase: Phase,
    index_within_phase: u32,
};

const PhaseLog = struct {
    entries: std.ArrayListUnmanaged(VisitEntry) = .empty,
    fn deinit(self: *PhaseLog, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }
};

// The declared access sets are EMPTY, and deliberately: these five systems
// exercise the PHASE pipeline and touch no component at all — each appends its
// name to a log reached through `ctx.frame.user`. The DAG has nothing to order
// here, and the ordering under test is the phase's.
const spec_pre_a: []const Access = &.{};
const spec_pre_b: []const Access = &.{};
const spec_update_a: []const Access = &.{};
const spec_post: []const Access = &.{};
const spec_render: []const Access = &.{};

fn logPreUpdateA(ctx: SystemContextOf(spec_pre_a)) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .pre_update, .index_within_phase = 0 });
}
fn logPreUpdateB(ctx: SystemContextOf(spec_pre_b)) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .pre_update, .index_within_phase = 1 });
}
fn logUpdateA(ctx: SystemContextOf(spec_update_a)) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .update, .index_within_phase = 0 });
}
fn logPostUpdate(ctx: SystemContextOf(spec_post)) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .post_update, .index_within_phase = 0 });
}
fn logPreRender(ctx: SystemContextOf(spec_render)) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .pre_render, .index_within_phase = 0 });
}

test "phases dispatch sequentially with end-of-phase barrier" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "phases dispatch sequentially with end-of-phase barrier");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Two systems in `pre_update` to cover intra-phase order, then one each in
    // `update`, `post_update` and `pre_render`. `fixed_update` and
    // `late_update` are deliberately left empty: a skipped phase must not
    // disturb the ordering.
    try sys.registerSystem(gpa, &world, .pre_update, "pre_a", spec_pre_a, logPreUpdateA);
    try sys.registerSystem(gpa, &world, .pre_update, "pre_b", spec_pre_b, logPreUpdateB);
    try sys.registerSystem(gpa, &world, .update, "update_a", spec_update_a, logUpdateA);
    try sys.registerSystem(gpa, &world, .post_update, "post", spec_post, logPostUpdate);
    try sys.registerSystem(gpa, &world, .pre_render, "render", spec_render, logPreRender);

    var log: PhaseLog = .{};
    defer log.deinit(gpa);

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &log);

    try std.testing.expectEqual(@as(usize, 5), log.entries.items.len);
    const expected = [_]VisitEntry{
        .{ .phase = .pre_update, .index_within_phase = 0 },
        .{ .phase = .pre_update, .index_within_phase = 1 },
        .{ .phase = .update, .index_within_phase = 0 },
        .{ .phase = .post_update, .index_within_phase = 0 },
        .{ .phase = .pre_render, .index_within_phase = 0 },
    };
    for (expected, log.entries.items) |want, got| {
        try std.testing.expectEqual(want.phase, got.phase);
        try std.testing.expectEqual(want.index_within_phase, got.index_within_phase);
    }
}

test "worker count matches CPU topology at startup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "worker count matches CPU topology at startup");
    defer wd.disarm();

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);
    wd.setScheduler(&sched);

    const expected = std.Thread.getCpuCount() catch jobs_sched_mod.default_worker_count;
    try std.testing.expectEqual(expected, sched.workerCount());
    try std.testing.expect(sched.workerCount() >= 1);
}

test "workers deterministically park then wake on dispatch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "workers deterministically park then wake on dispatch");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    // Several chunks' worth, so each dispatch gives every worker something to do
    // before it goes idle.
    const N: u32 = 2_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);
    wd.setScheduler(&sched);

    var query = try world.query(gpa);
    defer query.deinit(gpa);

    // CONCURRENCY FACT: a snapshot reads `parks_completed` before
    // `parks_entered`, so `entered > completed` can only hold when some worker
    // has entered a wait it has not yet woken from.
    try sched.dispatch(&query, idleBody, .{});
    const steals_at_dispatch = blk: {
        const stats = try sched.snapshotStats(gpa);
        defer gpa.free(stats);
        var min: u64 = std.math.maxInt(u64);
        for (stats) |s| min = @min(min, s.steals_attempted);
        break :blk min;
    };
    while (true) {
        std.Thread.yield() catch {};
        const stats = try sched.snapshotStats(gpa);
        defer gpa.free(stats);
        var entered: u64 = 0;
        var completed: u64 = 0;
        var min_steals: u64 = std.math.maxInt(u64);
        for (stats) |s| {
            entered += s.parks_entered;
            completed += s.parks_completed;
            min_steals = @min(min_steals, s.steals_attempted);
        }
        if (entered > completed) break; // at least one worker is parked now

        const spent = min_steals - steals_at_dispatch;
        if (spent > 2 * jobs_sched_mod.idle_spin_rounds) return error.WorkersDidNotParkAfterSpinBudget;
    }

    // The wake side. A worker is parked, so nothing raises the completed count
    // until the next dispatch — after which it growing means a parked worker
    // returned from `waitUncancelable`.
    var completed_before: u64 = 0;
    {
        const stats = try sched.snapshotStats(gpa);
        defer gpa.free(stats);
        for (stats) |s| completed_before += s.parks_completed;
    }
    try sched.dispatch(&query, idleBody, .{});
    while (true) {
        std.Thread.yield() catch {};
        const stats = try sched.snapshotStats(gpa);
        defer gpa.free(stats);
        var completed: u64 = 0;
        for (stats) |s| completed += s.parks_completed;
        if (completed > completed_before) break; // a park→wake completed
    }
}

fn idleBody(chunk: *Chunk) void {
    _ = chunk;
}
