const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const Archetype = weld_core.ecs.world.Archetype;
const Scheduler = weld_core.jobs.scheduler.Scheduler;

/// Apply a one-iteration integration to every entity in `chunk`. Mirrors the
/// bench body so `zig build run` exercises the full ECS + scheduler stack.
fn integrateChunk(chunk: *Archetype.ChunkT, dt: f32) void {
    const count = chunk.entityCount();
    const transforms = chunk.componentArray(0);
    const velocities = chunk.componentArray(1);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        velocities[i].linear[1] -= 9.81 * dt;
        transforms[i].pos[0] += velocities[i].linear[0] * dt;
        transforms[i].pos[1] += velocities[i].linear[1] * dt;
        transforms[i].pos[2] += velocities[i].linear[2] * dt;
    }
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var world = World.init();
    defer world.deinit(gpa);

    // Spawn a small batch of entities so the smoke output exercises the full
    // path: archetype allocation, chunk allocation, and one query iteration.
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        _ = try world.spawn(
            gpa,
            .{ .pos = .{ fi, 0, 0 } },
            .{ .linear = .{ 0, 1, 0 } },
        );
    }

    var scheduler = try Scheduler.init(gpa, init.io);
    try scheduler.start();
    defer scheduler.deinit();

    var query = world.query();
    scheduler.dispatch(&query, integrateChunk, .{@as(f32, 1.0 / 60.0)});

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print(
        "Weld bootstrap OK + ECS spike OK ({s}, {d} workers)\n",
        .{ @tagName(builtin.mode), weld_core.jobs.scheduler.worker_count },
    );
    try stdout.interface.flush();
}

test "main module compiles" {
    try std.testing.expect(true);
}
