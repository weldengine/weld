//! Mixed-query planner — M1.B/G7.
//!
//! A query whose members span both storage backends elects **exactly one
//! driver** — the member of smallest population, ties broken by declaration
//! order in the query — and reaches every other member by an O(1) membership
//! test. A query whose members are all table iterates archetypes exactly as
//! today, and this file is not on that path.
//!
//! **The contract is `engine-ecs-internals.md` §2, *Driving set des queries
//! mixtes*, and it is a contract before it is a mechanism:**
//!
//! - Iteration order is **deterministic** — a pure function of world state, so
//!   two machines in identical states visit in the same order. Comparing two
//!   populations is itself a pure function of the state, which is what lets a
//!   cardinality driver keep that promise.
//! - **Non invariant** — two states with different populations may visit in
//!   different orders. Already true before this file: an archetype migration or
//!   a swap-remove changes the order from one tick to the next.
//! - **Out of contract** — a rule sees each matching entity EXACTLY ONCE per
//!   tick, in an order it must not read. A rule whose result depends on the
//!   visit order is a defect of the rule.
//!
//! **This is a DISTINCT iteration type, not a second mode of `DynamicQuery`.**
//! The chunk-based dispatch protocol has no meaning for a sparse-driven walk —
//! there is no chunk — so a second mode would force every consumer to branch on
//! which one it holds. It is additive to the `World` API on the precedent
//! already written at `world.zig`'s `queryDynamic`: "The C0.5 freeze covers the
//! Tier-0 ↔ Tier-1 module interfaces, not internal `World` methods, so this does
//! not breach it." `WELD_ECS_PROTOCOL_VERSION` stays at 1 and the milestone
//! PROVES it rather than asserting it (see `hybrid_query_test.zig`).
//!
//! The module-scope tail-rescan helper `query.rescanNewArchetypes` is reused
//! rather than copied: it already serves the comptime `Query` and
//! `DynamicQuery`, so a third caller costs a call.

const std = @import("std");
const components = @import("components.zig");
const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");
const query_mod = @import("query.zig");
const registry_mod = @import("registry.zig");
const world_mod = @import("world.zig");
const command_buffer_mod = @import("command_buffer.zig");

const Archetype = archetype_mod.Archetype;
const Chunk = chunk_mod.Chunk;
const ComponentId = registry_mod.ComponentId;
const EntityId = components.EntityId;
const World = world_mod.World;

/// Where an entity's component bytes live — storage-agnostic, and the argument
/// the per-slot guards take instead of an `(archetype, chunk, slot)` triple.
///
/// The two arms are asymmetric deliberately, exactly as `ComponentRef`'s are
/// (M1.B/G5): the table arm keeps the direct triple so the delivered fast path
/// pays nothing, and the sparse arm carries the ENTITY because a sparse lookup
/// is an array index plus a generation compare, and because a row pointer would
/// be invalidated by any swap-remove in that store.
pub const Locator = union(enum) {
    table: struct { arch: *Archetype, chunk: *Chunk, slot: u32 },
    sparse: EntityId,

    /// The entity this locator designates, whichever arm it carries.
    pub fn entity(self: Locator) EntityId {
        return switch (self) {
            .table => |t| t.arch.entityIds(t.chunk)[t.slot],
            .sparse => |e| e,
        };
    }

    /// The bytes of `cid` for this locator's entity, or null when absent.
    ///
    /// The table arm resolves through its own archetype when `cid` is one of
    /// that archetype's columns — the direct path — and otherwise falls through
    /// to the World, which is what makes a SPARSE member of a table-driven
    /// query reachable without a second locator kind.
    pub fn componentBytes(self: Locator, world: *World, cid: ComponentId) ?[]u8 {
        switch (self) {
            .table => |t| {
                if (t.arch.componentIndex(cid)) |col| {
                    return t.arch.componentSlot(t.chunk, col, t.slot);
                }
                return world.componentBytes(t.arch.entityIds(t.chunk)[t.slot], cid);
            },
            .sparse => |e| return world.componentBytes(e, cid),
        }
    }
};

/// Which member drives the walk.
pub const Driver = union(enum) {
    /// No sparse member in the with-set: archetype iteration, unchanged.
    table,
    /// A sparse member drives: walk its dense array.
    sparse: ComponentId,
};

