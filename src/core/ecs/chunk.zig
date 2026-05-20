//! Byte-level chunk — the storage unit shared by every archetype.
//!
//! M0.1 / E2 generalises the S1 comptime-typed `Chunk(Components)` into a
//! single byte-level `Chunk` (16 KiB buffer + minimal header). The runtime
//! `ChunkLayout` descriptor pinned per archetype tells consumers where each
//! component column lives inside the buffer; typed access flows through a
//! comptime view defined in `query.zig`.
//!
//! Layout matches the S4 `archetype_dynamic.Chunk` byte-for-byte so the
//! Etch interpreter / bridge keep working through the
//! `archetype_dynamic.zig` re-export. Same 16 KiB size, same 16-byte
//! alignment, same `(component_offsets[], entity_ids_offset, capacity)`
//! triple computed from registered component sizes + alignments.
//!
//! Locked invariants (per `engine-ecs-internals.md` §2):
//!
//! - Chunk is exactly `ChunkSize` bytes, 16-byte aligned.
//! - Header lives at byte 0, padded up to `ChunkAlignment` so the first
//!   component array starts on a 16-byte boundary.
//! - Each component column is contiguous SoA, aligned to
//!   `max(ChunkAlignment, alignOf(component))`.
//! - `entity_ids[]` (a `[*]EntityId` of `capacity` slots) trails the
//!   component columns, 8-byte aligned.
//! - Slots are filled in order via swap-and-pop on remove — only
//!   `slots[0 .. entity_count)` are ever read.

const std = @import("std");
const entity_mod = @import("entity.zig");

const EntityId = entity_mod.EntityId;

/// Total chunk size — locked to 16 KiB to fit comfortably in L1D on modern
/// x86-64, Apple Silicon, and ARM Cortex CPUs (cf. `engine-spec.md` §2.3).
pub const ChunkSize: usize = 16 * 1024;

/// Required alignment of the chunk and of every SoA column within it.
/// 16 bytes matches `@Vector(4, f32)`, the worst case for the S1 components.
pub const ChunkAlignment: usize = 16;

/// Minimal header overlaid on the first 16 bytes of every chunk. Fits one
/// 16-byte cache line so the SoA columns start on a fresh line.
///
/// `entity_count` is the only field mutated at steady state; `capacity` and
/// `archetype_id` are set at chunk creation and frozen.
pub const ChunkHeader = extern struct {
    entity_count: u32,
    capacity: u32,
    archetype_id: u32,
    _pad: u32 = 0,
};

/// Per-archetype byte-offset descriptor. Computed once at archetype init
/// from the registered component sizes + alignments, then shared by every
/// chunk in that archetype.
pub const ChunkLayout = struct {
    /// Byte offset of each SoA column from the chunk's `bytes[0]`. Length
    /// equals the archetype's component count, indexed in the archetype's
    /// sorted-by-`ComponentId` order.
    component_offsets: []u16,
    /// Byte offset of the `entity_ids[]` array. 8-byte aligned.
    entity_ids_offset: u16,
    /// Maximum entities per chunk for this archetype.
    capacity: u32,
};

/// Surfaced by `chunk.computeLayout` and by every archetype operation
/// that may have to grow the chunk list (the spawn paths).
pub const ArchetypeError = error{
    EmptyComponentList,
    LayoutTooLarge,
    OutOfMemory,
};

/// Aligned raw 16 KiB buffer underpinning a single chunk. Type-erased on
/// purpose — the typed access pattern lives in `query.zig` so the chunk
/// itself stays archetype-agnostic.
pub const Chunk = struct {
    bytes: [ChunkSize]u8 align(ChunkAlignment),

    comptime {
        std.debug.assert(@sizeOf(Chunk) == ChunkSize);
        std.debug.assert(@alignOf(Chunk) >= ChunkAlignment);
    }

    pub fn header(self: *Chunk) *ChunkHeader {
        return @ptrCast(@alignCast(&self.bytes));
    }

    pub fn headerConst(self: *const Chunk) *const ChunkHeader {
        return @ptrCast(@alignCast(&self.bytes));
    }

    pub fn entityCount(self: *const Chunk) u32 {
        return self.headerConst().entity_count;
    }

    pub fn capacity(self: *const Chunk) u32 {
        return self.headerConst().capacity;
    }

    /// `true` when no more entities can be inserted before allocating a new
    /// chunk in the owning archetype.
    pub fn isFull(self: *const Chunk) bool {
        const hdr = self.headerConst();
        return hdr.entity_count >= hdr.capacity;
    }

    /// Initialise the header in place. Storage area is left uninitialised
    /// — only slots `[0, entity_count)` are ever read.
    pub fn initInPlace(self: *Chunk, archetype_id: u32, cap: u32) void {
        self.header().* = .{
            .entity_count = 0,
            .capacity = cap,
            .archetype_id = archetype_id,
        };
    }
};

