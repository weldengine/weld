//! Byte-level chunk tests — M0.1 / E2 replaced the comptime-generic
//! `Chunk(Components)` with a 16 KiB raw buffer + an `ChunkLayout`
//! descriptor computed from registered component sizes + alignments.
//! These tests cover the locked invariants surfaced by `chunk.zig`:
//! total size, alignment, header init, and the layout computation
//! against a reference (Transform, Velocity)-shaped component set.

const std = @import("std");
const weld_core = @import("weld_core");

const chunk_mod = weld_core.ecs.chunk;
const Chunk = chunk_mod.Chunk;
const ChunkSize = chunk_mod.ChunkSize;
const ChunkAlignment = chunk_mod.ChunkAlignment;
const computeLayout = chunk_mod.computeLayout;

const components = weld_core.ecs.components;
const Transform = components.Transform;
const Velocity = components.Velocity;
const EntityId = components.EntityId;

test "chunk total size is 16 KiB" {
    try std.testing.expectEqual(@as(usize, ChunkSize), @sizeOf(Chunk));
    try std.testing.expectEqual(@as(usize, 16 * 1024), @sizeOf(Chunk));
}

test "chunk alignment is at least 16 bytes" {
    try std.testing.expect(@alignOf(Chunk) >= ChunkAlignment);
}

test "computeLayout against (Transform, Velocity) yields a sensible capacity" {
    const gpa = std.testing.allocator;
    const layout = try computeLayout(
        gpa,
        &.{ @sizeOf(Transform), @sizeOf(Velocity) },
        &.{ @alignOf(Transform), @alignOf(Velocity) },
    );
    defer gpa.free(layout.component_offsets);

    // Capacity should land near the S1 pre-E2 reference (185 with the
    // old large header) — the new minimal header brings it a bit higher.
    try std.testing.expect(layout.capacity >= 180);
    try std.testing.expect(layout.capacity <= 230);

    // Each component column must be 16-byte aligned for SIMD.
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[0] % 16);
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[1] % 16);

    // entity_ids[] is 8-byte aligned (matches `@alignOf(EntityId)`).
    try std.testing.expectEqual(@as(u16, 0), layout.entity_ids_offset % @sizeOf(EntityId));
}

test "Chunk header initInPlace sets count=0, capacity, archetype_id" {
    const gpa = std.testing.allocator;
    const c = try gpa.create(Chunk);
    defer gpa.destroy(c);
    c.initInPlace(42, 200);
    try std.testing.expectEqual(@as(u32, 0), c.entityCount());
    try std.testing.expectEqual(@as(u32, 200), c.capacity());
    try std.testing.expectEqual(@as(u32, 42), c.header().archetype_id);
    try std.testing.expect(!c.isFull());
}
