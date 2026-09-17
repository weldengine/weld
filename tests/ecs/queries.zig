//! Extended comptime queries: the `With` / `Without` archetype filters, the
//! per-slot `Predicate`, the archetype → chunk → slot iteration order, the lazy
//! re-scan that absorbs an archetype created after construction, and the
//! `ComponentId`-keyed dynamic path the interpreter drives.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.entity.EntityId;
const Chunk = weld_core.ecs.world.Chunk;
const Archetype = weld_core.ecs.world.Archetype;

const query_mod = weld_core.ecs.query;
const With = query_mod.With;
const Without = query_mod.Without;
const Predicate = query_mod.Predicate;
const DynamicQuery = weld_core.ecs.world.DynamicQuery;
const ComponentId = weld_core.ecs.registry.ComponentId;

// Test-only POD components. Distinct sizes / fields so the predicate
// below can pick out the right column by `componentIndex` against the
// world's runtime registry.
const Health = extern struct {
    current: f32 = 100,
    max: f32 = 100,
};
const Marker = extern struct {
    kind: u32 = 0,
};
const Frozen = extern struct {
    _stamp: u8 = 1,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

test "With filter matches only archetypes containing all required components" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Three entities:
    //   a — (Transform, Velocity)
    //   b — (Transform, Velocity, Marker)
    //   c — (Transform, Velocity, Marker, Health)
    const a = try world.spawn(gpa, Transform{}, Velocity{});
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, b, Marker, .{ .kind = 1 });
    const c = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, c, Marker, .{ .kind = 2 });
    try world.addComponent(gpa, c, Health, .{});

    var q = try world.queryFiltered(gpa, &.{Transform}, .{With(Marker)});
    defer q.deinit(gpa);

    // Two matching archetypes: (T,V,Marker) and (T,V,Marker,Health).
    try std.testing.expectEqual(@as(usize, 2), q.matchCount());

    var visited: u32 = 0;
    for (q.matches.items) |m| {
        for (m.archetype.chunks.items) |chunk| {
            visited += chunk.entityCount();
        }
    }
    try std.testing.expectEqual(@as(u32, 2), visited);

    // `a` never moved into a Marker archetype.
    try std.testing.expect(q.matchFor(world.archetypes.items[world.dynamicLocation(a).?.archetype_idx].chunks.items[0]) == null);
    const b_chunk = world.archetypes.items[world.dynamicLocation(b).?.archetype_idx].chunks.items[0];
    try std.testing.expect(q.matchFor(b_chunk) != null);
    const c_chunk = world.archetypes.items[world.dynamicLocation(c).?.archetype_idx].chunks.items[0];
    try std.testing.expect(q.matchFor(c_chunk) != null);
}

test "Without filter excludes archetypes containing the listed components" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Three entities, structured so addComponent does not leave any
    // empty intermediate archetypes behind:
    //   a — stays in (Transform, Velocity)
    //   b — migrates to (Transform, Velocity, Frozen)
    //   c — also migrates to (Transform, Velocity, Frozen), reusing
    //        b's destination archetype (no extra empty archetype)
    const a = try world.spawn(gpa, Transform{}, Velocity{});
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, b, Frozen, .{});
    const c = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, c, Frozen, .{});

    try std.testing.expectEqual(@as(usize, 2), world.archetypeCount());

    var q = try world.queryFiltered(gpa, &.{Transform}, .{Without(Frozen)});
    defer q.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), q.matchCount());

    var visited: u32 = 0;
    for (q.matches.items) |m| {
        for (m.archetype.chunks.items) |chunk| {
            visited += chunk.entityCount();
        }
    }
    try std.testing.expectEqual(@as(u32, 1), visited);

    const a_arch = world.archetypes.items[world.dynamicLocation(a).?.archetype_idx];
    try std.testing.expect(q.matchFor(a_arch.chunks.items[0]) != null);
    const b_arch = world.archetypes.items[world.dynamicLocation(b).?.archetype_idx];
    try std.testing.expect(q.matchFor(b_arch.chunks.items[0]) == null);
    const c_arch = world.archetypes.items[world.dynamicLocation(c).?.archetype_idx];
    try std.testing.expect(q.matchFor(c_arch.chunks.items[0]) == null);
}

