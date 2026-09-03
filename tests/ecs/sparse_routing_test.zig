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
    // already uses for the sibling "spawn OOM leaves no orphan identity" sweep.
    //
    // Its semantics are NOT one-shot: it does not advance its index on failure,
    // so from `fail_index` onward EVERY allocation fails — the reason
    // `sparse_storage.zig` wrote its own `OneShotFail` for the storage-level
    // sweep. Here that is the right instrument anyway, because the property
    // under test is "a failure leaves NOTHING behind", not "the world recovers
    // and retries"; a permanent-failure allocator exercises it strictly harder.
    //
    // The consequence for the success branch: it is reached only when `fail_at`
    // is past the count this particular run performs, NOT because "a resize the
    // list recovered from" — an earlier version of this comment said the latter
    // and named a recovery the allocator's own semantics exclude. It stays
    // because a spawn that succeeded must still be WHOLE, and `induced` is what
    // keeps the sweep from passing by never entering the failure branch.
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
            // Succeeded because this run never reached the armed index. The
            // entity must nevertheless be WHOLE.
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

// ─── G3 review refusal — four defects, each pinned before its fix ───────────
//
// Raised by an adversarial review of the G3 diff and CONFIRMED at the code
// before anything was written here. Three of the four are G3's own doing, and
// in two of them the comment at the site asserted the opposite of what the code
// did — the exact family this gate spent itself cataloguing.

test "a batched remove of a SPARSE-ONLY set leaves the entity on a live slot" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const s_go = try reg(&world, gpa, "SGo", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, s_go }, &.{ &word(7), &word(3) });

    // When every dropped id is sparse, the target signature EQUALS the source's,
    // so `getOrCreateArchetype` returns the SAME archetype. `prepare` then
    // allocates a SECOND slot in it, `commit` copies old→new, and `removeSwap`
    // on the old slot brings that very copy back from the tail and reports our
    // own entity as the swapped one — which the `getPtr(swapped)` line records
    // correctly, right before `putAssumeCapacity` overwrites it with the slot
    // that swap just freed. The entity's recorded location then designates a
    // dead slot.
    try world.removeComponentsDynamic(gpa, e, &.{s_go});

    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    // The decisive assertion, and the one the earlier sparse-only-remove test
    // did NOT make: the slot the location points at must be the one holding
    // this entity's id. That test asserted the archetype INDEX and the absence
    // of the sparse component — both true under the corruption.
    try testing.expectEqual(e, arch.entityIds(chunk)[loc.slot]);
    try testing.expect(loc.slot < chunk.entityCount());
    try testing.expectEqual(@as(u64, 7), readWord(world.componentBytes(e, pos).?));
    try testing.expect(!world.hasComponentDyn(e, s_go));
}

test "a batched add of a SPARSE-ONLY set leaves the entity on a live slot" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const s_new = try reg(&world, gpa, "SNew", .sparse);

    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(7)});

    // Same unguarded `dst_arch == src_arch` path, reached from the other side:
    // adding only sparse ids leaves the signature unchanged.
    try world.addComponentsDynamic(gpa, e, &.{s_new}, &.{&word(3)});

    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    try testing.expectEqual(e, arch.entityIds(chunk)[loc.slot]);
    try testing.expect(loc.slot < chunk.entityCount());
    try testing.expectEqual(@as(u64, 7), readWord(world.componentBytes(e, pos).?));
    try testing.expectEqual(@as(u64, 3), readWord(world.componentBytes(e, s_new).?));
}

