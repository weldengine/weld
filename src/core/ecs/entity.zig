//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Generational entity identity for the Tier 0 ECS.
//!
//! `EntityId` packs a u32 slot index and a u32 generation tag into a 64-bit
//! handle (low half = index, high half = generation, fixed by `packed
//! struct(u64)`). The slot index addresses the world's per-slot table; the
//! generation tag detects use-after-free of stale handles after the slot
//! has been despawned and reused.
//!
//! The 64-bit layout is stable — Etch's `Value.entity_id` stores it as a
//! raw u64 via `@bitCast`, and the chunk `entity_ids[]` array remains a
//! `[*]EntityId` with the same 8-byte stride S1 committed to (cf.
//! `chunk.zig`'s capacity test). Changing the layout requires bumping
//! every chunk capacity reference.
//!
//! `EntityIdentityStore` owns the slot table + free-list. Both world spawn
//! paths — the S1 comptime archetype (`world.spawn`) and the S4 dynamic
//! archetypes (`world.spawnDynamic`) — allocate identity through this
//! single store so the generation counter is unique across the world
//! regardless of which storage path the entity lives in.

const std = @import("std");

/// Generational entity handle. Always 8 bytes, with `(index, generation)`
/// laid out low-to-high — `@bitCast(u64, eid) == (generation << 32) | index`.
/// The default value (index=0, generation=0) is the first entity allocated
/// from a fresh store; callers that need a "no entity" sentinel should use
/// `dead` rather than relying on default-zero.
pub const EntityId = packed struct(u64) {
    index: u32,
    generation: u32,

    /// Bit pattern reserved for "no entity". Never produced by
    /// `EntityIdentityStore.allocate` — `index = maxInt(u32)` would require
    /// 4 G slots already allocated, well past any milestone target.
    pub const dead = EntityId{
        .index = std.math.maxInt(u32),
        .generation = std.math.maxInt(u32),
    };
};

/// Surfaced by `World.despawn`, `World.spawn`, `World.spawnDynamic`, and any
/// other API that consumes or returns an identity through the store.
pub const WorldError = error{
    StaleEntityHandle,
    OutOfMemory,
};

/// One row of the slot table. Small (5 bytes once packed in
/// `ArrayList(EntitySlot)`) so a 1 M-entity world's table stays well under
/// the L2 cache budget. Kept private to this module so consumers go through
/// `EntityIdentityStore`'s public verbs.
const EntitySlot = struct {
    /// Current generation of the slot. Brand-new slots start at 0;
    /// `release` increments this so any outstanding handle to the previous
    /// occupant fails `validate`.
    generation: u32,
    /// `true` while the slot points at a live entity. Toggled to `false`
    /// in `release` and back to `true` in `allocate` when the slot is
    /// pulled off the free list.
    alive: bool,
};