// File-scope mutable so the comptime-bound predicate can recover the runtime
// Health `ComponentId` — there is no component-id-by-name lookup to reach it
// with. Reset at the start of every test that uses the predicate.
var test_health_component_id: u32 = std.math.maxInt(u32);

fn aliveHealthPredicate(arch: *const Archetype, chunk: *Chunk, slot: u32) bool {
    const idx = arch.componentIndex(test_health_component_id) orelse return true;
    const bytes = arch.componentSlot(chunk, idx, slot);
    const h: *const Health = @ptrCast(@alignCast(bytes.ptr));
    return h.current > 0;
}

const PredicateCounter = struct {
    counted: u32 = 0,
};

fn countAlive(chunk: *Chunk, q: *const query_mod.Query(&.{Health}, .{Predicate(aliveHealthPredicate)}), counter: *PredicateCounter) void {
    const arch = q.matchFor(chunk).?.archetype;
    const count = chunk.entityCount();
    var slot: u32 = 0;
    while (slot < count) : (slot += 1) {
        if (q.slotPasses(arch, chunk, slot)) counter.counted += 1;
    }
}

test "Predicate filter is applied per-entity within matched archetypes" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Two entities have Health; one with current > 0 (alive), one with
    // current == 0 (dead). The predicate keeps only the alive one.
    const alive = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, alive, Health, .{ .current = 25, .max = 100 });
    const dead = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, dead, Health, .{ .current = 0, .max = 100 });

    test_health_component_id = world.componentId(@typeName(Health)).?;

    var q = try world.queryFiltered(gpa, &.{Health}, .{Predicate(aliveHealthPredicate)});
    defer q.deinit(gpa);

    // Both entities land in the same (T,V,Health) archetype — exactly
    // one archetype matches the query.
    try std.testing.expectEqual(@as(usize, 1), q.matchCount());

    var counter: PredicateCounter = .{};
    q.forEachChunk(countAlive, .{ &q, &counter });

    try std.testing.expectEqual(@as(u32, 1), counter.counted);
}

const VisitLog = struct {
    visits: std.ArrayListUnmanaged(VisitRecord) = .empty,

    const VisitRecord = struct {
        archetype_idx: u32,
        chunk_idx_in_archetype: u32,
        entity_id: EntityId,
    };

    fn deinit(self: *VisitLog, gpa: std.mem.Allocator) void {
        self.visits.deinit(gpa);
    }
};

fn logVisits(chunk: *Chunk, q: *const query_mod.Query(&.{Transform}, .{}), log: *VisitLog, gpa: std.mem.Allocator) !void {
    const m = q.matchFor(chunk).?;
    const arch = m.archetype;
    // Recover the chunk's index inside its archetype by walking the
    // archetype's chunk list (no other surface gives us this index).
    var chunk_idx: u32 = 0;
    for (arch.chunks.items, 0..) |c, i| {
        if (c == chunk) {
            chunk_idx = @intCast(i);
            break;
        }
    }
    const ids = arch.entityIdsConst(chunk);
    const count = chunk.entityCount();
    var slot: u32 = 0;
    while (slot < count) : (slot += 1) {
        try log.visits.append(gpa, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx_in_archetype = chunk_idx,
            .entity_id = ids[slot],
        });
    }
}

