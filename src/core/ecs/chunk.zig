//! 16 KiB SoA chunk for archetype storage.
//!
//! Generic over a tuple of component types. Each component has its own
//! contiguous array within the chunk (SoA per component), 16-byte aligned for
//! SIMD. A single entity-id array runs alongside. The header is intentionally
//! minimal per `briefs/S1-mini-ecs.md` Scope: `entity_count`, `capacity`,
//! `archetype_id`, `next_chunk` pointer, and `component_offsets[C]`. Tick
//! arrays, dirty bitset, and transitions cache are deferred to Phase 0.1
//! (cf. `engine-ecs-internals.md` §2 — they are purely additive on top of
//! this layout).
//!
//! The chunk is allocated as a single 16 KiB block aligned to 16 bytes; the
//! header is overlaid on the first bytes via a comptime-computed layout. The
//! component arrays follow in declaration order, each starting at a 16-aligned
//! offset. The entity-id array trails (8-byte aligned suffices). Capacity is
//! the largest `N` such that the resulting layout fits within the chunk.

const std = @import("std");
const components = @import("components.zig");

const EntityId = components.EntityId;

/// Total chunk size — locked to 16 KiB to fit comfortably in L1D on modern
/// x86-64, Apple Silicon, and ARM Cortex CPUs (cf. `engine-spec.md` §2.3).
pub const ChunkSize: usize = 16 * 1024;

/// Required alignment of the chunk and of every component array within it.
/// 16 bytes matches `@Vector(4, f32)`, the worst case for the S1 components.
pub const ChunkAlignment: usize = 16;

/// Layout descriptor for an archetype with the given component types. All
/// fields are comptime constants — the layout is fully determined by the
/// component types alone.
pub fn ChunkLayout(comptime Components: []const type) type {
    return struct {
        pub const component_count: usize = Components.len;
        pub const header_size: usize = computeHeaderSize();
        pub const capacity: u32 = computeCapacity();
        pub const component_offsets: [component_count]u16 = computeComponentOffsets();
        pub const entity_ids_offset: u16 = computeEntityIdsOffset();

        fn computeHeaderSize() usize {
            // Mirror the field layout of `Header` below. Zig 0.16 lays out
            // extern structs in declaration order with C padding rules.
            var off: usize = 0;
            off = std.mem.alignForward(usize, off, @alignOf(u32)) + @sizeOf(u32); // entity_count
            off = std.mem.alignForward(usize, off, @alignOf(u32)) + @sizeOf(u32); // capacity
            off = std.mem.alignForward(usize, off, @alignOf(u32)) + @sizeOf(u32); // archetype_id
            off = std.mem.alignForward(usize, off, @alignOf(u32)) + @sizeOf(u32); // _pad
            off = std.mem.alignForward(usize, off, @alignOf(usize)) + @sizeOf(usize); // next_chunk pointer
            off = std.mem.alignForward(usize, off, @alignOf(u16)) + 2 * component_count; // component_offsets[C]
            // Round up so the first component array starts on `ChunkAlignment`.
            return std.mem.alignForward(usize, off, ChunkAlignment);
        }

        fn computeCapacity() u32 {
            var n: usize = (ChunkSize - header_size) / strideBytes();
            while (n > 0) : (n -= 1) {
                if (layoutFits(n)) break;
            }
            return @intCast(n);
        }

        fn strideBytes() usize {
            var s: usize = @sizeOf(EntityId);
            inline for (Components) |C| s += @sizeOf(C);
            return s;
        }

        fn layoutFits(n: usize) bool {
            var off: usize = header_size;
            inline for (Components) |C| {
                off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @alignOf(C)));
                off += @sizeOf(C) * n;
            }
            off = std.mem.alignForward(usize, off, @alignOf(EntityId));
            off += @sizeOf(EntityId) * n;
            return off <= ChunkSize;
        }

        fn computeComponentOffsets() [component_count]u16 {
            var offsets: [component_count]u16 = undefined;
            var off: usize = header_size;
            inline for (Components, 0..) |C, i| {
                off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @alignOf(C)));
                offsets[i] = @intCast(off);
                off += @sizeOf(C) * capacity;
            }
            return offsets;
        }

        fn computeEntityIdsOffset() u16 {
            var off: usize = header_size;
            inline for (Components) |C| {
                off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @alignOf(C)));
                off += @sizeOf(C) * capacity;
            }
            off = std.mem.alignForward(usize, off, @alignOf(EntityId));
            return @intCast(off);
        }
    };
}

