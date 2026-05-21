//! M0.1 / E2 — generalised archetype storage acceptance tests.
//!
//! Covers the three acceptance criteria listed in
//! `briefs/M0.1-ecs-full.md` § Acceptance criteria › Tests for E2
//! (Generalised archetype storage):
//!
//! - `test "add_component creates target archetype on first use and caches
//!   transition"` — the first `addComponent(T)` from a source archetype
//!   materialises the target archetype (signature = source ∪ {T}) and
//!   records the transition on the source's `TransitionCache.add`. The
//!   second `addComponent(T)` from another entity in the same source
//!   archetype reuses the cached id without consulting the global
//!   archetype list.
//! - `test "remove_component returns to source archetype via cached
//!   transition"` — symmetric to the above for `removeComponent`.
//!   Re-creating the same chain `(A)→(A,B)→(A)` reuses the cached
//!   `(A,B)→(A)` transition.
//! - `test "four archetypes coexist with independent chunk storage"` —
//!   spawning four entities with four distinct comptime component
//!   combinations creates four archetypes; each owns its own chunk
//!   list, and the world's location map resolves each entity to its
//!   own archetype.
//!
//! All three tests exercise the byte-level archetype layer added in
//! `src/core/ecs/archetype.zig` plus the transition routing wired into
//! `World.addComponent` / `World.removeComponent`. Generational identity
//! (E1) keeps providing the entity handles.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.entity.EntityId;
const Archetype = weld_core.ecs.archetype.Archetype;

// Additional POD components purely used by the transition tests so we
// can exercise add/remove without disturbing the canonical
// (Transform, Velocity) archetype the bench depends on.
const Health = extern struct {
    current: f32 = 100,
    max: f32 = 100,
};

const Tag = extern struct {
    flag: u32 = 1,
};

const Marker = extern struct {
    kind: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

test "add_component creates target archetype on first use and caches transition" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Spawn two entities in the same (Transform, Velocity) archetype.
    // The second one is needed to confirm the second `addComponent`
    // path hits the cached transition rather than rebuilding it.
    const a = try world.spawn(gpa, Transform{}, Velocity{});
    const b = try world.spawn(gpa, Transform{}, Velocity{});

    const initial_archetypes = world.archetypeCount();
    try std.testing.expectEqual(@as(usize, 1), initial_archetypes);

    // Source archetype before the first transition — no add-cache entry
    // for Health yet.
    const src_loc_a = world.dynamicLocation(a).?;
    const src_arch = world.dynamicArchetype(src_loc_a.archetype_idx);
    try std.testing.expectEqual(@as(usize, 0), src_arch.transitions.add.count());

    // First add: must materialise the target archetype and cache the
    // transition.
    try world.addComponent(gpa, a, Health, .{ .current = 75, .max = 100 });

    try std.testing.expectEqual(@as(usize, 2), world.archetypeCount());

    // The transition was cached on the source archetype.
    const cached = src_arch.transitions.add.get(world.componentId(@typeName(Health)).?);
    try std.testing.expect(cached != null);

    // The entity now lives in the target archetype with Health present.
    const loc_a_after = world.dynamicLocation(a).?;
    try std.testing.expect(loc_a_after.archetype_idx != src_loc_a.archetype_idx);
    const target_arch = world.dynamicArchetype(loc_a_after.archetype_idx);
    try std.testing.expect(target_arch.hasComponent(world.componentId(@typeName(Health)).?));
    try std.testing.expect(target_arch.hasComponent(world.componentId(@typeName(Transform)).?));
    try std.testing.expect(target_arch.hasComponent(world.componentId(@typeName(Velocity)).?));

    // Confirm the Health value was actually written through the
    // migration.
    const health_idx = target_arch.componentIndex(world.componentId(@typeName(Health)).?).?;
    const chunk = target_arch.chunks.items[loc_a_after.chunk_idx];
    const bytes = target_arch.componentSlot(chunk, health_idx, loc_a_after.slot);
    var read: Health = undefined;
    @memcpy(std.mem.asBytes(&read), bytes);
    try std.testing.expectEqual(@as(f32, 75), read.current);

    // Second add from the same source archetype reuses the cached id —
    // no new archetype materialises.
    const archetype_count_before_b = world.archetypeCount();
    try world.addComponent(gpa, b, Health, .{});
    try std.testing.expectEqual(archetype_count_before_b, world.archetypeCount());

    // Both `a` and `b` now sit in the same target archetype.
    const loc_b_after = world.dynamicLocation(b).?;
    try std.testing.expectEqual(loc_a_after.archetype_idx, loc_b_after.archetype_idx);
}

test "remove_component returns to source archetype via cached transition" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Build the (Transform, Velocity, Health) archetype by adding
    // Health, then walk back down.
    const a = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, a, Health, .{});
    const expanded_loc = world.dynamicLocation(a).?;
    const expanded_arch = world.dynamicArchetype(expanded_loc.archetype_idx);
    const health_id = world.componentId(@typeName(Health)).?;

    // No remove-cache entry yet on the expanded archetype.
    try std.testing.expectEqual(@as(usize, 0), expanded_arch.transitions.remove.count());

    // First remove: materialises (or reuses) the (Transform, Velocity)
    // archetype and caches the transition.
    try world.removeComponent(gpa, a, Health);
    const back_loc = world.dynamicLocation(a).?;
    try std.testing.expect(back_loc.archetype_idx != expanded_loc.archetype_idx);

    // Cache hit recorded on the expanded archetype.
    const cached_remove = expanded_arch.transitions.remove.get(health_id);
    try std.testing.expectEqual(@as(?u32, back_loc.archetype_idx), cached_remove);

    // Second remove from a new entity in the expanded archetype reuses
    // the cached transition.
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, b, Health, .{});
    const archetype_count_before = world.archetypeCount();
    try world.removeComponent(gpa, b, Health);
    try std.testing.expectEqual(archetype_count_before, world.archetypeCount());

    // Both `a` and `b` are back in the (Transform, Velocity) archetype.
    const back_b = world.dynamicLocation(b).?;
    try std.testing.expectEqual(back_loc.archetype_idx, back_b.archetype_idx);
}