/// The population of `cid` — the number of live entities carrying it.
///
/// For a sparse member this is `dense.len`, an O(1) read. For a table member it
/// is a sum over the archetypes carrying it, so O(archetypes), and
/// `arch.hasComponent` is itself a walk of that archetype's signature.
///
/// **THIS PATH IS NO LONGER COLD.** The clause that stood here — a write on the
/// hot structural path traded against "a read on a COLD one" — was exact while
/// the driver was elected once at build. Since M1.B/P2-1 `QueryPlan.elect` runs
/// at every walk, so one election per term per tick costs O(t · A) with `t` the
/// table members of the term's with-set and `A` the archetype count. The
/// arbitration against a per-component live count maintained on every migration
/// therefore no longer follows from where the read sits, and stands only on a
/// MEASUREMENT of that cost, which M1.B/P2-1 owes and this comment must not
/// pre-empt.
pub fn population(world: *const World, cid: ComponentId) usize {
    if (world.storageOf(cid) == .sparse) {
        const store = world.sparse_stores.getConst(cid) orelse return 0;
        return store.len();
    }
    var total: usize = 0;
    for (world.archetypes.items) |arch| {
        if (arch.hasComponent(cid)) total += arch.entityCount();
    }
    return total;
}

/// Elect the driver of a query whose "must contain" set is `with_ids`.
///
/// **The member of smallest population drives, and a tie is broken by
/// DECLARATION ORDER** — the position in `with_ids`, which is static, so the
/// decision is stable across runs for a given query even though it is not
/// stable across world states. That asymmetry is the contract, not an accident:
/// deterministic, non-invariant, out of contract.
///
/// Returns `.table` when `with_ids` names no sparse component, which keeps the
/// delivered archetype path exactly as it was — this file is not on it.
pub fn electDriver(world: *const World, with_ids: []const ComponentId) Driver {
    var best: ?struct { cid: ComponentId, pop: usize, sparse: bool } = null;
    for (with_ids) |cid| {
        const is_sparse = world.storageOf(cid) == .sparse;
        const pop = population(world, cid);
        // STRICTLY less: the first member of a tied population keeps the seat,
        // which is what "ties broken by declaration order" means.
        if (best == null or pop < best.?.pop) {
            best = .{ .cid = cid, .pop = pop, .sparse = is_sparse };
        }
    }
    const b = best orelse return .table;
    // A table member may legitimately win — a single-entity `Boss` against a
    // 500-entity sparse `Burning` — and then the walk is the archetype walk,
    // with the sparse members reached by membership from the locator.
    return if (b.sparse) .{ .sparse = b.cid } else .table;
}

