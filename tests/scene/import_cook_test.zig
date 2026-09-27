//! A scene or prefab that imports its components cooks as `etch check` resolves
//! it: to the bytes of the same source declaring them, under their own names,
//! and a refused import refuses the cook.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");

const scene = weld_core.scene;
const scene_cook = weld_etch.scene_cook;
const World = weld_core.ecs.World;
const EntityId = weld_core.ecs.EntityId;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = weld_etch.Interpreter;
const ProjectFile = weld_etch.ProjectFile;

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

const combat =
    \\component Health { current: i32 = 100, max: i32 = 100 }
    \\component Weapon { damage: i32 = 0 }
;

fn expectChecked(files: []const ProjectFile) !void {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.validateProject(gpa, files, &diags);
    for (diags.items) |d| std.debug.print("{s}: {s}\n", .{ d.code.code(), d.primary_message });
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

fn written(cooked: *scene_cook.Cooked) ![]u8 {
    return scene.writer.write(std.testing.allocator, cooked.model, &cooked.registry);
}

fn prefabBytes(files: []const ProjectFile, index: usize, base: ?scene_cook.BaseResolver) ![]u8 {
    var cooked = try scene_cook.cookPrefabInProject(std.testing.allocator, files, index, base, null);
    defer cooked.deinit(std.testing.allocator);
    return written(&cooked);
}

fn inlinePrefabBytes(source: []const u8, base: ?scene_cook.BaseResolver) ![]u8 {
    var cooked = try scene_cook.cookPrefab(std.testing.allocator, source, base, null);
    defer cooked.deinit(std.testing.allocator);
    return written(&cooked);
}

fn expectPrefabRefused(expected: scene_cook.CookError, files: []const ProjectFile, index: usize) !void {
    try std.testing.expectError(expected, scene_cook.cookPrefabInProject(std.testing.allocator, files, index, null, null));
}

test "a prefab importing its components cooks as one declaring them" {
    const gpa = std.testing.allocator;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health, Weapon }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } Weapon { damage: 3 } }
        \\}
        },
    };
    try expectChecked(&files);
    const imported = try prefabBytes(&files, 1, null);
    defer gpa.free(imported);
    const declared = try inlinePrefabBytes(combat ++
        \\
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } Weapon { damage: 3 } }
        \\}
    , null);
    defer gpa.free(declared);
    try std.testing.expectEqualSlices(u8, declared, imported);
}

test "a scene importing its components cooks as one declaring them" {
    const gpa = std.testing.allocator;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/level.scene.etch", .source =
        \\import combat { Health }
        \\scene "Level" {
        \\  entity "npc" { uuid: "00000000-0000-0000-0000-000000000002" Health { max: 40 } }
        \\}
        },
    };
    try expectChecked(&files);
    var imported = try scene_cook.cookSceneInProject(gpa, &files, 1, null, null);
    defer imported.deinit(gpa);
    const imported_bytes = try written(&imported);
    defer gpa.free(imported_bytes);
    var declared = try scene_cook.cook(gpa, combat ++
        \\
        \\scene "Level" {
        \\  entity "npc" { uuid: "00000000-0000-0000-0000-000000000002" Health { max: 40 } }
        \\}
    , null);
    defer declared.deinit(gpa);
    const declared_bytes = try written(&declared);
    defer gpa.free(declared_bytes);
    try std.testing.expectEqualSlices(u8, declared_bytes, imported_bytes);
}

test "an aliased import cooks under the component's own name" {
    const gpa = std.testing.allocator;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health as HP }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" HP { current: 5 } }
        \\}
        },
    };
    try expectChecked(&files);
    const imported = try prefabBytes(&files, 1, null);
    defer gpa.free(imported);
    const declared = try inlinePrefabBytes(combat ++
        \\
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } }
        \\}
    , null);
    defer gpa.free(declared);
    try std.testing.expectEqualSlices(u8, declared, imported);
}

