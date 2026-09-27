//! C0.2's two time metrics (`engine-phase-0-criteria.md`), both kept by C1.6:
//! the 500+ line reference file parsed in < 50 ms, and an interpreter hot
//! reload in < 500 ms from the edited source to the first tick running it.
//!
//! A reload is re-parse, type-check, `Interpreter.compile` on the live world,
//! then one tick; the source is already in memory, so reading the saved file is
//! outside it. Two reloads are measured: a rule-body edit of a one-rule program,
//! alternating between two bodies, and the reference file recompiled unchanged.
//! The verdict is on the maximum, the criterion bounding every parse and every
//! reload.
//!
//! `--smoke` runs each row once and writes nothing. `--protocol` records that
//! the run followed the cold-isolated protocol. Writes
//! `bench/reports/etch_reference_<date>.md`.

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");
const report = @import("report_header.zig");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = weld_etch.Interpreter;
const Diagnostic = weld_etch.Diagnostic;

const reference_src = @embedFile("reference_500_lines");

const counter_bodies = [2][]const u8{
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
    ,
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 5
    \\}
};

const parse_gate_ns: u64 = 50 * std.time.ns_per_ms;
const reload_gate_ns: u64 = 500 * std.time.ns_per_ms;

const Row = struct {
    name: []const u8,
    gate_ns: u64,
    dist: report.Distribution,
    samples: usize,
};

fn lineCount(s: []const u8) usize {
    return std.mem.count(u8, s, "\n") + 1;
}

fn checkClean(gpa: std.mem.Allocator, arena: *weld_etch.Ast) !void {
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, arena, &diags);
    if (diags.items.len != 0) return error.UnexpectedTypeDiagnostic;
}

fn benchParse(gpa: std.mem.Allocator, io: std.Io, warmup: usize, samples: []u64) !void {
    var i: usize = 0;
    while (i < warmup + samples.len) : (i += 1) {
        const t0 = std.Io.Clock.now(.awake, io);
        var pr = try weld_etch.parseSource(gpa, reference_src);
        const t1 = std.Io.Clock.now(.awake, io);
        defer pr.deinit(gpa);
        if (pr.diagnostics.len != 0) return error.UnexpectedParseDiagnostic;
        if (i >= warmup) samples[i - warmup] = report.elapsedNs(t0, t1);
    }
}

/// A program compiled on a world, with the parse its interpreter was built from.
/// The interpreter binds where it first ticks, so a session is filled in place
/// and never moved.
const Session = struct {
    pr: weld_etch.parser.ParseResult,
    interp: Interpreter,

    fn load(self: *Session, gpa: std.mem.Allocator, world: *World, source: []const u8) !void {
        self.pr = try weld_etch.parseSource(gpa, source);
        errdefer self.pr.deinit(gpa);
        if (self.pr.diagnostics.len != 0) return error.UnexpectedParseDiagnostic;
        try checkClean(gpa, &self.pr.ast);
        self.interp = try Interpreter.compile(gpa, &self.pr.ast, world);
        errdefer self.interp.deinit();
        _ = try self.interp.runFor(world, 1);
    }

    fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.interp.deinit();
        self.pr.deinit(gpa);
    }
};

/// Reloads `sources[i % sources.len]` onto a world first running `sources[0]`
/// with one entity carrying `entity_component`.
fn benchReload(
    gpa: std.mem.Allocator,
    io: std.Io,
    sources: []const []const u8,
    entity_component: []const u8,
    warmup: usize,
    samples: []u64,
) !void {
    var world = World.init();
    defer world.deinit(gpa);
    var sessions: [2]Session = undefined;
    var live = [2]bool{ false, false };
    defer for (&sessions, live) |*session, l| if (l) session.deinit(gpa);

    try sessions[0].load(gpa, &world, sources[0]);
    live[0] = true;
    const cid = world.registry.idOf(entity_component) orelse return error.MissingComponent;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{cid});

    var i: usize = 0;
    while (i < warmup + samples.len) : (i += 1) {
        const slot = (i + 1) % 2;
        if (live[slot]) sessions[slot].deinit(gpa);
        live[slot] = false;
        const t0 = std.Io.Clock.now(.awake, io);
        try sessions[slot].load(gpa, &world, sources[(i + 1) % sources.len]);
        const t1 = std.Io.Clock.now(.awake, io);
        live[slot] = true;
        if (i >= warmup) samples[i - warmup] = report.elapsedNs(t0, t1);
    }
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, rows: []const Row, protocol: bool) ![]const u8 {
    var path_buf: [128]u8 = undefined;
    const path = try report.datedPath(&path_buf, io, "etch_reference");
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try report.write(gpa, io, w, "Etch reference file and hot reload", protocol);
    try w.print("Reference file: `tests/etch/reference_500_lines.etch`, {d} lines.\n\n", .{lineCount(reference_src)});
    try w.writeAll("| Row | Samples | Median | p99 | Max | Gate | Verdict (max) |\n|---|---|---|---|---|---|---|\n");
    for (rows) |r| {
        try w.print("| {s} | {d} | {d:.3} ms | {d:.3} ms | {d:.3} ms | < {d} ms | {s} |\n", .{
            r.name,                r.samples,                      report.ms(r.dist.median),                      report.ms(r.dist.p99),
            report.ms(r.dist.max), r.gate_ns / std.time.ns_per_ms, if (r.dist.max < r.gate_ns) "GO" else "NO-GO",
        });
    }
    try w.flush();
    return try gpa.dupe(u8, path);
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

    const parse_n: usize = if (smoke) 1 else 200;
    const counter_n: usize = if (smoke) 1 else 200;
    const reference_n: usize = if (smoke) 1 else 50;
    const warmup: usize = if (smoke) 0 else 10;

    const parse_samples = try gpa.alloc(u64, parse_n);
    defer gpa.free(parse_samples);
    const counter_samples = try gpa.alloc(u64, counter_n);
    defer gpa.free(counter_samples);
    const reference_samples = try gpa.alloc(u64, reference_n);
    defer gpa.free(reference_samples);

    try benchParse(gpa, io, warmup, parse_samples);
    try benchReload(gpa, io, &counter_bodies, "Counter", warmup, counter_samples);
    try benchReload(gpa, io, &.{reference_src}, "RefProbe", warmup, reference_samples);

    const rows = [_]Row{
        .{ .name = "parse, reference file", .gate_ns = parse_gate_ns, .dist = .of(parse_samples), .samples = parse_n },
        .{ .name = "reload, rule-body edit", .gate_ns = reload_gate_ns, .dist = .of(counter_samples), .samples = counter_n },
        .{ .name = "reload, reference file", .gate_ns = reload_gate_ns, .dist = .of(reference_samples), .samples = reference_n },
    };
    for (rows) |r| {
        std.debug.print("{s}: median {d:.3} ms, p99 {d:.3} ms, max {d:.3} ms (gate < {d} ms)\n", .{
            r.name, report.ms(r.dist.median), report.ms(r.dist.p99), report.ms(r.dist.max), r.gate_ns / std.time.ns_per_ms,
        });
    }
    if (smoke) return;
    const path = try writeReport(gpa, io, &rows, protocol);
    defer gpa.free(path);
    std.debug.print("wrote {s}\n", .{path});
}
