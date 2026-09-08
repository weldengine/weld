//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! `EntityId` is 8 bytes, index low and generation high, and the layout is STABLE:
//! Etch bit-casts it to a `u64` and the chunk `entity_ids[]` stride depends on it,
//! so a change here forces every chunk capacity reference with it.

const std = @import("std");

/// Generational handle, `(index, generation)` low-to-high.
/// The default (0, 0) is the FIRST allocated entity, never a sentinel — see `dead`.
pub const EntityId = packed struct(u64) {
    index: u32,
    generation: u32,

    /// Reserved "no entity"; `allocate` cannot produce it without 4 G live slots.
    pub const dead = EntityId{
        .index = std.math.maxInt(u32),
        .generation = std.math.maxInt(u32),
    };
};

/// Raised by every API that consumes or returns an identity through the store.
pub const WorldError = error{
    StaleEntityHandle,
    OutOfMemory,
};

/// Private on purpose — consumers go through `EntityIdentityStore`'s verbs.
const EntitySlot = struct {
    /// `release` increments it, which is what fails a stale handle's `validate`.
    generation: u32,
    /// `false` between `release` and the `allocate` that pulls the slot back.
    alive: bool,
};

/// One store per world, driven by BOTH spawn paths, so a generation is unique.
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

    /// Reserve a fresh `EntityId`, recycling a freed slot when one is available.
    ///
    /// ESTABLISHES `free_indices.capacity >= slots.len`, the only reason `release`
    /// can be infallible. On the fresh path that means `ensureTotalCapacity(slots.len
    /// + 1)`: `ensureUnusedCapacity(1)` guarantees only `capacity >= 1` and freezes
    /// there. Either `OutOfMemory` leaves no observable mutation.
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

    /// `StaleEntityHandle` for an index past the table, a freed slot, or a mismatch.
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

    /// Free `id`'s slot and bump its generation. The caller validates first; debug
    /// asserts liveness. Infallible and allocation-free BECAUSE `allocate` reserved
    /// this push. The generation WRAPS at `u32` and nothing retires a spent slot.
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
    // Every consumer that bit-casts an `EntityId` to a `u64` assumes this.
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

    // Index past the end of the slot table.
    try std.testing.expectError(
        error.StaleEntityHandle,
        store.validate(.{ .index = 42, .generation = 0 }),
    );

    const a = try store.allocate(gpa);
    store.release(a);

    // Freed slot, original handle is stale.
    try std.testing.expectError(error.StaleEntityHandle, store.validate(a));

    // The original handle stays stale even though the slot is alive again.
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
    // N is deliberately 1000: the buggy `ensureUnusedCapacity(gpa, 1)` froze
    // `free_indices.capacity` far below `slots.len` and overflowed at release #33.
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    const N: u32 = 1000;
    const ids = try gpa.alloc(EntityId, N);
    defer gpa.free(ids);

    var i: u32 = 0;
    while (i < N) : (i += 1) ids[i] = try store.allocate(gpa);
    try std.testing.expectEqual(@as(usize, N), store.liveCount());

    // The free list can ALREADY hold every slot, so `release` never grows it.
    try std.testing.expect(store.free_indices.capacity >= store.slots.items.len);

    // `release` consults no allocator, so "release under a failing allocator" holds.
    i = 0;
    while (i < N) : (i += 1) store.release(ids[i]);
    try std.testing.expectEqual(@as(usize, 0), store.liveCount());
}

test "allocate is reserve-then-mutate: OOM on a fresh slot leaves no observable mutation" {
    const gpa = std.testing.allocator;
    var store = EntityIdentityStore.init();
    defer store.deinit(gpa);

    // Fill the table exactly to capacity, or `allocate` amortizes on spare capacity
    // and never reaches the allocator — there would be no OOM to observe.
    const a = try store.allocate(gpa);
    while (store.slots.items.len < store.slots.capacity) {
        _ = try store.allocate(gpa);
    }
    const slots_before = store.slots.items.len;
    const live_before = store.liveCount();

    // Failing the FIRST request hits the free-list reservation, which is made before
    // `slots` is touched — the reserve-then-mutate ordering under test.
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
