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

    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
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

    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
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

    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
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

    var result = try loader.loadScene(&world, gpa, path, null);
    defer result.deinit(gpa); // also closes the mmap

    try std.testing.expectEqual(@as(usize, n_entities), world.entityCount());
    try std.testing.expect(result.mmap != null);
    try std.testing.expectEqual(@as(usize, n_entities), result.spawned.len);
}

// ─── M1.B / G6 — hybrid storage through the scene loader ────────────────────
//
// The codec is NOT reopened and needs no change: the storage mode is a RUNTIME
// REGISTRY property and never part of on-disk identity, and the loader does not
// write column by column — it walks the blocks and INSTANTIATES ENTITY BY
// ENTITY, handing `World.spawnDynamicWithValues` the block's full ComponentId
// set plus each column's byte view at that entity's rank. That surface has been
// bimodal since G3, so the bifurcation is entirely in the spawn path.
//
// `engine-scene-serialization.md` §4, rectified 2026-09-03: "C'est le `World`
// qui place les octets, et c'est ce qui rend le second mode de stockage
// réalisable sans rouvrir ce codec."

/// Same two-column scene as `cookPosVelScene`, with `Vel` declared SPARSE. The
/// on-disk bytes are IDENTICAL in shape — only the registry entry differs, which
/// is the whole claim.
fn cookPosVelScene2(gpa: std.mem.Allocator, world: *World, vel_mode: ecs.StorageKind) ![]u8 {
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
        .storage = vel_mode,
    });
    std.debug.assert(pos < vel);

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

test "G6: a cooked scene loads a SPARSE component into its own store" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const bytes = try cookPosVelScene2(gpa, &world, .sparse);
    defer gpa.free(bytes);

    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, n_entities), world.entityCount());
    const pos_id = world.componentId("Pos").?;
    const vel_id = world.componentId("Vel").?;

    for (0..n_entities) |i| {
        const eid = result.uuid_to_entity.get(uuidFor(@intCast(i))).?;
        // Both components carried, both with their cooked values — the sparse
        // one through its store, the table one through its column.
        try std.testing.expect(world.hasComponentDyn(eid, pos_id));
        try std.testing.expect(world.hasComponentDyn(eid, vel_id));
        const pb = world.componentBytes(eid, pos_id).?;
        try std.testing.expectApproxEqAbs(posX(i), readF32(pb, 0), 1e-6);
        try std.testing.expectApproxEqAbs(posY(i), readF32(pb, 4), 1e-6);
        const vb = world.componentBytes(eid, vel_id).?;
        try std.testing.expectApproxEqAbs(velX(i), readF32(vb, 0), 1e-6);
        try std.testing.expectApproxEqAbs(velY(i), readF32(vb, 4), 1e-6);

        // And `Vel` is NOT in the archetype signature: the block named it, and
        // the spawn surface routed it away. The on-disk block is unchanged.
        const arch = world.dynamicArchetype(world.dynamicLocation(eid).?.archetype_idx);
        try std.testing.expect(arch.hasComponent(pos_id));
        try std.testing.expect(!arch.hasComponent(vel_id));
    }
    try std.testing.expectEqual(@as(usize, n_entities), world.sparse_stores.getConst(vel_id).?.len());
}

test "G6: the SAME cooked bytes give the same values under either mode" {
    // The counter-factual is the REGISTRY and nothing else: same cook function,
    // same column bytes, same UUIDs — only `Vel`'s declared mode differs. This
    // is what establishes that the on-disk identity does not carry the mode,
    // rather than asserting it.
    const gpa = std.testing.allocator;

    var w_table = World.init();
    defer w_table.deinit(gpa);
    const b_table = try cookPosVelScene2(gpa, &w_table, .table);
    defer gpa.free(b_table);

    var w_sparse = World.init();
    defer w_sparse.deinit(gpa);
    const b_sparse = try cookPosVelScene2(gpa, &w_sparse, .sparse);
    defer gpa.free(b_sparse);

    // The COOKED BYTES are identical: the writer never saw a storage mode.
    try std.testing.expectEqualSlices(u8, b_table, b_sparse);

    var r_table = try loader.loadFromBytes(&w_table, gpa, b_table, null);
    defer r_table.deinit(gpa);
    var r_sparse = try loader.loadFromBytes(&w_sparse, gpa, b_sparse, null);
    defer r_sparse.deinit(gpa);

    const vt = w_table.componentId("Vel").?;
    const vs = w_sparse.componentId("Vel").?;
    for (0..n_entities) |i| {
        const et = r_table.uuid_to_entity.get(uuidFor(@intCast(i))).?;
        const es = r_sparse.uuid_to_entity.get(uuidFor(@intCast(i))).?;
        try std.testing.expectEqualSlices(
            u8,
            w_table.componentBytes(et, vt).?,
            w_sparse.componentBytes(es, vs).?,
        );
    }
    // And the archetypes DIFFER, which is what makes the equality above a
    // statement about the storage and not about two identical worlds.
    const at = w_table.dynamicArchetype(w_table.dynamicLocation(r_table.spawned[0]).?.archetype_idx);
    const as_ = w_sparse.dynamicArchetype(w_sparse.dynamicLocation(r_sparse.spawned[0]).?.archetype_idx);
    try std.testing.expectEqual(@as(usize, 2), at.component_ids.len);
    try std.testing.expectEqual(@as(usize, 1), as_.component_ids.len);
}

