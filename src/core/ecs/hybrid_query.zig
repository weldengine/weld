//! Mixed-query planner: a query spanning both storage backends elects EXACTLY ONE
//! driver — the member of smallest population, ties broken by DECLARATION ORDER —
//! and reaches every other member by an O(1) membership test.
//!
//! Every entity-bound term reaches this file, all-table ones included; such a term
//! is NOT elected, `elect` answering from the ABSENCE of a sparse form.
//!
//! Iteration order is DETERMINISTIC and NOT invariant: two states with different
//! populations may visit in different orders. A rule sees each matching entity
//! exactly once per tick, in an order it must not read.

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

/// Where an entity's component bytes live, instead of an `(archetype, chunk, slot)`
/// triple. The arms are asymmetric DELIBERATELY: the table arm keeps the direct
/// triple so the fast path pays nothing, and the sparse arm carries the ENTITY,
/// a row pointer being invalidated by any swap-remove in that store.
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

    /// The table arm resolves through its own archetype when `cid` is one of its
    /// columns and otherwise falls through to the World — which is what makes a
    /// SPARSE member of a table-driven query reachable without a second arm.
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

/// `dense.len` for a sparse member, O(1); a sum over the carrying archetypes for a
/// table one. NOT COLD — `QueryPlan.elect` runs it at every walk, and the refusal of
/// a maintained live count rests on a measurement, not on where the read sits.
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

/// Smallest population drives; a tie breaks on POSITION in `with_ids`, which is
/// static — so the decision is stable across runs for a given query, and not across
/// world states. `.table` when no member is sparse, which `QueryPlan.elect` never
/// asks for.
pub fn electDriver(world: *const World, with_ids: []const ComponentId) Driver {
    var best: ?struct { cid: ComponentId, pop: usize, sparse: bool } = null;
    for (with_ids) |cid| {
        const is_sparse = world.storageOf(cid) == .sparse;
        const pop = population(world, cid);
        // STRICTLY less, which is what "ties broken by declaration order" means.
        if (best == null or pop < best.?.pop) {
            best = .{ .cid = cid, .pop = pop, .sparse = is_sparse };
        }
    }
    const b = best orelse return .table;
    // A table member may legitimately win — a one-entity `Boss` against 500 `Burning`.
    return if (b.sparse) .{ .sparse = b.cid } else .table;
}

/// A mixed query driven by a sparse set. Holds NO archetype list: the walk is over
/// the driver's dense array and every other member is a membership test.
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

    /// Walk the driver's dense array, yielding a `Locator` per admitted entity.
    ///
    /// The iterator captures a SLICE, and a structural change to the driver during
    /// the walk is unsound two ways, neither caught by a test: GROWTH reallocates and
    /// the slice dangles; SHRINK leaves the pointer valid and the length stale.
    ///
    /// Two INDEPENDENT guardians make it sound — remove/add/despawn are DEFERRED to
    /// the tick boundary, and a spawn, which is what appends, is kept out of a rule
    /// body only by the type-checker's `test_world()` gate. That second one is the
    /// fragile half: world access in rule bodies would leave this walk unprotected.
    pub fn iterator(self: *const SparseDrivenQuery, world: *World) Iterator {
        const store = world.sparse_stores.getConst(self.driver);
        return .{
            .q = self,
            .world = world,
            .dense = if (store) |s| s.entities() else &.{},
            .i = 0,
        };
    }

    /// `dense` is CAPTURED, not re-read — the reasons are on `iterator` above.
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

    /// Never zero and never above the population: an empty range is not a unit of work.
    pub fn rangeCount(self: *const SparseDrivenQuery, world: *World, target: usize) usize {
        const store = world.sparse_stores.getConst(self.driver) orelse return 0;
        const n = store.len();
        if (n == 0) return 0;
        const t = @max(target, 1);
        return @min(t, n);
    }

    /// The `i`-th of `rangeCount(target)` ranges. The split is EVEN with the
    /// remainder over the leading ranges, so no work-stealing worker starves on a tail.
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

    /// Dispatch `Body` over each dense range as `(range, ...args)`. The
    /// command-buffer bound is enforced HERE, at comptime, on this entry's `args`.
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

    /// Whether `e` satisfies every member other than the driver. `not has T` on a
    /// sparse `T` is PER-ENTITY: an archetype cannot answer for a column it lacks.
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

