//! Generational identity: a handle whose slot was despawned and reused is
//! rejected, and a recycled slot comes back with a strictly greater
//! generation.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.entity.EntityId;

test "stale entity handle is rejected after swap-and-pop" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // THREE entities, so despawning the middle one forces a swap-and-pop within
    // the chunk, and three distinct positions tell which one survived it.
    const a = try world.spawn(gpa, .{ .pos = .{ 1, 0, 0 } }, .{ .linear = .{ 0, 0, 0 } });
    const b = try world.spawn(gpa, .{ .pos = .{ 2, 0, 0 } }, .{ .linear = .{ 0, 0, 0 } });
    const c = try world.spawn(gpa, .{ .pos = .{ 3, 0, 0 } }, .{ .linear = .{ 0, 0, 0 } });
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());

    // `c` swap-and-pops into `b`'s freed slot.
    try world.despawn(gpa, b);
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());

    try std.testing.expect(!world.isLive(b));
    try std.testing.expectError(error.StaleEntityHandle, world.despawn(gpa, b));

    // `c` moved, so its original handle still resolving is what proves the swap
    // kept the location map coherent.
    try std.testing.expect(world.isLive(a));
    try std.testing.expect(world.isLive(c));
    try world.despawn(gpa, a);
    try world.despawn(gpa, c);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    try std.testing.expectError(error.StaleEntityHandle, world.despawn(gpa, a));
    try std.testing.expectError(error.StaleEntityHandle, world.despawn(gpa, c));
}

test "despawned slot is reused with bumped generation" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const a = try world.spawn(gpa, Transform{}, Velocity{});
    try std.testing.expectEqual(@as(u32, 0), a.generation);

    try world.despawn(gpa, a);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    // The next spawn pulls the freed slot off the free list: same index, strictly
    // greater generation.
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(b.generation > a.generation);
    try std.testing.expect(world.isLive(b));
    try std.testing.expect(!world.isLive(a));

    // Spinning the same slot keeps the generation strictly increasing — no
    // wraparound at this scale.
    var previous = b;
    var cycles: u32 = 0;
    while (cycles < 8) : (cycles += 1) {
        try world.despawn(gpa, previous);
        const next = try world.spawn(gpa, Transform{}, Velocity{});
        try std.testing.expectEqual(previous.index, next.index);
        try std.testing.expect(next.generation > previous.generation);
        previous = next;
    }

    try world.despawn(gpa, previous);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}
