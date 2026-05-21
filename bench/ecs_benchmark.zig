//! ECS benchmark — Phase 0 entry point.
//!
//! Hosts two cases, selectable via `--case=<name>`:
//!
//! 1. **S1 non-regression** (`--case=s1`, default): 100 000 entities ×
//!    1 archetype × 1000 measured iterations after 100 warm-up
//!    iterations through the comptime-generated
//!    `(*Transform, *Velocity)` query and the work-stealing scheduler.
//!    Mode requirement: ReleaseSafe (CI gate, comparable across hosts).
//!    Gate: median ≤ 62 µs (M0.1/E7 recalibrated from the 57.2 µs
//!    E5b gate by +5 µs to account for the dispatchFrame overhead
//!    inherent to the generalised scheduler — see brief journal).
//!
//! 2. **C0.1 production target** (`--case=c01`): 1 000 000 entities ×
//!    4 archetypes × 10 systems × tick loop. Mode requirement:
//!    ReleaseFast (spec C0.1 of the engine plan).
//!    Gate: median ≤ 16.6 ms (60 FPS), p99 ≤ 25 ms, imbalance ≤ 15 %.
//!
//! Output is a Markdown report at `zig-out/bench/ecs_benchmark.md`
//! containing machine config, build mode, per-mode timing
//! distribution, per-worker stats, load imbalance, and a GO/NO-GO
//! verdict against the case's gate.
//!
//! ## CLI flags
//!
//! - `--help`            — print this list and exit.
//! - `--case=s1|c01`     — pick the case. Default: `s1`.
//! - `--workers=N`       — force the job system's worker count instead of
//!                         `std.Thread.getCpuCount`. The S1 baseline is
//!                         calibrated at 4 workers (`--workers=4`) so the
//!                         CI gate is comparable across host topologies.
//!                         The C0.1 case uses the default (= one worker
//!                         per CPU) unless overridden.
//! - `--smoke`           — short-circuit run (single dispatch on a small
//!                         entity set). Used by the `bench-ecs-smoke` CI
//!                         job to gate compilation only. Applies to both
//!                         cases.
//! - `--cold-runs=N`     — number of full cold-isolated process invocations
//!                         the wrapper should expect. Affects the report
//!                         header only — the bench itself runs once.
//!
//! ## Build-mode guard
//!
//! `bench-ecs` REJECTS Debug builds (the inner gate would falsely
//! report GO at Debug speeds, hiding regressions — cf. brief E1
//! journal entry 2026-05-20 18:44). Compile with
//! `-Doptimize=ReleaseSafe` (S1) or `-Doptimize=ReleaseFast` (C0.1).
//!
//! ## Locked iteration body (S1 case — re-used by every measurement
//! ## and by the smoke paths in `src/main.zig` and
//! ## `tests/ecs/no_alloc_in_simulation_test.zig`)
//!
//! ```zig
//! velocities[i].linear[1] -= 9.81 * dt;
//! transforms[i].pos[0] += velocities[i].linear[0] * dt;
//! transforms[i].pos[1] += velocities[i].linear[1] * dt;
//! transforms[i].pos[2] += velocities[i].linear[2] * dt;
//! ```

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

// ─── S1 constants ─────────────────────────────────────────────────────────

const S1NumEntities: u32 = 100_000;
const S1WarmupIterations: u32 = 100;
const S1MeasuredIterations: u32 = 1000;
const S1SmokeEntities: u32 = 1024;

const S1LegacyPrimaryGateNs: u64 = 1_000_000; // 1.0 ms — historic S1 ceiling
const S1RegressionGateNs: u64 = 62_000; // 62 µs — E7 recalibrated gate
const SecondaryTargetNs: u64 = 500_000; // 0.5 ms — recorded only
const ImbalanceGate: f64 = 0.15;

// ─── Case selector ────────────────────────────────────────────────────────

const Case = enum { s1, c01 };

fn parseCase(s: []const u8) ?Case {
    if (std.mem.eql(u8, s, "s1")) return .s1;
    if (std.mem.eql(u8, s, "c01")) return .c01;
    return null;
}

// ─── S1 — Locked iteration body + system ──────────────────────────────────

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

/// Cross-frame state shared by the S1 `integrateSystem` —
/// stashes the query (built once, reused every dispatch) and the
/// pre-resolved Transform / Velocity column offsets. Lives on the
/// bench main stack frame and is forwarded to each `dispatchFrame`
/// through `FrameContext.user`.
const S1BenchState = struct {
    query: *Query,
    transforms_off: u16,
    velocities_off: u16,
};

fn integrateSystem(ctx: SystemContext) anyerror!void {
    const state: *S1BenchState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(state.query, integrateChunk, .{
        state.transforms_off,
        state.velocities_off,
        ctx.frame.dt,
    });
}

