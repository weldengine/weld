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
// M1.0.9 — hook execution (the interpreter binds the real on_attach/on_detach
// seam) + the deferred-drain stand-in (command buffer / observer registry).
const Interpreter = weld_etch.Interpreter;
const ComponentId = weld_core.ecs.registry.ComponentId;
const command_buffer = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer.CommandBuffer;

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

// ── M1.1.1-HF4 — fatal cook error E1797 on additive extension conflict (§30.5) ──
// (was M1.0.18's non-fatal warning; reject ratified — `error.ExtensionAdditiveConflict`)

/// Multi-entry in-process resolver mapping extension prefab names to their cooked
/// bytes (the additive-conflict gate resolves extension component sets through
/// this, exactly like `of`/`extends`). The bytes must outlive the cook.
const MultiResolver = struct {
    names: []const []const u8,
    blobs: []const []const u8,
    fn resolve(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *MultiResolver = @ptrCast(@alignCast(ctx));
        for (self.names, self.blobs) |n, b| if (std.mem.eql(u8, name, n)) return b;
        return null;
    }
    fn base(self: *MultiResolver) scene_cook.BaseResolver {
        return .{ .ctx = self, .resolveFn = MultiResolver.resolve };
    }
    fn ext(self: *MultiResolver) scene.loader.ExtensionResolver {
        return .{ .ctx = self, .resolveFn = MultiResolver.resolve };
    }
};

/// Cook an `extends` prefab source to its `.prefab.bin` bytes (caller frees). No
/// `requires` → the base need not exist, cookable with a null resolver. The bytes
/// are a self-contained serialized artifact, independent of the (freed) `Cooked`.
fn prefabBytes(gpa: std.mem.Allocator, src: []const u8) ![]const u8 {
    var c = try scene_cook.cookPrefab(gpa, src, null, null);
    defer c.deinit(gpa);
    return scene.writer.write(gpa, c.model, &c.registry);
}

const ext_combat = // CombatModule: declares Inventory + Weapon
    \\component Inventory { slots: i32 = 0 }
    \\component Weapon { damage: i32 = 0 }
    \\prefab "CombatModule" extends "Base" {
    \\  entity "m" { uuid: "00000000-0000-0000-0000-0000000000c1" Inventory { slots: 30 } Weapon { damage: 10 } }
    \\}
;
const ext_merchant = // MerchantModule: declares Inventory only
    \\component Inventory { slots: i32 = 0 }
    \\prefab "MerchantModule" extends "Base" {
    \\  entity "m" { uuid: "00000000-0000-0000-0000-0000000000c2" Inventory { slots: 100 } }
    \\}
;
const ext_trade = // TradeModule: declares Inventory only
    \\component Inventory { slots: i32 = 0 }
    \\prefab "TradeModule" extends "Base" {
    \\  entity "m" { uuid: "00000000-0000-0000-0000-0000000000c3" Inventory { slots: 50 } }
    \\}
;
const ext_arsenal = // ArsenalModule: declares Weapon only
    \\component Weapon { damage: i32 = 0 }
    \\prefab "ArsenalModule" extends "Base" {
    \\  entity "m" { uuid: "00000000-0000-0000-0000-0000000000c4" Weapon { damage: 5 } }
    \\}
;

// The `extensions:` clause + additive-conflict gate run through the SAME scene
// `build` loop for `entity` and `instance` — these tests use `entity`. A conflict
// (≥2 active extensions declaring the same component) is a FATAL cook error
// (`E1797 ExtensionAdditiveConflict` → `error.ExtensionAdditiveConflict`), the
// strictly-additive `extends` reject policy (M1.1.1-HF4). Disjoint components cook
// cleanly. Together with the runtime `error.ExtensionComponentConflict` this
// guarantees `cooked ⇒ loadable`.

