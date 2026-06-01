//! M0.2 / E3 — Resources API tests.
//!
//! Coverage per `briefs/M0.2-rtti-resources-events-bindgen.md` E3
//! § Local acceptance criteria:
//!
//! - `setResource` + `getResource` round-trip.
//! - `setResource` on a pre-existing type overwrites the value.
//! - `removeResource` invalidates the subsequent `getResource`.
//! - `hasResource` flips correctly across set/remove.
//! - `getResourceMut` returns a mutable pointer whose mutation is
//!   visible via `getResource`.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const resources = weld_core.resources;

const GameClock = extern struct {
    current_tick: u64 = 0,
    dt_micros: u64 = 16_667,
};

const PhysicsConfig = extern struct {
    gravity_y: f32 = -9.81,
    fixed_rate_hz: u32 = 60,
};

test "setResource then getResource returns the value" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{
        .current_tick = 42,
        .dt_micros = 16_667,
    });

    const got = resources.getResource(&world, GameClock);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 42), got.?.current_tick);
    try std.testing.expectEqual(@as(u64, 16_667), got.?.dt_micros);
}

test "setResource on an existing type overwrites the value" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 1 });
    try resources.setResource(&world, gpa, GameClock{ .current_tick = 100 });

    const got = resources.getResource(&world, GameClock).?;
    try std.testing.expectEqual(@as(u64, 100), got.current_tick);
    // The singleton registry still holds exactly one binding for
    // GameClock — the update path does not create a second entity.
    try std.testing.expectEqual(@as(u32, 1), world.singleton_resources.count());
}

test "removeResource invalidates getResource" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 7 });
    try std.testing.expect(resources.getResource(&world, GameClock) != null);

    try resources.removeResource(&world, gpa, GameClock);
    try std.testing.expect(resources.getResource(&world, GameClock) == null);
}

test "hasResource flips across set / remove" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try std.testing.expect(!resources.hasResource(&world, PhysicsConfig));
    try resources.setResource(&world, gpa, PhysicsConfig{});
    try std.testing.expect(resources.hasResource(&world, PhysicsConfig));
    try resources.removeResource(&world, gpa, PhysicsConfig);
    try std.testing.expect(!resources.hasResource(&world, PhysicsConfig));
}

test "getResourceMut returns a mutable pointer visible via getResource" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 5 });

    const mut_ptr = resources.getResourceMut(&world, GameClock).?;
    mut_ptr.current_tick = 999;
    mut_ptr.dt_micros = 100;

    const got = resources.getResource(&world, GameClock).?;
    try std.testing.expectEqual(@as(u64, 999), got.current_tick);
    try std.testing.expectEqual(@as(u64, 100), got.dt_micros);
}

test "two resources of different types coexist" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 1 });
    try resources.setResource(&world, gpa, PhysicsConfig{ .gravity_y = -3.711 });

    const clock = resources.getResource(&world, GameClock).?;
    const phys = resources.getResource(&world, PhysicsConfig).?;
    try std.testing.expectEqual(@as(u64, 1), clock.current_tick);
    try std.testing.expectApproxEqAbs(@as(f32, -3.711), phys.gravity_y, 0.0001);

    try std.testing.expectEqual(@as(u32, 2), world.singleton_resources.count());
}
