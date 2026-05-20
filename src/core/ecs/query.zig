//! Comptime-generic query over a single archetype.
//!
//! The S1 query is intentionally narrow: one archetype in, one body out, no
//! filters, no exclusions, no multi-archetype. Per `briefs/S1-mini-ecs.md`
//! Out-of-scope. The body receives a chunk pointer and is free to extract
//! the typed component arrays via `chunk.componentArray(i)`. Per-entity
//! iteration lives inside the body so the inner loop stays tight and
//! vectorisation-friendly — no closure overhead per slot.
//!
//! `forEachChunk` runs the body sequentially on every chunk; the scheduler
//! (`src/core/jobs/scheduler.zig`) reuses the per-chunk dispatch primitive
//! `runChunkAt` to split work across worker threads.

const std = @import("std");
const archetype_mod = @import("archetype.zig");

/// Generic comptime query factory: returns a struct that iterates the
/// chunks of the matching archetype yielding `(EntityId, *Components[0],
/// *Components[1], …)` per slot. Zero dispatch overhead at runtime.
pub fn Query(comptime Components: []const type) type {
    return struct {
        const Self = @This();
        pub const ArchetypeT = archetype_mod.Archetype(Components);
        pub const ChunkT = ArchetypeT.ChunkT;
        pub const component_types: []const type = Components;

        archetype: *ArchetypeT,

        pub fn init(arch: *ArchetypeT) Self {
            return .{ .archetype = arch };
        }

        pub fn chunkCount(self: *const Self) usize {
            return self.archetype.chunks.items.len;
        }

        pub fn chunkAt(self: *Self, idx: usize) *ChunkT {
            return self.archetype.chunks.items[idx];
        }

        /// Run `Body` once per chunk on the calling thread. `Body` receives
        /// `(*ChunkT, ...args)`.
        pub fn forEachChunk(self: *Self, comptime Body: anytype, args: anytype) void {
            for (self.archetype.chunks.items) |chunk| {
                @call(.auto, Body, .{chunk} ++ args);
            }
        }

        /// Run `Body` on a specific chunk. Used by the scheduler to dispatch
        /// chunks across workers.
        pub fn runChunkAt(self: *Self, idx: usize, comptime Body: anytype, args: anytype) void {
            const chunk = self.archetype.chunks.items[idx];
            @call(.auto, Body, .{chunk} ++ args);
        }
    };
}
