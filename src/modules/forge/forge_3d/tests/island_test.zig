//! M1.1.8 acceptance suite for island partitioning.
//!
//! Two layers, matching the two layers of the design
//! (`engine-physics-forge.md` §1.8.1): the branch-neutral union-find core of
//! `pipeline/island.zig` exercised in isolation — no physics type involved at all —
//! and, above it, the rigid adapter's partition of real bodies and contact
//! constraints.

const std = @import("std");
const island = @import("../pipeline/island.zig");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const rigid = @import("../rigid/root.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const BodyId = api.BodyId;
const ContactConstraint = rigid.ContactConstraint;
const testing = std.testing;

// --- neutral core -------------------------------------------------------------

/// Canonical labelling of a partition: each element is labelled with the SMALLEST
/// element index of its group. Two union-finds hold the same partition iff their
/// canonical labellings are equal — a representation that is independent of which
/// element happens to be the union-find root, so it compares partitions and not
/// tree shapes.
fn canonicalLabels(uf: *island.UnionFind, out: []u32) void {
    const n = uf.count();
    std.debug.assert(out.len == n);
    // `min_of_root[r]` = smallest element seen so far under root `r`. Walking i
    // ascending means the first element to reach a root IS that group's minimum.
    for (out) |*slot| slot.* = std.math.maxInt(u32);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const r = uf.find(i);
        if (out[r] == std.math.maxInt(u32)) out[r] = i;
    }
    // Second pass: publish each element's group minimum (the roots hold it now).
    i = 0;
    while (i < n) : (i += 1) out[i] = out[uf.find(i)];
}

test "island core seeds singletons and links only seeded indices" {
    const gpa = testing.allocator;
    var uf = island.UnionFind{};
    defer uf.deinit(gpa);

    // Seeding alone puts every element in its own group.
    try uf.seed(gpa, 5);
    try testing.expectEqual(@as(u32, 5), uf.count());
    var i: u32 = 0;
    while (i < 5) : (i += 1) try testing.expectEqual(i, uf.find(i));

    uf.link(1, 3);
    try testing.expectEqual(uf.find(1), uf.find(3));

    // Idempotent: re-linking an already-merged pair changes nothing.
    const root_before = uf.find(1);
    uf.link(1, 3);
    try testing.expectEqual(root_before, uf.find(1));
    try testing.expectEqual(root_before, uf.find(3));

    // Idempotent in the other endpoint order too: the pair is already merged.
    uf.link(3, 1);
    try testing.expectEqual(root_before, uf.find(1));
    try testing.expectEqual(root_before, uf.find(3));

    // Linking 1 and 3 touched no other element: 0, 2 and 4 are still singletons,
    // pairwise distinct and distinct from the merged group.
    for ([_]u32{ 0, 2, 4 }) |x| {
        try testing.expectEqual(x, uf.find(x));
        try testing.expect(uf.find(x) != root_before);
    }
    try testing.expect(uf.find(0) != uf.find(2));
    try testing.expect(uf.find(2) != uf.find(4));

    // Re-seeding drops every link — no residue from the previous partition, and
    // the element set really is `0..n` (an index beyond it is not addressable).
    try uf.seed(gpa, 3);
    try testing.expectEqual(@as(u32, 3), uf.count());
    i = 0;
    while (i < 3) : (i += 1) try testing.expectEqual(i, uf.find(i));
}

test "island core link is symmetric in endpoint order" {
    const gpa = testing.allocator;
    // Same link SET applied to two fresh instances, endpoints swapped in the
    // second. Shape equality (`parent` and `size` element-wise), not just
    // partition equality: the doc comment on `link` claims the reversed call
    // is the same operation, so the resulting trees must be identical, and a
    // canonical-label comparison would not catch a shape divergence.
    const links = [_][2]u32{ .{ 0, 1 }, .{ 2, 1 }, .{ 3, 4 }, .{ 5, 6 }, .{ 4, 5 } };
    var forward = island.UnionFind{};
    defer forward.deinit(gpa);
    var reversed = island.UnionFind{};
    defer reversed.deinit(gpa);
    try forward.seed(gpa, 8);
    try reversed.seed(gpa, 8);
    for (links) |l| {
        forward.link(l[0], l[1]);
        reversed.link(l[1], l[0]);
    }
    try testing.expectEqualSlices(u32, forward.parent.items, reversed.parent.items);
    try testing.expectEqualSlices(u32, forward.size.items, reversed.size.items);
}