/// A mixed query, driven by a sparse set.
///
/// Holds no archetype list: the walk is over the driver's dense array, and
/// every other member is a membership test. `deinit` frees the owned id copies.
pub const SparseDrivenQuery = struct {
    driver: ComponentId,
    /// The with-set MINUS the driver — each tested by membership per candidate.
    other_with: []ComponentId,
    without_ids: []ComponentId,

    pub fn deinit(self: *SparseDrivenQuery, gpa: std.mem.Allocator) void {
        gpa.free(self.other_with);
        gpa.free(self.without_ids);
        self.* = undefined;
    }

    /// Walk the driver's dense array, yielding a `Locator` for every entity
    /// that satisfies the whole query.
    ///
    /// The iterator captures a SLICE of the driver's dense array, not a length:
    /// `dense` is an `ArrayListUnmanaged`, and `s.entities()` is read once, here.
    /// So a structural change to the driver DURING the walk is unsound in two
    /// distinct ways, and this code survives neither:
    ///
    ///   - GROWTH reallocates, and the captured slice dangles. Loud in Debug
    ///     and ReleaseSafe, undefined in ReleaseFast.
    ///   - SHRINK (a swap-remove) leaves the pointer valid and the captured
    ///     LENGTH stale, so the tail of the walk reads dead-but-allocated
    ///     entries. Silent in every mode. In particular, capturing does NOT
    ///     make a concurrent swap-remove visit-at-most-once: nothing here
    ///     re-reads the length, so the removed entity's replacement is skipped
    ///     AND a stale trailing slot is read.
    ///
    /// What makes the capture sound is not this code. It is TWO INDEPENDENT
    /// guardians, and losing either one reopens its own half:
    ///
    ///   1. Remove, add and despawn are DEFERRED to the tick boundary — an Etch
    ///      body enqueues onto `world.observer_registry.deferred`, drained by
    ///      `Interpreter.flushStructural` — so no rule body shrinks the dense
    ///      array under a live walk. This guardian also covers the chunk pointer
    ///      `ComponentRef`'s table arm holds.
    ///   2. A spawn IS immediate somewhere: `spawn_with` calls
    ///      `World.spawnWithObservers` directly, and an APPEND is what
    ///      reallocates. What keeps it out of a rule body is not deferral but
    ///      the type-checker's surface gate — `test_world()` resolves only under
    ///      `Checker.in_test_body` and falls through to E0102 otherwise
    ///      (measured), so a rule body holds no world handle at all. This
    ///      guardian covers the dense slice ONLY, an append never invalidating
    ///      a chunk pointer, and it is the more fragile of the two: exposing
    ///      world access to rule bodies is a plausible evolution that would
    ///      leave guardian 1 untouched and this walk unprotected.
    pub fn iterator(self: *const SparseDrivenQuery, world: *World) Iterator {
        const store = world.sparse_stores.getConst(self.driver);
        return .{
            .q = self,
            .world = world,
            .dense = if (store) |s| s.entities() else &.{},
            .i = 0,
        };
    }

    /// `dense` is CAPTURED, not re-read — the two failure modes and the two
    /// guardians that keep them unreachable are on `iterator` above.
    pub const Iterator = struct {
        q: *const SparseDrivenQuery,
        world: *World,
        dense: []const EntityId,
        i: usize,

        pub fn next(it: *Iterator) ?Locator {
            while (it.i < it.dense.len) {
                const e = it.dense[it.i];
                it.i += 1;
                if (it.q.admits(it.world, e)) return .{ .sparse = e };
            }
            return null;
        }
    };

    /// How many dense ranges the driver's population splits into, for a target
    /// of `target` ranges. Never zero, and never more than the population: a
    /// range is a unit of work, and an empty one is not one.
    pub fn rangeCount(self: *const SparseDrivenQuery, world: *World, target: usize) usize {
        const store = world.sparse_stores.getConst(self.driver) orelse return 0;
        const n = store.len();
        if (n == 0) return 0;
        const t = @max(target, 1);
        return @min(t, n);
    }

    /// The `i`-th of `rangeCount(target)` ranges.
    ///
    /// The split is EVEN with the remainder spread over the leading ranges, so
    /// every range differs from every other by at most one — the property that
    /// keeps a work-stealing scheduler from starving on a tail.
    ///
    /// *That beneficiary was NAMED here before it existed: from M1.B/G8 until
    /// `JobBuilder.addDenseRangeJobs` landed, no dense range reached a worker
    /// at all, and the sentence above justified a split by a consumer with no
    /// producer. It is true as of that entry, and the note stays because the
    /// claim is only as good as the path that consumes it.*
    pub fn rangeAt(self: *const SparseDrivenQuery, world: *World, i: usize, target: usize) DenseRange {
        const total = blk: {
            const store = world.sparse_stores.getConst(self.driver) orelse break :blk 0;
            break :blk store.len();
        };
        const n = self.rangeCount(world, target);
        std.debug.assert(i < n);
        const base = total / n;
        const extra = total % n;
        const from = i * base + @min(i, extra);
        const size = base + (if (i < extra) @as(usize, 1) else 0);
        return .{ .from = from, .to = from + size };
    }

    /// Dispatch `Body` over each dense range, passing `(range, ...args)`.
    ///
    /// The command-buffer bound is enforced HERE, at comptime, on this entry's
    /// own `args` — see `refuseCommandBufferInArgs`.
    pub fn forEachDenseRange(
        self: *const SparseDrivenQuery,
        world: *World,
        target: usize,
        comptime Body: anytype,
        args: anytype,
    ) void {
        command_buffer_mod.refuseCommandBufferInArgs(@TypeOf(args));
        const n = self.rangeCount(world, target);
        for (0..n) |i| {
            @call(.auto, Body, .{self.rangeAt(world, i, target)} ++ args);
        }
    }

    /// The driver's dense array, for a body that took a range.
    pub fn dense(self: *const SparseDrivenQuery, world: *World) []const EntityId {
        const store = world.sparse_stores.getConst(self.driver) orelse return &.{};
        return store.entities();
    }

    /// Whether `e` satisfies every member other than the driver.
    ///
    /// `not has T` on a sparse `T` is a PER-ENTITY membership test here, not an
    /// archetype-level filter — which is the whole point: an archetype cannot
    /// answer for a component it does not carry a column for.
    pub fn admits(self: *const SparseDrivenQuery, world: *World, e: EntityId) bool {
        for (self.other_with) |cid| {
            if (!world.hasComponentDyn(e, cid)) return false;
        }
        for (self.without_ids) |cid| {
            if (world.hasComponentDyn(e, cid)) return false;
        }
        return true;
    }
};