/// Owns the per-slot generation table and the free-index stack. One
/// store per world; both spawn paths drive the same store so a generation
/// bump on despawn invalidates any outstanding handle regardless of which
/// storage path it indexed.
pub const EntityIdentityStore = struct {
    slots: std.ArrayListUnmanaged(EntitySlot) = .empty,
    free_indices: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init() EntityIdentityStore {
        return .{};
    }

    pub fn deinit(self: *EntityIdentityStore, gpa: std.mem.Allocator) void {
        self.slots.deinit(gpa);
        self.free_indices.deinit(gpa);
        self.* = undefined;
    }

    /// Reserve a fresh `EntityId`. Recycles a slot from the free list when
    /// one is available (returning the bumped generation captured by the
    /// previous `release`), otherwise appends a new slot with generation 0.
    ///
    /// Establishes the C1 invariant *`free_indices.capacity >= slots.len` at
    /// all times*, which is what lets `release` be an infallible
    /// `appendAssumeCapacity`: the recycled path frees a free-list slot the
    /// re-push reuses (`pop` drops `len` under an unchanged capacity), and the
    /// fresh path reserves free-list capacity for the new slot **before**
    /// growing `slots`. On the fresh path `free_indices.items.len == 0`, so
    /// `ensureTotalCapacity(slots.len + 1)` makes `capacity >= slots.len + 1`
    /// (`ensureUnusedCapacity(1)` would only guarantee `capacity >= 1` and
    /// freeze there — see brief B1).
    ///
    /// Reserve-then-mutate: an `OutOfMemory` from the free-list reservation
    /// leaves `slots` untouched and returns no handle; an `OutOfMemory` from
    /// the subsequent `slots.append` leaves harmless spare free-list capacity
    /// and adds no slot. Either way there is no observable mutation.
    ///
    /// Errors: `OutOfMemory` if either the free list or the slot table needs
    /// to grow and the allocator refuses.
    pub fn allocate(self: *EntityIdentityStore, gpa: std.mem.Allocator) WorldError!EntityId {
        if (self.free_indices.pop()) |idx| {
            const slot = &self.slots.items[idx];
            std.debug.assert(!slot.alive);
            slot.alive = true;
            return .{ .index = idx, .generation = slot.generation };
        }
        const idx: u32 = @intCast(self.slots.items.len);
        try self.free_indices.ensureTotalCapacity(gpa, self.slots.items.len + 1);
        try self.slots.append(gpa, .{ .generation = 0, .alive = true });
        return .{ .index = idx, .generation = 0 };
    }

    /// Confirm that `id` still refers to a live slot with a matching
    /// generation. Returns `error.StaleEntityHandle` for indices past the
    /// slot table, for freed slots, and for generation mismatches.
    pub fn validate(self: *const EntityIdentityStore, id: EntityId) WorldError!void {
        if (id.index >= self.slots.items.len) return error.StaleEntityHandle;
        const slot = self.slots.items[id.index];
        if (!slot.alive or slot.generation != id.generation) {
            return error.StaleEntityHandle;
        }
    }

    /// `true` if `id` refers to a live entity in this store. Non-erroring
    /// counterpart to `validate` for paths that just need a boolean.
    pub fn isLive(self: *const EntityIdentityStore, id: EntityId) bool {
        if (id.index >= self.slots.items.len) return false;
        const slot = self.slots.items[id.index];
        return slot.alive and slot.generation == id.generation;
    }

    /// Mark `id`'s slot as freed, bump its generation, and push the index
    /// onto the free list for recycling. Caller must have validated `id`
    /// prior; this still asserts liveness in debug.
    ///
    /// Infallible and allocation-free by construction: `allocate` already
    /// reserved the free-list slot this push reuses (C1 invariant
    /// `free_indices.capacity >= slots.len`), so this is a bare
    /// `appendAssumeCapacity` — no allocator parameter, no error. See
    /// `allocate` for the reservation that backs it.
    ///
    /// Generation arithmetic uses wrapping increment — the u32 counter is
    /// only at risk after 4 G releases of the same slot, which is well
    /// past the Phase 0 horizon. A future-phase milestone can introduce a
    /// guard that retires the slot once `generation == maxInt(u32) - 1`.
    pub fn release(self: *EntityIdentityStore, id: EntityId) void {
        std.debug.assert(id.index < self.slots.items.len);
        const slot = &self.slots.items[id.index];
        std.debug.assert(slot.alive);
        std.debug.assert(slot.generation == id.generation);
        slot.alive = false;
        slot.generation +%= 1;
        self.free_indices.appendAssumeCapacity(id.index);
    }

    /// Number of currently live entities — `total slots - freed slots`.
    pub fn liveCount(self: *const EntityIdentityStore) usize {
        return self.slots.items.len - self.free_indices.items.len;
    }
};

comptime {
    // Lock the wire-format identity layout. Chunks, the IPC catalogue, and
    // every consumer that bit-casts an `EntityId` to/from u64 assumes
    // 8-byte alignment and size.
    std.debug.assert(@sizeOf(EntityId) == 8);
    std.debug.assert(@alignOf(EntityId) == @alignOf(u64));
}

// ─── tests ────────────────────────────────────────────────────────────────

test "EntityId is exactly 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EntityId));
}

test "EntityId bit layout matches (generation << 32) | index" {
    const eid = EntityId{ .index = 7, .generation = 3 };
    const bits: u64 = @bitCast(eid);
    try std.testing.expectEqual(@as(u64, (@as(u64, 3) << 32) | 7), bits);
}

test "EntityId.dead bitcasts to maxInt(u64)" {
    const bits: u64 = @bitCast(EntityId.dead);
    try std.testing.expectEqual(std.math.maxInt(u64), bits);
}

test "first allocate returns generation 0 at index 0" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const id = try store.allocate(gpa);
    try std.testing.expectEqual(@as(u32, 0), id.index);
    try std.testing.expectEqual(@as(u32, 0), id.generation);
    try std.testing.expectEqual(@as(usize, 1), store.liveCount());
}

test "allocate / release / allocate recycles the slot with a bumped generation" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const a = try store.allocate(gpa);
    store.release(a);
    try std.testing.expectEqual(@as(usize, 0), store.liveCount());

    const b = try store.allocate(gpa);
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(b.generation > a.generation);
    try store.validate(b);
}

