//! M1.B / G3 — Tier 0 routing acceptance tests.
//!
//! G3's claim is that every resolution entry and every structural mutator of
//! `World` answers for BOTH storage backends, and that a sparse component's
//! presence never enters an archetype signature. These tests are written on
//! that claim rather than on the implementation: each asserts what an entity
//! CARRIES and where it does NOT appear, and where the claim is a guard the
//! test is accompanied by a counter-factual that changes the OBJECT — the
//! storage mode of a component, the set of ids handed to an entry — and never
//! the test's own expected constant.
//!
//! Components are registered through `registerComponentRaw` rather than through
//! Etch: the routing is a Tier 0 property and mixing the front-end into its
//! tests would make an Etch regression read as a routing regression.

const std = @import("std");
const weld_core = @import("weld_core");
const World = weld_core.ecs.World;
const world_mod = weld_core.ecs.world;
const ComponentId = weld_core.ecs.ComponentId;
const StorageKind = weld_core.ecs.StorageKind;
const testing = std.testing;

const zero8 = [_]u8{0} ** 8;

/// Register a component of `size` bytes under `mode`. The mode is the ONLY
/// difference between the two registrations any test here makes, which is what
/// makes a mode-flip a legitimate counter-factual.
fn reg(
    world: *World,
    gpa: std.mem.Allocator,
    name: []const u8,
    mode: StorageKind,
) !ComponentId {
    return world.registry.registerComponentRaw(gpa, .{
        .name = name,
        .size = 8,
        .alignment = 8,
        .default_bytes = &zero8,
        .fields = &.{},
        .storage = mode,
    });
}

fn word(v: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    return b;
}

fn readWord(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

// ─── The mode's reason to exist: no migration ───────────────────────────────

test "adding a sparse component migrates nothing" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const mark = try reg(&world, gpa, "Mark", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(11)});
    const before = world.dynamicLocation(e).?;
    const pos_addr = @intFromPtr(world.componentBytes(e, pos).?.ptr);
    const arch_count_before = world.archetypeCount();

    try world.addComponentDynamic(gpa, e, mark, &word(7));

    // The entity did not move: same archetype, same chunk, same slot — and the
    // table component's bytes are at the SAME ADDRESS, which is the property a
    // migration would break and the one the mode exists to preserve. Asserting
    // the location alone would not catch a migration into an archetype that
    // happened to reuse the indices.
    const after = world.dynamicLocation(e).?;
    try testing.expectEqual(before.archetype_idx, after.archetype_idx);
    try testing.expectEqual(before.chunk_idx, after.chunk_idx);
    try testing.expectEqual(before.slot, after.slot);
    try testing.expectEqual(pos_addr, @intFromPtr(world.componentBytes(e, pos).?.ptr));
    try testing.expectEqual(@as(u64, 11), readWord(world.componentBytes(e, pos).?));

    // No archetype was created for the new signature, because there is no new
    // signature.
    try testing.expectEqual(arch_count_before, world.archetypeCount());
    try testing.expect(!world.dynamicArchetype(after.archetype_idx).hasComponent(mark));

    // And the component is nonetheless carried, with its value.
    try testing.expect(world.hasComponentDyn(e, mark));
    try testing.expectEqual(@as(u64, 7), readWord(world.componentBytes(e, mark).?));
}

test "the same add on a TABLE component does migrate — the counter-factual" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    // The ONLY change from the test above: the mode.
    const mark = try reg(&world, gpa, "Mark", .table);

    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(11)});
    const before = world.dynamicLocation(e).?;
    const arch_count_before = world.archetypeCount();

    try world.addComponentDynamic(gpa, e, mark, &word(7));

    const after = world.dynamicLocation(e).?;
    try testing.expect(before.archetype_idx != after.archetype_idx);
    try testing.expectEqual(arch_count_before + 1, world.archetypeCount());
    try testing.expect(world.dynamicArchetype(after.archetype_idx).hasComponent(mark));
}

