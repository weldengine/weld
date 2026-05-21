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

    // Resolve column offsets once at setup — single-archetype
    // query, so `componentOffsetFor` on any chunk returns the same
    // value. The hot loop reads `bench_state.transforms_off /
    // velocities_off` instead of paying the per-chunk lookup.
    const first_chunk = query.chunkAt(0);
    var bench_state = S1BenchState{
        .query = &query,
        .transforms_off = query.componentOffsetFor(first_chunk, 0),
        .velocities_off = query.componentOffsetFor(first_chunk, 1),
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

// ─── C0.1 — production target case ────────────────────────────────────────
//
// 1 000 000 entities across 4 archetypes × 10 systems × 6 phases ×
// tick loop. Mode: ReleaseFast. Gates: median ≤ 16.6 ms (60 FPS),
// p99 ≤ 25 ms, imbalance ≤ 15 %.
//
// Archetypes (component composition deliberately overlapping so the
// 10 systems below get non-trivial multi-archetype matches):
//
//   A1 (Transform, Velocity, Mass)                            700 000  "physics-only objects"
//   A2 (Transform, Velocity, Mass, Health)                    200 000  "characters"
//   A3 (Transform, Velocity, Mass, Sprite)                     60 000  "sprite-only objects"
//   A4 (Transform, Velocity, Mass, Health, Sprite, AI)         40 000  "full NPCs"
//
// Phase map (DAG-friendly: writes ordered before reads on the same
// component, no W/W conflicts inside a phase):
//
//   pre_update:    ai_decide (W:AI, R:Transform,Health)       — A4 only
//                  update_camera (R:Transform)                — all 4
//   fixed_update:  apply_gravity (W:Velocity, R:Mass)         — all 4
//                  integrate_motion (W:Transform, R:Velocity) — all 4   [runs after apply_gravity via W→R on Velocity? no — different components.
//                                                                         Actually integrate writes Transform and reads Velocity, while apply_gravity
//                                                                         writes Velocity and reads Mass → no overlap → both level 0.
//                                                                         BUT integrate consumes Velocity which apply_gravity wrote → forward dataflow → W→R → seriliase.
//                                                                         Yes — apply_gravity Writes(Velocity), integrate Reads(Velocity) → W→R.
//                                                                         So apply_gravity is level 0, integrate is level 1.]
//   update:        damage_resolution (W:Health)               — A2, A4
//                  score_tracker (R:Health)                   — A2, A4 [W→R after damage_resolution]
//                  sprite_animator (W:Sprite)                 — A3, A4 [no overlap with damage/score, level 0 alongside damage]
//   post_update:   cleanup_dead (R:Health)                    — A2, A4 [reads Health, may queue despawn via cmd buffer]
//   late_update:   interpolate_transform (W:Sprite, R:Transform) — A3, A4
//                                                                  [interpolate Writes Sprite again — late_update is a separate phase so no
//                                                                   W/W conflict with sprite_animator in update]
//   pre_render:    frustum_cull (R:Transform, R:Sprite)       — A3, A4
//
// Total: 10 systems across 5 phases (skip fixed_update for one,
// wait no, fixed_update has 2). Actually 6 phases, fixed_update has
// 2, pre_update has 2, update has 3, post_update has 1, late_update
// has 1, pre_render has 1. Total 10. ✓

const C01Mass = extern struct { value: f32 = 1.0 };
const C01Health = extern struct { current: f32 = 100.0, max: f32 = 100.0 };
const C01Sprite = extern struct { frame: u32 = 0, anim_id: u32 = 0 };
const C01AI = extern struct { state: u32 = 0, target_index: u32 = 0 };

// Entity counts per archetype.
const C01NormalCounts: [4]u32 = .{ 700_000, 200_000, 60_000, 40_000 };
const C01SmokeCounts: [4]u32 = .{ 700, 200, 60, 40 };

const C01WarmupIterations: u32 = 100;
const C01MeasuredIterations: u32 = 1000;
const C01PrimaryGateNs: u64 = 16_600_000; // 16.6 ms — 60 FPS budget
const C01P99GateNs: u64 = 25_000_000; // 25 ms — p99 ceiling

// Query types — concrete because the body functions need to know the
// `componentOffsetFor` indices at the typed call site.
const QAI = weld_core.ecs.query.Query(&.{ Transform, C01Health, C01AI }, .{});
const QCamera = weld_core.ecs.query.Query(&.{Transform}, .{});
const QGravity = weld_core.ecs.query.Query(&.{ Velocity, C01Mass }, .{});
const QIntegrate = weld_core.ecs.query.Query(&.{ Transform, Velocity }, .{});
const QHealthW = weld_core.ecs.query.Query(&.{C01Health}, .{});
const QHealthR1 = weld_core.ecs.query.Query(&.{C01Health}, .{});
const QSpriteW = weld_core.ecs.query.Query(&.{C01Sprite}, .{});
const QHealthR2 = weld_core.ecs.query.Query(&.{C01Health}, .{});
const QInterp = weld_core.ecs.query.Query(&.{ Transform, C01Sprite }, .{});
const QFrustum = weld_core.ecs.query.Query(&.{ Transform, C01Sprite }, .{});

const Reads = weld_core.ecs.scheduler.Reads;
const Writes = weld_core.ecs.scheduler.Writes;

/// Cross-frame state for the C0.1 systems — one query per system,
/// stashed once at bench setup and reused across every dispatch.
const C01State = struct {
    q_ai: *QAI,
    q_camera: *QCamera,
    q_gravity: *QGravity,
    q_integrate: *QIntegrate,
    q_damage: *QHealthW,
    q_score: *QHealthR1,
    q_sprite: *QSpriteW,
    q_cleanup: *QHealthR2,
    q_interp: *QInterp,
    q_frustum: *QFrustum,
};

// ─── C0.1 — system body functions ─────────────────────────────────────────

// To prevent the optimiser from eliding the per-entity work, every
// body folds a result into a global atomic counter at the end of the
// chunk. The counter is reset each frame.
var C01_SCORE_ACC: std.atomic.Value(u64) align(64) = .init(0);
var C01_CAMERA_ACC: std.atomic.Value(u64) align(64) = .init(0);
var C01_FRUSTUM_ACC: std.atomic.Value(u64) align(64) = .init(0);

fn c01AiDecideChunk(chunk: *Chunk, query: *QAI, dt: f32) void {
    _ = dt;
    const t_off = query.componentOffsetFor(chunk, 0);
    const h_off = query.componentOffsetFor(chunk, 1);
    const a_off = query.componentOffsetFor(chunk, 2);
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[t_off]));
    const healths: [*]C01Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    const ais: [*]C01AI = @ptrCast(@alignCast(&chunk.bytes[a_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Cheap decision tree — keep state if health > 50, else flip.
        const next_state: u32 = if (healths[i].current > 50.0) ais[i].state else (ais[i].state +% 1) & 7;
        ais[i].state = next_state;
        ais[i].target_index = @as(u32, @bitCast(transforms[i].pos[0])) & 0xFFFF;
    }
}

fn c01AiDecideSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_ai, c01AiDecideChunk, .{ s.q_ai, ctx.frame.dt });
}

