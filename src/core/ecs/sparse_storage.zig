//! Sparse-set component storage — the second backend of `ARCH-005`, opt-in through
//! `@storage(.sparse)`: a dense entity array, a parallel component array, a sparse
//! index keyed by entity INDEX, and the two tick sidecars. Add and remove are O(1)
//! and neither migrates an archetype, which is the whole reason the mode exists.
//!
//! `ChunkAlignment` is imported and not re-declared: two of them would be two bounds.
//!
//! NO BITSET, so NO BLOCK SKIP — nothing here may be written as if a
//! block-granularity skip existed. ZERO-SIZED components allocate no component
//! buffer EVER. And `sparse` is addressed by the entity INDEX, never by the handle:
//! an entry whose generation no longer matches IS absence.

const std = @import("std");
const entity_mod = @import("entity.zig");
const registry_mod = @import("registry.zig");
const chunk_mod = @import("chunk.zig");
const tick_mod = @import("tick.zig");

const EntityId = entity_mod.EntityId;
const ComponentId = registry_mod.ComponentId;
const Tick = tick_mod.Tick;

/// `maxInt(u32)` is unreachable as a dense position — that would take 4 G live rows.
pub const absent: u32 = std.math.maxInt(u32);

/// `add` on an entity already present ASSERTS rather than errors: add-on-present is
/// a REPLACEMENT, decided one layer up by the observer-dispatching apply, and a
/// storage that accepted it silently would hide that decision.
pub const SparseError = error{
    OutOfMemory,
};

