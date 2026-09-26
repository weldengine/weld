//! Generalised byte-level archetype storage.
//!
//! One byte-level `Archetype` shared by both spawn paths. Its chunk layout is
//! computed from the component sizes and alignments registered with the world;
//! comptime-typed access is layered on top by `query.zig`, and transitions
//! between archetypes go through the per-archetype `TransitionCache`.
//!
//! Locked invariants:
//!
//! - `component_ids` is sorted strictly ascending. Two archetypes with
//!   the same sorted list of ids are the same archetype — the
//!   `ComponentSignature` view exposed below is the lookup key the
//!   `World` uses to deduplicate archetype creation.
//! - `sizes[i]` / `aligns[i]` always match the registry's
//!   `componentSize(component_ids[i])` / `componentAlignment(...)`.
//!   They are cached locally so the hot paths (append, removeSwap,
//!   componentSlot) do not need to bounce through the registry.
//! - `removeSwap` performs an IN-CHUNK swap-and-pop; a chunk it empties is
//!   freed by `releaseChunkIfEmpty`, which the OWNER calls because reclaiming
//!   a chunk can RENUMBER one other chunk and only the world holds the
//!   locations that name it.
//! - A chunk index is valid only between two structural mutations of its
//!   archetype: `removeSwap` moves a row under any live iterator, and a
//!   reclamation moves a whole chunk's index.
//! - The `TransitionCache` lifetime is tied to the owning archetype —
//!   the cached `ArchetypeId` values are indices into the world's
//!   archetype list, so they stay valid as long as the world does
//!   (archetype pointers are stable per `engine-ecs-internals.md` §3).

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const registry_mod = @import("registry.zig");
const entity_mod = @import("entity.zig");
const tick_mod = @import("tick.zig");
const change_detection = @import("change_detection.zig");

const ComponentId = registry_mod.ComponentId;
const Registry = registry_mod.Registry;
const EntityId = entity_mod.EntityId;
const Tick = tick_mod.Tick;

/// Re-export of `chunk.ChunkSize` — 16 KiB, locked.
pub const ChunkSize = chunk_mod.ChunkSize;
/// Re-export of `chunk.ChunkAlignment` — 16 bytes for SIMD.
pub const ChunkAlignment = chunk_mod.ChunkAlignment;
/// Re-export of `chunk.ChunkHeader` — the small in-chunk header layout.
pub const ChunkHeader = chunk_mod.ChunkHeader;
/// Re-export of `chunk.ChunkLayout` — per-archetype byte-offset map.
pub const ChunkLayout = chunk_mod.ChunkLayout;
/// Re-export of `chunk.Chunk` — the raw 16 KiB byte buffer.
pub const Chunk = chunk_mod.Chunk;
/// Re-export of `chunk.ArchetypeError` — shared error set across the
/// archetype + chunk layout code paths.
pub const ArchetypeError = chunk_mod.ArchetypeError;

/// Index of an archetype inside the world's archetype list. Stable for
/// the lifetime of the world (archetypes never relocate). Stored inside
/// `Location` so any entity handle can be resolved in O(1).
pub const ArchetypeId = u32;

/// Position of an entity in the world: which archetype, which chunk inside it,
/// which slot inside that chunk. The world's one location type, populated by
/// `entity_locations`.
///
/// `archetype_idx` is named for the older `DynamicLocation` field the Etch
/// interpreter and bridge consume; it holds the archetype's stable
/// `archetype_id`, an index into `World.archetypes`.
pub const Location = struct {
    archetype_idx: ArchetypeId,
    chunk_idx: u32,
    slot: u32,
};

/// Per-archetype cache of the neighbouring archetypes reached by adding
/// or removing a single component. The first transition lookup misses
/// and the world creates / finds the target archetype, then caches the
/// id here so subsequent add/remove of the same component on this
/// archetype skips the global lookup.
pub const TransitionCache = struct {
    add: std.AutoHashMapUnmanaged(ComponentId, ArchetypeId) = .empty,
    remove: std.AutoHashMapUnmanaged(ComponentId, ArchetypeId) = .empty,

    pub fn deinit(self: *TransitionCache, gpa: std.mem.Allocator) void {
        self.add.deinit(gpa);
        self.remove.deinit(gpa);
        self.* = undefined;
    }
};