test "query iteration order is archetype then chunk then slot" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Two archetypes:
    //   A — (Transform, Velocity) — spawned first
    //   B — (Transform, Velocity, Marker) — spawned second (via addComponent)
    //
    // Each archetype must hold enough entities to span 2 chunks. The
    // (Transform, Velocity) chunk capacity is ~185 entities, so 250
    // forces 2 chunks; the (T,V,Marker) chunk capacity is similar.
    const per_archetype: u32 = 250;

    var ids_a: std.ArrayListUnmanaged(EntityId) = .empty;
    defer ids_a.deinit(gpa);
    var i: u32 = 0;
    while (i < per_archetype) : (i += 1) {
        const e = try world.spawn(gpa, Transform{}, Velocity{});
        try ids_a.append(gpa, e);
    }

    var ids_b: std.ArrayListUnmanaged(EntityId) = .empty;
    defer ids_b.deinit(gpa);
    i = 0;
    while (i < per_archetype) : (i += 1) {
        const e = try world.spawn(gpa, Transform{}, Velocity{});
        try world.addComponent(gpa, e, Marker, .{});
        try ids_b.append(gpa, e);
    }

    var q = try world.queryFiltered(gpa, &.{Transform}, .{});
    defer q.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), q.matchCount());
    try std.testing.expect(q.matches.items[0].archetype.chunkCount() >= 2);
    try std.testing.expect(q.matches.items[1].archetype.chunkCount() >= 2);

    var log: VisitLog = .{};
    defer log.deinit(gpa);

    for (q.matches.items) |m| {
        for (m.archetype.chunks.items) |chunk| {
            try logVisits(chunk, &q, &log, gpa);
        }
    }

    // The match order is (A, B) — A was the first archetype created.
    const arch_a = q.matches.items[0].archetype.archetype_id;
    const arch_b = q.matches.items[1].archetype.archetype_id;
    try std.testing.expect(arch_a != arch_b);

    // Verify the strict ordering invariant: visit[i].archetype is
    // monotonic non-decreasing, visit[i].chunk_idx is monotonic
    // non-decreasing within an archetype, and the entity-id sequence
    // matches the spawn order.
    try std.testing.expectEqual(@as(usize, per_archetype * 2), log.visits.items.len);

    var idx: usize = 0;
    var slot_within_arch: u32 = 0;
    // First half: archetype A, entities spawned 0..per_archetype.
    while (idx < per_archetype) : (idx += 1) {
        const v = log.visits.items[idx];
        try std.testing.expectEqual(arch_a, v.archetype_idx);
        try std.testing.expectEqual(ids_a.items[slot_within_arch], v.entity_id);
        slot_within_arch += 1;
    }
    // Second half: archetype B, entities spawned per_archetype..2*per_archetype.
    slot_within_arch = 0;
    while (idx < per_archetype * 2) : (idx += 1) {
        const v = log.visits.items[idx];
        try std.testing.expectEqual(arch_b, v.archetype_idx);
        try std.testing.expectEqual(ids_b.items[slot_within_arch], v.entity_id);
        slot_within_arch += 1;
    }

    // Within each archetype, the chunk index is monotonic.
    var prev_arch: u32 = log.visits.items[0].archetype_idx;
    var prev_chunk: u32 = log.visits.items[0].chunk_idx_in_archetype;
    for (log.visits.items[1..]) |v| {
        if (v.archetype_idx == prev_arch) {
            try std.testing.expect(v.chunk_idx_in_archetype >= prev_chunk);
        } else {
            // Crossing to a new archetype resets chunk monotonicity.
            prev_arch = v.archetype_idx;
            prev_chunk = 0;
        }
        prev_chunk = v.chunk_idx_in_archetype;
    }
}

const command_buffer_mod = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer_mod.CommandBuffer;

// A query built BEFORE a command-buffer flush materialises a new archetype must
// observe it on the next iteration entry, with no explicit rebuild.
test "new archetype created during command buffer flush is visible to existing queries on next dispatch" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Initial state — one (Transform, Velocity) entity. Marker is
    // not yet attached, so the (T, V, Marker) archetype does not
    // exist at query construction time.
    _ = try world.spawn(gpa, Transform{}, Velocity{});

    var q = try world.queryFiltered(gpa, &.{Transform}, .{With(Marker)});
    defer q.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), q.matchCount());
    try std.testing.expectEqual(@as(usize, 0), q.chunkCount());

    // Stage a spawn that materialises a new (Transform, Velocity,
    // Marker) archetype via a deferred command. The world's entity
    // count stays unchanged until `cmd.flush()`.
    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();
    try cmd.spawn(.{
        Transform{},
        Velocity{},
        Marker{ .kind = 42 },
    });

    const before = world.archetypeCount();
    try std.testing.expectEqual(@as(usize, 0), q.chunkCount());

    try cmd.flush(&world);
    try std.testing.expect(world.archetypeCount() > before);

    // Now the next iteration entry on `q` must see the new archetype
    // even though the query was constructed BEFORE the flush
    // materialised it. This is the lazy re-scan contract.
    try std.testing.expectEqual(@as(usize, 1), q.matchCount());
    try std.testing.expectEqual(@as(usize, 1), q.chunkCount());
}