fn c01UpdateCameraChunk(chunk: *Chunk, query: *QCamera, _: f32) void {
    const t_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[t_off]));
    var local: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        local +%= @as(u64, @bitCast(@as(i64, @intFromFloat(transforms[i].pos[0] + transforms[i].pos[1] + transforms[i].pos[2]))));
    }
    _ = C01_CAMERA_ACC.fetchAdd(local, .acq_rel);
}

fn c01UpdateCameraSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_camera, c01UpdateCameraChunk, .{ s.q_camera, ctx.frame.dt });
}

fn c01ApplyGravityChunk(chunk: *Chunk, query: *QGravity, dt: f32) void {
    const v_off = query.componentOffsetFor(chunk, 0);
    const m_off = query.componentOffsetFor(chunk, 1);
    const count = chunk.entityCount();
    const velocities: [*]Velocity = @ptrCast(@alignCast(&chunk.bytes[v_off]));
    const masses: [*]C01Mass = @ptrCast(@alignCast(&chunk.bytes[m_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        velocities[i].linear[1] -= 9.81 * masses[i].value * dt;
    }
}

fn c01ApplyGravitySystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_gravity, c01ApplyGravityChunk, .{ s.q_gravity, ctx.frame.dt });
}

fn c01IntegrateMotionChunk(chunk: *Chunk, query: *QIntegrate, dt: f32) void {
    const t_off = query.componentOffsetFor(chunk, 0);
    const v_off = query.componentOffsetFor(chunk, 1);
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[t_off]));
    const velocities: [*]Velocity = @ptrCast(@alignCast(&chunk.bytes[v_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        transforms[i].pos[0] += velocities[i].linear[0] * dt;
        transforms[i].pos[1] += velocities[i].linear[1] * dt;
        transforms[i].pos[2] += velocities[i].linear[2] * dt;
    }
}

fn c01IntegrateMotionSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_integrate, c01IntegrateMotionChunk, .{ s.q_integrate, ctx.frame.dt });
}

