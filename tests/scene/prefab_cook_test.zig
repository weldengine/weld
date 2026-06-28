//! M1.0.6 E2 — `.prefab.etch` → `cookPrefab` → `.prefab.bin` writer → accessor.
//! A prefab is a mini-scene: it cooks to the identical `.scene.bin` format, so it
//! round-trips through the same `writer` + `accessor`. Covers the standalone form
//! and the `of` variant (base inherited from its cooked `.prefab.bin`, field-merge
//! on shared components, add on new ones), plus the rejected forms (`extends`,
//! hooks on a non-`extends` prefab). Components are POD scalar (the cook's only
//! component kind — enum/string are resource-only), so fixtures use f32/i32.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");

const scene = weld_core.scene;
const Registry = weld_core.ecs.registry.Registry;
const scene_cook = weld_etch.scene_cook;

const Accessor = scene.accessor.Accessor;

/// A one-entry base-prefab resolver over an in-process byte buffer.
const OneResolver = struct {
    name: []const u8,
    bytes: []const u8,

    fn resolve(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *OneResolver = @ptrCast(@alignCast(ctx));
        return if (std.mem.eql(u8, name, self.name)) self.bytes else null;
    }

    fn base(self: *OneResolver) scene_cook.BaseResolver {
        return .{ .ctx = self, .resolveFn = OneResolver.resolve };
    }
};

fn columnOf(acc: Accessor, arch: Accessor.Archetype, comp: []const u8) ?usize {
    var c: usize = 0;
    while (c < arch.component_count) : (c += 1) {
        if (std.mem.eql(u8, acc.schema(arch.schemaIndex(c)).name, comp)) return c;
    }
    return null;
}

fn decodeF32(acc: Accessor, reg: *const Registry, arch: Accessor.Archetype, comp: []const u8, field: []const u8, slot: usize) f32 {
    const c = columnOf(acc, arch, comp).?;
    const fd = reg.findField(reg.idOf(comp).?, field).?;
    return @bitCast(std.mem.readInt(u32, arch.componentSlot(c, slot)[fd.offset..][0..4], .little));
}

const standalone_src =
    \\component Transform { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 }
    \\component Light { intensity: f32 = 2000.0, radius: f32 = 8.0 }
    \\prefab "WallTorch" {
    \\  version: 2
    \\  entity "root" {
    \\    uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e"
    \\    Transform { x: 1.0 }
    \\    Light { intensity: 1500.0 }
    \\  }
    \\}
;

test "standalone prefab cooks and reads back" {
    const gpa = std.testing.allocator;

    var cooked = try scene_cook.cookPrefab(gpa, standalone_src, null, null);
    defer cooked.deinit(gpa);

    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    try std.testing.expectEqual(@as(u16, 2), acc.header.content_version);
    try std.testing.expectEqual(@as(u32, 1), acc.archetypeCount());

    const arch = acc.archetype(0);
    try std.testing.expectEqual(@as(u32, 1), arch.entity_count);
    try std.testing.expectEqual(@as(u32, 2), arch.component_count); // [Light, Transform]
    try std.testing.expectEqualStrings("root", arch.entityName(0));
    try std.testing.expectEqual(scene.format.no_parent, arch.entityParent(0));
    try std.testing.expectEqual(@as(u8, 0x7b), arch.entityUuid(0)[0]);

    // Authored field + inherited default.
    try std.testing.expectApproxEqAbs(@as(f32, 1500.0), decodeF32(acc, &cooked.registry, arch, "Light", "intensity", 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), decodeF32(acc, &cooked.registry, arch, "Light", "radius", 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decodeF32(acc, &cooked.registry, arch, "Transform", "x", 0), 1e-3);
}

const variant_src =
    \\component Transform { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 }
    \\component Light { intensity: f32 = 2000.0, radius: f32 = 8.0 }
    \\component Glow { power: f32 = 1.0 }
    \\prefab "WallTorch_Blue" of "WallTorch" {
    \\  entity "root" {
    \\    Light { intensity: 2500.0 }
    \\    Glow { power: 3.0 }
    \\  }
    \\}
;

test "variant prefab resolves of-chain" {
    const gpa = std.testing.allocator;

    // Cook the base standalone prefab to its `.prefab.bin` bytes.
    var base = try scene_cook.cookPrefab(gpa, standalone_src, null, null);
    defer base.deinit(gpa);
    const base_bytes = try scene.writer.write(gpa, base.model, &base.registry);
    defer gpa.free(base_bytes);

    var resolver = OneResolver{ .name = "WallTorch", .bytes = base_bytes };
    var cooked = try scene_cook.cookPrefab(gpa, variant_src, resolver.base(), null);
    defer cooked.deinit(gpa);

    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    try std.testing.expectEqual(@as(u32, 1), acc.archetypeCount());

    const arch = acc.archetype(0);
    try std.testing.expectEqual(@as(u32, 1), arch.entity_count);
    try std.testing.expectEqual(@as(u32, 3), arch.component_count); // [Glow, Light, Transform]
    try std.testing.expectEqualStrings("root", arch.entityName(0));

    // Overridden field, inherited field, inherited component, added component.
    try std.testing.expectApproxEqAbs(@as(f32, 2500.0), decodeF32(acc, &cooked.registry, arch, "Light", "intensity", 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), decodeF32(acc, &cooked.registry, arch, "Light", "radius", 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decodeF32(acc, &cooked.registry, arch, "Transform", "x", 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), decodeF32(acc, &cooked.registry, arch, "Glow", "power", 0), 1e-3);
}

test "prefab re-cook is byte-identical" {
    const gpa = std.testing.allocator;
    var c1 = try scene_cook.cookPrefab(gpa, standalone_src, null, null);
    defer c1.deinit(gpa);
    const b1 = try scene.writer.write(gpa, c1.model, &c1.registry);
    defer gpa.free(b1);
    var c2 = try scene_cook.cookPrefab(gpa, standalone_src, null, null);
    defer c2.deinit(gpa);
    const b2 = try scene.writer.write(gpa, c2.model, &c2.registry);
    defer gpa.free(b2);
    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "cookPrefab rejects extends (M1.0.6 E5) and a scene source" {
    const gpa = std.testing.allocator;
    const extends_src =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\prefab "CombatModule" extends "BaseCharacter" requires Health {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { max: 150 } }
        \\}
    ;
    var diag: []const u8 = "";
    try std.testing.expectError(error.ExtendsUnsupported, scene_cook.cookPrefab(gpa, extends_src, null, &diag));

    const scene_src =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\scene "S" { entity "e" { uuid: "00000000-0000-0000-0000-000000000002" Health {} } }
    ;
    try std.testing.expectError(error.SceneNotAllowedInPrefab, scene_cook.cookPrefab(gpa, scene_src, null, &diag));
}

test "cookPrefab rejects hooks on a non-extends prefab" {
    const gpa = std.testing.allocator;
    const of_with_hook =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\prefab "Boosted" of "Base" requires Health {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Health { max: 200 } }
        \\}
    ;
    var diag: []const u8 = "";
    try std.testing.expectError(error.PrefabHookNotAllowed, scene_cook.cookPrefab(gpa, of_with_hook, null, &diag));
}

test "of variant without a resolver errors BasePrefabMissing" {
    const gpa = std.testing.allocator;
    var diag: []const u8 = "";
    try std.testing.expectError(error.BasePrefabMissing, scene_cook.cookPrefab(gpa, variant_src, null, &diag));
}
