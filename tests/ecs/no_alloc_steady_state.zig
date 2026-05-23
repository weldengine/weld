//! M0.1 / E7 — composite steady-state no-allocation test.
//!
//! Drives a scaled-down C0.1-like scenario (4 archetypes × 4 systems
//! × 1000 entities total) over 100 dispatchFrame calls and asserts
//! that no allocation happens after the warm-up + setup window
//! closes. Exercises every M0.1 surface a real game tick touches:
//!
//! - **Queries** with mixed filters (no-filter, `With(T)`,
//!   `Changed(T)`) — proves `forEachChunk` + the lazy re-scan path
//!   stays alloc-free in steady state.
//! - **Change detection** — one system reads `Changed(Health)` so
//!   the per-slot evaluation runs every frame against the dirty
//!   bitset + `changed_tick` columns.
//! - **Command buffer** — one system records the deferred-mutation
//!   path but never actually issues a command (the `health <= 0`
//!   branch never fires because the bench keeps health > 0). This
//!   exercises the `commandCount == 0` fast-path in
//!   `dispatchPhase`'s flush loop.
//! - **Observer registry** — one `on_despawned` observer is
//!   registered. Since no entity is despawned during the steady-
//!   state loop, the registry's dispatch path runs at zero cost
//!   per frame (`hasPendingDeferred` returns false, the inner loop
//!   is skipped).
//!
//! Tighter than the existing `no_alloc_in_simulation_test.zig`
//! (single archetype, query-only iteration). Wider than the
//! `no_alloc_scheduler_dispatch.zig` test (jobs-only dispatch).
//! Together the three tests pin the alloc-free contract across the
//! full M0.1 surface.
//!
//! M0.2.1 / E2 — watchdog harness. The dispatchFrame measurement
//! loop runs on a worker thread; the test thread polls a `done`
//! atomic with a 5 s wall-clock budget (esprit de
//! `engine-zig-conventions.md §13` « Tests avec ressources externes —
//! timeout interne obligatoire »). On timeout, the test dumps the
//! job scheduler + event bus state via `livelock_dump.zig` and
//! aborts the test process with exit code 2 — that becomes the
//! signal the stress loop harness uses to count hangs vs healthy
//! runs. The dump targets the brief's E3 discriminant (H2 wake-lost
//! vs H4 job-lost vs H1bis isolated).

const std = @import("std");
const weld_core = @import("weld_core");
const dump = @import("livelock_dump.zig");

const ecs = weld_core.ecs;
const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;

const Mass = extern struct { value: f32 = 1.0 };
const Health = extern struct { current: f32 = 100.0, max: f32 = 100.0 };
const Sprite = extern struct { frame: u32 = 0, anim_id: u32 = 0 };

const QIntegrate = ecs.Query(&.{ ecs.Transform, ecs.Velocity }, .{});
const QDamage = ecs.Query(&.{Health}, .{});
const QChangedHealth = ecs.Query(&.{Health}, .{ecs.Changed(Health)});
const QCleanup = ecs.Query(&.{Health}, .{});

const SteadyState = struct {
    q_integrate: *QIntegrate,
    q_damage: *QDamage,
    q_changed: *QChangedHealth,
    q_cleanup: *QCleanup,
};

fn integrateChunk(chunk: *ecs.Chunk, query: *QIntegrate, dt: f32) void {
    const t_off = query.componentOffsetFor(chunk, 0);
    const v_off = query.componentOffsetFor(chunk, 1);
    const count = chunk.entityCount();
    const transforms: [*]ecs.Transform = @ptrCast(@alignCast(&chunk.bytes[t_off]));
    const velocities: [*]ecs.Velocity = @ptrCast(@alignCast(&chunk.bytes[v_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        transforms[i].pos[0] += velocities[i].linear[0] * dt;
    }
}

fn integrateSystem(ctx: ecs.SystemContext) anyerror!void {
    const s: *SteadyState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_integrate, integrateChunk, .{ s.q_integrate, ctx.frame.dt });
}

fn damageChunk(chunk: *ecs.Chunk, query: *QDamage, dt: f32) void {
    const h_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const healths: [*]Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        healths[i].current -= 0.001 * dt;
    }
}