test "four archetypes coexist with independent chunk storage" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Four entities, each with a different comptime component
    // combination:
    //   A : (Transform, Velocity)
    //   B : (Transform, Velocity, Health)
    //   C : (Transform, Velocity, Health, Tag)
    //   D : (Transform, Velocity, Marker)
    const a = try world.spawn(gpa, Transform{}, Velocity{});
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, b, Health, .{ .current = 50, .max = 200 });
    const c = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, c, Health, .{});
    try world.addComponent(gpa, c, Tag, .{ .flag = 7 });
    const d = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, d, Marker, .{ .kind = 3 });

    try std.testing.expectEqual(@as(usize, 4), world.archetypeCount());

    // Each entity sits in its own archetype.
    const la = world.dynamicLocation(a).?;
    const lb = world.dynamicLocation(b).?;
    const lc = world.dynamicLocation(c).?;
    const ld = world.dynamicLocation(d).?;
    try std.testing.expect(la.archetype_idx != lb.archetype_idx);
    try std.testing.expect(la.archetype_idx != lc.archetype_idx);
    try std.testing.expect(la.archetype_idx != ld.archetype_idx);
    try std.testing.expect(lb.archetype_idx != lc.archetype_idx);
    try std.testing.expect(lb.archetype_idx != ld.archetype_idx);
    try std.testing.expect(lc.archetype_idx != ld.archetype_idx);

    // Each archetype owns its own chunk list — exactly one chunk per
    // archetype here (we spawned a single entity per archetype after
    // the transition migrations), and each chunk's `archetype_id`
    // header field matches the owning archetype id.
    const ids = [_]u32{ la.archetype_idx, lb.archetype_idx, lc.archetype_idx, ld.archetype_idx };
    for (ids) |aid| {
        const arch: *Archetype = world.dynamicArchetype(aid);
        try std.testing.expectEqual(@as(usize, 1), arch.chunkCount());
        const chunk = arch.chunks.items[0];
        try std.testing.expectEqual(aid, chunk.header().archetype_id);
        try std.testing.expectEqual(@as(usize, 1), arch.entityCount());
    }

    // The values written via the typed spawn / addComponent path
    // survive the migrations. Read Health on entity `c` (it travelled
    // through two transitions).
    const c_arch = world.dynamicArchetype(lc.archetype_idx);
    const health_idx = c_arch.componentIndex(world.componentId(@typeName(Health)).?).?;
    const c_chunk = c_arch.chunks.items[lc.chunk_idx];
    var c_health: Health = undefined;
    @memcpy(std.mem.asBytes(&c_health), c_arch.componentSlot(c_chunk, health_idx, lc.slot));
    try std.testing.expectEqual(@as(f32, 100), c_health.current);

    // The `Tag.flag = 7` write also persisted through `c`'s second
    // transition (add Tag).
    const tag_idx = c_arch.componentIndex(world.componentId(@typeName(Tag)).?).?;
    var c_tag: Tag = undefined;
    @memcpy(std.mem.asBytes(&c_tag), c_arch.componentSlot(c_chunk, tag_idx, lc.slot));
    try std.testing.expectEqual(@as(u32, 7), c_tag.flag);
}

test "addComponent then removeComponent on the same entity is a round-trip" {
    // Sanity check: round-trip a single component on a single entity
    // and confirm the entity ends up exactly where it started and the
    // surviving components hold their pre-migration values.
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const e = try world.spawn(
        gpa,
        Transform{ .pos = .{ 1, 2, 3 } },
        Velocity{ .linear = .{ 4, 5, 6 } },
    );
    const initial = world.dynamicLocation(e).?;

    try world.addComponent(gpa, e, Health, .{});
    try world.removeComponent(gpa, e, Health);

    const final = world.dynamicLocation(e).?;
    try std.testing.expectEqual(initial.archetype_idx, final.archetype_idx);

    // Transform / Velocity survived both migrations byte-exact.
    const arch = world.dynamicArchetype(final.archetype_idx);
    const t_idx = arch.componentIndex(world.componentId(@typeName(Transform)).?).?;
    const v_idx = arch.componentIndex(world.componentId(@typeName(Velocity)).?).?;
    const chunk = arch.chunks.items[final.chunk_idx];

    var t_read: Transform = undefined;
    @memcpy(std.mem.asBytes(&t_read), arch.componentSlot(chunk, t_idx, final.slot));
    try std.testing.expectEqual(@as(f32, 1), t_read.pos[0]);
    try std.testing.expectEqual(@as(f32, 2), t_read.pos[1]);
    try std.testing.expectEqual(@as(f32, 3), t_read.pos[2]);

    var v_read: Velocity = undefined;
    @memcpy(std.mem.asBytes(&v_read), arch.componentSlot(chunk, v_idx, final.slot));
    try std.testing.expectEqual(@as(f32, 4), v_read.linear[0]);
    try std.testing.expectEqual(@as(f32, 5), v_read.linear[1]);
    try std.testing.expectEqual(@as(f32, 6), v_read.linear[2]);
}
