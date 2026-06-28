//! M1.0.6 E3 — `instance of` flattening at scene cook. A prefab is cooked to its
//! `.prefab.bin`, then a scene that instances it is cooked with a resolver that
//! hands back those bytes; the instance's entity inherits the prefab's components
//! and applies the instance's overrides (both forms). Covers: an override-free
//! instance equals the hand-authored equivalent (same archetype + bytes), both
//! override forms (`Comp.field = v` and `Comp { field: v }`), N instances loading
//! into the ECS through the M1.0.5 loader, and the single-entity boundary.
//!
//! Components are POD scalar (the cook's only component kind), so fixtures use f32.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");

const scene = weld_core.scene;
const ecs = weld_core.ecs;
const World = ecs.World;
const Registry = weld_core.ecs.registry.Registry;
const scene_cook = weld_etch.scene_cook;
const Accessor = scene.accessor.Accessor;

/// One-entry in-process base-prefab resolver.
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

// `Torch`: a mono-entity prefab — Transform{x:1} + Light{intensity:1500, radius:6}.
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

const scene_decls =
    \\component Transform { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 }
    \\component Light { intensity: f32 = 2000.0, radius: f32 = 8.0 }
    \\
;

fn cookTorch(gpa: std.mem.Allocator) !scene_cook.Cooked {
    return scene_cook.cookPrefab(gpa, torch_prefab, null, null);
}

fn columnOf(acc: Accessor, arch: Accessor.Archetype, comp: []const u8) ?usize {
    var c: usize = 0;
    while (c < arch.component_count) : (c += 1) {
        if (std.mem.eql(u8, acc.schema(arch.schemaIndex(c)).name, comp)) return c;
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

fn decodeF32(acc: Accessor, reg: *const Registry, arch: Accessor.Archetype, comp: []const u8, field: []const u8, slot: usize) f32 {
    const c = columnOf(acc, arch, comp).?;
    const fd = reg.findField(reg.idOf(comp).?, field).?;
    return @bitCast(std.mem.readInt(u32, arch.componentSlot(c, slot)[fd.offset..][0..4], .little));
}

test "instance of expands to the prefab's components (same archetype + bytes as hand-authored)" {
    const gpa = std.testing.allocator;
    var torch = try cookTorch(gpa);
    defer torch.deinit(gpa);
    const torch_bytes = try scene.writer.write(gpa, torch.model, &torch.registry);
    defer gpa.free(torch_bytes);
    var resolver = OneResolver{ .name = "Torch", .bytes = torch_bytes };

    // An override-free instance, beside the hand-authored entity carrying the
    // prefab's exact components/values.
    const src = scene_decls ++
        \\scene "S" {
        \\  instance of "Torch" "I" { uuid: "00000000-0000-0000-0000-0000000000a1" }
        \\  entity "H" {
        \\    uuid: "00000000-0000-0000-0000-0000000000a2"
        \\    Transform { x: 1.0 }
        \\    Light { intensity: 1500.0, radius: 6.0 }
        \\  }
        \\}
    ;
    var cooked = try scene_cook.cookScene(gpa, src, resolver.base(), null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    try std.testing.expectEqual(@as(u32, 1), acc.archetypeCount()); // I and H share [Light, Transform]
    const arch = acc.archetype(0);
    try std.testing.expectEqual(@as(u32, 2), arch.entity_count);
    try std.testing.expectEqual(@as(u32, 2), arch.component_count);

    // Per column, the instance slot and the hand-authored slot are byte-identical.
    const si = slotOf(arch, "I").?;
    const sh = slotOf(arch, "H").?;
    var c: usize = 0;
    while (c < arch.component_count) : (c += 1) {
        try std.testing.expectEqualSlices(u8, arch.componentSlot(c, sh), arch.componentSlot(c, si));
    }
}

test "per-field overrides apply over the prefab (both forms)" {
    const gpa = std.testing.allocator;
    var torch = try cookTorch(gpa);
    defer torch.deinit(gpa);
    const torch_bytes = try scene.writer.write(gpa, torch.model, &torch.registry);
    defer gpa.free(torch_bytes);
    var resolver = OneResolver{ .name = "Torch", .bytes = torch_bytes };

    const src = scene_decls ++
        \\scene "S" {
        \\  instance of "Torch" "I1" { uuid: "00000000-0000-0000-0000-0000000000b1" Light.intensity = 3000.0 }
        \\  instance of "Torch" "I2" { uuid: "00000000-0000-0000-0000-0000000000b2" Light { intensity: 2500.0 } }
        \\}
    ;
    var cooked = try scene_cook.cookScene(gpa, src, resolver.base(), null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    const arch = acc.archetype(0);
    const reg = &cooked.registry;

    // `Comp.field = v` form (I1): intensity overridden, radius + transform inherited.
    const s1 = slotOf(arch, "I1").?;
    try std.testing.expectApproxEqAbs(@as(f32, 3000.0), decodeF32(acc, reg, arch, "Light", "intensity", s1), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), decodeF32(acc, reg, arch, "Light", "radius", s1), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decodeF32(acc, reg, arch, "Transform", "x", s1), 1e-3);

    // `Comp { field: v }` form (I2): field-merge — intensity overridden, radius inherited.
    const s2 = slotOf(arch, "I2").?;
    try std.testing.expectApproxEqAbs(@as(f32, 2500.0), decodeF32(acc, reg, arch, "Light", "intensity", s2), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), decodeF32(acc, reg, arch, "Light", "radius", s2), 1e-3);
}

test "N instances of one prefab load as N entities (cook -> load -> ECS)" {
    const gpa = std.testing.allocator;
    var torch = try cookTorch(gpa);
    defer torch.deinit(gpa);
    const torch_bytes = try scene.writer.write(gpa, torch.model, &torch.registry);
    defer gpa.free(torch_bytes);
    var resolver = OneResolver{ .name = "Torch", .bytes = torch_bytes };

    const src = scene_decls ++
        \\scene "S" {
        \\  instance of "Torch" "I0" { uuid: "00000000-0000-0000-0000-0000000000c0" }
        \\  instance of "Torch" "I1" { uuid: "00000000-0000-0000-0000-0000000000c1" Light.intensity = 4000.0 }
        \\  instance of "Torch" "I2" { uuid: "00000000-0000-0000-0000-0000000000c2" }
        \\}
    ;
    var cooked = try scene_cook.cookScene(gpa, src, resolver.base(), null);
    defer cooked.deinit(gpa);
    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    // Load into a World whose registry mirrors the cook's component layout.
    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Transform", .size = 12, .alignment = 4, .default_bytes = &[_]u8{0} ** 12, .fields = &.{} });
    _ = try world.registry.registerComponentRaw(gpa, .{ .name = "Light", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &.{} });

    var result = try scene.loader.loadFromBytes(&world, gpa, bytes);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), world.entityCount());
    const light_id = world.componentId("Light").?;

    const Case = struct { uuid: [16]u8, intensity: f32 };
    const cases = [_]Case{
        .{ .uuid = uuidBytes(0xc0), .intensity = 1500.0 },
        .{ .uuid = uuidBytes(0xc1), .intensity = 4000.0 },
        .{ .uuid = uuidBytes(0xc2), .intensity = 1500.0 },
    };
    for (cases) |cs| {
        const eid = result.uuid_to_entity.get(cs.uuid).?;
        const lb = world.componentBytes(eid, light_id).?;
        try std.testing.expectApproxEqAbs(cs.intensity, @as(f32, @bitCast(std.mem.readInt(u32, lb[0..4], .little))), 1e-3); // intensity @0
        try std.testing.expectApproxEqAbs(@as(f32, 6.0), @as(f32, @bitCast(std.mem.readInt(u32, lb[4..8], .little))), 1e-3); // radius @4 (inherited)
    }
}