test "cook fails fatally when two extensions declare the same component" {
    const gpa = std.testing.allocator;
    const m = try prefabBytes(gpa, ext_merchant); // Inventory
    defer gpa.free(m);
    const t = try prefabBytes(gpa, ext_trade); // Inventory
    defer gpa.free(t);
    var mr = MultiResolver{ .names = &.{ "MerchantModule", "TradeModule" }, .blobs = &.{ m, t } };
    const src =
        \\component Marker { v: i32 = 0 }
        \\scene "S" {
        \\  entity "npc" {
        \\    uuid: "00000000-0000-0000-0000-0000000000f1"
        \\    extensions: ["MerchantModule", "TradeModule"]
        \\    Marker { v: 1 }
        \\  }
        \\}
    ;
    // Fatal: the cook returns `error.ExtensionAdditiveConflict` and produces no
    // `Cooked` (no output). `diag_out`, when provided, carries the static E1797
    // message (no leak — a `CookError` message is never gpa-owned).
    var diag: []const u8 = "";
    try std.testing.expectError(error.ExtensionAdditiveConflict, scene_cook.cookScene(gpa, src, mr.base(), &diag));
    try std.testing.expect(diag.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, diag, "additive") != null);
}

test "cook succeeds when extensions declare disjoint components" {
    const gpa = std.testing.allocator;
    const m = try prefabBytes(gpa, ext_merchant); // Inventory
    defer gpa.free(m);
    const a = try prefabBytes(gpa, ext_arsenal); // Weapon
    defer gpa.free(a);
    var mr = MultiResolver{ .names = &.{ "MerchantModule", "ArsenalModule" }, .blobs = &.{ m, a } };
    const src =
        \\component Marker { v: i32 = 0 }
        \\scene "S" {
        \\  entity "npc" {
        \\    uuid: "00000000-0000-0000-0000-0000000000f1"
        \\    extensions: ["MerchantModule", "ArsenalModule"]
        \\    Marker { v: 1 }
        \\  }
        \\}
    ;
    // Disjoint (Inventory vs Weapon): the cook succeeds with no error.
    var cooked = try scene_cook.cookScene(gpa, src, mr.base(), null);
    cooked.deinit(gpa);
}

test "cook fails on the first conflicting component" {
    const gpa = std.testing.allocator;
    const c = try prefabBytes(gpa, ext_combat); // Inventory + Weapon
    defer gpa.free(c);
    const m = try prefabBytes(gpa, ext_merchant); // Inventory
    defer gpa.free(m);
    const a = try prefabBytes(gpa, ext_arsenal); // Weapon
    defer gpa.free(a);
    var mr = MultiResolver{ .names = &.{ "CombatModule", "MerchantModule", "ArsenalModule" }, .blobs = &.{ c, m, a } };
    const src =
        \\component Marker { v: i32 = 0 }
        \\scene "S" {
        \\  entity "npc" {
        \\    uuid: "00000000-0000-0000-0000-0000000000f1"
        \\    extensions: ["CombatModule", "MerchantModule", "ArsenalModule"]
        \\    Marker { v: 1 }
        \\  }
        \\}
    ;
    // Inventory (Combat+Merchant) and Weapon (Combat+Arsenal) both conflict; the
    // cook fails ONCE, fatally, short-circuiting on the first — no enumeration.
    try std.testing.expectError(error.ExtensionAdditiveConflict, scene_cook.cookScene(gpa, src, mr.base(), null));
}

