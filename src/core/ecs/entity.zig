//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! Generational entity identity for the Tier 0 ECS.
//!
//! `EntityId` packs a u32 slot index and a u32 generation tag into a 64-bit
//! handle (low half = index, high half = generation, fixed by `packed
//! struct(u64)`). The slot index addresses the world's per-slot table; the
//! generation tag detects use-after-free of stale handles after the slot
//! has been despawned and reused.
//!
//! The 64-bit layout is stable: Etch bit-casts it to `u64` and chunks stride
//! `entity_ids[]` by 8. Changing it means bumping every chunk capacity
//! reference.
//!
//! `EntityIdentityStore` owns the slot table and free list. BOTH spawn paths
//! allocate through this one store, so a generation is unique world-wide
//! whatever storage the entity ends up in.

const std = @import("std");

/// Generational entity handle. Always 8 bytes, with `(index, generation)`
/// laid out low-to-high — `@bitCast(u64, eid) == (generation << 32) | index`.
/// The default value (index=0, generation=0) is the first entity allocated
/// from a fresh store; callers that need a "no entity" sentinel should use
/// `dead` rather than relying on default-zero.
pub const EntityId = packed struct(u64) {
    index: u32,
    generation: u32,

    /// Bit pattern reserved for "no entity". Never produced by `allocate` —
    /// reaching it would take 4 G live slots.
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

/// One row of the slot table.
const EntitySlot = struct {
    /// Starts at 0; `release` increments it so every outstanding handle to the
    /// previous occupant fails `validate`.
    generation: u32,
    /// `true` while the slot points at a live entity.
    alive: bool,
};

/// Owns the per-slot generation table and the free-index stack, one per world.
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

    /// Reserve a fresh `EntityId`, recycling a free-list slot when one exists.
    ///
    /// Maintains `free_indices.capacity >= slots.len` at all times, which is
    /// what makes `release` an infallible `appendAssumeCapacity`. The fresh path
    /// must reserve with `ensureTotalCapacity(slots.len + 1)`, BEFORE growing
    /// `slots`: the free list is empty there, so `ensureUnusedCapacity(1)` would
    /// only ever guarantee `capacity >= 1` and freeze at that.
    ///
    /// Reserve-then-mutate — an `OutOfMemory` from either allocation leaves no
    /// observable mutation and returns no handle.
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

    /// `error.StaleEntityHandle` for an index past the slot table, a freed
    /// slot, or a generation mismatch.
    pub fn validate(self: *const EntityIdentityStore, id: EntityId) WorldError!void {
        if (id.index >= self.slots.items.len) return error.StaleEntityHandle;
        const slot = self.slots.items[id.index];
        if (!slot.alive or slot.generation != id.generation) {
            return error.StaleEntityHandle;
        }
    }

    /// Non-erroring counterpart to `validate`.
    pub fn isLive(self: *const EntityIdentityStore, id: EntityId) bool {
        if (id.index >= self.slots.items.len) return false;
        const slot = self.slots.items[id.index];
        return slot.alive and slot.generation == id.generation;
    }

    /// Free `id`'s slot, bump its generation, push the index for recycling.
    /// Caller must have validated `id`; liveness is still asserted in debug.
    ///
    /// Takes no allocator and returns no error, by construction: `allocate`
    /// already reserved the free-list slot this push reuses. Generation
    /// arithmetic wraps, at risk only after 4 G releases of the same slot.
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
    std.debug.assert(@sizeOf(EntityId) == 8);
    std.debug.assert(@alignOf(EntityId) == @alignOf(u64));
}

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

    try std.testing.expectError(
        error.StaleEntityHandle,
        store.validate(.{ .index = 42, .generation = 0 }),
    );

    const a = try store.allocate(gpa);
    store.release(a);

    try std.testing.expectError(error.StaleEntityHandle, store.validate(a));

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
    // N must stay large: a reservation that froze `free_indices.capacity` low
    // overflows `release`'s `appendAssumeCapacity` only past a few dozen slots.
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const N: u32 = 1000;
    const ids = try gpa.alloc(EntityId, N);
    defer gpa.free(ids);

    var i: u32 = 0;
    while (i < N) : (i += 1) ids[i] = try store.allocate(gpa);
    try std.testing.expectEqual(@as(usize, N), store.liveCount());

    try std.testing.expect(store.free_indices.capacity >= store.slots.items.len);

    // `release` takes no allocator, so "release under a failing allocator" is
    // satisfied structurally and needs no leg of its own.
    i = 0;
    while (i < N) : (i += 1) store.release(ids[i]);
    try std.testing.expectEqual(@as(usize, 0), store.liveCount());
}

test "allocate is reserve-then-mutate: OOM on a fresh slot leaves no observable mutation" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    // Fill to capacity so the next fresh allocate must grow: without this it
    // amortizes on spare capacity and there is no OOM to observe.
    const a = try store.allocate(gpa);
    while (store.slots.items.len < store.slots.capacity) {
        _ = try store.allocate(gpa);
    }
    const slots_before = store.slots.items.len;
    const live_before = store.liveCount();

    // Request 0 is the free-list reservation, made before `slots` is touched —
    // failing it is what exercises the reserve-then-mutate ordering.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, store.allocate(failing.allocator()));

    try std.testing.expectEqual(slots_before, store.slots.items.len);
    try std.testing.expectEqual(live_before, store.liveCount());
    try store.validate(a);

    _ = try store.allocate(gpa);
    try std.testing.expectEqual(live_before + 1, store.liveCount());
}