/// Sorted slice of component ids that uniquely identifies an archetype.
/// The world's `archetype_by_signature` map keys on the byte
/// representation of this slice (via `signatureBytes`).
pub const ComponentSignature = struct {
    ids: []const ComponentId,

    /// `true` iff `cid` belongs to this signature. Linear because the
    /// signatures are short (a handful of components per archetype).
    pub fn contains(self: ComponentSignature, cid: ComponentId) bool {
        for (self.ids) |id| if (id == cid) return true;
        return false;
    }
};

/// Return the raw bytes underlying a `ComponentSignature.ids` slice. The
/// `World`'s archetype lookup map keys on these bytes — `AutoHashMap`
/// hashes them directly, avoiding a `ComponentSignature` context.
pub fn signatureBytes(ids: []const ComponentId) []const u8 {
    return std.mem.sliceAsBytes(ids);
}

/// Sort `ids` in place ascending. Required before passing to
/// `Archetype.init` — the archetype assumes sorted input so its
/// per-component arrays match the comptime order of consumers.
pub fn sortComponentIds(ids: []ComponentId) void {
    std.mem.sort(ComponentId, ids, {}, comptime std.sort.asc(ComponentId));
}

/// Stable slot location returned by the spawn paths so the world can
/// record it in `entity_locations`.
pub const SpawnResult = struct {
    chunk_idx: u32,
    slot: u32,
};

