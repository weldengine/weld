//! M1.0.5 E3 — resource `string` fields round-trip through the Tier-0 persistent
//! heap. Cooks (in-memory, via the writer) a scene with one resource carrying a
//! `string` field, loads it, and asserts the field reads back the cooked value:
//! the loaded string is interned into `weld_core.memory.persistent` (immortal)
//! and owned by `LoadResult`, with the resource's `StringSlot` pointing at it.
//! `weld_core` only.

const std = @import("std");
const weld_core = @import("weld_core");

const ecs = weld_core.ecs;
const scene = weld_core.scene;
const World = ecs.World;
const registry = ecs.registry;
const format = scene.format;
const writer = scene.writer;
const loader = scene.loader;
const persistent = weld_core.memory.persistent;

test "resource string fields round-trip through the persistent heap" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Resource `Settings { title: string }` — one 16-byte `StringSlot` at offset 0.
    const settings = try world.registry.registerComponentRaw(gpa, .{
        .name = "Settings",
        .size = 16,
        .alignment = 8,
        .default_bytes = &[_]u8{0} ** 16,
        .fields = &[_]registry.FieldDesc{
            .{ .name = "title", .offset = 0, .kind = .string_ },
        },
    });

    const title_value = "Verdant Keep";

    // Cook a 0-entity scene with just this resource. The string slot in `data`
    // is zeroed on disk; the value lives in the string table (string_fields).
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const strings = try a.dupe([]const u8, &.{try a.dupe(u8, title_value)});
    const data = try a.alloc(u8, 16);
    @memset(data, 0);
    const string_fields = try a.dupe(format.StringFieldRef, &.{.{ .offset = 0, .str = 0 }});
    const resources = try a.dupe(format.ResourceEntry, &.{.{
        .schema_id = settings,
        .data = data,
        .string_fields = string_fields,
    }});
    var model: format.CookModel = .{
        .strings = strings,
        .uuids = &.{},
        .resources = resources,
        .archetypes = &.{},
        .arena = arena,
    };
    defer model.deinit();
    const bytes = try writer.write(gpa, model, &world.registry);
    defer gpa.free(bytes);

    var result = try loader.loadFromBytes(&world, gpa, bytes, null);
    defer result.deinit(gpa);

    // Exactly one interned string block, owned by the result.
    try std.testing.expectEqual(@as(usize, 1), result.resource_strings.len);

    // The installed resource's `StringSlot` points at the interned bytes.
    const res_bytes = world.resources.getResource(settings).?;
    var ss: persistent.StringSlot = undefined;
    @memcpy(std.mem.asBytes(&ss), res_bytes[0..@sizeOf(persistent.StringSlot)]);
    try std.testing.expect(ss.ptr != 0);
    try std.testing.expectEqual(@as(u32, title_value.len), ss.len);
    const loaded: [*]const u8 = @ptrFromInt(ss.ptr);
    try std.testing.expectEqualStrings(title_value, loaded[0..ss.len]);
}