test "a tag mutation on a stale handle is a silent no-op, not a propagated error" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const tagset = try reg(&world, gpa, "TagSet", .table);
    const e = try world.spawnDynamic(gpa, &.{});
    try world.despawn(gpa, e);

    // The pre-G3 body opened with `entity_locations.get(entity) orelse return`,
    // so a stale handle was silently ignored — which is what the command-buffer
    // flush needs, a tag recorded for an entity despawned later in the same
    // tick being ordinary. G3 replaced that head with `componentBytes`, which
    // answers null for a stale handle and falls into the `else if (set)` arm,
    // where `addComponentDynamic` validates the handle and returns
    // `error.StaleEntityHandle` — aborting the whole flush. The comment at the
    // site claimed the behaviour was preserved; it was not.
    try world.applyTagMutation(gpa, e, tagset, 3, true);
    try world.applyTagMutation(gpa, e, tagset, 3, false);
    // Not merely "did not error": nothing was created for a dead entity.
    try testing.expect(!world.hasComponentDyn(e, tagset));
    try testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "the TYPED arms carry a sparse component end to end" {
    const gpa = testing.allocator;
    const Mark = extern struct { v: u64 = 0 };
    var world = World.init();
    defer world.deinit(gpa);

    // The four comptime-`T` arms — `get`, `getMut`, `addComponent`,
    // `removeComponent` — had NO coverage at all: every other test here goes
    // through the dynamic entries. That hole is why the typed `spawn`'s missing
    // `ensureSparseStores` went unseen.
    const cid = try world.registry.registerComponentRaw(gpa, .{
        .name = @typeName(Mark),
        .size = @sizeOf(Mark),
        .alignment = @alignOf(Mark),
        .default_bytes = &[_]u8{0} ** @sizeOf(Mark),
        .fields = &.{},
        .storage = .sparse,
    });
    const pos = try reg(&world, gpa, "Pos", .table);
    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(1)});

    try world.addComponent(gpa, e, Mark, .{ .v = 42 });
    try testing.expect(world.hasComponentDyn(e, cid));
    try testing.expectEqual(@as(u64, 42), world.get(Mark, e).?.v);
    // The archetype must be untouched — the typed arm owes the same
    // no-migration property as the dynamic one.
    try testing.expect(!world.dynamicArchetype(world.dynamicLocation(e).?.archetype_idx).hasComponent(cid));

    world.getMut(Mark, e).?.v = 43;
    try testing.expectEqual(@as(u64, 43), world.get(Mark, e).?.v);

    try world.removeComponent(gpa, e, Mark);
    try testing.expect(world.get(Mark, e) == null);
    try testing.expect(!world.hasComponentDyn(e, cid));
    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, pos).?));
}

test "the typed spawn path serves a sparse core component instead of panicking" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // `spawn` resolves `Transform`/`Velocity` through `ensureRegistered`, so to
    // reach its sparse arm one of them must be registered sparse FIRST. The
    // typed spawn then calls `addSparsePayloads` — which unwraps
    // `sparse_stores.get(cid).?` — without ever having called
    // `ensureSparseStores`. Its own comment says the split exists for exactly
    // "the day one of them is registered differently"; that day it panicked.
    _ = try world.registry.registerComponentRaw(gpa, .{
        .name = @typeName(world_mod.Velocity),
        .size = @sizeOf(world_mod.Velocity),
        .alignment = @alignOf(world_mod.Velocity),
        .default_bytes = &[_]u8{0} ** @sizeOf(world_mod.Velocity),
        .fields = &.{},
        .storage = .sparse,
    });

    const e = try world.spawn(gpa, .{}, .{});
    const vid = world.registry.idOf(@typeName(world_mod.Velocity)).?;
    const tid = world.registry.idOf(@typeName(world_mod.Transform)).?;
    try testing.expect(world.hasComponentDyn(e, vid));
    try testing.expect(world.hasComponentDyn(e, tid));
    const arch = world.dynamicArchetype(world.dynamicLocation(e).?.archetype_idx);
    try testing.expect(arch.hasComponent(tid));
    try testing.expect(!arch.hasComponent(vid));
}