fn c01DamageChunk(chunk: *Chunk, query: *QHealthW, dt: f32) void {
    const h_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const healths: [*]C01Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    var i: u32 = 0;
    // Light continuous damage — 0.001/frame keeps entities alive
    // through the 1000-iter measurement window.
    while (i < count) : (i += 1) {
        healths[i].current -= 0.001 * dt;
    }
}

fn c01DamageSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_damage, c01DamageChunk, .{ s.q_damage, ctx.frame.dt });
}

fn c01ScoreChunk(chunk: *Chunk, query: *QHealthR1, _: f32) void {
    const h_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const healths: [*]C01Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    var local: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        local +%= @as(u64, @bitCast(@as(i64, @intFromFloat(healths[i].current))));
    }
    _ = C01_SCORE_ACC.fetchAdd(local, .acq_rel);
}

fn c01ScoreSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_score, c01ScoreChunk, .{ s.q_score, ctx.frame.dt });
}

fn c01SpriteAnimChunk(chunk: *Chunk, query: *QSpriteW, _: f32) void {
    const s_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const sprites: [*]C01Sprite = @ptrCast(@alignCast(&chunk.bytes[s_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        sprites[i].frame = (sprites[i].frame +% 1) % 60;
    }
}

fn c01SpriteAnimSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_sprite, c01SpriteAnimChunk, .{ s.q_sprite, ctx.frame.dt });
}

fn c01CleanupDeadChunk(chunk: *Chunk, query: *QHealthR2, _: f32) void {
    const h_off = query.componentOffsetFor(chunk, 0);
    const count = chunk.entityCount();
    const healths: [*]C01Health = @ptrCast(@alignCast(&chunk.bytes[h_off]));
    var local: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Read-only pass — would record a despawn via cmd buffer if
        // health <= 0, but the bench keeps health > 0 across the
        // 1000-iter window so this branch never fires. The branch
        // and the read still cost the budget we want to measure.
        if (healths[i].current <= 0.0) {
            local +%= 1;
        }
    }
    _ = C01_SCORE_ACC.fetchAdd(local, .acq_rel);
}

fn c01CleanupDeadSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_cleanup, c01CleanupDeadChunk, .{ s.q_cleanup, ctx.frame.dt });
}