/// Byte-level archetype owning a list of chunks for a fixed component
/// set. Built from a sorted slice of `ComponentId` resolved against a
/// `Registry`; the registry pointer is borrowed for the archetype's
/// lifetime so `spawnDefault` can recover the per-component default
/// bytes without a re-lookup.
pub const Archetype = struct {
    archetype_id: ArchetypeId,
    /// Sorted ascending so the per-archetype id list itself is the
    /// canonical signature key.
    component_ids: []ComponentId,
    /// Cached sizes / alignments — see "Locked invariants" in the
    /// module doc.
    sizes: []u16,
    aligns: []u16,
    /// Borrowed reference to the world's registry. Not owned; the
    /// world outlives every archetype and the registry pointer stays
    /// valid for the archetype's lifetime.
    registry: *const Registry,
    layout: ChunkLayout,
    chunks: std.ArrayListUnmanaged(*Chunk) = .empty,
    /// Every chunk below this index is full, and it never exceeds
    /// `chunks.items.len`: a lower bound, not necessarily the first non-full
    /// chunk. Lowering it is always safe; advance it only past chunks seen full.
    first_partial: u32 = 0,
    transitions: TransitionCache = .{},
    /// `true` iff this archetype hosts a singleton-entity
    /// resource. Set by `resources.setResource` after spawning the
    /// resource's entity. Read at ITERATION time by `Query.maybeRescan` (the
    /// tail rescan) and by `ComptimeQuery.next`, both of which skip the
    /// archetype.
    ///
    /// It is NOT read by the initial scan `World.queryFiltered` performs when a
    /// typed `Query` is CONSTRUCTED, so a resource already flagged at that
    /// moment enters that query's match list. The exclusion is therefore weaker
    /// than this flag's name suggests, and a reader must not take it for an
    /// invariant over every query.
    is_singleton: bool = false,
    /// Chunks freed by `releaseChunkIfEmpty`. STATS-ONLY: a length that never
    /// rose proves nothing, so asserting on `chunks.items.len` alone cannot tell
    /// a release from an allocation that never happened.
    chunks_released: u64 = 0,

    /// Initialise the archetype with the given sorted component list.
    ///
    /// An EMPTY list is legal and yields the archetype of an entity whose whole
    /// set is sparse — an entity ALWAYS has an archetype. Making it optional
    /// would create a second entity lifecycle that despawn, the observers, the
    /// three spawn paths and `dynamicLocation` would each have to tell apart.
    pub fn init(
        gpa: std.mem.Allocator,
        registry: *const Registry,
        archetype_id: ArchetypeId,
        component_ids: []const ComponentId,
    ) ArchetypeError!Archetype {
        const ids = try gpa.dupe(ComponentId, component_ids);
        errdefer gpa.free(ids);
        std.mem.sort(ComponentId, ids, {}, comptime std.sort.asc(ComponentId));

        const sizes = try gpa.alloc(u16, ids.len);
        errdefer gpa.free(sizes);
        const aligns = try gpa.alloc(u16, ids.len);
        errdefer gpa.free(aligns);
        for (ids, 0..) |id, i| {
            sizes[i] = registry.componentSize(id);
            aligns[i] = registry.componentAlignment(id);
        }

        const layout = try chunk_mod.computeLayout(gpa, sizes, aligns);
        errdefer gpa.free(layout.component_offsets);

        return .{
            .archetype_id = archetype_id,
            .component_ids = ids,
            .sizes = sizes,
            .aligns = aligns,
            .registry = registry,
            .layout = layout,
        };
    }

    pub fn deinit(self: *Archetype, gpa: std.mem.Allocator) void {
        for (self.chunks.items) |c| gpa.destroy(c);
        self.chunks.deinit(gpa);
        gpa.free(self.component_ids);
        gpa.free(self.sizes);
        gpa.free(self.aligns);
        gpa.free(self.layout.component_offsets);
        gpa.free(self.layout.added_tick_offsets);
        gpa.free(self.layout.changed_tick_offsets);
        self.transitions.deinit(gpa);
        self.* = undefined;
    }

    pub fn capacity(self: *const Archetype) u32 {
        return self.layout.capacity;
    }

    pub fn chunkCount(self: *const Archetype) usize {
        return self.chunks.items.len;
    }

    pub fn entityCount(self: *const Archetype) usize {
        var total: usize = 0;
        for (self.chunks.items) |c| total += c.headerConst().entity_count;
        return total;
    }

    pub fn signature(self: *const Archetype) ComponentSignature {
        return .{ .ids = self.component_ids };
    }

    /// Index of `component_id` inside this archetype's sorted list, or
    /// `null` if absent. Linear scan — signatures are short.
    pub fn componentIndex(self: *const Archetype, component_id: ComponentId) ?usize {
        for (self.component_ids, 0..) |id, i| if (id == component_id) return i;
        return null;
    }

    pub fn hasComponent(self: *const Archetype, component_id: ComponentId) bool {
        return self.componentIndex(component_id) != null;
    }

    /// Reserve a slot at the tail of the first chunk with room, which need not
    /// be the trailing chunk (allocating a new chunk when every chunk is full),
    /// without writing any component data. The
    /// caller is responsible for filling the slot's component columns
    /// and the entity-id slot before any iteration touches them. The
    /// per-component `added_tick[col][slot]` and `changed_tick[col][slot]`
    /// sidecars are initialised to `tick`, and the slot's dirty bit is
    /// set — the entity is "fresh" for the current frame.
    pub fn allocateSlot(self: *Archetype, gpa: std.mem.Allocator, tick: Tick) ArchetypeError!SpawnResult {
        var idx = self.first_partial;
        while (idx < self.chunks.items.len and
            self.chunks.items[idx].header().entity_count >= self.layout.capacity) : (idx += 1)
        {}
        self.first_partial = idx;

        const chunk = if (idx < self.chunks.items.len)
            self.chunks.items[idx]
        else
            try self.allocChunk(gpa);
        const chunk_idx: u32 = @intCast(idx);
        const hdr = chunk.header();
        const slot = hdr.entity_count;
        hdr.entity_count = slot + 1;

        for (self.component_ids, 0..) |_, i| {
            const added = chunk.addedTickColumn(&self.layout, i);
            const changed = chunk.changedTickColumn(&self.layout, i);
            added[slot] = tick;
            changed[slot] = tick;
        }
        change_detection.setDirty(chunk.dirtyBitset(&self.layout), slot);

        return .{
            .chunk_idx = chunk_idx,
            .slot = slot,
        };
    }

    /// Append a fresh entity initialised from the registry's default bytes for
    /// every component. `tick` stamps both sidecars and callers propagate it
    /// from `World.current_tick`.
    pub fn spawnDefault(
        self: *Archetype,
        gpa: std.mem.Allocator,
        entity_id: EntityId,
        tick: Tick,
    ) ArchetypeError!SpawnResult {
        const r = try self.allocateSlot(gpa, tick);
        const chunk = self.chunks.items[r.chunk_idx];

        for (self.component_ids, 0..) |id, i| {
            const dst = self.componentSlot(chunk, i, r.slot);
            @memcpy(dst, self.registry.componentDefaultBytes(id));
        }
        self.entityIds(chunk)[r.slot] = entity_id;
        return r;
    }

    /// Append a fresh entity initialised from caller-provided byte
    /// slices. `bytes_per_component[i]` must be exactly `sizes[i]` bytes
    /// long and corresponds to `component_ids[i]` (caller orders the
    /// slices using `componentIndex`). The `tick` parameter stamps the
    /// per-component sidecars.
    pub fn appendRowFromBytes(
        self: *Archetype,
        gpa: std.mem.Allocator,
        entity_id: EntityId,
        bytes_per_component: []const []const u8,
        tick: Tick,
    ) ArchetypeError!SpawnResult {
        std.debug.assert(bytes_per_component.len == self.component_ids.len);
        const r = try self.allocateSlot(gpa, tick);
        const chunk = self.chunks.items[r.chunk_idx];

        for (self.component_ids, 0..) |_, i| {
            const dst = self.componentSlot(chunk, i, r.slot);
            std.debug.assert(bytes_per_component[i].len == self.sizes[i]);
            @memcpy(dst, bytes_per_component[i]);
        }
        self.entityIds(chunk)[r.slot] = entity_id;
        return r;
    }

    /// Swap-and-pop the entity at `(chunk_idx, slot)`. Returns the
    /// `EntityId` of the trailing entity that moved into the freed slot,
    /// or `null` when the freed slot was already the trailing slot of
    /// its chunk. Caller updates the swapped entity's location entry
    /// against `(self.archetype_id, chunk_idx, slot)`. The per-component
    /// `added_tick` / `changed_tick` sidecars travel with the entity,
    /// and the dirty bit at `slot` inherits the trailing slot's bit so
    /// the change-detection semantics survive the swap.
    pub fn removeSwap(self: *Archetype, chunk_idx: u32, slot: u32) ?EntityId {
        const chunk = self.chunks.items[chunk_idx];
        const hdr = chunk.header();
        std.debug.assert(slot < hdr.entity_count);
        self.first_partial = @min(self.first_partial, chunk_idx);
        const last = hdr.entity_count - 1;
        if (slot == last) {
            hdr.entity_count = last;
            return null;
        }
        for (self.component_ids, 0..) |_, i| {
            const dst = self.componentSlot(chunk, i, slot);
            const src = self.componentSlot(chunk, i, last);
            @memcpy(dst, src);

            const added = chunk.addedTickColumn(&self.layout, i);
            added[slot] = added[last];
            const changed = chunk.changedTickColumn(&self.layout, i);
            changed[slot] = changed[last];
        }
        const bitset = chunk.dirtyBitset(&self.layout);
        if (change_detection.isDirty(bitset, last)) {
            change_detection.setDirty(bitset, slot);
        } else {
            const word_idx: usize = @intCast(slot / 64);
            const bit_idx: u6 = @intCast(slot % 64);
            bitset[word_idx] &= ~(@as(u64, 1) << bit_idx);
        }

        const ids = self.entityIds(chunk);
        const moved_id = ids[last];
        ids[slot] = moved_id;
        hdr.entity_count = last;
        return moved_id;
    }

    /// Free the chunk at `chunk_idx` when it holds no entity; answer the index
    /// whose occupants were RENUMBERED by the free, or `null` when none were.
    ///
    /// Reclamation is the OWNER's call, never `removeSwap`'s. Freeing a chunk
    /// that is not the trailing one moves the trailing chunk into its index, and
    /// every entity in THAT chunk then carries a stale `Location.chunk_idx`. The
    /// archetype holds no locations and cannot repair them, so a caller that
    /// ignores the answer leaves entities naming a chunk that moved.
    ///
    /// `null` covers two cases alike to the caller — "not empty" and "the
    /// trailing chunk was freed" — since neither renumbers anything. Only
    /// `chunks_released` tells them apart.
    pub fn releaseChunkIfEmpty(self: *Archetype, gpa: std.mem.Allocator, chunk_idx: u32) ?u32 {
        const chunk = self.chunks.items[chunk_idx];
        if (chunk.header().entity_count != 0) return null;

        const last_idx: u32 = @intCast(self.chunks.items.len - 1);
        gpa.destroy(chunk);
        self.chunks_released += 1;
        if (chunk_idx == last_idx) {
            _ = self.chunks.pop();
            self.first_partial = @min(self.first_partial, @as(u32, @intCast(self.chunks.items.len)));
            return null;
        }
        self.chunks.items[chunk_idx] = self.chunks.items[last_idx];
        _ = self.chunks.pop();
        self.first_partial = @min(self.first_partial, chunk_idx);
        return chunk_idx;
    }

    fn allocChunk(self: *Archetype, gpa: std.mem.Allocator) ArchetypeError!*Chunk {
        const chunk = try gpa.create(Chunk);
        errdefer gpa.destroy(chunk);
        chunk.initInPlace(self.archetype_id, self.layout.capacity);
        try self.chunks.append(gpa, chunk);
        return chunk;
    }

    /// Pointer to a single component slot — `sizes[i]` bytes long.
    /// `i` is the index into `component_ids`, not a public ComponentId.
    pub fn componentSlot(self: *const Archetype, chunk: *Chunk, i: usize, slot: u32) []u8 {
        const off = self.layout.component_offsets[i];
        const sz = self.sizes[i];
        return chunk.bytes[off + sz * slot ..][0..sz];
    }

    /// Slice covering the contiguous SoA column for component `i` over
    /// the currently-live slots `[0, entity_count)`.
    pub fn componentBytes(self: *const Archetype, chunk: *Chunk, i: usize) []u8 {
        const off = self.layout.component_offsets[i];
        const sz = self.sizes[i];
        const len = chunk.header().entity_count;
        return chunk.bytes[off..][0 .. sz * len];
    }

    pub fn entityIds(self: *const Archetype, chunk: *Chunk) [*]EntityId {
        return @ptrCast(@alignCast(&chunk.bytes[self.layout.entity_ids_offset]));
    }

    pub fn entityIdsConst(self: *const Archetype, chunk: *const Chunk) [*]const EntityId {
        return @ptrCast(@alignCast(&chunk.bytes[self.layout.entity_ids_offset]));
    }

    /// Mark `(comp_idx, slot)` as modified at `tick`. Writes the
    /// `changed_tick` sidecar and sets the slot's dirty bit so chunk-
    /// granularity skip checks pick it up. `added_tick` is left alone.
    pub fn markChanged(self: *const Archetype, chunk: *Chunk, comp_idx: usize, slot: u32, tick: Tick) void {
        const changed = chunk.changedTickColumn(&self.layout, comp_idx);
        changed[slot] = tick;
        change_detection.setDirty(chunk.dirtyBitset(&self.layout), slot);
    }

    /// Read the `added_tick[comp_idx][slot]` value — the tick at which
    /// the component was first attached to its current owner entity.
    pub fn addedTick(self: *const Archetype, chunk: *const Chunk, comp_idx: usize, slot: u32) Tick {
        const col = chunk.addedTickColumnConst(&self.layout, comp_idx);
        return col[slot];
    }

    /// Read the `changed_tick[comp_idx][slot]` value — the tick of
    /// the most recent write via `World.getMut(T)` (or `markChanged`).
    pub fn changedTick(self: *const Archetype, chunk: *const Chunk, comp_idx: usize, slot: u32) Tick {
        const col = chunk.changedTickColumnConst(&self.layout, comp_idx);
        return col[slot];
    }

    /// `true` iff every slot in `chunk` has a zero dirty bit. Used by
    /// `Changed<T>`-filtered queries to skip an entire chunk before
    /// inspecting any slot.
    pub fn isChunkClean(self: *const Archetype, chunk: *const Chunk) bool {
        return change_detection.isAllZero(chunk.dirtyBitsetConst(&self.layout));
    }

    /// Reset every chunk's dirty bitset to all-zero. Called by
    /// `World.beginFrame` once per frame so the bit only carries
    /// "modified since the start of the current frame" semantics.
    pub fn clearAllDirtyBitsets(self: *Archetype) void {
        for (self.chunks.items) |chunk| {
            change_detection.clearAll(chunk.dirtyBitset(&self.layout));
        }
    }
};