/// One component's sparse-set storage.
pub const SparseSetStorage = struct {
    /// The component this storage holds. Carried so a set of storages can be
    /// enumerated in `ComponentId` order without a side table (invariant 4).
    component_id: ComponentId,
    /// Bytes per row, from `Registry.componentSize`. **Zero is a supported
    /// value and its own path** (invariant 5).
    elem_size: u16,
    /// Row alignment, from `Registry.componentAlignment`. Asserted at `init`
    /// against the engine's own bound; see `rows`.
    elem_align: u16,

    /// Live entities, in insertion order with swap-remove holes closed. The
    /// driver of a sparse-driven query iterates THIS.
    dense: std.ArrayListUnmanaged(EntityId) = .empty,
    /// `added_tick` / `changed_tick`, parallel to `dense`, index for index.
    added_ticks: std.ArrayListUnmanaged(Tick) = .empty,
    changed_ticks: std.ArrayListUnmanaged(Tick) = .empty,
    /// Entity INDEX → position in `dense`, or `absent`. NEVER indexed by a handle.
    /// Its size follows the largest INDEX, bounded by the PEAK of concurrently live
    /// entities — and it NEVER SHRINKS back, shrinking on despawn being a thrash
    /// against the very churn this mode serves.
    sparse: std.ArrayListUnmanaged(u32) = .empty,

    /// Component rows, `elem_size` bytes each, parallel to `dense`. A raw
    /// over-aligned buffer and not a byte `ArrayList`, the row alignment being a
    /// RUNTIME value while Zig's aligned list takes a comptime one. Row `i` inherits
    /// `ChunkAlignment` because `@sizeOf(T)` is a multiple of `@alignOf(T)`.
    ///
    /// NULL FOREVER when `elem_size == 0`.
    rows: ?[]align(chunk_mod.ChunkAlignment) u8 = null,
    /// Rows the `rows` buffer can hold. Meaningless when `rows == null`.
    rows_capacity: usize = 0,

    /// The exact field SET, pinned — not the count, which swapping two fields for a
    /// different pair leaves untouched.
    ///
    /// `World.beginFrame` has NO sparse arm, there being no chunk-granular bitset
    /// here to clear. A comment saying so is a claim; this block is the guard, and
    /// breaking it is the moment to re-read the frame boundary.
    const field_set_pin = [_][]const u8{
        "component_id", "elem_size",   "elem_align",
        "dense",        "added_ticks", "changed_ticks",
        "sparse",       "rows",        "rows_capacity",
    };

    comptime {
        const actual = std.meta.fieldNames(SparseSetStorage);
        if (actual.len != field_set_pin.len) @compileError(
            "SparseSetStorage's field set moved — see `field_set_pin` and `World.beginFrame`",
        );
        for (actual, field_set_pin) |a, pinned| {
            if (!std.mem.eql(u8, a, pinned)) @compileError(
                "SparseSetStorage's field set moved at `" ++ a ++
                    "` — see `field_set_pin` and `World.beginFrame`",
            );
        }
    }

    /// Create an empty storage for `component_id`.
    pub fn init(component_id: ComponentId, elem_size: u16, elem_align: u16) SparseSetStorage {
        // Past the bound, the `i * elem_size` row arithmetic would mis-align rows
        // SILENTLY. The same contract the table backend applies to every column.
        std.debug.assert(elem_align <= chunk_mod.ChunkAlignment);
        // `@sizeOf` is a multiple of `@alignOf`, so a size that is not cannot come
        // from a real component and would break the row arithmetic.
        std.debug.assert(elem_align == 0 or elem_size % elem_align == 0);
        return .{ .component_id = component_id, .elem_size = elem_size, .elem_align = elem_align };
    }

    pub fn deinit(self: *SparseSetStorage, gpa: std.mem.Allocator) void {
        self.dense.deinit(gpa);
        self.added_ticks.deinit(gpa);
        self.changed_ticks.deinit(gpa);
        self.sparse.deinit(gpa);
        if (self.rows) |buf| gpa.free(buf);
        self.* = undefined;
    }

    /// Number of live entries.
    pub fn len(self: *const SparseSetStorage) usize {
        return self.dense.items.len;
    }

    /// The iteration order of a sparse-driven query: DETERMINISTIC and NOT invariant,
    /// a swap-remove reordering it, which `ARCH-005` puts out of contract.
    pub fn entities(self: *const SparseSetStorage) []const EntityId {
        return self.dense.items;
    }

    /// THE GENERATION CHECK LIVES HERE AND NOWHERE ELSE: the full handle in `dense`
    /// is what separates THIS entity from a previous occupant of the same index.
    pub fn positionOf(self: *const SparseSetStorage, entity: EntityId) ?u32 {
        if (entity.index >= self.sparse.items.len) return null;
        const pos = self.sparse.items[entity.index];
        if (pos == absent) return null;
        // A recycled index whose generation moved on reads as absence.
        if (self.dense.items[pos].generation != entity.generation) return null;
        return pos;
    }

    /// Whether `entity` carries this component. The O(1) membership test a
    /// mixed query uses on its non-driver members.
    pub fn contains(self: *const SparseSetStorage, entity: EntityId) bool {
        return self.positionOf(entity) != null;
    }

    /// An EMPTY SLICE for a zero-sized component — the correct answer, deriving no
    /// pointer from an unallocated buffer.
    pub fn get(self: *const SparseSetStorage, entity: EntityId) ?[]const u8 {
        const pos = self.positionOf(entity) orelse return null;
        return self.rowConst(pos);
    }

    /// Mirrors `World.getMut`'s auto-mark: every write through the returned slice is
    /// observable by a change filter.
    pub fn getMut(self: *SparseSetStorage, entity: EntityId, tick: Tick) ?[]u8 {
        const pos = self.positionOf(entity) orelse return null;
        self.changed_ticks.items[pos] = tick;
        return self.row(pos);
    }

    /// Mutable bytes WITHOUT the change stamp: `World.componentBytes` reads through
    /// here to build the observers' old/new payloads, and stamping would make every
    /// dispatch register as a mutation of the component it reports on.
    pub fn bytesMut(self: *SparseSetStorage, entity: EntityId) ?[]u8 {
        const pos = self.positionOf(entity) orelse return null;
        return self.row(pos);
    }

    /// Stamp `entity`'s row as changed at `tick`. No-op when absent, mirroring
    /// `World.markComponentChangedDyn`.
    pub fn markChanged(self: *SparseSetStorage, entity: EntityId, tick: Tick) void {
        const pos = self.positionOf(entity) orelse return;
        self.changed_ticks.items[pos] = tick;
    }

    pub fn addedTick(self: *const SparseSetStorage, entity: EntityId) ?Tick {
        const pos = self.positionOf(entity) orelse return null;
        return self.added_ticks.items[pos];
    }

    pub fn changedTick(self: *const SparseSetStorage, entity: EntityId) ?Tick {
        const pos = self.positionOf(entity) orelse return null;
        return self.changed_ticks.items[pos];
    }

    /// Insert `entity` with `bytes` as its row, stamping both sidecars at `tick`.
    /// `bytes.len` must equal `elem_size`; an empty slice is correct for a tag.
    ///
    /// RESERVE-THEN-MUTATE: every fallible step precedes the first observable
    /// mutation, so a failure leaves no `sparse[index]` on an uninitialised row.
    /// An entity already present ASSERTS — that decision belongs to the apply path.
    pub fn add(
        self: *SparseSetStorage,
        gpa: std.mem.Allocator,
        entity: EntityId,
        bytes: []const u8,
        tick: Tick,
    ) SparseError!void {
        std.debug.assert(bytes.len == self.elem_size);
        std.debug.assert(!self.contains(entity));

        const pos: u32 = @intCast(self.dense.items.len);

        // ── Fallible phase. Nothing below this comment is observable yet.
        const needed_sparse = @as(usize, entity.index) + 1;
        if (needed_sparse > self.sparse.items.len) {
            try self.sparse.ensureTotalCapacity(gpa, needed_sparse);
        }
        try self.dense.ensureUnusedCapacity(gpa, 1);
        try self.added_ticks.ensureUnusedCapacity(gpa, 1);
        try self.changed_ticks.ensureUnusedCapacity(gpa, 1);
        // Reserved BEFORE the dense append, so a failure cannot leave a dense
        // entry without a row.
        if (self.elem_size != 0 and pos + 1 > self.rows_capacity) {
            const want = @max(@as(usize, 8), (pos + 1) * 2);
            const fresh = try gpa.alignedAlloc(u8, comptime .fromByteUnits(chunk_mod.ChunkAlignment), want * self.elem_size);
            if (self.rows) |old| {
                @memcpy(fresh[0 .. pos * self.elem_size], old[0 .. pos * self.elem_size]);
                gpa.free(old);
            }
            self.rows = fresh;
            self.rows_capacity = want;
        }

        // ── Infallible commit. Every append below is assume-capacity.
        while (self.sparse.items.len < needed_sparse) self.sparse.appendAssumeCapacity(absent);
        self.dense.appendAssumeCapacity(entity);
        self.added_ticks.appendAssumeCapacity(tick);
        self.changed_ticks.appendAssumeCapacity(tick);
        if (self.elem_size != 0) @memcpy(self.row(pos), bytes);
        self.sparse.items[entity.index] = pos;
    }

    /// Remove `entity`'s entry, returning the entity RELOCATED into the freed
    /// position, or null when nothing moved. Returned only because
    /// `Archetype.removeSwap` returns it and two divergent swap-removes would be one
    /// more thing to remember.
    ///
    /// The trailing row's bytes AND both sidecars travel, so a change filter sees a
    /// relocated entity exactly as un-relocated. No dirty bit to carry.
    pub fn remove(self: *SparseSetStorage, entity: EntityId) ?EntityId {
        const pos = self.positionOf(entity) orelse return null;
        const last: u32 = @intCast(self.dense.items.len - 1);

        self.sparse.items[entity.index] = absent;

        if (pos == last) {
            _ = self.dense.pop();
            _ = self.added_ticks.pop();
            _ = self.changed_ticks.pop();
            return null;
        }

        const moved = self.dense.items[last];
        self.dense.items[pos] = moved;
        self.added_ticks.items[pos] = self.added_ticks.items[last];
        self.changed_ticks.items[pos] = self.changed_ticks.items[last];
        if (self.elem_size != 0) @memcpy(self.row(pos), self.rowConst(last));

        _ = self.dense.pop();
        _ = self.added_ticks.pop();
        _ = self.changed_ticks.pop();
        self.sparse.items[moved.index] = pos;
        return moved;
    }

    /// Empty, and derived from no pointer, for a zero-sized component.
    fn row(self: *SparseSetStorage, pos: u32) []u8 {
        if (self.elem_size == 0) return &.{};
        const off = @as(usize, pos) * self.elem_size;
        return self.rows.?[off..][0..self.elem_size];
    }

    fn rowConst(self: *const SparseSetStorage, pos: u32) []const u8 {
        if (self.elem_size == 0) return &.{};
        const off = @as(usize, pos) * self.elem_size;
        return self.rows.?[off..][0..self.elem_size];
    }
};