fn c01InterpChunk(chunk: *Chunk, query: *QInterp, _: f32) void {
    const t_off = query.componentOffsetFor(chunk, 0);
    const s_off = query.componentOffsetFor(chunk, 1);
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[t_off]));
    const sprites: [*]C01Sprite = @ptrCast(@alignCast(&chunk.bytes[s_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Re-derive sprite anim_id from transform pos hash — cheap
        // arithmetic that touches both columns (write to sprite, read
        // from transform).
        sprites[i].anim_id = @as(u32, @bitCast(transforms[i].pos[0])) ^ @as(u32, @bitCast(transforms[i].pos[2]));
    }
}

fn c01InterpSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_interp, c01InterpChunk, .{ s.q_interp, ctx.frame.dt });
}

fn c01FrustumChunk(chunk: *Chunk, query: *QFrustum, _: f32) void {
    const t_off = query.componentOffsetFor(chunk, 0);
    const s_off = query.componentOffsetFor(chunk, 1);
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[t_off]));
    const sprites: [*]C01Sprite = @ptrCast(@alignCast(&chunk.bytes[s_off]));
    var visible: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Trivial frustum: 0 < x < 1000 and sprite.frame != 0.
        const inside_x = transforms[i].pos[0] > 0 and transforms[i].pos[0] < 1000.0;
        if (inside_x and sprites[i].frame != 0) visible +%= 1;
    }
    _ = C01_FRUSTUM_ACC.fetchAdd(visible, .acq_rel);
}

fn c01FrustumSystem(ctx: SystemContext) anyerror!void {
    const s: *C01State = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(s.q_frustum, c01FrustumChunk, .{ s.q_frustum, ctx.frame.dt });
}

// ─── C0.1 — entity spawn ──────────────────────────────────────────────────

fn spawnC01Entities(
    world: *World,
    gpa: std.mem.Allocator,
    counts: [4]u32,
) !void {
    // Pre-register every component once so `spawnDynamicWithValues`
    // does not pay the registration cost per spawn.
    const t_id = try world.ensureComponentRegistered(gpa, Transform);
    const v_id = try world.ensureComponentRegistered(gpa, Velocity);
    const m_id = try world.ensureComponentRegistered(gpa, C01Mass);
    const h_id = try world.ensureComponentRegistered(gpa, C01Health);
    const s_id = try world.ensureComponentRegistered(gpa, C01Sprite);
    const a_id = try world.ensureComponentRegistered(gpa, C01AI);

    const t_default = Transform{ .pos = .{ 100, 100, 100 } };
    const v_default = Velocity{ .linear = .{ 0, 1, 0 } };
    const m_default = C01Mass{};
    const h_default = C01Health{};
    const s_default = C01Sprite{ .frame = 1 };
    const a_default = C01AI{};

    const t_bytes = std.mem.asBytes(&t_default);
    const v_bytes = std.mem.asBytes(&v_default);
    const m_bytes = std.mem.asBytes(&m_default);
    const h_bytes = std.mem.asBytes(&h_default);
    const s_bytes = std.mem.asBytes(&s_default);
    const a_bytes = std.mem.asBytes(&a_default);

    // A1 (T, V, M)
    {
        const ids = [_]registry_id_t{ t_id, v_id, m_id };
        const payloads = [_][]const u8{ t_bytes, v_bytes, m_bytes };
        var i: u32 = 0;
        while (i < counts[0]) : (i += 1) {
            _ = try world.spawnDynamicWithValues(gpa, &ids, &payloads);
        }
    }
    // A2 (T, V, M, H)
    {
        const ids = [_]registry_id_t{ t_id, v_id, m_id, h_id };
        const payloads = [_][]const u8{ t_bytes, v_bytes, m_bytes, h_bytes };
        var i: u32 = 0;
        while (i < counts[1]) : (i += 1) {
            _ = try world.spawnDynamicWithValues(gpa, &ids, &payloads);
        }
    }
    // A3 (T, V, M, S)
    {
        const ids = [_]registry_id_t{ t_id, v_id, m_id, s_id };
        const payloads = [_][]const u8{ t_bytes, v_bytes, m_bytes, s_bytes };
        var i: u32 = 0;
        while (i < counts[2]) : (i += 1) {
            _ = try world.spawnDynamicWithValues(gpa, &ids, &payloads);
        }
    }
    // A4 (T, V, M, H, S, A)
    {
        const ids = [_]registry_id_t{ t_id, v_id, m_id, h_id, s_id, a_id };
        const payloads = [_][]const u8{ t_bytes, v_bytes, m_bytes, h_bytes, s_bytes, a_bytes };
        var i: u32 = 0;
        while (i < counts[3]) : (i += 1) {
            _ = try world.spawnDynamicWithValues(gpa, &ids, &payloads);
        }
    }
}