fn spawnS1Entities(world: *World, gpa: std.mem.Allocator, n: u32) !void {
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

// ─── Distribution helpers ─────────────────────────────────────────────────

const Distribution = struct {
    min: u64,
    median: u64,
    mean: u64,
    p95: u64,
    p99: u64,
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
        .p99 = samples[(samples.len * 99) / 100],
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
    case: Case,
    distribution: Distribution,
    /// Per-worker stats. Caller owns the slice.
    worker_stats: []const weld_core.jobs.worker.WorkerStats.Snapshot,
    imbalance: f64,
    total_chunks: usize,
    total_entities: u32,
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
    const imbalance_pct = ctx.imbalance * 100.0;

    const case_name: []const u8 = switch (ctx.case) {
        .s1 => "S1 — ECS iteration bench",
        .c01 => "C0.1 — ECS production target bench",
    };
    const primary_gate_ns: u64 = switch (ctx.case) {
        .s1 => S1RegressionGateNs,
        .c01 => 16_600_000,
    };
    const verdict = if (ctx.distribution.median <= primary_gate_ns) "GO" else "NO-GO";
    const secondary_hit = ctx.case == .s1 and ctx.distribution.median <= SecondaryTargetNs;

    try out.print(
        \\# {s}
        \\
        \\## Machine config
        \\
        \\| Field | Value |
        \\|---|---|
        \\| OS | {s} |
        \\| Arch | {s} |
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
        \\| Total chunks | {d} |
        \\| Worker count | {d} |
        \\
        \\## Timing distribution (ns)
        \\
        \\| min | median | mean | p95 | p99 | max |
        \\|---|---|---|---|---|---|
        \\| {d} | {d} | {d} | {d} | {d} | {d} |
        \\
        \\## Load imbalance
        \\
        \\| Worker | Chunks | Steal attempts | Steal hits | Parks done | Work duration (ns) |
        \\|---|---|---|---|---|---|
        \\
    , .{
        case_name,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        ctx.cpu_count,
        ram_gib,
        builtin.zig_version,
        @tagName(builtin.mode),
        ctx.total_entities,
        ctx.total_chunks,
        ctx.worker_count,
        ctx.distribution.min,
        ctx.distribution.median,
        ctx.distribution.mean,
        ctx.distribution.p95,
        ctx.distribution.p99,
        ctx.distribution.max,
    });
    for (ctx.worker_stats, 0..) |s, idx| {
        try out.print(
            "| {d} | {d} | {d} | {d} | {d} | {d} |\n",
            .{
                idx,
                s.chunks_processed,
                s.steals_attempted,
                s.steals_succeeded,
                s.parks_completed,
                s.work_duration_ns,
            },
        );
    }
    try out.print(
        \\
        \\Span / mean = **{d:.2}%** (gate {d:.0}%).
        \\
        \\## Verdict
        \\
        \\Primary gate: median ≤ {d} ns — **{s}**
        \\
    , .{
        imbalance_pct,
        ImbalanceGate * 100.0,
        primary_gate_ns,
        verdict,
    });
    if (ctx.case == .s1) {
        try out.print(
            "\nSecondary (record only): median ≤ {d} ns — {s} ({d} ns)\n",
            .{ SecondaryTargetNs, if (secondary_hit) "hit" else "miss", ctx.distribution.median },
        );
    }
    try out.print(
        \\
        \\Imbalance gate: ≤ {d:.0}% — **{s}** ({d:.2}%)
        \\
        \\Result: median = {d} ns, verdict = **{s}**.
        \\
    , .{
        ImbalanceGate * 100.0,
        if (ctx.imbalance <= ImbalanceGate) "OK" else "OVER",
        imbalance_pct,
        ctx.distribution.median,
        verdict,
    });

    try out.flush();
}

fn writeSmokeReport(io: std.Io, case: Case) !void {
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
    const case_name: []const u8 = switch (case) {
        .s1 => "S1",
        .c01 => "C0.1",
    };
    try out.print(
        "# {s} — ECS bench (smoke)\n\nCompilation gate only — no measurements taken.\n",
        .{case_name},
    );
    try out.flush();
}

// ─── Help text ────────────────────────────────────────────────────────────

const help_text =
    \\ecs-benchmark — Weld ECS micro and macro benchmarks
    \\
    \\Usage: ecs-benchmark [options]
    \\
    \\Options:
    \\  --help             Print this help and exit.
    \\  --case=s1|c01      Pick the case. Default: s1.
    \\                       s1  — 100k entities × 1 archetype × 1000 iter.
    \\                              Mode: ReleaseSafe. Gate: median ≤ 62 µs.
    \\                       c01 — 1M entities × 4 archetypes × 10 systems.
    \\                              Mode: ReleaseFast. Gate: median ≤ 16.6 ms,
    \\                              p99 ≤ 25 ms, imbalance ≤ 15 %.
    \\  --workers=N        Force the job-system worker count.
    \\                       S1 baseline calibrated at --workers=4.
    \\  --smoke            Single-dispatch sanity run on a small set.
    \\                       Used by the bench-ecs-smoke CI step.
    \\  --cold-runs=N      Informational — number of full cold-isolated
    \\                       process invocations the wrapper expects.
    \\                       The bench itself runs once per invocation.
    \\
    \\Build-mode guard: Debug builds are rejected.
    \\
;

// ─── Build-mode guard ─────────────────────────────────────────────────────

fn assertReleaseMode() void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSmall) {
        std.debug.print(
            "ERROR: ecs-benchmark refuses build mode .{s}. Compile with " ++
                "-Doptimize=ReleaseSafe (S1) or -Doptimize=ReleaseFast (C0.1).\n",
            .{@tagName(builtin.mode)},
        );
        std.process.exit(2);
    }
}