test "cooked scene with extensions is loadable" {
    // Contract test — the core deliverable. A cooked multi-extension scene with
    // DISJOINT components loads cleanly and every extension's components are
    // present (the positive side of `cooked ⇒ loadable`).
    const gpa = std.testing.allocator;
    const m = try prefabBytes(gpa, ext_merchant); // Inventory
    defer gpa.free(m);
    const a = try prefabBytes(gpa, ext_arsenal); // Weapon
    defer gpa.free(a);

    const src =
        \\component Marker { v: i32 = 0 }
        \\scene "S" {
        \\  entity "npc" {
        \\    uuid: "00000000-0000-0000-0000-0000000000f1"
        \\    extensions: ["MerchantModule", "ArsenalModule"]
        \\    Marker { v: 1 }
        \\  }
        \\}
    ;
    var cooked = try scene_cook.cook(gpa, src, null);
    defer cooked.deinit(gpa);
    const scene_bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(scene_bytes);

    // A World mirroring the base + extension component layout (all i32-sized).
    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Marker", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Inventory", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Weapon", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });

    var mr = MultiResolver{ .names = &.{ "MerchantModule", "ArsenalModule" }, .blobs = &.{ m, a } };
    var result = try scene.loader.loadFromBytes(&world, gpa, scene_bytes, mr.ext());
    defer result.deinit(gpa);

    const npc = result.uuid_to_entity.get(uuidBytes(0xf1)).?;
    // Base component + BOTH extensions' components are present on the entity.
    try std.testing.expect(world.componentBytes(npc, world.componentId("Marker").?) != null);
    try std.testing.expect(world.componentBytes(npc, world.componentId("Inventory").?) != null);
    try std.testing.expect(world.componentBytes(npc, world.componentId("Weapon").?) != null);
    try std.testing.expect(world.hasEntityExtension(npc, "MerchantModule"));
    try std.testing.expect(world.hasEntityExtension(npc, "ArsenalModule"));
}

test "runtime activate rejects a component the entity already carries" {
    // The dynamic counterpart of the static cook gate: `activate_extension` adding
    // a component the entity already carries is rejected with
    // `error.ExtensionComponentConflict`, and the entity is left unchanged.
    const gpa = std.testing.allocator;
    const combat_bytes = try cookCombatModule(gpa); // adds Weapon{25}, on_attach Health.max += 50
    defer gpa.free(combat_bytes);

    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Health", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &.{} });
    const weapon_id = try world.registry.registerComponentRaw(gpa, .{ .name = "Weapon", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });

    // Entity already carries Weapon (damage 10) — the component CombatModule adds.
    const health_id = world.componentId("Health").?;
    var hv = [_]i32{ 100, 100 };
    var wv: i32 = 10;
    const eid = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{ health_id, weapon_id }, &[_][]const u8{ std.mem.asBytes(&hv), std.mem.asBytes(&wv) });

    var res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    try std.testing.expectError(error.ExtensionComponentConflict, scene.loader.runtimeActivate(&world, gpa, eid, "CombatModule", res.ext()));

    // Unchanged: Weapon keeps its value, on_attach never ran (Health.max stays
    // 100), and no extension record was created (rejected at prevalidate).
    const wb = world.componentBytes(eid, weapon_id).?;
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, wb[0..4], .little));
    try std.testing.expectEqual(@as(i32, 100), healthMax(&world, eid));
    try std.testing.expect(!world.hasEntityExtension(eid, "CombatModule"));
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

    // The bare Tier-0 seam (an AttachSpy callback, no Etch bridge bound) does NOT
    // execute the hook — Health.max stays 100. The M1.0.9 headline test below
    // binds the real interpreter callback and asserts the `+= 50` effect (150).
    const health_id = world.componentId("Health").?;
    const hb = world.componentBytes(npc, health_id).?;
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, hb[4..8], .little)); // max @4
}

fn uuidBytes(last: u8) [16]u8 {
    var u = [_]u8{0} ** 16;
    u[15] = last;
    return u;
}

// ── M1.0.9 — hook EXECUTION (the E6 seam now re-parses + runs the cooked text) ──
//
// These tests live here rather than inline in `interp.zig` (where the brief lists
// the activate/deactivate/has/active tests) because they need the cook pipeline
// (`scene_cook.cookPrefab`) + the loader, which would form a circular import from
// `interp.zig` (`scene_cook` already imports `interp`). Same tier-dependency
// reason as the M1.0.8 cross-file tests. See the brief's Recorded deviations.

