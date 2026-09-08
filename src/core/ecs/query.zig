//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Comptime-typed multi-archetype query: every type in `Components` and in every
//! `With(T)`, none from `Without(T)`.
//!
//! ITERATION ORDER IS PART OF THE CONTRACT — archetype-creation order, then chunk,
//! then slot — and the job system relies on `chunkAt(i)` handing back a STABLE
//! `*Chunk` for the whole dispatch.
//!
//! `Predicate(fn)` and `Changed<T>` are NOT applied by `forEachChunk`: the body
//! calls `slotPasses` in its inner loop, and a body that ignores it iterates every
//! slot of every matched chunk.
//!
//! Archetype re-scan is LAZY and by polling: each iteration entry compares the
//! world's archetype count against the cached one and scans only the tail. There is
//! no notification from the world, so an archetype created mid-frame appears at the
//! next entry and not before.

const std = @import("std");
const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");
const registry_mod = @import("registry.zig");
// for the job-body bound only; the type is refused, never built here.
const command_buffer_mod = @import("command_buffer.zig");
const tick_mod = @import("tick.zig");

const Archetype = archetype_mod.Archetype;
const Chunk = chunk_mod.Chunk;
const ComponentId = registry_mod.ComponentId;
const Tick = tick_mod.Tick;

/// Runs against ONE slot and returns `true` to keep the entity. Reads through the
/// archetype's byte accessors, so it does not depend on how the query was typed.
pub const PredicateFn = *const fn (
    archetype: *const Archetype,
    chunk: *Chunk,
    slot: u32,
) bool;

/// Opaque accessor to the world's archetype slice: a hard dependency on `world.zig`
/// would be a cyclic import. The slice is recomputed per call, so a caller must NOT
/// retain it past the rescan loop.
pub const ArchetypeView = struct {
    ctx: *anyopaque,
    archetypes_slice: *const fn (ctx: *anyopaque) []const *Archetype,
};

/// Comptime tag used by `Query`'s parser to bucket the filters tuple.
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

/// At most ONE predicate per query — a second is a `@compileError`.
pub fn Predicate(comptime f: PredicateFn) type {
    return struct {
        pub const filter_kind: FilterKind = .predicate;
        pub const predicate_fn: PredicateFn = f;
    };
}

/// Matches a slot whose `changed_tick` for `T` is STRICTLY after `last_run_tick`.
/// `T` must appear in `Components`; the parser asserts it and records its index.
pub fn Changed(comptime T: type) type {
    return struct {
        pub const filter_kind: FilterKind = .changed;
        pub const component_type: type = T;
    };
}

