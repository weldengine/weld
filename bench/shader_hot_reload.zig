//! `--smoke` measures one reload and writes no report; `--protocol` records a
//! cold-isolated run.

const std = @import("std");
const hot_reload = @import("weld_render").shader_pipeline.hot_reload;
const compiler = @import("weld_render").shader_pipeline.compiler;
const report = @import("report_header.zig");

const watch_root = ".weld-cache/bench-shader-watch";
const probe_path = watch_root ++ "/probe.frag.glsl";

const probe_sources = [2][]const u8{
    \\#version 450
    \\layout(location = 0) out vec4 outColor;
    \\void main() { outColor = vec4(0.25, 0.5, 0.5, 1.0); }
    \\
    ,
    \\#version 450
    \\layout(location = 0) out vec4 outColor;
    \\void main() { outColor = vec4(0.75, 0.5, 0.5, 1.0); }
    \\
};

/// C0.3's bound (`engine-phase-0-criteria.md`), timed from the probe's write to
/// its `on_recompile` carrying SPIR-V.
const gate_ns: u64 = 200 * std.time.ns_per_ms;
/// A recompile that has not arrived by then is reported as missing rather than
/// waited for.
const give_up_ns: u64 = 60 * std.time.ns_per_s;

const Probe = struct {
    io: std.Io,
    compiles: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),
    last_ns: std.atomic.Value(u64) = .init(0),
    origin: std.Io.Timestamp,
};

fn onRecompile(ctx: ?*anyopaque, path: []const u8, spv: ?[]const u8, diag: ?[]const u8) void {
    _ = diag;
    const probe: *Probe = @ptrCast(@alignCast(ctx.?));
    if (!std.mem.eql(u8, path, probe_path)) return;
    probe.last_ns.store(report.elapsedNs(probe.origin, std.Io.Clock.now(.awake, probe.io)), .release);
    if (spv == null or spv.?.len == 0) _ = probe.failures.fetchAdd(1, .acq_rel);
    _ = probe.compiles.fetchAdd(1, .acq_rel);
}

/// Written beside the probe and renamed over it, so a scan never reads it half
/// written.
fn writeProbe(io: std.Io, source: []const u8) !void {
    const staged = watch_root ++ "/probe.staged";
    const cwd = std.Io.Dir.cwd();
    {
        var file = try cwd.createFile(io, staged, .{ .truncate = true });
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(source);
        try w.interface.flush();
    }
    try std.Io.Dir.rename(cwd, staged, cwd, probe_path, io);
}

fn awaitCompile(io: std.Io, probe: *Probe, count: u32) !void {
    const start = std.Io.Clock.now(.awake, io);
    while (probe.compiles.load(.acquire) < count) {
        if (report.elapsedNs(start, std.Io.Clock.now(.awake, io)) > give_up_ns) return error.NoRecompile;
        std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    if (probe.failures.load(.acquire) != 0) return error.ProbeFailedToCompile;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var smoke = false;
    for (args[1..]) |a| if (std.mem.eql(u8, a, "--smoke")) {
        smoke = true;
    };
    const protocol = report.protocolFlag(args[1..]);

    if (!compiler.isAvailable(gpa, io)) {
        std.debug.print("glslc is not on PATH: nothing to measure\n", .{});
        return error.GlslcUnavailable;
    }

    const n: usize = if (smoke) 1 else 30;
    const samples = try gpa.alloc(u64, n);
    defer gpa.free(samples);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, watch_root);
    defer cwd.deleteTree(io, watch_root) catch {};
    try writeProbe(io, probe_sources[0]);

    var probe = Probe{ .io = io, .origin = std.Io.Clock.now(.awake, io) };
    var watcher = hot_reload.init(gpa, .{
        .io = io,
        .root = watch_root,
        .on_recompile = onRecompile,
        .callback_ctx = @ptrCast(&probe),
    });
    defer watcher.deinit();
    try watcher.start();
    try awaitCompile(io, &probe, 1);

    for (samples, 0..) |*sample, i| {
        const before = report.elapsedNs(probe.origin, std.Io.Clock.now(.awake, io));
        try writeProbe(io, probe_sources[(i + 1) % 2]);
        try awaitCompile(io, &probe, @intCast(i + 2));
        sample.* = probe.last_ns.load(.acquire) - before;
    }

    const dist = report.Distribution.of(samples);
    std.debug.print("shader reload: median {d:.3} ms, p99 {d:.3} ms, max {d:.3} ms (gate < {d} ms)\n", .{
        report.ms(dist.median), report.ms(dist.p99), report.ms(dist.max), gate_ns / std.time.ns_per_ms,
    });
    if (smoke) return;

    var path_buf: [128]u8 = undefined;
    const path = try report.datedPath(&path_buf, io, "shader_hot_reload");
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try report.write(gpa, io, w, "Shader hot reload", protocol);
    try w.print("Watcher poll interval: {d} ms (default). {d} reloads, one warm-up compile.\n\n", .{
        (hot_reload.Config{ .io = io, .on_recompile = onRecompile }).poll_interval_ms, n,
    });
    try w.writeAll("| Median | p99 | Max | Gate | Verdict (max) |\n|---|---|---|---|---|\n");
    try w.print("| {d:.3} ms | {d:.3} ms | {d:.3} ms | < {d} ms | {s} |\n", .{
        report.ms(dist.median),       report.ms(dist.p99),                       report.ms(dist.max),
        gate_ns / std.time.ns_per_ms, if (dist.max < gate_ns) "GO" else "NO-GO",
    });
    try w.flush();
    std.debug.print("wrote {s}\n", .{path});
}
