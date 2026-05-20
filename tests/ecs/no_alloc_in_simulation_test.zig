const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Chunk = weld_core.ecs.world.Chunk;
const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;

fn integrateChunk(chunk: *Chunk, transforms_off: u16, velocities_off: u16, dt: f32) void {
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[transforms_off]));
    const velocities: [*]Velocity = @ptrCast(@alignCast(&chunk.bytes[velocities_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        velocities[i].linear[1] -= 9.81 * dt;
        transforms[i].pos[0] += velocities[i].linear[0] * dt;
        transforms[i].pos[1] += velocities[i].linear[1] * dt;
        transforms[i].pos[2] += velocities[i].linear[2] * dt;
    }
}

test "1000 query iterations allocate zero bytes after init" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();

    var world = World.init();
    defer world.deinit(gpa);

    // Spawn enough entities to fill several chunks. Allocations during this
    // phase are expected — we measure only the steady-state simulation loop.
    const N: u32 = 10_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        _ = try world.spawn(gpa, Transform{}, Velocity{});
    }

    const before = counting.snapshot();
    var query = world.query();
    const transforms_off = query.componentOffset(0);
    const velocities_off = query.componentOffset(1);
    var iter: u32 = 0;
    while (iter < 1000) : (iter += 1) {
        query.forEachChunk(integrateChunk, .{ transforms_off, velocities_off, @as(f32, 1.0 / 60.0) });
    }
    const after = counting.snapshot();
    const delta = CountingAllocator.delta(after, before);

    try std.testing.expectEqual(@as(u64, 0), delta.alloc_count);
    try std.testing.expectEqual(@as(u64, 0), delta.free_count);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), delta.bytes_freed);
}
