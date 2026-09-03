//! Tier 0 sparse-set component storage — the SECOND backend of `ARCH-005`,
//! opt-in per component through `@storage(.sparse)`.
//!
//! Shape, from `engine-ecs-internals.md` §1 *Architecture*: a dense entity
//! array, a component array parallel to it, a sparse index keyed by entity
//! index with a reserved absence marker, and `added_ticks` / `changed_ticks`
//! parallel to dense. Add and remove are O(1) by swap-remove, and neither
//! migrates an archetype — which is the whole reason the mode exists.
//!
//! **Wired to the `World` since M1.B/G3.** G2 delivered the structure in
//! isolation and this header said "not wired to the `World` at this gate" —
//! true then, made false by G3, and left standing until an adversarial review
//! of the G3 diff found it. `World` owns a `SparseStores` field, every
//! resolution entry and every structural mutator routes through it, and
//! `World.storageOf` is the mode authority.
//!
//! It does read exactly one thing from `chunk.zig`: `ChunkAlignment`, the
//! engine's named bound on component alignment. That is a layout CONSTANT and
//! not a dependency on chunk storage — and importing it is the point, since
//! re-declaring the bound here would give the engine two of them, which is the
//! defect the single-declaration discipline of the `StorageKind` domain exists
//! to prevent. `rows` explains what the constant buys.
//!
//! The seven invariants of `engine-ecs-internals.md` §2 (*Invariants du backend
//! sparse*) and where each is realised:
//!
//! 1. **Swap-remove parity** — `remove`. The trailing entry moves into the
//!    freed position and its `added_tick` / `changed_tick` travel with it,
//!    exactly as `Archetype.removeSwap` makes them travel. MINUS the dirty bit,
//!    because of invariant 2, and that subtraction is the only difference.
//! 2. **No bitset, so no block skip** — this file allocates none and exposes no
//!    skip entry. A sparse component is examined per entry; nothing here may be
//!    written as if a block-granularity skip existed.
//! 3. **Despawn removes from every storage** — `remove` is the primitive the
//!    despawn path calls, and `SparseStores.removeEntity` is the union sweep it
//!    calls once per entity. A sparse entry outliving its entity is both a leak
//!    and a dangling index.
//! 4. **Observer order at despawn** — `SparseStores.forEachOf` yields ascending
//!    `ComponentId`, the same key the archetype's sorted component list gives,
//!    so a union walk merging the two is ordered on one key. Storage mode
//!    reorders nothing.
//! 5. **Zero-sized components** — `elem_size == 0` allocates NO component
//!    buffer, ever, and derives no pointer from one. A sparse tag is a dense
//!    entity array and its two tick sidecars.
//! 6. **`EntityId` generation** — `sparse` is addressed by the entity INDEX,
//!    never by the full handle, and an entry whose generation no longer matches
//!    counts as absence. Two entities of one index and different generations
//!    therefore never share an entry.
//! 7. **OOM rollback** — `add` reserves every fallible resource before it
//!    mutates anything, so a failure leaves no half-written entry and no
//!    `sparse[index]` designating an uninitialised dense row. This is the
//!    repository's own **reserve-then-mutate** invariant, named at M1.1.1-HF1
//!    (D3/D4) and applied here rather than re-invented.

const std = @import("std");
const entity_mod = @import("entity.zig");
const registry_mod = @import("registry.zig");
const chunk_mod = @import("chunk.zig");
const tick_mod = @import("tick.zig");

const EntityId = entity_mod.EntityId;
const ComponentId = registry_mod.ComponentId;
const Tick = tick_mod.Tick;

/// Reserved value of a `sparse` slot meaning "this entity index carries no
/// entry". `maxInt(u32)` is unreachable as a dense position for the same
/// reason `EntityId.dead` is unreachable as an index: 4 G live rows would be
/// needed to produce it.
pub const absent: u32 = std.math.maxInt(u32);

