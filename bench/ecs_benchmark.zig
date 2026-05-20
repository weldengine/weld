//! ECS benchmark — Phase 0 entry point.
//!
//! Currently hosts the **S1 non-regression case** inherited from
//! `bench/ecs_iteration.zig` (renamed in M0.1 / E1 per
//! `briefs/M0.1-ecs-full.md`): 100 000 entities × 1 archetype × 1000
//! measured iterations after 100 warm-up iterations through the
//! comptime-generated `(*Transform, *Velocity)` query and the work-stealing
//! scheduler. Output is a single Markdown report at
//! `zig-out/bench/ecs_benchmark.md` containing machine config, build mode,
//! per-mode timing distribution, per-worker stats, load imbalance, and a
//! GO/NO-GO verdict against the 1.0 ms median ReleaseSafe gate.
//!
//! M0.1 / E7 will extend this file with the C0.1 1 M × 4 archetypes × 10
//! systems case alongside the S1 non-regression baseline.
//!
//! ## Locked iteration body (re-used by every measurement and by the smoke
//! ## paths in `src/main.zig` and `tests/ecs/no_alloc_in_simulation_test.zig`)
//!
//! ```zig
//! velocities[i].linear[1] -= 9.81 * dt;
//! transforms[i].pos[0] += velocities[i].linear[0] * dt;
//! transforms[i].pos[1] += velocities[i].linear[1] * dt;
//! transforms[i].pos[2] += velocities[i].linear[2] * dt;
//! ```
//!
//! `--smoke`: short-circuit run (single dispatch, ~1k entities). Used by the
//! `bench-ecs-smoke` CI job to gate compilation only.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Chunk = weld_core.ecs.world.Chunk;
const Scheduler = weld_core.jobs.scheduler.Scheduler;
const SystemScheduler = weld_core.ecs.scheduler.SystemScheduler;
const SystemContext = weld_core.ecs.scheduler.SystemContext;
const Query = weld_core.ecs.world.Query;

const NumEntities: u32 = 100_000;
const WarmupIterations: u32 = 100;
const MeasuredIterations: u32 = 1000;
const SmokeEntities: u32 = 1024;

const PrimaryGateNs: u64 = 1_000_000; // 1.0 ms — primary GO/NO-GO gate
const SecondaryTargetNs: u64 = 500_000; // 0.5 ms — recorded only
const ImbalanceGate: f64 = 0.15;

/// Locked iteration body. Reads the byte offsets of the Transform and
/// Velocity columns from the dispatch args (resolved once at query
/// construction by `componentOffset` on the query view) and casts the
/// chunk bytes to the typed SoA pointers. Mirrors the pre-E2 inner
/// loop verbatim — only the way the typed pointers are recovered
/// changed.
fn integrateChunk(chunk: *Chunk, transforms_off: u16, velocities_off: u16, dt: f32) void {
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[transforms_off]));
    const velocities: [*]Velocity = @ptrCast(@alignCast(&chunk.bytes[velocities_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        velocities[i].linear[1] -= 9.81 * dt;
        transforms[i].pos[0] += velocities[i].linear[0] * dt;
        transforms[i].pos[1] += velocities[i].linear[1] * dt;
        transforms[i].pos[2] += velocities[i].linear[2] * dt;
    }
}

/// Cross-frame state shared by the M0.1 / E5a `integrateSystem` —
/// stashes the query (built once, reused every dispatch) and the
/// pre-resolved Transform / Velocity column offsets. Lives on the
/// bench main stack frame and is forwarded to each `dispatchFrame`
/// through `FrameContext.user`.
const BenchState = struct {
    query: *Query,
    transforms_off: u16,
    velocities_off: u16,
};

/// E5a system registered in the `.update` phase. Pulls its cached
/// query + offsets from `ctx.frame.user`, hands the chunked work
/// off to `ctx.jobs.dispatch`. The `dt` value comes from
/// `ctx.frame.dt` so the bench's `1.0 / 60.0` constant flows
/// through the system scheduler instead of being captured directly.
fn integrateSystem(ctx: SystemContext) anyerror!void {
    const state: *BenchState = @ptrCast(@alignCast(ctx.frame.user.?));
    ctx.jobs.dispatch(state.query, integrateChunk, .{
        state.transforms_off,
        state.velocities_off,
        ctx.frame.dt,
    });
}

fn spawnEntities(world: *World, gpa: std.mem.Allocator, n: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        _ = try world.spawn(
            gpa,
            .{ .pos = .{ fi, 0, 0 } },
            .{ .linear = .{ 0, 1, 0 } },
        );
    }
}