/// A half-open range of the driver's dense array — the sparse-driven
/// equivalent of a chunk, and the unit a worker takes.
///
/// A chunk is a unit because it is a contiguous allocation; a dense range is a
/// unit for the same reason and nothing else. Both are index intervals over
/// storage that no other worker touches, which is what makes the split safe
/// WITHOUT a merge step.
pub const DenseRange = struct {
    from: usize,
    to: usize,

    pub fn len(self: DenseRange) usize {
        return self.to - self.from;
    }
};

/// Build the sparse-driven query for `driver` out of a with/without set.
pub fn planSparseDriven(
    gpa: std.mem.Allocator,
    driver: ComponentId,
    with_ids: []const ComponentId,
    without_ids: []const ComponentId,
) !SparseDrivenQuery {
    var others: std.ArrayListUnmanaged(ComponentId) = .empty;
    errdefer others.deinit(gpa);
    for (with_ids) |cid| {
        if (cid != driver) try others.append(gpa, cid);
    }
    const without_copy = try gpa.dupe(ComponentId, without_ids);
    errdefer gpa.free(without_copy);
    return .{
        .driver = driver,
        .other_with = try others.toOwnedSlice(gpa),
        .without_ids = without_copy,
    };
}

/// A mixed query whose driver is a TABLE member — or which has no sparse member
/// in its with-set at all.
///
/// The walk is the archetype walk, delegated to `DynamicQuery` over the TABLE
/// subset of both sets, and the SPARSE half of each set is applied PER ENTITY
/// from the locator. That split is what the contract requires: "`not has T` on a
/// sparse `T` ceases to be an archetype-level filter and becomes a per-entity
/// membership test."
///
/// It is not an optimisation: `DynamicQuery`'s `without_ids` is evaluated at
/// archetype level, and since M1.B/G3 a sparse component is in NO archetype's
/// signature — so a sparse exclusion handed to it matches nothing to exclude
/// and every candidate survives. The defect is pinned in
/// `tests/ecs/hybrid_query_test.zig` before the fix, on the two entities that
/// share one archetype precisely because the sparse member routes away.
pub const TableDrivenQuery = struct {
    /// The archetype-level query, over the table subset of both sets.
    inner: query_mod.DynamicQuery,
    /// Sparse members that must be PRESENT, tested per entity.
    sparse_with: []ComponentId,
    /// Sparse members that must be ABSENT, tested per entity.
    sparse_without: []ComponentId,

    pub fn deinit(self: *TableDrivenQuery, gpa: std.mem.Allocator) void {
        self.inner.deinit(gpa);
        gpa.free(self.sparse_with);
        gpa.free(self.sparse_without);
        self.* = undefined;
    }

    pub fn iterator(self: *TableDrivenQuery, world: *World) Iterator {
        _ = self.inner.maybeRescan();
        return .{ .q = self, .world = world, .ai = 0, .ci = 0, .slot = 0 };
    }

    pub const Iterator = struct {
        q: *TableDrivenQuery,
        world: *World,
        ai: usize,
        ci: usize,
        slot: u32,

        pub fn next(it: *Iterator) ?Locator {
            while (it.ai < it.q.inner.matching.items.len) {
                const arch = it.q.inner.matching.items[it.ai];
                if (it.ci >= arch.chunks.items.len) {
                    it.ai += 1;
                    it.ci = 0;
                    it.slot = 0;
                    continue;
                }
                const chunk = arch.chunks.items[it.ci];
                if (it.slot >= chunk.entityCount()) {
                    it.ci += 1;
                    it.slot = 0;
                    continue;
                }
                const s = it.slot;
                it.slot += 1;
                const loc: Locator = .{ .table = .{ .arch = arch, .chunk = chunk, .slot = s } };
                if (it.q.admits(it.world, loc.entity())) return loc;
            }
            return null;
        }
    };

    /// The sparse half of both sets, per entity.
    pub fn admits(self: *const TableDrivenQuery, world: *World, e: EntityId) bool {
        for (self.sparse_with) |cid| {
            if (!world.hasComponentDyn(e, cid)) return false;
        }
        for (self.sparse_without) |cid| {
            if (world.hasComponentDyn(e, cid)) return false;
        }
        return true;
    }
};

