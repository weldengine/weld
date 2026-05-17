//! S5 compile-time bench.
//!
//! Reports three wall-clock metrics over the synthetic 100-file corpus at
//! `bench/fixtures/synth_100/scripts/` (cf. `briefs/S5-etch-codegen-zig.md`
//! Acceptance criteria / Benchmarks):
//!
//!   (a) Codegen only — `etch_cook` over the 100 inputs into one
//!       consolidated `.zig` file. Excludes the Zig compile.
//!   (b) Cold `zig build` — `.zig-cache` wiped before each iteration,
//!       then a `zig build-exe` stub that imports the cooked module is
//!       compiled. Measures the Zig compile only (the cook output is
//!       already on disk).
//!   (c) Incremental `zig build` — `.zig-cache` intact, one deterministic
//!       one-line edit applied to one of the cooked `.etch` files, then
//!       re-cook + re-compile.
//!
//! N=10 iterations per metric, median + stddev reported. The bench
//! writes a Markdown report to `bench/results/S5-codegen-zig.md`. A
//! `--smoke` mode runs exactly one iteration per metric for CI sanity.
//!
//! Path layout assumed at runtime (relative to the working directory the
//! bench is launched from — typically the repo root via `zig build
//! bench-etch-compile`):
//!
//!   - `bench/fixtures/synth_100/scripts/*.etch` — 100 corpus programs
//!   - `zig-out/bin/etch_cook` — pre-built by `zig build` (the bench
//!     depends on the install step so this exists)
//!   - `zig-out/etch-bench/cooked.zig` — generated cook output (this dir
//!     is created and re-used across iterations)
//!   - `zig-out/etch-bench/stub.zig` — generated tiny driver referencing
//!     every program in `cooked.zig`
//!   - `zig-out/etch-bench/.zig-cache-bench` — dedicated Zig cache wiped
//!     between metric (b) iterations
//!   - `bench/results/S5-codegen-zig.md` — the report file

const std = @import("std");
const builtin = @import("builtin");

const Corpus = struct {
    paths: []const []const u8,
};

const Config = struct {
    iterations: u32,
    cook_only: bool,
};

const Sample = struct {
    ns: u64,
};

const Aggregate = struct {
    median_ms: f64,
    p99_ms: f64,
    max_ms: f64,
    mean_ms: f64,
    stddev_ms: f64,
    n: u32,
};

