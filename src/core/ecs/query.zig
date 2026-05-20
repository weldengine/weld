//! Comptime-typed multi-archetype query.
//!
//! M0.1 / E3 extends the E2 single-archetype view with `With(T)`,
//! `Without(T)`, and `Predicate(fn)` filters. A `Query(components,
//! filters)` walks every archetype in the world that:
//!
//! - holds **every** type in `components` (the read/write set),
//! - holds **every** type in the `With(...)` filters,
//! - holds **none** of the types in the `Without(...)` filters,
//!
//! caches the per-archetype column-index map, and exposes the chunks
//! of every matching archetype through a unified `chunkAt(i)` /
//! `chunkCount()` view. Iteration order is documented:
//! **archetype-creation order → chunk order → slot order** inside each
//! chunk. The job system relies on `chunkAt(i)` returning a stable
//! `*Chunk` for the duration of the dispatch.
//!
//! Per-entity filtering. `Predicate(fn)` registers a predicate that is
//! **not** applied automatically inside `forEachChunk` — the dispatch
//! body calls `query.slotPasses(arch, chunk, slot)` inside its inner
//! loop so the predicate can run alongside the body's own work. Bodies
//! that ignore the predicate iterate every slot of every matched
//! chunk (Phase 0 design — automatic per-slot dispatch is a Phase 1
//! refinement).
//!
//! M0.1 / E3 explicitly defers `Changed<T>` to E4 (tick-based change
//! detection) and the multi-job concurrent intra-phase scheduler to
//! E5b. The S1 job system (one job in flight at a time, via
//! `Scheduler.dispatch`) still consumes the query through the same
//! `chunkAt(i)` protocol.

const std = @import("std");
const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");
const registry_mod = @import("registry.zig");

const Archetype = archetype_mod.Archetype;
const Chunk = chunk_mod.Chunk;
const ComponentId = registry_mod.ComponentId;

/// Predicate signature used by the `Predicate(fn)` filter. The
/// predicate runs against a single slot in a matched archetype's
/// chunk and returns `true` to keep the entity. Components are read
/// through the archetype's byte-level accessors so the predicate
/// stays independent of how the calling query was typed.
pub const PredicateFn = *const fn (
    archetype: *const Archetype,
    chunk: *Chunk,
    slot: u32,
) bool;

/// Comptime tag distinguishing the three filter spec kinds. Used by
/// `Query`'s internal `parseFilters` to bucket the filters tuple.
pub const FilterKind = enum { with, without, predicate };

/// Filter spec: matching archetype must contain `T`.
pub fn With(comptime T: type) type {
    return struct {
        pub const filter_kind: FilterKind = .with;
        pub const component_type: type = T;
    };
}

/// Filter spec: matching archetype must NOT contain `T`.
pub fn Without(comptime T: type) type {
    return struct {
        pub const filter_kind: FilterKind = .without;
        pub const component_type: type = T;
    };
}

/// Filter spec: per-slot predicate evaluated by `query.slotPasses`.
/// E3 supports at most one predicate per query (the comptime parser
/// raises a `@compileError` on a second predicate).
pub fn Predicate(comptime f: PredicateFn) type {
    return struct {
        pub const filter_kind: FilterKind = .predicate;
        pub const predicate_fn: PredicateFn = f;
    };
}

