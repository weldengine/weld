//! S3 Etch parser benchmark.
//!
//! Iterates the valid corpus from `tests/etch/corpus/valid/` and measures
//! lexer-only, parser-only, type-checker-only, and total time per file at
//! N=1000 iterations. Computes median / p99 / max per file and per LOC
//! bucket (small <50, medium 50-150, large 150-300).
//!
//! Output: a Markdown report under `bench/results/s3-etch-parse-<TS>.md`
//! including machine info, Zig version, build mode, per-bucket table,
//! and an explicit verdict line on the `< 5 ms median per file` target.
//!
//! Pass `--smoke` for a CI sanity short-circuit (single iteration, no
//! report). The full bench is not run in CI — the verdict is captured on
//! the physical reference machine (cf. S2 convention,
//! `engine-development-workflow.md` §17 CI obligations).

const std = @import("std");
const builtin = @import("builtin");
const etch = @import("weld_etch");
const corpus_mod = @import("corpus_facade");

const Iterations: u32 = 1000;
const WarmupIterations: u32 = 50;

const MedianGateNs: u64 = 5_000_000; // 5.0 ms
const P99GateNs: u64 = 15_000_000; // 15.0 ms
const MaxGateNs: u64 = 25_000_000; // 25.0 ms

const corpus = corpus_mod.valid;

const Bucket = enum { small, medium, large };

const Distribution = struct {
    min: u64 = 0,
    median: u64 = 0,
    p99: u64 = 0,
    max: u64 = 0,
};

const FileStats = struct {
    name: []const u8,
    loc: u32,
    bucket: Bucket,
    lexer: Distribution,
    parser: Distribution,
    type_check: Distribution,
    total: Distribution,
};

fn countLines(source: []const u8) u32 {
    var n: u32 = 1;
    for (source) |b| if (b == '\n') {
        n += 1;
    };
    return n;
}

fn classify(loc: u32) Bucket {
    if (loc < 50) return .small;
    if (loc < 150) return .medium;
    return .large;
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

fn benchOne(gpa: std.mem.Allocator, io: std.Io, file: corpus_mod.Entry, smoke: bool) !FileStats {
    const iters: usize = if (smoke) 1 else Iterations;

    var lexer_samples = try gpa.alloc(u64, iters);
    defer gpa.free(lexer_samples);
    var parser_samples = try gpa.alloc(u64, iters);
    defer gpa.free(parser_samples);
    var type_samples = try gpa.alloc(u64, iters);
    defer gpa.free(type_samples);
    var total_samples = try gpa.alloc(u64, iters);
    defer gpa.free(total_samples);

    if (!smoke) {
        var w: u32 = 0;
        while (w < WarmupIterations) : (w += 1) {
            try runOnce(gpa, io, file.source, null, null, null, null);
        }
    }

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        try runOnce(gpa, io, file.source, &lexer_samples[i], &parser_samples[i], &type_samples[i], &total_samples[i]);
    }

    return .{
        .name = file.name,
        .loc = countLines(file.source),
        .bucket = classify(countLines(file.source)),
        .lexer = distribution(lexer_samples),
        .parser = distribution(parser_samples),
        .type_check = distribution(type_samples),
        .total = distribution(total_samples),
    };
}

fn nowNs(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.now(.awake, io);
}

fn deltaNs(a: std.Io.Timestamp, b: std.Io.Timestamp) u64 {
    const dur = a.durationTo(b).nanoseconds;
    return @intCast(@max(@as(i96, 0), dur));
}

fn runOnce(gpa: std.mem.Allocator, io: std.Io, source: []const u8, lexer_ns: ?*u64, parser_ns: ?*u64, type_ns: ?*u64, total_ns: ?*u64) !void {
    const t_total_start = nowNs(io);

    // Lexer-only pass: tokenize through to EOF.
    var lex = etch.Lexer.init(source);
    defer lex.deinit(gpa);
    const t_lex_start = nowNs(io);
    while (true) {
        const t = try lex.next(gpa);
        if (t.kind == .eof) break;
    }
    const lex_ns = deltaNs(t_lex_start, nowNs(io));

    // Parser pass (independent — parse() drives its own lexer).
    const t_parse_start = nowNs(io);
    var pr = try etch.parseSource(gpa, source);
    defer pr.ast.deinit(gpa);
    defer if (pr.diagnostic) |*d| d.deinit(gpa);
    const parse_ns = deltaNs(t_parse_start, nowNs(io));
    if (pr.diagnostic) |_| return error.UnexpectedParseDiagnostic;

    // Type-check pass.
    const t_type_start = nowNs(io);
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try etch.typeCheck(gpa, &pr.ast, &diags);
    const t_ns_val = deltaNs(t_type_start, nowNs(io));
    if (diags.items.len != 0) return error.UnexpectedTypeDiagnostic;

    if (lexer_ns) |p| p.* = lex_ns;
    if (parser_ns) |p| p.* = parse_ns;
    if (type_ns) |p| p.* = t_ns_val;
    if (total_ns) |p| p.* = deltaNs(t_total_start, nowNs(io));
}

