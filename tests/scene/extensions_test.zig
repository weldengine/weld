//! M1.0.6 E5 — `extensions:` clause: parse + AST + descriptors (Claude.ai
//! amendment). The clause `extensions: [STRING_LITERAL]` on `entity`/`instance`
//! (after `uuid`/`parent`, before components) records active-extension prefab
//! names by name (like `parent:` / cross-refs, D-B).
//!
//! The cook/binary portions of E5/E6 (Entity Extensions Table + Prefab ID Table,
//! the `extends` cook + `.prefab.bin` hooks section, `applyExtensions` + the
//! `on_attach` dispatch at load) land here once the `.prefab.bin` hooks-section
//! shape blocker is resolved — see `briefs/M1.0.6-…` Blockers.

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const parser = weld_etch.parser;
const descriptor = weld_etch.descriptor;
const scene_cook = weld_etch.scene_cook;
const scene = weld_core.scene;
const Accessor = scene.accessor.Accessor;
const World = weld_core.ecs.World;
const EntityId = weld_core.ecs.EntityId;

/// One-entry in-process base-prefab resolver (for `extends`/`of`/`instance`).
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
    fn ext(self: *OneResolver) scene.loader.ExtensionResolver {
        return .{ .ctx = self, .resolveFn = OneResolver.resolve };
    }
};

// A mono-entity base prefab carrying `Health` (the `requires` target).
const base_character =
    \\component Health { current: i32 = 100, max: i32 = 100 }
    \\prefab "BaseCharacter" {
    \\  entity "root" {
    \\    uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e"
    \\    Health { current: 100, max: 100 }
    \\  }
    \\}
;

test "entity and instance extensions clauses parse to AST names" {
    const gpa = std.testing.allocator;
    const src =
        \\component Health { current: i32 = 100 }
        \\scene "S" {
        \\  entity "A" {
        \\    uuid: "00000000-0000-0000-0000-000000000001"
        \\    extensions: ["CombatModule", "DialogueModule"]
        \\    Health { current: 50 }
        \\  }
        \\  instance of "Base" "I" {
        \\    uuid: "00000000-0000-0000-0000-000000000002"
        \\    extensions: ["MerchantModule"]
        \\  }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    const ast = &pr.ast;

    const a = ast.scene_entities.items[0];
    try std.testing.expectEqual(@as(u32, 2), a.extensions_len);
    try std.testing.expectEqualStrings("CombatModule", ast.strings.slice(ast.scene_extensions.items[a.extensions_start]));
    try std.testing.expectEqualStrings("DialogueModule", ast.strings.slice(ast.scene_extensions.items[a.extensions_start + 1]));

    const inst = ast.scene_instances.items[0];
    try std.testing.expectEqual(@as(u32, 1), inst.extensions_len);
    try std.testing.expectEqualStrings("MerchantModule", ast.strings.slice(ast.scene_extensions.items[inst.extensions_start]));
}

test "empty extensions list and trailing comma parse" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  entity "A" { uuid: "00000000-0000-0000-0000-000000000001" extensions: [] }
        \\  entity "B" { uuid: "00000000-0000-0000-0000-000000000002" extensions: ["X",] }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    const ast = &pr.ast;

    try std.testing.expectEqual(@as(u32, 0), ast.scene_entities.items[0].extensions_len);
    const b = ast.scene_entities.items[1];
    try std.testing.expectEqual(@as(u32, 1), b.extensions_len);
    try std.testing.expectEqualStrings("X", ast.strings.slice(ast.scene_extensions.items[b.extensions_start]));
}

test "an entity with no extensions clause has an empty run" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  entity "A" { uuid: "00000000-0000-0000-0000-000000000001" }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 0), pr.ast.scene_entities.items[0].extensions_len);
}

test "descriptors carry the extensions names" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  entity "A" {
        \\    uuid: "00000000-0000-0000-0000-000000000001"
        \\    extensions: ["X", "Y"]
        \\  }
        \\  instance of "Base" "I" {
        \\    uuid: "00000000-0000-0000-0000-000000000002"
        \\    extensions: ["Z"]
        \\  }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var descs = try descriptor.build(gpa, &pr.ast);
    defer descs.deinit(gpa);

    var saw_scene = false;
    for (descs.items) |d| switch (d) {
        .scene => |sc| {
            saw_scene = true;
            try std.testing.expectEqual(@as(usize, 1), sc.entities.len);
            try std.testing.expectEqual(@as(usize, 2), sc.entities[0].extensions.len);
            try std.testing.expectEqualStrings("X", sc.entities[0].extensions[0]);
            try std.testing.expectEqualStrings("Y", sc.entities[0].extensions[1]);
            try std.testing.expectEqual(@as(usize, 1), sc.instances.len);
            try std.testing.expectEqual(@as(usize, 1), sc.instances[0].extensions.len);
            try std.testing.expectEqualStrings("Z", sc.instances[0].extensions[0]);
        },
        else => {},
    };
    try std.testing.expect(saw_scene);
}

