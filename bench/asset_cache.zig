//! Bench: asset cooking-cache hit differential — M0.6 / E4.
//!
//! Measures the wall-clock differential between a *cold cook* (cache miss:
//! BLAKE3 over the payload + assemble + write the `.bin`) and a *warm cache
//! hit* (a directory lookup that skips the cook entirely). This is the
//! performance half of the brief's cache criterion; the correctness half
//! (a miss → hit transition that returns byte-identical bytes) is the
//! deterministic gate `tests/assets/cache_diff.zig`.
//!
//! The differential is host- and load-dependent, so it lives here — measured
//! under the opposable protocol on the reference machine — not inside
//! `zig build test`, where a single cache-hit sample spiking on a page
//! fault / AV scan / cold directory would red-fail the gate. The brief's
//! reference figure is ≥ 100 ms cold cook / < 10 ms hit for a real
//! decode-heavy asset; this synthetic 16 MiB RGBA8 cook is hash- and
//! write-bound rather than decode-bound, so the absolute cold time is
//! smaller — the *ratio* (cook ≫ lookup) is the signal.
//!
//! Run: `zig build bench-asset-cache` (add `-- --smoke` for a tiny CI sanity
//! run). Writes `bench/out/asset_cache_<os>.md`.

const std = @import("std");
const builtin = @import("builtin");
const assets = @import("weld_asset_pipeline");

const log = std.log.scoped(.bench_asset_cache);

const REPORT_DIR: []const u8 = "bench/out";
const SCRATCH_DIR: []const u8 = "bench/out/asset_cache_scratch";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var smoke = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--smoke")) smoke = true;
    }

    // Non-smoke: 2048×2048 RGBA8 = 16 MiB, so the cold cook (BLAKE3 over the
    // payload + a 16 MiB write) is clearly expensive vs a dir-lookup hit.
    // Smoke: a tiny asset, just enough to exercise the path under CI.
    const dim: u32 = if (smoke) 64 else 2048;
    const iterations: usize = if (smoke) 3 else 16;

    log.info("config: {d}x{d} RGBA8 ({d} KiB), {d} iterations, smoke={}", .{
        dim, dim, (dim * dim * 4) / 1024, iterations, smoke,
    });

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, SCRATCH_DIR) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    // The scratch cache is bench-private state; remove it on the way out so a
    // re-run always starts from genuine misses (cf. bench/etch_compile.zig).
    defer cwd.deleteTree(io, SCRATCH_DIR) catch {};

    var scratch = try cwd.openDir(io, SCRATCH_DIR, .{});
    defer scratch.close(io);
    const cache = assets.cache.Cache.init(scratch);

    const blob = try gpa.alloc(u8, dim * dim * 4);
    defer gpa.free(blob);
    for (blob, 0..) |*b, i| b.* = @truncate(i *% 2_654_435_761);

    const source_hash = assets.hash.hex128(blob);
    const extracted = [_]assets.format.Field{
        .{ .key = "width", .value = .{ .int = @intCast(dim) } },
        .{ .key = "height", .value = .{ .int = @intCast(dim) } },
        .{ .key = "blob", .value = .{ .string = &source_hash } },
    };
    const doc = assets.AssetDoc{
        .name = "big",
        .type_name = "Texture2D",
        .version = 1,
        .source = "big.png",
        .source_hash = &source_hash,
        .extracted = &extracted,
    };

    const cold_ns = try gpa.alloc(u64, iterations);
    defer gpa.free(cold_ns);
    const hit_ns = try gpa.alloc(u64, iterations);
    defer gpa.free(hit_ns);

    // Each iteration uses a distinct cache key (distinct settings string) so
    // every cold sample starts from a genuine miss in the shared scratch dir.
    var settings_buf: [16]u8 = undefined;
    for (0..iterations) |i| {
        const settings = try std.fmt.bufPrint(&settings_buf, "pc-{d}", .{i});
        const key = assets.cache.computeKey(&source_hash, settings, 0);

        // Cold path — cache miss: look up (absent) → cook → store.
        const t_cold = std.Io.Clock.Timestamp.now(io, .awake);
        std.debug.assert(!cache.contains(io, &key));
        const bin = try assets.cookers.cookTexture(gpa, doc, blob);
        try cache.put(io, &key, bin);
        cold_ns[i] = @intCast(t_cold.untilNow(io).raw.nanoseconds);
        gpa.free(bin);

        // Warm path — cache hit: a directory lookup; the cook is skipped.
        const t_hit = std.Io.Clock.Timestamp.now(io, .awake);
        const hit = cache.contains(io, &key);
        hit_ns[i] = @intCast(t_hit.untilNow(io).raw.nanoseconds);
        std.debug.assert(hit);
    }

    try writeReport(gpa, io, cold_ns, hit_ns, dim, iterations, smoke);
}

