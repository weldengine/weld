//! S5 demo binary — exercises the cooked Etch → Zig codegen output. The
//! `tick` function is statically compiled into the binary; no parser or
//! VM is loaded at runtime. Output is deterministic so the test gate can
//! diff it against `bench/fixtures/demo_5_rules_codegen.expected.txt`.

const std = @import("std");
const weld_core = @import("weld_core");
const cooked = @import("cooked_demo");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;

const Ticks: u32 = 10;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var world = World.init();
    defer world.deinit(gpa);

    try cooked.demo.register(&world, gpa);

    const counter_id = world.registry.idOf("Counter").?;
    const score_id = world.registry.idOf("Score").?;
    const active_id = world.registry.idOf("Active").?;

    // Three entities with deliberately different starting compositions so
    // each rule fires in a different combination.
    const e0 = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, score_id, active_id });
    const e1 = try world.spawnDynamic(gpa, &[_]ComponentId{ counter_id, score_id });
    const e2 = try world.spawnDynamic(gpa, &[_]ComponentId{counter_id});

    // Tick the cooked program.
    var t: u32 = 0;
    while (t < Ticks) : (t += 1) cooked.demo.tick(&world);

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    // No `mode=...` or timing in the output — the demo's stdout is byte-
    // compared against `bench/fixtures/demo_5_rules_codegen.expected.txt`
    // and we want that match to hold regardless of build mode.
    try out.print("Demo S5 OK | ticks={d}\n", .{Ticks});
    try printEntity(out, &world, 0, e0, counter_id, score_id, active_id);
    try printEntity(out, &world, 1, e1, counter_id, score_id, null);
    try printEntity(out, &world, 2, e2, counter_id, null, null);
    try out.flush();
}

fn printEntity(
    out: anytype,
    world: *World,
    idx: u32,
    eid: u64,
    counter_id: ComponentId,
    score_id_opt: ?ComponentId,
    active_id_opt: ?ComponentId,
) !void {
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];

    var counter_val: i64 = 0;
    {
        const c_idx = arch.componentIndex(counter_id).?;
        const off = arch.layout.component_offsets[c_idx];
        const slot = chunk.bytes[off + 8 * loc.slot ..][0..8];
        @memcpy(std.mem.asBytes(&counter_val), slot);
    }
    try out.print("entity {d}: Counter.value={d}", .{ idx, counter_val });

    if (score_id_opt) |sid| {
        var score_val: f64 = 0;
        const s_idx = arch.componentIndex(sid).?;
        const off = arch.layout.component_offsets[s_idx];
        const slot = chunk.bytes[off + 8 * loc.slot ..][0..8];
        @memcpy(std.mem.asBytes(&score_val), slot);
        try out.print(" Score.total={d:.3}", .{score_val});
    }
    if (active_id_opt) |aid| {
        const a_idx = arch.componentIndex(aid).?;
        const off = arch.layout.component_offsets[a_idx];
        const slot = chunk.bytes[off + 1 * loc.slot ..][0..1];
        try out.print(" Active.flag={}", .{slot[0] != 0});
    }
    try out.print("\n", .{});
}