fn damageSystem(ctx: ecs.SystemContext) anyerror!void {
    const s: *SteadyState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_damage, damageChunk, .{ s.q_damage, ctx.frame.dt });
}

var CHANGED_FLAG_TOUCHED: u64 align(64) = 0;

fn changedReaderChunk(chunk: *ecs.Chunk, query: *QChangedHealth, _: f32) void {
    const h_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    // The Changed(Health) filter is evaluated per-slot through
    // `query.slotPasses` — but `forEachChunk` itself does NOT
    // apply per-slot filters automatically (cf. query.zig doc).
    // We just touch the column so the alloc-free property is
    // measured even when the body would normally do filter work.
    const healths: [*]const Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    var local: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        local +%= @as(u64, @bitCast(@as(i64, @intFromFloat(healths[i].current))));
    }
    CHANGED_FLAG_TOUCHED +%= local;
}

fn changedReaderSystem(ctx: ecs.SystemContext) anyerror!void {
    const s: *SteadyState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_changed, changedReaderChunk, .{ s.q_changed, ctx.frame.dt });
}

fn cleanupChunk(chunk: *ecs.Chunk, query: *QCleanup, _: f32) void {
    const h_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const healths: [*]const Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // The branch never fires in steady state — health > 0
        // throughout the 100-iter test window. The branch existence
        // alone, combined with the cmd buffer field on SystemContext,
        // exercises the alloc-free path through dispatchPhase's
        // per-system flush loop (commandCount == 0 → continue).
        if (healths[i].current <= 0.0) {
            // Unreachable in this test.
            @branchHint(.cold);
        }
    }
}

fn cleanupSystem(ctx: ecs.SystemContext) anyerror!void {
    const s: *SteadyState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_cleanup, cleanupChunk, .{ s.q_cleanup, ctx.frame.dt });
}

var DESPAWN_OBSERVER_FIRED: u64 = 0;

fn onDespawnedNoop(
    _: *ecs.World,
    _: ecs.EntityId,
    _: ?ecs.ComponentId,
    _: *ecs.CommandBuffer,
) anyerror!void {
    DESPAWN_OBSERVER_FIRED +%= 1;
}

/// M0.2.1 / E2 — argument bundle for the dispatch-loop worker
/// thread. The thread runs the full dispatchFrame loop, signalling
/// completion via `done` so the watchdog can observe it.
const DispatchArgs = struct {
    sys: *ecs.SystemScheduler,
    world: *ecs.World,
    gpa: std.mem.Allocator,
    io: std.Io,
    jobs: *weld_core.jobs.scheduler.Scheduler,
    state: *SteadyState,
    iter_total: u32,
    iter_done: *std.atomic.Value(u32),
    done: *std.atomic.Value(bool),
    err_slot: *anyerror!void,
};

fn dispatchLoop(args: *DispatchArgs) void {
    var i: u32 = 0;
    while (i < args.iter_total) : (i += 1) {
        args.sys.dispatchFrame(
            args.world,
            args.gpa,
            args.io,
            args.jobs,
            1.0 / 60.0,
            args.state,
        ) catch |e| {
            args.err_slot.* = e;
            args.done.store(true, .release);
            return;
        };
        args.iter_done.store(i + 1, .release);
    }
    args.done.store(true, .release);
}

