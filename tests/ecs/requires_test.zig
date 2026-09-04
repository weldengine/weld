//! M1.B / G9 — `@requires`: closure, transaction, and the refusal channel.
//!
//! Written at Tier 0, through `registerComponentRaw`'s `.requires` name list,
//! so the semantics are exercised without the Etch front end in the loop: a
//! front-end regression must not read as a `@requires` regression.
//!
//! The five guards and the tests their counter-factuals must redden were
//! written into the brief BEFORE this file existed. Any gap between that list
//! and the measured result is a finding, in either direction.

const std = @import("std");
const weld_core = @import("weld_core");
const ecs = weld_core.ecs;
const World = ecs.World;
const EntityId = ecs.EntityId;
const ComponentId = ecs.ComponentId;
const testing = std.testing;

const zero8 = [_]u8{0} ** 8;

fn reg(
    world: *World,
    gpa: std.mem.Allocator,
    name: []const u8,
    requires: []const []const u8,
    mode: ecs.StorageKind,
) !ComponentId {
    return world.registry.registerComponentRaw(gpa, .{
        .name = name,
        .size = 8,
        .alignment = 8,
        .default_bytes = &zero8,
        .fields = &.{},
        .storage = mode,
        .requires = requires,
    });
}

fn word(v: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    return b;
}

// ─── Guard 1 — a cycle is an error, not a fixpoint ──────────────────────────

test "G9/1: a requires cycle is refused, and a DIAMOND is not" {
    const gpa = testing.allocator;
    {
        var world = World.init();
        defer world.deinit(gpa);
        _ = try reg(&world, gpa, "A", &.{"B"}, .table);
        _ = try reg(&world, gpa, "B", &.{"A"}, .table);
        // The fixpoint is computable and is refused: it would make `add(A)` and
        // `add(B)` indistinguishable and leave every carrier of one carrying
        // the other, with nothing able to undo the coupling.
        try testing.expectError(error.RequiresCycle, world.registry.finalizeRequires(gpa));
    }
    {
        // Self-requirement is the degenerate cycle and must be caught too — a
        // two-colour visited set would let it through on the first visit.
        var world = World.init();
        defer world.deinit(gpa);
        _ = try reg(&world, gpa, "S", &.{"S"}, .table);
        try testing.expectError(error.RequiresCycle, world.registry.finalizeRequires(gpa));
    }
    {
        // THE COMPLEMENT, and it is what makes the refusals above a
        // discrimination: a DIAMOND is legal. `A requires B, C`; `B requires D`;
        // `C requires D`. A visited-set implementation that reported a cycle
        // here would pass both assertions above and be wrong.
        var world = World.init();
        defer world.deinit(gpa);
        const d = try reg(&world, gpa, "D", &.{}, .table);
        const b = try reg(&world, gpa, "B", &.{"D"}, .table);
        const c = try reg(&world, gpa, "C", &.{"D"}, .table);
        const a = try reg(&world, gpa, "A", &.{ "B", "C" }, .table);
        try world.registry.finalizeRequires(gpa);
        // The closure is the transitive set, DEDUPLICATED — `D` reached twice
        // appears once — and ascending by id, which is a pure function of the
        // program rather than of the walk.
        try testing.expectEqualSlices(ComponentId, &.{ d, b, c }, world.registry.requiresClosure(a));
        try testing.expectEqualSlices(ComponentId, &.{d}, world.registry.requiresClosure(b));
        try testing.expectEqual(@as(usize, 0), world.registry.requiresClosure(d).len);
    }
}

test "G9/1b: an unknown requisite is refused, not silently ignored" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    _ = try reg(&world, gpa, "A", &.{"Nonexistent"}, .table);
    // Silently ignored, the invariant would be unenforceable for `A` while
    // nothing reported it — the silent-wrong-answer shape.
    try testing.expectError(error.UnknownRequisite, world.registry.finalizeRequires(gpa));
}

test "G9/1c: a FORWARD reference resolves — names, not ids, is why" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    // `A` names `B` before `B` exists. Etch admits forward references, so
    // resolving at registration would make the closure depend on declaration
    // order; the descriptor carries NAMES and `finalizeRequires` resolves them.
    const a = try reg(&world, gpa, "A", &.{"B"}, .table);
    const b = try reg(&world, gpa, "B", &.{}, .table);
    try world.registry.finalizeRequires(gpa);
    try testing.expectEqualSlices(ComponentId, &.{b}, world.registry.requiresClosure(a));
}

// ─── Guard 2 — the closure is added TRANSACTIONALLY ─────────────────────────