/// Build the table-driven query: partition both sets by storage mode, hand the
/// TABLE halves to `World.queryDynamic`, and keep the SPARSE halves for the
/// per-entity test.
pub fn planTableDriven(
    gpa: std.mem.Allocator,
    world: *World,
    with_ids: []const ComponentId,
    without_ids: []const ComponentId,
) !TableDrivenQuery {
    var t_with: std.ArrayListUnmanaged(ComponentId) = .empty;
    defer t_with.deinit(gpa);
    var t_without: std.ArrayListUnmanaged(ComponentId) = .empty;
    defer t_without.deinit(gpa);
    var s_with: std.ArrayListUnmanaged(ComponentId) = .empty;
    errdefer s_with.deinit(gpa);
    var s_without: std.ArrayListUnmanaged(ComponentId) = .empty;
    errdefer s_without.deinit(gpa);

    for (with_ids) |cid| {
        if (world.storageOf(cid) == .sparse) try s_with.append(gpa, cid) else try t_with.append(gpa, cid);
    }
    for (without_ids) |cid| {
        if (world.storageOf(cid) == .sparse) try s_without.append(gpa, cid) else try t_without.append(gpa, cid);
    }

    var inner = try world.queryDynamic(gpa, t_with.items, t_without.items);
    errdefer inner.deinit(gpa);
    return .{
        .inner = inner,
        .sparse_with = try s_with.toOwnedSlice(gpa),
        .sparse_without = try s_without.toOwnedSlice(gpa),
    };
}

/// Which form of one term the current tick walks.
///
/// `sparse` carries an INDEX into `QueryPlan.sparse` and not a `ComponentId`,
/// because the form is what the walk needs and the id would have to be mapped
/// back to it at every use.
pub const Walk = union(enum) {
    table,
    sparse: usize,
};

