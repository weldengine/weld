//! Byte-level chunk — the storage unit shared by every archetype: a 16 KiB buffer
//! with a minimal header, addressed through a per-archetype `ChunkLayout`.
//!
//! THE SECTION ORDER IS THE CONTRACT, because the Etch bridge reads
//! `component_offsets[]` and `entity_ids_offset` out of the layout: header at byte 0
//! padded to `ChunkAlignment`, then the SoA component columns each aligned to
//! `max(ChunkAlignment, alignOf(component))`, then `entity_ids[]` 8-byte aligned,
//! then `added_tick[N]` and `changed_tick[N]` 4-byte aligned, then `dirty_bitset[]`.
//!
//! Slots fill in order and remove is swap-and-pop, so only `slots[0..entity_count)`
//! is ever readable — past it the bytes are UNINITIALISED, not empty.

const std = @import("std");
const entity_mod = @import("entity.zig");
const tick_mod = @import("tick.zig");
const change_detection = @import("change_detection.zig");

const EntityId = entity_mod.EntityId;
const Tick = tick_mod.Tick;

/// Locked to 16 KiB.
pub const ChunkSize: usize = 16 * 1024;

/// Required of the chunk itself AND of every SoA column start.
pub const ChunkAlignment: usize = 16;

/// Overlaid on the first 16 bytes of every chunk.
pub const ChunkHeader = extern struct {
    entity_count: u32,
    capacity: u32,
    archetype_id: u32,
    _pad: u32 = 0,
};

/// Per-archetype byte offsets, computed once at archetype creation.
pub const ChunkLayout = struct {
    /// Indexed in the SAME order as the archetype's component-id list.
    component_offsets: []u16,
    /// Byte offset of the `entity_ids[]` array. 8-byte aligned.
    entity_ids_offset: u16,
    /// Per-component `added_tick[capacity]u32`, same index order.
    added_tick_offsets: []u16,
    /// Per-component `changed_tick[capacity]u32`, same index order.
    changed_tick_offsets: []u16,
    /// The single per-chunk `dirty_bitset[ceil(capacity/64)]u64`.
    dirty_bitset_offset: u16,
    /// Number of `u64` words in the dirty bitset = `ceil(capacity / 64)`.
    dirty_bitset_word_count: u16,
    /// Maximum entities per chunk for this archetype.
    capacity: u32,
};

/// Raised by `computeLayout` and by every archetype operation that may grow.
pub const ArchetypeError = error{
    LayoutTooLarge,
    OutOfMemory,
    // `EmptyComponentList` is gone: an entity ALWAYS has an archetype, and an
    // entity whose whole set is sparse lives in the archetype of zero components.
    // Re-adding it would fork the entity lifecycle across despawn, the observers,
    // the three spawn paths and `dynamicLocation`.
};