test "a component imported with its requisites cooks as one declaring them" {
    const gpa = std.testing.allocator;
    const chain =
        \\component Anchor { a: i32 = 0 }
        \\@requires(Anchor)
        \\component Transform { x: i32 = 0 }
        \\@requires(Transform)
        \\component Health { current: i32 = 100, max: i32 = 100 }
    ;
    const body =
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } }
        \\}
    ;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = chain },
        .{ .name = "src/goblin.prefab.etch", .source = "import combat { Health }\n" ++ body },
    };
    try expectChecked(&files);
    const imported = try prefabBytes(&files, 1, null);
    defer gpa.free(imported);
    const declared = try inlinePrefabBytes(chain ++ "\n" ++ body, null);
    defer gpa.free(declared);
    try std.testing.expectEqualSlices(u8, declared, imported);
}

test "a requisite its module imports refuses the cook, as it fails etch check" {
    const gpa = std.testing.allocator;
    const files = [_]ProjectFile{
        .{ .name = "src/core.etch", .source = "component Transform { x: i32 = 0 }" },
        .{ .name = "src/combat.etch", .source =
        \\import core { Transform }
        \\@requires(Transform)
        \\component Health { current: i32 = 100, max: i32 = 100 }
        },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health }
        \\import core { Transform }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try expectPrefabRefused(error.UndeclaredType, &files, 2);
}

test "an aliased extension hook runs at load under the component's own name" {
    const gpa = std.testing.allocator;
    const base_bytes = try inlinePrefabBytes(combat ++
        \\
        \\prefab "BaseCharacter" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Health { current: 100, max: 100 } }
        \\}
    , null);
    defer gpa.free(base_bytes);
    var base_res = OneResolver{ .name = "BaseCharacter", .bytes = base_bytes };
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/base.prefab.etch", .source =
        \\import combat { Health }
        \\prefab "BaseCharacter" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Health { current: 100, max: 100 } }
        \\}
        },
        .{ .name = "src/combat_module.prefab.etch", .source =
        \\import combat { Health as HP, Weapon }
        \\prefab "CombatModule" extends "BaseCharacter" requires HP {
        \\  entity "mod" { uuid: "00000000-0000-0000-0000-000000000004" Weapon { damage: 25 } }
        \\  on_attach { entity.get_mut(HP).max += 50 }
        \\}
        },
    };
    try expectChecked(&files);
    const module_bytes = try prefabBytes(&files, 2, base_res.base());
    defer gpa.free(module_bytes);

    var world = World.init();
    defer world.deinit(gpa);
    var pr = try weld_etch.parser.parse(gpa, combat);
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);
    const health = world.componentId("Health").?;
    var hv = [_]i32{ 100, 100 };
    const npc = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{health}, &[_][]const u8{std.mem.asBytes(&hv)});
    var ext_res = OneResolver{ .name = "CombatModule", .bytes = module_bytes };
    try scene.loader.runtimeActivate(&world, gpa, npc, "CombatModule", ext_res.ext());
    const hb = world.componentBytes(npc, health).?;
    try std.testing.expectEqual(@as(i32, 150), std.mem.readInt(i32, hb[4..8], .little));
}

test "an instance override of an imported component passes etch check and cooks" {
    const gpa = std.testing.allocator;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } }
        \\}
        },
        .{ .name = "src/level.scene.etch", .source =
        \\import combat { Health }
        \\scene "Level" {
        \\  instance of "Goblin" "g1" { uuid: "00000000-0000-0000-0000-000000000005" Health.current = 3 }
        \\}
        },
    };
    try expectChecked(&files);
    const goblin = try prefabBytes(&files, 1, null);
    defer gpa.free(goblin);
    var res = OneResolver{ .name = "Goblin", .bytes = goblin };
    var cooked = try scene_cook.cookSceneInProject(gpa, &files, 2, res.base(), null);
    defer cooked.deinit(gpa);
    const bytes = try written(&cooked);
    defer gpa.free(bytes);
    const acc = try scene.accessor.Accessor.open(bytes);
    const arch = acc.archetype(0);
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, arch.componentSlot(0, 0)[0..4], .little));
}

test "an import of a module the project lacks refuses the cook" {
    const files = [_]ProjectFile{
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import ghost { Health }
        \\component Weapon { damage: i32 = 0 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Weapon { damage: 3 } }
        \\}
        },
    };
    try expectPrefabRefused(error.ImportRefused, &files, 0);
}