/// One DNF term's plans — EVERY form the term can be walked in, built once,
/// with the CHOICE of driver deferred to the walk.
///
/// **The FORM of a plan is static and the CHOICE of driver is not**, and that
/// is the whole factorisation. `planTableDriven` partitions the two sets by
/// `storageOf`, a REGISTRY fact recorded at registration and never mutated
/// (`Registry.componentStorage` has no setter); `electDriver` compares
/// POPULATIONS, a world fact that moves every tick. So the forms are built
/// once and each walk elects among them, which makes a driver change free and
/// removes the question of a beat entirely — there is no hysteresis to
/// calibrate and no threshold to engrave, because nothing is being smoothed.
///
/// **Three preconditions of the design, not observations of it.** A form that
/// lies dormant for N ticks and is then elected must be as correct as one
/// walked every tick, and that rests on:
///
///   1. `world.archetypes` is APPEND-ONLY — one `append` in `World`, whose
///      only `pop` is the `errdefer` that annuls it. `query.rescanNewArchetypes`
///      walks `[last_seen, len)`, so a dormant table form's tail rescan is
///      exact whatever its cursor's age. **The day a `swapRemove` reaches that
///      list, this page is what must redden.**
///   2. The table form's with/without split is derived from `storageOf`, so a
///      form re-consulted after any number of dormant ticks carries the SAME
///      sets it was built with. There is no with-set the cached archetypes were
///      never examined against.
///   3. `matching` holds `*Archetype` into individually allocated archetypes,
///      stable for the world's lifetime, so growth of the list relocates
///      nothing a dormant form still points at.
pub const QueryPlan = struct {
    /// The with-set in DECLARATION ORDER.
    ///
    /// Kept whole even though both forms hold partitioned copies: `electDriver`
    /// breaks a population tie on the POSITION in this slice, and a partition
    /// loses the interleaving that position encodes.
    with_ids: []ComponentId,
    /// The archetype walk. ALWAYS built — it serves any term, which is what
    /// lets `elect` fall back on it rather than fail.
    table: TableDrivenQuery,
    /// One sparse-driven form per SPARSE member of the with-set, in declaration
    /// order. Empty when the with-set names no sparse component.
    ///
    /// One per member and not one shared form with a mutable driver: a form's
    /// `other_with` is the with-set MINUS its own driver, so a shared form would
    /// have to recompute that slice at every flip — an allocation on the very
    /// path this design makes free — or test the driver against itself once per
    /// entity on the hot walk.
    sparse: []SparseDrivenQuery,

    pub fn deinit(self: *QueryPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.with_ids);
        self.table.deinit(gpa);
        for (self.sparse) |*q| q.deinit(gpa);
        gpa.free(self.sparse);
        self.* = undefined;
    }

    /// Elect the form this walk uses, from the CURRENT populations.
    ///
    /// Called once per walk per term, and `population` is O(archetypes) for a
    /// table member — the cost the milestone measures rather than assumes.
    pub fn elect(self: *const QueryPlan, world: *const World) Walk {
        switch (electDriver(world, self.with_ids)) {
            .table => return .table,
            .sparse => |cid| {
                for (self.sparse, 0..) |*q, i| {
                    if (q.driver == cid) return .{ .sparse = i };
                }
                // Unreachable by the two facts above — a returned cid is a
                // sparse member of `with_ids`, and this array holds one form per
                // such member — so the fallback exists for the state that cannot
                // occur rather than for one that can. It is the TABLE form and
                // NOT `unreachable`: that form is total, so an impossible state
                // costs a slower walk and never a wrong answer.
                std.debug.assert(false);
                return .table;
            },
        }
    }

    /// Whether this term's admission is decided PER ENTITY, so a union
    /// containing it cannot de-duplicate by archetype.
    ///
    /// True for a term carrying ANY sparse member, present or absent — read off
    /// the table form, whose two sparse lists are a partition by `storageOf`.
    /// **So the predicate is a function of storage modes ALONE and does not
    /// enter the election**: making it answer from the elected form would send a
    /// term with sparse members but a table election back through the archetype
    /// merge, which is the P1-2 defect exactly.
    ///
    /// The merge runs `iterateArchetype` once per archetype under a SINGLE
    /// owner, so every other term's `admits` is skipped, and the entity a
    /// non-last term would have admitted is silently lost.
    pub fn needsEntityDedup(self: *const QueryPlan) bool {
        return self.table.sparse_with.len != 0 or self.table.sparse_without.len != 0;
    }
};

/// Build every form one term can be walked in. **No driver is elected here** —
/// see `QueryPlan.elect`, which does it per walk from live populations.
pub fn plan(
    gpa: std.mem.Allocator,
    world: *World,
    with_ids: []const ComponentId,
    without_ids: []const ComponentId,
) !QueryPlan {
    const with_copy = try gpa.dupe(ComponentId, with_ids);
    errdefer gpa.free(with_copy);

    var table = try planTableDriven(gpa, world, with_ids, without_ids);
    errdefer table.deinit(gpa);

    var forms: std.ArrayListUnmanaged(SparseDrivenQuery) = .empty;
    errdefer {
        for (forms.items) |*q| q.deinit(gpa);
        forms.deinit(gpa);
    }
    // Reserved up front so no append can fail after a form is built and leak it.
    try forms.ensureTotalCapacity(gpa, table.sparse_with.len);
    for (with_ids) |cid| {
        if (world.storageOf(cid) != .sparse) continue;
        forms.appendAssumeCapacity(try planSparseDriven(gpa, cid, with_ids, without_ids));
    }

    return .{
        .with_ids = with_copy,
        .table = table,
        .sparse = try forms.toOwnedSlice(gpa),
    };
}
