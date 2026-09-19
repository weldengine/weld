//! Byte-level chunk — the storage unit shared by every archetype.
//!
//! A 16 KiB buffer plus a minimal header. The per-archetype `ChunkLayout`
//! says where each column lives inside it; typed access goes through the
//! comptime view in `query.zig`.
//!
//! Three change-detection sidecars live inside that same buffer:
//!
//! - `added_tick[N][capacity]u32` — per-component, per-slot tick of
//!   first attachment to the entity.
//! - `changed_tick[N][capacity]u32` — per-component, per-slot tick of
//!   last modification (set by `World.getMut(T)`).
//! - `dirty_bitset[ceil(capacity/64)]u64` — single per-chunk bitset,
//!   reset by `World.beginFrame`; lets queries skip whole chunks
//!   without per-slot inspection.
//!
//! The sidecars trail the columns and cost per-slot budget: capacity drops
//! about 16 % against a sidecar-free layout for (Transform, Velocity).
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
//! - `added_tick[N]` / `changed_tick[N]` columns follow, each
//!   4-byte aligned, sized `capacity * sizeof(Tick)`.
//! - `dirty_bitset[]` is 8-byte aligned, sized
//!   `ceil(capacity / 64) * 8` bytes.
//! - Slots are filled in order via swap-and-pop on remove — only
//!   `slots[0 .. entity_count)` are ever read.

const std = @import("std");
const entity_mod = @import("entity.zig");
const tick_mod = @import("tick.zig");
const change_detection = @import("change_detection.zig");

const EntityId = entity_mod.EntityId;
const Tick = tick_mod.Tick;

/// Total chunk size — locked to 16 KiB to fit comfortably in L1D on modern
/// x86-64, Apple Silicon, and ARM Cortex CPUs (cf. `ARCH-005`; detail
/// `engine-ecs-internals.md` § "Archetype Chunk Layout (SoA par composant)").
pub const ChunkSize: usize = 16 * 1024;

/// Required alignment of the chunk and of every SoA column within it.
/// 16 bytes matches `@Vector(4, f32)`, the worst case for the canonical components.
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
    /// Byte offset of each per-component `added_tick[capacity]u32` column, same
    /// length and ordering as `component_offsets`.
    added_tick_offsets: []u16,
    /// Byte offset of each per-component `changed_tick[capacity]u32` column,
    /// same length and ordering as `component_offsets`.
    changed_tick_offsets: []u16,
    /// Byte offset of the per-chunk `dirty_bitset[ceil(capacity/64)]u64`,
    /// 8-byte aligned.
    dirty_bitset_offset: u16,
    /// Number of `u64` words in the dirty bitset = `ceil(capacity / 64)`.
    dirty_bitset_word_count: u16,
    /// Maximum entities per chunk for this archetype.
    capacity: u32,
};

/// Surfaced by `chunk.computeLayout` and by every archetype operation
/// that may have to grow the chunk list (the spawn paths).
pub const ArchetypeError = error{
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

    /// Pointer to the `added_tick[capacity]u32` column for component index
    /// `comp_idx`. Sized to the LAYOUT, not the live entity count — trailing
    /// unused slots carry a tick too.
    pub fn addedTickColumn(self: *Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]Tick {
        const off = layout.added_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    /// `*const` counterpart for read-only paths.
    pub fn addedTickColumnConst(self: *const Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]const Tick {
        const off = layout.added_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    /// Pointer to the `changed_tick[capacity]u32` column for component
    /// index `comp_idx`.
    pub fn changedTickColumn(self: *Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]Tick {
        const off = layout.changed_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    pub fn changedTickColumnConst(self: *const Chunk, layout: *const ChunkLayout, comp_idx: usize) [*]const Tick {
        const off = layout.changed_tick_offsets[comp_idx];
        return @ptrCast(@alignCast(&self.bytes[off]));
    }

    /// Mutable slice of the per-chunk dirty bitset. Length is
    /// `layout.dirty_bitset_word_count` (= `ceil(capacity / 64)`).
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

/// Compute a `ChunkLayout` for the given column sizes + alignments: the largest
/// capacity `N` whose full layout — header, component columns, entity_ids,
/// added_tick, changed_tick, dirty_bitset — fits within `ChunkSize`. The offset
/// slices are freshly allocated and owned by the caller.
///
/// An EMPTY column list is legal and yields a positive capacity: the per-slot
/// cost is then the entity id plus the dirty bitset alone, which is what the
/// archetype of an entity carrying only sparse components needs.
///
/// The `per_slot` arithmetic inside only SEEDS the search with an upper bound;
/// `fits` is the authority on whether a capacity actually fits.
pub fn computeLayout(
    gpa: std.mem.Allocator,
    sizes: []const u16,
    aligns: []const u16,
) ArchetypeError!ChunkLayout {
    const header_size: usize = std.mem.alignForward(usize, @sizeOf(ChunkHeader), ChunkAlignment);

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
    for (sizes, aligns, 0..) |sz, al, i| {
        off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @as(usize, al)));
        offsets[i] = @intCast(off);
        off += @as(usize, sz) * n;
    }
    off = std.mem.alignForward(usize, off, @alignOf(EntityId));
    const entity_ids_offset: u16 = @intCast(off);
    off += @sizeOf(EntityId) * n;
    for (added_offsets, 0..) |*slot, i| {
        _ = i;
        off = std.mem.alignForward(usize, off, @alignOf(Tick));
        slot.* = @intCast(off);
        off += @sizeOf(Tick) * n;
    }
    for (changed_offsets, 0..) |*slot, i| {
        _ = i;
        off = std.mem.alignForward(usize, off, @alignOf(Tick));
        slot.* = @intCast(off);
        off += @sizeOf(Tick) * n;
    }
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

test "computeLayout ACCEPTS an empty component list" {
    // An entity ALWAYS has an archetype, so the archetype of zero components
    // must exist. Re-introducing the old refusal fails here rather than three
    // layers up as a spawn that cannot happen.
    const gpa = std.testing.allocator;
    const layout = try computeLayout(gpa, &.{}, &.{});
    defer {
        gpa.free(layout.component_offsets);
        gpa.free(layout.added_tick_offsets);
        gpa.free(layout.changed_tick_offsets);
    }
    try std.testing.expect(layout.capacity > 0);
    try std.testing.expectEqual(@as(usize, 0), layout.component_offsets.len);
    try std.testing.expectEqual(@as(usize, 0), layout.added_tick_offsets.len);
}

test "computeLayout for (Transform-like 48b/16a, Velocity-like 32b/16a) carries sidecars" {
    // The capacity bounds are a sanity check, not a lock: the sidecars put it
    // below the sidecar-free reference of 185 without pinning a value.
    const gpa = std.testing.allocator;
    const layout = try computeLayout(gpa, &.{ 48, 32 }, &.{ 16, 16 });
    defer gpa.free(layout.component_offsets);
    defer gpa.free(layout.added_tick_offsets);
    defer gpa.free(layout.changed_tick_offsets);

    try std.testing.expect(layout.capacity >= 140);
    try std.testing.expect(layout.capacity <= 180);

    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[0] % 16);
    try std.testing.expectEqual(@as(u16, 0), layout.component_offsets[1] % 16);

    try std.testing.expectEqual(@as(u16, 0), layout.added_tick_offsets[0] % @sizeOf(Tick));
    try std.testing.expectEqual(@as(u16, 0), layout.changed_tick_offsets[0] % @sizeOf(Tick));

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