/// Comptime-typed query factory. Filter order does NOT affect matching.
///
/// The bucket split is copied into fixed arrays so the resulting struct never
/// captures a pointer to a `comptime var` local, which Zig 0.16 forbids.
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

    // Inside `comptime` blocks so the values are consts, not comptime vars.
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
    // `Changed<T>` needs T's index INSIDE the components tuple, because
    // `slotPasses` reads `match.column_indices[that index]`.
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
        /// Resolved at comptime, so the inner-loop inspection stays branchless.
        pub const changed_component_indices: [CHCOUNT]usize = CH_COMPONENT_INDICES;
        pub const ChunkT = Chunk;

        /// `column_indices[i]` is the archetype's column for `Components[i]`.
        pub const Match = struct {
            archetype: *Archetype,
            column_indices: [Components.len]u32,
        };

        matches: std.ArrayListUnmanaged(Match) = .empty,

        /// `Changed<T>` compares against this. CALLERS update it between
        /// dispatches — nothing in the scheduler does it for them.
        last_run_tick: Tick = tick_mod.initial_tick,

        /// `null` for a query built outside `World.queryFiltered`, which then never rescans.
        archetype_view: ?ArchetypeView = null,
        /// Captured so `maybeRescan` needs no gpa threaded through every entry.
        rescan_gpa: std.mem.Allocator = undefined,
        /// Compared against `world.archetypes.items.len` on every iteration entry.
        last_seen_archetype_count: usize = 0,
        /// Captured at construction so the rescan reuses the SAME id sets.
        required_ids: [Components.len]ComponentId = undefined,
        with_ids: [WCOUNT]ComponentId = undefined,
        without_ids: [WOCOUNT]ComponentId = undefined,

        /// The no-allocation seed `World.query` / `queryFiltered` then populates.
        pub fn empty() Self {
            return .{};
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.matches.deinit(gpa);
            self.* = undefined;
        }

        /// Re-apply the filter set to the archetypes gained since the last scan.
        /// Called from every iteration entry — callers never invoke it. No-op when
        /// `archetype_view` is null.
        pub fn maybeRescan(self: *Self) void {
            const view = self.archetype_view orelse return;
            // On OOM this PANICS: losing a match silently would corrupt the
            // `chunkCount`/`chunkAt` index contract for the rest of the dispatch.
            const Appender = struct {
                fn onMatch(s: *Self, arch: *Archetype) void {
                    var indices: [Components.len]u32 = undefined;
                    for (s.required_ids, 0..) |cid, i| {
                        indices[i] = @intCast(arch.componentIndex(cid).?);
                    }
                    s.matches.append(s.rescan_gpa, .{
                        .archetype = arch,
                        .column_indices = indices,
                    }) catch @panic("Query.maybeRescan: out of memory appending new match");
                }
            };
            // One matcher, one rescan body, two callers — the dynamic path reuses it.
            _ = rescanNewArchetypes(
                view,
                &self.last_seen_archetype_count,
                &self.required_ids,
                &self.with_ids,
                &self.without_ids,
                self,
                Appender.onMatch,
            );
        }

        /// For tests; the dispatch protocol cares about `chunkCount`. Rescans first.
        pub fn matchCount(self: *Self) usize {
            self.maybeRescan();
            return self.matches.items.len;
        }

        /// Defines the `[0, chunkCount)` index range `chunkAt` resolves. Rescans first.
        pub fn chunkCount(self: *Self) usize {
            self.maybeRescan();
            var total: usize = 0;
            for (self.matches.items) |m| total += m.archetype.chunks.items.len;
            return total;
        }

        /// Resolve `i` to a `*Chunk`, in archetype-creation then chunk order.
        ///
        /// Does NOT rescan: the caller owes one `chunkCount` first, which stabilises
        /// the index space for the whole dispatch. Rescanning here cost ~10 µs over
        /// 640 chunks on the S1 bench.
        pub fn chunkAt(self: *const Self, i: usize) *Chunk {
            var idx = i;
            for (self.matches.items) |m| {
                const n = m.archetype.chunks.items.len;
                if (idx < n) return m.archetype.chunks.items[idx];
                idx -= n;
            }
            @panic("chunkAt index out of range");
        }

        /// `null` when the chunk belongs to no matched archetype of this query.
        pub fn matchFor(self: *const Self, chunk: *Chunk) ?*const Match {
            const arch_id = chunk.header().archetype_id;
            for (self.matches.items) |*m| {
                if (m.archetype.archetype_id == arch_id) return m;
            }
            return null;
        }

        /// Byte offset of `Components[i]`'s column in the archetype owning `chunk`.
        ///
        /// The lookup is a LINEAR scan of `matches`. A single-archetype caller
        /// resolves it once at construction and stashes it; a multi-archetype caller
        /// must call it per chunk, the offset varying between matched archetypes.
        ///
        /// PANICS on a chunk outside every match — `forEachChunk` and `chunkAt` only
        /// ever hand out chunks from matched archetypes.
        pub fn componentOffsetFor(self: *const Self, chunk: *Chunk, comptime i: usize) u16 {
            const m = self.matchFor(chunk) orelse @panic("componentOffsetFor on a non-match chunk");
            return m.archetype.layout.component_offsets[m.column_indices[i]];
        }

        /// Typed slice over the LIVE entities of `chunk` — length is `entity_count`.
        pub fn componentColumn(self: *const Self, chunk: *Chunk, comptime i: usize) []Components[i] {
            const off = self.componentOffsetFor(chunk, i);
            const count = chunk.header().entity_count;
            const ptr: [*]Components[i] = @ptrCast(@alignCast(&chunk.bytes[off]));
            return ptr[0..count];
        }

        /// `componentColumn(...).ptr` without the length, for a body already holding it.
        pub fn componentArray(self: *const Self, chunk: *Chunk, comptime i: usize) [*]Components[i] {
            const off = self.componentOffsetFor(chunk, i);
            return @ptrCast(@alignCast(&chunk.bytes[off]));
        }

        /// Evaluate the per-slot filters; `true` when none disqualifies the slot.
        /// THE CALLER guarantees `archetype` owns `chunk`, typically via `matchFor`.
        pub fn slotPasses(self: *const Self, archetype: *const Archetype, chunk: *Chunk, slot: u32) bool {
            if (Self.predicate_fn) |f| {
                if (!f(archetype, chunk, slot)) return false;
            }
            if (Self.changed_component_indices.len > 0) {
                // The match recovers the archetype column for each `Changed<T>`.
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

        /// Run `Body(*Chunk, ...args)` once per chunk on the CALLING thread; rescans
        /// first. The predicate is not applied — bodies call `slotPasses` themselves.
        pub fn forEachChunk(self: *Self, comptime Body: anytype, args: anytype) void {
            self.maybeRescan();
            for (self.matches.items) |m| {
                for (m.archetype.chunks.items) |chunk| {
                    @call(.auto, Body, .{chunk} ++ args);
                }
            }
        }

        /// Run `Body` on the chunk at global index `idx`. The caller owes one
        /// `chunkCount` first, which stabilises the index space for the dispatch.
        pub fn runChunkAt(self: *Self, idx: usize, comptime Body: anytype, args: anytype) void {
            // A real dispatch entry, hence the bound. `forEachChunk` is a double loop
            // on the calling thread and carries no such hazard.
            command_buffer_mod.refuseCommandBufferInArgs(@TypeOf(args));
            const chunk = self.chunkAt(idx);
            @call(.auto, Body, .{chunk} ++ args);
        }
    };
}