// The Etch interpreter holds resolved `ComponentId`s, not Zig types, so it
// drives rule selection through `World.queryDynamic` rather than the comptime
// `queryFiltered`. These two tests pin the contract the interpreter relies on:
// (1) the dynamic path returns the SAME archetype set as the equivalent
// comptime `Query` — proving the two paths share `archetypeMatches`; and
// (2) the dynamic path absorbs archetypes created after its first iteration —
// proving it reuses the same option-β lazy re-scan (`rescanNewArchetypes`).

test "dynamic query matches comptime query" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A spread of archetypes around the (Marker present, Frozen absent) term:
    //   a — (T, V)                    ← no Marker
    //   b — (T, V, Marker)            ← MATCH
    //   c — (T, V, Marker, Health)    ← MATCH
    //   d — (T, V, Marker, Frozen)    ← excluded by Without(Frozen)
    //   e — (T, V, Frozen)            ← excluded (no Marker)
    _ = try world.spawn(gpa, Transform{}, Velocity{});
    const b = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, b, Marker, .{ .kind = 1 });
    const c = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, c, Marker, .{ .kind = 2 });
    try world.addComponent(gpa, c, Health, .{});
    const d = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, d, Marker, .{ .kind = 3 });
    try world.addComponent(gpa, d, Frozen, .{});
    const e = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e, Frozen, .{});

    // Comptime reference: Query(.{Transform}, .{With(Marker), Without(Frozen)}).
    var cq = try world.queryFiltered(gpa, &.{Transform}, .{ With(Marker), Without(Frozen) });
    defer cq.deinit(gpa);

    // Dynamic equivalent, by ComponentId. `required` folds into `with`
    // (archetypeMatches treats them identically), so the with-set is
    // {Transform, Marker}, the without-set is {Frozen}.
    const t_id = try world.ensureComponentRegistered(gpa, Transform);
    const m_id = try world.ensureComponentRegistered(gpa, Marker);
    const f_id = try world.ensureComponentRegistered(gpa, Frozen);
    var dq = try world.queryDynamic(gpa, &.{ t_id, m_id }, &.{f_id});
    defer dq.deinit(gpa);

    var cq_ids: std.ArrayListUnmanaged(u32) = .empty;
    defer cq_ids.deinit(gpa);
    for (cq.matches.items) |m| try cq_ids.append(gpa, m.archetype.archetype_id);

    _ = dq.maybeRescan(); // initial full scan
    var dq_ids: std.ArrayListUnmanaged(u32) = .empty;
    defer dq_ids.deinit(gpa);
    for (dq.matching.items) |arch| try dq_ids.append(gpa, arch.archetype_id);

    std.mem.sort(u32, cq_ids.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, dq_ids.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, cq_ids.items, dq_ids.items);
    // Exactly b's and c's archetypes match.
    try std.testing.expectEqual(@as(usize, 2), dq_ids.items.len);
}

test "dynamic query lazy rescan" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Only a (Transform, Velocity) entity exists — no Marker carrier yet.
    _ = try world.spawn(gpa, Transform{}, Velocity{});

    const t_id = try world.ensureComponentRegistered(gpa, Transform);
    const m_id = try world.ensureComponentRegistered(gpa, Marker);
    var dq = try world.queryDynamic(gpa, &.{ t_id, m_id }, &.{});
    defer dq.deinit(gpa);

    const first_scanned = dq.maybeRescan();
    try std.testing.expect(first_scanned > 0); // scanned the existing (T,V) archetype
    try std.testing.expectEqual(@as(usize, 0), dq.matching.items.len);

    // Materialise a (T, V, Marker) archetype AFTER the first iteration.
    const e = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, e, Marker, .{ .kind = 7 });

    // The next rescan scans only the tail and picks up the new archetype —
    // the same option-β contract the comptime Query satisfies above.
    const second_scanned = dq.maybeRescan();
    try std.testing.expect(second_scanned > 0);
    try std.testing.expectEqual(@as(usize, 1), dq.matching.items.len);

    // Steady state: no new archetypes → no scan, set unchanged.
    try std.testing.expectEqual(@as(usize, 0), dq.maybeRescan());
    try std.testing.expectEqual(@as(usize, 1), dq.matching.items.len);
}