test "removing a sparse component migrates nothing and drops the row" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const mark = try reg(&world, gpa, "Mark", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, mark }, &.{ &word(11), &word(7) });
    const before = world.dynamicLocation(e).?;
    try testing.expect(world.hasComponentDyn(e, mark));

    try world.removeComponentDynamic(gpa, e, mark);

    const after = world.dynamicLocation(e).?;
    try testing.expectEqual(before.archetype_idx, after.archetype_idx);
    try testing.expectEqual(before.slot, after.slot);
    try testing.expect(!world.hasComponentDyn(e, mark));
    try testing.expect(world.componentBytes(e, mark) == null);
    // The table neighbour is untouched — an implementation that dropped both
    // would pass every assertion above.
    try testing.expectEqual(@as(u64, 11), readWord(world.componentBytes(e, pos).?));
    try testing.expectEqual(@as(usize, 0), world.sparse_stores.getConst(mark).?.len());
}

// ─── The routed presence question ───────────────────────────────────────────

test "hasComponentDyn is total: stale handle, unknown id and absent component" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const mark = try reg(&world, gpa, "Mark", .sparse);
    const never = try reg(&world, gpa, "Never", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, mark }, &.{ &word(1), &word(2) });
    try testing.expect(world.hasComponentDyn(e, pos));
    try testing.expect(world.hasComponentDyn(e, mark));
    // Declared sparse, never populated: no store slot exists at all, and the
    // answer must still be a plain `false` rather than a fall-through to the
    // archetype that happens to say the same thing.
    try testing.expect(!world.hasComponentDyn(e, never));
    // An id past the registry's end — the bound `storageOf` re-establishes,
    // without which this call would index out of range.
    try testing.expect(!world.hasComponentDyn(e, 9999));

    try world.despawn(gpa, e);
    try testing.expect(!world.hasComponentDyn(e, pos));
    try testing.expect(!world.hasComponentDyn(e, mark));
}

test "a batched add refuses an already-present SPARSE component" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const mark = try reg(&world, gpa, "Mark", .sparse);
    const extra = try reg(&world, gpa, "Extra", .table);

    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, mark }, &.{ &word(1), &word(2) });

    // `mark` is present, in the sparse store. The archetype does not know that,
    // so the pre-G3 check would have passed and the add would have reached the
    // storage's own assert — stripped in ReleaseFast, hence a silent double
    // insert. The refusal is the guard.
    try testing.expectError(
        error.DuplicateComponent,
        world.addComponentsDynamic(gpa, e, &.{ extra, mark }, &.{ &word(3), &word(4) }),
    );

    // And the refusal is ATOMIC: `extra` did not land, and `mark` still holds
    // exactly one row with its original value.
    try testing.expect(!world.hasComponentDyn(e, extra));
    try testing.expectEqual(@as(usize, 1), world.sparse_stores.getConst(mark).?.len());
    try testing.expectEqual(@as(u64, 2), readWord(world.componentBytes(e, mark).?));
}

test "a batched add of a mixed set migrates the table half only" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const t_new = try reg(&world, gpa, "TNew", .table);
    const s_new = try reg(&world, gpa, "SNew", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(1)});
    try world.addComponentsDynamic(gpa, e, &.{ t_new, s_new }, &.{ &word(2), &word(3) });

    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    // Two components in the signature, not three.
    try testing.expectEqual(@as(usize, 2), arch.component_ids.len);
    try testing.expect(arch.hasComponent(pos));
    try testing.expect(arch.hasComponent(t_new));
    try testing.expect(!arch.hasComponent(s_new));
    // All three carried, each with its own caller-supplied bytes — which is
    // what refuses an implementation that paired payloads by position after
    // the split permuted them.
    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, pos).?));
    try testing.expectEqual(@as(u64, 2), readWord(world.componentBytes(e, t_new).?));
    try testing.expectEqual(@as(u64, 3), readWord(world.componentBytes(e, s_new).?));
}