/// Compute a `ChunkLayout` for the given column sizes + alignments. The
/// algorithm picks the largest capacity `N` such that
/// `header + Σ aligned_column_size(i, N) + entity_ids[N] ≤ ChunkSize`,
/// then writes the resulting offsets into a freshly-allocated slice owned
/// by the caller.
///
/// Errors: `EmptyComponentList` if `sizes.len == 0`, `LayoutTooLarge` if no
/// capacity fits, `OutOfMemory` from the slice allocation.
pub fn computeLayout(
    gpa: std.mem.Allocator,
    sizes: []const u16,
    aligns: []const u16,
) ArchetypeError!ChunkLayout {
    if (sizes.len == 0) return ArchetypeError.EmptyComponentList;

    const header_size: usize = std.mem.alignForward(usize, @sizeOf(ChunkHeader), ChunkAlignment);

    // Per-slot byte cost: components + entity id. Used only to seed the
    // capacity search loop with a reasonable upper bound.
    var per_slot: usize = @sizeOf(EntityId);
    for (sizes) |s| per_slot += s;
    if (per_slot == 0) return ArchetypeError.LayoutTooLarge;

    var n: usize = (ChunkSize - header_size) / per_slot;
    while (n > 0) : (n -= 1) {
        if (fits(sizes, aligns, n, header_size)) break;
    }
    if (n == 0) return ArchetypeError.LayoutTooLarge;

    const offsets = try gpa.alloc(u16, sizes.len);
    errdefer gpa.free(offsets);

    var off: usize = header_size;
    for (sizes, aligns, 0..) |sz, al, i| {
        off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @as(usize, al)));
        offsets[i] = @intCast(off);
        off += @as(usize, sz) * n;
    }
    off = std.mem.alignForward(usize, off, @alignOf(EntityId));
    const entity_ids_offset: u16 = @intCast(off);

    return .{
        .component_offsets = offsets,
        .entity_ids_offset = entity_ids_offset,
        .capacity = @intCast(n),
    };
}

fn fits(sizes: []const u16, aligns: []const u16, n: usize, header_size: usize) bool {
    var off: usize = header_size;
    for (sizes, aligns) |sz, al| {
        off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @as(usize, al)));
        off += @as(usize, sz) * n;
    }
    off = std.mem.alignForward(usize, off, @alignOf(EntityId));
    off += @sizeOf(EntityId) * n;
    return off <= ChunkSize;
}

// ─── tests ────────────────────────────────────────────────────────────────

test "chunk total size is 16 KiB" {
    try std.testing.expectEqual(@as(usize, ChunkSize), @sizeOf(Chunk));
}

test "chunk alignment is at least 16 bytes" {
    try std.testing.expect(@alignOf(Chunk) >= ChunkAlignment);
}

test "computeLayout rejects empty component list" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        ArchetypeError.EmptyComponentList,
        computeLayout(gpa, &.{}, &.{}),
    );
}

test "computeLayout for (Transform-like 48b/16a, Velocity-like 32b/16a) matches S1 capacity reference" {
    // The S1 chunk for `(Transform, Velocity)` had capacity 185 (cf.
    // `briefs/S1-mini-ecs.md` journal + the legacy chunk_test capacity
    // constant). The runtime layout aligns each column to max(16, alignof) = 16
    // with a 16-byte header — capacity should land in the same ballpark.
    const gpa = std.testing.allocator;
    const layout = try computeLayout(gpa, &.{ 48, 32 }, &.{ 16, 16 });
    defer gpa.free(layout.component_offsets);

    try std.testing.expect(layout.capacity >= 180);
    try std.testing.expect(layout.capacity <= 210);
    // Both columns must be 16-byte aligned for SIMD.
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[0] % 16);
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[1] % 16);
}

test "Chunk header init writes the expected zero/capacity/id triple" {
    const gpa = std.testing.allocator;
    const c = try gpa.create(Chunk);
    defer gpa.destroy(c);
    c.initInPlace(42, 256);
    try std.testing.expectEqual(@as(u32, 0), c.entityCount());
    try std.testing.expectEqual(@as(u32, 256), c.capacity());
    try std.testing.expectEqual(@as(u32, 42), c.header().archetype_id);
    try std.testing.expect(!c.isFull());
}