/// Errors this storage can raise. `add` on an entity already present is a
/// programmer error and asserts rather than erroring, mirroring
/// `World.addComponent`'s treatment of the same mistake — the add-on-present
/// case is a REPLACEMENT, decided one layer up by the observer-dispatching
/// apply, and a storage that silently accepted it would hide that decision.
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
    /// Entity INDEX → position in `dense`, or `absent`. Grown to cover the
    /// largest index ever inserted; never indexed by a full handle.
    ///
    /// **Its size follows the largest entity INDEX, not the entry count** — and
    /// the index space is bounded by the PEAK of CONCURRENTLY LIVE entities,
    /// not by the total number ever spawned: `EntityIdentityStore.allocate`
    /// recycles from `free_indices` before appending a slot, so reaching index
    /// 10^6 takes 10^6 entities coexisting, which is a very different statement
    /// from "one entry on an entity at index 10^6".
    ///
    /// The real residual is that this array **never shrinks back** after such a
    /// peak. That is the sparse set's accepted trade-off and not a defect to
    /// fix: shrinking on despawn would thrash the allocation against the very
    /// churn the mode exists to serve. It is the price of O(1) membership with
    /// no hash container, which the determinism discipline wants anyway.
    sparse: std.ArrayListUnmanaged(u32) = .empty,

    /// Component rows, `elem_size` bytes each, parallel to `dense`.
    ///
    /// A raw over-aligned buffer rather than a byte `ArrayList`, because the
    /// row alignment is a RUNTIME value from the registry and Zig's aligned
    /// list takes a comptime one. It is allocated at `chunk_mod.ChunkAlignment`
    /// — the engine's own named bound on component alignment, 16 bytes for
    /// `@Vector(4, f32)` — and row `i` at offset `i * elem_size` inherits that
    /// alignment because `@sizeOf(T)` is always a multiple of `@alignOf(T)`.
    /// `init` asserts `elem_align <= ChunkAlignment` so a component past the
    /// bound fails loud instead of landing mis-aligned.
    ///
    /// **Null forever when `elem_size == 0`** (invariant 5): a zero-sized
    /// component allocates no buffer and no pointer is derived from one.
    rows: ?[]align(chunk_mod.ChunkAlignment) u8 = null,
    /// Rows the `rows` buffer can hold. Meaningless when `rows == null`.
    rows_capacity: usize = 0,

    /// The exact field set, pinned.
    ///
    /// `World.beginFrame` clears every archetype's dirty bitset and has NO
    /// sparse arm, because a sparse store carries per-row `added`/`changed`
    /// ticks and no chunk-granular bitset — a granularity a sparse set does not
    /// have, so there would be nothing to clear (invariant 2). A comment saying
    /// so is a claim; the block below is the guard. Add or reorder a field and
    /// it breaks, which is the moment to go re-read the frame boundary and
    /// decide whether it now owes the new field something.
    ///
    /// Pinned as the field SET and not the count: swapping two fields for a
    /// different pair leaves the count untouched, and the message names the
    /// field where the sets diverge.
    ///
    /// Here, beside the fields, because here is where a field gets added. It
    /// spent one round at file scope on a FALSE diagnosis — both
    /// counter-factuals had compiled clean and I read that as a struct-body
    /// `comptime` block not being analysed, when in fact my two mutation
    /// patterns omitted the fields' `= 0` / `= .empty` defaults and had
    /// silently matched nothing. A struct-body block IS analysed, measured with
    /// an always-false probe; the move is undone rather than re-justified.
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
        // A component past the engine's own alignment bound would be stored
        // mis-aligned by the `i * elem_size` row arithmetic, silently. The
        // bound is `chunk_mod.ChunkAlignment`, which the table backend already
        // applies to every SoA column, so this asserts the SAME contract rather
        // than inventing a second one.
        std.debug.assert(elem_align <= chunk_mod.ChunkAlignment);
        // `@sizeOf` is a multiple of `@alignOf` for every Zig type, so a
        // non-zero size that is not a multiple of its alignment cannot come
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

    /// The live entity list — the iteration order of a sparse-driven query.
    /// Deterministic (a pure function of the operation sequence) and NOT
    /// invariant: a swap-remove reorders it, which `ARCH-005` puts out of
    /// contract explicitly.
    pub fn entities(self: *const SparseSetStorage) []const EntityId {
        return self.dense.items;
    }

    /// Dense position of `entity`, or null. **The generation check lives here
    /// and nowhere else** (invariant 6): `sparse` is indexed by
    /// `entity.index`, and the full handle stored in `dense` is what decides
    /// whether the entry belongs to THIS entity or to a previous occupant of
    /// the same index. One comparison, no second table.
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

    /// Read-only bytes of `entity`'s row, or null when absent. An empty slice
    /// for a zero-sized component — the correct answer, and one that derives
    /// no pointer from an unallocated buffer (invariant 5).
    pub fn get(self: *const SparseSetStorage, entity: EntityId) ?[]const u8 {
        const pos = self.positionOf(entity) orelse return null;
        return self.rowConst(pos);
    }

    /// Mutable bytes of `entity`'s row plus the change stamp, or null when
    /// absent. Mirrors `World.getMut`'s auto-mark: every write through the
    /// returned slice is observable by a change filter whose `last_run_tick`
    /// is below `tick`.
    pub fn getMut(self: *SparseSetStorage, entity: EntityId, tick: Tick) ?[]u8 {
        const pos = self.positionOf(entity) orelse return null;
        self.changed_ticks.items[pos] = tick;
        return self.row(pos);
    }

    /// Mutable bytes of `entity`'s row WITHOUT the change stamp, or null when
    /// absent.
    ///
    /// The distinction from `getMut` is not a convenience: `World.componentBytes`
    /// is the byte-level surface `observers.zig` reads through to build its
    /// `old_ptr` / `new_ptr` payloads, it hands out mutable bytes, and its table
    /// arm does NOT stamp. Serving it from `getMut` would make every observer
    /// dispatch register as a mutation of the component it is reporting on,
    /// which a `Changed<T>` filter would then see one tick later — a change
    /// nobody made, with no diagnostic. `markChanged` remains the entry whose
    /// job the stamp is.
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

    /// Insert `entity` with `bytes` as its row, stamping both sidecars at
    /// `tick`. `bytes.len` must equal `elem_size`; an empty slice is the
    /// correct argument for a zero-sized component.
    ///
    /// **Reserve-then-mutate** (invariant 7): every fallible step runs before
    /// the first observable mutation, so a failure leaves the storage exactly
    /// as it was — no half-written entry, and no `sparse[index]` designating an
    /// uninitialised dense row. This is the repository's named invariant from
    /// M1.1.1-HF1 (D3/D4), applied rather than re-derived.
    ///
    /// Adding an entity that is already present is a programmer error and
    /// asserts: add-on-present is a REPLACEMENT and the decision belongs to the
    /// apply path above, not to the storage.
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
        // The row buffer grows by doubling, and it is reserved BEFORE the dense
        // append so a failure here cannot leave a dense entry without a row.
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

    /// Remove `entity`'s entry. Returns the entity that was RELOCATED into the
    /// freed position, or null when nothing moved (the entry was last, or was
    /// absent). The caller needs the relocated handle for nothing today — the
    /// sparse index is updated here — and it is returned because the table's
    /// `Archetype.removeSwap` returns it and a divergent shape between the two
    /// swap-removes would be one more thing to remember.
    ///
    /// Swap-remove parity (invariant 1): the trailing row's bytes AND both of
    /// its tick sidecars travel into the freed position, so a change filter
    /// sees a relocated entity exactly as it would have seen it un-relocated.
    /// There is no dirty bit to carry — invariant 2 — and that absence is the
    /// only difference from the table's version.
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

    /// Row `pos` as mutable bytes. Empty — and derived from no pointer — for a
    /// zero-sized component (invariant 5).
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
/// **Why the set is part of G2 and not of the routing gate.** Two of the seven
/// invariants are not expressible against a single storage: invariant 3 is a
/// sweep over EVERY storage for one entity, and invariant 4 is an ORDER across
/// storages. The smallest object that can carry either is a collection, so it
/// belongs to the gate that proves the invariants. What stays out is the
/// `World` — nothing here knows one.
///
/// A dense array indexed by `ComponentId`, not a hash map: component ids are
/// small sequential integers assigned by the registry, so the array is O(1) and
/// carries no hashed container, which the determinism discipline of
/// `ARCH-031` and the broadphase precedent both ask for. Ascending index IS
/// ascending `ComponentId`, which is what makes invariant 4 structural rather
/// than a sort.
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

    /// Declare `component_id` sparse. Idempotent: a second call for the same id
    /// keeps the existing storage, so a hot-reload re-compile does not discard
    /// live rows (the treatment `compileResource` already gives a re-registered
    /// resource).
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

    /// The smallest `ComponentId` at or above `from` whose storage holds
    /// `entity`, or null when there is none.
    ///
    /// Ascending BY CONSTRUCTION: `slots` is indexed by `ComponentId`, so
    /// walking it in index order walks the ids in ascending order — no sort and
    /// no allocation. That is what lets the despawn path merge the two backends
    /// into one ascending sequence with a two-pointer walk, which is the
    /// normative firing order over the union.
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

    /// Call `cb(ctx, component_id)` for every sparse component `entity`
    /// carries, in **ascending `ComponentId`** (invariant 4). The order is a
    /// property of the container — ascending slot index is ascending id — not
    /// of a sort, so it cannot be lost by a comparator.
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

    /// Drop every sparse entry `entity` carries. The primitive the despawn path
    /// calls once per entity (invariant 3): removing an entity from its
    /// archetype does not remove its sparse components, and an entry that
    /// outlives its entity is both a leak and a dangling index.
    ///
    /// Returns how many entries were dropped, so a caller can assert a sweep
    /// actually swept — a sweep whose extent is not reported can cover less in
    /// silence.
    pub fn removeEntity(self: *SparseStores, entity: EntityId) usize {
        var dropped: usize = 0;
        for (self.slots.items) |*maybe| {
            const store = if (maybe.*) |*s| s else continue;
            // The count comes from a membership test taken BEFORE the removal:
            // `remove` returns the RELOCATED handle, which is null both when
            // nothing moved and when the entity was absent, so its return value
            // cannot serve as "was something dropped".
            if (!store.contains(entity)) continue;
            _ = store.remove(entity);
            dropped += 1;
        }
        return dropped;
    }
};

