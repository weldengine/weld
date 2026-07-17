//! M0.2.1 / E2 — stress variant of `no_alloc_steady_state.zig`.
//!
//! Runs the exact same composite steady-state scenario (4 archetypes
//! × 4 systems × 1000 entities × 100 dispatchFrame iterations) but
//! wraps it with synthetic concurrent noise that mimics the pre-push
//! hook's overall load profile:
//!
//!   - **CPU noise threads** — `noise_cpu_thread_count = 2 × CPU count`
//!     threads spinning on tight ALU loops (M0.2.1 / E2bis addition #1 —
//!     oversubscription to reproduce the real CPU contention of the
//!     pre-push where several parallel `zig build`/`zig test`
//!     far exceed the physical cardinality). Drains CPU
//!     bandwidth so the scheduler's workers compete for cores against
//!     background work — equivalent to the parallel `zig build` +
//!     `zig build test` processes that run during the pre-push hook.
//!
//!   - **Allocator pressure threads** — 4 threads doing rapid
//!     malloc / free cycles on a separate page allocator. Drives
//!     memory-allocator contention which (on macOS at least) wakes
//!     up the kernel's VM subsystem and adds latency to syscalls
//!     used by the job scheduler's mutex / condvar primitives.
//!
//!   - **Process fork threads** (M0.2.1 / E2bis addition #2) — 8 threads
//!     each looping `spawnAndWait` on `zig version` (~10-30 ms per
//!     spawn) to drive the kernel's fork/clone/exec/wait paths. The
//!     pre-push hook fans out parallel `zig build` subcompilers — this
//!     addition reproduces that fork churn synthetically.
//!
//!   - **FS I/O threads** (M0.2.1 / E2bis addition #3) — 4 threads each
//!     looping `create + writeAll(1MB) + flush + sync + close +
//!     reopen + readAll(1MB) + close` on a per-thread temporary file
//!     in cwd. Drives page cache pressure, dirty-page writeback, and
//!     fsync syscalls — the I/O footprint of `zig build` writing
//!     intermediate objects.
//!
//! Together these reproduce the H1bis → H2 amplification chain
//! documented in the brief § Notes : the noise extends every
//! `std.Thread.yield()` and `dispatchPhase` inter-step gap past
//! the worker spin window, forcing more `work_available` parks,
//! and (suspected) exposing the latent wake-lost race in
//! `std.Io.Condition.waitUncancelable`.
//!
//! Stop criterion E2 (cf. brief § Step decomposition):
//! reproduction > 90 % over 50 local runs. If reproduction stays
//! below this threshold, the brief mandates Case 2 — return to
//! Claude.ai (no autonomous decision to widen the noise).
//!
//! Watchdog : identical to `no_alloc_steady_state.zig` — 5 s budget
//! per dispatchFrame loop (warm-up + measurement), dump state and
//! exit(2) on timeout.

const std = @import("std");
const weld_core = @import("weld_core");
const dump = @import("livelock_dump.zig");
const watchdog = @import("test_watchdog");

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
        if (healths[i].current <= 0.0) {
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
    _: ?*anyopaque,
    _: *ecs.World,
    _: ecs.EntityId,
    _: ?ecs.ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: *ecs.CommandBuffer,
) anyerror!void {
    DESPAWN_OBSERVER_FIRED +%= 1;
}

// ── Noise threads ─────────────────────────────────────────────────────────

/// CPU noise — tight ALU loop. Volatile read/write through `sink`
/// prevents the optimizer from eliminating the loop body.
var CPU_NOISE_SINK: u64 align(64) = 0;

fn cpuNoiseThread(stop: *std.atomic.Value(bool)) void {
    var seed: u64 = 0x9E3779B97F4A7C15;
    while (!stop.load(.monotonic)) {
        // Mix the seed with a Wyhash-like step a few hundred times,
        // then publish to `CPU_NOISE_SINK` so the work is observable.
        var i: u32 = 0;
        while (i < 512) : (i += 1) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
        }
        _ = @atomicRmw(u64, &CPU_NOISE_SINK, .Xor, seed, .monotonic);
    }
}