test "extends prefab cooks with components, hooks and requires" {
    const gpa = std.testing.allocator;

    // Cook the base (carries Health), wire it as the `extends`/`requires` target.
    var base = try scene_cook.cookPrefab(gpa, base_character, null, null);
    defer base.deinit(gpa);
    const base_bytes = try scene.writer.write(gpa, base.model, &base.registry);
    defer gpa.free(base_bytes);
    var resolver = OneResolver{ .name = "BaseCharacter", .bytes = base_bytes };

    const combat =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 10 }
        \\prefab "CombatModule" extends "BaseCharacter" requires Health {
        \\  entity "mod" {
        \\    uuid: "9c4f3a2b-1e7d-4a5c-b8e9-f4d2c3a1b5e6"
        \\    Weapon { damage: 25 }
        \\  }
        \\  on_attach { entity.get_mut(Health).max += 50 }
        \\  on_detach { entity.get_mut(Health).max -= 50 }
        \\}
    ;
    var cooked = try scene_cook.cookPrefab(gpa, combat, resolver.base(), null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    try std.testing.expectEqual(@as(u16, 2), acc.header.version); // format v2

    // The added component (Weapon) is in an archetype.
    try std.testing.expectEqual(@as(u32, 1), acc.archetypeCount());
    try std.testing.expectEqualStrings("Weapon", acc.schema(acc.archetype(0).schemaIndex(0)).name);

    // Hooks: one set, both present, rendered as Etch text.
    try std.testing.expectEqual(@as(u32, 1), acc.hookCount());
    const h = acc.hook(0);
    try std.testing.expect(h.on_attach != null);
    try std.testing.expect(h.on_detach != null);
    try std.testing.expect(std.mem.indexOf(u8, h.on_attach.?, "Health") != null);

    // No entity extensions in a prefab.bin.
    try std.testing.expectEqual(@as(u32, 0), acc.extensionsCount());
}

test "extends requires a component the base lacks is rejected" {
    const gpa = std.testing.allocator;
    var base = try scene_cook.cookPrefab(gpa, base_character, null, null);
    defer base.deinit(gpa);
    const base_bytes = try scene.writer.write(gpa, base.model, &base.registry);
    defer gpa.free(base_bytes);
    var resolver = OneResolver{ .name = "BaseCharacter", .bytes = base_bytes };

    const bad =
        \\component Mana { current: i32 = 0 }
        \\prefab "MagicModule" extends "BaseCharacter" requires Mana {
        \\  entity "mod" { uuid: "00000000-0000-0000-0000-0000000000e1" Mana { current: 30 } }
        \\}
    ;
    var diag: []const u8 = "";
    try std.testing.expectError(error.RequiresNotSatisfied, scene_cook.cookPrefab(gpa, bad, resolver.base(), &diag));
}

test "scene extensions clause populates the Entity Extensions + Prefab ID tables" {
    const gpa = std.testing.allocator;

    // A scene with two entities, each activating extensions by name. No prefab
    // resolution is needed for the clause itself (it is by-name, like parent:).
    const src =
        \\component Health { current: i32 = 100 }
        \\scene "S" {
        \\  entity "A" {
        \\    uuid: "00000000-0000-0000-0000-0000000000a1"
        \\    extensions: ["CombatModule", "MerchantModule"]
        \\    Health { current: 100 }
        \\  }
        \\  entity "B" {
        \\    uuid: "00000000-0000-0000-0000-0000000000b2"
        \\    extensions: ["CombatModule"]
        \\    Health { current: 80 }
        \\  }
        \\}
    ;
    var cooked = try scene_cook.cook(gpa, src, null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());

    // Two entities have active extensions.
    try std.testing.expectEqual(@as(u32, 2), acc.extensionsCount());

    // Prefab ID Table is deduplicated: CombatModule + MerchantModule = 2.
    try std.testing.expectEqual(@as(u32, 2), acc.prefabIdCount());

    // Entity A: two extensions; both names resolve through the Prefab ID Table.
    // (Entries are in entity-encounter order; A first.)
    const ea = acc.extension(0);
    try std.testing.expectEqual(@as(u8, 0xa1), acc.uuidAt(ea.uuid_ordinal)[15]);
    try std.testing.expectEqual(@as(u32, 2), ea.extension_count);
    try std.testing.expectEqualStrings("CombatModule", acc.prefabName(ea.extensionId(0)));
    try std.testing.expectEqualStrings("MerchantModule", acc.prefabName(ea.extensionId(1)));

    // Entity B: one extension, sharing the deduplicated CombatModule id with A.
    const eb = acc.extension(1);
    try std.testing.expectEqual(@as(u32, 1), eb.extension_count);
    try std.testing.expectEqual(ea.extensionId(0), eb.extensionId(0)); // same Prefab ID slot

    // No hooks in a .scene.bin.
    try std.testing.expectEqual(@as(u32, 0), acc.hookCount());
}

