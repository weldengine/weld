//! Tick-based change detection: the `Changed<T>` filter, `getMut`'s automatic
//! stamp, and the chunk-level dirty-bitset skip.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.entity.EntityId;
const Chunk = weld_core.ecs.world.Chunk;
const Archetype = weld_core.ecs.world.Archetype;

const query_mod = weld_core.ecs.query;
const Changed = query_mod.Changed;

// Test-only POD components used by the change-detection scenarios.
const Health = extern struct {
    current: f32 = 100,
    max: f32 = 100,
};
const Tag = extern struct {
    flag: u32 = 0,
};

const ChangedCounter = struct {
    matched: u32 = 0,
};

fn countChangedHealth(
    chunk: *Chunk,
    q: *const query_mod.Query(&.{Health}, .{Changed(Health)}),
    counter: *ChangedCounter,
) void {
    const arch = q.matchFor(chunk).?.archetype;
    const count = chunk.entityCount();
    var slot: u32 = 0;
    while (slot < count) : (slot += 1) {
        if (q.slotPasses(arch, chunk, slot)) counter.matched += 1;
    }
}

test "Changed<T> returns only entities whose component changed since last run" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const stable = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, stable, Health, .{ .current = 100, .max = 100 });
    const modified = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, modified, Health, .{ .current = 100, .max = 100 });

    var q = try world.queryFiltered(gpa, &.{Health}, .{Changed(Health)});
    defer q.deinit(gpa);

    // Snapshot the post-spawn tick as `last_run_tick`: a spawn stamps
    // `changed_tick` at `current_tick`, so without this baseline both entities
    // would read as "changed since last run".
    q.last_run_tick = world.current_tick;

    world.beginFrame();
    world.getMut(Health, modified).?.current = 42.0;

    var counter: ChangedCounter = .{};
    q.forEachChunk(countChangedHealth, .{ &q, &counter });
    try std.testing.expectEqual(@as(u32, 1), counter.matched);

    // Advance `last_run_tick` so the second iteration, with no mutation between
    // the two, must see zero changes.
    q.last_run_tick = world.current_tick;

    world.beginFrame();
    var counter2: ChangedCounter = .{};
    q.forEachChunk(countChangedHealth, .{ &q, &counter2 });
    try std.testing.expectEqual(@as(u32, 0), counter2.matched);
}

test "getMut auto-marks changed_tick to current world tick" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const e = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e, Health, .{ .current = 100, .max = 100 });

    // A new frame makes `current_tick` non-zero AND clears the bitset, isolating
    // this slot's dirty state to the write below.
    world.beginFrame();
    const tick_before_write = world.current_tick;

    world.getMut(Health, e).?.current = 13.0;

    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const health_id = world.componentId(@typeName(Health)).?;
    const col = arch.componentIndex(health_id).?;

    try std.testing.expectEqual(tick_before_write, arch.changedTick(chunk, col, loc.slot));
    try std.testing.expect(!arch.isChunkClean(chunk));

    // The auto-mark must not have corrupted the payload it stamped.
    const bytes = arch.componentSlot(chunk, col, loc.slot);
    var read: Health = undefined;
    @memcpy(std.mem.asBytes(&read), bytes);
    try std.testing.expectEqual(@as(f32, 13.0), read.current);
}

test "dirty bitset skip on a fully clean chunk avoids per-entity inspection" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `allocateSlot` stamps a fresh slot dirty for first-frame visibility, so
    // this frame ends with a dirty bitset.
    const e1 = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e1, Health, .{});
    const e2 = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e2, Health, .{});

    const loc = world.dynamicLocation(e1).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];

    try std.testing.expect(!arch.isChunkClean(chunk));

    // `beginFrame` clears every chunk's bitset, and nothing mutates after it.
    world.beginFrame();
    try std.testing.expect(arch.isChunkClean(chunk));

    // The skip is applied here rather than inside the query, so the per-slot
    // inspections a clean chunk costs are directly observable.
    var q = try world.queryFiltered(gpa, &.{Health}, .{Changed(Health)});
    defer q.deinit(gpa);
    q.last_run_tick = world.current_tick - 1; // any prior tick is fine

    var inspected_slots: u32 = 0;
    for (q.matches.items) |m| {
        for (m.archetype.chunks.items) |c| {
            if (m.archetype.isChunkClean(c)) continue;
            inspected_slots += c.entityCount();
        }
    }
    try std.testing.expectEqual(@as(u32, 0), inspected_slots);

    // Non-vacuity: a write flips the bitset and the skip stops dropping the
    // chunk — without it, a skip that dropped everything would also pass.
    world.getMut(Health, e1).?.current = 1.0;
    try std.testing.expect(!arch.isChunkClean(chunk));
}
