//! M1.0.4 E2 — `.scene.etch` → cook → `.scene.bin` writer → zero-copy accessor
//! round-trip. Reads the committed fixture, cooks it (`weld_etch.scene_cook`),
//! serializes the model (`weld_core.scene.writer`), opens the bytes
//! (`weld_core.scene.accessor`), and asserts that entities, archetypes, UUIDs,
//! names, and parent links survive the round-trip byte-for-byte in meaning.
//!
//! Resource-block + determinism assertions are added in E3 (per the milestone
//! découpage); the writer already serializes resources, but this E2 gate covers
//! the entity/archetype/identity surface.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");

const scene = weld_core.scene;
const Registry = weld_core.ecs.registry.Registry;
const scene_cook = weld_etch.scene_cook;

const fixture_path = "tests/fixtures/scene/arena_wave1.scene.etch";

fn readFixture(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const dir = std.Io.Dir.cwd();
    var file = try dir.openFile(io, fixture_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, stat.size);
    errdefer gpa.free(buf);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    return buf[0..written];
}

/// Find, within `arch`, the column index whose schema name == `comp` (column
/// order is the cook's sorted-id mask, surfaced by name through the schema table).
fn columnOf(acc: scene.accessor.Accessor, arch: scene.accessor.Accessor.Archetype, comp: []const u8) ?usize {
    var c: usize = 0;
    while (c < arch.component_count) : (c += 1) {
        if (std.mem.eql(u8, acc.schema(arch.schemaIndex(c)).name, comp)) return c;
    }
    return null;
}

fn decodeF32(acc: scene.accessor.Accessor, reg: *const Registry, arch: scene.accessor.Accessor.Archetype, comp: []const u8, field: []const u8, slot: usize) f32 {
    const c = columnOf(acc, arch, comp).?;
    const fd = reg.findField(reg.idOf(comp).?, field).?;
    const slot_bytes = arch.componentSlot(c, slot);
    return @bitCast(std.mem.readInt(u32, slot_bytes[fd.offset..][0..4], .little));
}

fn decodeI64(acc: scene.accessor.Accessor, reg: *const Registry, arch: scene.accessor.Accessor.Archetype, comp: []const u8, field: []const u8, slot: usize) i64 {
    const c = columnOf(acc, arch, comp).?;
    const fd = reg.findField(reg.idOf(comp).?, field).?;
    const slot_bytes = arch.componentSlot(c, slot);
    return std.mem.readInt(i64, slot_bytes[fd.offset..][0..8], .little);
}

test "scene round-trips through cook and accessor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const src = try readFixture(gpa, io);
    defer gpa.free(src);

    var cooked = try scene_cook.cook(gpa, src, null);
    defer cooked.deinit(gpa);

    const bytes = try scene.writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    var acc = try scene.accessor.Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    try std.testing.expectEqual(@as(u32, 2), acc.archetypeCount());

    // Spawner's UUID first byte, for the parent-link assertion.
    const spawner_uuid0: u8 = 0x7b;

    var saw_solo = false;
    var saw_pair = false;
    var ai: u32 = 0;
    while (ai < acc.archetypeCount()) : (ai += 1) {
        const arch = acc.archetype(ai);
        try std.testing.expectEqual(@as(u32, 1), arch.entity_count);

        if (arch.component_count == 1) {
            // [Position] — Spawner (root).
            saw_solo = true;
            try std.testing.expectEqualStrings("Spawner", arch.entityName(0));
            try std.testing.expectEqual(scene.format.no_parent, arch.entityParent(0));
            try std.testing.expectEqual(spawner_uuid0, arch.entityUuid(0)[0]);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), decodeF32(acc, &cooked.registry, arch, "Position", "x", 0), 1e-6);
        } else {
            // [Position, Health] — Hero (parented to Spawner).
            saw_pair = true;
            try std.testing.expectEqual(@as(u32, 2), arch.component_count);
            try std.testing.expectEqualStrings("Hero", arch.entityName(0));
            try std.testing.expectApproxEqAbs(@as(f32, 10.0), decodeF32(acc, &cooked.registry, arch, "Position", "x", 0), 1e-6);
            try std.testing.expectEqual(@as(i64, 75), decodeI64(acc, &cooked.registry, arch, "Health", "current", 0));
            // Parent link resolves to Spawner's UUID.
            const parent = arch.entityParent(0);
            try std.testing.expect(parent != scene.format.no_parent);
            try std.testing.expectEqual(spawner_uuid0, acc.uuidAt(parent)[0]);
        }
    }
    try std.testing.expect(saw_solo and saw_pair);
}