const registry_id_t = weld_core.ecs.registry.ComponentId;

// ─── C0.1 — run ───────────────────────────────────────────────────────────

fn runC01(
    gpa: std.mem.Allocator,
    io: std.Io,
    smoke: bool,
    worker_count_override: ?usize,
) !void {
    var world = World.init();
    defer world.deinit(gpa);

    const counts: [4]u32 = if (smoke) C01SmokeCounts else C01NormalCounts;
    try spawnC01Entities(&world, gpa, counts);

    var sched = if (worker_count_override) |n|
        try Scheduler.initWithWorkerCount(gpa, io, n)
    else
        try Scheduler.init(gpa, io);
    try sched.start();
    defer sched.deinit(gpa);

    // Build all 10 queries. Each is heap-allocated (matches list)
    // and freed via defer.
    var q_ai = try world.queryFiltered(gpa, &.{ Transform, C01Health, C01AI }, .{});
    defer q_ai.deinit(gpa);
    var q_camera = try world.queryFiltered(gpa, &.{Transform}, .{});
    defer q_camera.deinit(gpa);
    var q_gravity = try world.queryFiltered(gpa, &.{ Velocity, C01Mass }, .{});
    defer q_gravity.deinit(gpa);
    var q_integrate = try world.queryFiltered(gpa, &.{ Transform, Velocity }, .{});
    defer q_integrate.deinit(gpa);
    var q_damage = try world.queryFiltered(gpa, &.{C01Health}, .{});
    defer q_damage.deinit(gpa);
    var q_score = try world.queryFiltered(gpa, &.{C01Health}, .{});
    defer q_score.deinit(gpa);
    var q_sprite = try world.queryFiltered(gpa, &.{C01Sprite}, .{});
    defer q_sprite.deinit(gpa);
    var q_cleanup = try world.queryFiltered(gpa, &.{C01Health}, .{});
    defer q_cleanup.deinit(gpa);
    var q_interp = try world.queryFiltered(gpa, &.{ Transform, C01Sprite }, .{});
    defer q_interp.deinit(gpa);
    var q_frustum = try world.queryFiltered(gpa, &.{ Transform, C01Sprite }, .{});
    defer q_frustum.deinit(gpa);

    var state = C01State{
        .q_ai = &q_ai,
        .q_camera = &q_camera,
        .q_gravity = &q_gravity,
        .q_integrate = &q_integrate,
        .q_damage = &q_damage,
        .q_score = &q_score,
        .q_sprite = &q_sprite,
        .q_cleanup = &q_cleanup,
        .q_interp = &q_interp,
        .q_frustum = &q_frustum,
    };

    var sys_sched = SystemScheduler.init();
    defer sys_sched.deinit(gpa);

    // pre_update — ai_decide + update_camera (parallel, no overlap).
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .pre_update,
        .name = "ai_decide",
        .run = c01AiDecideSystem,
        .accesses = &.{ Reads(Transform), Reads(C01Health), Writes(C01AI) },
    });
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .pre_update,
        .name = "update_camera",
        .run = c01UpdateCameraSystem,
        .accesses = &.{Reads(Transform)},
    });

    // fixed_update — apply_gravity (W:Velocity) then integrate_motion
    // (R:Velocity, W:Transform). DAG W→R serialises them.
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .fixed_update,
        .name = "apply_gravity",
        .run = c01ApplyGravitySystem,
        .accesses = &.{ Reads(C01Mass), Writes(Velocity) },
    });
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .fixed_update,
        .name = "integrate_motion",
        .run = c01IntegrateMotionSystem,
        .accesses = &.{ Reads(Velocity), Writes(Transform) },
    });

    // update — damage_resolution (W:Health) → score_tracker (R:Health),
    // sprite_animator (W:Sprite) parallel on level 0 with damage.
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "damage_resolution",
        .run = c01DamageSystem,
        .accesses = &.{Writes(C01Health)},
    });
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "sprite_animator",
        .run = c01SpriteAnimSystem,
        .accesses = &.{Writes(C01Sprite)},
    });
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "score_tracker",
        .run = c01ScoreSystem,
        .accesses = &.{Reads(C01Health)},
    });

    // post_update — cleanup_dead (R:Health).
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .post_update,
        .name = "cleanup_dead",
        .run = c01CleanupDeadSystem,
        .accesses = &.{Reads(C01Health)},
    });

    // late_update — interpolate_transform (R:Transform, W:Sprite).
    // Note: same component Sprite is written here AND in update
    // phase's sprite_animator. Phase boundary flushes everything so
    // no W/W conflict — the DAG is scoped per phase.
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .late_update,
        .name = "interpolate_transform",
        .run = c01InterpSystem,
        .accesses = &.{ Reads(Transform), Writes(C01Sprite) },
    });

    // pre_render — frustum_cull (R:Transform, R:Sprite).
    try sys_sched.registerSystem(gpa, &world, .{
        .phase = .pre_render,
        .name = "frustum_cull",
        .run = c01FrustumSystem,
        .accesses = &.{ Reads(Transform), Reads(C01Sprite) },
    });

    const dt: f32 = 1.0 / 60.0;

    if (smoke) {
        try sys_sched.dispatchFrame(&world, gpa, io, &sched, dt, &state);
        try writeSmokeReport(io, .c01);
        return;
    }

    // Warm-up.
    var i: u32 = 0;
    while (i < C01WarmupIterations) : (i += 1) {
        try sys_sched.dispatchFrame(&world, gpa, io, &sched, dt, &state);
    }

    sched.resetStats();

    const samples = try gpa.alloc(u64, C01MeasuredIterations);
    defer gpa.free(samples);

    i = 0;
    while (i < C01MeasuredIterations) : (i += 1) {
        const t0 = std.Io.Clock.now(.awake, io);
        try sys_sched.dispatchFrame(&world, gpa, io, &sched, dt, &state);
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

    const total_entities = counts[0] + counts[1] + counts[2] + counts[3];

    try writeReport(io, .{
        .case = .c01,
        .distribution = distribution,
        .worker_stats = worker_stats,
        .imbalance = imbalance,
        .total_chunks = world.chunkCount(),
        .total_entities = total_entities,
        .worker_count = sched.workerCount(),
        .cpu_count = cpu_count,
        .total_ram_bytes = ram_bytes,
    });

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const median_ms: f64 = @as(f64, @floatFromInt(distribution.median)) / 1_000_000.0;
    const p99_ms: f64 = @as(f64, @floatFromInt(distribution.p99)) / 1_000_000.0;
    const verdict_median = distribution.median <= C01PrimaryGateNs;
    const verdict_p99 = distribution.p99 <= C01P99GateNs;
    const verdict_imb = imbalance <= ImbalanceGate;
    const verdict_all = verdict_median and verdict_p99 and verdict_imb;
    try stdout_w.interface.print(
        "C0.1 bench median = {d:.2} ms, p99 = {d:.2} ms, imbalance = {d:.2}% — {s}\n",
        .{ median_ms, p99_ms, imbalance * 100.0, if (verdict_all) "GO" else "NO-GO" },
    );
    try stdout_w.interface.flush();
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
