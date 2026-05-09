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
    while (j > half) : (j -= 1) world.despawn(ids[j - 1]);
    var k: u32 = 0;
    while (k < half) : (k += 1) world.despawn(ids[k]);

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}
