//! M1.0.5 E2 — runtime scene loader benchmark.
//!
//! Measures the wall time of `scene.loader.loadFromBytes` on a ~10k-entity
//! scene. The image is produced in-process by the M1.0.4 `writer` (no
//! `.scene.etch` authoring, no file I/O) so the number isolates the load work:
//! the per-entity `spawnDynamicWithValues` (archetype find/create + slot alloc +
//! component memcpy), the schema-identity remap, and the `on_spawned` pass.
//!
//! **Measurement, not a gate.** It prints a median; the milestone's per-entity-
//! vs-bulk decision is recorded from this number (spec ref ~10–50 ms / 10k).
//! Run in ReleaseFast for a representative figure:
//!   `zig build bench-scene-load -Doptimize=ReleaseFast`

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");

const World = weld_core.ecs.World;
const Registry = weld_core.ecs.registry.Registry;
const scene = weld_core.scene;
const format = scene.format;
const writer = scene.writer;
const loader = scene.loader;

const num_entities: u32 = 10_000;
const warmup_runs: u32 = 3;
const measured_runs: u32 = 50;
const pos_size: u16 = 12; // [3]f32
const pos_align: u16 = 4;

/// Cook a single `[Pos]` archetype of `num_entities` entities into `.scene.bin`
/// bytes (caller-owned). The cook registry is local — the writer copies the
/// schema name into the image, so the bytes outlive it.
fn buildSceneBytes(gpa: std.mem.Allocator) ![]u8 {
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const pos = try reg.registerComponentRaw(gpa, .{
        .name = "Pos",
        .size = pos_size,
        .alignment = pos_align,
        .default_bytes = &[_]u8{0} ** pos_size,
        .fields = &.{},
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "E")});
    const uuids = try a.alloc([16]u8, num_entities);
    for (0..num_entities) |i| {
        uuids[i] = [_]u8{0} ** 16;
        std.mem.writeInt(u32, uuids[i][0..4], @intCast(i + 1), .little);
    }
    const col = try a.alloc(u8, @as(usize, pos_size) * num_entities);
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.alloc(format.EntityEntry, num_entities);
    for (0..num_entities) |i| ents[i] = .{ .name = 0, .uuid = @intCast(i), .parent_uuid = format.no_parent };
    const ids = try a.dupe(format.ComponentId, &.{pos});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = num_entities,
        .columns = cols,
        .entities = ents,
    }});
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, &reg);
}

/// One timed load into a fresh world. Returns the elapsed ns (the load only —
/// world setup and teardown are outside the measured window).
fn timeOneLoad(gpa: std.mem.Allocator, io: std.Io, bytes: []const u8) !u64 {
    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{
        .name = "Pos",
        .size = pos_size,
        .alignment = pos_align,
        .default_bytes = &[_]u8{0} ** pos_size,
        .fields = &.{},
    });

    const t0 = std.Io.Clock.now(.awake, io);
    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
    const t1 = std.Io.Clock.now(.awake, io);
    result.deinit(gpa);
    const elapsed = t0.durationTo(t1).nanoseconds;
    return @intCast(@max(@as(i96, 0), elapsed));
}

fn msFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const bytes = try buildSceneBytes(gpa);
    defer gpa.free(bytes);

    const samples = try gpa.alloc(u64, measured_runs);
    defer gpa.free(samples);

    var run: u32 = 0;
    const total = warmup_runs + measured_runs;
    while (run < total) : (run += 1) {
        const ns = try timeOneLoad(gpa, io, bytes);
        if (run >= warmup_runs) samples[run - warmup_runs] = ns;
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const median = samples[samples.len / 2];

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(
        "scene_load_bench [{s}]: {d} entities, {d} runs\n" ++
            "  median {d:.3} ms | min {d:.3} ms | max {d:.3} ms\n",
        .{
            @tagName(builtin.mode),
            num_entities,
            measured_runs,
            msFromNs(median),
            msFromNs(samples[0]),
            msFromNs(samples[samples.len - 1]),
        },
    );
    try w.interface.flush();
}