/// Chunk type for an archetype with the given component types. The struct
/// is exactly `ChunkSize` bytes, 16-byte aligned. The header is overlaid on
/// the first bytes; the rest holds the SoA arrays.
pub fn Chunk(comptime Components: []const type) type {
    return struct {
        const Self = @This();
        pub const Layout = ChunkLayout(Components);
        pub const component_types: []const type = Components;
        pub const capacity: u32 = Layout.capacity;

        /// Limited header per `briefs/S1-mini-ecs.md` Scope. `_pad` keeps
        /// `next_chunk` 8-byte aligned.
        pub const Header = extern struct {
            entity_count: u32,
            capacity: u32,
            archetype_id: u32,
            _pad: u32 = 0,
            next_chunk: ?*Self,
            component_offsets: [Components.len]u16,
        };

        bytes: [ChunkSize]u8 align(ChunkAlignment),

        comptime {
            std.debug.assert(@sizeOf(Self) == ChunkSize);
            std.debug.assert(@alignOf(Self) >= ChunkAlignment);
            std.debug.assert(@sizeOf(Header) <= Layout.header_size);
        }

        /// Initialize the header in place. Storage area is left uninitialized
        /// — only slots `[0, entity_count)` are ever read.
        pub fn initInPlace(self: *Self, archetype_id: u32) void {
            const hdr: *Header = @ptrCast(@alignCast(&self.bytes));
            hdr.* = .{
                .entity_count = 0,
                .capacity = capacity,
                .archetype_id = archetype_id,
                .next_chunk = null,
                .component_offsets = Layout.component_offsets,
            };
        }

        pub fn header(self: *Self) *Header {
            return @ptrCast(@alignCast(&self.bytes));
        }

        pub fn headerConst(self: *const Self) *const Header {
            return @ptrCast(@alignCast(&self.bytes));
        }

        pub fn entityCount(self: *const Self) u32 {
            return self.headerConst().entity_count;
        }

        pub fn isFull(self: *const Self) bool {
            return self.entityCount() >= capacity;
        }

        /// Pointer to the contiguous array for component index `i`. Length is
        /// `entityCount()` (only valid slots).
        pub fn componentArray(self: *Self, comptime i: usize) [*]Components[i] {
            const off = Layout.component_offsets[i];
            return @ptrCast(@alignCast(&self.bytes[off]));
        }

        pub fn componentArrayConst(self: *const Self, comptime i: usize) [*]const Components[i] {
            const off = Layout.component_offsets[i];
            return @ptrCast(@alignCast(&self.bytes[off]));
        }

        /// Pointer to the entity-id array. Length is `entityCount()`.
        pub fn entityIds(self: *Self) [*]EntityId {
            return @ptrCast(@alignCast(&self.bytes[Layout.entity_ids_offset]));
        }

        pub fn entityIdsConst(self: *const Self) [*]const EntityId {
            return @ptrCast(@alignCast(&self.bytes[Layout.entity_ids_offset]));
        }

        /// Append an entity to the chunk. Returns the slot index, or null if
        /// the chunk is full.
        pub fn append(self: *Self, entity_id: EntityId, init_values: anytype) ?u32 {
            const hdr = self.header();
            if (hdr.entity_count >= capacity) return null;
            const slot = hdr.entity_count;
            inline for (Components, 0..) |C, i| {
                const arr = self.componentArray(i);
                arr[slot] = @field(init_values, std.fmt.comptimePrint("{d}", .{i}));
                _ = C;
            }
            self.entityIds()[slot] = entity_id;
            hdr.entity_count = slot + 1;
            return slot;
        }

        /// Swap-and-pop the entity at `slot`. Returns the entity id that got
        /// swapped into `slot` (so the caller can update its location map),
        /// or null if `slot` was already the last entity.
        pub fn removeSwap(self: *Self, slot: u32) ?EntityId {
            const hdr = self.header();
            std.debug.assert(slot < hdr.entity_count);
            const last = hdr.entity_count - 1;
            if (slot == last) {
                hdr.entity_count = last;
                return null;
            }
            inline for (Components, 0..) |C, i| {
                const arr = self.componentArray(i);
                arr[slot] = arr[last];
                _ = C;
            }
            const ids = self.entityIds();
            const moved_id = ids[last];
            ids[slot] = moved_id;
            hdr.entity_count = last;
            return moved_id;
        }
    };
}
