//! M0.9 vertical slice — headless host (E3).
//!
//! Option A (E3 ruling, brief Blockers #1): this host SPAWNS the 100 entities
//! via the canonical Phase 0 host-spawn pattern (the `demo_etch_codegen` /
//! `diff_runner` Etch↔ECS bridge), using the POD component types declared in
//! `gameplay.etch`, then ticks the five cooked Etch rules at a fixed 60 Hz
//! timestep. There is NO rendering (arrives in E4) and NO scene instantiation:
//! the `*.scene.etch` / `*.prefab.etch` are authored + cross-file validated
//! (E2-B), NOT loaded — runtime scene loading is the Phase 1 Scene
//! Serialization deliverable.

const std = @import("std");
const weld_core = @import("weld_core");
const cooked = @import("cooked_slice");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;

/// The slice spawns exactly 100 entities (C0.8 / brief E3).
pub const entity_count: u32 = 100;
/// Fixed 60 Hz timestep.
pub const fixed_dt: f32 = 1.0 / 60.0;
/// Default headless tick budget (≥ 120 per the brief's integration test).
pub const default_ticks: u32 = 120;

/// Authored cross-file Etch content, embedded (same-directory `@embedFile`) so
/// the integration test can run `validateProject` over it WITHOUT loading or
/// instantiating it. These exercise E2-B (cross-file scene→prefab + prefab `of`
/// base resolution) and E2-A (triple-quote text); they are never spawned.
pub const scene_etch = @embedFile("world.scene.etch");
pub const mob_prefab_etch = @embedFile("mob.prefab.etch");
pub const elite_prefab_etch = @embedFile("elite.prefab.etch");

/// The component-id set every slice entity carries (all five cooked rules fire
/// on each). Valid only after `cooked.gameplay.register` has run.
pub fn sliceComponentIds(world: *World) [5]ComponentId {
    return .{
        world.registry.idOf("Counter").?,
        world.registry.idOf("Position").?,
        world.registry.idOf("Velocity").?,
        world.registry.idOf("Health").?,
        world.registry.idOf("Energy").?,
    };
}

/// Register the cooked gameplay components/rules and spawn `entity_count`
/// entities. Shared by the host `main` and the headless integration test.
pub fn bootAndSpawn(world: *World, gpa: std.mem.Allocator) !void {
    try cooked.gameplay.register(world, gpa);
    const comps = sliceComponentIds(world);
    var i: u32 = 0;
    while (i < entity_count) : (i += 1) {
        _ = try world.spawnDynamic(gpa, &comps);
    }
}

/// One fixed-timestep simulation step — dispatch the five cooked Etch rules.
pub fn step(world: *World, gpa: std.mem.Allocator) void {
    cooked.gameplay.tick(world, gpa);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Optional `--ticks N` (default 120); the entity count is fixed at 100.
    var ticks: u32 = default_ticks;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--ticks") and ai + 1 < args.len) {
            ticks = std.fmt.parseInt(u32, args[ai + 1], 10) catch default_ticks;
            ai += 1;
        }
    }

    var world = World.init();
    defer world.deinit(gpa);

    try bootAndSpawn(&world, gpa);
    var t: u32 = 0;
    while (t < ticks) : (t += 1) step(&world, gpa);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    try out.print(
        "vertical-slice headless OK | entities={d} ticks={d} dt={d:.5}\n",
        .{ entity_count, ticks, fixed_dt },
    );
    try out.flush();
}