test "a duplicate sparse id in a spawn is refused, not written twice" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const s = try reg(&world, gpa, "S", .sparse);

    // Two dense rows for one entity would make `positionOf` answer the first,
    // `remove` swap one away, and the other unreachable for the world's
    // lifetime — `SparseStores.removeEntity` drops ONE row per store, so the
    // leak survives despawn. `SparseSetStorage.add`'s own `assert(!contains)` is
    // compiled to nothing in ReleaseFast, so the guard has to be active.
    try testing.expectError(
        error.DuplicateComponent,
        world.spawnDynamicWithValues(gpa, &.{ s, s }, &.{ &word(1), &word(2) }),
    );

    // And the refusal is clean: no entity, no row, nothing to leak.
    try testing.expectEqual(@as(usize, 0), world.entityCount());
    try testing.expectEqual(@as(usize, 0), world.identity.liveCount());
    if (world.sparse_stores.getConst(s)) |store| {
        try testing.expectEqual(@as(usize, 0), store.len());
    }

    // The complement: a NON-duplicated set of the same id count is accepted, so
    // the refusal is about duplication and not about arity.
    const s2 = try reg(&world, gpa, "S2", .sparse);
    const e = try world.spawnDynamicWithValues(gpa, &.{ s, s2 }, &.{ &word(1), &word(2) });
    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, s).?));
    try testing.expectEqual(@as(u64, 2), readWord(world.componentBytes(e, s2).?));
}

// ─── G4 — the TABLE twins of F4/F5 ──────────────────────────────────────────
//
// The G3 review closed the sparse halves and REPORTED these two, whose
// preconditions predate M1.B and were carried by `std.debug.assert` alone —
// compiled to nothing in ReleaseFast, which is the mode a game ships and the
// one `ci.yml`'s single ReleaseFast cell exists to cover (its own comment names
// this class: "the guard was absent precisely where its breach silently returns
// an entity twice"). Converting them to active checks RESTORES a contract that
// is already written; it does not invent one.
//
// They live in this file because the class was found through the sparse arm and
// the two halves must not drift apart again.

test "adding a TABLE component the entity already has is refused" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const other = try reg(&world, gpa, "Other", .table);
    const e = try world.spawnDynamicWithValues(gpa, &.{pos}, &.{&word(1)});

    // Under the assert alone this is UB in ReleaseFast: the migration proceeds
    // and `Archetype.init` builds a signature carrying `pos` TWICE.
    try testing.expectError(
        error.DuplicateComponent,
        world.addComponentDynamic(gpa, e, pos, &word(2)),
    );
    // Refused without side effect: the original value stands and no archetype
    // was minted for the malformed signature.
    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, pos).?));
    const n_arch = world.archetypeCount();

    // The complement, without which the test above would pass an implementation
    // that refuses every table add: an ABSENT component still lands.
    try world.addComponentDynamic(gpa, e, other, &word(3));
    try testing.expectEqual(@as(u64, 3), readWord(world.componentBytes(e, other).?));
    try testing.expectEqual(n_arch + 1, world.archetypeCount());
}

test "a duplicate TABLE id in a spawn is refused" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);
    const vel = try reg(&world, gpa, "Vel", .table);

    // A repeated column is a malformed archetype: two entries of
    // `component_ids` resolve to one `ComponentId`, so `componentIndex` answers
    // the first and the second column is written but never read again.
    try testing.expectError(
        error.DuplicateComponent,
        world.spawnDynamicWithValues(gpa, &.{ pos, pos }, &.{ &word(1), &word(2) }),
    );
    try testing.expectEqual(@as(usize, 0), world.entityCount());
    try testing.expectEqual(@as(usize, 0), world.identity.liveCount());

    // Complement: the same arity with DISTINCT ids is accepted, so the refusal
    // is about duplication and not about the count.
    const e = try world.spawnDynamicWithValues(gpa, &.{ pos, vel }, &.{ &word(1), &word(2) });
    try testing.expectEqual(@as(u64, 1), readWord(world.componentBytes(e, pos).?));
    try testing.expectEqual(@as(u64, 2), readWord(world.componentBytes(e, vel).?));
}

test "a duplicate TABLE id in the default-payload spawn is refused" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try reg(&world, gpa, "Pos", .table);

    // `spawnDynamic` is the sibling entry and takes the same caller slice, so
    // leaving it unguarded would reopen the hole through the other door — the
    // "one path out of two" shape this milestone keeps meeting.
    try testing.expectError(
        error.DuplicateComponent,
        world.spawnDynamic(gpa, &.{ pos, pos }),
    );
    try testing.expectEqual(@as(usize, 0), world.entityCount());
    _ = try world.spawnDynamic(gpa, &.{pos});
    try testing.expectEqual(@as(usize, 1), world.entityCount());
}