test "an import of an item its module does not export refuses the cook" {
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Armor }
        \\component Weapon { damage: i32 = 0 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Weapon { damage: 3 } }
        \\}
        },
    };
    try expectPrefabRefused(error.ImportRefused, &files, 1);
}

test "an import of a private item refuses the cook" {
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = "private component Secret { v: i32 = 0 }" },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Secret }
        \\component Weapon { damage: i32 = 0 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Weapon { damage: 3 } }
        \\}
        },
    };
    try expectPrefabRefused(error.ImportRefused, &files, 1);
}

test "a local declaration shadows an import of its name, as in etch check" {
    const gpa = std.testing.allocator;
    const local =
        \\component Health { hp: i32 = 7 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { hp: 3 } }
        \\}
    ;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source = "import combat { Health }\n" ++ local },
    };
    try expectCheckReports(&files, .typed_extension_mismatch);
    const imported = try prefabBytes(&files, 1, null);
    defer gpa.free(imported);
    const declared = try inlinePrefabBytes(local, null);
    defer gpa.free(declared);
    try std.testing.expectEqualSlices(u8, declared, imported);
}

test "an alias naming a component the file also declares refuses the cook" {
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health as HP }
        \\component Health { hp: i32 = 7 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" HP { current: 5 } }
        \\}
        },
    };
    try expectCheckReports(&files, .duplicate_symbol);
    try expectPrefabRefused(error.DuplicateType, &files, 1);
}

test "a requisite the file imports rather than declares refuses the cook, as it fails etch check" {
    const gpa = std.testing.allocator;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health }
        \\@requires(Health)
        \\component Tag { t: i32 = 0 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Tag { t: 1 } }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
    try expectCheckReports(&files, .unknown_requisite);
    try expectCheckReports(&files, .typed_extension_mismatch);
    try expectPrefabRefused(error.UndeclaredType, &files, 1);
}

test "an import cycle in the project refuses the cook, as it fails etch check" {
    const files = [_]ProjectFile{
        .{ .name = "src/a.etch", .source = "import b { Weapon }\ncomponent Health { current: i32 = 100 }" },
        .{ .name = "src/b.etch", .source = "import a { Health }\ncomponent Weapon { damage: i32 = 0 }" },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import a { Health }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } }
        \\}
        },
    };
    try expectPrefabRefused(error.ImportRefused, &files, 2);
}

test "a project file that does not parse refuses the cook, as it fails etch check" {
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = "component Health { current: i32 = 100 " },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\component Weapon { damage: i32 = 0 }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Weapon { damage: 3 } }
        \\}
        },
    };
    try expectPrefabRefused(error.ParseFailed, &files, 1);
}

test "two imported components under one name refuse the cook" {
    const files = [_]ProjectFile{
        .{ .name = "src/a.etch", .source = "component Health { current: i32 = 100 }" },
        .{ .name = "src/b.etch", .source = "component Health { hp: i32 = 7, max: i32 = 7 }" },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import a { Health }
        \\import b { Health as Life }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Life { hp: 5 } }
        \\}
        },
    };
    try expectCheckReports(&files, .duplicate_symbol);
    try expectPrefabRefused(error.DuplicateType, &files, 2);
}

fn expectCheckReports(files: []const ProjectFile, code: weld_etch.diagnostics.DiagnosticCode) !void {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.validateProject(gpa, files, &diags);
    for (diags.items) |d| {
        if (d.code == code) return;
    }
    return error.TestExpectedDiagnostic;
}

fn expectCheckRefused(files: []const ProjectFile) !void {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.validateProject(gpa, files, &diags);
    try std.testing.expect(diags.items.len > 0);
}

test "the last import of a name binds it, as in etch check" {
    const gpa = std.testing.allocator;
    const body =
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Pos { x: 1 } }
        \\}
    ;
    const files = [_]ProjectFile{
        .{ .name = "src/a.etch", .source = "component Pos { x: i32 = 0 }" },
        .{ .name = "src/b.etch", .source = "component Other { x: i32 = 0, y: i32 = 0 }" },
        .{ .name = "src/goblin.prefab.etch", .source = "import b { Other as Pos }\nimport a { Pos }\n" ++ body },
    };
    try expectChecked(&files);
    const imported = try prefabBytes(&files, 2, null);
    defer gpa.free(imported);
    const declared = try inlinePrefabBytes("component Pos { x: i32 = 0 }\n" ++ body, null);
    defer gpa.free(declared);
    try std.testing.expectEqualSlices(u8, declared, imported);
}