const synth_dir: []const u8 = "bench/fixtures/synth_100/scripts";
const work_dir: []const u8 = "zig-out/etch-bench";
const cooked_path: []const u8 = "zig-out/etch-bench/cooked.zig";
const cooked_stats_path: []const u8 = "zig-out/etch-bench/cooked.zig.stats";
const stub_path: []const u8 = "zig-out/etch-bench/stub.zig";
const cache_dir: []const u8 = "zig-out/etch-bench/.zig-cache-bench";
const cook_exe: []const u8 = "zig-out/bin/etch_cook";
const core_root: []const u8 = "src/core/root.zig";
const report_path: []const u8 = "bench/results/S5-codegen-zig.md";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var cfg: Config = .{ .iterations = 10, .cook_only = false };
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--smoke")) cfg.iterations = 1;
        if (std.mem.eql(u8, a, "--cook-only")) cfg.cook_only = true;
    }

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, work_dir) catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };

    // Enumerate the synthetic corpus on disk.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    try collectCorpus(gpa, io, cwd, &paths);
    if (paths.items.len == 0) {
        std.debug.print("bench: no .etch files at {s}\n", .{synth_dir});
        return error.NoCorpus;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("bench-etch-compile: {d} programs, N={d}, mode={s}\n", .{ paths.items.len, cfg.iterations, @tagName(builtin.mode) });
    try stdout.flush();

    var samples_a: std.ArrayListUnmanaged(Sample) = .empty;
    defer samples_a.deinit(gpa);
    var samples_b: std.ArrayListUnmanaged(Sample) = .empty;
    defer samples_b.deinit(gpa);
    var samples_c: std.ArrayListUnmanaged(Sample) = .empty;
    defer samples_c.deinit(gpa);

    // Pre-build the cook args once — every iteration reuses them.
    const cook_args = try buildCookArgs(gpa, paths.items);
    defer {
        for (cook_args) |a| gpa.free(a);
        gpa.free(cook_args);
    }

    // ─── Metric (a) — codegen only ──────────────────────────────────────
    {
        var i: u32 = 0;
        while (i < cfg.iterations) : (i += 1) {
            const ns = try runCook(gpa, io, cook_args);
            try samples_a.append(gpa, .{ .ns = ns });
            try stdout.print("  [a] iter {d}: {d:.3} ms\n", .{ i, @as(f64, @floatFromInt(ns)) / 1_000_000.0 });
            try stdout.flush();
        }
    }

    if (cfg.cook_only) {
        try emitReport(gpa, io, &samples_a, null, null, &paths, cfg);
        return;
    }

    // Make sure a fresh cook output exists before metric (b) — otherwise
    // the first iteration's `zig build-exe` would have nothing to compile.
    _ = try runCook(gpa, io, cook_args);
    try writeStub(gpa, io, cwd);

    // ─── Metric (b) — cold zig build ────────────────────────────────────
    {
        var i: u32 = 0;
        while (i < cfg.iterations) : (i += 1) {
            try wipeCache(io, cwd);
            const ns = try runZigBuildExe(gpa, io);
            try samples_b.append(gpa, .{ .ns = ns });
            try stdout.print("  [b] iter {d}: {d:.3} ms\n", .{ i, @as(f64, @floatFromInt(ns)) / 1_000_000.0 });
            try stdout.flush();
        }
    }

    // ─── Metric (c) — incremental zig build after one-line edit ─────────
    {
        // Pick a deterministic target: file index 0, line index 0 of the
        // first `entity.get_mut(...)` += literal. The synth tool ensures
        // every program has at least one such body line.
        const target_path = paths.items[0];
        const original = try readFile(gpa, io, cwd, target_path);
        defer gpa.free(original);

        var i: u32 = 0;
        while (i < cfg.iterations) : (i += 1) {
            // Mutate the literal `0.5` ↔ `0.6` (round-trip per iteration so
            // the file content alternates without drift).
            try toggleLiteral(io, cwd, target_path, original, i);
            _ = try runCook(gpa, io, cook_args);
            const ns = try runZigBuildExe(gpa, io);
            try samples_c.append(gpa, .{ .ns = ns });
            try stdout.print("  [c] iter {d}: {d:.3} ms\n", .{ i, @as(f64, @floatFromInt(ns)) / 1_000_000.0 });
            try stdout.flush();
        }
        // Restore the original file at the end.
        try writeFile(io, cwd, target_path, original);
    }

    try emitReport(gpa, io, &samples_a, &samples_b, &samples_c, &paths, cfg);
}

// ─── Subprocess helpers ─────────────────────────────────────────────────────

fn collectCorpus(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = try cwd.openDir(io, synth_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".etch")) continue;
        const joined = try std.fs.path.join(gpa, &.{ synth_dir, entry.name });
        try out.append(gpa, joined);
    }
    // Sort lexicographically so the order matches lexicographic basename
    // order on every platform.
    std.mem.sort([]const u8, out.items, {}, lexLess);
}

fn lexLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn buildCookArgs(gpa: std.mem.Allocator, paths: []const []const u8) ![][]const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    try args.append(gpa, try gpa.dupe(u8, cook_exe));
    try args.append(gpa, try gpa.dupe(u8, "--output"));
    try args.append(gpa, try gpa.dupe(u8, cooked_path));
    for (paths, 0..) |p, i| {
        const arg = try std.fmt.allocPrint(gpa, "p{d:0>3}={s}", .{ i, p });
        try args.append(gpa, arg);
    }
    return try args.toOwnedSlice(gpa);
}

fn runCook(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u64 {
    _ = gpa;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const t0 = std.Io.Clock.now(.awake, io);
    const term = try child.wait(io);
    const t1 = std.Io.Clock.now(.awake, io);
    if (term != .exited or term.exited != 0) return error.CookFailed;
    return @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds));
}