// ─── G4 — the three apply switches, over the union ──────────────────────────

const observers_mod = weld_core.ecs.observers;
const EntityId = weld_core.ecs.EntityId;
const Command = weld_core.ecs.Command;
const CommandBuffer = weld_core.ecs.CommandBuffer;

/// Records the `component_id` of every observer firing, in order.
const FireLog = struct {
    ids: std.ArrayListUnmanaged(ComponentId) = .empty,
    fn note(
        ctx: ?*anyopaque,
        world: *World,
        entity: EntityId,
        component_id: ?ComponentId,
        old_value: ?*const anyopaque,
        new_value: ?*const anyopaque,
        deferred: *CommandBuffer,
    ) anyerror!void {
        _ = world;
        _ = entity;
        _ = old_value;
        _ = new_value;
        _ = deferred;
        const self: *FireLog = @ptrCast(@alignCast(ctx.?));
        try self.ids.append(std.testing.allocator, component_id.?);
    }
};

test "on_remove at despawn fires over the UNION, ascending by component id" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Registration order interleaves the two modes, so ascending id order is
    // NOT "all table then all sparse" — an implementation that appended the
    // sparse ids after the table ones would pass a same-mode scene.
    const t0 = try reg(&world, gpa, "T0", .table);
    const s1 = try reg(&world, gpa, "S1", .sparse);
    const t2 = try reg(&world, gpa, "T2", .table);
    const s3 = try reg(&world, gpa, "S3", .sparse);

    var log: FireLog = .{};
    defer log.ids.deinit(gpa);
    for ([_]ComponentId{ t0, s1, t2, s3 }) |cid| {
        try world.observer_registry.registerOnRemove(gpa, &world, cid, &log, &FireLog.note);
    }

    // The caller's slice order is DELIBERATELY not ascending: the firing order
    // must come from the id, not from this list.
    const e = try world.spawnDynamicWithValues(
        gpa,
        &.{ s3, t0, s1, t2 },
        &.{ &word(4), &word(1), &word(2), &word(3) },
    );

    const c: Command = .{ .despawn = .{ .entity = e } };
    try observers_mod.applyWithObservers(c, &world.observer_registry, &world, gpa);

    // Four firings, ascending, sparse ones INCLUDED. Before G4 the arm walked
    // `arch.component_ids` alone, so `s1` and `s3` never fired at all — an
    // observer silently skipped, which no caller can detect.
    try testing.expectEqualSlices(ComponentId, &.{ t0, s1, t2, s3 }, log.ids.items);
}

test "add-on-present on a SPARSE component fires the replacement, not the add" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const s = try reg(&world, gpa, "S", .sparse);
    var adds: FireLog = .{};
    var reps: FireLog = .{};
    defer adds.ids.deinit(gpa);
    defer reps.ids.deinit(gpa);
    try world.observer_registry.registerOnAdd(gpa, &world, s, &adds, &FireLog.note);
    try world.observer_registry.registerOnReplaced(gpa, &world, s, &reps, &FireLog.note);

    // Through `spawnWithObservers` and NOT `spawnDynamicWithValues`: the direct
    // entry fires no observer at all, which a first version of this test got
    // wrong. Spawning here also checks that the spawn's own `on_add` reaches a
    // SPARSE component — `spawnWithObservers` iterates the CALLER's id list
    // rather than the archetype signature, so it covers the union already, and
    // this is what establishes that rather than asserting it.
    const e = try world.observer_registry.spawnWithObservers(gpa, &world, &.{s}, &.{&word(1)});
    try testing.expectEqual(@as(usize, 1), adds.ids.items.len);
    try testing.expectEqualSlices(ComponentId, &.{s}, adds.ids.items);

    // Add-on-present through the observer-dispatching apply. The direct entry
    // `addComponentDynamic` returns `DuplicateComponent` here — deliberately,
    // it is not the command-buffer contract — and this path tests presence
    // FIRST and overwrites in place, which G3 made work for the sparse row by
    // routing `componentBytes` and `markComponentChangedDyn`.
    const c: Command = .{ .add_component = .{
        .entity = e,
        .component_id = s,
        .bytes = &word(9),
    } };
    try observers_mod.applyWithObservers(c, &world.observer_registry, &world, gpa);

    try testing.expectEqual(@as(usize, 1), reps.ids.items.len);
    try testing.expectEqual(@as(usize, 1), adds.ids.items.len); // NOT a second add
    try testing.expectEqual(@as(u64, 9), readWord(world.componentBytes(e, s).?));
}

