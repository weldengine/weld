//! S4 Etch tree-walking interpreter benchmark.
//!
//! Drives the fixed 5-rule program at `bench/fixtures/demo_5_rules.etch`
//! over two configurations:
//!   - 1 000 entities × 1 000 ticks (`ReleaseSafe`). Gate: median < 10 ms / tick.
//!   - 10 000 entities × 100 ticks scaling sweep. Gate: median < 100 ms / tick.
//!
//! Outputs a Markdown report to `bench/results/s4-etch-interp-<TS>.md`
//! with: hostname, CPU model, OS, Zig version, build mode, per-config
//! median / p99 / max per tick, per-rule breakdown (rules evaluated,
//! rules matched, mutation count from the interpreter's RuntimeReport),
//! and an explicit GO / NO-GO verdict line.
//!
//! Pass `--smoke` for a CI sanity short-circuit (single tick, no report).
//! The full bench is not run in CI — the verdict is captured on the
//! physical reference machine (cf. S2 / S3 convention).

const std = @import("std");
const builtin = @import("builtin");
const etch = @import("weld_etch");
const weld_core = @import("weld_core");
const fixture_facade = @import("fixture_facade");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = etch.Interpreter;
const RuntimeReport = etch.RuntimeReport;

const WarmupTicks: u32 = 50;
const MainEntities: u32 = 1_000;
const MainTicks: u32 = 1_000;
const ScalingEntities: u32 = 10_000;
const ScalingTicks: u32 = 100;

const MainMedianGateNs: u64 = 10 * std.time.ns_per_ms;
const MainMedianTargetNs: u64 = 5 * std.time.ns_per_ms;
const ScalingMedianGateNs: u64 = 100 * std.time.ns_per_ms;
const ScalingMedianTargetNs: u64 = 50 * std.time.ns_per_ms;

const Distribution = struct {
    min: u64 = 0,
    median: u64 = 0,
    p99: u64 = 0,
    max: u64 = 0,
};

const Sweep = struct {
    label: []const u8,
    entities: u32,
    ticks: u32,
    /// Gate (must beat) and target (nice-to-have) in nanoseconds.
    median_gate_ns: u64,
    median_target_ns: u64,
    dist: Distribution,
    report: RuntimeReport,
};

fn nowTs(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.now(.awake, io);
}

fn deltaNs(a: std.Io.Timestamp, b: std.Io.Timestamp) u64 {
    const dur = a.durationTo(b).nanoseconds;
    return @intCast(@max(@as(i96, 0), dur));
}

fn distribution(samples: []u64) Distribution {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .min = samples[0],
        .median = samples[samples.len / 2],
        .p99 = samples[(samples.len * 99) / 100],
        .max = samples[samples.len - 1],
    };
}

fn runSweep(
    gpa: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    entity_count: u32,
    ticks: u32,
    median_gate_ns: u64,
    median_target_ns: u64,
    smoke: bool,
) !Sweep {
    var world = World.init();
    defer world.deinit(gpa);

    // Parse + type-check + compile once.
    var pr = try etch.parseSource(gpa, fixture_facade.demo_5_rules_etch);
    defer pr.deinit(gpa);
    if (pr.diagnostics.len > 0) {
        std.debug.print("fixture parse failed: {s}\n", .{pr.diagnostics[0].primary_message});
        return error.FixtureParseFailed;
    }
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try etch.typeCheck(gpa, &pr.ast, &diags);
    if (diags.items.len != 0) {
        for (diags.items) |d| std.debug.print("type-check diag {s}: {s}\n", .{ d.code.code(), d.primary_message });
        return error.FixtureTypeCheckFailed;
    }
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    // Spawn N entities with every component the fixture declares.
    const cid_position = world.registry.idOf("Position").?;
    const cid_velocity = world.registry.idOf("Velocity").?;
    const cid_health = world.registry.idOf("Health").?;
    const cid_score = world.registry.idOf("Score").?;
    const cid_active = world.registry.idOf("Active").?;
    var i: u32 = 0;
    while (i < entity_count) : (i += 1) {
        _ = try world.spawnDynamic(gpa, &[_]ComponentId{
            cid_position,
            cid_velocity,
            cid_health,
            cid_score,
            cid_active,
        });
    }

    // Warm up.
    var report: RuntimeReport = .{};
    var w: u32 = 0;
    while (w < WarmupTicks) : (w += 1) {
        try interp.stepOnce(&world, &report);
        world.tickBoundary();
    }

    if (smoke) {
        return .{
            .label = label,
            .entities = entity_count,
            .ticks = 1,
            .median_gate_ns = median_gate_ns,
            .median_target_ns = median_target_ns,
            .dist = .{},
            .report = report,
        };
    }

    // Measured loop — one sample per tick.
    var samples = try gpa.alloc(u64, ticks);
    defer gpa.free(samples);
    report = .{};
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        const t0 = nowTs(io);
        try interp.stepOnce(&world, &report);
        world.tickBoundary();
        samples[t] = deltaNs(t0, nowTs(io));
    }

    return .{
        .label = label,
        .entities = entity_count,
        .ticks = ticks,
        .median_gate_ns = median_gate_ns,
        .median_target_ns = median_target_ns,
        .dist = distribution(samples),
        .report = report,
    };
}

