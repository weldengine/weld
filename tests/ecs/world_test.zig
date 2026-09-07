const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.world.EntityId;

test "spawn and despawn 100k entities without leak" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const N: u32 = 100_000;
    var ids = try gpa.alloc(EntityId, N);
    defer gpa.free(ids);

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        ids[i] = try world.spawn(
            gpa,
            .{ .pos = .{ fi, 0, 0 } },
            .{ .linear = .{ 0, 1, 0 } },
        );
    }
    try std.testing.expectEqual(@as(usize, N), world.entityCount());

    // Despawn in reverse to exercise the no-swap-needed path mostly, plus
    // the first half despawned forward to exercise swap-and-pop.
    const half: u32 = N / 2;
    var j: u32 = N;
    while (j > half) : (j -= 1) try world.despawn(gpa, ids[j - 1]);
    var k: u32 = 0;
    while (k < half) : (k += 1) try world.despawn(gpa, ids[k]);

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

// ─── M1.B / G2 — the EMPTY archetype ──────────────────────────────────────

test "an entity spawns into the EMPTY archetype, is locatable, and despawns" {
    // The archetype of zero components became legal at M1.B/G2. The reason is
    // not the sparse backend's convenience: an entity ALWAYS has an archetype,
    // and making it optional would create a second entity lifecycle that
    // despawn, the observers, the three spawn paths and `dynamicLocation` would
    // each have to tell apart. So an entity whose whole component set is sparse
    // lives here — and at this gate the sparse side is not yet wired to the
    // `World`, so what is provable is exactly this: the empty set spawns,
    // resolves and despawns like any other.
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const e = try world.spawnDynamic(gpa, &.{});
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
    try std.testing.expect(world.isLive(e));

    // It resolves through the ordinary funnel: a real location, in a real
    // archetype, which carries no component column.
    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    try std.testing.expectEqual(@as(usize, 0), arch.component_ids.len);
    try std.testing.expectEqual(@as(usize, 1), arch.entityCount());

    // Two such entities share ONE archetype rather than producing one each —
    // the signature of the empty set is the empty signature, so the lookup
    // hits. Without this the empty archetype would be a per-entity allocation.
    const e2 = try world.spawnDynamic(gpa, &.{});
    try std.testing.expectEqual(loc.archetype_idx, world.dynamicLocation(e2).?.archetype_idx);
    try std.testing.expectEqual(@as(usize, 2), arch.entityCount());

    try world.despawn(gpa, e);
    try world.despawn(gpa, e2);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
    try std.testing.expectEqual(@as(usize, 0), arch.entityCount());
    try std.testing.expect(!world.isLive(e));
}