const Distribution = struct {
    min: u64,
    median: u64,
    mean: u64,
    p95: u64,
    max: u64,
};

fn computeDistribution(samples: []u64) Distribution {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean: u64 = @intCast(sum / @as(u128, samples.len));
    return .{
        .min = samples[0],
        .median = samples[samples.len / 2],
        .mean = mean,
        .p95 = samples[(samples.len * 95) / 100],
        .max = samples[samples.len - 1],
    };
}

fn computeImbalance(snapshots: []const weld_core.jobs.worker.WorkerStats.Snapshot) f64 {
    var min_dur: u64 = std.math.maxInt(u64);
    var max_dur: u64 = 0;
    var sum_dur: u128 = 0;
    for (snapshots) |s| {
        if (s.work_duration_ns < min_dur) min_dur = s.work_duration_ns;
        if (s.work_duration_ns > max_dur) max_dur = s.work_duration_ns;
        sum_dur += s.work_duration_ns;
    }
    const mean_dur: f64 = @as(f64, @floatFromInt(sum_dur)) / @as(f64, @floatFromInt(snapshots.len));
    if (mean_dur == 0) return 0;
    const span: f64 = @floatFromInt(max_dur - min_dur);
    return span / mean_dur;
}

const ReportContext = struct {
    distribution: Distribution,
    /// Per-worker stats — M0.1 / E5a makes the worker count
    /// runtime-derived, so this is a slice instead of a fixed-size
    /// `[worker_count]` array. Caller owns the slice.
    worker_stats: []const weld_core.jobs.worker.WorkerStats.Snapshot,
    imbalance: f64,
    total_chunks: usize,
    worker_count: usize,
    cpu_count: usize,
    total_ram_bytes: u64,
};

fn writeReport(io: std.Io, ctx: ReportContext) !void {
    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out/bench") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var file = try dir.createFile(io, "zig-out/bench/ecs_benchmark.md", .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var w = file.writer(io, &buf);
    const out = &w.interface;

    const ram_gib: f64 = @as(f64, @floatFromInt(ctx.total_ram_bytes)) / (1024.0 * 1024.0 * 1024.0);
    const verdict = if (ctx.distribution.median <= PrimaryGateNs) "GO" else "NO-GO";
    const secondary_hit = ctx.distribution.median <= SecondaryTargetNs;
    const imbalance_pct = ctx.imbalance * 100.0;

    try out.print(
        \\# S1 — ECS iteration bench
        \\
        \\## Machine config
        \\
        \\| Field | Value |
        \\|---|---|
        \\| OS | {s} |
        \\| Arch | {s} |
        \\| CPU model | {s} |
        \\| CPU count | {d} |
        \\| Total RAM | {d:.2} GiB |
        \\| Zig version | {f} |
        \\| Build mode | {s} |
        \\
        \\## Bench parameters
        \\
        \\| Field | Value |
        \\|---|---|
        \\| Entities | {d} |
        \\| Archetype | (Transform, Velocity) |
        \\| Chunks | {d} |
        \\| Workers | {d} |
        \\| Warm-up iterations | {d} |
        \\| Measured iterations | {d} |
        \\
        \\## Iteration time distribution (nanoseconds)
        \\
        \\| min | median | mean | p95 | max |
        \\|---|---|---|---|---|
        \\| {d} | {d} | {d} | {d} | {d} |
        \\
        \\## Per-worker stats (over the measured window)
        \\
        \\| Worker | Chunks processed | Steals attempted | Steals succeeded | Work duration (ns) |
        \\|---|---|---|---|---|
        \\
    ,
        .{
            @tagName(builtin.target.os.tag),
            @tagName(builtin.target.cpu.arch),
            builtin.target.cpu.model.name,
            ctx.cpu_count,
            ram_gib,
            builtin.zig_version,
            @tagName(builtin.mode),
            NumEntities,
            ctx.total_chunks,
            ctx.worker_count,
            WarmupIterations,
            MeasuredIterations,
            ctx.distribution.min,
            ctx.distribution.median,
            ctx.distribution.mean,
            ctx.distribution.p95,
            ctx.distribution.max,
        },
    );

    for (ctx.worker_stats, 0..) |s, i| {
        try out.print(
            "| {d} | {d} | {d} | {d} | {d} |\n",
            .{ i, s.chunks_processed, s.steals_attempted, s.steals_succeeded, s.work_duration_ns },
        );
    }

    try out.print(
        \\
        \\## Load imbalance
        \\
        \\`(max_worker_duration - min_worker_duration) / mean_worker_duration` over the measured window:
        \\
        \\**{d:.2}%** (gate: ≤ {d:.2}%)
        \\
        \\## Verdict
        \\
        \\| Gate | Threshold | Result |
        \\|---|---|---|
        \\| Primary (median ReleaseSafe) | ≤ {d} ns | **{s}** ({d} ns) |
        \\| Secondary (recorded only) | ≤ {d} ns | {s} ({d} ns) |
        \\| Load imbalance | ≤ {d:.2}% | {s} ({d:.2}%) |
        \\
        \\**{s}**
        \\
    ,
        .{
            imbalance_pct,
            ImbalanceGate * 100.0,
            PrimaryGateNs,
            verdict,
            ctx.distribution.median,
            SecondaryTargetNs,
            if (secondary_hit) "hit" else "miss",
            ctx.distribution.median,
            ImbalanceGate * 100.0,
            if (ctx.imbalance <= ImbalanceGate) "OK" else "OVER",
            imbalance_pct,
            verdict,
        },
    );

    try out.flush();
}

