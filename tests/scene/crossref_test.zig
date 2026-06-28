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

    var result = try scene.loader.loadFromBytes(&world, gpa, bytes);
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
