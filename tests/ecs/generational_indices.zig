//! M0.1 / E1 — generational identity acceptance tests.
//!
//! Covers the two acceptance criteria listed in
//! `briefs/M0.1-ecs-full.md` § Acceptance criteria › Tests for E1
//! (Identity foundations):
//!
//! - `test "stale entity handle is rejected after swap-and-pop"` — a
//!   handle that was valid before its slot was despawned and reused
//!   returns `error.StaleEntityHandle` from `World.despawn`, and
//!   `World.isLive` reports `false` for it. The swap-and-pop case is
//!   explicitly exercised by despawning a non-last entity so the chunk's
//!   trailing entity migrates into the freed slot.
//!
//! - `test "despawned slot is reused with bumped generation"` — after a
//!   `despawn` the next `spawn` recycles the previous slot index with a
//!   strictly greater generation. Multiple cycles confirm the generation
//!   keeps increasing across re-uses.
//!
//! The bench non-regression case (S1 100 k × 1 archetype) lives in
//! `bench/ecs_benchmark.zig` and is exercised separately by `zig build
//! bench-ecs`. The tests below are deliberately small so they can run
//! under `zig build test` in both Debug and ReleaseSafe.

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

    // Spawn three entities so despawn of the middle one triggers a
    // swap-and-pop in the same chunk — the trailing entity migrates into
    // the freed chunk slot. Three distinct positions make it easy to
    // verify the right one survived.
    const a = try world.spawn(gpa, .{ .pos = .{ 1, 0, 0 } }, .{ .linear = .{ 0, 0, 0 } });
    const b = try world.spawn(gpa, .{ .pos = .{ 2, 0, 0 } }, .{ .linear = .{ 0, 0, 0 } });
    const c = try world.spawn(gpa, .{ .pos = .{ 3, 0, 0 } }, .{ .linear = .{ 0, 0, 0 } });
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());

    // Despawn `b` — `c` swap-and-pops into the freed slot.
    try world.despawn(gpa, b);
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());

    // The original `b` handle is now stale.
    try std.testing.expect(!world.isLive(b));
    try std.testing.expectError(error.StaleEntityHandle, world.despawn(gpa, b));

    // `a` and `c` are still live and despawnable through their original
    // handles — the swap update kept their location map entries coherent.
    try std.testing.expect(world.isLive(a));
    try std.testing.expect(world.isLive(c));
    try world.despawn(gpa, a);
    try world.despawn(gpa, c);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    // Both `a` and `c` are now also stale handles.
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

    // Next spawn pulls the freed slot off the free list — same index,
    // strictly greater generation.
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(b.generation > a.generation);
    try std.testing.expect(world.isLive(b));
    try std.testing.expect(!world.isLive(a));

    // Spinning the same slot a few more times keeps the generation strictly
    // increasing on every cycle — no wraparound at the milestone scale.
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