fn writeSmokeReport(io: std.Io) !void {
    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out/bench") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var file = try dir.createFile(io, "zig-out/bench/ecs_benchmark.md", .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    const out = &w.interface;
    try out.print(
        "# S1 — ECS iteration bench (smoke)\n\nCompilation gate only — no measurements taken.\n",
        .{},
    );
    try out.flush();
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--smoke")) smoke = true;
    }

    var world = World.init();
    defer world.deinit(gpa);

    const n_entities: u32 = if (smoke) SmokeEntities else NumEntities;
    try spawnEntities(&world, gpa, n_entities);

    var sched = try Scheduler.init(gpa, init.io);
    try sched.start();
    defer sched.deinit(gpa);

    // The E3 query owns a heap-allocated matches list — `defer` frees
    // it once the bench loop returns. Bench builds the query once and
    // dispatches it across every warm-up + measured iteration.
    var query = try world.query(gpa);
    defer query.deinit(gpa);
    const dt: f32 = 1.0 / 60.0;
    // M0.1 / E5a — drive the dispatch through the new SystemScheduler.
    // The integrateSystem reads its cached query + column offsets from
    // `ctx.frame.user`, dispatched once per `dispatchFrame` in the
    // `.update` phase. World.beginFrame runs inside each
    // `dispatchFrame` call.
    var bench_state = BenchState{
        .query = &query,
        .transforms_off = query.componentOffset(0),
        .velocities_off = query.componentOffset(1),
    };
    var sys_sched = SystemScheduler.init();
    defer sys_sched.deinit(gpa);
    try sys_sched.registerSystem(gpa, .{
        .phase = .update,
        .name = "bench_integrate",
        .run = integrateSystem,
    });

    if (smoke) {
        try sys_sched.dispatchFrame(&world, gpa, init.io, &sched, dt, &bench_state);
        try writeSmokeReport(init.io);
        return;
    }

    // Warm-up.
    var i: u32 = 0;
    while (i < WarmupIterations) : (i += 1) {
        try sys_sched.dispatchFrame(&world, gpa, init.io, &sched, dt, &bench_state);
    }

    sched.resetStats();

    const samples = try gpa.alloc(u64, MeasuredIterations);
    defer gpa.free(samples);

    i = 0;
    while (i < MeasuredIterations) : (i += 1) {
        const t0 = std.Io.Clock.now(.awake, init.io);
        try sys_sched.dispatchFrame(&world, gpa, init.io, &sched, dt, &bench_state);
        const t1 = std.Io.Clock.now(.awake, init.io);
        const elapsed = t0.durationTo(t1).nanoseconds;
        samples[i] = @intCast(@max(@as(i96, 0), elapsed));
    }

    const distribution = computeDistribution(samples);
    const worker_stats = try sched.snapshotStats(gpa);
    defer gpa.free(worker_stats);
    const imbalance = computeImbalance(worker_stats);

    const cpu_count = std.Thread.getCpuCount() catch 0;
    const ram_bytes = std.process.totalSystemMemory() catch 0;

    try writeReport(init.io, .{
        .distribution = distribution,
        .worker_stats = worker_stats,
        .imbalance = imbalance,
        .total_chunks = world.chunkCount(),
        .worker_count = sched.workerCount(),
        .cpu_count = cpu_count,
        .total_ram_bytes = ram_bytes,
    });

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const verdict = if (distribution.median <= PrimaryGateNs) "GO" else "NO-GO";
    try stdout_w.interface.print(
        "ECS bench median = {d} ns, imbalance = {d:.2}% — {s}\n",
        .{ distribution.median, imbalance * 100.0, verdict },
    );
    try stdout_w.interface.flush();
}