/// Allocator pressure — repeatedly malloc / free buffers of varying
/// sizes. Uses the page allocator directly so it doesn't share state
/// with the test's CountingAllocator. The varying sizes drive the
/// system allocator's bin / arena management code paths, exercising
/// kernel VM syscalls under contention.
fn allocPressureThread(stop: *std.atomic.Value(bool)) void {
    const allocator = std.heap.page_allocator;
    var seed: u64 = 0xDEADBEEFCAFEBABE;
    while (!stop.load(.monotonic)) {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        const size: usize = 64 + @as(usize, @intCast(seed & 0x3FFF));
        const buf = allocator.alloc(u8, size) catch continue;
        defer allocator.free(buf);
        // Touch the buffer so the kernel actually backs the pages.
        @memset(buf, @as(u8, @truncate(seed)));
    }
}

/// M0.2.1 / E2bis addition #2 — Process fork churn. Repeatedly spawns
/// `zig version` (a fast print-and-exit subprocess) so the kernel's
/// fork / clone / exec / wait paths and the page-table / fd / signal
/// machinery stay hot — mimics the pre-push hook's parallel `zig
/// build` subcompilers without doing real compilation work.
fn processForkThread(stop: *std.atomic.Value(bool), io: std.Io) void {
    while (!stop.load(.monotonic)) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "zig", "version" },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        _ = child.wait(io) catch continue;
    }
}

/// M0.2.1 / E2bis addition #3 — FS I/O churn. Each thread maintains a
/// per-tid temporary file in cwd (typically `.zig-cache/o/.../`) and
/// loops the full write + fsync + read cycle on 1 MB to drive page
/// cache and writeback contention — the I/O footprint of the pre-push
/// hook's `zig build` intermediate object writes.
fn fsIOThread(stop: *std.atomic.Value(bool), io: std.Io, tid: u32) void {
    const gpa = std.heap.page_allocator;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        ".m0_2_1_stress_{d}.dat",
        .{tid},
    ) catch return;

    const data = gpa.alloc(u8, 1024 * 1024) catch return;
    defer gpa.free(data);
    @memset(data, 0xAB);

    const read_buf = gpa.alloc(u8, 1024 * 1024) catch return;
    defer gpa.free(read_buf);

    const cwd = std.Io.Dir.cwd();
    while (!stop.load(.monotonic)) {
        // Write phase: create + writeAll + flush + sync + close.
        const w_file = cwd.createFile(io, path, .{}) catch continue;
        var w_io_buf: [16 * 1024]u8 = undefined;
        var w = w_file.writer(io, &w_io_buf);
        w.interface.writeAll(data) catch {};
        w.interface.flush() catch {};
        w_file.sync(io) catch {};
        w_file.close(io);

        // Read phase: open + readAll(1MB) + close. Drains page cache
        // back through the read path.
        const r_file = cwd.openFile(io, path, .{}) catch continue;
        var r_io_buf: [16 * 1024]u8 = undefined;
        var r = r_file.reader(io, &r_io_buf);
        _ = r.interface.readSliceAll(read_buf) catch {};
        r_file.close(io);
    }

    // Best-effort cleanup. exit(2) from the watchdog bypasses this.
    cwd.deleteFile(io, path) catch {};
}

// ── Watchdog harness (mirrors no_alloc_steady_state.zig) ─────────────────

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

fn runWithWatchdog(args: *DispatchArgs) !void {
    const thread = try std.Thread.spawn(.{}, dispatchLoop, .{args});

    const start = std.Io.Clock.now(.awake, args.io);
    const timeout_ns: i96 = 5 * std.time.ns_per_s;

    while (!args.done.load(.acquire)) {
        const now = std.Io.Clock.now(.awake, args.io);
        const elapsed_ns: i96 = start.durationTo(now).nanoseconds;
        if (elapsed_ns > timeout_ns) {
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
            std.process.exit(2);
        }
        const poll_dur: std.Io.Duration = .{ .nanoseconds = 50 * std.time.ns_per_ms };
        std.Io.sleep(args.io, poll_dur, .awake) catch {};
    }

    thread.join();
    try args.err_slot.*;
}