/// A canonical UUID `00000000-0000-0000-0000-0000000000XX` as its 16 bytes (the
/// last byte = `last`), matching the `uuid:` strings above.
fn uuidBytes(last: u8) [16]u8 {
    var u = [_]u8{0} ** 16;
    u[15] = last;
    return u;
}

test "instancing a multi-entity prefab is rejected" {
    const gpa = std.testing.allocator;
    const multi_prefab =
        \\component Light { intensity: f32 = 2000.0 }
        \\component Transform { x: f32 = 0.0 }
        \\prefab "Multi" {
        \\  entity "root" { uuid: "00000000-0000-0000-0000-0000000000d0" Light { } }
        \\  entity "child" { uuid: "00000000-0000-0000-0000-0000000000d1" Transform { } }
        \\}
    ;
    var multi = try scene_cook.cookPrefab(gpa, multi_prefab, null, null);
    defer multi.deinit(gpa);
    const multi_bytes = try scene.writer.write(gpa, multi.model, &multi.registry);
    defer gpa.free(multi_bytes);
    var resolver = OneResolver{ .name = "Multi", .bytes = multi_bytes };

    const src =
        \\component Light { intensity: f32 = 2000.0 }
        \\component Transform { x: f32 = 0.0 }
        \\scene "S" {
        \\  instance of "Multi" "I" { uuid: "00000000-0000-0000-0000-0000000000d2" }
        \\}
    ;
    var diag: []const u8 = "";
    try std.testing.expectError(error.MultiEntityInstanceUnsupported, scene_cook.cookScene(gpa, src, resolver.base(), &diag));
}