/// The set of sparse storages a world owns, keyed by `ComponentId`.
///
/// A dense array and NOT a hash map, ids being small sequential integers. Ascending
/// index IS ascending `ComponentId`, which makes the despawn order structural.
pub const SparseStores = struct {
    /// `slots[cid]` is the storage for `cid`, or null when `cid` is a table
    /// component or is not registered.
    slots: std.ArrayListUnmanaged(?SparseSetStorage) = .empty,

    pub fn deinit(self: *SparseStores, gpa: std.mem.Allocator) void {
        for (self.slots.items) |*maybe| {
            if (maybe.*) |*store| store.deinit(gpa);
        }
        self.slots.deinit(gpa);
        self.* = undefined;
    }

    /// IDEMPOTENT: a second call keeps the existing storage, so a hot-reload
    /// re-compile does not discard live rows.
    pub fn ensure(
        self: *SparseStores,
        gpa: std.mem.Allocator,
        component_id: ComponentId,
        elem_size: u16,
        elem_align: u16,
    ) SparseError!*SparseSetStorage {
        const needed = @as(usize, component_id) + 1;
        if (needed > self.slots.items.len) {
            try self.slots.ensureTotalCapacity(gpa, needed);
            while (self.slots.items.len < needed) self.slots.appendAssumeCapacity(null);
        }
        if (self.slots.items[component_id] == null) {
            self.slots.items[component_id] = SparseSetStorage.init(component_id, elem_size, elem_align);
        }
        return &self.slots.items[component_id].?;
    }

    /// The storage for `component_id`, or null when it is not a sparse
    /// component.
    pub fn get(self: *SparseStores, component_id: ComponentId) ?*SparseSetStorage {
        if (component_id >= self.slots.items.len) return null;
        if (self.slots.items[component_id]) |*store| return store;
        return null;
    }

    pub fn getConst(self: *const SparseStores, component_id: ComponentId) ?*const SparseSetStorage {
        if (component_id >= self.slots.items.len) return null;
        if (self.slots.items[component_id]) |*store| return store;
        return null;
    }

    /// The smallest `ComponentId` at or above `from` holding `entity`. ASCENDING BY
    /// CONSTRUCTION, which is what lets despawn merge both backends by two pointers.
    pub fn nextContaining(self: *const SparseStores, from: ComponentId, entity: EntityId) ?ComponentId {
        var cid: usize = from;
        while (cid < self.slots.items.len) : (cid += 1) {
            if (self.slots.items[cid]) |*store| {
                if (store.contains(entity)) return @intCast(cid);
            }
        }
        return null;
    }

    /// Whether `component_id` is stored sparse.
    pub fn isSparse(self: *const SparseStores, component_id: ComponentId) bool {
        return self.getConst(component_id) != null;
    }

    /// In ASCENDING `ComponentId`, a property of the container and not of a sort, so
    /// it cannot be lost by a comparator.
    pub fn forEachOf(
        self: *const SparseStores,
        entity: EntityId,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), ComponentId) void,
    ) void {
        for (self.slots.items, 0..) |maybe, cid| {
            const store = if (maybe) |*s| s else continue;
            if (store.contains(entity)) cb(ctx, @intCast(cid));
        }
    }

    /// Removing an entity from its archetype does NOT remove its sparse components.
    /// Returns the count, so a caller can assert the sweep actually swept.
    pub fn removeEntity(self: *SparseStores, entity: EntityId) usize {
        var dropped: usize = 0;
        for (self.slots.items) |*maybe| {
            const store = if (maybe.*) |*s| s else continue;
            // Taken BEFORE the removal: `remove` returns the RELOCATED handle, null
            // both when nothing moved and when the entity was absent.
            if (!store.contains(entity)) continue;
            _ = store.remove(entity);
            dropped += 1;
        }
        return dropped;
    }
};