/// `true` if `arch` satisfies the id sets. STRUCTURAL only — the predicate runs at
/// iteration time, inside `slotPasses`.
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

/// THE single lazy-rescan body, driving both the comptime and the dynamic query:
/// walks the archetypes gained since `last_seen.*`, skips singletons, and calls
/// `onMatch` per new match. Returns the count scanned, 0 in the steady state.
pub fn rescanNewArchetypes(
    view: ArchetypeView,
    last_seen: *usize,
    required_ids: []const ComponentId,
    with_ids: []const ComponentId,
    without_ids: []const ComponentId,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), *Archetype) void,
) usize {
    const all = view.archetypes_slice(view.ctx);
    if (all.len == last_seen.*) return 0;
    // Tail only: existing matches stay valid, archetype pointers being stable.
    const tail = all[last_seen.*..];
    for (tail) |arch| {
        // Singleton-entity resources are INVISIBLE to user queries.
        if (arch.is_singleton) continue;
        if (!archetypeMatches(arch, required_ids, with_ids, without_ids)) continue;
        onMatch(ctx, arch);
    }
    const scanned = tail.len;
    last_seen.* = all.len;
    return scanned;
}

/// Runtime, `ComponentId`-keyed query: the Etch interpreter has resolved ids and no
/// Zig types, so it cannot use the comptime `Query`. ONE conjunctive term; a rule's
/// `when` lowers to a DNF and the caller unions the terms' lists.
///
/// `matching` is in archetype-creation order — which is ascending `archetype_id` —
/// so the interpreter can k-way-merge several terms without sorting.
pub const DynamicQuery = struct {
    /// Owned copy of the "must contain" component ids.
    with_ids: []ComponentId,
    /// Owned copy of the "must not contain" component ids.
    without_ids: []ComponentId,
    /// Matched archetypes, ascending by `archetype_id`. The option-β cache.
    matching: std.ArrayListUnmanaged(*Archetype) = .empty,
    /// `null` only for a default-constructed query never wired by the world.
    archetype_view: ?ArchetypeView = null,
    /// Captured so `maybeRescan` needs no gpa threaded through every entry.
    rescan_gpa: std.mem.Allocator = undefined,
    /// Compared against `world.archetypes.items.len` on every `maybeRescan`.
    last_seen_archetype_count: usize = 0,

    pub fn deinit(self: *DynamicQuery, gpa: std.mem.Allocator) void {
        gpa.free(self.with_ids);
        gpa.free(self.without_ids);
        self.matching.deinit(gpa);
        self.* = undefined;
    }

    /// Returns the count scanned, which the interpreter surfaces per rule. The
    /// required-id set is EMPTY here: a term's components all live in `with_ids`.
    pub fn maybeRescan(self: *DynamicQuery) usize {
        const view = self.archetype_view orelse return 0;
        const Appender = struct {
            fn onMatch(s: *DynamicQuery, arch: *Archetype) void {
                s.matching.append(s.rescan_gpa, arch) catch
                    @panic("DynamicQuery.maybeRescan: out of memory appending new match");
            }
        };
        return rescanNewArchetypes(
            view,
            &self.last_seen_archetype_count,
            &.{},
            self.with_ids,
            self.without_ids,
            self,
            Appender.onMatch,
        );
    }
};
