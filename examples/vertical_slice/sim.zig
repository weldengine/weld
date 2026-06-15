//! M0.9 vertical slice — simulation, scene init, and input (pure, no GPU).
//!
//! The render-free core of the slice, shared by the host (`main.zig`) and the
//! integration test. It boots an ECS `World` with the cooked gameplay
//! components/rules (Option A host-spawn — brief Blockers #1), lays the 100
//! entities out on a grid with gentle per-entity velocities, ticks the five
//! cooked Etch rules at a fixed 60 Hz, and reads back live `Position` for the
//! renderer. Input is the M0.3 raw path: a host pumps window events into an
//! `InputRawState`; `Control.applyEdge` toggles a pause flag on the SPACE
//! rising edge, and `stepIfRunning` gates the simulation on it — an observable
//! effect on the sim driven by one input action.

const std = @import("std");
const weld_core = @import("weld_core");
const cooked = @import("cooked_slice");

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const ComponentId = weld_core.ecs.registry.ComponentId;
const window = weld_core.platform.window;

/// The slice spawns exactly 100 entities (C0.8 / brief E3).
pub const entity_count: u32 = 100;
/// Fixed 60 Hz timestep.
pub const fixed_dt: f32 = 1.0 / 60.0;
/// Default tick budget (≥ 120 per the brief's integration test).
pub const default_ticks: u32 = 120;

/// Grid layout: 10 × 10, world-unit spacing between cells.
const grid_cols: u32 = 10;
const grid_spacing: f32 = 2.0;

/// Authored cross-file Etch content, embedded so the integration test can run
/// `validateProject` over it WITHOUT loading/instantiating it (E2-B / E2-A).
/// Never spawned — runtime scene instantiation is Phase 1.
pub const scene_etch = @embedFile("world.scene.etch");
pub const mob_prefab_etch = @embedFile("mob.prefab.etch");
pub const elite_prefab_etch = @embedFile("elite.prefab.etch");

/// The slice's single source asset (raw PNG bytes), exposed so the integration
/// test can run the M0.6 import → cook pipeline over it without a disk file.
pub const albedo_png = @embedFile("assets/slice_albedo.png");

/// The component-id set every slice entity carries. Valid only after
/// `cooked.gameplay.register` has run.
pub fn sliceComponentIds(world: *World) [5]ComponentId {
    return .{
        world.registry.idOf("Counter").?,
        world.registry.idOf("Position").?,
        world.registry.idOf("Velocity").?,
        world.registry.idOf("Health").?,
        world.registry.idOf("Energy").?,
    };
}

/// Write one `f32` field of a component on a live entity, via the registry +
/// archetype layout (the `diff_runner` host-write path: the symmetric twin of
/// the test's read path).
fn setF32(world: *World, eid: EntityId, comp: []const u8, field: []const u8, value: f32) void {
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = world.registry.idOf(comp).?;
    const cidx = arch.componentIndex(cid).?;
    const slot = arch.componentSlot(chunk, cidx, loc.slot);
    const fd = world.registry.findField(cid, field).?;
    @memcpy(slot[fd.offset..][0..4], std.mem.asBytes(&value));
}

/// Read entity `index`'s live `Position` (x, y) — for the renderer's per-instance
/// offsets and for the integration test.
pub fn readPosition(world: *World, index: u32) [2]f32 {
    const eid = EntityId{ .index = index, .generation = 0 };
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = world.registry.idOf("Position").?;
    const cidx = arch.componentIndex(cid).?;
    const slot = arch.componentSlot(chunk, cidx, loc.slot);
    const fx = world.registry.findField(cid, "x").?;
    const fy = world.registry.findField(cid, "y").?;
    var x: f32 = 0;
    var y: f32 = 0;
    @memcpy(std.mem.asBytes(&x), slot[fx.offset..][0..4]);
    @memcpy(std.mem.asBytes(&y), slot[fy.offset..][0..4]);
    return .{ x, y };
}

/// Register the cooked gameplay components/rules, spawn `entity_count`
/// entities, and lay them out on a centered grid with gentle outward
/// velocities (host spawn gives zero-initialized components, so without this
/// every entity sits at the origin with no motion). Shared by host + test.
pub fn bootAndSpawn(world: *World, gpa: std.mem.Allocator) !void {
    try cooked.gameplay.register(world, gpa);
    const comps = sliceComponentIds(world);
    var i: u32 = 0;
    while (i < entity_count) : (i += 1) {
        const eid = try world.spawnDynamic(gpa, &comps);
        const gx: f32 = @floatFromInt(i % grid_cols);
        const gy: f32 = @floatFromInt(i / grid_cols);
        const cx = (gx - @as(f32, grid_cols - 1) / 2.0) * grid_spacing;
        const cy = (gy - @as(f32, grid_cols - 1) / 2.0) * grid_spacing;
        setF32(world, eid, "Position", "x", cx);
        setF32(world, eid, "Position", "y", cy);
        // Gentle outward drift so `integrate_motion` produces visible, bounded
        // motion over the tick budget (≈ 1.6 u max over 120 ticks).
        setF32(world, eid, "Velocity", "dx", cx * 0.0015);
        setF32(world, eid, "Velocity", "dy", cy * 0.0015);
    }
}

/// One fixed-timestep simulation step — dispatch the five cooked Etch rules.
pub fn step(world: *World, gpa: std.mem.Allocator) void {
    cooked.gameplay.tick(world, gpa);
}

/// Input-driven host control. One action: SPACE toggles pause.
pub const Control = struct {
    paused: bool = false,

    /// Toggle pause on a SPACE key-down edge (non-repeat). Reacts to the
    /// event's NORMALIZED `KeyCode` (`.code`) rather than the scancode-indexed
    /// `InputRawState` keyboard array: in Phase 0 the array is keyed by raw OS
    /// scancode (`applyEvent` uses `scancode & 0xFF`), and logical-key lookup
    /// is the Tier-1 action mapping (Phase 1). The host still pumps every event
    /// into `InputRawState` (the M0.3 resource pipeline); this reads the same
    /// event stream by logical key.
    pub fn applyEvent(self: *Control, event: window.Event) void {
        switch (event) {
            .key_down => |ev| {
                if (ev.code == .space and !ev.repeat) self.paused = !self.paused;
            },
            else => {},
        }
    }

    /// Step the simulation unless paused — the observable input effect.
    pub fn stepIfRunning(self: *const Control, world: *World, gpa: std.mem.Allocator) void {
        if (!self.paused) step(world, gpa);
    }
};
