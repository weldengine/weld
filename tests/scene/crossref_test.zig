//! M1.0.6 E4 — entity→entity cross-references. A component `Entity` field is
//! written `EntityId.dead` in its SoA column at cook and the reference carried in
//! the Cross-references Table (by target entity NAME, the D-B by-name form);
//! the loader patches the slot to the target's runtime handle. Covers: a forward
//! reference (target declared later — exercises the two-phase cook), an unset
//! field staying `dead`, a reference to an absent entity rejected at cook
//! (`UnresolvedCrossRef`), and the cook→load→ECS resolved-handle round-trip.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");

const scene = weld_core.scene;
const ecs = weld_core.ecs;
const World = ecs.World;
const EntityId = ecs.EntityId;
const Registry = weld_core.ecs.registry.Registry;
const scene_cook = weld_etch.scene_cook;
const Accessor = scene.accessor.Accessor;

const dead_u64: u64 = std.math.maxInt(u64); // EntityId.dead bit pattern

// A references B (declared AFTER A → forward reference, two-phase resolution);
// C leaves its Entity field unset (stays dead).
const src =
    \\component Marker { v: i32 = 0 }
    \\component Link { target: Entity }
    \\scene "S" {
    \\  entity "A" { uuid: "00000000-0000-0000-0000-0000000000a1" Link { target: "B" } }
    \\  entity "B" { uuid: "00000000-0000-0000-0000-0000000000b2" Marker { v: 7 } }
    \\  entity "C" { uuid: "00000000-0000-0000-0000-0000000000c3" Link { } }
    \\}
;

fn uuidBytes(last: u8) [16]u8 {
    var u = [_]u8{0} ** 16;
    u[15] = last;
    return u;
}

fn linkColumn(acc: Accessor, arch: Accessor.Archetype) ?usize {
    var c: usize = 0;
    while (c < arch.component_count) : (c += 1) {
        if (std.mem.eql(u8, acc.schema(arch.schemaIndex(c)).name, "Link")) return c;
    }
    return null;
}

fn slotOf(arch: Accessor.Archetype, name: []const u8) ?usize {
    var s: usize = 0;
    while (s < arch.entity_count) : (s += 1) {
        if (std.mem.eql(u8, arch.entityName(s), name)) return s;
    }
    return null;
}

test "Entity field cooks to a dead slot + a cross-ref entry; unset stays dead" {
    const gpa = std.testing.allocator;
    var cooked = try scene_cook.cook(gpa, src, null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());

    // Exactly one cross-ref (A.Link.target → B); C's unset field emits none.
    try std.testing.expectEqual(@as(u32, 1), acc.crossrefsCount());
    const e = acc.crossref(0);
    // source = A, target = B (by UUID first byte through the ordinal).
    try std.testing.expectEqual(@as(u8, 0xa1), acc.uuidAt(e.source_uuid_ordinal)[15]);
    try std.testing.expectEqual(@as(u8, 0xb2), acc.uuidAt(e.target_uuid_ordinal)[15]);
    try std.testing.expectEqual(@as(u32, 0), e.field_offset); // target @0 in Link
    try std.testing.expectEqualStrings("Link", acc.schema(e.schema_index).name);

    // On disk, BOTH A's and C's Link.target slots are dead (the side table carries
    // the value; the column slot is a placeholder).
    var ai: u32 = 0;
    while (ai < acc.archetypeCount()) : (ai += 1) {
        const arch = acc.archetype(ai);
        const lc = linkColumn(acc, arch) orelse continue;
        var s: usize = 0;
        while (s < arch.entity_count) : (s += 1) {
            const raw = std.mem.readInt(u64, arch.componentSlot(lc, s)[0..8], .little);
            try std.testing.expectEqual(dead_u64, raw);
        }
    }
}

test "cross-ref resolves to the target handle on load; unset reads dead" {
    const gpa = std.testing.allocator;
    var cooked = try scene_cook.cook(gpa, src, null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Marker", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Link", .size = 8, .alignment = 8, .default_bytes = &[_]u8{0xFF} ** 8, .fields = &.{} });

    var result = try scene.loader.loadFromBytes(&world, gpa, bytes, null);
    defer result.deinit(gpa);

    const link_id = world.componentId("Link").?;
    const a = result.uuid_to_entity.get(uuidBytes(0xa1)).?;
    const b = result.uuid_to_entity.get(uuidBytes(0xb2)).?;
    const c = result.uuid_to_entity.get(uuidBytes(0xc3)).?;

    // A.Link.target resolved to B's runtime handle.
    const a_target = std.mem.readInt(u64, world.componentBytes(a, link_id).?[0..8], .little);
    try std.testing.expectEqual(@as(u64, @bitCast(b)), a_target);

    // C.Link.target was never assigned → still dead.
    const c_target = std.mem.readInt(u64, world.componentBytes(c, link_id).?[0..8], .little);
    try std.testing.expectEqual(dead_u64, c_target);
}

test "cook rejects a reference to an absent entity" {
    const gpa = std.testing.allocator;
    const bad =
        \\component Link { target: Entity }
        \\scene "S" {
        \\  entity "A" { uuid: "00000000-0000-0000-0000-0000000000a1" Link { target: "Ghost" } }
        \\}
    ;
    var diag: []const u8 = "";
    try std.testing.expectError(error.UnresolvedCrossRef, scene_cook.cook(gpa, bad, &diag));
    try std.testing.expect(diag.len > 0);
}

// ─── M1.B / G6 — a cross-ref borne by a SPARSE component ────────────────────

