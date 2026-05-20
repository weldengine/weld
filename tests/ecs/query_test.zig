const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Chunk = weld_core.ecs.world.Chunk;

fn countChunk(chunk: *Chunk, counter: *u32) void {
    counter.* += chunk.entityCount();
}

test "query visits every spawned entity exactly once" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const N: u32 = 4_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        _ = try world.spawn(gpa, Transform{}, Velocity{});
    }

    var counter: u32 = 0;
    var query = world.query();
    query.forEachChunk(countChunk, .{&counter});
    try std.testing.expectEqual(N, counter);
}

fn writeKnown(chunk: *Chunk, transforms_off: u16, value: f32) void {
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[transforms_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        transforms[i].pos[0] = value;
    }
}

fn assertKnown(chunk: *Chunk, transforms_off: u16, value: f32, all_equal: *bool) void {
    const count = chunk.entityCount();
    const transforms: [*]Transform = @ptrCast(@alignCast(&chunk.bytes[transforms_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (transforms[i].pos[0] != value) all_equal.* = false;
    }
}

test "writes through query persist across iterations" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const N: u32 = 1_000;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        _ = try world.spawn(gpa, Transform{}, Velocity{});
    }

    var query = world.query();
    const transforms_off = query.componentOffset(0);
    query.forEachChunk(writeKnown, .{ transforms_off, @as(f32, 7.5) });

    var all_equal: bool = true;
    query.forEachChunk(assertKnown, .{ transforms_off, @as(f32, 7.5), &all_equal });
    try std.testing.expect(all_equal);
}