/// The six command kinds, named so the oracle below counts a SET and not a
/// number it chose. Adding a seventh kind to `CommandKind` breaks the comptime
/// check beside it rather than silently lowering the bar.
const all_kinds = [_][]const u8{
    "spawn", "despawn", "add_component", "remove_component", "set_tag", "clear_tag",
};

comptime {
    const actual = std.meta.fieldNames(weld_core.ecs.command_buffer.CommandKind);
    if (actual.len != all_kinds.len) @compileError(
        "CommandKind's arity moved — the three-path oracle in sparse_routing_test.zig counts " ++
            "against `all_kinds` and must be extended before this compiles again",
    );
    for (actual, all_kinds) |a, named| {
        if (!std.mem.eql(u8, a, named)) @compileError(
            "CommandKind's members moved at `" ++ a ++ "` — see `all_kinds`",
        );
    }
}

/// Queues one command into the observer-deferred buffer when it fires. This is
/// the ONLY way to reach `applyRawCommand`, which is private and drains that
/// buffer on the NEXT flush.
const Queuer = struct {
    cmd: Command,
    fired: usize = 0,
    fn note(
        ctx: ?*anyopaque,
        world: *World,
        entity: EntityId,
        component_id: ?ComponentId,
        old_value: ?*const anyopaque,
        new_value: ?*const anyopaque,
        deferred: *CommandBuffer,
    ) anyerror!void {
        _ = world;
        _ = entity;
        _ = component_id;
        _ = old_value;
        _ = new_value;
        const self: *Queuer = @ptrCast(@alignCast(ctx.?));
        self.fired += 1;
        try deferred.commands.append(deferred.gpa, self.cmd);
    }
};