test "G6: a cross-ref resolves into a SPARSE component's row" {
    const gpa = std.testing.allocator;
    // The SAME cooked bytes as the sibling test — the cook never sees a storage
    // mode, so only the runtime registry differs.
    var cooked = try scene_cook.cook(gpa, src, null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Marker", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Link", .size = 8, .alignment = 8, .default_bytes = &[_]u8{0xFF} ** 8, .fields = &.{}, .storage = .sparse });

    var result = try scene.loader.loadFromBytes(&world, gpa, bytes, null);
    defer result.deinit(gpa);

    const link_id = world.componentId("Link").?;
    const a = result.uuid_to_entity.get(uuidBytes(0xa1)).?;
    const b = result.uuid_to_entity.get(uuidBytes(0xb2)).?;
    const c = result.uuid_to_entity.get(uuidBytes(0xc3)).?;

    // `resolveCrossRefs` writes the resolved handle INTO the component's bytes
    // at the field's offset, and marks it changed — both through the World-level
    // entries G3 made bimodal, so the write lands in the sparse ROW. This is the
    // one production path in the loader that MUTATES a component after spawn,
    // and it had no sparse coverage.
    const a_target = std.mem.readInt(u64, world.componentBytes(a, link_id).?[0..8], .little);
    try std.testing.expectEqual(@as(u64, @bitCast(b)), a_target);

    // The unset reference stays dead — the negative twin, without which "the
    // write lands" would not distinguish a resolved handle from a default.
    const c_target = std.mem.readInt(u64, world.componentBytes(c, link_id).?[0..8], .little);
    try std.testing.expectEqual(dead_u64, c_target);

    // And `Link` is in nobody's archetype: the block named it, the spawn surface
    // routed it away, and the cross-ref found it anyway.
    for ([_]EntityId{ a, c }) |e| {
        const arch = world.dynamicArchetype(world.dynamicLocation(e).?.archetype_idx);
        try std.testing.expect(!arch.hasComponent(link_id));
        try std.testing.expect(world.hasComponentDyn(e, link_id));
    }
    try std.testing.expectEqual(@as(usize, 2), world.sparse_stores.getConst(link_id).?.len());
}

// ─── M1.B / G6 — @storage(.sparse) through the ETCH COOK ────────────────────

const src_plain =
    \\component Marker { v: i32 = 0 }
    \\component Burning { remaining: float = 3.0 }
    \\scene "S" {
    \\  entity "A" { uuid: "00000000-0000-0000-0000-0000000000a1" Burning { remaining: 5.0 } }
    \\  entity "B" { uuid: "00000000-0000-0000-0000-0000000000b2" Marker { v: 7 } }
    \\}
;

const src_sparse =
    \\component Marker { v: i32 = 0 }
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\scene "S" {
    \\  entity "A" { uuid: "00000000-0000-0000-0000-0000000000a1" Burning { remaining: 5.0 } }
    \\  entity "B" { uuid: "00000000-0000-0000-0000-0000000000b2" Marker { v: 7 } }
    \\}
;

test "G6: @storage(.sparse) changes NOTHING in the cooked bytes" {
    const gpa = std.testing.allocator;

    var plain = try scene_cook.cook(gpa, src_plain, null);
    defer plain.deinit(gpa);
    const b_plain = try scene.writer.write(gpa, plain.model, &plain.registry);
    defer gpa.free(b_plain);

    var sparse = try scene_cook.cook(gpa, src_sparse, null);
    defer sparse.deinit(gpa);
    const b_sparse = try scene.writer.write(gpa, sparse.model, &sparse.registry);
    defer gpa.free(b_sparse);

    // BYTE-IDENTICAL. The cook resolves the declared mode into its own registry
    // (`types_mod.storageModeOf`, the same resolver the interpreter uses, so the
    // two registries cannot disagree) and the WRITER never reads it back —
    // measured: `writer.zig` contains no occurrence of `storage` at all. The
    // storage mode is a runtime-registry property and is NEVER part of on-disk
    // identity, which is the sentence that lets this milestone leave the frozen
    // codec shut.
    //
    // This is also the seam the G6 recon found uncovered: every other test here
    // hand-builds a `CookModel`, so nothing drove the annotation through the
    // Etch front end.
    try std.testing.expectEqualSlices(u8, b_plain, b_sparse);
}

test "G6: the Etch-cooked scene loads under EITHER host registration" {
    const gpa = std.testing.allocator;
    var cooked = try scene_cook.cook(gpa, src_sparse, null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    // The load-time mode comes from the HOST's registry, not from the file —
    // which is what "not on-disk identity" means in practice, and why the same
    // bytes are loaded twice here under opposite declarations.
    inline for (.{ ecs.StorageKind.table, ecs.StorageKind.sparse }) |mode| {
        var world = World.init();
        defer world.deinit(gpa);
        _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Marker", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
        _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Burning", .size = 8, .alignment = 8, .default_bytes = &[_]u8{0} ** 8, .fields = &.{}, .storage = mode });

        var result = try scene.loader.loadFromBytes(&world, gpa, bytes, null);
        defer result.deinit(gpa);

        const burning = world.componentId("Burning").?;
        const a = result.uuid_to_entity.get(uuidBytes(0xa1)).?;
        try std.testing.expect(world.hasComponentDyn(a, burning));
        // Same value either way — `remaining: 5.0`, an Etch `float`, so an f64.
        const v: f64 = @bitCast(std.mem.readInt(u64, world.componentBytes(a, burning).?[0..8], .little));
        try std.testing.expectApproxEqAbs(@as(f64, 5.0), v, 1e-9);
        // And the archetype differs, which is what makes the equality a
        // statement about storage rather than about two identical loads.
        const arch = world.dynamicArchetype(world.dynamicLocation(a).?.archetype_idx);
        try std.testing.expectEqual(mode == .table, arch.hasComponent(burning));
    }
}