// ─── The prepared trio ──────────────────────────────────────────────────────

test "a prepared remove keeps the sparse row readable until commit" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const t_go = try reg(&world, gpa, "TGo", .table);
    const s_go = try reg(&world, gpa, "SGo", .sparse);

    const e = try world.spawnDynamicWithValues(
        gpa,
        &.{ pos, t_go, s_go },
        &.{ &word(1), &word(2), &word(3) },
    );

    const prepared = try world.prepareRemoveComponentsDynamic(gpa, e, &.{ t_go, s_go });

    // The hook window. `loader.deactivateExtension` fires `on_detach` here, and
    // that hook may READ what is being removed: the table columns are still in
    // the source archetype, so the sparse row must still be in its store. A
    // sparse removal done in `prepare` would show the hook a half-removed
    // component, which is why this assertion is the point of the test.
    try testing.expectEqual(@as(u64, 2), readWord(world.componentBytes(e, t_go).?));
    try testing.expectEqual(@as(u64, 3), readWord(world.componentBytes(e, s_go).?));
    try testing.expect(world.hasComponentDyn(e, s_go));

    world.commitRemoveComponentsDynamic(gpa, prepared);

    try testing.expect(!world.hasComponentDyn(e, t_go));
    try testing.expect(!world.hasComponentDyn(e, s_go));
    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, pos).?));
    try testing.expectEqual(@as(usize, 0), world.sparse_stores.getConst(s_go).?.len());
}

test "an aborted prepared remove leaves the sparse row in place" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const t_go = try reg(&world, gpa, "TGo", .table);
    const s_go = try reg(&world, gpa, "SGo", .sparse);

    const e = try world.spawnDynamicWithValues(
        gpa,
        &.{ pos, t_go, s_go },
        &.{ &word(1), &word(2), &word(3) },
    );
    const before = world.dynamicLocation(e).?;

    const prepared = try world.prepareRemoveComponentsDynamic(gpa, e, &.{ t_go, s_go });
    world.abortRemoveComponentsDynamic(gpa, prepared);

    // Nothing moved and nothing was dropped, on either backend.
    const after = world.dynamicLocation(e).?;
    try testing.expectEqual(before.archetype_idx, after.archetype_idx);
    try testing.expectEqual(before.slot, after.slot);
    try testing.expect(world.hasComponentDyn(e, t_go));
    try testing.expect(world.hasComponentDyn(e, s_go));
    try testing.expectEqual(@as(u64, 3), readWord(world.componentBytes(e, s_go).?));
}

test "a prepared remove of a sparse-only set builds no new signature" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const s_go = try reg(&world, gpa, "SGo", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, s_go }, &.{ &word(1), &word(3) });
    const arch_before = world.dynamicLocation(e).?.archetype_idx;

    // `src_len - cids.len` would have been `1 - 1 == 0` here and produced the
    // EMPTY archetype — a wrong answer that only became expressible once G2
    // made the empty archetype legal. The partition is what keeps the target
    // equal to the source.
    try world.removeComponentsDynamic(gpa, e, &.{s_go});

    try testing.expectEqual(arch_before, world.dynamicLocation(e).?.archetype_idx);
    try testing.expect(world.dynamicArchetype(arch_before).hasComponent(pos));
    try testing.expect(!world.hasComponentDyn(e, s_go));
}

test "a prepared remove refuses an absent sparse component by name, not by shape" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const s_absent = try reg(&world, gpa, "SAbsent", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(1)});

    try testing.expectError(
        error.UnknownComponent,
        world.removeComponentsDynamic(gpa, e, &.{s_absent}),
    );
    // The complement: a PRESENT sparse component is accepted. Without this the
    // test above would pass an implementation that refuses every sparse drop —
    // the right error for the wrong reason, which is the harder kind to find.
    try world.addComponentDynamic(gpa, e, s_absent, &word(5));
    try world.removeComponentsDynamic(gpa, e, &.{s_absent});
    try testing.expect(!world.hasComponentDyn(e, s_absent));
}

