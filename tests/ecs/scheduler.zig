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
//! - `test "workers deterministically park then wake on dispatch"` —
//!   M1.1.1-HF3 E9 deterministic replacement for the former fixed
//!   40×50 ms window (which flaked / hung under CI load). Two phases,
//!   each polled against the scheduler's park stats, bounded only by
//!   the 5 s watchdog:
//!     (a) after one dispatch, poll until `Σ parks_entered >
//!         Σ parks_completed` — at least one worker is parked RIGHT
//!         NOW (it incremented `parks_entered` under the park mutex and
//!         is blocked in `waitUncancelable`, not yet woken);
//!     (b) capture the completed count, dispatch again, poll until
//!         `Σ parks_completed` strictly grows — the park→wake cycle is
//!         proven. No wall-clock sleep window is used.

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

    // Register two systems in `pre_update` (testing intra-phase order),
    // then one each in `update`, `post_update`, `pre_render`. Skip
    // `fixed_update` and `late_update` to verify empty phases are
    // skipped cleanly without breaking ordering.
    try sys.registerSystem(gpa, &world, .{ .phase = .pre_update, .name = "pre_a", .run = logPreUpdateA });
    try sys.registerSystem(gpa, &world, .{ .phase = .pre_update, .name = "pre_b", .run = logPreUpdateB });
    try sys.registerSystem(gpa, &world, .{ .phase = .update, .name = "update_a", .run = logUpdateA });
    try sys.registerSystem(gpa, &world, .{ .phase = .post_update, .name = "post", .run = logPostUpdate });
    try sys.registerSystem(gpa, &world, .{ .phase = .pre_render, .name = "render", .run = logPreRender });

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

    // Spawn enough entities to span multiple chunks so each dispatch
    // gives every worker something to do, then has them go idle.
    const N: u32 = 2_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) _ = try world.spawn(gpa, Transform{}, Velocity{});

    var sched = try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);
    wd.setScheduler(&sched);

    var query = try world.query(gpa);
    defer query.deinit(gpa);

    // Phase (a) — observe a worker parked RIGHT NOW.
    //
    // One dispatch of trivial work; idle workers then spin briefly and park on
    // `work_available.waitUncancelable`, incrementing `parks_entered` under the
    // park mutex before the wait. Poll until `Σ parks_entered > Σ parks_completed`:
    // that strict inequality can only hold when a worker has entered a wait it
    // has not yet woken from. The per-snapshot invariant
    // `parks_completed <= parks_entered` (snapshot reads completed before entered)
    // rules out a sampling artefact; and because this dispatch's wave has drained
    // (no park↔wake churn), that entered-not-woken worker is a worker parked now.
    // `std.Thread.yield` between polls; the 5 s watchdog armed above is
    // the hard upper bound (a genuine regression — workers never parking — hangs
    // here and the watchdog dumps the scheduler state, rather than a silent CI
    // timeout).
    try sched.dispatch(&query, idleBody, .{});
    while (true) {
        std.Thread.yield() catch {};
        const stats = try sched.snapshotStats(gpa);
        defer gpa.free(stats);
        var entered: u64 = 0;
        var completed: u64 = 0;
        for (stats) |s| {
            entered += s.parks_entered;
            completed += s.parks_completed;
        }
        if (entered > completed) break; // at least one worker is parked now
    }

    // Phase (b) — prove the wake side of the cycle.
    //
    // Capture the current completed count (a worker is parked, so nothing raises
    // it until the next dispatch), dispatch again, and poll until
    // `Σ parks_completed` strictly grows — a parked worker returned from
    // `waitUncancelable`.
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
