//! Bench: render instancing — Phase 0 / M0.4 § Scope — Complément Post-Review.
//!
//! Measures the CPU-side batcher throughput on the 100k entities / 100
//! distinct (mesh, material) target from the brief Benchmarks targets.
//! Writes a Markdown report to `bench/out/render_instancing_<os>.md`.
//!
//! GPU-side metrics (FPS sustained 60s, GPU frame time p99 via Vulkan
//! timestamp queries, GPU memory) require a real Vulkan device on the
//! reference machine (Fedora 44 + GTX 1660 Ti). They are exercised by
//! the runtime-smoke-test CI step and the manual GPU validation §4.5.1
//! — they are not in scope of this CPU-only bench harness.
//!
//! The batcher target is the architectural gate: without bucketing,
//! 100k entities at 60 FPS is impossible on any GPU because the driver
//! overhead per drawcall plateaus around 5–15 k drawcalls/frame. The
//! bench confirms the bucketing collapses the workload to ≤ 100
//! drawcalls/frame and measures the CPU latency of that collapse.

const std = @import("std");
const builtin = @import("builtin");
const weld_render = @import("weld_render");
const weld_core = @import("weld_core");
const batcher_mod = weld_render.instancing.batcher;
const time_mod = weld_core.platform.time;

const log = std.log.scoped(.bench_render_instancing);

const N_ENTITIES: u32 = 100_000;
const N_MESHES: u32 = 10;
const N_MATERIALS: u32 = 10;
const N_FRAMES: u32 = 60;
const SEED: u64 = 0xC0FFEE;
const REPORT_DIR: []const u8 = "bench/out";

const Sample = struct {
    nanos: u64,
    buckets: u32,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    log.info("config: {d} entities, {d}x{d} buckets, {d} frames, seed=0x{x}", .{
        N_ENTITIES, N_MESHES, N_MATERIALS, N_FRAMES, SEED,
    });

    var prng = std.Random.DefaultPrng.init(SEED);
    const rand = prng.random();

    const entities = try allocator.alloc(batcher_mod.Entity, N_ENTITIES);
    defer allocator.free(entities);
    for (entities) |*e| {
        e.* = .{
            .mesh = rand.intRangeAtMost(u32, 0, N_MESHES - 1),
            .material = rand.intRangeAtMost(u32, 0, N_MATERIALS - 1),
            .transform = .{ .position = .{
                rand.float(f32) * 100,
                rand.float(f32) * 100,
                rand.float(f32) * 100,
            } },
        };
    }

    var batcher = batcher_mod.Batcher.init(allocator);
    defer batcher.deinit();

    var samples: [N_FRAMES]Sample = undefined;
    for (samples[0..]) |*sample| {
        batcher.reset();
        const start = time_mod.nowNanos();
        for (entities) |e| try batcher.submit(e);
        try batcher.finalize(.{ 50, 50, 50 });
        const end = time_mod.nowNanos();
        sample.* = .{
            .nanos = end - start,
            .buckets = batcher.stats.buckets,
        };
    }

    try writeReport(allocator, io, samples[0..]);
}

const Stats = struct {
    min_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    buckets_max: u32,
};

fn computeStats(allocator: std.mem.Allocator, samples: []const Sample) !Stats {
    const sorted = try allocator.alloc(u64, samples.len);
    defer allocator.free(sorted);
    for (samples, 0..) |s, i| sorted[i] = s.nanos;
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));

    var sum: u128 = 0;
    for (sorted) |n| sum += n;
    const mean: u64 = @intCast(sum / sorted.len);

    var buckets_max: u32 = 0;
    for (samples) |s| buckets_max = @max(buckets_max, s.buckets);

    const p99_idx = @min((sorted.len * 99) / 100, sorted.len - 1);

    return .{
        .min_ns = sorted[0],
        .mean_ns = mean,
        .p50_ns = sorted[sorted.len / 2],
        .p99_ns = sorted[p99_idx],
        .max_ns = sorted[sorted.len - 1],
        .buckets_max = buckets_max,
    };
}

fn writeReport(allocator: std.mem.Allocator, io: std.Io, samples: []const Sample) !void {
    const stats = try computeStats(allocator, samples);

    std.Io.Dir.cwd().createDirPath(io, REPORT_DIR) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const platform_tag = @tagName(builtin.os.tag);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/render_instancing_{s}.md", .{ REPORT_DIR, platform_tag });

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    const w = &writer.interface;

    try w.print("# Bench: render instancing — {s}\n\n", .{platform_tag});
    try w.print(
        "Config: {d} entities, {d} meshes × {d} materials, {d} frames, seed=0x{x}.\n\n",
        .{ N_ENTITIES, N_MESHES, N_MATERIALS, samples.len, SEED },
    );

    try w.print("## CPU batching latency (per frame)\n\n", .{});
    try w.print("| Metric | Value (ms) |\n|---|---|\n", .{});
    try w.print("| min   | {d:.3} |\n", .{nanosToMs(stats.min_ns)});
    try w.print("| mean  | {d:.3} |\n", .{nanosToMs(stats.mean_ns)});
    try w.print("| p50   | {d:.3} |\n", .{nanosToMs(stats.p50_ns)});
    try w.print("| p99   | {d:.3} |\n", .{nanosToMs(stats.p99_ns)});
    try w.print("| max   | {d:.3} |\n\n", .{nanosToMs(stats.max_ns)});

    try w.print("## Drawcalls\n\n", .{});
    try w.print("- Max buckets across frames: **{d}** (gate ≤ 100)\n", .{stats.buckets_max});
    const drawcall_ok = stats.buckets_max <= 100;
    try w.print("- Constraint OK: **{s}**\n\n", .{if (drawcall_ok) "yes" else "**NO**"});

    try w.print("## Limitations\n\n", .{});
    try w.print(
        "This bench measures the CPU-side batcher only. GPU frame time " ++
            "(p50/p99 via Vulkan timestamp queries), FPS sustained 60 s, and GPU " ++
            "memory budget require a hardware Vulkan device on the reference " ++
            "machine (Fedora 44 + GTX 1660 Ti). The runtime-smoke-test CI step " ++
            "and the manual GPU validation §4.5.1 cover the GPU side; brief targets " ++
            "≥ 60 FPS, ≤ 16.6 ms p99, ≤ 200 MiB are checked there.\n",
        .{},
    );
    try w.flush();

    log.info("report written: {s}", .{path});
    log.info("batching p99 = {d:.3} ms, max buckets = {d}, drawcall gate {s}", .{
        nanosToMs(stats.p99_ns),
        stats.buckets_max,
        if (drawcall_ok) "OK" else "FAIL",
    });

    if (!drawcall_ok) return error.DrawcallGateFailed;
}

fn nanosToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
