//! Stress variant of `no_alloc_steady_state.zig`: the same composite scenario
//! (4 archetypes × 4 systems × 1000 entities × 100 `dispatchFrame` iterations)
//! wrapped in synthetic noise that reproduces the pre-push hook's load profile,
//! each kind aimed at a distinct contention path:
//!
//!   - **CPU** — `2 × CPU count` threads on tight ALU loops. The
//!     oversubscription is the point: the pre-push runs several parallel
//!     `zig build` / `zig test` well past the logical cardinality, and the
//!     scheduler's workers must compete for cores against them.
//!
//!   - **Allocator** — 4 threads cycling malloc / free on a separate page
//!     allocator, which on macOS wakes the kernel's VM subsystem and adds
//!     latency to the very syscalls the job scheduler's mutex and condvar
//!     stand on.
//!
//!   - **Fork** — 8 threads looping `spawnAndWait` on `zig version` (10–30 ms
//!     each) to keep the fork / clone / exec / wait paths hot, as the parallel
//!     subcompilers do.
//!
//!   - **FS I/O** — 4 threads looping create + writeAll(1 MB) + flush + sync +
//!     close + reopen + readAll + close on a per-thread temporary file, for the
//!     page cache pressure and writeback of intermediate object writes.
//!
//! What the noise does is extend every `std.Thread.yield()` and `dispatchPhase`
//! inter-step gap past the worker spin window, forcing `work_available` parks —
//! which is what exposes a lost wake if one exists.
//!
//! Watchdog identical to `no_alloc_steady_state.zig`: 5 s per dispatch loop,
//! dump state and `exit(2)` on timeout.

const std = @import("std");
const weld_core = @import("weld_core");
const dump = @import("livelock_dump.zig");
const watchdog = @import("test_watchdog");

const ecs = weld_core.ecs;
const SystemContextOf = ecs.SystemContextOf;
const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;

const Mass = extern struct { value: f32 = 1.0 };
const Health = extern struct { current: f32 = 100.0, max: f32 = 100.0 };
const Sprite = extern struct { frame: u32 = 0, anim_id: u32 = 0 };

const QIntegrate = ecs.Query(&.{ ecs.Transform, ecs.Velocity }, .{});
const QDamage = ecs.Query(&.{Health}, .{});
const QChangedHealth = ecs.Query(&.{Health}, .{ecs.Changed(Health)});
const QCleanup = ecs.Query(&.{Health}, .{});

// One declared access set per registered system, named after it.
// `registerSystem` derives BOTH the DAG's descriptors and the body's context
// type from the set named here, so a body cannot be paired with a declaration
// that does not describe it.
const spec_integrate: []const ecs.Access = &.{ ecs.Access.reads(ecs.Velocity), ecs.Access.writes(ecs.Transform) };
const spec_damage: []const ecs.Access = &.{ecs.Access.writes(Health)};
const spec_changed_reader: []const ecs.Access = &.{ecs.Access.reads(Health)};
const spec_cleanup: []const ecs.Access = &.{ecs.Access.reads(Health)};

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

fn integrateSystem(ctx: SystemContextOf(spec_integrate)) anyerror!void {
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

fn damageSystem(ctx: SystemContextOf(spec_damage)) anyerror!void {
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

fn changedReaderSystem(ctx: SystemContextOf(spec_changed_reader)) anyerror!void {
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

fn cleanupSystem(ctx: SystemContextOf(spec_cleanup)) anyerror!void {
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

/// Fork churn: repeated `zig version` spawns — a print-and-exit subprocess —
/// keep the kernel's fork / clone / exec / wait paths and the page-table, fd
/// and signal machinery hot, without doing any real compilation.
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

/// FS I/O churn: a per-tid temporary file in cwd (typically under
/// `.zig-cache/o/`), looping the full write + fsync + read cycle on 1 MB for
/// page cache and writeback contention.
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

    // The noise starts BEFORE world setup so it is already hot when the first
    // dispatch runs.
    var stop_flag = std.atomic.Value(bool).init(false);
    // CPU oversubscription at 2× the logical cardinality: the pre-push's
    // parallel `zig build` / `zig test` far exceed the number of cores.
    const cpu_count = (std.Thread.getCpuCount() catch 4) * 2;
    const alloc_thread_count: usize = 4;
    // Fork churn, 8 threads of repeated spawn.
    const proc_thread_count: usize = 8;
    // FS I/O churn, 4 threads writing, fsyncing and re-reading 1 MB in a loop.
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
        // Only the healthy-completion path reaches this — the watchdog's
        // `exit(2)` bypasses every defer — and on that path the leak detector
        // requires it.
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

    var world = ecs.World.init();
    defer world.deinit(gpa);

    // A GLOBAL watchdog, covering the teardown `Scheduler.deinit()`/`join()`
    // that the per-dispatch `runWithWatchdog` below does NOT reach. Armed after
    // the noise threads so its 5 s window wraps the scheduler lifecycle tightly
    // rather than the spin-up, with `defer disarm()` declared before
    // `defer jobs_sched.deinit` so LIFO keeps it armed through deinit and join.
    // It uses `io` and its own thread stack, never the counting `gpa`, so it
    // cannot perturb the measured delta.
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

    try sys.registerSystem(gpa, &world, .fixed_update, "integrate", spec_integrate, integrateSystem);
    try sys.registerSystem(gpa, &world, .update, "damage", spec_damage, damageSystem);
    try sys.registerSystem(gpa, &world, .update, "changed_reader", spec_changed_reader, changedReaderSystem);
    try sys.registerSystem(gpa, &world, .post_update, "cleanup", spec_cleanup, cleanupSystem);

    // The same 10-dispatch warm-up as the non-stress test, so the alloc-free
    // contract carries over unchanged.
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
