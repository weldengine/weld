//! S4 demo binary — loads the fixed 5-rule program from
//! `bench/fixtures/demo_5_rules.etch`, spawns 1 000 entities with every
//! component the fixture declares, runs 60 ticks, prints the summary line
//! mandated by `briefs/S4-etch-tree-walking-interpreter.md`
//! Observable behaviour:
//!
//!     Demo S4 OK | mode=ReleaseSafe | entities=1000 | rules=5 | ticks=60 | rules_matched=N | errors=0 | total=Tms

const std = @import("std");
const builtin = @import("builtin");
const etch = @import("weld_etch");
const weld_core = @import("weld_core");
const fixture_facade = @import("fixture_facade");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = etch.Interpreter;
const RuntimeReport = etch.RuntimeReport;

const Entities: u32 = 1_000;
const Ticks: u32 = 60;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var world = World.init();
    defer world.deinit(gpa);

    var pr = try etch.parseSource(gpa, fixture_facade.demo_5_rules_etch);
    defer pr.ast.deinit(gpa);
    if (pr.diagnostic) |*d| {
        var dd = d.*;
        defer dd.deinit(gpa);
        std.debug.print("demo fixture parse failed: {s}\n", .{dd.primary_message});
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

    const cid_position = world.registry.idOf("Position").?;
    const cid_velocity = world.registry.idOf("Velocity").?;
    const cid_health = world.registry.idOf("Health").?;
    const cid_score = world.registry.idOf("Score").?;
    const cid_active = world.registry.idOf("Active").?;
    var i: u32 = 0;
    while (i < Entities) : (i += 1) {
        _ = try world.spawnDynamic(gpa, &[_]ComponentId{
            cid_position,
            cid_velocity,
            cid_health,
            cid_score,
            cid_active,
        });
    }

    const t0 = std.Io.Clock.now(.awake, io);
    var report: RuntimeReport = .{};
    var t: u32 = 0;
    while (t < Ticks) : (t += 1) {
        try interp.stepOnce(&world, &report);
        world.tickBoundary();
    }
    const t1 = std.Io.Clock.now(.awake, io);
    const total_ns: u64 = @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds));
    const total_ms = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));

    var out_buf: [256]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;
    try out.print(
        "Demo S4 OK | mode={s} | entities={d} | rules=5 | ticks={d} | rules_matched={d} | errors={d} | total={d:.3}ms\n",
        .{
            @tagName(builtin.mode),
            Entities,
            Ticks,
            report.rules_matched,
            report.runtime_errors,
            total_ms,
        },
    );
    try out.flush();
}