test "Archetype init pins sorted component_ids and registry-driven sizes/aligns" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Health = extern struct { current: f32 = 0, max: f32 = 100 };
    // `u32` and not `u8`: the `FieldKind` registry whitelist has no `u8`. All
    // this needs is two components with distinct sizes and alignments.
    const Tag = extern struct { v: u32 = 0 };

    const id_h = try reg.registerComponent(gpa, Health);
    const id_t = try reg.registerComponent(gpa, Tag);

    // Pass in non-sorted to confirm init sorts.
    var arch = try Archetype.init(gpa, &reg, 0, &[_]ComponentId{ id_t, id_h });
    defer arch.deinit(gpa);

    try std.testing.expect(arch.component_ids[0] < arch.component_ids[1]);
    try std.testing.expectEqual(@as(u16, @sizeOf(Health)), arch.sizes[arch.componentIndex(id_h).?]);
    try std.testing.expectEqual(@as(u16, @sizeOf(Tag)), arch.sizes[arch.componentIndex(id_t).?]);
}

test "removeSwap returns the swapped entity id and leaves the chunk consistent" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Pos = extern struct { x: f32 = 0, y: f32 = 0 };
    const id_p = try reg.registerComponent(gpa, Pos);

    var arch = try Archetype.init(gpa, &reg, 0, &[_]ComponentId{id_p});
    defer arch.deinit(gpa);

    const a_id = EntityId{ .index = 1, .generation = 0 };
    const b_id = EntityId{ .index = 2, .generation = 0 };
    const c_id = EntityId{ .index = 3, .generation = 0 };

    const a_pos: Pos = .{ .x = 1, .y = 0 };
    const b_pos: Pos = .{ .x = 2, .y = 0 };
    const c_pos: Pos = .{ .x = 3, .y = 0 };

    _ = try arch.appendRowFromBytes(gpa, a_id, &.{std.mem.asBytes(&a_pos)}, 0);
    _ = try arch.appendRowFromBytes(gpa, b_id, &.{std.mem.asBytes(&b_pos)}, 0);
    _ = try arch.appendRowFromBytes(gpa, c_id, &.{std.mem.asBytes(&c_pos)}, 0);

    // Remove the middle — `c` migrates into slot 1.
    const swapped = arch.removeSwap(0, 1);
    try std.testing.expectEqual(@as(?EntityId, c_id), swapped);
    try std.testing.expectEqual(@as(usize, 2), arch.entityCount());

    const chunk = arch.chunks.items[0];
    const ids = arch.entityIdsConst(chunk);
    try std.testing.expectEqual(a_id, ids[0]);
    try std.testing.expectEqual(c_id, ids[1]);

    const x_slot1: *const Pos = @ptrCast(@alignCast(arch.componentSlot(chunk, 0, 1).ptr));
    try std.testing.expectEqual(@as(f32, 3), x_slot1.x);

    // Remove the trailing slot — no swap takes place.
    const swapped2 = arch.removeSwap(0, 1);
    try std.testing.expectEqual(@as(?EntityId, null), swapped2);
    try std.testing.expectEqual(@as(usize, 1), arch.entityCount());
}