/// Decode `k` (`0 <= k < n!`) into the `k`-th permutation of `0..n` in
/// factorial-number-system order. Deterministic and exhaustive — no RNG in a test
/// that has to be reproducible.
fn nthPermutation(comptime n: usize, k: usize, out: *[n]usize) void {
    var pool: [n]usize = undefined;
    for (0..n) |i| pool[i] = i;

    var remaining = k;
    var pool_len: usize = n;
    for (0..n) |i| {
        var factorial: usize = 1;
        for (1..pool_len) |f| factorial *= f;
        const pick = remaining / factorial;
        remaining %= factorial;
        out[i] = pool[pick];
        for (pick..pool_len - 1) |j| pool[j] = pool[j + 1];
        pool_len -= 1;
    }
}

test "island core grouping is invariant under link-order permutation" {
    const gpa = testing.allocator;

    // Eight elements, five links. Element 7 is never linked (it must stay a
    // singleton). Element 1 appears as the SECOND endpoint of two different links,
    // which is what makes the order-dependence of a naive merge observable: a merge
    // that overwrote `parent[b]` without resolving the root first would strand
    // whichever group linked first, and strand a DIFFERENT one per order.
    const links = [_][2]u32{ .{ 0, 1 }, .{ 2, 1 }, .{ 3, 4 }, .{ 5, 6 }, .{ 4, 5 } };
    const n_links = links.len;
    const element_count = 8;

    // Expected partition: {0,1,2}, {3,4,5,6}, {7}.
    const expected = [element_count]u32{ 0, 0, 0, 3, 3, 3, 3, 7 };

    var total_permutations: usize = 1;
    for (1..n_links + 1) |f| total_permutations *= f;

    var uf = island.UnionFind{};
    defer uf.deinit(gpa);

    var labels: [element_count]u32 = undefined;
    var order: [n_links]usize = undefined;
    for (0..total_permutations) |k| {
        nthPermutation(n_links, k, &order);
        try uf.seed(gpa, element_count);
        for (order) |link_index| {
            const l = links[link_index];
            uf.link(l[0], l[1]);
        }
        canonicalLabels(&uf, &labels);
        try testing.expectEqualSlices(u32, &expected, &labels);
    }
}

// --- rigid partition ------------------------------------------------------------

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

fn pairKey(a: BodyId, b: BodyId) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// A minimal scene for partition tests: bodies, every pair fed to `build`, and the
/// island manager over the result. No broadphase and no solver — the partition is a
/// function of the awake dynamic set and the sorted constraint array, and nothing
/// else, so nothing else is composed here.
const Rig = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty,
    pairs: std.ArrayListUnmanaged(u64) = .empty,
    manager: rigid.IslandManager = .{},
    ids: std.ArrayListUnmanaged(BodyId) = .empty,

    fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
        self.constraints.deinit(gpa);
        self.pairs.deinit(gpa);
        self.manager.deinit(gpa);
        self.ids.deinit(gpa);
        self.* = undefined;
    }

    /// Add a box of `half` half-extents at `pos`. Entity index mirrors the creation
    /// order so a test can name a body independently of the handle it received.
    fn addBox(
        self: *Rig,
        gpa: std.mem.Allocator,
        body_type: api.BodyType,
        pos: foundation.math.Vec3,
        half: foundation.math.Vec3,
    ) !BodyId {
        const s = try self.store.createShape(gpa, .{ .box = .{ .half_extents = half } });
        var d = api.BodyDescriptor{
            .entity = .{ .index = @intCast(self.ids.items.len), .generation = 0 },
            .body_type = body_type,
            .shape = s,
        };
        d.mass = 1;
        d.position = pos;
        const id = try self.bm.addBody(gpa, &self.store, d);
        try self.ids.append(gpa, id);
        return id;
    }

    /// Feed every body pair to `build`, then partition.
    fn partitionAll(self: *Rig, gpa: std.mem.Allocator) !void {
        self.pairs.clearRetainingCapacity();
        for (self.ids.items, 0..) |a, i| {
            for (self.ids.items[i + 1 ..]) |b| try self.pairs.append(gpa, pairKey(a, b));
        }
        std.mem.sort(u64, self.pairs.items, {}, std.sort.asc(u64));
        try rigid.build(gpa, &self.constraints, &self.bm, &self.store, self.pairs.items);
        try self.manager.partition(gpa, &self.bm, self.constraints.items);
    }

    /// The rank of the island `id` belongs to, or null if it is not a member.
    fn rankOf(self: *const Rig, id: BodyId) ?u32 {
        for (self.manager.islandsSlice(), 0..) |isl, rank| {
            for (self.manager.islandMembers(isl)) |member| {
                if (member == id) return @intCast(rank);
            }
        }
        return null;
    }

    /// Every constraint sits in exactly one island range, and the ranges tile the
    /// array from 0 to its length with no hole and no overlap.
    fn expectRangesTileTheArray(self: *const Rig) !void {
        var cursor: u32 = 0;
        for (self.manager.islandsSlice()) |isl| {
            try testing.expectEqual(cursor, isl.constraint_from);
            try testing.expect(isl.constraint_to >= isl.constraint_from);
            cursor = isl.constraint_to;
        }
        try testing.expectEqual(@as(u32, @intCast(self.constraints.items.len)), cursor);
    }
};

