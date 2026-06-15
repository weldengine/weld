//! M0.1 / E4 — tick-based change detection acceptance tests.
//!
//! Covers the three acceptance criteria listed in
//! `briefs/M0.1-ecs-full.md` § Acceptance criteria › Tests for E4
//! (Tick-based change detection):
//!
//! - `test "Changed<T> returns only entities whose component changed
//!   since last run"` — build a `Query(.{Health}, .{Changed(Health)})`,
//!   tick the world, write to one entity via `getMut`, leave the
//!   other untouched. The query body counts only the modified
//!   entity.
//! - `test "getMut auto-marks changed_tick to current world tick"` —
//!   write through `world.getMut(T, entity)`, then read
//!   `archetype.changedTick(chunk, col, slot)` and assert it equals
//!   `world.current_tick`.
//! - `test "dirty bitset skip on a fully clean chunk avoids per-entity
//!   inspection"` — after a `beginFrame` with no mutations, the chunk
//!   bitset is all-zero and a `Changed<T>`-filtered iteration that
//!   honours the dirty-skip optimisation does zero per-slot
//!   inspections.

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

// ─── Test infrastructure for the Changed<Health> iteration ────────────────

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

    // Two entities in the same (Transform, Velocity, Health) archetype.
    const stable = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, stable, Health, .{ .current = 100, .max = 100 });
    const modified = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, modified, Health, .{ .current = 100, .max = 100 });

    var q = try world.queryFiltered(gpa, &.{Health}, .{Changed(Health)});
    defer q.deinit(gpa);

    // Snapshot the post-spawn tick as the query's `last_run_tick` so
    // the initial spawn-stamped `changed_tick` values do not count as
    // "changed since last run" — every spawn marks `changed_tick`
    // at `world.current_tick`, which is shared with the snapshot
    // here. The first run is the baseline.
    q.last_run_tick = world.current_tick;

    // Frame 1 — mutate one entity, leave the other alone.
    world.beginFrame();
    world.getMut(Health, modified).?.current = 42.0;

    var counter: ChangedCounter = .{};
    q.forEachChunk(countChangedHealth, .{ &q, &counter });
    try std.testing.expectEqual(@as(u32, 1), counter.matched);

    // Advance last_run_tick so a second iteration with no mutations
    // sees zero changes.
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

    // Open a new frame so `current_tick` is non-zero — `beginFrame`
    // also clears the bitset, isolating this slot's dirty state to
    // the upcoming write.
    world.beginFrame();
    const tick_before_write = world.current_tick;

    // Write through getMut and confirm the sidecar caught it.
    world.getMut(Health, e).?.current = 13.0;

    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const health_id = world.componentId(@typeName(Health)).?;
    const col = arch.componentIndex(health_id).?;

    try std.testing.expectEqual(tick_before_write, arch.changedTick(chunk, col, loc.slot));
    try std.testing.expect(!arch.isChunkClean(chunk));

    // The value the caller wrote is observable through the byte
    // slot — a smoke check the auto-mark did not corrupt the
    // payload.
    const bytes = arch.componentSlot(chunk, col, loc.slot);
    var read: Health = undefined;
    @memcpy(std.mem.asBytes(&read), bytes);
    try std.testing.expectEqual(@as(f32, 13.0), read.current);
}

test "dirty bitset skip on a fully clean chunk avoids per-entity inspection" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Spawn entities into the (T,V,Health) archetype so we have a
    // chunk to inspect. `allocateSlot` stamps the slot as dirty
    // (first-frame visibility), so we end this frame with a dirty
    // bitset.
    const e1 = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e1, Health, .{});
    const e2 = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e2, Health, .{});

    const loc = world.dynamicLocation(e1).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];

    // After spawn but before beginFrame, the bitset has at least one
    // dirty bit (the freshly-allocated slots).
    try std.testing.expect(!arch.isChunkClean(chunk));

    // beginFrame clears every chunk's bitset. After it, no mutation
    // happens, so the bitset stays all-zero.
    world.beginFrame();
    try std.testing.expect(arch.isChunkClean(chunk));

    // Iterate the query, applying the chunk-level skip ourselves to
    // observe that NO per-entity inspection happens on a clean chunk.
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

    // Sanity check: once a write happens, the bitset flips dirty and
    // the chunk-level skip stops dropping that chunk.
    world.getMut(Health, e1).?.current = 1.0;
    try std.testing.expect(!arch.isChunkClean(chunk));
}