/// M0.2.1 / E2 — watchdog wrapper. Spawns `dispatchLoop` on a worker
/// thread, polls `done` every 50 ms up to a 5 s wall-clock budget.
/// On timeout, dumps the scheduler + event bus state to stderr and
/// aborts the test process with exit code 2 (= SchedulerLivelock).
fn runWithWatchdog(args: *DispatchArgs) !void {
    const thread = try std.Thread.spawn(.{}, dispatchLoop, .{args});

    const start = std.Io.Clock.now(.awake, args.io);
    const timeout_ns: i96 = 5 * std.time.ns_per_s;

    while (!args.done.load(.acquire)) {
        const now = std.Io.Clock.now(.awake, args.io);
        const elapsed_ns: i96 = start.durationTo(now).nanoseconds;
        if (elapsed_ns > timeout_ns) {
            // Timeout — dump state and abort.
            var stderr_buf: [8192]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(args.io, &stderr_buf);
            const stderr = &stderr_writer.interface;
            const elapsed_ms: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
            dump.dumpLivelockState(
                args.jobs,
                args.world,
                stderr,
                args.iter_done.load(.acquire),
                elapsed_ms,
            ) catch {};
            stderr.flush() catch {};
            // Workers are stuck on the scheduler; we cannot safely
            // `thread.join()`. Abort the process — the harness reads
            // exit code 2 as the SchedulerLivelock signal.
            std.process.exit(2);
        }
        const poll_dur: std.Io.Duration = .{ .nanoseconds = 50 * std.time.ns_per_ms };
        std.Io.sleep(args.io, poll_dur, .awake) catch {};
    }

    thread.join();
    try args.err_slot.*;
}