// ─── Despawn, change marking, tags ──────────────────────────────────────────

test "despawn sweeps every sparse store, and a recycled index inherits nothing" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const a = try reg(&world, gpa, "A", .sparse);
    const b = try reg(&world, gpa, "B", .sparse);

    const e = try world.spawnDynamicWithValues(
        gpa,
        &.{ pos, a, b },
        &.{ &word(1), &word(2), &word(3) },
    );
    try testing.expectEqual(@as(usize, 1), world.sparse_stores.getConst(a).?.len());
    try testing.expectEqual(@as(usize, 1), world.sparse_stores.getConst(b).?.len());

    try world.despawn(gpa, e);
    // BOTH stores swept, not just the first.
    try testing.expectEqual(@as(usize, 0), world.sparse_stores.getConst(a).?.len());
    try testing.expectEqual(@as(usize, 0), world.sparse_stores.getConst(b).?.len());

    // The identity store recycles indices LIFO, so the next spawn reuses `e`'s
    // slot index with a bumped generation, and it must carry nothing.
    //
    // This half does NOT discriminate the sweep's position relative to
    // `identity.release` — measured, the suite stays green with the two
    // swapped, because `positionOf` checks the store's own stored handle rather
    // than the identity store. What it does establish is that a recycled index
    // is clean, which is the property a sparse set's `absent` sentinel could
    // plausibly get wrong on its own.
    const e2 = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(9)});
    try testing.expectEqual(e.index, e2.index);
    try testing.expect(e.generation != e2.generation);
    try testing.expect(!world.hasComponentDyn(e2, a));
    try testing.expect(!world.hasComponentDyn(e2, b));
}

test "markComponentChangedDyn reaches a sparse component" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const mark = try reg(&world, gpa, "Mark", .sparse);
    const pos = try reg(&world, gpa, "Pos", .table);

    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, mark }, &.{ &word(1), &word(2) });
    const at_spawn = world.sparse_stores.getConst(mark).?.changedTick(e).?;

    world.beginFrame();
    world.beginFrame();
    world.markComponentChangedDyn(e, mark);

    const after = world.sparse_stores.getConst(mark).?.changedTick(e).?;
    // The entry returns `void`, so a lost mark has NO diagnostic anywhere —
    // which is why the stamp is asserted to have moved rather than merely to
    // exist. The two `beginFrame`s are what make the two ticks distinguishable.
    try testing.expect(after != at_spawn);
    try testing.expectEqual(world.current_tick, after);
}

test "componentBytes does not stamp a sparse component as changed" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const mark = try reg(&world, gpa, "Mark", .sparse);
    const e = try world.spawnDynamicWithValues(gpa, &.{mark}, &.{&word(2)});
    const at_spawn = world.sparse_stores.getConst(mark).?.changedTick(e).?;

    world.beginFrame();
    world.beginFrame();
    _ = world.componentBytes(e, mark).?;

    // `observers.zig` reads through this entry to build its payloads. If it
    // stamped, every observer dispatch would register as a mutation of the
    // component it reports on, and a `Changed<T>` filter would see a change
    // nobody made. The table arm does not stamp either.
    try testing.expectEqual(at_spawn, world.sparse_stores.getConst(mark).?.changedTick(e).?);
}