/// Cook `CombatModule extends BaseCharacter` to `.prefab.bin` bytes (adds
/// `Weapon`; `on_attach` does `Health.max += 50`, `on_detach` `-= 50`). The
/// `Health` declared here matches `base_character`'s layout. Caller frees.
fn cookCombatModule(gpa: std.mem.Allocator) ![]const u8 {
    var base = try scene_cook.cookPrefab(gpa, base_character, null, null);
    defer base.deinit(gpa);
    const base_bytes = try scene.writer.write(gpa, base.model, &base.registry);
    defer gpa.free(base_bytes);
    var base_res = OneResolver{ .name = "BaseCharacter", .bytes = base_bytes };
    const combat =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 10 }
        \\prefab "CombatModule" extends "BaseCharacter" requires Health {
        \\  entity "mod" { uuid: "9c4f3a2b-1e7d-4a5c-b8e9-f4d2c3a1b5e6" Weapon { damage: 25 } }
        \\  on_attach { entity.get_mut(Health).max += 50 }
        \\  on_detach { entity.get_mut(Health).max -= 50 }
        \\}
    ;
    var cooked = try scene_cook.cookPrefab(gpa, combat, base_res.base(), null);
    defer cooked.deinit(gpa);
    return scene.writer.write(gpa, cooked.model, &cooked.registry);
}

/// Compile + bind an interpreter declaring `Health` + `Weapon` (WITH fields, so a
/// hook's `Health.max` resolves) into `world`, registering the real on_attach /
/// on_detach execution seam. The caller owns `pr` (parse result) and `interp`.
const HookEnv = struct {
    pr: parser.ParseResult,
    interp: Interpreter,
    fn deinit(self: *HookEnv, gpa: std.mem.Allocator) void {
        self.interp.deinit();
        self.pr.deinit(gpa);
    }
};

fn spawnHealth(world: *World, gpa: std.mem.Allocator, current: i32, max: i32) !EntityId {
    const cid = world.componentId("Health").?;
    var hv = [_]i32{ current, max };
    return world.spawnDynamicWithValues(gpa, &[_]ComponentId{cid}, &[_][]const u8{std.mem.asBytes(&hv)});
}

fn healthMax(world: *World, entity: EntityId) i32 {
    const hb = world.componentBytes(entity, world.componentId("Health").?).?;
    return std.mem.readInt(i32, hb[4..8], .little);
}

test "scene with active extension executes on_attach at load — Health.max adjusted (M1.0.9 headline)" {
    const gpa = std.testing.allocator;

    const combat_bytes = try cookCombatModule(gpa);
    defer gpa.free(combat_bytes);

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

    var world = World.init();
    defer world.deinit(gpa);

    // Compile + bind an interpreter declaring Health+Weapon WITH fields and
    // registering the real on_attach execution seam.
    const prog =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 0 }
        \\rule keep(entity: Entity) when entity has Health {}
    ;
    var prog_pr = try parser.parse(gpa, prog);
    defer prog_pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), prog_pr.diagnostics.len);
    var interp = try Interpreter.compile(gpa, &prog_pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    var ext_res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    var result = try scene.loader.loadFromBytes(&world, gpa, scene_bytes, ext_res.ext());
    defer result.deinit(gpa);

    const npc = result.uuid_to_entity.get(uuidBytes(0xf1)).?;
    // The headline: on_attach RAN at load — Health.max went 100 → 150.
    try std.testing.expectEqual(@as(i32, 150), healthMax(&world, npc));
    // The extension's component is present and the extension is tracked active.
    try std.testing.expect(world.componentBytes(npc, world.componentId("Weapon").?) != null);
    try std.testing.expect(world.hasEntityExtension(npc, "CombatModule"));
}

test "entity.activate_extension executes on_attach (M1.0.9)" {
    const gpa = std.testing.allocator;
    const combat_bytes = try cookCombatModule(gpa);
    defer gpa.free(combat_bytes);

    var world = World.init();
    defer world.deinit(gpa);

    // `activate_extension` ENQUEUES a deferred command (B1); the structural add
    // (Weapon) + on_attach are applied at the tick-boundary flush, after the live
    // archetype walk. Single entity here; the multi-entity no-corruption case is
    // the dedicated B1 test below.
    const prog =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 0 }
        \\rule go(entity: Entity) when entity has Health and not entity has Weapon {
        \\  entity.activate_extension("CombatModule")
        \\}
    ;
    var pr = try parser.parse(gpa, prog);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);
    var res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    interp.setExtensionResolver(res.ext());

    const eid = try spawnHealth(&world, gpa, 100, 100);
    _ = try interp.runFor(&world, 1);

    try std.testing.expectEqual(@as(i32, 150), healthMax(&world, eid)); // on_attach
    try std.testing.expect(world.componentBytes(eid, world.componentId("Weapon").?) != null);
    try std.testing.expect(world.hasEntityExtension(eid, "CombatModule"));
}