test "a name the last import binds to no component names none, as in etch check" {
    const files = [_]ProjectFile{
        .{ .name = "src/a.etch", .source = "component Health { current: i32 = 100 }" },
        .{ .name = "src/b.etch", .source = "struct Stats { v: i32 = 0 }" },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import a { Health }
        \\import b { Stats as Health }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } }
        \\}
        },
    };
    try expectCheckRefused(&files);
    try expectPrefabRefused(error.UndeclaredType, &files, 2);
}

test "two imports of one name bind the later, as in etch check" {
    const gpa = std.testing.allocator;
    const body =
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { hp: 5 } }
        \\}
    ;
    const files = [_]ProjectFile{
        .{ .name = "src/a.etch", .source = "component Health { current: i32 = 100 }" },
        .{ .name = "src/b.etch", .source = "component Health { hp: i32 = 7, max: i32 = 7 }" },
        .{ .name = "src/goblin.prefab.etch", .source = "import a { Health }\nimport b { Health }\n" ++ body },
    };
    try expectChecked(&files);
    const imported = try prefabBytes(&files, 2, null);
    defer gpa.free(imported);
    const declared = try inlinePrefabBytes("component Health { hp: i32 = 7, max: i32 = 7 }\n" ++ body, null);
    defer gpa.free(declared);
    try std.testing.expectEqualSlices(u8, declared, imported);
}

test "a requisite reached only through an import is not the file's to name, as in etch check" {
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source =
        \\component Transform { x: i32 = 0 }
        \\@requires(Transform)
        \\component Health { current: i32 = 100, max: i32 = 100 }
        },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } Transform { x: 3 } }
        \\}
        },
    };
    try expectCheckRefused(&files);
    try expectPrefabRefused(error.UndeclaredType, &files, 1);
}

test "a builtin declaration shadows an import of its name, as in etch check" {
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source =
        \\import combat { Health as Error }
        \\prefab "Goblin" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Error { current: 5 } }
        \\}
        },
    };
    try expectCheckRefused(&files);
    try expectPrefabRefused(error.UndeclaredType, &files, 1);
}

test "an alias spelling a builtin type name refuses a hook's cook" {
    const gpa = std.testing.allocator;
    const base_bytes = try inlinePrefabBytes(combat ++
        \\
        \\prefab "BaseCharacter" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Health { current: 100, max: 100 } }
        \\}
    , null);
    defer gpa.free(base_bytes);
    var base_res = OneResolver{ .name = "BaseCharacter", .bytes = base_bytes };
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/base.prefab.etch", .source =
        \\import combat { Health }
        \\prefab "BaseCharacter" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Health { current: 100, max: 100 } }
        \\}
        },
        .{ .name = "src/combat_module.prefab.etch", .source =
        \\import combat { Health as Entity, Weapon }
        \\prefab "CombatModule" extends "BaseCharacter" requires Entity {
        \\  entity "mod" { uuid: "00000000-0000-0000-0000-000000000004" Weapon { damage: 25 } }
        \\  on_attach {
        \\    let e: Entity = entity
        \\    e.get_mut(Entity).max += 50
        \\  }
        \\}
        },
    };
    try expectCheckReports(&files, .duplicate_symbol);
    try std.testing.expectError(error.HookRefused, scene_cook.cookPrefabInProject(gpa, &files, 2, base_res.base(), null));
}