test "a tag mutation sets AND clears a bit through the routed entry" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `TagSet`-shaped component, registered SPARSE. The engine injects its
    // real `TagSet` as table today and no `@storage` annotation can reach it,
    // so this exercises the routing rather than a reachable authoring state —
    // which is the point: `applyTagMutation` reaches the archetype IN PLACE and
    // is therefore not among the archetype funnel's callers, so an enumeration
    // of that funnel does not find it.
    const tagset = try reg(&world, gpa, "TagSet", .sparse);
    const e = try world.spawnDynamic(gpa, &.{});

    try world.applyTagMutation(gpa, e, tagset, 3, true);
    try testing.expect(world.hasComponentDyn(e, tagset));
    try testing.expectEqual(@as(u64, 1) << 3, readWord(world.componentBytes(e, tagset).?));

    // Setting a SECOND bit must flip it in place, not double-add the row.
    try world.applyTagMutation(gpa, e, tagset, 5, true);
    try testing.expectEqual(@as(usize, 1), world.sparse_stores.getConst(tagset).?.len());
    try testing.expectEqual((@as(u64, 1) << 3) | (@as(u64, 1) << 5), readWord(world.componentBytes(e, tagset).?));

    // And clearing must reach the row. The pre-G3 body fell into `else if
    // (set)` with `set == false` and did NOTHING — a silent no-op, the failure
    // mode this assertion exists for.
    try world.applyTagMutation(gpa, e, tagset, 3, false);
    try testing.expectEqual(@as(u64, 1) << 5, readWord(world.componentBytes(e, tagset).?));
}

// ─── Reserve-then-mutate, at the World level ────────────────────────────────

test "a failed multi-sparse spawn leaves no half-populated entity" {
    // `SparseSetStorage.add` is reserve-then-mutate per store (G2 invariant 7),
    // which says nothing about a spawn that populates THREE of them: a failure
    // on the third would leave the first two committed, and a half-populated
    // entity is exactly the observable mutation the invariant forbids. The
    // World-level unwind is what this sweeps.
    //
    // Apparatus: `std.testing.FailingAllocator`, the instrument `world.zig`
    // already uses for the sibling "spawn OOM leaves no orphan identity" sweep
    // — deliberately NOT `sparse_storage.zig`'s private `OneShotFail`, which
    // fails only `alloc` because a storage-level sweep must not count the
    // in-place `resize` a list retries around. Here a resize refusal the world
    // recovers from is a legitimate outcome, so the assertions are conditional
    // on an error actually surfacing, and `induced` is what keeps the sweep
    // from passing by never entering that branch.
    const gpa = testing.allocator;

    const pass1 = blk: {
        var w = World.init();
        defer w.deinit(gpa);
        _ = try reg(&w, gpa, "T", .table);
        _ = try reg(&w, gpa, "A", .sparse);
        _ = try reg(&w, gpa, "B", .sparse);
        _ = try reg(&w, gpa, "C", .sparse);
        var counting = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
        _ = try w.spawnDynamicWithValues(
            counting.allocator(),
            &.{ 0, 1, 2, 3 },
            &.{ &word(1), &word(2), &word(3), &word(4) },
        );
        break :blk counting.alloc_index;
    };
    try testing.expect(pass1 > 0);

    var induced: usize = 0;
    var fail_at: usize = 0;
    while (fail_at < pass1) : (fail_at += 1) {
        var w = World.init();
        defer w.deinit(gpa);
        // Registration runs on the real allocator: the sweep is about the
        // spawn, and letting a registration fail would measure a different
        // entry under this test's name.
        const t = try reg(&w, gpa, "T", .table);
        const a = try reg(&w, gpa, "A", .sparse);
        const b = try reg(&w, gpa, "B", .sparse);
        const c = try reg(&w, gpa, "C", .sparse);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_at });
        const fa = failing.allocator();
        const result = w.spawnDynamicWithValues(
            fa,
            &.{ t, a, b, c },
            &.{ &word(1), &word(2), &word(3), &word(4) },
        );

        if (result) |e| {
            // Succeeded despite the armed index — a resize the list recovered
            // from. The entity must be WHOLE.
            try testing.expect(w.hasComponentDyn(e, t));
            try testing.expect(w.hasComponentDyn(e, a));
            try testing.expect(w.hasComponentDyn(e, b));
            try testing.expect(w.hasComponentDyn(e, c));
        } else |_| {
            induced += 1;
            // No entity, and not one row anywhere. Asserting `entityCount`
            // alone would miss a sparse row left behind by a spawn that never
            // registered a location — which is precisely the leak the
            // World-level unwind exists to prevent, and the one a per-store
            // invariant cannot see.
            try testing.expectEqual(@as(usize, 0), w.entityCount());
            try testing.expectEqual(@as(usize, 0), w.identity.liveCount());
            for ([_]ComponentId{ a, b, c }) |cid| {
                if (w.sparse_stores.getConst(cid)) |store| {
                    try testing.expectEqual(@as(usize, 0), store.len());
                }
            }
        }
    }
    // Non-vacuity: at least one index really did make the spawn fail.
    try testing.expect(induced > 0);
}