/// A unit box (half-extents 0.5): two of them 0.99 apart overlap by 0.01.
const unit_half: f32 = 0.5;

test "two separated stacks partition into two islands" {
    const gpa = testing.allocator;
    var rig = Rig{};
    defer rig.deinit(gpa);
    const half = av3(unit_half, unit_half, unit_half);

    // Two stacked pairs, 50 m apart — no ground, so the only contacts are the two
    // internal ones.
    const a0 = try rig.addBox(gpa, .dynamic, av3(0, 0, 0), half);
    const a1 = try rig.addBox(gpa, .dynamic, av3(0, 0.99, 0), half);
    const b0 = try rig.addBox(gpa, .dynamic, av3(50, 0, 0), half);
    const b1 = try rig.addBox(gpa, .dynamic, av3(50, 0.99, 0), half);
    try rig.partitionAll(gpa);

    try testing.expectEqual(@as(usize, 2), rig.constraints.items.len);
    try testing.expectEqual(@as(usize, 2), rig.manager.islandsSlice().len);
    try testing.expectEqual(rig.rankOf(a0).?, rig.rankOf(a1).?);
    try testing.expectEqual(rig.rankOf(b0).?, rig.rankOf(b1).?);
    try testing.expect(rig.rankOf(a0).? != rig.rankOf(b0).?);
    for (rig.manager.islandsSlice()) |isl| {
        try testing.expectEqual(@as(u32, 2), isl.member_to - isl.member_from);
        try testing.expectEqual(@as(u32, 1), isl.constraint_to - isl.constraint_from);
    }
    try rig.expectRangesTileTheArray();
}

test "a static ground does not link the bodies resting on it" {
    const gpa = testing.allocator;
    var rig = Rig{};
    defer rig.deinit(gpa);
    const half = av3(unit_half, unit_half, unit_half);

    // One ground, two boxes resting on it far enough apart not to touch each other.
    // Linking through the static would fuse them — the classic trap this refuses.
    _ = try rig.addBox(gpa, .static, av3(0, 0, 0), av3(20, 0.5, 20));
    const left = try rig.addBox(gpa, .dynamic, av3(-3, 0.99, 0), half);
    const right = try rig.addBox(gpa, .dynamic, av3(3, 0.99, 0), half);
    try rig.partitionAll(gpa);

    // Two islands of one body each — and the ground is a member of neither.
    try testing.expectEqual(@as(usize, 2), rig.manager.islandsSlice().len);
    try testing.expect(rig.rankOf(left).? != rig.rankOf(right).?);
    try testing.expectEqual(@as(?u32, null), rig.rankOf(rig.ids.items[0]));

    // Each ground contact belongs to its own dynamic body's island: no constraint is
    // left unassigned, which is what would strand a resting box without its support.
    try testing.expectEqual(@as(usize, 2), rig.constraints.items.len);
    for (rig.manager.islandsSlice()) |isl| {
        try testing.expectEqual(@as(u32, 1), isl.member_to - isl.member_from);
        try testing.expectEqual(@as(u32, 1), isl.constraint_to - isl.constraint_from);
    }
    try rig.expectRangesTileTheArray();
}

