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
//!
//! M0.1 / E6 adds **lazy archetype re-scan**. After construction the
//! query caches `last_seen_archetype_count` plus the resolved
//! `required_ids` / `with_ids` / `without_ids` lists plus an opaque
//! accessor to the world's archetype slice. Every external iteration
//! entry point (`chunkCount`, `chunkAt`, `forEachChunk`,
//! `runChunkAt`) compares `world.archetypes.items.len` against
//! `last_seen_archetype_count` and, if different, scans only the new
//! slice `world.archetypes.items[last_seen_archetype_count..]`,
//! applies the same filter set as construction, and appends new
//! matches. Cost in steady-state: `usize == usize` per entry.
//! No registry side, no notification mechanism on the world — pure
//! polling at iteration time. Closes the E3 dette explicitly accepted
//! when command buffers (E6) made mid-frame archetype creation real.

const std = @import("std");
const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");
const registry_mod = @import("registry.zig");
const tick_mod = @import("tick.zig");

const Archetype = archetype_mod.Archetype;
const Chunk = chunk_mod.Chunk;
const ComponentId = registry_mod.ComponentId;
const Tick = tick_mod.Tick;

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

/// Opaque accessor to the world's archetype slice — lets the query's
/// lazy re-scan path read the up-to-date archetype list without
/// taking a hard dependency on `world.zig` (which would create a
/// cyclic import since `world.zig` already depends on `query.zig`).
///
/// `ctx` points at the owning `*World`; `archetypes_slice` casts back
/// and returns `world.archetypes.items`. The slice is recomputed on
/// every call — safe because callers do not retain the result past
/// the rescan loop.
pub const ArchetypeView = struct {
    ctx: *anyopaque,
    archetypes_slice: *const fn (ctx: *anyopaque) []const *Archetype,
};

/// Comptime tag distinguishing the four filter spec kinds. Used by
/// `Query`'s internal parser to bucket the filters tuple.
pub const FilterKind = enum { with, without, predicate, changed };

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