// ─── The empty archetype, and what an all-negative query may see ────────────

test "an all-negative dynamic query matches the empty archetype" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const frozen = try reg(&world, gpa, "Frozen", .table);

    // An entity with NO table component — legal since G2 — and one with a
    // component the query excludes.
    const bare = try world.spawnDynamic(gpa, &.{});
    const carrier = try world.spawnDynamicWithValues(gpa, &.{frozen}, &.{&word(1)});
    const bare_arch = world.dynamicLocation(bare).?.archetype_idx;
    const carrier_arch = world.dynamicLocation(carrier).?.archetype_idx;
    try testing.expectEqual(@as(usize, 0), world.dynamicArchetype(bare_arch).component_ids.len);

    // `archetypeMatches` falls through to `true` when required and with are
    // both empty, so an all-negative term matches an archetype carrying
    // nothing. That was unreachable before G2 — the empty archetype could not
    // exist — and it is a PERMISSION rather than a defect: an entity that
    // carries no `Frozen` genuinely satisfies `without Frozen`.
    var dq = try world.queryDynamic(gpa, &.{}, &.{frozen});
    defer dq.deinit(gpa);
    _ = dq.maybeRescan();

    var saw_bare = false;
    var saw_carrier = false;
    for (dq.matching.items) |arch| {
        if (arch.archetype_id == bare_arch) saw_bare = true;
        if (arch.archetype_id == carrier_arch) saw_carrier = true;
    }
    try testing.expect(saw_bare);
    // And the exclusion still bites, which is what makes the line above a
    // permission and not a claim that the query matches everything.
    try testing.expect(!saw_carrier);

    // A query with a non-empty with-set does NOT match it — the complement,
    // without which "matches the empty archetype" would read as "matches
    // unconditionally".
    var dq2 = try world.queryDynamic(gpa, &.{pos}, &.{});
    defer dq2.deinit(gpa);
    _ = dq2.maybeRescan();
    for (dq2.matching.items) |arch| {
        try testing.expect(arch.archetype_id != bare_arch);
    }
}

test "an entity carrying ONLY sparse components lives in the empty archetype" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const a = try reg(&world, gpa, "A", .sparse);
    const b = try reg(&world, gpa, "B", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{ a, b }, &.{ &word(1), &word(2) });

    // Backs the contract written on `dynamicLocation`: it never returns null
    // for a live handle, sparse-only entities included, because the table half
    // of the split is EMPTY and the empty archetype is legal since G2. Before
    // that, this spawn had no destination at all.
    const loc = world.dynamicLocation(e) orelse return error.SparseOnlyEntityHasNoLocation;
    try testing.expectEqual(@as(usize, 0), world.dynamicArchetype(loc.archetype_idx).component_ids.len);
    try testing.expect(world.isLive(e));

    // Both components are carried and readable, and both survive a despawn of
    // a SECOND sparse-only entity sharing the same empty archetype — the swap
    // in that archetype has no columns to move, which is the case a zero-column
    // `removeSwap` could plausibly get wrong.
    const e2 = try world.spawnDynamicWithValues(gpa, &.{a}, &.{&word(3)});
    try testing.expectEqual(loc.archetype_idx, world.dynamicLocation(e2).?.archetype_idx);
    try world.despawn(gpa, e2);

    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, a).?));
    try testing.expectEqual(@as(u64, 2), readWord(world.componentBytes(e, b).?));
    try testing.expect(world.dynamicLocation(e) != null);
}