/// Type-erased on purpose — the typed access pattern lives in `query.zig`.
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

    /// `true` when the owning archetype must allocate another chunk to insert.
    pub fn isFull(self: *const Chunk) bool {
        const hdr = self.headerConst();
        return hdr.entity_count >= hdr.capacity;
    }

    /// Header only — the storage area is left UNINITIALISED.
    pub fn initInPlace(self: *Chunk, archetype_id: u32, cap: u32) void {
        self.header().* = .{
            .entity_count = 0,
            .capacity = cap,
            .archetype_id = archetype_id,
        };
    }

    /// The `added_tick` column for `comp_idx`, `capacity` long — sized to the
    /// LAYOUT and not to the live entity count, trailing slots included.
    pub fn addedTickColumn(self: *Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]Tick {
        const off = layout.added_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    /// `*const` counterpart for read-only paths.
    pub fn addedTickColumnConst(self: *const Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]const Tick {
        const off = layout.added_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    /// The `changed_tick` column for `comp_idx`.
    pub fn changedTickColumn(self: *Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]Tick {
        const off = layout.changed_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    pub fn changedTickColumnConst(self: *const Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]const Tick {
        const off = layout.changed_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    /// `layout.dirty_bitset_word_count` words long.
    pub fn dirtyBitset(self: *Chunk, layout: *const ChunkLayout) change_detection.DirtyBitset {
        const off = layout.dirty_bitset_offset;
        const ptr: [*]u64 = @ptrCast(@alignCast(&self.bytes[off]));
        return ptr[0..layout.dirty_bitset_word_count];
    }

    pub fn dirtyBitsetConst(self: *const Chunk, layout: *const ChunkLayout) []const u64 {
        const off = layout.dirty_bitset_offset;
        const ptr: [*]const u64 = @ptrCast(@alignCast(&self.bytes[off]));
        return ptr[0..layout.dirty_bitset_word_count];
    }
};

/// Largest capacity whose full layout fits in `ChunkSize`. The offset slices are
/// freshly allocated and OWNED BY THE CALLER.
///
/// An EMPTY column list is legal and yields a positive capacity — the per-slot cost
/// is then the entity id and the bitset alone, which is what the sparse-only
/// archetype needs.
pub fn computeLayout(
    gpa: std.mem.Allocator,
    sizes: []const u16,
    aligns: []const u16,
) ArchetypeError!ChunkLayout {
    const header_size: usize = std.mem.alignForward(usize, @sizeOf(ChunkHeader), ChunkAlignment);

    // Seeds the search loop only; `fits` below is the precise check.
    var per_slot: usize = @sizeOf(EntityId);
    for (sizes) |s| per_slot += s;
    per_slot += 2 * @sizeOf(Tick) * sizes.len;
    if (per_slot == 0) return ArchetypeError.LayoutTooLarge;

    var n: usize = (ChunkSize - header_size) / per_slot;
    while (n > 0) : (n -= 1) {
        if (fits(sizes, aligns, n, header_size)) break;
    }
    if (n == 0) return ArchetypeError.LayoutTooLarge;

    const offsets = try gpa.alloc(u16, sizes.len);
    errdefer gpa.free(offsets);
    const added_offsets = try gpa.alloc(u16, sizes.len);
    errdefer gpa.free(added_offsets);
    const changed_offsets = try gpa.alloc(u16, sizes.len);
    errdefer gpa.free(changed_offsets);

    var off: usize = header_size;
    // Component columns.
    for (sizes, aligns, 0..) |sz, al, i| {
        off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @as(usize, al)));
        offsets[i] = @intCast(off);
        off += @as(usize, sz) * n;
    }
    // entity_ids[capacity].
    off = std.mem.alignForward(usize, off, @alignOf(EntityId));
    const entity_ids_offset: u16 = @intCast(off);
    off += @sizeOf(EntityId) * n;
    // added_tick[N][capacity].
    for (added_offsets, 0..) |*slot, i| {
        _ = i;
        off = std.mem.alignForward(usize, off, @alignOf(Tick));
        slot.* = @intCast(off);
        off += @sizeOf(Tick) * n;
    }
    // changed_tick[N][capacity].
    for (changed_offsets, 0..) |*slot, i| {
        _ = i;
        off = std.mem.alignForward(usize, off, @alignOf(Tick));
        slot.* = @intCast(off);
        off += @sizeOf(Tick) * n;
    }
    // dirty_bitset[ceil(capacity/64)]u64.
    off = std.mem.alignForward(usize, off, @alignOf(u64));
    const dirty_bitset_offset: u16 = @intCast(off);
    const word_count: usize = (n + 63) / 64;
    off += word_count * @sizeOf(u64);
    std.debug.assert(off <= ChunkSize);

    return .{
        .component_offsets = offsets,
        .entity_ids_offset = entity_ids_offset,
        .added_tick_offsets = added_offsets,
        .changed_tick_offsets = changed_offsets,
        .dirty_bitset_offset = dirty_bitset_offset,
        .dirty_bitset_word_count = @intCast(word_count),
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
    // added_tick + changed_tick — N columns each, capacity slots each.
    var i: usize = 0;
    while (i < sizes.len) : (i += 1) {
        off = std.mem.alignForward(usize, off, @alignOf(Tick));
        off += @sizeOf(Tick) * n;
    }
    i = 0;
    while (i < sizes.len) : (i += 1) {
        off = std.mem.alignForward(usize, off, @alignOf(Tick));
        off += @sizeOf(Tick) * n;
    }
    // dirty bitset — ceil(n/64) u64 words.
    off = std.mem.alignForward(usize, off, @alignOf(u64));
    off += ((n + 63) / 64) * @sizeOf(u64);
    return off <= ChunkSize;
}

test "chunk total size is 16 KiB" {
    try std.testing.expectEqual(@as(usize, ChunkSize), @sizeOf(Chunk));
}

test "chunk alignment is at least 16 bytes" {
    try std.testing.expect(@alignOf(Chunk) >= ChunkAlignment);
}

test "computeLayout ACCEPTS an empty component list (M1.B/G2)" {
    // This asserted the REFUSAL once; it is the same call with the opposite verdict,
    // so a re-introduced guard fails here and not three layers up.
    const gpa = std.testing.allocator;
    const layout = try computeLayout(gpa, &.{}, &.{});
    defer {
        gpa.free(layout.component_offsets);
        gpa.free(layout.added_tick_offsets);
        gpa.free(layout.changed_tick_offsets);
    }
    // The per-slot cost is the entity id plus the bitset — no component columns.
    try std.testing.expect(layout.capacity > 0);
    try std.testing.expectEqual(@as(usize, 0), layout.component_offsets.len);
    try std.testing.expectEqual(@as(usize, 0), layout.added_tick_offsets.len);
}

test "computeLayout for (Transform-like 48b/16a, Velocity-like 32b/16a) carries E4 sidecars" {
    // A sanity bound, not a lock: the sidecars cost capacity, and the precise value
    // is observable through the bench harness.
    const gpa = std.testing.allocator;
    const layout = try computeLayout(gpa, &.{ 48, 32 }, &.{ 16, 16 });
    defer gpa.free(layout.component_offsets);
    defer gpa.free(layout.added_tick_offsets);
    defer gpa.free(layout.changed_tick_offsets);

    try std.testing.expect(layout.capacity >= 140);
    try std.testing.expect(layout.capacity <= 180);

    // Component columns 16-byte aligned for SIMD.
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[0] % 16);
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[1] % 16);

    // Sidecar columns 4-byte aligned (size of Tick).
    try std.testing.expectEqual(@as(u16, 0), layout.added_tick_offsets[0] % @sizeOf(Tick));
    try std.testing.expectEqual(@as(u16, 0), layout.changed_tick_offsets[0] % @sizeOf(Tick));

    // Bitset 8-byte aligned, sized to ceil(capacity/64).
    try std.testing.expectEqual(@as(u16, 0), layout.dirty_bitset_offset % @alignOf(u64));
    try std.testing.expectEqual(@as(u16, @intCast((layout.capacity + 63) / 64)), layout.dirty_bitset_word_count);
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