test "validate rejects out-of-range index, freed slot, and stale generation" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    // Index past the end of the slot table.
    try std.testing.expectError(
        error.StaleEntityHandle,
        store.validate(.{ .index = 42, .generation = 0 }),
    );

    const a = try store.allocate(gpa);
    store.release(a);

    // Freed slot, original handle is stale.
    try std.testing.expectError(error.StaleEntityHandle, store.validate(a));

    // Same slot recycled — the original handle stays stale even though the
    // slot is alive again.
    const b = try store.allocate(gpa);
    try std.testing.expect(a.index == b.index);
    try std.testing.expectError(error.StaleEntityHandle, store.validate(a));
    try store.validate(b);
}

test "free list is LIFO — last released slot is reused first" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const a = try store.allocate(gpa);
    const b = try store.allocate(gpa);
    const c = try store.allocate(gpa);

    store.release(a);
    store.release(c);

    const d = try store.allocate(gpa);
    try std.testing.expectEqual(c.index, d.index);
    const e = try store.allocate(gpa);
    try std.testing.expectEqual(a.index, e.index);

    // `b` is still live, so the slot table didn't grow further.
    try std.testing.expectEqual(@as(usize, 3), store.slots.items.len);
    try std.testing.expectEqual(@as(usize, 3), store.liveCount());
    _ = b;
}

test "100k allocate then release back to zero live count" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const N: u32 = 100_000;
    const ids = try gpa.alloc(EntityId, N);
    defer gpa.free(ids);
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        ids[i] = try store.allocate(gpa);
    }
    try std.testing.expectEqual(@as(usize, N), store.liveCount());

    i = 0;
    while (i < N) : (i += 1) {
        store.release(ids[i]);
    }
    try std.testing.expectEqual(@as(usize, 0), store.liveCount());
}

test "allocate reserves release capacity; release is allocation-free" {
    // C1 acceptance test. N is deliberately large (1000) so the buggy
    // `ensureUnusedCapacity(gpa, 1)` fresh-path reservation (brief B1) would
    // freeze `free_indices.capacity` far below `slots.len` and overflow the
    // infallible `appendAssumeCapacity` in `release` (repro: overflow at
    // release #33). The corrected `ensureTotalCapacity(gpa, slots.len + 1)`
    // keeps `free_indices.capacity >= slots.len`, so every release fits.
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const N: u32 = 1000;
    const ids = try gpa.alloc(EntityId, N);
    defer gpa.free(ids);

    var i: u32 = 0;
    while (i < N) : (i += 1) ids[i] = try store.allocate(gpa);
    try std.testing.expectEqual(@as(usize, N), store.liveCount());

    // The invariant `allocate` establishes: the free list can already hold
    // every slot, so `release` never needs to grow it.
    try std.testing.expect(store.free_indices.capacity >= store.slots.items.len);

    // Release all N. `release` takes no allocator and is a bare
    // `appendAssumeCapacity` — allocation-free by construction. No allocator
    // can be consulted here, so "release with the allocator set to fail every
    // request" is satisfied structurally.
    i = 0;
    while (i < N) : (i += 1) store.release(ids[i]);
    try std.testing.expectEqual(@as(usize, 0), store.liveCount());
}

test "allocate is reserve-then-mutate: OOM on a fresh slot leaves no observable mutation" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    // Fill the slot table exactly to capacity so the NEXT fresh allocate is
    // forced to grow (and can therefore OOM). Without this, `allocate`
    // amortizes on the spare capacity from an earlier geometric growth and
    // never touches the allocator, so there would be no OOM to observe.
    const a = try store.allocate(gpa);
    while (store.slots.items.len < store.slots.capacity) {
        _ = try store.allocate(gpa);
    }
    const slots_before = store.slots.items.len;
    const live_before = store.liveCount();

    // The free list is empty (every slot is live), so the next allocate takes
    // the fresh path. Its first allocation is the free-list reservation, made
    // *before* `slots` is touched; `slots.append` then must grow too. Failing
    // the first allocation request exercises the reserve-then-mutate ordering.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, store.allocate(failing.allocator()));

    // Reserve-then-mutate: no new slot, live count unchanged, prior handle intact.
    try std.testing.expectEqual(slots_before, store.slots.items.len);
    try std.testing.expectEqual(live_before, store.liveCount());
    try store.validate(a);

    // The store is still usable with a working allocator afterwards.
    _ = try store.allocate(gpa);
    try std.testing.expectEqual(live_before + 1, store.liveCount());
}