// Every counter-factual changes the OBJECT rather than the expected constant, and an
// invariant that is an ABSENCE is paired with a positive witness.

const testing = std.testing;

/// A component small enough to read at a glance and large enough that a row
/// copy is observable: two distinct bytes per entity.
const Pair = extern struct { a: u8, b: u8 };

fn pairBytes(p: *const Pair) []const u8 {
    return std.mem.asBytes(p);
}

fn e(index: u32, generation: u32) EntityId {
    return .{ .index = index, .generation = generation };
}

/// Fails exactly ONE allocation, then behaves normally.
/// `std.testing.FailingAllocator` does not advance its index on failure, so a
/// recovery assertion under it cannot tell the property from exhaustion.
const OneShotFail = struct {
    backing: std.mem.Allocator,
    /// Counted over `alloc` ONLY. `resize` and `remap` are deliberately excluded: an
    /// `ArrayList` past capacity first asks to extend in place, and a refusal there
    /// is a ROUTINE MISS it recovers from — no OOM is induced at all.
    fail_at: ?usize,
    attempts: usize = 0,

    fn allocator(self: *OneShotFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn shouldFail(self: *OneShotFail) bool {
        const at = self.fail_at orelse {
            self.attempts += 1;
            return false;
        };
        const now = self.attempts;
        self.attempts += 1;
        return now == at;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = vtAlloc,
        .resize = vtResize,
        .remap = vtRemap,
        .free = vtFree,
    };

    fn vtAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    // `resize` and `remap` pass straight through: a refusal from either is
    // recoverable by the caller, so failing one induces no OOM. See `fail_at`.
    fn vtResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn vtRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn vtFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "invariant 1: swap-remove moves the trailing row AND both tick sidecars" {
    const gpa = testing.allocator;
    var s = SparseSetStorage.init(7, @sizeOf(Pair), @alignOf(Pair));
    defer s.deinit(gpa);

    // Three entries, each with DISTINCT bytes and DISTINCT ticks, so a sidecar
    // that failed to travel is visible rather than coincidentally right.
    const p0 = Pair{ .a = 10, .b = 11 };
    const p1 = Pair{ .a = 20, .b = 21 };
    const p2 = Pair{ .a = 30, .b = 31 };
    try s.add(gpa, e(0, 0), pairBytes(&p0), 100);
    try s.add(gpa, e(1, 0), pairBytes(&p1), 200);
    try s.add(gpa, e(2, 0), pairBytes(&p2), 300);

    // Distinct change ticks too, and distinct from the added ones, so the two
    // sidecars cannot be confused for each other.
    s.markChanged(e(0, 0), 1000);
    s.markChanged(e(1, 0), 2000);
    s.markChanged(e(2, 0), 3000);

    // A NON-LAST entry: removing the last relocates nothing, which would prove the
    // early-out and say nothing about parity.
    const relocated = s.remove(e(1, 0));
    try testing.expectEqual(@as(?EntityId, e(2, 0)), relocated);
    try testing.expectEqual(@as(usize, 2), s.len());

    // The relocated entity is seen EXACTLY as it would have been un-relocated:
    // its bytes, its added tick and its changed tick all travelled.
    const got = s.get(e(2, 0)).?;
    try testing.expectEqual(@as(u8, 30), got[0]);
    try testing.expectEqual(@as(u8, 31), got[1]);
    try testing.expectEqual(@as(?Tick, 300), s.addedTick(e(2, 0)));
    try testing.expectEqual(@as(?Tick, 3000), s.changedTick(e(2, 0)));

    // The untouched entry is untouched, which is what makes the above a
    // relocation rather than a wholesale rewrite.
    try testing.expectEqual(@as(?Tick, 100), s.addedTick(e(0, 0)));
    try testing.expectEqual(@as(?Tick, 1000), s.changedTick(e(0, 0)));
    try testing.expect(!s.contains(e(1, 0)));
}

test "invariant 1, counter-factual: removing the LAST entry relocates nothing" {
    // The discriminating half: a reported relocation here would mean the test above
    // passes on a path that always copies.
    const gpa = testing.allocator;
    var s = SparseSetStorage.init(7, @sizeOf(Pair), @alignOf(Pair));
    defer s.deinit(gpa);
    const p = Pair{ .a = 1, .b = 2 };
    try s.add(gpa, e(0, 0), pairBytes(&p), 1);
    try s.add(gpa, e(1, 0), pairBytes(&p), 2);
    try testing.expectEqual(@as(?EntityId, null), s.remove(e(1, 0)));
    try testing.expectEqual(@as(usize, 1), s.len());
    try testing.expect(s.contains(e(0, 0)));
}

test "invariant 2: there is no bitset and no block-skip entry, and per-entry works" {
    // The ABSENCE, checked structurally at comptime so it cannot rot: the table
    // backend's block-granularity vocabulary must not exist here.
    comptime {
        for (@typeInfo(SparseSetStorage).@"struct".fields) |f| {
            if (std.mem.indexOf(u8, f.name, "bitset") != null) {
                @compileError("sparse storage must carry no dirty bitset (invariant 2): " ++ f.name);
            }
        }
        std.debug.assert(!@hasDecl(SparseSetStorage, "isChunkClean"));
        std.debug.assert(!@hasDecl(SparseSetStorage, "dirtyBitset"));
        std.debug.assert(!@hasDecl(SparseSetStorage, "clearAllDirtyBitsets"));
    }

    // THE POSITIVE WITNESS, without which the absence above is satisfied by an
    // apparatus that does nothing.
    const gpa = testing.allocator;
    var s = SparseSetStorage.init(3, 0, 0);
    defer s.deinit(gpa);
    var i: u32 = 0;
    while (i < 6) : (i += 1) try s.add(gpa, e(i, 0), &.{}, 5);
    s.markChanged(e(1, 0), 9);
    s.markChanged(e(4, 0), 9);

    var changed: usize = 0;
    var scanned: usize = 0;
    for (s.entities()) |ent| {
        scanned += 1;
        if (s.changedTick(ent).? > 5) changed += 1;
    }
    // The scan's EXTENT is asserted as well as its result: a loop whose visit
    // count is unchecked can cover less in silence.
    try testing.expectEqual(@as(usize, 6), scanned);
    try testing.expectEqual(@as(usize, 2), changed);
}

test "invariant 3: the union sweep drops every sparse entry of an entity" {
    const gpa = testing.allocator;
    var stores = SparseStores{};
    defer stores.deinit(gpa);

    const p = Pair{ .a = 4, .b = 5 };
    _ = try stores.ensure(gpa, 2, @sizeOf(Pair), @alignOf(Pair));
    _ = try stores.ensure(gpa, 5, 0, 0);
    _ = try stores.ensure(gpa, 9, @sizeOf(Pair), @alignOf(Pair));

    const victim = e(3, 0);
    const bystander = e(4, 0);
    try stores.get(2).?.add(gpa, victim, pairBytes(&p), 1);
    try stores.get(5).?.add(gpa, victim, &.{}, 1);
    try stores.get(9).?.add(gpa, victim, pairBytes(&p), 1);
    try stores.get(2).?.add(gpa, bystander, pairBytes(&p), 1);

    // The sweep reports its extent, so it cannot cover less in silence.
    try testing.expectEqual(@as(usize, 3), stores.removeEntity(victim));

    // No sparse index entry designates the dead entity, in any storage.
    for ([_]ComponentId{ 2, 5, 9 }) |cid| {
        try testing.expect(!stores.get(cid).?.contains(victim));
        try testing.expectEqual(@as(?u32, null), stores.get(cid).?.positionOf(victim));
    }
    // And the sweep was a sweep, not a purge: the bystander survives.
    try testing.expect(stores.get(2).?.contains(bystander));
}

test "invariant 3 + 6: a recycled index with a new generation inherits nothing" {
    const gpa = testing.allocator;
    var s = SparseSetStorage.init(1, @sizeOf(Pair), @alignOf(Pair));
    defer s.deinit(gpa);

    const old_val = Pair{ .a = 77, .b = 88 };
    try s.add(gpa, e(6, 0), pairBytes(&old_val), 1);
    _ = s.remove(e(6, 0));

    // Same INDEX, next generation — the shape a respawn produces.
    const reborn = e(6, 1);
    try testing.expect(!s.contains(reborn));
    const new_val = Pair{ .a = 1, .b = 2 };
    try s.add(gpa, reborn, pairBytes(&new_val), 2);
    const got = s.get(reborn).?;
    try testing.expectEqual(@as(u8, 1), got[0]);
    try testing.expectEqual(@as(u8, 2), got[1]);
    // And the dead handle stays dead rather than aliasing its successor.
    try testing.expect(!s.contains(e(6, 0)));
}

test "invariant 4: the union enumerates in ascending ComponentId" {
    const gpa = testing.allocator;
    var stores = SparseStores{};
    defer stores.deinit(gpa);

    // DECLARED in descending order: permuting the declaration must not change the
    // firing order.
    _ = try stores.ensure(gpa, 12, 0, 0);
    _ = try stores.ensure(gpa, 4, 0, 0);
    _ = try stores.ensure(gpa, 8, 0, 0);

    const ent = e(2, 0);
    try stores.get(12).?.add(gpa, ent, &.{}, 1);
    try stores.get(4).?.add(gpa, ent, &.{}, 1);
    try stores.get(8).?.add(gpa, ent, &.{}, 1);

    const Sink = struct {
        seen: [8]ComponentId = @splat(0),
        n: usize = 0,
        fn push(self: *@This(), cid: ComponentId) void {
            self.seen[self.n] = cid;
            self.n += 1;
        }
    };
    var sink = Sink{};
    stores.forEachOf(ent, &sink, Sink.push);

    try testing.expectEqual(@as(usize, 3), sink.n);
    try testing.expectEqualSlices(ComponentId, &.{ 4, 8, 12 }, sink.seen[0..3]);
}

test "invariant 5: a zero-sized component allocates no row buffer, ever" {
    const gpa = testing.allocator;
    var tag = SparseSetStorage.init(1, 0, 0);
    defer tag.deinit(gpa);

    var i: u32 = 0;
    while (i < 32) : (i += 1) try tag.add(gpa, e(i, 0), &.{}, 1);
    // The invariant, stated on the field the buffer would live in.
    try testing.expectEqual(@as(?[]align(chunk_mod.ChunkAlignment) u8, null), tag.rows);
    try testing.expectEqual(@as(usize, 0), tag.rows_capacity);
    // The tag still behaves: added, tested, removed.
    try testing.expect(tag.contains(e(17, 0)));
    try testing.expectEqual(@as(usize, 0), tag.get(e(17, 0)).?.len);
    _ = tag.remove(e(17, 0));
    try testing.expect(!tag.contains(e(17, 0)));
    try testing.expectEqual(@as(?[]align(chunk_mod.ChunkAlignment) u8, null), tag.rows);

    // COUNTER-FACTUAL on the object: a sized component on the same path DOES
    // allocate, so the null above discriminates.
    var sized = SparseSetStorage.init(2, @sizeOf(Pair), @alignOf(Pair));
    defer sized.deinit(gpa);
    const p = Pair{ .a = 1, .b = 2 };
    try sized.add(gpa, e(0, 0), pairBytes(&p), 1);
    try testing.expect(sized.rows != null);
    try testing.expect(sized.rows_capacity > 0);
}

test "invariant 6: the sparse index is keyed by INDEX and generation decides" {
    const gpa = testing.allocator;
    var s = SparseSetStorage.init(1, 0, 0);
    defer s.deinit(gpa);

    try s.add(gpa, e(5, 3), &.{}, 1);
    // The entry is reachable by the exact handle…
    try testing.expect(s.contains(e(5, 3)));
    // …and by no other generation of the same index, in either direction.
    try testing.expect(!s.contains(e(5, 2)));
    try testing.expect(!s.contains(e(5, 4)));
    try testing.expectEqual(@as(?u32, null), s.positionOf(e(5, 0)));

    // The keying itself: the sparse slot lives at the INDEX, not at a hash of
    // the handle, so slot 5 is occupied and the array is exactly index+1 long.
    try testing.expectEqual(@as(usize, 6), s.sparse.items.len);
    try testing.expect(s.sparse.items[5] != absent);
    // Slots below the inserted index are absent rather than uninitialised.
    for (s.sparse.items[0..5]) |slot| try testing.expectEqual(absent, slot);
}

test "invariant 7: a failed add rolls back every fallible step, and a retry works" {
    // TWO sweeps, one state being unable to exercise both halves. COLD is the first
    // add of a fresh storage, where every fallible step allocates — a WARM add
    // allocates NOTHING and a sweep over zero attempts passes vacuously. WARM proves
    // the prior state SURVIVES, which a rollback to "empty" would satisfy vacuously.
    const gpa = testing.allocator;
    const p = Pair{ .a = 30, .b = 31 };

    // ── (a) Measure the cold add's attempts rather than assuming a count: a
    //        hardcoded number stops covering silently when the shape changes.
    const cold_allocs = blk: {
        var counter = OneShotFail{ .backing = gpa, .fail_at = null };
        const a = counter.allocator();
        var s = SparseSetStorage.init(1, @sizeOf(Pair), @alignOf(Pair));
        defer s.deinit(a);
        try s.add(a, e(0, 0), pairBytes(&p), 300);
        break :blk counter.attempts;
    };
    try testing.expect(cold_allocs > 0);

    var cold_induced: usize = 0;
    var fail_at: usize = 0;
    while (fail_at < cold_allocs) : (fail_at += 1) {
        var counter = OneShotFail{ .backing = gpa, .fail_at = fail_at };
        const a = counter.allocator();
        var s = SparseSetStorage.init(1, @sizeOf(Pair), @alignOf(Pair));
        defer s.deinit(a);

        const result = s.add(a, e(0, 0), pairBytes(&p), 300);
        counter.fail_at = null; // disarm before asserting

        if (result) |_| {
            // No allocation on this index; the induced count below keeps it honest.
            continue;
        } else |err| {
            cold_induced += 1;
            try testing.expectEqual(SparseError.OutOfMemory, err);

            // Nothing half-written: no entry, and no sparse slot designating
            // an uninitialised dense row.
            try testing.expectEqual(@as(usize, 0), s.len());
            try testing.expect(!s.contains(e(0, 0)));
            for (s.sparse.items) |slot| try testing.expectEqual(absent, slot);

            // THE RECOVERY HALF, and the reason the allocator is one-shot: a corrupt
            // storage would refuse this too, and the test could not tell which.
            try s.add(a, e(0, 0), pairBytes(&p), 300);
            try testing.expectEqual(@as(usize, 1), s.len());
            try testing.expectEqual(@as(u8, 30), s.get(e(0, 0)).?[0]);
            try testing.expectEqual(@as(?Tick, 300), s.addedTick(e(0, 0)));
        }
    }
    // An EQUALITY and not a floor: a `>= 1` would pass with four of five
    // allocations uncovered. Failing low means an uncovered allocation on the add path.
    try testing.expectEqual(cold_allocs, cold_induced);

    // (b) The target index is far out so `sparse` must grow whatever spare capacity
    //     the lists hold — the one fallible step a warm storage still reaches.
    var counter = OneShotFail{ .backing = gpa, .fail_at = null };
    const a = counter.allocator();
    var s = SparseSetStorage.init(1, @sizeOf(Pair), @alignOf(Pair));
    defer s.deinit(a);

    const p0 = Pair{ .a = 10, .b = 11 };
    const p1 = Pair{ .a = 20, .b = 21 };
    try s.add(a, e(0, 0), pairBytes(&p0), 100);
    try s.add(a, e(1, 0), pairBytes(&p1), 200);
    s.markChanged(e(1, 0), 250);

    const far = e(4096, 0);
    counter.attempts = 0;
    counter.fail_at = 0; // the sparse array's fresh block is the first ALLOC it reaches
    const warm = s.add(a, far, pairBytes(&p), 300);
    counter.fail_at = null;

    try testing.expectError(SparseError.OutOfMemory, warm);
    // Prior state intact — bytes and BOTH sidecars, which is what makes this a
    // rollback and not a reset.
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expect(!s.contains(far));
    try testing.expectEqual(@as(u8, 10), s.get(e(0, 0)).?[0]);
    try testing.expectEqual(@as(u8, 20), s.get(e(1, 0)).?[0]);
    try testing.expectEqual(@as(?Tick, 100), s.addedTick(e(0, 0)));
    try testing.expectEqual(@as(?Tick, 250), s.changedTick(e(1, 0)));
    // And the retry lands.
    try s.add(a, far, pairBytes(&p), 300);
    try testing.expectEqual(@as(usize, 3), s.len());
    try testing.expectEqual(@as(u8, 30), s.get(far).?[0]);
}
