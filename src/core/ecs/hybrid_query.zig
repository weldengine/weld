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
/// is a sum over the archetypes carrying it, so O(archetypes) — paid once per
/// election and not per entity, and the alternative (a per-component live count
/// maintained on every migration) would put a write on the hot structural path
/// to save a read on a cold one.
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
    /// The dense array is SNAPSHOT by length at the start: a structural change
    /// during the walk is a programmer error on this path (the interpreter
    /// defers every structural mutation to the tick boundary), and snapshotting
    /// the length rather than re-reading it makes a swap-remove during the walk
    /// visit-at-most-once rather than skip-or-repeat.
    pub fn iterator(self: *const SparseDrivenQuery, world: *World) Iterator {
        const store = world.sparse_stores.getConst(self.driver);
        return .{
            .q = self,
            .world = world,
            .dense = if (store) |s| s.entities() else &.{},
            .i = 0,
        };
    }

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

/// One DNF term's plan: which of the two walks serves it.
///
/// A UNION and not a flag on one struct, because the two walks share no state:
/// the table arm owns a matched-archetype cache and a tail-rescan cursor, the
/// sparse arm owns neither and reads its driver's dense array live. A flag
/// would force every consumer to hold both sets of fields and branch on which
/// half is meaningful.
pub const QueryPlan = union(enum) {
    table: TableDrivenQuery,
    sparse: SparseDrivenQuery,

    pub fn deinit(self: *QueryPlan, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .table => |*q| q.deinit(gpa),
            .sparse => |*q| q.deinit(gpa),
        }
    }

    /// Whether this term is served by the archetype walk. The disjunctive path
    /// keeps its ascending-archetype-id merge only while EVERY term answers
    /// true — one sparse-driven term and the whole union de-duplicates by
    /// entity instead.
    pub fn isTableDriven(self: QueryPlan) bool {
        return self == .table;
    }
};

/// Elect the driver for one term and build its plan.
pub fn plan(
    gpa: std.mem.Allocator,
    world: *World,
    with_ids: []const ComponentId,
    without_ids: []const ComponentId,
) !QueryPlan {
    return switch (electDriver(world, with_ids)) {
        .table => .{ .table = try planTableDriven(gpa, world, with_ids, without_ids) },
        .sparse => |driver| .{ .sparse = try planSparseDriven(gpa, driver, with_ids, without_ids) },
    };
}