// ─── inline tests — the seven invariants, one by one ──────────────────────
//
// Each invariant gets its own test and its own counter-factual, and the
// counter-factual changes the OBJECT rather than the expected constant
// (`engine-development-workflow.md` §5.5). Where an invariant is an ABSENCE it
// is paired with its positive witness, because an apparatus that produces
// nothing satisfies a negative assertion on its own.

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

/// Allocator that fails exactly ONE **allocation** and then behaves normally.
///
/// `std.testing.FailingAllocator` cannot serve here: it does not advance its
/// index on failure, so from `fail_index` onward EVERY allocation fails, and a
/// test that asserts recovery after the induced failure would be proving the
/// property OR exhaustion without distinguishing them
/// (`engine-development-workflow.md` §5.5, measured at M1.1.15.1). One shot is
/// what makes the assertion after the failure mean something.
const OneShotFail = struct {
    backing: std.mem.Allocator,
    /// Allocation to fail, counted from zero over `alloc` ONLY. `null` fails
    /// nothing, which is how the count is measured.
    ///
    /// **`resize` and `remap` are deliberately NOT counted, and that cost a
    /// round.** Counting them looked more thorough and was wrong: an
    /// `ArrayList` growing past its capacity first asks the allocator to extend
    /// in place, and a refusal there is a ROUTINE MISS the list recovers from by
    /// allocating a fresh block and copying. Failing it therefore induces no
    /// OOM at all — the warm case of invariant 7 consumed its one shot on such
    /// a resize and the add then SUCCEEDED, which is exactly the shape the test
    /// read as the property failing. What this instrument must fail is the
    /// allocation whose refusal ABORTS the operation, and that is `alloc`.
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

// ── Invariant 1 — swap-remove parity ──────────────────────────────────────

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

    // Remove a NON-LAST entry. This is the counter-factual shape the gate
    // demands: removing the last one relocates nothing, so it would prove the
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
    // The discriminating half. If `remove` reported a relocation here, the
    // test above would be passing on a path that always copies, and its
    // "relocation" would be an artefact.
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

// ── Invariant 2 — no bitset, so no block skip ─────────────────────────────

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

    // The POSITIVE WITNESS, without which the absence above is satisfied by an
    // apparatus that does nothing: a per-entry change scan over a mix returns
    // exactly the changed entries, so examination-per-entry is real.
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

// ── Invariant 3 — despawn removes from every storage ──────────────────────

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

// ── Invariant 4 — observer order at despawn ───────────────────────────────

test "invariant 4: the union enumerates in ascending ComponentId" {
    const gpa = testing.allocator;
    var stores = SparseStores{};
    defer stores.deinit(gpa);

    // DECLARED in descending order. This is the counter-factual the gate asks
    // for — permuting the declaration order must not change the firing order —
    // and it is applied to the object rather than to an expected constant.
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

// ── Invariant 5 — zero-sized components ───────────────────────────────────

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

    // COUNTER-FACTUAL on the object: a sized component on the same code path
    // DOES allocate, so the null above discriminates instead of being the
    // constant answer of a storage that never allocates anything.
    var sized = SparseSetStorage.init(2, @sizeOf(Pair), @alignOf(Pair));
    defer sized.deinit(gpa);
    const p = Pair{ .a = 1, .b = 2 };
    try sized.add(gpa, e(0, 0), pairBytes(&p), 1);
    try testing.expect(sized.rows != null);
    try testing.expect(sized.rows_capacity > 0);
}

// ── Invariant 6 — EntityId generation ─────────────────────────────────────

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

// ── Invariant 7 — OOM rollback ────────────────────────────────────────────

test "invariant 7: a failed add rolls back every fallible step, and a retry works" {
    // TWO sweeps, because one state cannot exercise both halves of the
    // invariant — and the first version of this test learned that from its own
    // non-vacuity check rather than from an argument.
    //
    // What it did: built a warm storage with two entries, then swept the fail
    // index over the THIRD add. `attempts` came back **zero** and
    // `expect(attempts > 0)` fired. The measurement was right and the
    // expectation was wrong: after two appends the dense array, both tick
    // sidecars and the row buffer all hold spare capacity (the lists grow
    // geometrically, `rows` doubles to 8 on the first add), and `sparse`
    // already covers index 2 — so a warm add allocates NOTHING and there was
    // no failure to induce. A sweep over zero attempts would have passed every
    // assertion below by never entering the branch that carries them; the
    // guard that says so is the only reason this is visible.
    //
    // (a) COLD sweep — the first add of a fresh storage, where every fallible
    //     step must allocate. This is what covers all of them.
    // (b) WARM case — prior state present and a target index far enough out to
    //     force the sparse array to grow. This is what proves the prior state
    //     survives, which a rollback to "empty" would satisfy vacuously.
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
            // This index did not reach an allocation on this run; nothing to
            // assert, and the induced count below is what keeps the sweep
            // honest about how many did.
            continue;
        } else |err| {
            cold_induced += 1;
            try testing.expectEqual(SparseError.OutOfMemory, err);

            // Nothing half-written: no entry, and no sparse slot designating
            // an uninitialised dense row.
            try testing.expectEqual(@as(usize, 0), s.len());
            try testing.expect(!s.contains(e(0, 0)));
            for (s.sparse.items) |slot| try testing.expectEqual(absent, slot);

            // THE RECOVERY HALF, and the reason the allocator is one-shot: a
            // storage left corrupt would also refuse this, so without recovery
            // the test would prove the property OR exhaustion without telling
            // them apart.
            try s.add(a, e(0, 0), pairBytes(&p), 300);
            try testing.expectEqual(@as(usize, 1), s.len());
            try testing.expectEqual(@as(u8, 30), s.get(e(0, 0)).?[0]);
            try testing.expectEqual(@as(?Tick, 300), s.addedTick(e(0, 0)));
        }
    }
    // Extent reported, not assumed — and asserted as an EQUALITY rather than a
    // floor, which is the stronger claim and not a brittle one: every
    // allocation the add path performs must have induced a rollback. A `>= 1`
    // would pass with four of five allocations uncovered; an exact magic number
    // would pin `ArrayList` internals. If this ever fails low, an allocation is
    // happening on the add path that the rollback does not cover.
    try testing.expectEqual(cold_allocs, cold_induced);

    // ── (b) Prior state must survive. The target index is far out so the
    //        sparse array has to grow whatever the lists' spare capacity — the
    //        one fallible step a warm storage still reaches.
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
