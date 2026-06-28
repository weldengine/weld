//! M1.0.6 E3/E4/E6 — cross-module capstone: one scene exercising prefab
//! instancing (with a per-field override), an entity→entity cross-reference, and
//! an active extension, end to end (Etch cook → `.scene.bin` → ECS load). Asserts
//! entity count, an overridden field, the resolved reference handle, the added
//! extension component, and that the `on_attach` Tier-0 seam fired (hook
//! EXECUTION is M1.0.9 — see extensions_test.zig).

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const scene_cook = weld_etch.scene_cook;
const scene = weld_core.scene;
const World = weld_core.ecs.World;
const EntityId = weld_core.ecs.EntityId;

/// Multi-name in-process resolver (cook base-prefab + load extension).
const MultiResolver = struct {
    names: []const []const u8,
    blobs: []const []const u8,
    fn resolve(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *MultiResolver = @ptrCast(@alignCast(ctx));
        for (self.names, self.blobs) |n, b| if (std.mem.eql(u8, n, name)) return b;
        return null;
    }
    fn base(self: *MultiResolver) scene_cook.BaseResolver {
        return .{ .ctx = self, .resolveFn = MultiResolver.resolve };
    }
    fn ext(self: *MultiResolver) scene.loader.ExtensionResolver {
        return .{ .ctx = self, .resolveFn = MultiResolver.resolve };
    }
};

const AttachSpy = struct {
    var fired: u32 = 0;
    fn reset() void {
        fired = 0;
    }
    fn cb(_: ?*anyopaque, _: *World, _: EntityId, _: []const u8, _: ?[]const u8) anyerror!void {
        fired += 1;
    }
};

fn uuidBytes(last: u8) [16]u8 {
    var u = [_]u8{0} ** 16;
    u[15] = last;
    return u;
}

const torch_prefab =
    \\component Transform { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 }
    \\component Light { intensity: f32 = 2000.0, radius: f32 = 8.0 }
    \\prefab "Torch" {
    \\  entity "root" {
    \\    uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e"
    \\    Transform { x: 1.0 }
    \\    Light { intensity: 1500.0, radius: 6.0 }
    \\  }
    \\}
;

const base_char =
    \\component Health { current: i32 = 100, max: i32 = 100 }
    \\prefab "BaseChar" {
    \\  entity "root" { uuid: "9c4f3a2b-1e7d-4a5c-b8e9-f4d2c3a1b5e6" Health { current: 100, max: 100 } }
    \\}
;

const combat_module =
    \\component Health { current: i32 = 100, max: i32 = 100 }
    \\component Weapon { damage: i32 = 10 }
    \\prefab "CombatModule" extends "BaseChar" requires Health {
    \\  entity "mod" { uuid: "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d" Weapon { damage: 25 } }
    \\  on_attach { entity.get_mut(Health).max += 50 }
    \\}
;

const scene_src =
    \\component Transform { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 }
    \\component Light { intensity: f32 = 2000.0, radius: f32 = 8.0 }
    \\component Health { current: i32 = 100, max: i32 = 100 }
    \\component Target { who: Entity }
    \\scene "Village" {
    \\  instance of "Torch" "T1" { uuid: "00000000-0000-0000-0000-000000000011" Light.intensity = 3000.0 }
    \\  instance of "Torch" "T2" { uuid: "00000000-0000-0000-0000-000000000012" }
    \\  entity "Boss" {
    \\    uuid: "00000000-0000-0000-0000-0000000000b0"
    \\    extensions: ["CombatModule"]
    \\    Health { current: 100, max: 100 }
    \\  }
    \\  entity "Targeter" {
    \\    uuid: "00000000-0000-0000-0000-000000000002"
    \\    Target { who: "Boss" }
    \\  }
    \\}
;

fn cookStandalone(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var c = try scene_cook.cookPrefab(gpa, src, null, null);
    defer c.deinit(gpa);
    return scene.writer.write(gpa, c.model, &c.registry);
}

test "scene with prefab instances, a cross-ref and an extension loads end to end" {
    const gpa = std.testing.allocator;

    // Cook the three prefabs.
    const torch_bytes = try cookStandalone(gpa, torch_prefab);
    defer gpa.free(torch_bytes);
    const base_bytes = try cookStandalone(gpa, base_char);
    defer gpa.free(base_bytes);

    var base_only = MultiResolver{ .names = &.{"BaseChar"}, .blobs = &.{base_bytes} };
    var combat = try scene_cook.cookPrefab(gpa, combat_module, base_only.base(), null);
    defer combat.deinit(gpa);
    const combat_bytes = try scene.writer.write(gpa, combat.model, &combat.registry);
    defer gpa.free(combat_bytes);

    // Cook the scene (instance flattening resolves "Torch").
    var torch_only = MultiResolver{ .names = &.{"Torch"}, .blobs = &.{torch_bytes} };
    var cooked = try scene_cook.cookScene(gpa, scene_src, torch_only.base(), null);
    defer cooked.deinit(gpa);
    const scene_bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(scene_bytes);

    // Load into a World mirroring the component layout, with the on_attach seam +
    // the extension resolver ("CombatModule").
    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Transform", .size = 12, .alignment = 4, .default_bytes = &[_]u8{0} ** 12, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Light", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Health", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Weapon", .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Target", .size = 8, .alignment = 8, .default_bytes = &[_]u8{0xFF} ** 8, .fields = &.{} });
    AttachSpy.reset();
    world.registerOnAttach(null, &AttachSpy.cb);

    var ext_res = MultiResolver{ .names = &.{"CombatModule"}, .blobs = &.{combat_bytes} };
    var result = try scene.loader.loadFromBytes(&world, gpa, scene_bytes, ext_res.ext());
    defer result.deinit(gpa);

    // 4 entities: T1, T2, Boss, Targeter.
    try std.testing.expectEqual(@as(usize, 4), world.entityCount());

    const light_id = world.componentId("Light").?;
    const t1 = result.uuid_to_entity.get(uuidBytes(0x11)).?;
    const t2 = result.uuid_to_entity.get(uuidBytes(0x12)).?;
    // E3: per-field override on T1 (intensity 3000), inherited on T2 (1500).
    try std.testing.expectApproxEqAbs(@as(f32, 3000.0), @as(f32, @bitCast(std.mem.readInt(u32, world.componentBytes(t1, light_id).?[0..4], .little))), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1500.0), @as(f32, @bitCast(std.mem.readInt(u32, world.componentBytes(t2, light_id).?[0..4], .little))), 1e-3);

    // E4: Targeter.Target.who resolved to Boss's runtime handle.
    const boss = result.uuid_to_entity.get(uuidBytes(0xb0)).?;
    const targeter = result.uuid_to_entity.get(uuidBytes(0x02)).?;
    const target_id = world.componentId("Target").?;
    const who = std.mem.readInt(u64, world.componentBytes(targeter, target_id).?[0..8], .little);
    try std.testing.expectEqual(@as(u64, @bitCast(boss)), who);

    // E6: Boss got the extension's Weapon, and the on_attach seam fired once.
    const weapon_id = world.componentId("Weapon").?;
    const wb = world.componentBytes(boss, weapon_id) orelse return error.WeaponNotAdded;
    try std.testing.expectEqual(@as(i32, 25), std.mem.readInt(i32, wb[0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), AttachSpy.fired);

    // M1.0.9 boundary: on_attach not executed → Boss.Health.max still 100.
    const health_id = world.componentId("Health").?;
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, world.componentBytes(boss, health_id).?[4..8], .little));
}
