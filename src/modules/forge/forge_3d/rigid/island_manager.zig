//! `forge_3d/rigid/island_manager.zig` — the rigid branch's adapter onto the
//! branch-neutral island core (`engine-physics-forge.md` §1.8.1).
//!
//! `pipeline/island.zig` knows only opaque indices. This file is what gives them
//! meaning for the rigid branch: it projects the awake dynamic bodies onto
//! `0..count`, links the pairs its contact constraints couple, ranks the resulting
//! groups, reorders the constraint array into one contiguous range per island —
//! the range shape the solver's stage entries have taken since M1.1.6 —
//! and arbitrates the two decisions the model makes per island: activation at step
//! 5 of the normative cycle (§1.7) and the sleep transition at step 11.
//!
//! Four rules, all normative, all load-bearing:
//!
//!   - **Seeded by bodies, not by constraints.** Every awake dynamic body is a
//!     member of exactly one island, including one carrying no constraint at all —
//!     it forms a SINGLETON island, which can fall asleep like any other. A
//!     sleeping body is not simulated, so it is not a member; it becomes one again
//!     on the tick it wakes, the partition running after every wake of the tick is
//!     acquired.
//!   - **Only dynamic bodies link.** Two bodies merge iff BOTH are dynamic and a
//!     contact constraint couples them. A constraint cannot change the velocity of
//!     an infinite-mass body, so nothing couples the bodies touching one — and
//!     linking through statics would fuse the whole scene through the ground, the
//!     classic trap.
//!   - **A constraint belongs to its dynamic endpoint's island** (the first one in
//!     canonical pair order). `prepare`'s true-zero skip already removed the
//!     infinite-mass pairs, so EVERY constraint has an island: a box at rest keeps
//!     its ground contact.
//!   - **Rank is the smallest member `BodyId`.** No tie-break exists or is needed —
//!     membership partitions the awake dynamic set, so that minimum is unique per
//!     island.
//!
//! Determinism by construction (M1.1.14). No hash container anywhere: the reverse
//! `BodyId` → dense-index direction is a scratch array indexed by slot, members are
//! sorted ascending by `BodyId`, ranks are assigned by walking members in that
//! order, and constraints are ordered by the COMPOSITE key
//! `(rank, pair_key, subshape_id)` — so the result never depends on the sort
//! algorithm's stability. Rank, membership and constraint order are a pure function
//! of two inputs: the awake dynamic set, and the pair-key-sorted constraint array.
//!
//! That key is a TRIPLET and not a pair, and the third term is what makes the
//! sentence above true: since M1.1.11.1 a mesh pair contributes one constraint per
//! contacting triangle, all sharing `rank` and `pair_key`, and on those two alone
//! their relative order would be `std.sort.block`'s internal tie-handling — which is
//! UNSTABLE. `lessByCompositeKey` is the authority.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("../config.zig");
const bm_mod = @import("../body_manager.zig");
const island = @import("../pipeline/island.zig");
const sleep = @import("../pipeline/sleep.zig");
const cc = @import("contact_constraint.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyManager = bm_mod.BodyManager;
const ContactConstraint = cc.ContactConstraint;
const SleepConfig = sleep.SleepConfig;
const BodyId = api.BodyId;

/// One island: where its members and its constraints sit, and whether anything
/// outside it is moving it.
pub const Island = struct {
    /// First constraint index of this island in the reordered array.
    constraint_from: u32,
    /// One past the last. `constraint_from == constraint_to` for a singleton, which
    /// is a normal island and not an absence.
    constraint_to: u32,
    /// First member index in the manager's grouped member array.
    member_from: u32,
    /// One past the last. Always `> member_from` — an island has at least one body.
    member_to: u32,
    /// Whether a constraint of this island touches a NON-member (a static or
    /// kinematic body) whose velocity is not exactly zero — wake cause W3
    /// (§1.8.5). Without it a group resting on a moving platform would see only
    /// eligible members and fall asleep on a support that is moving.
    touches_moving_non_member: bool,
};

/// A member of the partition: its handle and the store column it lives in.
const Member = struct {
    id: BodyId,
    slot: u32,
};

/// The composite sort key of one constraint — `(rank, pair_key, subshape_id)` — plus
/// where the constraint currently sits, so the array can be permuted into key order.
pub const ConstraintKey = struct {
    rank: u32,
    pair_key: u64,
    /// The constraint's SUB-SHAPE — the third term of the composite key, and load-bearing since
    /// M1.1.11.1 (closure finding F4). A mesh pair contributes one constraint per contacting
    /// triangle, all sharing `rank` and `pair_key`; on those two alone their relative order would
    /// be `std.sort.block`'s internal behaviour, which is UNSTABLE, and this file's own docstring
    /// promises the opposite — that the ordering "never leans on the sort algorithm being stable".
    subshape_id: u32,
    source_index: u32,
};

/// Sentinel for "this dense index has no rank yet" in `root_rank`. Ranks are dense
/// from zero, so `maxInt` cannot collide with a real one.
const rank_unassigned: u32 = std.math.maxInt(u32);

/// Partitions the awake dynamic bodies into islands and arbitrates their two
/// decisions. Reused across ticks: every buffer is cleared and refilled by
/// `partition`, capacity is retained, so a steady-state tick allocates nothing.
pub const IslandManager = struct {
    /// The branch-neutral union-find, seeded to one element per member.
    core: island.UnionFind = .{},
    /// Members in ascending `BodyId` order — dense index `i` IS `members[i]`.
    /// Ascending order is what makes rank assignment "by minimum member `BodyId`"
    /// fall out of a simple ascending walk.
    members: std.ArrayListUnmanaged(Member) = .empty,
    /// Store column → dense index + 1, or 0 for a body that is not a member. The
    /// reverse direction, kept as a scratch array indexed by slot rather than any
    /// associative container.
    slot_to_dense: std.ArrayListUnmanaged(u32) = .empty,
    /// Union-find root → island rank, `rank_unassigned` until seen.
    root_rank: std.ArrayListUnmanaged(u32) = .empty,
    /// Dense index → island rank.
    dense_rank: std.ArrayListUnmanaged(u32) = .empty,
    /// Member handles grouped by island, ascending `BodyId` inside each group.
    member_ids: std.ArrayListUnmanaged(BodyId) = .empty,
    /// Scratch write cursor per island, used to scatter members into their group.
    group_cursor: std.ArrayListUnmanaged(u32) = .empty,
    /// The constraint sort keys, left in sorted order by `partition`.
    keys: std.ArrayListUnmanaged(ConstraintKey) = .empty,
    /// Scratch: original constraint index → its index after reordering.
    destination: std.ArrayListUnmanaged(u32) = .empty,
    /// The islands, indexed BY RANK — `islands.items[r].member_from` etc.
    islands: std.ArrayListUnmanaged(Island) = .empty,

    /// Release every buffer.
    pub fn deinit(self: *IslandManager, gpa: std.mem.Allocator) void {
        self.core.deinit(gpa);
        self.members.deinit(gpa);
        self.slot_to_dense.deinit(gpa);
        self.root_rank.deinit(gpa);
        self.dense_rank.deinit(gpa);
        self.member_ids.deinit(gpa);
        self.group_cursor.deinit(gpa);
        self.keys.deinit(gpa);
        self.destination.deinit(gpa);
        self.islands.deinit(gpa);
        self.* = undefined;
    }

    /// The islands of the last `partition`, indexed by rank (so rank order is
    /// ascending minimum member `BodyId`).
    pub fn islandsSlice(self: *const IslandManager) []const Island {
        return self.islands.items;
    }

    /// The members of `isl`, ascending by `BodyId`.
    pub fn islandMembers(self: *const IslandManager, isl: Island) []const BodyId {
        return self.member_ids.items[isl.member_from..isl.member_to];
    }

    /// Step 5 of the normative cycle (§1.7): partition the awake dynamic bodies,
    /// reorder `constraints` into one contiguous range per island, and apply the
    /// activation arbitration. Nothing is ever put to sleep here — this step only
    /// wakes.
    ///
    /// `constraints` must be the array `contact_constraint.build` produced, sorted
    /// ascending by pair key; it is permuted in place into
    /// `(rank, pair_key, subshape_id)` order. Both accumulated impulses and every
    /// other field ride along untouched — only the ORDER changes.
    ///
    /// On the two wake causes this step owns: W3 is applied here as a real wake, so
    /// a group on a moving support restarts its window every tick and cannot
    /// accumulate toward sleep. W2 — "an island is awake as soon as one of its
    /// members is not eligible" — needs no flag write at this point, because a
    /// sleeping body is never a member: every member is awake by construction. Its
    /// operative form is the AND that `sleepEligibleIslands` evaluates at step 11,
    /// on the post-solve windows rather than these stale ones.
    pub fn partition(
        self: *IslandManager,
        gpa: std.mem.Allocator,
        bm: *BodyManager,
        constraints: []ContactConstraint,
    ) !void {
        try self.collectMembers(gpa, bm);
        try self.core.seed(gpa, @intCast(self.members.items.len));
        self.linkConstraints(bm, constraints);
        try self.assignRanks(gpa);
        try self.groupMembers(gpa);
        try self.orderConstraints(gpa, bm, constraints);
        self.markMovingNonMembers(bm, constraints);
        self.applyW3(bm);
    }

    /// Step 11 of the cycle, second half: put to sleep every island all of whose
    /// members are eligible. Call it AFTER `sleep.updateWindows` has advanced the
    /// windows on the post-solve state — this reads them, it does not compute them.
    ///
    /// The reduction is an AND over members (§1.8.3): one member that cannot sleep
    /// keeps the whole island awake. That is wake cause W2 in its operative form.
    /// An island touching a moving non-member is excluded outright (W3); its
    /// members' windows were already restarted at step 5, so this is belt and
    /// braces, and deliberately so — the exclusion is normative and should not
    /// depend on a side effect.
    ///
    /// Returns how many islands fell asleep this tick.
    pub fn sleepEligibleIslands(self: *const IslandManager, bm: *BodyManager, cfg: SleepConfig) u32 {
        if (!cfg.allow_sleeping) return 0;
        var slept: u32 = 0;
        for (self.islands.items) |isl| {
            if (isl.touches_moving_non_member) continue;
            var all_eligible = true;
            for (self.islandMembers(isl)) |id| {
                if (!sleep.isEligible(bm, id, cfg)) {
                    all_eligible = false;
                    break;
                }
            }
            if (!all_eligible) continue;
            for (self.islandMembers(isl)) |id| sleep.putToSleep(bm, id);
            slept += 1;
        }
        return slept;
    }

    // --- partition steps ------------------------------------------------------

    /// Collect the awake dynamic bodies into `members`, ascending by `BodyId`, and
    /// build the slot → dense reverse map.
    fn collectMembers(self: *IslandManager, gpa: std.mem.Allocator, bm: *const BodyManager) !void {
        self.members.clearRetainingCapacity();

        const body_types = bm.bodies.items(.body_type);
        const flags = bm.bodies.items(.flags);
        const slot_count: u32 = @intCast(bm.bodies.len);

        var slot: u32 = 0;
        while (slot < slot_count) : (slot += 1) {
            if (body_types[slot] != .dynamic) continue;
            if (flags[slot].sleeping) continue;
            // `idAtIndex` filters dead columns and rebuilds the generation the bare
            // column index does not carry.
            const id = bm.alloc.idAtIndex(slot) orelse continue;
            try self.members.append(gpa, .{ .id = id, .slot = slot });
        }
        // Ascending `BodyId`. Slot order is NOT `BodyId` order — the generation sits
        // in the high bits — so this sort is what makes the dense projection ordered
        // by handle, and therefore rank assignment ordered by minimum member handle.
        std.mem.sort(Member, self.members.items, {}, lessByBodyId);

        self.slot_to_dense.clearRetainingCapacity();
        try self.slot_to_dense.appendNTimes(gpa, 0, slot_count);
        for (self.members.items, 0..) |m, dense| {
            self.slot_to_dense.items[m.slot] = @as(u32, @intCast(dense)) + 1;
        }
    }

    /// The dense index of `id`, or null if it is not a member (a static, a
    /// kinematic, or a sleeping dynamic body).
    ///
    /// Goes through `validate` rather than reading the handle's own index field:
    /// the reverse map is indexed by store COLUMN, and a stale handle names a column
    /// that may since have been refilled by a different body. Checking the
    /// generation is what stops it resolving to that body's island.
    fn denseOf(self: *const IslandManager, bm: *const BodyManager, id: BodyId) ?u32 {
        const slot = bm.alloc.validate(id) orelse return null;
        const dense_plus_one = self.slot_to_dense.items[slot];
        if (dense_plus_one == 0) return null;
        return dense_plus_one - 1;
    }

    /// Link the two endpoints of every constraint whose endpoints are BOTH members.
    /// Statics and kinematics are non-members, so they never link — which is what
    /// stops the ground fusing the scene into one island.
    fn linkConstraints(
        self: *IslandManager,
        bm: *const BodyManager,
        constraints: []const ContactConstraint,
    ) void {
        for (constraints) |c| {
            const dense_a = self.denseOf(bm, c.body_a) orelse continue;
            const dense_b = self.denseOf(bm, c.body_b) orelse continue;
            self.core.link(dense_a, dense_b);
        }
    }

    /// Assign each island its rank, walking members in ascending `BodyId` order so
    /// that the first member to reach a root carries that island's minimum handle —
    /// rank order IS ascending minimum member `BodyId`, with no comparison of roots
    /// anywhere (a root is not canonical, `island.UnionFind.find`).
    fn assignRanks(self: *IslandManager, gpa: std.mem.Allocator) !void {
        const count: u32 = @intCast(self.members.items.len);

        self.root_rank.clearRetainingCapacity();
        try self.root_rank.appendNTimes(gpa, rank_unassigned, count);
        self.dense_rank.clearRetainingCapacity();
        try self.dense_rank.appendNTimes(gpa, 0, count);

        var next_rank: u32 = 0;
        var dense: u32 = 0;
        while (dense < count) : (dense += 1) {
            const root = self.core.find(dense);
            if (self.root_rank.items[root] == rank_unassigned) {
                self.root_rank.items[root] = next_rank;
                next_rank += 1;
            }
            self.dense_rank.items[dense] = self.root_rank.items[root];
        }

        self.islands.clearRetainingCapacity();
        try self.islands.appendNTimes(gpa, .{
            .constraint_from = 0,
            .constraint_to = 0,
            .member_from = 0,
            .member_to = 0,
            .touches_moving_non_member = false,
        }, next_rank);
    }

    /// Scatter the members into contiguous per-island groups by counting sort.
    /// Scattering in ascending dense order leaves each group ascending by `BodyId`.
    fn groupMembers(self: *IslandManager, gpa: std.mem.Allocator) !void {
        const island_count: u32 = @intCast(self.islands.items.len);

        self.group_cursor.clearRetainingCapacity();
        try self.group_cursor.appendNTimes(gpa, 0, island_count);
        for (self.dense_rank.items) |rank| self.group_cursor.items[rank] += 1;

        var start: u32 = 0;
        for (self.islands.items, 0..) |*isl, rank| {
            const size = self.group_cursor.items[rank];
            isl.member_from = start;
            isl.member_to = start + size;
            self.group_cursor.items[rank] = start; // becomes the write cursor
            start += size;
        }

        self.member_ids.clearRetainingCapacity();
        try self.member_ids.appendNTimes(gpa, 0, self.members.items.len);
        for (self.members.items, 0..) |m, dense| {
            const rank = self.dense_rank.items[dense];
            self.member_ids.items[self.group_cursor.items[rank]] = m.id;
            self.group_cursor.items[rank] += 1;
        }
    }

    /// Reorder `constraints` into `(rank, pair_key, subshape_id)` order and record
    /// each island's index range. The composite key is explicit AND total, so the
    /// ordering never leans on the sort algorithm being stable.
    fn orderConstraints(
        self: *IslandManager,
        gpa: std.mem.Allocator,
        bm: *const BodyManager,
        constraints: []ContactConstraint,
    ) !void {
        self.keys.clearRetainingCapacity();
        try self.keys.ensureTotalCapacity(gpa, constraints.len);
        for (constraints, 0..) |c, i| {
            self.keys.appendAssumeCapacity(.{
                .rank = self.rankOfConstraint(bm, c),
                .pair_key = c.pair_key,
                .subshape_id = c.subshape_id,
                .source_index = @intCast(i),
            });
        }
        std.mem.sort(ConstraintKey, self.keys.items, {}, lessByCompositeKey);

        // Turn "take position i from `source_index`" into "send what is at position
        // s to `destination[s]`", which is the convention the in-place permutation
        // below consumes — and which leaves `keys` sorted, so the range scan that
        // follows can still read the ranks in ascending order.
        self.destination.clearRetainingCapacity();
        try self.destination.appendNTimes(gpa, 0, constraints.len);
        for (self.keys.items, 0..) |key, i| {
            self.destination.items[key.source_index] = @intCast(i);
        }
        applyPermutation(constraints, self.destination.items);

        // Ranks are dense from zero, so one forward scan assigns every range —
        // including the empty ones of constraint-less singleton islands, which come
        // out as `from == to` at the current cursor and keep the ranges contiguous.
        var cursor: u32 = 0;
        for (self.islands.items, 0..) |*isl, rank| {
            isl.constraint_from = cursor;
            while (cursor < self.keys.items.len and self.keys.items[cursor].rank == rank) {
                cursor += 1;
            }
            isl.constraint_to = cursor;
        }
        std.debug.assert(cursor == self.keys.items.len);
    }

    /// The island rank of `c`: that of its first DYNAMIC endpoint in canonical pair
    /// order.
    ///
    /// A constraint ALWAYS has an island. Two guarantees compose to give that:
    /// `prepare`'s true-zero inverse-mass skip means at least one endpoint is
    /// dynamic, and `build`'s wake fixpoint means every dynamic endpoint of a live
    /// constraint is awake — hence a member. The `unreachable` names that composed
    /// invariant, not a hope; it is safety-checked in Debug and ReleaseSafe, which is
    /// the whole test matrix.
    fn rankOfConstraint(self: *const IslandManager, bm: *const BodyManager, c: ContactConstraint) u32 {
        if (self.denseOf(bm, c.body_a)) |dense| return self.dense_rank.items[dense];
        const dense_b = self.denseOf(bm, c.body_b) orelse unreachable; // see doc
        return self.dense_rank.items[dense_b];
    }

    /// Flag every island holding a constraint against a moving non-member (W3).
    /// The velocity test is at TRUE ZERO and there is no branch on body type: what
    /// matters is that the other endpoint is outside the partition, not what kind of
    /// body it is.
    fn markMovingNonMembers(
        self: *IslandManager,
        bm: *const BodyManager,
        constraints: []const ContactConstraint,
    ) void {
        for (constraints) |c| {
            const dense_a = self.denseOf(bm, c.body_a);
            const dense_b = self.denseOf(bm, c.body_b);
            if (dense_a != null and dense_b != null) continue; // no non-member here
            const member_dense = dense_a orelse dense_b orelse unreachable; // see `rankOfConstraint`
            const non_member = if (dense_a == null) c.body_a else c.body_b;
            if (!sleep.isMoving(bm, non_member)) continue;
            self.islands.items[self.dense_rank.items[member_dense]].touches_moving_non_member = true;
        }
    }

    /// Wake every member of every island flagged by W3, restarting their windows so
    /// a group cannot accumulate toward sleep on a support that is moving.
    fn applyW3(self: *const IslandManager, bm: *BodyManager) void {
        for (self.islands.items) |isl| {
            if (!isl.touches_moving_non_member) continue;
            for (self.islandMembers(isl)) |id| bm.wakeBody(id);
        }
    }
};

fn lessByBodyId(_: void, x: Member, y: Member) bool {
    return x.id < y.id;
}

/// TOTAL order over constraint keys — `(rank, pair_key, subshape_id)`.
///
/// Total, and not merely a grouping: two constraints of one pair cannot share a `subshape_id`,
/// the sub-shape being the triangle index and each triangle being offered at most once. That is
/// what lets the permutation below be a function of the keys alone rather than of the sort's
/// tie-handling — the invariant M1.1.8 wrote down and several constraints per pair had annulled.
pub fn lessByCompositeKey(_: void, x: ConstraintKey, y: ConstraintKey) bool {
    if (x.rank != y.rank) return x.rank < y.rank;
    if (x.pair_key != y.pair_key) return x.pair_key < y.pair_key;
    return x.subshape_id < y.subshape_id;
}

/// Permute `items` in place so that whatever entered at position `s` ends up at
/// `destination[s]`. `destination` is consumed (left as the identity).
///
/// The textbook in-place permutation: at each position, keep swapping in whatever
/// belongs there until it does. Every swap puts at least one element in its final
/// place, so the total work is linear. In place rather than through a scratch
/// buffer because a `ContactConstraint` is several hundred bytes and the scratch
/// would be per-tick dead weight.
///
/// The DESTINATION convention is not interchangeable with the source one
/// ("position i takes from `perm[i]`"): fed a source permutation this loop silently
/// produces a different, wrong order. The caller inverts before calling.
fn applyPermutation(items: []ContactConstraint, destination: []u32) void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        while (destination[i] != i) {
            const j = destination[i];
            std.mem.swap(ContactConstraint, &items[i], &items[j]);
            std.mem.swap(u32, &destination[i], &destination[j]);
        }
    }
}