test "a hook names what the last import of a name binds, as in etch check" {
    const gpa = std.testing.allocator;
    const a = "component Pos { x: i32 = 0 }\ncomponent Mark { m: i32 = 0 }";
    const base_bytes = try inlinePrefabBytes(a ++
        \\
        \\prefab "Base" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Pos { x: 0 } }
        \\}
    , null);
    defer gpa.free(base_bytes);
    var base_res = OneResolver{ .name = "Base", .bytes = base_bytes };
    const files = [_]ProjectFile{
        .{ .name = "src/a.etch", .source = a },
        .{ .name = "src/b.etch", .source = "component Other { x: i32 = 0 }" },
        .{ .name = "src/base.prefab.etch", .source =
        \\import a { Pos }
        \\prefab "Base" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000003" Pos { x: 0 } }
        \\}
        },
        .{ .name = "src/mod.prefab.etch", .source =
        \\import b { Other as Pos }
        \\import a { Pos, Mark }
        \\prefab "Mod" extends "Base" requires Pos {
        \\  entity "m" { uuid: "00000000-0000-0000-0000-000000000004" Mark { m: 1 } }
        \\  on_attach { entity.get_mut(Pos).x += 7 }
        \\}
        },
    };
    try expectChecked(&files);
    const mod_bytes = try prefabBytes(&files, 3, base_res.base());
    defer gpa.free(mod_bytes);

    var world = World.init();
    defer world.deinit(gpa);
    var pr = try weld_etch.parser.parse(gpa, a);
    defer pr.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);
    const pos = world.componentId("Pos").?;
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{pos});
    var ext_res = OneResolver{ .name = "Mod", .bytes = mod_bytes };
    try scene.loader.runtimeActivate(&world, gpa, e, "Mod", ext_res.ext());
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, world.componentBytes(e, pos).?[0..4], .little));
}

const goblin_prefab =
    \\import combat { Health, Weapon }
    \\prefab "Goblin" {
    \\  entity "root" { uuid: "00000000-0000-0000-0000-000000000001" Health { current: 5 } Weapon { damage: 3 } }
    \\}
;

test "a scene instancing a prefab cooks without naming the prefab's components, as etch check allows" {
    const gpa = std.testing.allocator;
    const instance =
        \\scene "Level" {
        \\  instance of "Goblin" "G" { uuid: "00000000-0000-0000-0000-0000000000a1" }
        \\}
    ;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source = goblin_prefab },
        .{ .name = "src/level.scene.etch", .source = instance },
    };
    try expectChecked(&files);
    const goblin = try prefabBytes(&files, 1, null);
    defer gpa.free(goblin);
    var resolver = OneResolver{ .name = "Goblin", .bytes = goblin };

    var cooked = try scene_cook.cookSceneInProject(gpa, &files, 2, resolver.base(), null);
    defer cooked.deinit(gpa);
    const bytes = try written(&cooked);
    defer gpa.free(bytes);
    const importing = [_]ProjectFile{
        files[0],
        files[1],
        .{ .name = "src/level.scene.etch", .source = "import combat { Health, Weapon }\n" ++ instance },
    };
    var reference = try scene_cook.cookSceneInProject(gpa, &importing, 2, resolver.base(), null);
    defer reference.deinit(gpa);
    const reference_bytes = try written(&reference);
    defer gpa.free(reference_bytes);
    try std.testing.expectEqualSlices(u8, reference_bytes, bytes);
}

test "a prefab variant cooks without naming its base's components, as etch check allows" {
    const gpa = std.testing.allocator;
    const variant =
        \\import combat { Weapon }
        \\prefab "Elite" of "Goblin" { entity "root" { Weapon { damage: 9 } } }
    ;
    const files = [_]ProjectFile{
        .{ .name = "src/combat.etch", .source = combat },
        .{ .name = "src/goblin.prefab.etch", .source = goblin_prefab },
        .{ .name = "src/elite.prefab.etch", .source = variant },
    };
    try expectChecked(&files);
    const goblin = try prefabBytes(&files, 1, null);
    defer gpa.free(goblin);
    var resolver = OneResolver{ .name = "Goblin", .bytes = goblin };

    const bytes = try prefabBytes(&files, 2, resolver.base());
    defer gpa.free(bytes);
    const importing = [_]ProjectFile{
        files[0],
        files[1],
        // A base column registers after the file's own imports.
        .{ .name = "src/elite.prefab.etch", .source =
        \\import combat { Weapon, Health }
        \\prefab "Elite" of "Goblin" { entity "root" { Weapon { damage: 9 } } }
        },
    };
    const reference_bytes = try prefabBytes(&importing, 2, resolver.base());
    defer gpa.free(reference_bytes);
    try std.testing.expectEqualSlices(u8, reference_bytes, bytes);
}
