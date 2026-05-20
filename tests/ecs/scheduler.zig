//! M0.1 / E5a — system scheduler acceptance tests.
//!
//! Covers the three acceptance criteria listed in
//! `briefs/M0.1-ecs-full.md` § Acceptance criteria › Tests for E5a:
//!
//! - `test "phases dispatch sequentially with end-of-phase barrier"` —
//!   register systems across multiple phases. Each system writes its
//!   `(phase, index_in_phase)` to a shared visit log. Assert: the
//!   log order matches the canonical phase pipeline order and,
//!   within a phase, the registration order.
//! - `test "worker count matches CPU topology at startup"` —
//!   `Scheduler.init` reports a worker count equal to
//!   `std.Thread.getCpuCount() catch default_worker_count`.
//! - `test "idle workers sleep instead of busy-yielding"` — method
//!   (a) from the brief: an observable counter
//!   (`WorkerStats.parks_completed`) increments every time a worker
//!   returns from `work_available.waitUncancelable`. After two
//!   dispatches with no concurrent work, total parks_completed
//!   across workers is strictly greater than zero — proof that
//!   workers reached the parked path rather than busy-yielding.

const std = @import("std");
const weld_core = @import("weld_core");

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

// ─── Phase-ordering test infrastructure ───────────────────────────────────

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

fn logPreUpdateA(ctx: SystemContext) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .pre_update, .index_within_phase = 0 });
}
fn logPreUpdateB(ctx: SystemContext) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .pre_update, .index_within_phase = 1 });
}
fn logUpdateA(ctx: SystemContext) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .update, .index_within_phase = 0 });
}
fn logPostUpdate(ctx: SystemContext) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .post_update, .index_within_phase = 0 });
}
fn logPreRender(ctx: SystemContext) anyerror!void {
    const log: *PhaseLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.entries.append(ctx.gpa, .{ .phase = .pre_render, .index_within_phase = 0 });
}

test "phases dispatch sequentially with end-of-phase barrier" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Register two systems in `pre_update` (testing intra-phase order),
    // then one each in `update`, `post_update`, `pre_render`. Skip
    // `fixed_update` and `late_update` to verify empty phases are
    // skipped cleanly without breaking ordering.
    try sys.registerSystem(gpa, .{ .phase = .pre_update, .name = "pre_a", .run = logPreUpdateA });
    try sys.registerSystem(gpa, .{ .phase = .pre_update, .name = "pre_b", .run = logPreUpdateB });
    try sys.registerSystem(gpa, .{ .phase = .update, .name = "update_a", .run = logUpdateA });
    try sys.registerSystem(gpa, .{ .phase = .post_update, .name = "post", .run = logPostUpdate });
    try sys.registerSystem(gpa, .{ .phase = .pre_render, .name = "render", .run = logPreRender });

    var log: PhaseLog = .{};
    defer log.deinit(gpa);

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &log);

    // Expected order: pre_a, pre_b, update_a, post, render.
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

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);

    const expected = std.Thread.getCpuCount() catch jobs_sched_mod.default_worker_count;
    try std.testing.expectEqual(expected, sched.workerCount());
    try std.testing.expect(sched.workerCount() >= 1);
}

test "idle workers sleep instead of busy-yielding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    // Spawn enough entities to span multiple chunks so each dispatch
    // gives every worker something to do, then has them go idle.
    const N: u32 = 2_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);

    var query = try world.query(gpa);
    defer query.deinit(gpa);

    // First dispatch — wake every worker, give them work, drain to
    // completion. After this, workers will hit the idle path and
    // park on `work_available`.
    sched.dispatch(&query, idleBody, .{});

    // Give workers time to reach the parked path. The dispatch
    // returns when `pending_count == 0`, so workers may still be in
    // the inter-iteration window — the sleep gives them a generous
    // grace period to enter `cond.wait`.
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};

    // Second dispatch — workers wake from their parked state. The
    // parks_completed counter must have advanced.
    sched.dispatch(&query, idleBody, .{});

    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};

    const stats = try sched.snapshotStats(gpa);
    defer gpa.free(stats);
    var total_parks: u64 = 0;
    for (stats) |s| total_parks += s.parks_completed;
    // At least one worker must have parked + woken at least once —
    // confirms the sleep/wake path is exercised. In practice we
    // expect roughly `worker_count` parks per dispatch cycle, but
    // exact counts depend on chunk-distribution timing.
    try std.testing.expect(total_parks > 0);
}

fn idleBody(chunk: *Chunk) void {
    _ = chunk;
}