test "a moving kinematic platform does not link but forces its islands awake" {
    const gpa = testing.allocator;
    var rig = Rig{};
    defer rig.deinit(gpa);
    const half = av3(unit_half, unit_half, unit_half);

    const platform = try rig.addBox(gpa, .kinematic, av3(0, 0, 0), av3(20, 0.5, 20));
    const left = try rig.addBox(gpa, .dynamic, av3(-3, 0.99, 0), half);
    const right = try rig.addBox(gpa, .dynamic, av3(3, 0.99, 0), half);
    rig.bm.setLinearVelocity(platform, Vec3r.fromArray(.{ 1, 0, 0 }));
    try rig.partitionAll(gpa);

    // No fusion through the kinematic body — it is not a member, so it links nothing.
    try testing.expectEqual(@as(usize, 2), rig.manager.islandsSlice().len);
    try testing.expect(rig.rankOf(left).? != rig.rankOf(right).?);
    try testing.expectEqual(@as(?u32, null), rig.rankOf(platform));

    // But both islands see it moving (W3). Without the flag they would show nothing
    // but eligible members and fall asleep on a support that is moving.
    for (rig.manager.islandsSlice()) |isl| try testing.expect(isl.touches_moving_non_member);

    // The flag is about MOTION, not about the body type: the same scene with the
    // platform at rest raises nothing.
    var still = Rig{};
    defer still.deinit(gpa);
    _ = try still.addBox(gpa, .kinematic, av3(0, 0, 0), av3(20, 0.5, 20));
    _ = try still.addBox(gpa, .dynamic, av3(-3, 0.99, 0), half);
    _ = try still.addBox(gpa, .dynamic, av3(3, 0.99, 0), half);
    try still.partitionAll(gpa);
    for (still.manager.islandsSlice()) |isl| try testing.expect(!isl.touches_moving_non_member);
}

test "a dynamic body with no constraint is a singleton island" {
    const gpa = testing.allocator;
    var rig = Rig{};
    defer rig.deinit(gpa);
    const half = av3(unit_half, unit_half, unit_half);

    const a = try rig.addBox(gpa, .dynamic, av3(0, 0, 0), half);
    const b = try rig.addBox(gpa, .dynamic, av3(0, 0.99, 0), half);
    const lone = try rig.addBox(gpa, .dynamic, av3(100, 0, 0), half);
    try rig.partitionAll(gpa);

    try testing.expectEqual(@as(usize, 2), rig.manager.islandsSlice().len);
    try testing.expectEqual(rig.rankOf(a).?, rig.rankOf(b).?);

    // Present in the table with an EMPTY constraint range — a first-class island that
    // can fall asleep like any other, not an absence.
    const singleton = rig.manager.islandsSlice()[rig.rankOf(lone).?];
    try testing.expectEqual(@as(u32, 1), singleton.member_to - singleton.member_from);
    try testing.expectEqual(lone, rig.manager.islandMembers(singleton)[0]);
    try testing.expectEqual(singleton.constraint_from, singleton.constraint_to);
    try rig.expectRangesTileTheArray();
}

/// Chain `L0–L1–L2` at the origin plus the pair `L3–L4` fifty metres away, with the
/// bodies created in `order` (a permutation of the five logical indices). Returns the
/// handle each logical body received.
fn buildTwoGroupScene(gpa: std.mem.Allocator, rig: *Rig, order: []const usize) ![5]BodyId {
    const half = av3(unit_half, unit_half, unit_half);
    const positions = [5]foundation.math.Vec3{
        av3(0, 0, 0),
        av3(0.99, 0, 0),
        av3(1.98, 0, 0), // 1.98 from L0 ⇒ touches L1 only
        av3(50, 0, 0),
        av3(50.99, 0, 0),
    };
    var handles: [5]BodyId = undefined;
    for (order) |logical| {
        handles[logical] = try rig.addBox(gpa, .dynamic, positions[logical], half);
    }
    return handles;
}