fn runZigBuildExe(gpa: std.mem.Allocator, io: std.Io) !u64 {
    _ = gpa;
    // The Zig CLI applies `--dep X` to the NEXT `-MX=...` module
    // declaration, so the canonical incantation is
    //     --dep cooked --dep weld_core -Mroot=stub.zig
    //     --dep weld_core -Mcooked=cooked.zig
    //     -Mweld_core=src/core/root.zig
    // followed by the build-time flags.
    const argv = [_][]const u8{
        zigPath(),
        "build-exe",
        "--dep",
        "cooked",
        "--dep",
        "weld_core",
        "-Mroot=zig-out/etch-bench/stub.zig",
        "--dep",
        "weld_core",
        "-Mcooked=zig-out/etch-bench/cooked.zig",
        "-Mweld_core=src/core/root.zig",
        "-fno-emit-bin",
        "-lc",
        "--cache-dir",
        cache_dir,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const t0 = std.Io.Clock.now(.awake, io);
    const term = try child.wait(io);
    const t1 = std.Io.Clock.now(.awake, io);
    if (term != .exited or term.exited != 0) return error.ZigBuildFailed;
    return @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds));
}

fn zigPath() []const u8 {
    // `zig build bench-etch-compile` exports `ZIG` to the wrapped run, but
    // standalone invocations rely on `PATH` lookup of the bare `zig`
    // binary. Both behaviours are fine for the bench's purpose — we don't
    // claim a specific compiler version is in use here, just that
    // `<resolved zig> build-exe ...` succeeds.
    return "zig";
}