fn fmtMs(ns: u64, buf: []u8) ![]u8 {
    const ms = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    return try std.fmt.bufPrint(buf, "{d:.3} ms", .{ms});
}

const Stamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

fn wallClockStamp(io: std.Io) Stamp {
    const wall = std.Io.Clock.now(.real, io);
    const secs: u64 = @intCast(@max(@as(i96, 0), wall.toSeconds()));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u8, month_day.day_index) + 1,
        .hour = day_secs.getHoursIntoDay(),
        .minute = day_secs.getMinutesIntoHour(),
    };
}

const has_posix_hostname: bool = switch (builtin.os.tag) {
    .windows => false,
    else => true,
};

const hostname_buf_len: usize = if (has_posix_hostname) std.posix.HOST_NAME_MAX else 1;

fn hostnameOrUnavailable(buf: *[hostname_buf_len]u8) []const u8 {
    if (comptime has_posix_hostname) {
        return std.posix.gethostname(buf) catch "<unavailable>";
    } else {
        return "<unavailable>";
    }
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, sweeps: []const Sweep) !void {
    _ = gpa;
    const stamp = wallClockStamp(io);

    var filename_buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "bench/results/s4-etch-interp-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}.md", .{
        stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute,
    });

    var dir = std.Io.Dir.cwd();
    var file = try dir.createFile(io, filename, .{});
    defer file.close(io);

    var report_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &report_buf);
    const writer = &fw.interface;

    var host_buf: [hostname_buf_len]u8 = undefined;
    const hostname = hostnameOrUnavailable(&host_buf);

    try writer.print("# S4 Etch interpreter bench — {s}\n\n", .{filename[14..]});
    try writer.print("Hostname: {s}\n", .{hostname});
    try writer.print("CPU model: {s}\n", .{builtin.cpu.model.name});
    try writer.print("Target: {s}-{s}\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    try writer.print("Zig {d}.{d}.{d}\n", .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch });
    try writer.print("Build mode: {s}\n", .{@tagName(builtin.mode)});
    try writer.print("Warmup ticks per sweep: {d}\n\n", .{WarmupTicks});

    try writer.print("## Per-sweep timings\n\n", .{});
    try writer.print("| Sweep | Entities | Ticks | Median | p99 | Max | Min | Verdict |\n", .{});
    try writer.print("|---|---|---|---|---|---|---|---|\n", .{});
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    var b4: [16]u8 = undefined;
    for (sweeps) |s| {
        const verdict = if (s.dist.median <= s.median_gate_ns) "GO" else "NO-GO";
        try writer.print(
            "| {s} | {d} | {d} | {s} | {s} | {s} | {s} | **{s}** |\n",
            .{
                s.label,
                s.entities,
                s.ticks,
                try fmtMs(s.dist.median, &b1),
                try fmtMs(s.dist.p99, &b2),
                try fmtMs(s.dist.max, &b3),
                try fmtMs(s.dist.min, &b4),
                verdict,
            },
        );
    }

    try writer.print("\n## Runtime reports (steady state, post-warmup)\n\n", .{});
    try writer.print("| Sweep | Entities iterated | Rules evaluated | Rules matched | Runtime errors |\n", .{});
    try writer.print("|---|---|---|---|---|\n", .{});
    for (sweeps) |s| {
        try writer.print("| {s} | {d} | {d} | {d} | {d} |\n", .{
            s.label,
            s.report.entities_iterated,
            s.report.rules_evaluated,
            s.report.rules_matched,
            s.report.runtime_errors,
        });
    }

    // Final verdict.
    var all_go = true;
    for (sweeps) |s| if (s.dist.median > s.median_gate_ns) {
        all_go = false;
    };
    const final = if (all_go) "GO" else "NO-GO";
    try writer.print("\n## Final verdict — **{s}**\n\n", .{final});
    try writer.print(
        "Gates: 1 000 entities median < 10 ms / tick, 10 000 entities median < 100 ms / tick.\n",
        .{},
    );
    try writer.print(
        "Targets: 1 000 entities median < 5 ms / tick, 10 000 entities median < 50 ms / tick.\n",
        .{},
    );

    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena.allocator());

    var smoke = false;
    for (args[1..]) |a| if (std.mem.eql(u8, a, "--smoke")) {
        smoke = true;
    };

    var sweeps: [2]Sweep = undefined;
    sweeps[0] = try runSweep(
        gpa,
        io,
        "1 000 × 5 × 1 000",
        MainEntities,
        MainTicks,
        MainMedianGateNs,
        MainMedianTargetNs,
        smoke,
    );
    sweeps[1] = try runSweep(
        gpa,
        io,
        "10 000 × 5 × 100",
        ScalingEntities,
        ScalingTicks,
        ScalingMedianGateNs,
        ScalingMedianTargetNs,
        smoke,
    );

    if (smoke) return;
    try writeReport(gpa, io, &sweeps);
}