test "island ranks are ordered by minimum member BodyId" {
    const gpa = testing.allocator;
    var rig = Rig{};
    defer rig.deinit(gpa);
    _ = try buildTwoGroupScene(gpa, &rig, &.{ 0, 3, 4, 1, 2 });
    try rig.partitionAll(gpa);
    try testing.expect(rig.manager.islandsSlice().len >= 2);

    // Members come out ascending inside an island, so element 0 IS the minimum. Ranks
    // must be strictly increasing in it — strictly, because membership partitions the
    // awake dynamic set, so no two islands can share a minimum and no tie-break
    // exists or is needed.
    var previous_min: ?BodyId = null;
    for (rig.manager.islandsSlice()) |isl| {
        const members = rig.manager.islandMembers(isl);
        try testing.expect(members.len > 0);
        for (members[1..], 0..) |id, i| try testing.expect(members[i] < id);
        if (previous_min) |prev| try testing.expect(prev < members[0]);
        previous_min = members[0];
    }
}

test "constraint ranges are contiguous and pair-key ascending inside each island" {
    const gpa = testing.allocator;
    var rig = Rig{};
    defer rig.deinit(gpa);

    // Creation order 0,3,4,1,2 gives handles L0=0, L3=1, L4=2, L1=3, L2=4. The chain
    // is then {0,3,4} (rank 0, minimum handle 0) and the far pair {1,2} (rank 1). Its
    // point: the chain owns the constraint (3,4), whose pair key is the LARGEST of
    // the three, while (1,2) belongs to the higher-ranked island. Sorting by pair key
    // alone would interleave them; the composite key must not.
    const handles = try buildTwoGroupScene(gpa, &rig, &.{ 0, 3, 4, 1, 2 });
    try rig.partitionAll(gpa);
    try testing.expectEqual(@as(usize, 3), rig.constraints.items.len);
    try testing.expectEqual(@as(usize, 2), rig.manager.islandsSlice().len);

    // The discriminator really is present in this scene: the far pair's key sits
    // strictly between the chain's two keys.
    const chain_low = pairKey(handles[0], handles[1]);
    const chain_high = pairKey(handles[1], handles[2]);
    const far = pairKey(handles[3], handles[4]);
    try testing.expect(chain_low < far and far < chain_high);

    try rig.expectRangesTileTheArray();

    // Rank 0 holds the chain's two constraints, in ascending pair-key order, BEFORE
    // the far pair — which pure pair-key order would have placed between them.
    const first = rig.manager.islandsSlice()[0];
    try testing.expectEqual(@as(u32, 0), first.constraint_from);
    try testing.expectEqual(@as(u32, 2), first.constraint_to);
    try testing.expectEqual(chain_low, rig.constraints.items[0].pair_key);
    try testing.expectEqual(chain_high, rig.constraints.items[1].pair_key);
    try testing.expectEqual(far, rig.constraints.items[2].pair_key);

    // And the general invariant: ascending pair keys within every range, each
    // constraint really belonging to the island whose range holds it.
    for (rig.manager.islandsSlice(), 0..) |isl, rank| {
        const range = rig.constraints.items[isl.constraint_from..isl.constraint_to];
        for (range, 0..) |c, i| {
            if (i > 0) try testing.expect(range[i - 1].pair_key < c.pair_key);
            const owner = rig.rankOf(c.body_a) orelse rig.rankOf(c.body_b).?;
            try testing.expectEqual(@as(u32, @intCast(rank)), owner);
        }
    }
}

test "island partition is invariant under body add-order permutation" {
    const gpa = testing.allocator;
    // The partition — WHICH bodies are grouped together — must not depend on the
    // order the bodies were created in. Bit-exactness is NOT asserted and must not
    // be: permuting the add order changes the `BodyId`s, hence the pair keys, hence
    // the solve order.
    const expected = [5]u32{ 0, 0, 0, 3, 3 }; // {L0,L1,L2} and {L3,L4}

    var order: [5]usize = undefined;
    for (0..120) |k| {
        nthPermutation(5, k, &order);
        var rig = Rig{};
        defer rig.deinit(gpa);
        const handles = try buildTwoGroupScene(gpa, &rig, &order);
        try rig.partitionAll(gpa);

        // Canonical labelling over LOGICAL indices (handles differ per permutation):
        // each logical body is labelled with the smallest logical index sharing its
        // island.
        var labels: [5]u32 = undefined;
        for (0..5) |logical| {
            const rank = rig.rankOf(handles[logical]).?;
            var smallest: u32 = @intCast(logical);
            for (0..logical) |other| {
                if (rig.rankOf(handles[other]).? == rank) {
                    smallest = @intCast(other);
                    break;
                }
            }
            labels[logical] = smallest;
        }
        try testing.expectEqualSlices(u32, &expected, &labels);
    }
}