test "has_extension / active_extensions (Etch methods) reflect activation (M1.0.9)" {
    const gpa = std.testing.allocator;
    const combat_bytes = try cookCombatModule(gpa);
    defer gpa.free(combat_bytes);

    var world = World.init();
    defer world.deinit(gpa);

    const prog =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 0 }
        \\component Probe { has_combat: bool = false, count: i32 = 0 }
        \\rule probe(entity: Entity) when entity has Probe {
        \\  entity.get_mut(Probe).has_combat = entity.has_extension("CombatModule")
        \\  entity.get_mut(Probe).count = entity.active_extensions().len() as i32
        \\}
    ;
    var pr = try parser.parse(gpa, prog);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);
    var res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    interp.setExtensionResolver(res.ext());

    // Spawn Health+Probe, then activate directly via the loader entry (no rule
    // iteration → the immediate component add is unambiguously safe).
    const health_id = world.componentId("Health").?;
    const probe_id = world.componentId("Probe").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{ health_id, probe_id });
    try scene.loader.runtimeActivate(&world, gpa, eid, "CombatModule", res.ext());

    _ = try interp.runFor(&world, 1); // probe reads has_extension / active_extensions
    const pb = world.componentBytes(eid, probe_id).?;
    try std.testing.expect(pb[0] != 0); // has_combat == true (bool @0)
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, pb[4..8], .little)); // active_extensions().len() == 1
}

test "entity.deactivate_extension executes on_detach and removes components (M1.0.9)" {
    const gpa = std.testing.allocator;
    const combat_bytes = try cookCombatModule(gpa);
    defer gpa.free(combat_bytes);

    var world = World.init();
    defer world.deinit(gpa);

    const prog =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 0 }
        \\rule off(entity: Entity) when entity has Weapon {
        \\  entity.deactivate_extension("CombatModule")
        \\}
    ;
    var pr = try parser.parse(gpa, prog);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);
    var res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    interp.setExtensionResolver(res.ext());

    // Activate first (direct loader entry: max 100→150, Weapon added).
    const eid = try spawnHealth(&world, gpa, 100, 100);
    try scene.loader.runtimeActivate(&world, gpa, eid, "CombatModule", res.ext());
    const weapon_id = world.componentId("Weapon").?;
    try std.testing.expectEqual(@as(i32, 150), healthMax(&world, eid));
    try std.testing.expect(world.componentBytes(eid, weapon_id) != null);

    // The `off` rule (single entity carrying Weapon) deactivates.
    _ = try interp.runFor(&world, 1);

    // on_detach ran (max 150 → 100) and the extension's component is gone.
    try std.testing.expectEqual(@as(i32, 100), healthMax(&world, eid));
    try std.testing.expect(world.componentBytes(eid, weapon_id) == null);
    try std.testing.expect(!world.hasEntityExtension(eid, "CombatModule"));
}

