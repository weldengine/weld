//! Byte-level archetype storage, shared by both spawn paths. The chunk layout comes
//! from the registered component sizes and alignments; typed access is layered on
//! by `query.zig`.
//!
//! `component_ids` is sorted STRICTLY ASCENDING, and two archetypes with the same
//! sorted list ARE the same archetype — the `ComponentSignature` below is the key
//! the world deduplicates on.
//!
//! `sizes[i]` / `aligns[i]` must stay equal to the registry's answer for
//! `component_ids[i]`; they are cached only so the hot paths skip the registry.
//!
//! `chunks` grows MONOTONICALLY: `removeSwap` is an in-chunk swap-and-pop and never
//! frees the trailing empty chunk.

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

/// Re-export of `chunk.ChunkSize` — 16 KiB locked per S1.
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

/// Where an entity is: archetype, chunk inside it, slot inside that chunk.
/// `archetype_idx` is named for the field the Etch bridge already consumes, and is
/// the same value as the archetype's stable `archetype_id`.
pub const Location = struct {
    archetype_idx: ArchetypeId,
    chunk_idx: u32,
    slot: u32,
};

/// Neighbouring archetypes reached by adding or removing ONE component, cached
/// after the first miss so a repeat add/remove skips the global lookup.
pub const TransitionCache = struct {
    add: std.AutoHashMapUnmanaged(ComponentId, ArchetypeId) = .empty,
    remove: std.AutoHashMapUnmanaged(ComponentId, ArchetypeId) = .empty,

    pub fn deinit(self: *TransitionCache, gpa: std.mem.Allocator) void {
        self.add.deinit(gpa);
        self.remove.deinit(gpa);
        self.* = undefined;
    }
};

/// The sorted id slice that identifies an archetype; the world keys its map on the
/// BYTE representation of it, via `signatureBytes`.
pub const ComponentSignature = struct {
    ids: []const ComponentId,

    /// Linear because a signature is a handful of components.
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

/// Owns the chunks of a fixed component set. The registry pointer is BORROWED for
/// the archetype's lifetime, so `spawnDefault` recovers default bytes without a
/// re-lookup.
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
    transitions: TransitionCache = .{},
    /// `Query.maybeRescan` SKIPS a singleton archetype, so user queries never see
    /// resource entities.
    is_singleton: bool = false,

    /// `component_ids` must already be sorted ascending.
    pub fn init(
        gpa: std.mem.Allocator,
        registry: *const Registry,
        archetype_id: ArchetypeId,
        component_ids: []const ComponentId,
    ) ArchetypeError!Archetype {
        // An EMPTY component list is LEGAL: an entity whose whole set is sparse
        // still has an archetype, because an entity always has one.

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

    /// Reserve a slot without writing any component data — THE CALLER fills the
    /// columns and the entity-id slot before anything iterates. Both tick sidecars
    /// are stamped `tick` and the dirty bit is set.
    pub fn allocateSlot(self: *Archetype, gpa: std.mem.Allocator, tick: Tick) ArchetypeError!SpawnResult {
        const chunk = blk: {
            if (self.chunks.items.len > 0) {
                const last = self.chunks.items[self.chunks.items.len - 1];
                if (last.header().entity_count < self.layout.capacity) break :blk last;
            }
            break :blk try self.allocChunk(gpa);
        };
        const hdr = chunk.header();
        const slot = hdr.entity_count;
        hdr.entity_count = slot + 1;

        // Stamp every component's sidecars at the new slot.
        for (self.component_ids, 0..) |_, i| {
            const added = chunk.addedTickColumn(&self.layout, i);
            const changed = chunk.changedTickColumn(&self.layout, i);
            added[slot] = tick;
            changed[slot] = tick;
        }
        // Dirty from birth, so a first-frame `Changed<T>` sees it before any write.
        change_detection.setDirty(chunk.dirtyBitset(&self.layout), slot);

        return .{
            .chunk_idx = @intCast(self.chunks.items.len - 1),
            .slot = slot,
        };
    }

    /// Append an entity from the registry's DEFAULT bytes, stamping both sidecars
    /// with `tick` — which callers propagate from `World.current_tick`.
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

    /// `bytes_per_component[i]` must be EXACTLY `sizes[i]` long and correspond to
    /// `component_ids[i]`; the caller orders the slices via `componentIndex`.
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

    /// Swap-and-pop. Returns the entity RELOCATED into the freed slot, or `null` when
    /// the freed slot was already the trailing one — THE CALLER updates that entity's
    /// location. Both sidecars travel with the entity and the dirty bit at `slot`
    /// inherits the trailing slot's.
    pub fn removeSwap(self: *Archetype, chunk_idx: u32, slot: u32) ?EntityId {
        const chunk = self.chunks.items[chunk_idx];
        const hdr = chunk.header();
        std.debug.assert(slot < hdr.entity_count);
        const last = hdr.entity_count - 1;
        if (slot == last) {
            hdr.entity_count = last;
            return null;
        }
        // Copy each component column's `last` byte slot into `slot`,
        // plus the matching `added_tick` / `changed_tick` entries.
        for (self.component_ids, 0..) |_, i| {
            const dst = self.componentSlot(chunk, i, slot);
            const src = self.componentSlot(chunk, i, last);
            @memcpy(dst, src);

            const added = chunk.addedTickColumn(&self.layout, i);
            added[slot] = added[last];
            const changed = chunk.changedTickColumn(&self.layout, i);
            changed[slot] = changed[last];
        }
        // Carried, so a `Changed<T>` about to inspect the trailing slot still
        // sees the relocated entity as dirty.
        const bitset = chunk.dirtyBitset(&self.layout);
        if (change_detection.isDirty(bitset, last)) {
            change_detection.setDirty(bitset, slot);
        } else {
            // Clear the destination bit so we don't carry stale state.
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

    /// Lets a `Changed<T>` query skip a whole chunk before inspecting any slot.
    pub fn isChunkClean(self: *const Archetype, chunk: *const Chunk) bool {
        return change_detection.isAllZero(chunk.dirtyBitsetConst(&self.layout));
    }

    /// Called by `World.beginFrame`, which is what bounds the bit to one frame.
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
    // `u32` and not `u8` because the `FieldKind` whitelist excludes `u8`; the test
    // only needs two distinct sizes and alignments.
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

    // The component column moved with the entity id.
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

    // Initially empty.
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