/// The sparse-driven equivalent of a chunk: an index interval no other worker
/// touches, which is what makes the split safe WITHOUT a merge step.
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

/// A mixed query driven by a TABLE member, or with no sparse member at all. The
/// SPARSE half of each set is applied PER ENTITY from the locator — not an
/// optimisation, a sparse component being in NO archetype signature, so a sparse
/// exclusion handed to `DynamicQuery` excludes nothing.
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

/// Partition both sets by storage mode; the TABLE halves go to `World.queryDynamic`.
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

/// Which form of one term the current tick walks. `sparse` carries an INDEX into
/// `QueryPlan.sparse`, an id having to be mapped back to it at every use.
pub const Walk = union(enum) {
    table,
    sparse: usize,
};

/// One DNF term's plans — every form it can be walked in, built ONCE, with the
/// choice of driver deferred to the walk.
///
/// THE FORM IS STATIC AND THE CHOICE IS NOT: the partition comes from `storageOf`,
/// never mutated after registration, while `electDriver` compares POPULATIONS. So a
/// driver change is free and there is no hysteresis to calibrate.
///
/// A form dormant for N ticks must be as correct as one walked every tick, which
/// rests on `world.archetypes` being APPEND-ONLY — THE DAY A `swapRemove` REACHES
/// THAT LIST, THIS PAGE MUST REDDEN — on the split coming from `storageOf`, and on
/// `matching` holding pointers into individually allocated archetypes.
pub const QueryPlan = struct {
    /// The with-set in DECLARATION ORDER, kept whole even though both forms hold
    /// partitioned copies: a tie breaks on POSITION here, which a partition loses.
    with_ids: []ComponentId,
    /// ALWAYS built — it serves any term, which is what lets `elect` fall back on it.
    table: TableDrivenQuery,
    /// One form per SPARSE member, in declaration order. One per member and NOT one
    /// shared form with a mutable driver: `other_with` is the with-set minus its own
    /// driver, so sharing would recompute that slice at every flip.
    sparse: []SparseDrivenQuery,

    pub fn deinit(self: *QueryPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.with_ids);
        self.table.deinit(gpa);
        for (self.sparse) |*q| q.deinit(gpa);
        gpa.free(self.sparse);
        self.* = undefined;
    }

    /// Called once per walk per term, and `population` is O(archetypes) per table member.
    pub fn elect(self: *const QueryPlan, world: *const World) Walk {
        // NO sparse form means ONE possible election. Without this guard a table-only
        // term pays `population` per member every tick for a decision with one
        // outcome — and no test can see it, the elected walk being identical.
        if (self.sparse.len == 0) return .table;
        switch (electDriver(world, self.with_ids)) {
            .table => return .table,
            .sparse => |cid| {
                for (self.sparse, 0..) |*q, i| {
                    if (q.driver == cid) return .{ .sparse = i };
                }
                // Unreachable: a returned cid is a sparse member of `with_ids` and
                // this array holds one form per such member. The TABLE form and NOT
                // `unreachable`, being total — an impossible state costs a slower
                // walk and never a wrong answer.
                std.debug.assert(false);
                return .table;
            },
        }
    }

    /// Whether admission is decided PER ENTITY, so a union containing this term
    /// cannot de-duplicate by archetype. A function of STORAGE MODES ALONE, and it
    /// must NOT enter the election: answering from the elected form sends a term with
    /// sparse members but a table election back through the archetype merge, which
    /// runs under a single owner and silently loses what another term would admit.
    pub fn needsEntityDedup(self: *const QueryPlan) bool {
        return self.table.sparse_with.len != 0 or self.table.sparse_without.len != 0;
    }
};

/// NO driver is elected here — `QueryPlan.elect` does that per walk.
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