test "G9/2: adding a component adds its whole closure, in one migration" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const t = try reg(&world, gpa, "Transform", &.{}, .table);
    const rb = try reg(&world, gpa, "RigidBody", &.{"Transform"}, .table);
    const mesh = try reg(&world, gpa, "Mesh", &.{"RigidBody"}, .table);
    try world.registry.finalizeRequires(gpa);
    // Transitive: Mesh → RigidBody → Transform.
    try testing.expectEqualSlices(ComponentId, &.{ t, rb }, world.registry.requiresClosure(mesh));

    const e = try world.spawnDynamic(gpa, &.{});
    try world.addComponentDynamic(gpa, e, mesh, &word(9));

    try testing.expect(world.hasComponentDyn(e, mesh));
    try testing.expect(world.hasComponentDyn(e, rb));
    try testing.expect(world.hasComponentDyn(e, t));
    // The requested component keeps the CALLER's bytes; the closure members get
    // registry defaults.
    try testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, world.componentBytes(e, mesh).?[0..8], .little));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, world.componentBytes(e, t).?[0..8], .little));
    // ONE migration: the entity's archetype holds all three, so it did not
    // travel through an intermediate signature per member.
    const arch = world.dynamicArchetype(world.dynamicLocation(e).?.archetype_idx);
    try testing.expectEqual(@as(usize, 3), arch.component_ids.len);
}

test "G9/2b: the closure is a FLOOR, not a reset — a present member keeps its value" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const t = try reg(&world, gpa, "Transform", &.{}, .table);
    const mesh = try reg(&world, gpa, "Mesh", &.{"Transform"}, .table);
    try world.registry.finalizeRequires(gpa);

    const e = try world.spawnDynamicWithValues(gpa, &.{t}, &.{&word(42)});
    try world.addComponentDynamic(gpa, e, mesh, &word(7));
    // 42 and not 0: an entity that already carries a requisite keeps ITS value.
    // Overwriting with the default would destroy state the caller never asked
    // to touch, and no diagnostic would say so.
    try testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, world.componentBytes(e, t).?[0..8], .little));
    try testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, world.componentBytes(e, mesh).?[0..8], .little));
}

test "G9/2c: a failed closure add leaves the entity EXACTLY as it was" {
    const gpa = testing.allocator;
    const pass1 = blk: {
        var w = World.init();
        defer w.deinit(gpa);
        _ = try reg(&w, gpa, "Transform", &.{}, .table);
        _ = try reg(&w, gpa, "RigidBody", &.{"Transform"}, .table);
        const m = try reg(&w, gpa, "Mesh", &.{"RigidBody"}, .table);
        try w.registry.finalizeRequires(gpa);
        const e = try w.spawnDynamic(gpa, &.{});
        var counting = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
        try w.addComponentDynamic(counting.allocator(), e, m, &word(1));
        break :blk counting.alloc_index;
    };
    try testing.expect(pass1 > 0);

    var induced: usize = 0;
    var fail_at: usize = 0;
    while (fail_at < pass1) : (fail_at += 1) {
        var w = World.init();
        defer w.deinit(gpa);
        const t = try reg(&w, gpa, "Transform", &.{}, .table);
        const rb = try reg(&w, gpa, "RigidBody", &.{"Transform"}, .table);
        const m = try reg(&w, gpa, "Mesh", &.{"RigidBody"}, .table);
        try w.registry.finalizeRequires(gpa);
        const e = try w.spawnDynamic(gpa, &.{});

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_at });
        const result = w.addComponentDynamic(failing.allocator(), e, m, &word(1));

        if (result) |_| {
            // Succeeded: all three present, whole.
            try testing.expect(w.hasComponentDyn(e, m));
            try testing.expect(w.hasComponentDyn(e, rb));
            try testing.expect(w.hasComponentDyn(e, t));
        } else |_| {
            induced += 1;
            // NONE of the three — a partial closure is the invariant violation
            // this transaction exists to prevent, and it would carry no
            // diagnostic: the entity would simply be quietly invalid.
            try testing.expect(!w.hasComponentDyn(e, m));
            try testing.expect(!w.hasComponentDyn(e, rb));
            try testing.expect(!w.hasComponentDyn(e, t));
        }
    }
    try testing.expect(induced > 0);
}

