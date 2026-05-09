const std = @import("std");
const weld_core = @import("weld_core");

const components = weld_core.ecs.components;
const chunk_mod = weld_core.ecs.chunk;
const Transform = components.Transform;
const Velocity = components.Velocity;
const EntityId = components.EntityId;

const ArchetypeComponents: []const type = &.{ Transform, Velocity };
const TestChunk = chunk_mod.Chunk(ArchetypeComponents);

/// Capacity recorded the first time the layout was measured. Locked here so
/// any future change in component sizes or header layout is caught loudly
/// instead of silently shifting the bench numbers.
const expected_capacity: u32 = 185;

test "chunk total size is 16 KiB" {
    try std.testing.expectEqual(@as(usize, 16 * 1024), @sizeOf(TestChunk));
}

test "per-component arrays are 16-byte aligned within chunk" {
    const offsets = TestChunk.Layout.component_offsets;
    for (offsets) |o| {
        try std.testing.expectEqual(@as(u16, 0), o % 16);
    }
}

test "chunk capacity matches manual computation for (Transform, Velocity)" {
    try std.testing.expectEqual(expected_capacity, TestChunk.capacity);
    // Sanity: the formula must keep header + capacity * stride within 16 KiB.
    const stride = @sizeOf(Transform) + @sizeOf(Velocity) + @sizeOf(EntityId);
    try std.testing.expect(TestChunk.Layout.header_size + TestChunk.capacity * stride <= 16 * 1024);
    // Sanity: the next entity would overflow the chunk.
    try std.testing.expect(TestChunk.Layout.header_size + (TestChunk.capacity + 1) * stride > 16 * 1024);
}

test "chunk header is initialized correctly" {
    const gpa = std.testing.allocator;
    const c = try gpa.create(TestChunk);
    defer gpa.destroy(c);
    c.initInPlace(42);
    const hdr = c.header();
    try std.testing.expectEqual(@as(u32, 0), hdr.entity_count);
    try std.testing.expectEqual(TestChunk.capacity, hdr.capacity);
    try std.testing.expectEqual(@as(u32, 42), hdr.archetype_id);
    try std.testing.expectEqual(@as(?*TestChunk, null), hdr.next_chunk);
    try std.testing.expectEqualSlices(u16, &TestChunk.Layout.component_offsets, &hdr.component_offsets);
}

test "append and removeSwap maintain entity_ids consistency" {
    const gpa = std.testing.allocator;
    const c = try gpa.create(TestChunk);
    defer gpa.destroy(c);
    c.initInPlace(0);

    const slot_a = c.append(@as(EntityId, 100), .{ Transform{}, Velocity{} }) orelse unreachable;
    const slot_b = c.append(@as(EntityId, 200), .{ Transform{}, Velocity{} }) orelse unreachable;
    const slot_c = c.append(@as(EntityId, 300), .{ Transform{}, Velocity{} }) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 0), slot_a);
    try std.testing.expectEqual(@as(u32, 1), slot_b);
    try std.testing.expectEqual(@as(u32, 2), slot_c);
    try std.testing.expectEqual(@as(u32, 3), c.entityCount());

    // Remove middle: last (entity 300) gets swapped into slot 1.
    const swapped = c.removeSwap(1);
    try std.testing.expectEqual(@as(?EntityId, 300), swapped);
    try std.testing.expectEqual(@as(u32, 2), c.entityCount());
    const ids = c.entityIds();
    try std.testing.expectEqual(@as(EntityId, 100), ids[0]);
    try std.testing.expectEqual(@as(EntityId, 300), ids[1]);

    // Remove last: no swap needed.
    const swapped2 = c.removeSwap(1);
    try std.testing.expectEqual(@as(?EntityId, null), swapped2);
    try std.testing.expectEqual(@as(u32, 1), c.entityCount());
}