// ─── S1 case ──────────────────────────────────────────────────────────────

fn runS1(
    gpa: std.mem.Allocator,
    io: std.Io,
    smoke: bool,
    worker_count_override: ?usize,
) !void {
    var world = World.init();
    defer world.deinit(gpa);

    const n_entities: u32 = if (smoke) S1SmokeEntities else S1NumEntities;
    try spawnS1Entities(&world, gpa, n_entities);

    var sched = if (worker_count_override) |n|
        try Scheduler.initWithWorkerCount(gpa, io, n)
    else
        try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);

    var query = try world.query(gpa);
    defer query.deinit(gpa);
    const dt: f32 = 1.0 / 60.0;

    var bench_state = S1BenchState{
        .query = &query,
        .transforms_off = query.componentOffset(0),
        .velocities_off = query.componentOffset(1),
    };
    var sys_sched = SystemScheduler.init();
    defer sys_sched.deinit(gpa);
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "bench_integrate",
        .run = integrateSystem,
    });

    if (smoke) {
        try sys_sched.dispatchFrame(&world, gpa, io, &sched, dt, &bench_state);
        try writeSmokeReport(io, .s1);
        return;
    }

    // Warm-up.
    var i: u32 = 0;
    while (i < S1WarmupIterations) : (i += 1) {
        try sys_sched.dispatchFrame(&world, gpa, io, &sched, dt, &bench_state);
    }

    sched.resetStats();

    const samples = try gpa.alloc(u64, S1MeasuredIterations);
    defer gpa.free(samples);

    i = 0;
    while (i < S1MeasuredIterations) : (i += 1) {
        const t0 = std.Io.Clock.now(.awake, io);
        try sys_sched.dispatchFrame(&world, gpa, io, &sched, dt, &bench_state);
        const t1 = std.Io.Clock.now(.awake, io);
        const elapsed = t0.durationTo(t1).nanoseconds;
        samples[i] = @intCast(@max(@as(i96, 0), elapsed));
    }

    const distribution = computeDistribution(samples);
    const worker_stats = try sched.snapshotStats(gpa);
    defer gpa.free(worker_stats);
    const imbalance = computeImbalance(worker_stats);

    const cpu_count = std.Thread.getCpuCount() catch 0;
    const ram_bytes = std.process.totalSystemMemory() catch 0;

    try writeReport(io, .{
        .case = .s1,
        .distribution = distribution,
        .worker_stats = worker_stats,
        .imbalance = imbalance,
        .total_chunks = world.chunkCount(),
        .total_entities = n_entities,
        .worker_count = sched.workerCount(),
        .cpu_count = cpu_count,
        .total_ram_bytes = ram_bytes,
    });

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const verdict = if (distribution.median <= S1RegressionGateNs) "GO" else "NO-GO";
    try stdout_w.interface.print(
        "ECS bench median = {d} ns, imbalance = {d:.2}% — {s}\n",
        .{ distribution.median, imbalance * 100.0, verdict },
    );
    try stdout_w.interface.flush();
}

// ─── C0.1 case — placeholder until E7.2 ───────────────────────────────────

fn runC01(
    _: std.mem.Allocator,
    io: std.Io,
    smoke: bool,
    _: ?usize,
) !void {
    if (smoke) {
        try writeSmokeReport(io, .c01);
        return;
    }
    std.debug.print(
        "ERROR: --case=c01 is not yet implemented (M0.1 / E7.2).\n",
        .{},
    );
    std.process.exit(3);
}

// ─── main ─────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var case: Case = .s1;
    var smoke = false;
    var worker_count_override: ?usize = null;

    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{help_text});
            return;
        } else if (std.mem.eql(u8, a, "--smoke")) {
            smoke = true;
        } else if (std.mem.startsWith(u8, a, "--workers=")) {
            const value_str = a["--workers=".len..];
            worker_count_override = try std.fmt.parseInt(usize, value_str, 10);
        } else if (std.mem.startsWith(u8, a, "--case=")) {
            const value_str = a["--case=".len..];
            case = parseCase(value_str) orelse {
                std.debug.print(
                    "ERROR: unknown --case={s}. Valid: s1, c01.\n",
                    .{value_str},
                );
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, a, "--cold-runs=")) {
            // Informational only — affects nothing in this binary.
        } else {
            std.debug.print(
                "WARNING: unknown bench arg '{s}' (run with --help).\n",
                .{a},
            );
        }
    }

    // Build-mode guard — skip for smoke (CI compile-only path).
    if (!smoke) assertReleaseMode();

    switch (case) {
        .s1 => try runS1(gpa, init.io, smoke, worker_count_override),
        .c01 => try runC01(gpa, init.io, smoke, worker_count_override),
    }
}