// ── E6 — load applies extension components + fires the on_attach seam ──

/// Tier-0 `on_attach` dispatch spy (the M1.0.9 Etch execution is out of scope;
/// E6 only proves the seam fires with the right name + hook text).
const AttachSpy = struct {
    var fired: u32 = 0;
    var saw_name: bool = false;
    var saw_text: bool = false;
    fn reset() void {
        fired = 0;
        saw_name = false;
        saw_text = false;
    }
    fn cb(_: ?*anyopaque, _: *World, _: EntityId, name: []const u8, text: ?[]const u8) anyerror!void {
        fired += 1;
        if (std.mem.eql(u8, name, "CombatModule")) saw_name = true;
        if (text != null and std.mem.indexOf(u8, text.?, "Health") != null) saw_text = true;
    }
};

test "load applies extension components and the on_attach seam fires" {
    const gpa = std.testing.allocator;

    // Cook BaseCharacter (the extends/requires base) + CombatModule (adds Weapon,
    // with on_attach), wiring the cook-time base resolver.
    var base = try scene_cook.cookPrefab(gpa, base_character, null, null);
    defer base.deinit(gpa);
    const base_bytes = try scene.writer.write(gpa, base.model, &base.registry);
    defer gpa.free(base_bytes);
    var base_res = OneResolver{ .name = "BaseCharacter", .bytes = base_bytes };

    const combat =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 10 }
        \\prefab "CombatModule" extends "BaseCharacter" requires Health {
        \\  entity "mod" {
        \\    uuid: "9c4f3a2b-1e7d-4a5c-b8e9-f4d2c3a1b5e6"
        \\    Weapon { damage: 25 }
        \\  }
        \\  on_attach { entity.get_mut(Health).max += 50 }
        \\}
    ;
    var combat_cooked = try scene_cook.cookPrefab(gpa, combat, base_res.base(), null);
    defer combat_cooked.deinit(gpa);
    const combat_bytes = try scene.writer.write(gpa, combat_cooked.model, &combat_cooked.registry);
    defer gpa.free(combat_bytes);

    // A scene with one entity activating CombatModule.
    const scene_src =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\scene "S" {
        \\  entity "npc" {
        \\    uuid: "00000000-0000-0000-0000-0000000000f1"
        \\    extensions: ["CombatModule"]
        \\    Health { current: 100, max: 100 }
        \\  }
        \\}
    ;
    var scene_cooked = try scene_cook.cook(gpa, scene_src, null);
    defer scene_cooked.deinit(gpa);
    const scene_bytes = try scene.writer.write(gpa, scene_cooked.model, &scene_cooked.registry);
    defer gpa.free(scene_bytes);

    // World mirrors the component layout; register the Tier-0 on_attach seam.
    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Health", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Weapon", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    AttachSpy.reset();
    world.registerOnAttach(null, &AttachSpy.cb);

    var ext_res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    var result = try scene.loader.loadFromBytes(&world, gpa, scene_bytes, ext_res.ext());
    defer result.deinit(gpa);

    const npc = result.uuid_to_entity.get(uuidBytes(0xf1)).?;

    // The extension's component was added (Weapon.damage == 25).
    const weapon_id = world.componentId("Weapon").?;
    const wb = world.componentBytes(npc, weapon_id) orelse return error.WeaponNotAdded;
    try std.testing.expectEqual(@as(i32, 25), std.mem.readInt(i32, wb[0..4], .little));

    // The on_attach seam fired once with the extension name + the cooked hook text.
    try std.testing.expectEqual(@as(u32, 1), AttachSpy.fired);
    try std.testing.expect(AttachSpy.saw_name);
    try std.testing.expect(AttachSpy.saw_text);

    // M1.0.9 boundary: the hook is NOT executed at load — Health.max stays 100
    // (the `+= 50` effect is M1.0.9, not E6).
    const health_id = world.componentId("Health").?;
    const hb = world.componentBytes(npc, health_id).?;
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, hb[4..8], .little)); // max @4
}

fn uuidBytes(last: u8) [16]u8 {
    var u = [_]u8{0} ** 16;
    u[15] = last;
    return u;
}