/// Comptime-typed query factory.
///
/// - `Components` — the tuple of types the body reads / writes. Every
///   matched archetype is guaranteed to expose these in its column
///   list; the per-archetype `Match.column_indices` map their tuple
///   index to the archetype's sorted column.
/// - `filters` — a tuple of filter spec types built from `With(T)`,
///   `Without(T)`, and `Predicate(fn)`. The order of filters does not
///   affect matching; the comptime parser inlined below splits them
///   into three buckets (with-list, without-list, optional predicate).
///
/// The split is computed inside this function and copied into fixed
/// arrays so the resulting struct never captures a pointer to a
/// `comptime var` local (Zig 0.16 forbids that).
pub fn Query(comptime Components: []const type, comptime filters: anytype) type {
    // Pass 1 — count each filter bucket and surface the predicate.
    comptime var w_count: usize = 0;
    comptime var wo_count: usize = 0;
    comptime var predicate: ?PredicateFn = null;
    inline for (filters) |F| {
        switch (F.filter_kind) {
            .with => w_count += 1,
            .without => wo_count += 1,
            .predicate => {
                if (predicate != null) {
                    @compileError("Query supports at most one Predicate filter in M0.1 / E3");
                }
                predicate = F.predicate_fn;
            },
        }
    }
    const WCOUNT = w_count;
    const WOCOUNT = wo_count;
    const PRED = predicate;

    // Pass 2 — populate fixed-size arrays inside `comptime` blocks so
    // the resulting values are immutable consts, not comptime vars.
    const W_TYPES: [WCOUNT]type = comptime blk: {
        var arr: [WCOUNT]type = undefined;
        var i: usize = 0;
        for (filters) |F| {
            if (F.filter_kind == .with) {
                arr[i] = F.component_type;
                i += 1;
            }
        }
        break :blk arr;
    };
    const WO_TYPES: [WOCOUNT]type = comptime blk: {
        var arr: [WOCOUNT]type = undefined;
        var i: usize = 0;
        for (filters) |F| {
            if (F.filter_kind == .without) {
                arr[i] = F.component_type;
                i += 1;
            }
        }
        break :blk arr;
    };

    return struct {
        const Self = @This();
        pub const component_types: []const type = Components;
        pub const with_types: [WCOUNT]type = W_TYPES;
        pub const without_types: [WOCOUNT]type = WO_TYPES;
        pub const predicate_fn: ?PredicateFn = PRED;
        pub const ChunkT = Chunk;

        /// One entry per matched archetype. `column_indices[i]` is the
        /// archetype's column index for `Components[i]` — used by the
        /// typed accessors to recover the SoA pointer.
        pub const Match = struct {
            archetype: *Archetype,
            column_indices: [Components.len]u32,
        };

        matches: std.ArrayListUnmanaged(Match) = .empty,

        /// Construct an empty query — used as the no-allocation seed
        /// the world populates via `World.query` / `World.queryFiltered`.
        pub fn empty() Self {
            return .{};
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.matches.deinit(gpa);
            self.* = undefined;
        }

        /// Number of matched archetypes. Mostly useful for tests and
        /// debugging — the dispatch protocol cares about `chunkCount`.
        pub fn matchCount(self: *const Self) usize {
            return self.matches.items.len;
        }

        /// Aggregate chunk count across every matched archetype.
        /// Defines the dispatch's `[0, chunkCount)` index range that
        /// `chunkAt` resolves.
        pub fn chunkCount(self: *const Self) usize {
            var total: usize = 0;
            for (self.matches.items) |m| total += m.archetype.chunks.items.len;
            return total;
        }

        /// Resolve `i ∈ [0, chunkCount)` to the matching `*Chunk`. The
        /// chunk index walks matches in archetype-creation order
        /// (matches are appended in `world.archetypes` order) then
        /// chunks in `archetype.chunks.items` order.
        pub fn chunkAt(self: *const Self, i: usize) *Chunk {
            var idx = i;
            for (self.matches.items) |m| {
                const n = m.archetype.chunks.items.len;
                if (idx < n) return m.archetype.chunks.items[idx];
                idx -= n;
            }
            @panic("chunkAt index out of range");
        }

        /// Look up the `Match` record for a chunk by its owning
        /// archetype id. `null` if the chunk does not belong to any of
        /// this query's matched archetypes.
        pub fn matchFor(self: *const Self, chunk: *Chunk) ?*const Match {
            const arch_id = chunk.header().archetype_id;
            for (self.matches.items) |*m| {
                if (m.archetype.archetype_id == arch_id) return m;
            }
            return null;
        }

        /// Byte offset of `Components[i]`'s SoA column inside the
        /// **single matched archetype**. Asserts `matchCount() == 1` —
        /// kept for the bench / no_alloc paths that resolve the offset
        /// once before the dispatch loop. Multi-archetype callers use
        /// `componentOffsetFor` instead.
        pub fn componentOffset(self: *const Self, comptime i: usize) u16 {
            std.debug.assert(self.matches.items.len == 1);
            const m = self.matches.items[0];
            return m.archetype.layout.component_offsets[m.column_indices[i]];
        }

        /// Byte offset of `Components[i]` in the archetype owning
        /// `chunk`. The multi-archetype counterpart to
        /// `componentOffset`. Panics if the chunk is not part of any
        /// match — only a programmer error since `forEachChunk` only
        /// hands out chunks from matched archetypes.
        pub fn componentOffsetFor(self: *const Self, chunk: *Chunk, comptime i: usize) u16 {
            const m = self.matchFor(chunk) orelse @panic("componentOffsetFor on a non-match chunk");
            return m.archetype.layout.component_offsets[m.column_indices[i]];
        }

        /// Typed slice covering `Components[i]`'s SoA column for the
        /// live entities of `chunk`. Length is the chunk's
        /// `entity_count`. Hot-path-friendly: one comptime-resolved
        /// type pun + one implicit slice from the live count.
        pub fn componentColumn(self: *const Self, chunk: *Chunk, comptime i: usize) []Components[i] {
            const off = self.componentOffsetFor(chunk, i);
            const count = chunk.header().entity_count;
            const ptr: [*]Components[i] = @ptrCast(@alignCast(&chunk.bytes[off]));
            return ptr[0..count];
        }

        /// Raw `[*]Components[i]` pointer to the SoA column for the
        /// archetype owning `chunk`. Equivalent to
        /// `componentColumn(...).ptr` without the implicit length
        /// pickup — handy when the body already has the entity count
        /// in hand.
        pub fn componentArray(self: *const Self, chunk: *Chunk, comptime i: usize) [*]Components[i] {
            const off = self.componentOffsetFor(chunk, i);
            return @ptrCast(@alignCast(&chunk.bytes[off]));
        }

        /// Evaluate the optional per-slot predicate. Returns `true`
        /// when no predicate was configured. Bodies that want
        /// per-entity filtering call this inside their inner loop so
        /// the comptime-known predicate can be inlined alongside the
        /// hot-path work.
        pub fn slotPasses(_: *const Self, archetype: *const Archetype, chunk: *Chunk, slot: u32) bool {
            if (Self.predicate_fn) |f| return f(archetype, chunk, slot);
            return true;
        }

        /// Run `Body` once per chunk on the calling thread. `Body`
        /// must accept `(*Chunk, ...args)`. Iteration order is
        /// archetype-creation order then chunk order — the predicate
        /// is **not** applied automatically; bodies call `slotPasses`
        /// on individual slots when they want filtering.
        pub fn forEachChunk(self: *Self, comptime Body: anytype, args: anytype) void {
            for (self.matches.items) |m| {
                for (m.archetype.chunks.items) |chunk| {
                    @call(.auto, Body, .{chunk} ++ args);
                }
            }
        }

        /// Run `Body` on the chunk at global index `idx`. Used by the
        /// scheduler to dispatch chunks across workers via the same
        /// `chunkAt(i)` protocol.
        pub fn runChunkAt(self: *Self, idx: usize, comptime Body: anytype, args: anytype) void {
            const chunk = self.chunkAt(idx);
            @call(.auto, Body, .{chunk} ++ args);
        }
    };
}

// ─── Convenience for the world's matching routine ─────────────────────────

/// Helper consumed by `World` when populating the matches list. Returns
/// `true` if `arch` satisfies the requested component / with / without
/// component-id sets. Predicate evaluation happens at iteration time
/// inside `slotPasses` — at archetype-matching time we only care about
/// the structural shape.
pub fn archetypeMatches(
    arch: *const Archetype,
    required_ids: []const ComponentId,
    with_ids: []const ComponentId,
    without_ids: []const ComponentId,
) bool {
    for (required_ids) |cid| {
        if (!arch.hasComponent(cid)) return false;
    }
    for (with_ids) |cid| {
        if (!arch.hasComponent(cid)) return false;
    }
    for (without_ids) |cid| {
        if (arch.hasComponent(cid)) return false;
    }
    return true;
}