test "each of the THREE apply switches carries the routing on all six kinds" {
    // The brief's own words: "A change landing in one and not the others is the
    // dominant defect shape of this milestone." So the count is reported PER
    // PATH, on its own line, and a path that covers five kinds is visible as
    // five — not hidden inside a single aggregate that passes.
    const gpa = testing.allocator;

    var covered = [_]usize{ 0, 0, 0 };
    const path_names = [_][]const u8{ "CommandBuffer.applyOne", "applyWithObservers", "applyRawCommand (deferred drain)" };

    // ── path 0: CommandBuffer.applyOne ──────────────────────────────────
    {
        var world = World.init();
        defer world.deinit(gpa);
        const s = try reg(&world, gpa, "S", .sparse);
        const tag = try reg(&world, gpa, "TagSet", .sparse);
        var cmd = CommandBuffer.init(gpa, &world);
        defer cmd.deinit();

        // spawn
        var e: EntityId = undefined;
        try cmd.applyOne(.{ .spawn = .{ .component_ids = &.{s}, .payloads = &.{&word(1)} } });
        e = blk: {
            var it = world.entity_locations.keyIterator();
            break :blk it.next().?.*;
        };
        if (readWord(world.componentBytes(e, s).?) == 1) covered[0] += 1;
        // remove_component
        try cmd.applyOne(.{ .remove_component = .{ .entity = e, .component_id = s } });
        if (!world.hasComponentDyn(e, s)) covered[0] += 1;
        // add_component (absent — the raw paths refuse add-on-present by design)
        try cmd.applyOne(.{ .add_component = .{ .entity = e, .component_id = s, .bytes = &word(5) } });
        if (readWord(world.componentBytes(e, s).?) == 5) covered[0] += 1;
        // set_tag / clear_tag on a SPARSE TagSet
        try cmd.applyOne(.{ .set_tag = .{ .entity = e, .tagset_id = tag, .bit_index = 2 } });
        if (readWord(world.componentBytes(e, tag).?) == @as(u64, 1) << 2) covered[0] += 1;
        try cmd.applyOne(.{ .clear_tag = .{ .entity = e, .tagset_id = tag, .bit_index = 2 } });
        if (readWord(world.componentBytes(e, tag).?) == 0) covered[0] += 1;
        // despawn
        try cmd.applyOne(.{ .despawn = .{ .entity = e } });
        if (world.sparse_stores.getConst(s).?.len() == 0 and !world.isLive(e)) covered[0] += 1;
    }

    // ── path 1: applyWithObservers ──────────────────────────────────────
    {
        var world = World.init();
        defer world.deinit(gpa);
        const s = try reg(&world, gpa, "S", .sparse);
        const tag = try reg(&world, gpa, "TagSet", .sparse);

        const eid = try world.observer_registry.spawnWithObservers(gpa, &world, &.{s}, &.{&word(1)});
        if (readWord(world.componentBytes(eid, s).?) == 1) covered[1] += 1;

        const R = &world.observer_registry;
        try observers_mod.applyWithObservers(.{ .remove_component = .{ .entity = eid, .component_id = s } }, R, &world, gpa);
        if (!world.hasComponentDyn(eid, s)) covered[1] += 1;
        try observers_mod.applyWithObservers(.{ .add_component = .{ .entity = eid, .component_id = s, .bytes = &word(5) } }, R, &world, gpa);
        if (readWord(world.componentBytes(eid, s).?) == 5) covered[1] += 1;
        try observers_mod.applyWithObservers(.{ .set_tag = .{ .entity = eid, .tagset_id = tag, .bit_index = 2 } }, R, &world, gpa);
        if (readWord(world.componentBytes(eid, tag).?) == @as(u64, 1) << 2) covered[1] += 1;
        try observers_mod.applyWithObservers(.{ .clear_tag = .{ .entity = eid, .tagset_id = tag, .bit_index = 2 } }, R, &world, gpa);
        if (readWord(world.componentBytes(eid, tag).?) == 0) covered[1] += 1;
        try observers_mod.applyWithObservers(.{ .despawn = .{ .entity = eid } }, R, &world, gpa);
        if (world.sparse_stores.getConst(s).?.len() == 0 and !world.isLive(eid)) covered[1] += 1;
    }

    // ── path 2: applyRawCommand, reached only through the deferred drain ─
    for (all_kinds, 0..) |_, k| {
        var world = World.init();
        defer world.deinit(gpa);
        const s = try reg(&world, gpa, "S", .sparse);
        const tag = try reg(&world, gpa, "TagSet", .sparse);
        const trigger = try reg(&world, gpa, "Trigger", .table);

        // A subject entity carrying the sparse component the queued command
        // will act on, plus a trigger whose `on_add` does the queueing.
        const subject = try world.spawnDynamicWithValues(gpa, &.{s}, &.{&word(1)});

        var q: Queuer = .{ .cmd = switch (k) {
            0 => .{ .spawn = .{ .component_ids = &.{s}, .payloads = &.{&word(7)} } },
            1 => .{ .despawn = .{ .entity = subject } },
            2 => .{ .add_component = .{ .entity = subject, .component_id = tag, .bytes = &word(0) } },
            3 => .{ .remove_component = .{ .entity = subject, .component_id = s } },
            4 => .{ .set_tag = .{ .entity = subject, .tagset_id = tag, .bit_index = 2 } },
            5 => .{ .clear_tag = .{ .entity = subject, .tagset_id = tag, .bit_index = 2 } },
            else => unreachable,
        } };
        try world.observer_registry.registerOnAdd(gpa, &world, trigger, &q, &Queuer.note);

        var cmd = CommandBuffer.init(gpa, &world);
        defer cmd.deinit();
        // Flush 1: the trigger's add fires the observer, which QUEUES.
        // Appended raw rather than through `cmd.addComponent`, whose signature
        // is typed (`comptime T: type`) and cannot name a runtime
        // `ComponentId`. `trigger_bytes` is a named local so the slice outlives
        // the flush rather than pointing at an expression temporary.
        const trigger_bytes = word(0);
        try cmd.commands.append(gpa, .{ .add_component = .{
            .entity = subject,
            .component_id = trigger,
            .bytes = &trigger_bytes,
        } });
        try observers_mod.flushWithObservers(&cmd, &world.observer_registry);
        try testing.expectEqual(@as(usize, 1), q.fired);
        cmd.reset();
        // Flush 2: the queued command drains through `applyRawCommand`.
        try observers_mod.flushWithObservers(&cmd, &world.observer_registry);

        const ok = switch (k) {
            0 => world.sparse_stores.getConst(s).?.len() == 2, // subject + the spawned one
            1 => !world.isLive(subject) and world.sparse_stores.getConst(s).?.len() == 0,
            2 => world.hasComponentDyn(subject, tag),
            3 => !world.hasComponentDyn(subject, s),
            4 => readWord(world.componentBytes(subject, tag).?) == @as(u64, 1) << 2,
            5 => world.componentBytes(subject, tag) == null, // clear on an absent TagSet is a no-op
            else => unreachable,
        };
        if (ok) covered[2] += 1;
    }

    // THREE LINES, one per path — the report the gate owes, not an aggregate.
    for (path_names, covered) |name, n| {
        std.debug.print("[apply-routing] {s}: {d}/{d} kinds\n", .{ name, n, all_kinds.len });
    }
    for (path_names, covered) |name, n| {
        if (n != all_kinds.len) {
            std.debug.print("[apply-routing] UNCOVERED on {s}\n", .{name});
            return error.ApplyPathDoesNotCoverAllKinds;
        }
    }
}

