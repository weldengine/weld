//! Comptime-generic archetype storage. An `Archetype(Components)` owns the
//! list of chunks for a single component combination. Append goes to the last
//! chunk (allocating a new one when full); `removeSwap` performs swap-and-pop
//! within a chunk. The archetype keeps an `ArrayListUnmanaged` of chunk
//! pointers for index-based access (used by the scheduler to split work) and
//! also maintains the linked-list `next_chunk` field of each chunk header so
//! both traversal modes are coherent.
//!
//! Out-of-scope per `briefs/S1-mini-ecs.md`: archetype transitions, slot
//! reuse across chunks, archetype matching across multiple archetypes. This
//! S1 implementation grows monotonically on append and shrinks monotonically
//! at the trailing chunk on remove.

const std = @import("std");
const components = @import("components.zig");
const chunk_mod = @import("chunk.zig");

/// Re-exports `components.EntityId` — `u64` entity handle.
pub const EntityId = components.EntityId;

/// Location of an entity within an archetype: chunk index in the archetype's
/// chunk list, plus slot index within that chunk.
pub const Location = struct {
    chunk_idx: u32,
    slot: u32,
};

/// Generic comptime SoA archetype factory: returns a struct whose
/// chunks store one column per `Components` entry. The returned type
/// owns the chunk list and exposes entity insertion / removal / lookup.
pub fn Archetype(comptime Components: []const type) type {
    return struct {
        const Self = @This();
        pub const ChunkT = chunk_mod.Chunk(Components);
        pub const component_types: []const type = Components;

        archetype_id: u32,
        chunks: std.ArrayListUnmanaged(*ChunkT),

        pub fn init(archetype_id: u32) Self {
            return .{ .archetype_id = archetype_id, .chunks = .empty };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.chunks.items) |chunk| gpa.destroy(chunk);
            self.chunks.deinit(gpa);
            self.* = undefined;
        }

        pub fn entityCount(self: *const Self) usize {
            var total: usize = 0;
            for (self.chunks.items) |chunk| total += chunk.entityCount();
            return total;
        }

        pub fn chunkCount(self: *const Self) usize {
            return self.chunks.items.len;
        }

        /// Append an entity and return its location. `init_values` is a tuple
        /// of component values, one per type in `Components` and in the same
        /// order.
        pub fn append(
            self: *Self,
            gpa: std.mem.Allocator,
            entity_id: EntityId,
            init_values: anytype,
        ) !Location {
            const chunk = blk: {
                if (self.chunks.items.len > 0) {
                    const last = self.chunks.items[self.chunks.items.len - 1];
                    if (!last.isFull()) break :blk last;
                }
                break :blk try self.allocChunk(gpa);
            };
            const slot = chunk.append(entity_id, init_values) orelse unreachable;
            return .{
                .chunk_idx = @intCast(self.chunks.items.len - 1),
                .slot = slot,
            };
        }

        fn allocChunk(self: *Self, gpa: std.mem.Allocator) !*ChunkT {
            const chunk = try gpa.create(ChunkT);
            errdefer gpa.destroy(chunk);
            chunk.initInPlace(self.archetype_id);
            if (self.chunks.items.len > 0) {
                self.chunks.items[self.chunks.items.len - 1].header().next_chunk = chunk;
            }
            try self.chunks.append(gpa, chunk);
            return chunk;
        }

        /// Swap-and-pop the entity at `location`. Returns the entity id that
        /// was moved into the freed slot (so the caller can update its
        /// location map), or null if `location` was already the last slot of
        /// its chunk and no swap took place.
        pub fn removeSwap(self: *Self, location: Location) ?EntityId {
            return self.chunks.items[location.chunk_idx].removeSwap(location.slot);
        }

        /// Pointer to chunk `i`. Used by the scheduler to split work across
        /// chunks.
        pub fn chunkAt(self: *Self, i: usize) *ChunkT {
            return self.chunks.items[i];
        }
    };
}