test "G6: two blocks whose TABLE subset coincides land in one archetype" {
    // The property the corpus names: an Archetype Block is a SERIALIZATION
    // group keyed by the full on-disk signature, so two entities differing only
    // by a sparse component cook into DIFFERENT blocks — and instantiate into
    // the SAME archetype, because the spawn surface routes the sparse id away
    // before the signature is resolved. Nothing computes that; signature
    // resolution gives it.
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

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
        .storage = .sparse,
    });
    std.debug.assert(pos < vel);

    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "E")});
    const uuids = try a.alloc([16]u8, 2);
    uuids[0] = uuidFor(0);
    uuids[1] = uuidFor(1);

    // Block A: {Pos, Vel} — one entity. Block B: {Pos} — one entity.
    const a_pos = try a.alloc(u8, 8);
    const a_vel = try a.alloc(u8, 8);
    const b_pos = try a.alloc(u8, 8);
    writeF32(a_pos, 0, 1.0);
    writeF32(a_pos, 4, 2.0);
    writeF32(a_vel, 0, 3.0);
    writeF32(a_vel, 4, 4.0);
    writeF32(b_pos, 0, 5.0);
    writeF32(b_pos, 4, 6.0);

    const ent_a = try a.alloc(format.EntityEntry, 1);
    ent_a[0] = .{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent };
    const ent_b = try a.alloc(format.EntityEntry, 1);
    ent_b[0] = .{ .name = 0, .uuid = 1, .parent_uuid = format.no_parent };

    const blocks = try a.dupe(format.ArchetypeBlock, &.{
        .{
            .component_ids = try a.dupe(format.ComponentId, &.{ pos, vel }),
            .entity_count = 1,
            .columns = try a.dupe([]u8, &.{ a_pos, a_vel }),
            .entities = ent_a,
        },
        .{
            .component_ids = try a.dupe(format.ComponentId, &.{pos}),
            .entity_count = 1,
            .columns = try a.dupe([]u8, &.{b_pos}),
            .entities = ent_b,
        },
    });
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    const bytes = try writer.write(gpa, model, &world.registry);
    defer gpa.free(bytes);

    // TWO blocks on disk — the cook grouped by the FULL signature.
    {
        var acc = try scene.accessor.Accessor.open(bytes);
        try std.testing.expectEqual(@as(u32, 2), acc.archetypeCount());
    }

    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
    defer result.deinit(gpa);

    const e_a = result.uuid_to_entity.get(uuidFor(0)).?;
    const e_b = result.uuid_to_entity.get(uuidFor(1)).?;

    // ONE archetype after load — the two blocks' table subsets coincide.
    try std.testing.expectEqual(
        world.dynamicLocation(e_a).?.archetype_idx,
        world.dynamicLocation(e_b).?.archetype_idx,
    );
    // And the sparse component is carried by A alone, which is what makes the
    // shared archetype a routing result and not two identical entities.
    try std.testing.expect(world.hasComponentDyn(e_a, vel));
    try std.testing.expect(!world.hasComponentDyn(e_b, vel));
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), readF32(world.componentBytes(e_a, vel).?, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readF32(world.componentBytes(e_a, pos).?, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), readF32(world.componentBytes(e_b, pos).?, 0), 1e-6);
}