const Stats = struct {
    min_ns: u64,
    p50_ns: u64,
    max_ns: u64,
};

fn computeStats(gpa: std.mem.Allocator, samples: []const u64) !Stats {
    const sorted = try gpa.dupe(u64, samples);
    defer gpa.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{
        .min_ns = sorted[0],
        .p50_ns = sorted[sorted.len / 2],
        .max_ns = sorted[sorted.len - 1],
    };
}

fn writeReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    cold_ns: []const u64,
    hit_ns: []const u64,
    dim: u32,
    iterations: usize,
    smoke: bool,
) !void {
    const cold = try computeStats(gpa, cold_ns);
    const hit = try computeStats(gpa, hit_ns);
    const speedup: f64 = if (hit.p50_ns == 0)
        0
    else
        @as(f64, @floatFromInt(cold.p50_ns)) / @as(f64, @floatFromInt(hit.p50_ns));

    std.Io.Dir.cwd().createDirPath(io, REPORT_DIR) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const platform_tag = @tagName(builtin.os.tag);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/asset_cache_{s}.md", .{ REPORT_DIR, platform_tag });

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    const w = &writer.interface;

    try w.print("# Bench: asset cooking-cache hit differential — {s}\n\n", .{platform_tag});
    try w.print(
        "Config: {d}×{d} RGBA8 ({d} KiB payload), {d} iterations{s}.\n\n",
        .{ dim, dim, (dim * dim * 4) / 1024, iterations, if (smoke) " (smoke)" else "" },
    );

    try w.print("## Cold cook (cache miss)\n\n", .{});
    try w.print("| Metric | Value (ms) |\n|---|---|\n", .{});
    try w.print("| min | {d:.3} |\n", .{nanosToMs(cold.min_ns)});
    try w.print("| p50 | {d:.3} |\n", .{nanosToMs(cold.p50_ns)});
    try w.print("| max | {d:.3} |\n\n", .{nanosToMs(cold.max_ns)});

    try w.print("## Warm hit (cache lookup)\n\n", .{});
    try w.print("| Metric | Value (µs) |\n|---|---|\n", .{});
    try w.print("| min | {d:.3} |\n", .{nanosToUs(hit.min_ns)});
    try w.print("| p50 | {d:.3} |\n", .{nanosToUs(hit.p50_ns)});
    try w.print("| max | {d:.3} |\n\n", .{nanosToUs(hit.max_ns)});

    try w.print("## Differential\n\n", .{});
    try w.print("- Cache-hit speedup (cold p50 / hit p50): **{d:.0}×**\n\n", .{speedup});

    try w.print("## Notes\n\n", .{});
    try w.print(
        "This differential is host- and load-dependent and is therefore a " ++
            "bench number, not a `zig build test` gate (the correctness half — " ++
            "a miss → hit transition that returns byte-identical bytes — is the " ++
            "deterministic gate `tests/assets/cache_diff.zig`). Measure under the " ++
            "opposable protocol on the reference machine. The brief reference is " ++
            "≥ 100 ms cold / < 10 ms hit for a real decode-heavy asset; this " ++
            "synthetic RGBA8 cook is hash- and write-bound, so the cold time is " ++
            "smaller — the ratio (cook ≫ lookup) is the signal.\n",
        .{},
    );
    try w.flush();

    log.info("report written: {s}", .{path});
    log.info("cold p50 = {d:.3} ms, hit p50 = {d:.3} µs, speedup = {d:.0}×", .{
        nanosToMs(cold.p50_ns),
        nanosToUs(hit.p50_ns),
        speedup,
    });
}

fn nanosToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn nanosToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e3;
}