test "transition cache stores and retrieves add/remove targets" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Pos = extern struct { x: f32 = 0 };
    const id_p = try reg.registerComponent(gpa, Pos);

    var arch = try Archetype.init(gpa, &reg, 0, &[_]ComponentId{id_p});
    defer arch.deinit(gpa);

    try std.testing.expect(arch.transitions.add.get(id_p) == null);

    try arch.transitions.add.put(gpa, id_p, 7);
    try std.testing.expectEqual(@as(?ArchetypeId, 7), arch.transitions.add.get(id_p));

    try arch.transitions.remove.put(gpa, id_p, 9);
    try std.testing.expectEqual(@as(?ArchetypeId, 9), arch.transitions.remove.get(id_p));
}

test "componentSignature contains check matches archetype's component list" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = extern struct { v: f32 = 0 };
    const B = extern struct { v: f32 = 0 };

    const id_a = try reg.registerComponent(gpa, A);
    const id_b = try reg.registerComponent(gpa, B);

    var arch = try Archetype.init(gpa, &reg, 0, &[_]ComponentId{ id_a, id_b });
    defer arch.deinit(gpa);

    const sig = arch.signature();
    try std.testing.expect(sig.contains(id_a));
    try std.testing.expect(sig.contains(id_b));
    try std.testing.expect(!sig.contains(99));
}