// ─── G5 — the public surface gains a tick reader ────────────────────────────

test "changedTickOf answers for BOTH backends, and the modes are twins" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const t = try reg(&world, gpa, "T", .table);
    const s = try reg(&world, gpa, "S", .sparse);
    const e = try world.spawnDynamicWithValues(gpa, &.{ t, s }, &.{ &word(1), &word(2) });

    const t0 = world.changedTickOf(e, t).?;
    const s0 = world.changedTickOf(e, s).?;
    // Both stamped at the same spawn, so the two backends agree at t=0 — which
    // is what makes the divergence below attributable to the write and not to a
    // difference in how the two record a spawn.
    try testing.expectEqual(t0, s0);

    world.beginFrame();
    world.beginFrame();
    world.markComponentChangedDyn(e, s);

    // The sparse tick MOVED and the table one did not. Before G5 the public
    // surface had no tick reader at all: every consumer reached the archetype
    // through the two-call idiom, which answers for the table half only, so a
    // sparse component read as NEVER CHANGED — a wrong answer with no
    // diagnostic anywhere.
    try testing.expectEqual(world.current_tick, world.changedTickOf(e, s).?);
    try testing.expectEqual(t0, world.changedTickOf(e, t).?);

    // And the table arm still moves when IT is marked, so the asymmetry above
    // is the mark's and not the arm's.
    world.markComponentChangedDyn(e, t);
    try testing.expectEqual(world.current_tick, world.changedTickOf(e, t).?);
}

test "changedTickOf is total: stale handle, unknown id, absent component" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const s = try reg(&world, gpa, "S", .sparse);
    const absent = try reg(&world, gpa, "Absent", .sparse);
    const e = try world.spawnDynamicWithValues(gpa, &.{s}, &.{&word(1)});

    try testing.expect(world.changedTickOf(e, s) != null);
    try testing.expect(world.changedTickOf(e, absent) == null);
    try testing.expect(world.changedTickOf(e, 9999) == null);
    try world.despawn(gpa, e);
    try testing.expect(world.changedTickOf(e, s) == null);
}
