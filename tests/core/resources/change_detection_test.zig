//! M0.2 / E3 — Resources change-detection tests.
//!
//! Reuses the M0.1 tick-based mechanism (`World.current_tick` +
//! per-archetype `changed_ticks`). `getResourceMut` auto-marks
//! `changed_tick = current_tick` on the resource's slot via
//! `world.getMut`, then `resourceChanged(T, since_tick)` reads
//! the tick back.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const resources = weld_core.resources;

const Counter = extern struct {
    value: u64 = 0,
};

test "getResourceMut bumps changed_tick to the current tick" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, Counter{ .value = 1 });

    // Capture the initial tick — `setResource`'s first-time path
    // routes through `spawnDynamicWithValues` which writes
    // `current_tick` to both `added_tick` and `changed_tick`.
    const tick_before_mut = world.current_tick;

    // Bump the world tick — emulates a frame boundary. After this,
    // any `changed_tick` on the resource that equals
    // `tick_before_mut` is stale relative to the new current_tick.
    world.beginFrame();
    try std.testing.expect(world.current_tick > tick_before_mut);

    const mut = resources.getResourceMut(&world, Counter).?;
    mut.value = 2;

    // `resourceChanged(since = tick_before_mut)` must now return
    // true because `getResourceMut` rewrote `changed_tick` to the
    // post-`beginFrame` current_tick.
    try std.testing.expect(resources.resourceChanged(&world, Counter, tick_before_mut));
}

test "resourceChanged(since=tick_avant) returns true after getResourceMut" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, Counter{});
    const baseline = world.current_tick;

    world.beginFrame();
    _ = resources.getResourceMut(&world, Counter).?;

    try std.testing.expect(resources.resourceChanged(&world, Counter, baseline));
}

test "resourceChanged(since=tick_apres) returns false without modification" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, Counter{});
    // Advance the clock without touching the resource.
    world.beginFrame();
    world.beginFrame();
    const tick_after = world.current_tick;

    // No `getResourceMut` between the two ticks → the resource's
    // `changed_tick` is older than `tick_after`.
    try std.testing.expect(!resources.resourceChanged(&world, Counter, tick_after));
}

test "resourceChanged is false for an absent resource" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try std.testing.expect(!resources.resourceChanged(&world, Counter, 0));
}

test "setResource initial marks added_tick = current_tick" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const tick_at_set = world.current_tick;
    try resources.setResource(&world, gpa, Counter{ .value = 1 });

    // Read the resource's archetype `added_tick` directly to
    // confirm the spawn path stamps it correctly. The slot is
    // resolved via the singleton entity's location.
    const Tid = weld_core.rtti.computeTypeId(Counter);
    const eid = world.singleton_resources.lookup(Tid).?;
    const loc = world.entity_locations.get(eid).?;
    const cid = world.registry.idOf(@typeName(Counter)).?;
    const arch = world.archetypes.items[loc.archetype_idx];
    const col_idx = arch.componentIndex(cid).?;
    const chunk = arch.chunks.items[loc.chunk_idx];
    const added = arch.addedTick(chunk, col_idx, loc.slot);
    try std.testing.expectEqual(tick_at_set, added);
}