/// Filter spec: matches slots where `T`'s `changed_tick` is strictly
/// greater than the query's runtime `last_run_tick`. `T` must appear
/// in `Components` — the parser asserts that and records the matching
/// index inside the components tuple. Evaluated by `query.slotPasses`
/// (M0.1 / E4).
pub fn Changed(comptime T: type) type {
    return struct {
        pub const filter_kind: FilterKind = .changed;
        pub const component_type: type = T;
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
    comptime var ch_count: usize = 0;
    comptime var predicate: ?PredicateFn = null;
    inline for (filters) |F| {
        switch (F.filter_kind) {
            .with => w_count += 1,
            .without => wo_count += 1,
            .changed => ch_count += 1,
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
    const CHCOUNT = ch_count;
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
    // Changed<T> must reference a component already in `Components`
    // so the per-match column_indices map points at the right
    // archetype column. Record T's index inside the tuple for each
    // Changed filter — slotPasses then reads
    // `match.column_indices[changed_components_index]`.
    const CH_COMPONENT_INDICES: [CHCOUNT]usize = comptime blk: {
        var arr: [CHCOUNT]usize = undefined;
        var i: usize = 0;
        for (filters) |F| {
            if (F.filter_kind == .changed) {
                var found: ?usize = null;
                for (Components, 0..) |C, ci| {
                    if (C == F.component_type) {
                        found = ci;
                        break;
                    }
                }
                if (found == null) {
                    @compileError(
                        "Changed(" ++ @typeName(F.component_type) ++
                            ") requires the same component in the Components tuple of the Query",
                    );
                }
                arr[i] = found.?;
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
        /// Per-Changed<T> filter, the index of T inside the
        /// `Components` tuple. Empty for queries that do not use the
        /// `Changed` filter. Resolved at comptime so the inner-loop
        /// inspection stays branchless on this side.
        pub const changed_component_indices: [CHCOUNT]usize = CH_COMPONENT_INDICES;
        pub const ChunkT = Chunk;

        /// One entry per matched archetype. `column_indices[i]` is the
        /// archetype's column index for `Components[i]` — used by the
        /// typed accessors to recover the SoA pointer.
        pub const Match = struct {
            archetype: *Archetype,
            column_indices: [Components.len]u32,
        };

        matches: std.ArrayListUnmanaged(Match) = .empty,

        /// Tick of the last run of this query. `Changed<T>` filters
        /// compare `changed_tick[T][slot] > last_run_tick` to decide
        /// per-slot inclusion. Callers update this between dispatches
        /// (manual convention until the E5a scheduler introduces
        /// system-level tracking).
        last_run_tick: Tick = tick_mod.initial_tick,

        /// M0.1 / E6 — lazy re-scan state. `archetype_view` is null
        /// for queries built outside `World.queryFiltered` (e.g.
        /// tests constructing a Query directly via `empty()`); those
        /// queries skip the rescan and behave like pre-E6.
        archetype_view: ?ArchetypeView = null,
        /// Allocator captured at construction so `maybeRescan` can
        /// extend the matches list without threading a gpa through
        /// every iteration entry point.
        rescan_gpa: std.mem.Allocator = undefined,
        /// Number of archetypes seen by the most recent rescan (or
        /// by the initial scan in `queryFiltered`). Compared against
        /// `world.archetypes.items.len` on every iteration entry.
        last_seen_archetype_count: usize = 0,
        /// Resolved required / with / without ComponentIds, captured
        /// at construction so the rescan loop reuses the same set.
        required_ids: [Components.len]ComponentId = undefined,
        with_ids: [WCOUNT]ComponentId = undefined,
        without_ids: [WOCOUNT]ComponentId = undefined,

        /// Construct an empty query — used as the no-allocation seed
        /// the world populates via `World.query` / `World.queryFiltered`.
        pub fn empty() Self {
            return .{};
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.matches.deinit(gpa);
            self.* = undefined;
        }

        /// Compare `world.archetypes.items.len` against the cached
        /// `last_seen_archetype_count`. If the world has gained
        /// archetypes since the last scan (typically via a command
        /// buffer flush that materialised a new shape), re-apply the
        /// filter set to the tail slice and append new matches.
        ///
        /// Cheap in the steady state: one usize equality compared,
        /// no heap traffic. The rescan loop itself is `O(new)` over
        /// archetype count.
        ///
        /// Called automatically from every iteration entry point —
        /// callers do not need to invoke it explicitly. No-op when
        /// `archetype_view` is null (test queries built via
        /// `Self.empty()` directly).
        pub fn maybeRescan(self: *Self) void {
            const view = self.archetype_view orelse return;
            const all = view.archetypes_slice(view.ctx);
            if (all.len == self.last_seen_archetype_count) return;
            // Scan only the tail — existing matches remain valid
            // (archetype pointers are stable for the world's lifetime).
            const tail = all[self.last_seen_archetype_count..];
            for (tail) |arch| {
                if (!archetypeMatches(
                    arch,
                    &self.required_ids,
                    &self.with_ids,
                    &self.without_ids,
                )) continue;
                var indices: [Components.len]u32 = undefined;
                for (self.required_ids, 0..) |cid, i| {
                    indices[i] = @intCast(arch.componentIndex(cid).?);
                }
                // `appendBounded` would error on OOM — but a Query
                // built via queryFiltered always carries a heap gpa,
                // and the matches list only grows by O(world
                // archetype delta). On OOM we panic — losing a match
                // silently is a worse failure mode than crashing
                // (would corrupt the iteration's chunkCount/chunkAt
                // contract).
                self.matches.append(self.rescan_gpa, .{
                    .archetype = arch,
                    .column_indices = indices,
                }) catch @panic("Query.maybeRescan: out of memory appending new match");
            }
            self.last_seen_archetype_count = all.len;
        }

        /// Number of matched archetypes. Mostly useful for tests and
        /// debugging — the dispatch protocol cares about `chunkCount`.
        /// Triggers a lazy re-scan against the world's archetype
        /// slice if it has grown since the last entry.
        pub fn matchCount(self: *Self) usize {
            self.maybeRescan();
            return self.matches.items.len;
        }

        /// Aggregate chunk count across every matched archetype.
        /// Defines the dispatch's `[0, chunkCount)` index range that
        /// `chunkAt` resolves. Triggers a lazy re-scan first.
        pub fn chunkCount(self: *Self) usize {
            self.maybeRescan();
            var total: usize = 0;
            for (self.matches.items) |m| total += m.archetype.chunks.items.len;
            return total;
        }

        /// Resolve `i ∈ [0, chunkCount)` to the matching `*Chunk`. The
        /// chunk index walks matches in archetype-creation order
        /// (matches are appended in `world.archetypes` order) then
        /// chunks in `archetype.chunks.items` order.
        ///
        /// **Does NOT** trigger a lazy re-scan — the caller is
        /// expected to have invoked `chunkCount` first (which does
        /// the rescan and stabilises the index space for the rest
        /// of the dispatch). The dispatch protocol in `JobBuilder`
        /// follows this contract: one `chunkCount` followed by N
        /// `chunkAt(i)` calls. Skipping the rescan on the hot path
        /// is a perf optimisation — staging 640 chunks × the rescan
        /// overhead added ~10 µs to the S1 bench at E6.
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
        /// archetype owning `chunk`. The body recovers the chunk's
        /// archetype via the chunk's header and looks up the matching
        /// `column_indices` entry — handles both single- and
        /// multi-archetype queries through a uniform API.
        ///
        /// Single-archetype callers (the S1 bench, the
        /// `no_alloc_in_simulation_test` path) resolve the offset once
        /// at query construction by calling
        /// `query.componentOffsetFor(query.chunkAt(0), i)` and stash
        /// the result in their state struct — the lookup cost (a
        /// linear scan of `matches`, O(matchCount)) is paid once, not
        /// once per chunk.
        ///
        /// Multi-archetype callers (the C0.1 bench's 10 systems) call
        /// `componentOffsetFor(chunk, i)` inside the chunk body itself
        /// because the offset varies between matched archetypes.
        ///
        /// Panics if the chunk is not part of any match — only a
        /// programmer error since `forEachChunk` and `chunkAt` only
        /// hand out chunks from matched archetypes.
        ///
        /// M0.1 / E7 — replaces the older single-archetype-only
        /// `componentOffset(comptime i)` helper. Fusion decision
        /// recorded in the brief journal.
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

        /// Evaluate the per-slot filters — the optional `Predicate(fn)`
        /// from E3 and every `Changed<T>` filter from E4. Returns
        /// `true` when no filters disqualify the slot. Bodies call
        /// this inside their inner loop so the comptime-known filter
        /// set inlines alongside the hot-path work.
        ///
        /// Caller must guarantee `archetype` owns `chunk` — typically
        /// via `query.matchFor(chunk)` upstream of the slot loop.
        pub fn slotPasses(self: *const Self, archetype: *const Archetype, chunk: *Chunk, slot: u32) bool {
            if (Self.predicate_fn) |f| {
                if (!f(archetype, chunk, slot)) return false;
            }
            if (Self.changed_component_indices.len > 0) {
                // The match is needed to recover the archetype's
                // column index for each Changed<T> filter.
                const match = self.matchFor(chunk) orelse return false;
                inline for (Self.changed_component_indices) |ci| {
                    const col = match.column_indices[ci];
                    if (archetype.changedTick(chunk, col, slot) <= self.last_run_tick) {
                        return false;
                    }
                }
            }
            return true;
        }

        /// Run `Body` once per chunk on the calling thread. `Body`
        /// must accept `(*Chunk, ...args)`. Iteration order is
        /// archetype-creation order then chunk order — the predicate
        /// is **not** applied automatically; bodies call `slotPasses`
        /// on individual slots when they want filtering. Triggers a
        /// lazy re-scan first so newly-materialised archetypes appear
        /// on the next iteration.
        pub fn forEachChunk(self: *Self, comptime Body: anytype, args: anytype) void {
            self.maybeRescan();
            for (self.matches.items) |m| {
                for (m.archetype.chunks.items) |chunk| {
                    @call(.auto, Body, .{chunk} ++ args);
                }
            }
        }

        /// Run `Body` on the chunk at global index `idx`. Used by the
        /// scheduler to dispatch chunks across workers via the same
        /// `chunkAt(i)` protocol. The caller is expected to have
        /// invoked `chunkCount` first, which triggers the rescan and
        /// stabilises the index space for the rest of the dispatch.
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