test "G9/2d: the closure applies identically to a SPARSE member" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    // `engine-ecs-internals.md` §3: the transactional add "vaut identiquement …
    // pour les deux modes de stockage."
    const t = try reg(&world, gpa, "Transform", &.{}, .table);
    const burn = try reg(&world, gpa, "Burning", &.{"Transform"}, .sparse);
    try world.registry.finalizeRequires(gpa);

    const e = try world.spawnDynamic(gpa, &.{});
    try world.addComponentDynamic(gpa, e, burn, &word(3));

    try testing.expect(world.hasComponentDyn(e, burn));
    try testing.expect(world.hasComponentDyn(e, t));
    // The sparse member is NOT in the signature and the table requisite IS —
    // the closure crossed the storage boundary without either arm special-casing
    // it, because the closure is applied through the routed batched add.
    const arch = world.dynamicArchetype(world.dynamicLocation(e).?.archetype_idx);
    try testing.expect(!arch.hasComponent(burn));
    try testing.expect(arch.hasComponent(t));
}

// ─── Guards 3, 4, 5 — removal ───────────────────────────────────────────────

test "G9/3: removing the REQUIRER removes nothing else" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const t = try reg(&world, gpa, "Transform", &.{}, .table);
    const mesh = try reg(&world, gpa, "Mesh", &.{"Transform"}, .table);
    try world.registry.finalizeRequires(gpa);

    const e = try world.spawnDynamic(gpa, &.{});
    try world.addComponentDynamic(gpa, e, mesh, &word(1));
    try world.removeComponentDynamic(gpa, e, mesh);

    // `Transform` SURVIVES. It may have been added independently before, and
    // nothing in the model distinguishes the two provenances — a cascade would
    // destroy one for the other with no way to know.
    try testing.expect(!world.hasComponentDyn(e, mesh));
    try testing.expect(world.hasComponentDyn(e, t));
    try testing.expectEqual(@as(u32, 0), world.requires_removals_skipped);
}

test "G9/4: removing a still-required requisite is SKIPPED and SIGNALLED" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const t = try reg(&world, gpa, "Transform", &.{}, .table);
    const mesh = try reg(&world, gpa, "Mesh", &.{"Transform"}, .table);
    try world.registry.finalizeRequires(gpa);

    const e = try world.spawnDynamic(gpa, &.{});
    try world.addComponentDynamic(gpa, e, mesh, &word(1));

    // No error: the removal is SKIPPED. An error here would abort a tick from
    // the flush, which is the channel the brief refuses in its own words — "a
    // deferred command turned into an unobservable tick failure".
    try world.removeComponentDynamic(gpa, e, t);

    // The invariant HOLDS: `Mesh` is present and so is its closure.
    try testing.expect(world.hasComponentDyn(e, t));
    try testing.expect(world.hasComponentDyn(e, mesh));
    // And the deviation is OBSERVABLE — the half that makes "skipped" different
    // from "silently ignored".
    try testing.expectEqual(@as(u32, 1), world.requires_removals_skipped);
    try testing.expectEqual(t, world.first_requires_skip.?);

    // Reset at the frame boundary: a counter that never reset would report a
    // run instead of a tick.
    world.beginFrame();
    try testing.expectEqual(@as(u32, 0), world.requires_removals_skipped);
    try testing.expect(world.first_requires_skip == null);
}

test "G9/5: a GROUPED removal of the requisite with its dependents is allowed" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const t = try reg(&world, gpa, "Transform", &.{}, .table);
    const mesh = try reg(&world, gpa, "Mesh", &.{"Transform"}, .table);
    const other = try reg(&world, gpa, "Other", &.{}, .table);
    try world.registry.finalizeRequires(gpa);

    const e = try world.spawnDynamic(gpa, &.{other});
    try world.addComponentDynamic(gpa, e, mesh, &word(1));

    // THE WIDENING COUNTER-FACTUAL's subject: a guard has two ways of being
    // wrong, and without this exception a legitimate teardown is refused
    // forever. Dropping both together is allowed.
    try world.removeComponentsDynamic(gpa, e, &.{ mesh, t });
    try testing.expect(!world.hasComponentDyn(e, mesh));
    try testing.expect(!world.hasComponentDyn(e, t));
    try testing.expect(world.hasComponentDyn(e, other));
    try testing.expectEqual(@as(u32, 0), world.requires_removals_skipped);

    // And the grouped path still REFUSES when the requirer is NOT in the set —
    // the complement, without which "grouped is allowed" would read as
    // "grouped bypasses the guard".
    const e2 = try world.spawnDynamic(gpa, &.{});
    try world.addComponentDynamic(gpa, e2, mesh, &word(1));
    try testing.expectError(
        error.RequiredComponent,
        world.removeComponentsDynamic(gpa, e2, &.{t}),
    );
    try testing.expect(world.hasComponentDyn(e2, t));
    try testing.expect(world.hasComponentDyn(e2, mesh));
}