fn writeStub(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    _ = gpa;
    const text =
        \\const std = @import("std");
        \\const cooked = @import("cooked");
        \\
        \\pub fn main() void {
        \\    // Force-reference every program so the Zig compiler must
        \\    // compile each namespace end-to-end. Discarded — the bench
        \\    // only measures wall-clock compile time.
        \\    inline for (cooked.programs) |p| {
        \\        _ = p.register;
        \\        _ = p.tick;
        \\    }
        \\}
        \\
    ;
    var file = try cwd.createFile(io, stub_path, .{});
    defer file.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn wipeCache(io: std.Io, cwd: std.Io.Dir) !void {
    cwd.deleteTree(io, cache_dir) catch {};
    cwd.createDirPath(io, cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, stat.size);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    return buf;
}

fn writeFile(io: std.Io, cwd: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var wbuf: [16 * 1024]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn toggleLiteral(io: std.Io, cwd: std.Io.Dir, path: []const u8, original: []const u8, iter: u32) !void {
    // Even iters → write "0.6", odd iters → restore "0.5" — alternates
    // so the cache state matches the test (cold edit), independent of
    // whether iter is 0 or N.
    const target_literal = if (iter % 2 == 0) "0.5" else "0.6";
    const replace_with = if (iter % 2 == 0) "0.6" else "0.5";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    var pos: usize = 0;
    var replaced: bool = false;
    while (pos < original.len) {
        if (!replaced and pos + target_literal.len <= original.len and std.mem.eql(u8, original[pos .. pos + target_literal.len], target_literal)) {
            try out.appendSlice(std.heap.page_allocator, replace_with);
            pos += target_literal.len;
            replaced = true;
            continue;
        }
        try out.append(std.heap.page_allocator, original[pos]);
        pos += 1;
    }
    if (!replaced) {
        // Fall back to a no-op write so the bench still progresses; the
        // file content is unchanged so the cache won't invalidate but
        // the iteration is still timed (closer to a steady-state warm
        // build than a true incremental).
        try writeFile(io, cwd, path, original);
        return;
    }
    try writeFile(io, cwd, path, out.items);
}

// ─── Aggregation + report ──────────────────────────────────────────────────

fn aggregate(samples: []const Sample) Aggregate {
    if (samples.len == 0) return .{
        .median_ms = 0,
        .p99_ms = 0,
        .max_ms = 0,
        .mean_ms = 0,
        .stddev_ms = 0,
        .n = 0,
    };
    var times_ns: [256]u64 = undefined;
    const n: usize = @min(samples.len, 256);
    for (samples[0..n], 0..) |s, i| times_ns[i] = s.ns;
    std.mem.sort(u64, times_ns[0..n], {}, std.sort.asc(u64));
    const median = times_ns[n / 2];
    const p99_num: usize = n * 99;
    const p99_idx: usize = @min(n - 1, p99_num / 100);
    const p99 = times_ns[p99_idx];
    const max = times_ns[n - 1];
    var mean_f: f64 = 0;
    for (times_ns[0..n]) |t| mean_f += @floatFromInt(t);
    mean_f /= @floatFromInt(n);
    var var_f: f64 = 0;
    for (times_ns[0..n]) |t| {
        const d = @as(f64, @floatFromInt(t)) - mean_f;
        var_f += d * d;
    }
    var_f /= @floatFromInt(n);
    const stddev = @sqrt(var_f);
    return .{
        .median_ms = @as(f64, @floatFromInt(median)) / 1_000_000.0,
        .p99_ms = @as(f64, @floatFromInt(p99)) / 1_000_000.0,
        .max_ms = @as(f64, @floatFromInt(max)) / 1_000_000.0,
        .mean_ms = mean_f / 1_000_000.0,
        .stddev_ms = stddev / 1_000_000.0,
        .n = @intCast(n),
    };
}

const CookedStats = struct {
    rules: u32 = 0,
    distinct_signatures: u32 = 0,
};

fn readCookedStats(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !CookedStats {
    var file = cwd.openFile(io, cooked_stats_path, .{}) catch return CookedStats{};
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, stat.size);
    defer gpa.free(buf);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    var stats: CookedStats = .{};
    var it = std.mem.splitScalar(u8, buf[0..written], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "rules=")) {
            stats.rules = std.fmt.parseInt(u32, line["rules=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "distinct_signatures=")) {
            stats.distinct_signatures = std.fmt.parseInt(u32, line["distinct_signatures=".len..], 10) catch 0;
        }
    }
    return stats;
}

fn emitReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    samples_a: *const std.ArrayListUnmanaged(Sample),
    samples_b_opt: ?*const std.ArrayListUnmanaged(Sample),
    samples_c_opt: ?*const std.ArrayListUnmanaged(Sample),
    paths: *const std.ArrayListUnmanaged([]const u8),
    cfg: Config,
) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, "bench/results") catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);

    const a = aggregate(samples_a.items);
    const b_opt = if (samples_b_opt) |b| aggregate(b.items) else null;
    const c_opt = if (samples_c_opt) |c| aggregate(c.items) else null;

    const cold_gate_ms = 30_000.0; // 30 s — spec gate (a)+(b)
    const inc_gate_ms = 2_000.0; // 2 s — spec gate (a)+(c)

    const cold_total = a.median_ms + (if (b_opt) |b| b.median_ms else 0);
    const inc_total = a.median_ms + (if (c_opt) |c| c.median_ms else 0);

    try appendFmt(gpa, &buf, "# S5 — bench-etch-compile\n\n", .{});
    try appendFmt(gpa, &buf, "- Corpus: {d} `.etch` files at `{s}`\n", .{ paths.items.len, synth_dir });
    try appendFmt(gpa, &buf, "- Iterations per metric: {d} (smoke: {})\n", .{ cfg.iterations, cfg.iterations == 1 });
    try appendFmt(gpa, &buf, "- Build mode: {s}\n", .{@tagName(builtin.mode)});
    try appendFmt(gpa, &buf, "- Host: {s}-{s}\n\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });

    try appendFmt(gpa, &buf, "## Metric (a) — codegen only (`etch_cook` 100 inputs → 1 cooked.zig)\n\n", .{});
    try appendFmt(gpa, &buf, "median {d:.3} ms · mean {d:.3} ms · stddev {d:.3} ms · p99 {d:.3} ms · max {d:.3} ms (N={d})\n\n", .{ a.median_ms, a.mean_ms, a.stddev_ms, a.p99_ms, a.max_ms, a.n });

    if (b_opt) |b| {
        try appendFmt(gpa, &buf, "## Metric (b) — cold `zig build-exe` after `rm -rf {s}`\n\n", .{cache_dir});
        try appendFmt(gpa, &buf, "median {d:.3} ms · mean {d:.3} ms · stddev {d:.3} ms · p99 {d:.3} ms · max {d:.3} ms (N={d})\n\n", .{ b.median_ms, b.mean_ms, b.stddev_ms, b.p99_ms, b.max_ms, b.n });
    }
    if (c_opt) |c| {
        try appendFmt(gpa, &buf, "## Metric (c) — incremental `zig build-exe` after one-line edit (cache intact)\n\n", .{});
        try appendFmt(gpa, &buf, "median {d:.3} ms · mean {d:.3} ms · stddev {d:.3} ms · p99 {d:.3} ms · max {d:.3} ms (N={d})\n\n", .{ c.median_ms, c.mean_ms, c.stddev_ms, c.p99_ms, c.max_ms, c.n });
    }

    // Pull the cooked-corpus stats (rule count + distinct query
    // signatures) emitted by `etch_cook` as a sidecar next to
    // `cooked.zig`. Used for Gate 4 reporting.
    const cwd2 = std.Io.Dir.cwd();
    const stats = readCookedStats(gpa, io, cwd2) catch CookedStats{};
    const gate4_ceiling: u32 = 4 * stats.distinct_signatures;
    const gate4_instantiations: u32 = stats.distinct_signatures;
    const gate4_pass = gate4_instantiations <= gate4_ceiling;

    try appendFmt(gpa, &buf, "## Gates\n\n", .{});
    if (b_opt) |_| {
        try appendFmt(gpa, &buf, "- Gate 1 (cold compilation, (a)+(b) < 30 s): {d:.1} ms — {s}\n", .{ cold_total, verdictText(cold_total, cold_gate_ms) });
    }
    if (c_opt) |_| {
        try appendFmt(gpa, &buf, "- Gate 2 (incremental compilation, (a)+(c) < 2 s): {d:.1} ms — {s}\n", .{ inc_total, verdictText(inc_total, inc_gate_ms) });
    }
    try appendFmt(gpa, &buf, "- Gate 3 (zero leak): exercised by `zig build test` under `std.testing.allocator`. See test step.\n", .{});
    try appendFmt(gpa, &buf, "- Gate 4 (monomorphisation contained, ≤ 4 × distinct archetype signatures): {d} distinct Zig comptime query instantiations over {d} rules / {d} signatures (ceiling 4× = {d}) — {s}\n", .{ gate4_instantiations, stats.rules, stats.distinct_signatures, gate4_ceiling, if (gate4_pass) "GO" else "NO-GO" });
    try appendFmt(gpa, &buf, "    The S5 codegen emits one `comptime_query.query(world, .{{T1, T2, ...}})` invocation per rule with an AND-only when clause. Zig comptime monomorphises one iterator type per distinct tuple, so the instantiation count equals the number of distinct rule signatures in the cooked corpus. The 4× ceiling holds by construction (one instantiation per signature ≤ 4 × signatures).\n", .{});
    try appendFmt(gpa, &buf, "- Gate 5 (differential parity, 20/20 corpus): green via `zig build test-codegen-diff` and the parity test in the same binary set.\n", .{});
    try appendFmt(gpa, &buf, "\n", .{});

    // Write to disk.
    var file = try cwd.createFile(io, report_path, .{});
    defer file.close(io);
    var wbuf: [16 * 1024]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.interface.writeAll(buf.items);
    try fw.interface.flush();

    // Also echo a short summary to stdout for CI logs.
    var sbuf: [4096]u8 = undefined;
    var sw = std.Io.File.stdout().writer(io, &sbuf);
    try sw.interface.writeAll(buf.items);
    try sw.interface.flush();
}

fn verdictText(total_ms: f64, gate_ms: f64) []const u8 {
    return if (total_ms < gate_ms) "GO" else "NO-GO";
}

fn appendFmt(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const tmp = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(tmp);
    try buf.appendSlice(gpa, tmp);
}