fn fmtMs(ns: u64, buf: []u8) ![]u8 {
    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
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

/// Resolve the host name through whichever portable API the target OS
/// exposes. `std.posix.gethostname` only compiles on POSIX
/// (`std.posix.HOST_NAME_MAX` is `void` on Windows). On platforms without
/// a stable Zig API we fall back to `"<unavailable>"` rather than pull in
/// a per-OS shim — the brief explicitly allowed this fallback.
///
/// Gating is on `builtin.os.tag` (not `@hasDecl(std.posix, "HOST_NAME_MAX")`)
/// because the latter still returns `true` on Windows where the constant
/// is declared as a `void` placeholder; using its value still trips a
/// compile error.
const has_posix_hostname: bool = switch (builtin.os.tag) {
    .windows => false,
    else => true,
};

const hostname_buf_len: usize = if (has_posix_hostname)
    std.posix.HOST_NAME_MAX
else
    1; // unused on non-POSIX; the value just has to compile

fn hostnameOrUnavailable(buf: *[hostname_buf_len]u8) []const u8 {
    if (comptime has_posix_hostname) {
        return std.posix.gethostname(buf) catch "<unavailable>";
    } else {
        return "<unavailable>";
    }
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, stats: []const FileStats) !void {
    const stamp = wallClockStamp(io);

    var buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "bench/results/s3-etch-parse-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}.md", .{
        stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute,
    });

    var dir = std.Io.Dir.cwd();
    var file = try dir.createFile(io, filename, .{});
    defer file.close(io);

    var report_buf: [4096]u8 = undefined;
    var w = file.writer(io, &report_buf);
    const writer = &w.interface;

    var host_buf: [hostname_buf_len]u8 = undefined;
    const hostname = hostnameOrUnavailable(&host_buf);

    try writer.print("# S3 Etch parser bench — {s}\n\n", .{filename[14..]});
    try writer.print("Hostname: {s}\n", .{hostname});
    try writer.print("CPU model: {s}\n", .{builtin.cpu.model.name});
    try writer.print("Target: {s}-{s}\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    try writer.print("Zig {d}.{d}.{d}\n", .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch });
    try writer.print("Build mode: {s}\n", .{@tagName(builtin.mode)});
    try writer.print("Iterations per file: {d} (warmup {d})\n\n", .{ Iterations, WarmupIterations });

    try writer.print("## Per-file timings (total = lexer + parser + type-checker)\n\n", .{});
    try writer.print("| File | LOC | Bucket | Median | p99 | Max | Lex | Parse | Check |\n", .{});
    try writer.print("|---|---|---|---|---|---|---|---|---|\n", .{});
    var time_buf: [16]u8 = undefined;
    for (stats) |s| {
        const median_str = try fmtMs(s.total.median, &time_buf);
        try writer.print("| {s} | {d} | {s} | {s} |", .{ s.name, s.loc, @tagName(s.bucket), median_str });
        var b2: [16]u8 = undefined;
        try writer.print(" {s} |", .{try fmtMs(s.total.p99, &b2)});
        try writer.print(" {s} |", .{try fmtMs(s.total.max, &b2)});
        try writer.print(" {s} |", .{try fmtMs(s.lexer.median, &b2)});
        try writer.print(" {s} |", .{try fmtMs(s.parser.median, &b2)});
        try writer.print(" {s} |\n", .{try fmtMs(s.type_check.median, &b2)});
    }

    // Per-bucket aggregation.
    try writer.print("\n## Per-bucket aggregation\n\n", .{});
    try writer.print("| Bucket | Files | Worst median | Worst p99 | Worst max |\n", .{});
    try writer.print("|---|---|---|---|---|\n", .{});
    inline for (.{ Bucket.small, Bucket.medium, Bucket.large }) |b| {
        var count: u32 = 0;
        var worst_median: u64 = 0;
        var worst_p99: u64 = 0;
        var worst_max: u64 = 0;
        for (stats) |s| {
            if (s.bucket != b) continue;
            count += 1;
            if (s.total.median > worst_median) worst_median = s.total.median;
            if (s.total.p99 > worst_p99) worst_p99 = s.total.p99;
            if (s.total.max > worst_max) worst_max = s.total.max;
        }
        if (count > 0) {
            var bm: [16]u8 = undefined;
            var bp: [16]u8 = undefined;
            var bx: [16]u8 = undefined;
            try writer.print("| {s} | {d} | {s} | {s} | {s} |\n", .{
                @tagName(b),                  count,
                try fmtMs(worst_median, &bm), try fmtMs(worst_p99, &bp),
                try fmtMs(worst_max, &bx),
            });
        }
    }

    // Verdict.
    var worst_median: u64 = 0;
    var worst_p99: u64 = 0;
    var worst_max: u64 = 0;
    for (stats) |s| {
        if (s.total.median > worst_median) worst_median = s.total.median;
        if (s.total.p99 > worst_p99) worst_p99 = s.total.p99;
        if (s.total.max > worst_max) worst_max = s.total.max;
    }
    const median_go = worst_median < MedianGateNs;
    const p99_go = worst_p99 < P99GateNs;
    const max_go = worst_max < MaxGateNs;
    const verdict = if (median_go and p99_go and max_go) "GO" else "NO-GO";
    var vb: [16]u8 = undefined;
    try writer.print("\n## Verdict — **{s}**\n\n", .{verdict});
    try writer.print("Target: < 5 ms median, < 15 ms p99, < 25 ms max per file.\n\n", .{});
    try writer.print("- Worst median across all files: {s}{s}\n", .{ try fmtMs(worst_median, &vb), if (median_go) " ✓" else " ✗" });
    try writer.print("- Worst p99: {s}{s}\n", .{ try fmtMs(worst_p99, &vb), if (p99_go) " ✓" else " ✗" });
    try writer.print("- Worst max: {s}{s}\n", .{ try fmtMs(worst_max, &vb), if (max_go) " ✓" else " ✗" });

    try writer.flush();
    _ = gpa;
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

    var stats = try gpa.alloc(FileStats, corpus.len);
    defer gpa.free(stats);

    for (corpus, 0..) |file, i| {
        stats[i] = try benchOne(gpa, io, file, smoke);
    }

    if (smoke) return;
    try writeReport(gpa, io, stats);
}
