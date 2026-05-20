//! Comptime-typed query view over the M0.1 / E2 generalised archetype
//! storage.
//!
//! The S1 single-archetype query API surface is preserved: `Query(.{T1,
//! T2, …})` exposes `chunkCount`, `chunkAt`, `forEachChunk`, and
//! `runChunkAt` so the work-stealing scheduler and the bench harness
//! consume the same shape they did under the pre-E2 comptime archetype.
//! Underneath, the query just borrows a `*Archetype` and remembers the
//! runtime mapping `Components[i] → column index` so the typed component
//! accessors below can dereference the byte-level chunks without a
//! per-call HashMap probe.
//!
//! The brief's E2 step explicitly defers any new filter surface (with /
//! without / changed / predicate) to E3+ — this file only carries the
//! single-archetype, no-filter case.

const std = @import("std");
const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");
const registry_mod = @import("registry.zig");

const Archetype = archetype_mod.Archetype;
const Chunk = chunk_mod.Chunk;
const ComponentId = registry_mod.ComponentId;

/// Comptime-typed query factory. `Components` is the tuple of component
/// types the consumer wants to read or write; the resulting query yields
/// `*Chunk` pointers (the byte-level chunks owned by the matched
/// archetype) and exposes per-component accessors that pre-compute the
/// runtime byte offset for `Components[i]`.
pub fn Query(comptime Components: []const type) type {
    return struct {
        const Self = @This();
        pub const component_types: []const type = Components;
        pub const ChunkT = Chunk;

        /// Borrowed archetype matching this query's component set.
        /// `null` when no archetype with those components has been
        /// created in the world yet — `forEachChunk` becomes a no-op.
        archetype: ?*Archetype,
        /// Runtime mapping `i (index into Components) → j (index into
        /// archetype.component_ids)`. Computed once at query
        /// construction so the chunk accessors stay branch-free.
        column_indices: [Components.len]u32,

        pub fn empty() Self {
            return .{ .archetype = null, .column_indices = [_]u32{0} ** Components.len };
        }

        /// Build a query against an already-resolved archetype. Used by
        /// `World.query()` once it has located (or failed to locate)
        /// the matching archetype. Caller must guarantee the archetype
        /// holds every type in `Components` — the column index map
        /// asserts that contract via `componentIndex`.
        pub fn fromArchetype(arch: *Archetype, component_ids: [Components.len]ComponentId) Self {
            var indices: [Components.len]u32 = undefined;
            for (component_ids, 0..) |cid, i| {
                const ci = arch.componentIndex(cid) orelse @panic("query archetype missing component");
                indices[i] = @intCast(ci);
            }
            return .{ .archetype = arch, .column_indices = indices };
        }

        pub fn chunkCount(self: *const Self) usize {
            return if (self.archetype) |a| a.chunks.items.len else 0;
        }

        /// Return the `*Chunk` at index `i`. Used by the scheduler to
        /// stripe chunks across workers. The chunk pointer alone does
        /// not carry typed layout — call `componentArray` or
        /// `componentColumn` on the query view to recover typed slices.
        pub fn chunkAt(self: *const Self, i: usize) *Chunk {
            return self.archetype.?.chunks.items[i];
        }

        /// Byte offset of `Components[i]`'s SoA column inside any chunk
        /// of the matched archetype. Constant for the query's lifetime
        /// — the bench harness reads it once and passes the offset down
        /// to the dispatch body so the inner loop can index by raw
        /// bytes.
        pub fn componentOffset(self: *const Self, comptime i: usize) u16 {
            return self.archetype.?.layout.component_offsets[self.column_indices[i]];
        }

        /// Typed slice covering `Components[i]`'s SoA column for the
        /// live entities of `chunk`. Length is the chunk's
        /// `entity_count`. Hot-path-friendly: one comptime-resolved
        /// type pun + one bounds-implied slice from the live count.
        pub fn componentColumn(self: *const Self, chunk: *Chunk, comptime i: usize) []Components[i] {
            const off = self.componentOffset(i);
            const count = chunk.header().entity_count;
            const ptr: [*]Components[i] = @ptrCast(@alignCast(&chunk.bytes[off]));
            return ptr[0..count];
        }

        /// Raw `[*]Components[i]` pointer to the SoA column for the
        /// matched archetype. Equivalent to `componentColumn(...).ptr`
        /// without the implicit length pickup — handy when the body
        /// already has the entity count in hand.
        pub fn componentArray(self: *const Self, chunk: *Chunk, comptime i: usize) [*]Components[i] {
            const off = self.componentOffset(i);
            return @ptrCast(@alignCast(&chunk.bytes[off]));
        }

        /// Run `Body` once per chunk on the calling thread. `Body` must
        /// accept `(*Chunk, ...args)`. No-op when the query has no
        /// matching archetype.
        pub fn forEachChunk(self: *Self, comptime Body: anytype, args: anytype) void {
            const arch = self.archetype orelse return;
            for (arch.chunks.items) |chunk| {
                @call(.auto, Body, .{chunk} ++ args);
            }
        }

        /// Run `Body` on a specific chunk. Used by the scheduler to
        /// dispatch chunks across workers.
        pub fn runChunkAt(self: *Self, idx: usize, comptime Body: anytype, args: anytype) void {
            const chunk = self.archetype.?.chunks.items[idx];
            @call(.auto, Body, .{chunk} ++ args);
        }
    };
}
