//! M1.0.5 E2 — runtime loader `.scene.bin` → ECS `World` round-trip.
//!
//! Builds a cooked scene image in memory via the M1.0.4 `writer` (no `.scene.etch`
//! authoring, no filesystem), loads it with `scene.loader.loadFromBytes`, and
//! asserts the three E2 invariants:
//!   T1 — every entity is instantiated and its component bytes survive verbatim;
//!   T2 — `on_spawned` fires exactly once per loaded entity;
//!   T3 — every loaded entity exists before any `on_spawned` fires (two-phase).
//!
//! `weld_core` only — the loader and writer are both Tier 0.

const std = @import("std");
const weld_core = @import("weld_core");

const ecs = weld_core.ecs;
const scene = weld_core.scene;
const World = ecs.World;
const EntityId = ecs.EntityId;
const ComponentId = ecs.ComponentId;
const CommandBuffer = ecs.CommandBuffer;
const format = scene.format;
const writer = scene.writer;
const loader = scene.loader;

const n_entities = 3;

fn uuidFor(i: u32) [16]u8 {
    var u = [_]u8{0} ** 16;
    std.mem.writeInt(u32, u[0..4], i + 1, .little); // +1 so entity 0 ≠ all-zero
    return u;
}

// Per-entity component values, recomputed on the assert side (the source of truth).
fn posX(i: usize) f32 {
    return @floatFromInt(i);
}
fn posY(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) + 0.25;
}
fn velX(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) * 10.0;
}
fn velY(i: usize) f32 {
    return -@as(f32, @floatFromInt(i));
}

fn writeF32(buf: []u8, off: usize, v: f32) void {
    std.mem.writeInt(u32, buf[off..][0..4], @bitCast(v), .little);
}
fn readF32(buf: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
}

/// Register `Pos`/`Vel` (both `[2]f32`, size 8, align 4) into `world.registry`
/// and cook a single `[Pos, Vel]` archetype of `n_entities` entities. Returns
/// the caller-owned `.scene.bin` bytes.
fn cookPosVelScene(gpa: std.mem.Allocator, world: *World) ![]u8 {
    const pos = try world.registry.registerComponentRaw(gpa, .{
        .name = "Pos",
        .size = 8,
        .alignment = 4,
        .default_bytes = &[_]u8{0} ** 8,
        .fields = &.{},
    });
    const vel = try world.registry.registerComponentRaw(gpa, .{
        .name = "Vel",
        .size = 8,
        .alignment = 4,
        .default_bytes = &[_]u8{0} ** 8,
        .fields = &.{},
    });
    std.debug.assert(pos < vel); // column order below is sorted-ascending by id

    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "E")});
    const uuids = try a.alloc([16]u8, n_entities);
    for (0..n_entities) |i| uuids[i] = uuidFor(@intCast(i));

    const pos_col = try a.alloc(u8, 8 * n_entities);
    const vel_col = try a.alloc(u8, 8 * n_entities);
    for (0..n_entities) |i| {
        writeF32(pos_col, i * 8 + 0, posX(i));
        writeF32(pos_col, i * 8 + 4, posY(i));
        writeF32(vel_col, i * 8 + 0, velX(i));
        writeF32(vel_col, i * 8 + 4, velY(i));
    }
    const cols = try a.dupe([]u8, &.{ pos_col, vel_col });
    const ents = try a.alloc(format.EntityEntry, n_entities);
    for (0..n_entities) |i| ents[i] = .{ .name = 0, .uuid = @intCast(i), .parent_uuid = format.no_parent };
    const ids = try a.dupe(format.ComponentId, &.{ pos, vel });
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = n_entities,
        .columns = cols,
        .entities = ents,
    }});
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, &world.registry);
}

test "loading a cooked scene instantiates every entity" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const bytes = try cookPosVelScene(gpa, &world);
    defer gpa.free(bytes);

    var result = try loader.loadFromBytes(&world, gpa, bytes);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, n_entities), world.entityCount());
    try std.testing.expectEqual(@as(usize, n_entities), result.spawned.len);

    const pos_id = world.componentId("Pos").?;
    const vel_id = world.componentId("Vel").?;
    for (0..n_entities) |i| {
        // Resolve the runtime handle through the UUID map, then read storage.
        const eid = result.uuid_to_entity.get(uuidFor(@intCast(i))).?;
        const pb = world.componentBytes(eid, pos_id).?;
        try std.testing.expectApproxEqAbs(posX(i), readF32(pb, 0), 1e-6);
        try std.testing.expectApproxEqAbs(posY(i), readF32(pb, 4), 1e-6);
        const vb = world.componentBytes(eid, vel_id).?;
        try std.testing.expectApproxEqAbs(velX(i), readF32(vb, 0), 1e-6);
        try std.testing.expectApproxEqAbs(velY(i), readF32(vb, 4), 1e-6);
    }
}

// ── T2 — on_spawned fires once per loaded entity ──

const Counter = struct {
    var fired: u32 = 0;
    fn reset() void {
        fired = 0;
    }
};

fn countObserver(
    _: ?*anyopaque,
    _: *World,
    _: EntityId,
    _: ?ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: *CommandBuffer,
) anyerror!void {
    Counter.fired += 1;
}

test "on_spawned fires once per loaded entity" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    Counter.reset();
    try world.registerOnSpawned(gpa, null, &countObserver);

    const bytes = try cookPosVelScene(gpa, &world);
    defer gpa.free(bytes);

    var result = try loader.loadFromBytes(&world, gpa, bytes);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u32, n_entities), Counter.fired);
}

// ── T3 — every entity exists before any on_spawned fires ──

const FirstSeen = struct {
    var count: i64 = -1; // sentinel: not yet fired
    fn reset() void {
        count = -1;
    }
};

fn firstSeenObserver(
    _: ?*anyopaque,
    w: *World,
    _: EntityId,
    _: ?ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: *CommandBuffer,
) anyerror!void {
    if (FirstSeen.count < 0) FirstSeen.count = @intCast(w.entityCount());
}

test "all entities exist before any on_spawned fires" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    FirstSeen.reset();
    try world.registerOnSpawned(gpa, null, &firstSeenObserver);

    const bytes = try cookPosVelScene(gpa, &world);
    defer gpa.free(bytes);

    var result = try loader.loadFromBytes(&world, gpa, bytes);
    defer result.deinit(gpa);

    // At the very first on_spawned invocation, the full set was already present.
    try std.testing.expectEqual(@as(i64, n_entities), FirstSeen.count);
}

// ── loadScene(path) — the mmap entry (the byte-level core is covered above) ──

test "loadScene mmaps a cooked file and instantiates every entity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    const bytes = try cookPosVelScene(gpa, &world);
    defer gpa.free(bytes);

    // Write the image to a CWD-relative file (portable across OSes; deleted
    // after) so `loadScene` exercises the real `fs.mmapFile` path.
    const path = "weld_m105_loadscene_test.scene.bin";
    const root = std.Io.Dir.cwd();
    const f = try root.createFile(io, path, .{ .truncate = true });
    try f.writeStreamingAll(io, bytes);
    f.close(io);
    defer root.deleteFile(io, path) catch {};

    var result = try loader.loadScene(&world, gpa, path);
    defer result.deinit(gpa); // also closes the mmap

    try std.testing.expectEqual(@as(usize, n_entities), world.entityCount());
    try std.testing.expect(result.mmap != null);
    try std.testing.expectEqual(@as(usize, n_entities), result.spawned.len);
}