test "stress steady-state — composite scenario under concurrent CPU and allocator noise" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    const io = std.testing.io;

    // ── Spin up noise threads BEFORE world setup so they're hot
    //    by the time the scheduler dispatch begins. ────────────────────
    var stop_flag = std.atomic.Value(bool).init(false);
    // M0.2.1 / E2bis addition #1 — CPU oversubscription (2× physical
    // cardinality) to reproduce the pre-push contention, where several
    // parallel `zig build`/`zig test` far exceed the number of logical
    // cores.
    const cpu_count = (std.Thread.getCpuCount() catch 4) * 2;
    const alloc_thread_count: usize = 4;
    // M0.2.1 / E2bis addition #2 — fork churn (8 threads of repeated
    // spawn to mimic the parallel subcompilers of the pre-push).
    const proc_thread_count: usize = 8;
    // M0.2.1 / E2bis addition #3 — FS I/O churn (4 threads write+fsync+read
    // 1 MB in a loop for page cache pressure + writeback).
    const fsio_thread_count: usize = 4;
    var cpu_threads = try std.testing.allocator.alloc(std.Thread, cpu_count);
    defer std.testing.allocator.free(cpu_threads);
    var alloc_threads = try std.testing.allocator.alloc(std.Thread, alloc_thread_count);
    defer std.testing.allocator.free(alloc_threads);
    var proc_threads = try std.testing.allocator.alloc(std.Thread, proc_thread_count);
    defer std.testing.allocator.free(proc_threads);
    var fsio_threads = try std.testing.allocator.alloc(std.Thread, fsio_thread_count);
    defer std.testing.allocator.free(fsio_threads);
    var n_cpu_started: usize = 0;
    var n_alloc_started: usize = 0;
    var n_proc_started: usize = 0;
    var n_fsio_started: usize = 0;
    defer {
        // Stop all started noise threads at scope exit. Done in
        // `defer` so it runs even if watchdog `exit(2)`s — well,
        // exit(2) bypasses defers; but on the healthy-completion
        // path this cleanup is required for the leak detector.
        stop_flag.store(true, .release);
        for (cpu_threads[0..n_cpu_started]) |t| t.join();
        for (alloc_threads[0..n_alloc_started]) |t| t.join();
        for (proc_threads[0..n_proc_started]) |t| t.join();
        for (fsio_threads[0..n_fsio_started]) |t| t.join();
    }
    while (n_cpu_started < cpu_count) : (n_cpu_started += 1) {
        cpu_threads[n_cpu_started] = try std.Thread.spawn(.{}, cpuNoiseThread, .{&stop_flag});
    }
    while (n_alloc_started < alloc_thread_count) : (n_alloc_started += 1) {
        alloc_threads[n_alloc_started] = try std.Thread.spawn(.{}, allocPressureThread, .{&stop_flag});
    }
    while (n_proc_started < proc_thread_count) : (n_proc_started += 1) {
        proc_threads[n_proc_started] = try std.Thread.spawn(.{}, processForkThread, .{ &stop_flag, io });
    }
    while (n_fsio_started < fsio_thread_count) : (n_fsio_started += 1) {
        fsio_threads[n_fsio_started] = try std.Thread.spawn(.{}, fsIOThread, .{ &stop_flag, io, @as(u32, @intCast(n_fsio_started)) });
    }

    // ── World + scheduler setup. ─────────────────────────────────────
    var world = ecs.World.init();
    defer world.deinit(gpa);

    // E9b: GLOBAL teardown watchdog covering Scheduler.deinit()/join() — the
    // site the local per-dispatch `runWithWatchdog` below does NOT cover. Armed
    // immediately before the Scheduler (after the noise threads) so the 5 s
    // window wraps the scheduler lifecycle + deinit/join tightly, not the noise
    // spin-up; `defer disarm()` is declared before `defer jobs_sched.deinit` so
    // LIFO keeps it armed through deinit/join. It uses `io` + its own thread
    // stack, never the counting `gpa`, so it can't perturb the measured delta
    // (the before/after `snapshot` window further down). The local
    // `runWithWatchdog` stays in place (complementary dispatch-side coverage).
    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "stress steady-state — composite scenario under concurrent CPU and allocator noise");
    defer wd.disarm();

    var jobs_sched = try weld_core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

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

    try world.registerOnDespawned(gpa, null, &onDespawnedNoop);

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

    // Warm-up window — same 10 dispatchFrame as the non-stress test
    // so the alloc-free contract carries over.
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

    try std.testing.expectEqual(@as(u64, 0), DESPAWN_OBSERVER_FIRED);
}