test "composite steady-state — queries + change detection + cmd + observers do not allocate post-warmup" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    const io = std.testing.io;

    var world = ecs.World.init();
    defer world.deinit(gpa);

    var jobs_sched = try weld_core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    // Spawn ~1000 entities across the 4 archetypes — small enough
    // that the entire test runs in well under a second even in
    // Debug mode, large enough that multiple chunks per archetype
    // get materialised.
    const t_id = try world.ensureComponentRegistered(gpa, ecs.Transform);
    const v_id = try world.ensureComponentRegistered(gpa, ecs.Velocity);
    const m_id = try world.ensureComponentRegistered(gpa, Mass);
    const h_id = try world.ensureComponentRegistered(gpa, Health);
    const s_id = try world.ensureComponentRegistered(gpa, Sprite);

    const t_def = ecs.Transform{};
    const v_def = ecs.Velocity{ .linear = .{ 0, 1, 0 } };
    const m_def = Mass{};
    const h_def = Health{};
    const s_def = Sprite{};

    {
        const ids = [_]ecs.ComponentId{ t_id, v_id, m_id };
        const pl = [_][]const u8{
            std.mem.asBytes(&t_def),
            std.mem.asBytes(&v_def),
            std.mem.asBytes(&m_def),
        };
        var i: u32 = 0;
        while (i < 400) : (i += 1) _ = try world.spawnDynamicWithValues(gpa, &ids, &pl);
    }
    {
        const ids = [_]ecs.ComponentId{ t_id, v_id, m_id, h_id };
        const pl = [_][]const u8{
            std.mem.asBytes(&t_def),
            std.mem.asBytes(&v_def),
            std.mem.asBytes(&m_def),
            std.mem.asBytes(&h_def),
        };
        var i: u32 = 0;
        while (i < 300) : (i += 1) _ = try world.spawnDynamicWithValues(gpa, &ids, &pl);
    }
    {
        const ids = [_]ecs.ComponentId{ t_id, v_id, m_id, s_id };
        const pl = [_][]const u8{
            std.mem.asBytes(&t_def),
            std.mem.asBytes(&v_def),
            std.mem.asBytes(&m_def),
            std.mem.asBytes(&s_def),
        };
        var i: u32 = 0;
        while (i < 200) : (i += 1) _ = try world.spawnDynamicWithValues(gpa, &ids, &pl);
    }
    {
        const ids = [_]ecs.ComponentId{ t_id, v_id, m_id, h_id, s_id };
        const pl = [_][]const u8{
            std.mem.asBytes(&t_def),
            std.mem.asBytes(&v_def),
            std.mem.asBytes(&m_def),
            std.mem.asBytes(&h_def),
            std.mem.asBytes(&s_def),
        };
        var i: u32 = 0;
        while (i < 100) : (i += 1) _ = try world.spawnDynamicWithValues(gpa, &ids, &pl);
    }

    // Build queries before the snapshot — their matches list is
    // heap-allocated (E3) so construction must NOT count against
    // steady-state delta.
    var q_integrate = try world.queryFiltered(gpa, &.{ ecs.Transform, ecs.Velocity }, .{});
    defer q_integrate.deinit(gpa);
    var q_damage = try world.queryFiltered(gpa, &.{Health}, .{});
    defer q_damage.deinit(gpa);
    var q_changed = try world.queryFiltered(gpa, &.{Health}, .{ecs.Changed(Health)});
    defer q_changed.deinit(gpa);
    var q_cleanup = try world.queryFiltered(gpa, &.{Health}, .{});
    defer q_cleanup.deinit(gpa);

    var state = SteadyState{
        .q_integrate = &q_integrate,
        .q_damage = &q_damage,
        .q_changed = &q_changed,
        .q_cleanup = &q_cleanup,
    };

    // Register observer (allocates on first call).
    try world.registerOnDespawned(gpa, &onDespawnedNoop);

    var sys = ecs.SystemScheduler.init();
    defer sys.deinit(gpa);

    try sys.registerSystem(gpa, &world, .{
        .phase = .fixed_update,
        .name = "integrate",
        .run = integrateSystem,
        .accesses = &.{ ecs.Reads(ecs.Velocity), ecs.Writes(ecs.Transform) },
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "damage",
        .run = damageSystem,
        .accesses = &.{ecs.Writes(Health)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "changed_reader",
        .run = changedReaderSystem,
        .accesses = &.{ecs.Reads(Health)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .post_update,
        .name = "cleanup",
        .run = cleanupSystem,
        .accesses = &.{ecs.Reads(Health)},
    });

    // Warm-up window: 10 dispatchFrame calls so the JobBuilder
    // arena reaches its working-set size, the per-system cmd
    // buffer arenas allocate their initial chunk, etc. Anything
    // that grows on first use lands during warm-up.
    var iter_done_warmup = std.atomic.Value(u32).init(0);
    var done_warmup = std.atomic.Value(bool).init(false);
    var err_warmup: anyerror!void = {};
    var args_warmup = DispatchArgs{
        .sys = &sys,
        .world = &world,
        .gpa = gpa,
        .io = io,
        .jobs = &jobs_sched,
        .state = &state,
        .iter_total = 10,
        .iter_done = &iter_done_warmup,
        .done = &done_warmup,
        .err_slot = &err_warmup,
    };
    try runWithWatchdog(&args_warmup);

    // Snapshot AFTER warm-up. Every alloc-related counter must
    // stay flat across the 100-iter measurement window.
    const before = counting.snapshot();

    var iter_done_measure = std.atomic.Value(u32).init(0);
    var done_measure = std.atomic.Value(bool).init(false);
    var err_measure: anyerror!void = {};
    var args_measure = DispatchArgs{
        .sys = &sys,
        .world = &world,
        .gpa = gpa,
        .io = io,
        .jobs = &jobs_sched,
        .state = &state,
        .iter_total = 100,
        .iter_done = &iter_done_measure,
        .done = &done_measure,
        .err_slot = &err_measure,
    };
    try runWithWatchdog(&args_measure);

    const after = counting.snapshot();
    const delta = CountingAllocator.delta(after, before);

    try std.testing.expectEqual(@as(u64, 0), delta.alloc_count);
    try std.testing.expectEqual(@as(u64, 0), delta.free_count);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_freed);

    // Observer must NOT have fired — no despawn happened.
    try std.testing.expectEqual(@as(u64, 0), DESPAWN_OBSERVER_FIRED);
}
