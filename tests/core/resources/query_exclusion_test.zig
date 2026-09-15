//! Singleton entities stay invisible to user queries (`ARCH-006`).
const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const resources = weld_core.resources;
const ecs = weld_core.ecs;

const GameClock = extern struct {
    current_tick: u64 = 0,
};

const ConfigA = extern struct {
    setting: u32 = 0,
};

const ConfigB = extern struct {
    flag: u8 = 0,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
};

test "singleton entity is invisible to comptime query on the resource type" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 1 });

    // The dynamic comptime query path is used by the Etch codegen
    // and is the one the resource flag must hide from. Walk
    // `world.query(.{GameClock})` and confirm zero rows.
    var q = ecs.comptime_query.query(&world, .{GameClock});
    var matched: u32 = 0;
    while (q.next()) |_| matched += 1;
    try std.testing.expectEqual(@as(u32, 0), matched);
}

test "two resources of different types have two distinct singleton entities" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, ConfigA{ .setting = 1 });
    try resources.setResource(&world, gpa, ConfigB{ .flag = 2 });

    const Tid = weld_core.rtti.computeTypeId;
    const eid_a = world.singleton_resources.lookup(Tid(ConfigA)).?;
    const eid_b = world.singleton_resources.lookup(Tid(ConfigB)).?;

    // Distinct entity ids (the packed index OR generation must
    // differ — same world identity store guarantees uniqueness).
    try std.testing.expect(
        eid_a.index != eid_b.index or eid_a.generation != eid_b.generation,
    );
    try std.testing.expectEqual(@as(u32, 2), world.singleton_resources.count());
}

test "user entity carrying a same-typed component coexists with the resource" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Resource of type ConfigA.
    try resources.setResource(&world, gpa, ConfigA{ .setting = 42 });

    // User entity also carrying a ConfigA component, spawned via
    // the dynamic path (the singleton archetype `[ConfigA,
    // ResourceMarker]` differs from this user archetype
    // `[ConfigA]` thanks to the marker, so the two coexist).
    const cid = try world.ensureComponentRegistered(gpa, ConfigA);
    var user_value = ConfigA{ .setting = 7 };
    const user_bytes = std.mem.asBytes(&user_value);
    const user_eid = try world.spawnDynamicWithValues(
        gpa,
        &.{cid},
        &.{user_bytes},
    );

    // Resource still readable.
    try std.testing.expectEqual(
        @as(u32, 42),
        resources.getResource(&world, ConfigA).?.setting,
    );

    // The user entity is reachable via `world.get` (direct entity
    // access — bypasses query exclusion).
    const user_view = world.get(ConfigA, user_eid).?;
    try std.testing.expectEqual(@as(u32, 7), user_view.setting);

    // Query iteration sees the user entity exactly once.
    var q = ecs.comptime_query.query(&world, .{ConfigA});
    var matched: u32 = 0;
    while (q.next()) |row| {
        matched += 1;
        try std.testing.expectEqual(@as(u32, 7), row[0].setting);
    }
    try std.testing.expectEqual(@as(u32, 1), matched);
}

// ─── The typed path, and the order the two scans divide ───────────────────

test "a resource declared BEFORE a typed query is invisible to it" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 7 });

    var q = try world.queryFiltered(gpa, &.{GameClock}, .{});
    defer q.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), q.matchCount());
}

test "a resource declared AFTER a typed query is invisible too" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var q = try world.queryFiltered(gpa, &.{GameClock}, .{});
    defer q.deinit(gpa);
    try resources.setResource(&world, gpa, GameClock{ .current_tick = 7 });

    try std.testing.expectEqual(@as(usize, 0), q.matchCount());
}

test "a typed query still returns USER entities of the resource's own type" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 7 });
    const cid = try world.ensureComponentRegistered(gpa, GameClock);
    var user = GameClock{ .current_tick = 42 };
    _ = try world.spawnDynamicWithValues(gpa, &.{cid}, &.{std.mem.asBytes(&user)});

    var q = try world.queryFiltered(gpa, &.{GameClock}, .{});
    defer q.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), q.matchCount());
    var visited: u32 = 0;
    for (q.matches.items) |m| {
        for (m.archetype.chunks.items) |chunk| visited += chunk.entityCount();
    }
    try std.testing.expectEqual(@as(u32, 1), visited);
}

test "a singleton entity is not counted in the population the planner elects on" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const cid = try world.ensureComponentRegistered(gpa, GameClock);
    try std.testing.expectEqual(@as(usize, 0), ecs.hybrid_query.population(&world, cid));

    try resources.setResource(&world, gpa, GameClock{ .current_tick = 7 });
    try std.testing.expectEqual(@as(usize, 0), ecs.hybrid_query.population(&world, cid));

    var user = GameClock{ .current_tick = 42 };
    _ = try world.spawnDynamicWithValues(gpa, &.{cid}, &.{std.mem.asBytes(&user)});
    try std.testing.expectEqual(@as(usize, 1), ecs.hybrid_query.population(&world, cid));
}