test "multi-entity rule activate_extension defers without corrupting iteration (M1.0.9 B1)" {
    const gpa = std.testing.allocator;
    const combat_bytes = try cookCombatModule(gpa);
    defer gpa.free(combat_bytes);

    var world = World.init();
    defer world.deinit(gpa);

    // No `not has Weapon` guard: B1 defers the structural add to the tick boundary,
    // so the rule's live archetype walk never sees a mid-walk migration. Every one
    // of the N matched entities enqueues; the flush activates them all afterwards.
    const prog =
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\component Weapon { damage: i32 = 0 }
        \\rule go(entity: Entity) when entity has Health {
        \\  entity.activate_extension("CombatModule")
        \\}
    ;
    var pr = try parser.parse(gpa, prog);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);
    var res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    interp.setExtensionResolver(res.ext());

    // Several entities in the SAME archetype — the live-walk corruption case.
    const n = 5;
    var ents: [n]EntityId = undefined;
    for (&ents) |*e| e.* = try spawnHealth(&world, gpa, 100, 100);

    _ = try interp.runFor(&world, 1);

    // Every matched entity was activated after the flush — none skipped, no crash.
    const weapon_id = world.componentId("Weapon").?;
    for (ents) |e| {
        try std.testing.expectEqual(@as(i32, 150), healthMax(&world, e)); // on_attach
        try std.testing.expect(world.componentBytes(e, weapon_id) != null); // component added
        try std.testing.expect(world.hasEntityExtension(e, "CombatModule"));
    }
}

test "on_attach-issued structural command is drained before on_spawned (M1.0.9)" {
    const gpa = std.testing.allocator;
    const combat_bytes = try cookCombatModule(gpa);
    defer gpa.free(combat_bytes);

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

    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Health", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Weapon", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    DrainSpy.marker_id = try world.registry.registerComponentRaw(gpa, .{ .name = "Marker", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    DrainSpy.saw_marker_at_spawn = false;

    // Stand-in for a hook that issues a DEFERRED structural change: the attach
    // callback enqueues `add_component(Marker)` into the world's shared observer-
    // deferred buffer — the exact channel `execHookText` routes a hook's deferred
    // structural change into. (The interpreter has no `entity.add(T)`/`spawn` in
    // bodies — S4 boundary — and tag mutation is not in the cookable hook subset,
    // so a cooked Etch hook cannot itself issue a deferred structural change; this
    // Tier-0 stand-in exercises the same drain channel + ordering. See the brief's
    // Recorded deviations.)
    world.registerOnAttach(null, &DrainSpy.attachCb);
    try world.observer_registry.registerOnSpawned(gpa, &world, null, &DrainSpy.onSpawnedCb);

    var ext_res = OneResolver{ .name = "CombatModule", .bytes = combat_bytes };
    var result = try scene.loader.loadFromBytes(&world, gpa, scene_bytes, ext_res.ext());
    defer result.deinit(gpa);

    const npc = result.uuid_to_entity.get(uuidBytes(0xf1)).?;
    // The deferred command was drained: the entity carries Marker after load.
    try std.testing.expect(world.componentBytes(npc, DrainSpy.marker_id) != null);
    // And it was drained BEFORE on_spawned (the spawn observer saw Marker).
    try std.testing.expect(DrainSpy.saw_marker_at_spawn);
}

/// Tier-0 stand-in for a hook that issues a deferred structural change (see the
/// drain test). The attach callback enqueues an `add_component(Marker)` into the
/// registry's deferred buffer; the on_spawned observer records whether the
/// command was already applied when the spawn lifecycle fired.
const DrainSpy = struct {
    var marker_id: ComponentId = undefined;
    var saw_marker_at_spawn: bool = false;
    var marker_bytes = [_]u8{ 1, 0, 0, 0 };
    fn attachCb(_: ?*anyopaque, world: *World, entity: EntityId, _: []const u8, _: ?[]const u8) anyerror!void {
        if (world.observer_registry.deferred == null) {
            world.observer_registry.deferred = CommandBuffer.init(std.testing.allocator, world);
        }
        try world.observer_registry.deferred.?.commands.append(std.testing.allocator, .{ .add_component = .{ .entity = entity, .component_id = marker_id, .bytes = marker_bytes[0..] } });
    }
    fn onSpawnedCb(_: ?*anyopaque, world: *World, entity: EntityId, _: ?ComponentId, _: ?*const anyopaque, _: ?*const anyopaque, _: *CommandBuffer) anyerror!void {
        if (world.componentBytes(entity, marker_id) != null) saw_marker_at_spawn = true;
    }
};
