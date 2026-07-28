//! Acceptance suite for `forge_3d/pipeline/broadphase.zig`.
//!
//! Grows gate by gate with M1.1.1: E1 covers `Bvh(T)` insert/remove invariants
//! and deterministic LIFO free-list reuse. Later gates add update hysteresis,
//! `queryAabb`, determinism, the layer-pair matrix, `computePairs`, and the
//! `BodyManager`→`Broadphase` integration.

const std = @import("std");
const broadphase = @import("../pipeline/broadphase.zig");
const math = @import("foundation").math;
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const body_manager_mod = @import("../body_manager.zig");
const api = @import("weld_forge");

const Aabbf = math.Aabbf;
const Vec3 = math.Vec3;
const BvhF = broadphase.Bvh(f32);
const BphF = broadphase.Broadphase(f32);
const Layer = broadphase.BroadphaseLayer;

// Real-precision aliases for the BodyManager integration test (f32 by default,
// f64 under -Dphysics_f64) — so that gate exercises the solver's actual scalar.
const Real = config.Real;
const Aabbr = config.Aabbr;
const Vec3r = config.Vec3r;
const BphR = broadphase.Broadphase(Real);

/// Unit-half-extent box centred at (x, 0, 0).
fn boxAt(x: f32) Aabbf {
    return Aabbf.fromCenterHalfExtents(Vec3.fromArray(.{ x, 0, 0 }), Vec3.splat(0.5));
}

/// Box centred at `c` with uniform half-extent `he`.
fn boxCe(c: [3]f32, he: f32) Aabbf {
    return Aabbf.fromCenterHalfExtents(Vec3.fromArray(c), Vec3.splat(he));
}

/// Whether the pair set contains the unordered pair {a, b}.
fn hasPair(pairs: []const BphF.Pair, a: u32, b: u32) bool {
    const lo = @min(a, b);
    const hi = @max(a, b);
    for (pairs) |p| {
        if (p.a == lo and p.b == hi) return true;
    }
    return false;
}

/// Assert every pair is canonical (`a < b`) and the list is strictly ascending
/// by packed key — which proves both sorted order and the absence of dups.
fn assertSortedDeduped(pairs: []const BphF.Pair) !void {
    for (pairs) |p| try std.testing.expect(p.a < p.b);
    if (pairs.len < 2) return;
    var i: usize = 1;
    while (i < pairs.len) : (i += 1) {
        const prev = (@as(u64, pairs[i - 1].a) << 32) | @as(u64, pairs[i - 1].b);
        const cur = (@as(u64, pairs[i].a) << 32) | @as(u64, pairs[i].b);
        try std.testing.expect(prev < cur);
    }
}

/// Query sink: records the `user_data` of every proxy the traversal reports.
const Collector = struct {
    items: std.ArrayListUnmanaged(u32) = .empty,
    gpa: std.mem.Allocator,

    pub fn add(self: *Collector, user_data: u32) void {
        self.items.append(self.gpa, user_data) catch @panic("collector OOM");
    }
    fn deinit(self: *Collector) void {
        self.items.deinit(self.gpa);
    }
    fn contains(self: *const Collector, user_data: u32) bool {
        return std.mem.indexOfScalar(u32, self.items.items, user_data) != null;
    }
    fn sortedOwned(self: *Collector) []u32 {
        std.mem.sort(u32, self.items.items, {}, std.sort.asc(u32));
        return self.items.items;
    }
};

test "insert N proxies keeps tree invariants" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{});
    defer tree.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(0xB2D2_A11F);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const center = Vec3.fromArray(.{
            rng.float(f32) * 100.0 - 50.0,
            rng.float(f32) * 100.0 - 50.0,
            rng.float(f32) * 100.0 - 50.0,
        });
        const he = 0.1 + rng.float(f32) * 2.0;
        _ = try tree.insert(gpa, Aabbf.fromCenterHalfExtents(center, Vec3.splat(he)), i);
        if ((i + 1) % 100 == 0) tree.validate();
    }

    tree.validate();
    try std.testing.expectEqual(@as(u32, 1000), tree.leafCount());
}

test "remove restores invariants and free-list reuse is deterministic" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{});
    defer tree.deinit(gpa);

    // Two proxies: leaf 0, leaf 1, internal root 2.
    const a = try tree.insert(gpa, boxAt(0), 100);
    const b = try tree.insert(gpa, boxAt(10), 101);
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 1), b);
    tree.validate();

    // Removing A frees the internal parent (node 2) then the leaf (node 0);
    // the free-list is LIFO, so its head is the leaf — the next insert reuses
    // index 0, and the split after it reuses index 2.
    tree.remove(a);
    tree.validate();
    try std.testing.expectEqual(@as(u32, 1), tree.leafCount());

    const c = try tree.insert(gpa, boxAt(20), 102);
    try std.testing.expectEqual(@as(u32, 0), c); // reused A's freed leaf slot
    tree.validate();
    try std.testing.expectEqual(@as(u32, 2), tree.leafCount());

    // Interleaved churn: invariants hold and the leaf census stays exact
    // through many insert/remove cycles.
    var proxies: [16]u32 = undefined;
    for (0..16) |k| {
        proxies[k] = try tree.insert(gpa, boxAt(@floatFromInt(k * 3)), @intCast(200 + k));
    }
    tree.validate();
    try std.testing.expectEqual(@as(u32, 18), tree.leafCount());

    var removed: u32 = 0;
    var k: usize = 0;
    while (k < 16) : (k += 2) {
        tree.remove(proxies[k]);
        removed += 1;
    }
    tree.validate();
    try std.testing.expectEqual(@as(u32, 18 - 8), tree.leafCount());

    var j: u32 = 0;
    while (j < removed) : (j += 1) {
        _ = try tree.insert(gpa, boxAt(@floatFromInt(300 + j)), 400 + j);
    }
    tree.validate();
    try std.testing.expectEqual(@as(u32, 18), tree.leafCount());
}

test "validate holds through heavy insert/remove churn and re-emptying" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{});
    defer tree.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(0x5EED_1111);
    const rng = prng.random();

    var live: std.ArrayListUnmanaged(u32) = .empty;
    defer live.deinit(gpa);

    // Randomised churn: insert when empty or on a coin flip, else remove a
    // random live proxy. Invariants must hold after every single op, and the
    // leaf census must track the live set exactly.
    var op: u32 = 0;
    while (op < 4000) : (op += 1) {
        if (live.items.len == 0 or rng.boolean()) {
            const center = Vec3.fromArray(.{
                rng.float(f32) * 200 - 100,
                rng.float(f32) * 200 - 100,
                rng.float(f32) * 200 - 100,
            });
            const he = 0.05 + rng.float(f32) * 3.0;
            const p = try tree.insert(gpa, Aabbf.fromCenterHalfExtents(center, Vec3.splat(he)), op);
            try live.append(gpa, p);
        } else {
            const idx = rng.intRangeLessThan(usize, 0, live.items.len);
            tree.remove(live.swapRemove(idx));
        }
        tree.validate();
        try std.testing.expectEqual(@as(u32, @intCast(live.items.len)), tree.leafCount());
    }

    // Drain to empty — exercises the remove-root and single-leaf paths.
    while (live.items.len > 0) {
        tree.remove(live.pop().?);
        tree.validate();
    }
    try std.testing.expectEqual(@as(i32, -1), tree.height());
    try std.testing.expectEqual(@as(u32, 0), tree.leafCount());

    // Re-inserting after emptying returns to a valid single-leaf tree.
    const again = try tree.insert(gpa, boxAt(0), 7);
    tree.validate();
    try std.testing.expectEqual(@as(u32, 1), tree.leafCount());
    try std.testing.expectEqual(@as(i32, 0), tree.height());
    tree.remove(again);
    tree.validate();
    try std.testing.expectEqual(@as(i32, -1), tree.height());
}

test "update hysteresis" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0.1 });
    defer tree.deinit(gpa);

    // A few anchors plus the proxy we move. Anchors keep the tree non-trivial
    // so `update` actually exercises removeLeaf + insertLeaf (not just re-root).
    _ = try tree.insert(gpa, boxCe(.{ 20, 0, 0 }, 0.5), 1);
    _ = try tree.insert(gpa, boxCe(.{ -20, 0, 0 }, 0.5), 2);
    _ = try tree.insert(gpa, boxCe(.{ 0, 20, 0 }, 0.5), 3);
    const p = try tree.insert(gpa, boxCe(.{ 0, 0, 0 }, 0.5), 42); // fat [-0.6, 0.6]^3
    tree.validate();

    // Move within the margin: tight [-0.45, 0.55]^3 stays inside the fat box.
    try std.testing.expect(!tree.update(p, boxCe(.{ 0.05, 0, 0 }, 0.5)));
    tree.validate();
    try std.testing.expectEqual(@as(u32, 4), tree.leafCount());
    {
        // Still found at the original location; not at a far one.
        var c = Collector{ .gpa = gpa };
        defer c.deinit();
        _ = tree.queryAabb(boxCe(.{ 0, 0, 0 }, 0.1), &c);
        try std.testing.expect(c.contains(42));
    }

    // Move beyond the margin: tight [4.5, 5.5]×… exits the fat box → re-insert.
    try std.testing.expect(tree.update(p, boxCe(.{ 5, 0, 0 }, 0.5)));
    tree.validate();
    try std.testing.expectEqual(@as(u32, 4), tree.leafCount());
    {
        var at_new = Collector{ .gpa = gpa };
        defer at_new.deinit();
        _ = tree.queryAabb(boxCe(.{ 5, 0, 0 }, 0.1), &at_new);
        try std.testing.expect(at_new.contains(42));

        var at_old = Collector{ .gpa = gpa };
        defer at_old.deinit();
        _ = tree.queryAabb(boxCe(.{ 0, 0, 0 }, 0.1), &at_old);
        try std.testing.expect(!at_old.contains(42)); // it moved away
    }
}

test "queryAabb matches brute force" {
    const gpa = std.testing.allocator;
    // margin 0 → stored box == tight box, so the brute-force reference is a
    // plain `overlaps` scan (the face-inclusive convention, brief trap note).
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    const Proxy = struct { ud: u32, box: Aabbf };
    var proxies: std.ArrayListUnmanaged(Proxy) = .empty;
    defer proxies.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(0x0A11_CE55);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const box = boxCe(.{
            rng.float(f32) * 100 - 50,
            rng.float(f32) * 100 - 50,
            rng.float(f32) * 100 - 50,
        }, 0.2 + rng.float(f32) * 2.0);
        _ = try tree.insert(gpa, box, i);
        try proxies.append(gpa, .{ .ud = i, .box = box });
    }
    tree.validate();

    const queries = [_]Aabbf{
        boxCe(.{ 0, 0, 0 }, 10),
        boxCe(.{ 25, -25, 10 }, 5),
        boxCe(.{ -40, 40, -40 }, 15),
        boxCe(.{ 0, 0, 0 }, 60), // covers the whole cloud
        boxCe(.{ 200, 200, 200 }, 1), // empty region
    };

    for (queries) |q| {
        var got = Collector{ .gpa = gpa };
        defer got.deinit();
        _ = tree.queryAabb(q, &got);

        var want: std.ArrayListUnmanaged(u32) = .empty;
        defer want.deinit(gpa);
        for (proxies.items) |pr| {
            if (pr.box.overlaps(q)) try want.append(gpa, pr.ud);
        }

        std.mem.sort(u32, want.items, {}, std.sort.asc(u32));
        try std.testing.expectEqualSlices(u32, want.items, got.sortedOwned());
    }
}

test "query cost is logarithmic" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    // 20 × 20 × 25 = 10 000 unit boxes on a grid, spaced 2 apart (disjoint).
    var ud: u32 = 0;
    for (0..20) |x| {
        for (0..20) |y| {
            for (0..25) |z| {
                const c = [3]f32{
                    @as(f32, @floatFromInt(x)) * 2,
                    @as(f32, @floatFromInt(y)) * 2,
                    @as(f32, @floatFromInt(z)) * 2,
                };
                _ = try tree.insert(gpa, boxCe(c, 0.5), ud);
                ud += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 10000), tree.leafCount());
    tree.validate();

    // A single-cell query (the box at the origin) touches only a logarithmic
    // slice of the tree. Generous c·log2(n) bound.
    var c = Collector{ .gpa = gpa };
    defer c.deinit();
    const visited = tree.queryAabb(boxCe(.{ 0, 0, 0 }, 0.5), &c);
    try std.testing.expect(visited <= 128);
    // The origin cell overlaps only its own box (id 0); neighbours are 2 apart.
    try std.testing.expectEqualSlices(u32, &.{0}, c.sortedOwned());
}

/// Deterministic op sequence (insert / update / remove) used to prove two
/// independently-built trees end in identical state.
fn runOps(gpa: std.mem.Allocator, tree: *BvhF) !void {
    var prng = std.Random.DefaultPrng.init(0xD37E_3311);
    const rng = prng.random();
    var live: std.ArrayListUnmanaged(u32) = .empty;
    defer live.deinit(gpa);

    var op: u32 = 0;
    while (op < 2000) : (op += 1) {
        const r = rng.float(f32);
        if (live.items.len == 0 or r < 0.5) {
            const box = boxCe(.{
                rng.float(f32) * 100 - 50,
                rng.float(f32) * 100 - 50,
                rng.float(f32) * 100 - 50,
            }, 0.2 + rng.float(f32) * 2.0);
            const p = try tree.insert(gpa, box, op);
            try live.append(gpa, p);
        } else if (r < 0.8) {
            const idx = rng.intRangeLessThan(usize, 0, live.items.len);
            const box = boxCe(.{
                rng.float(f32) * 100 - 50,
                rng.float(f32) * 100 - 50,
                rng.float(f32) * 100 - 50,
            }, 0.2 + rng.float(f32) * 2.0);
            _ = tree.update(live.items[idx], box);
        } else {
            const idx = rng.intRangeLessThan(usize, 0, live.items.len);
            tree.remove(live.swapRemove(idx));
        }
    }
}

test "identical op sequences produce identical trees and query results" {
    const gpa = std.testing.allocator;
    var a = BvhF.init(.{});
    defer a.deinit(gpa);
    var b = BvhF.init(.{});
    defer b.deinit(gpa);

    try runOps(gpa, &a);
    try runOps(gpa, &b);
    a.validate();
    b.validate();

    // Identical tree state: same pool, roots, free-list, and node-by-node.
    try std.testing.expectEqual(a.nodes.items.len, b.nodes.items.len);
    try std.testing.expectEqual(a.root, b.root);
    try std.testing.expectEqual(a.free_list, b.free_list);
    try std.testing.expectEqual(a.leaf_count, b.leaf_count);
    for (a.nodes.items, b.nodes.items) |na, nb| {
        try std.testing.expectEqual(na.height, nb.height);
        try std.testing.expectEqual(na.parent, nb.parent);
        if (na.height == -1) continue; // free slot: only the link matters
        try std.testing.expectEqual(na.child1, nb.child1);
        try std.testing.expectEqual(na.child2, nb.child2);
        try std.testing.expectEqual(na.user_data, nb.user_data);
        try std.testing.expect(na.aabb.min.eql(nb.aabb.min));
        try std.testing.expect(na.aabb.max.eql(nb.aabb.max));
    }

    // Identical query results across several boxes.
    const queries = [_]Aabbf{
        boxCe(.{ 0, 0, 0 }, 20),
        boxCe(.{ 30, 30, 30 }, 10),
        boxCe(.{ -25, 10, -5 }, 8),
    };
    for (queries) |q| {
        var ca = Collector{ .gpa = gpa };
        defer ca.deinit();
        var cb = Collector{ .gpa = gpa };
        defer cb.deinit();
        const va = a.queryAabb(q, &ca);
        const vb = b.queryAabb(q, &cb);
        try std.testing.expectEqual(va, vb);
        try std.testing.expectEqualSlices(u32, ca.sortedOwned(), cb.sortedOwned());
    }
}

test "layer-pair matrix filters pairs" {
    const gpa = std.testing.allocator;
    var bph = BphF.init(.{ .margin = 0 });
    defer bph.deinit(gpa);

    // Two proxies per layer, all identical boxes at the origin → all overlap,
    // so only the layer-pair matrix decides which pairs appear.
    const box = boxCe(.{ 0, 0, 0 }, 1);
    _ = try bph.insert(gpa, .static, box, 10);
    _ = try bph.insert(gpa, .static, box, 11);
    _ = try bph.insert(gpa, .dynamic, box, 20);
    _ = try bph.insert(gpa, .dynamic, box, 21);
    _ = try bph.insert(gpa, .debris, box, 30);
    _ = try bph.insert(gpa, .debris, box, 31);
    _ = try bph.insert(gpa, .trigger, box, 40);
    _ = try bph.insert(gpa, .trigger, box, 41);

    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);
    try bph.computePairs(gpa, &pairs);
    try assertSortedDeduped(pairs.items);

    // Allowed combinations present.
    try std.testing.expect(hasPair(pairs.items, 20, 21)); // dynamic × dynamic
    try std.testing.expect(hasPair(pairs.items, 10, 20)); // static × dynamic
    try std.testing.expect(hasPair(pairs.items, 10, 30)); // static × debris
    try std.testing.expect(hasPair(pairs.items, 20, 30)); // dynamic × debris
    try std.testing.expect(hasPair(pairs.items, 20, 40)); // dynamic × trigger

    // Forbidden combinations absent.
    try std.testing.expect(!hasPair(pairs.items, 10, 11)); // static × static
    try std.testing.expect(!hasPair(pairs.items, 30, 31)); // debris × debris
    try std.testing.expect(!hasPair(pairs.items, 40, 41)); // trigger × trigger
    try std.testing.expect(!hasPair(pairs.items, 10, 40)); // static × trigger
    try std.testing.expect(!hasPair(pairs.items, 30, 40)); // debris × trigger
}

test "computePairs matches brute force multi-layer" {
    const gpa = std.testing.allocator;
    var bph = BphF.init(.{ .margin = 0 }); // fat == tight → reference is a plain overlaps scan
    defer bph.deinit(gpa);

    const Rec = struct { ud: u32, layer: Layer, box: Aabbf };
    var recs: std.ArrayListUnmanaged(Rec) = .empty;
    defer recs.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(0xBEEF_F00D);
    const rng = prng.random();
    const nlayers: u8 = broadphase.layer_count;

    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const layer: Layer = @enumFromInt(rng.uintLessThan(u8, nlayers));
        const bx = boxCe(.{
            rng.float(f32) * 30 - 15,
            rng.float(f32) * 30 - 15,
            rng.float(f32) * 30 - 15,
        }, 0.5 + rng.float(f32) * 2.0);
        _ = try bph.insert(gpa, layer, bx, i);
        try recs.append(gpa, .{ .ud = i, .layer = layer, .box = bx });
    }

    var got: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer got.deinit(gpa);
    try bph.computePairs(gpa, &got);
    try assertSortedDeduped(got.items);

    // O(n²) reference: same matrix, face-inclusive `overlaps`, canonical key.
    var want: std.ArrayListUnmanaged(u64) = .empty;
    defer want.deinit(gpa);
    for (recs.items, 0..) |ri, ii| {
        for (recs.items[ii + 1 ..]) |rj| {
            if (!broadphase.default_layer_pairs[@intFromEnum(ri.layer)][@intFromEnum(rj.layer)]) continue;
            if (!ri.box.overlaps(rj.box)) continue;
            const a = @min(ri.ud, rj.ud);
            const b = @max(ri.ud, rj.ud);
            try want.append(gpa, (@as(u64, a) << 32) | @as(u64, b));
        }
    }
    std.mem.sort(u64, want.items, {}, std.sort.asc(u64));

    var got_keys: std.ArrayListUnmanaged(u64) = .empty;
    defer got_keys.deinit(gpa);
    for (got.items) |p| try got_keys.append(gpa, (@as(u64, p.a) << 32) | @as(u64, p.b));

    try std.testing.expect(got.items.len > 0); // non-vacuous
    try std.testing.expectEqualSlices(u64, want.items, got_keys.items);
}

/// Deterministic multi-layer op sequence (insert / update / remove across all
/// four layers) used to prove `computePairs` is a pure function of the ops.
fn runBph(gpa: std.mem.Allocator, bph: *BphF) !void {
    var prng = std.Random.DefaultPrng.init(0xC0DE_5EED);
    const rng = prng.random();
    const nlayers: u8 = broadphase.layer_count;
    var live: std.ArrayListUnmanaged(BphF.Proxy) = .empty;
    defer live.deinit(gpa);

    var op: u32 = 0;
    while (op < 1500) : (op += 1) {
        const r = rng.float(f32);
        if (live.items.len == 0 or r < 0.5) {
            const layer: Layer = @enumFromInt(rng.uintLessThan(u8, nlayers));
            const bx = boxCe(.{
                rng.float(f32) * 30 - 15,
                rng.float(f32) * 30 - 15,
                rng.float(f32) * 30 - 15,
            }, 0.5 + rng.float(f32) * 2.0);
            const p = try bph.insert(gpa, layer, bx, op);
            try live.append(gpa, p);
        } else if (r < 0.8) {
            const idx = rng.intRangeLessThan(usize, 0, live.items.len);
            const bx = boxCe(.{
                rng.float(f32) * 30 - 15,
                rng.float(f32) * 30 - 15,
                rng.float(f32) * 30 - 15,
            }, 0.5 + rng.float(f32) * 2.0);
            try bph.update(gpa, live.items[idx], bx);
        } else {
            const idx = rng.intRangeLessThan(usize, 0, live.items.len);
            bph.remove(live.swapRemove(idx));
        }
    }
}

test "computePairs is deterministic across identical op sequences" {
    const gpa = std.testing.allocator;
    var a = BphF.init(.{ .margin = 0.1 });
    defer a.deinit(gpa);
    var b = BphF.init(.{ .margin = 0.1 });
    defer b.deinit(gpa);

    try runBph(gpa, &a);
    try runBph(gpa, &b);

    var pa: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pa.deinit(gpa);
    var pb: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pb.deinit(gpa);
    try a.computePairs(gpa, &pa);
    try b.computePairs(gpa, &pb);

    try assertSortedDeduped(pa.items);
    try assertSortedDeduped(pb.items);
    try std.testing.expect(pa.items.len > 0); // non-vacuous
    try std.testing.expectEqual(pa.items.len, pb.items.len);
    for (pa.items, pb.items) |x, y| {
        try std.testing.expectEqual(x.a, y.a);
        try std.testing.expectEqual(x.b, y.b);
    }
}

/// Small query cell (half-extent 0.1) at solver precision.
fn cell(x: Real, y: Real, z: Real) Aabbr {
    return Aabbr.fromCenterHalfExtents(Vec3r.fromArray(.{ x, y, z }), Vec3r.splat(0.1));
}

/// Run a `Broadphase(Real)` query and assert the collected ids equal
/// `expected_sorted` (which must be ascending).
fn expectQueryIds(gpa: std.mem.Allocator, bph: *const BphR, query: Aabbr, expected_sorted: []const u32) !void {
    var c = Collector{ .gpa = gpa };
    defer c.deinit();
    _ = bph.queryAabb(query, &c);
    try std.testing.expectEqualSlices(u32, expected_sorted, c.sortedOwned());
}

test "BodyManager to Broadphase integration" {
    const gpa = std.testing.allocator;
    var store = shape_mod.ShapeStore{};
    defer store.deinit(gpa);
    var bm = body_manager_mod.BodyManager{};
    defer bm.deinit(gpa);
    var bph = BphR.init(.{ .margin = 0 }); // fat == tight ⇒ exact query matching
    defer bph.deinit(gpa);

    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    // Mixed body types at distinct, well-separated positions (spheres r=0.5,
    // 10 m apart, so a small cell query hits exactly one).
    const Spec = struct { pos: [3]f32, bt: api.BodyType };
    const specs = [_]Spec{
        .{ .pos = .{ 0, 0, 0 }, .bt = .static },
        .{ .pos = .{ 10, 0, 0 }, .bt = .dynamic },
        .{ .pos = .{ 20, 0, 0 }, .bt = .kinematic },
        .{ .pos = .{ 0, 10, 0 }, .bt = .dynamic },
        .{ .pos = .{ 10, 10, 0 }, .bt = .static },
    };

    var ids: [specs.len]api.BodyId = undefined;
    for (specs, 0..) |s, i| {
        var d = api.BodyDescriptor{
            .entity = .{ .index = @intCast(i), .generation = 0 },
            .body_type = s.bt,
            .shape = sphere,
        };
        d.position = Vec3.fromArray(s.pos);
        const id = try bm.addBody(gpa, &store, d);
        ids[i] = id;
        // body_type → layer: static → .static, dynamic/kinematic → .dynamic.
        const layer: Layer = switch (s.bt) {
            .static => .static,
            .dynamic, .kinematic => .dynamic,
        };
        const aabb = bm.bodyAabb(&store, id).?; // exact world AABB from the manager
        _ = try bph.insert(gpa, layer, aabb, id); // user_data = packed BodyId
    }

    // Single-cell queries return exactly the body at that cell — including the
    // kinematic one (in the .dynamic layer) since the query spans all layers.
    try expectQueryIds(gpa, &bph, cell(10, 0, 0), &.{ids[1]});
    try expectQueryIds(gpa, &bph, cell(0, 0, 0), &.{ids[0]});
    try expectQueryIds(gpa, &bph, cell(20, 0, 0), &.{ids[2]});

    // A box spanning (10,0,0) and (10,10,0) returns both across layers
    // (dynamic ids[1] + static ids[4]).
    {
        const q = Aabbr.fromMinMax(Vec3r.fromArray(.{ 9, -1, -1 }), Vec3r.fromArray(.{ 11, 11, 1 }));
        var expected = [_]u32{ ids[1], ids[4] };
        std.mem.sort(u32, &expected, {}, std.sort.asc(u32));
        try expectQueryIds(gpa, &bph, q, &expected);
    }

    // A box covering the whole scene returns all five ids.
    {
        const q = Aabbr.fromMinMax(Vec3r.splat(-5), Vec3r.fromArray(.{ 25, 15, 5 }));
        var expected = ids;
        std.mem.sort(u32, &expected, {}, std.sort.asc(u32));
        try expectQueryIds(gpa, &bph, q, &expected);
    }
}

test "insert is atomic under allocation failure (no orphan leaf)" {
    const dyn: usize = @intFromEnum(Layer.dynamic);
    const attempts = 24;
    // Sweep the failing allocation index across an insert batch. The moved-log
    // grows from empty and the Bvh node pool grows too, so every allocation
    // site is exercised. Whatever fails, the tree must hold EXACTLY the proxies
    // the caller received — never a half-inserted orphan (leaf in the tree but
    // no `Proxy` returned, hence unremovable and invisible to `computePairs`).
    var fail_index: usize = 0;
    while (fail_index < 400) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var bph = BphF.init(.{ .margin = 0 });
        defer bph.deinit(gpa);

        // Track only the proxies actually returned (this list uses the real
        // allocator, so it never fails).
        var ids: std.ArrayListUnmanaged(u32) = .empty;
        defer ids.deinit(std.testing.allocator);

        var oom = false;
        var i: u32 = 0;
        while (i < attempts) : (i += 1) {
            const proxy = bph.insert(gpa, .dynamic, boxCe(.{ @floatFromInt(i * 3), 0, 0 }, 0.5), i) catch |e| {
                try std.testing.expectEqual(error.OutOfMemory, e);
                oom = true;
                break;
            };
            try ids.append(std.testing.allocator, proxy.id);
        }

        // No orphan: dynamic-tree leaf count == the proxies the caller holds.
        try std.testing.expectEqual(@as(u32, @intCast(ids.items.len)), bph.trees[dyn].leafCount());

        // And a whole-region query returns exactly those ids (an orphan leaf
        // would surface here as an extra hit).
        var c = Collector{ .gpa = std.testing.allocator };
        defer c.deinit();
        _ = bph.queryAabb(Aabbf.fromMinMax(Vec3.splat(-1), Vec3.fromArray(.{ attempts * 3, 1, 1 })), &c);
        try std.testing.expectEqual(ids.items.len, c.items.items.len);

        if (!oom) break; // reached the all-succeed index — sweep is complete
    }
}

test "update is atomic under allocation failure (no hysteresis poisoning)" {
    const gpa = std.testing.allocator;
    const dyn: usize = @intFromEnum(Layer.dynamic);

    var bph = BphF.init(.{ .margin = 0.1 });
    defer bph.deinit(gpa);

    // Stationary pair target (ud 3), the proxy under test p @ origin (ud 2),
    // and a filler (ud 1) shuttled to consume the moved-log's capacity.
    _ = try bph.insert(gpa, .dynamic, boxCe(.{ 100, 0, 0 }, 0.5), 3);
    const p = try bph.insert(gpa, .dynamic, boxCe(.{ 0, 0, 0 }, 0.5), 2);
    const filler = try bph.insert(gpa, .dynamic, boxCe(.{ -100, 0, 0 }, 0.5), 1);

    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);
    try bph.computePairs(gpa, &pairs); // drain the moved-log (capacity retained)

    // Fill the moved-log back to exactly capacity by shuttling the filler
    // between two far cells (each move exits its fat box ⇒ re-insert ⇒ mark).
    // p stays at the origin. The NEXT mark then has to grow the log — the
    // allocation the failing update will hit.
    var at_a = true;
    var guard: usize = 0;
    while (bph.moved[dyn].items.len < bph.moved[dyn].capacity and guard < 256) : (guard += 1) {
        const fx: f32 = if (at_a) -200 else -100;
        try bph.update(gpa, filler, boxCe(.{ fx, 0, 0 }, 0.5));
        at_a = !at_a;
    }
    try std.testing.expectEqual(bph.moved[dyn].capacity, bph.moved[dyn].items.len); // log is full

    // Failing update on p: the log grow is the sole fallible op and (with the
    // fix) precedes the allocation-free tree re-insert, so p must stay put.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, bph.update(failing.allocator(), p, boxCe(.{ 50, 0, 0 }, 0.5)));

    // Anti-poisoning: p is still queryable at the origin, NOT at the target.
    {
        var at_old = Collector{ .gpa = gpa };
        defer at_old.deinit();
        _ = bph.queryAabb(boxCe(.{ 0, 0, 0 }, 0.1), &at_old);
        try std.testing.expect(at_old.contains(2));

        var at_new = Collector{ .gpa = gpa };
        defer at_new.deinit();
        _ = bph.queryAabb(boxCe(.{ 50, 0, 0 }, 0.1), &at_new);
        try std.testing.expect(!at_new.contains(2));
    }

    // Retry with a healthy allocator: p moves onto the target, and `computePairs`
    // reports (2,3) — the move was NOT lost to hysteresis poisoning.
    try bph.update(gpa, p, boxCe(.{ 100, 0, 0 }, 0.5));
    pairs.clearRetainingCapacity();
    try bph.computePairs(gpa, &pairs);
    try std.testing.expect(hasPair(pairs.items, 2, 3));
}

// ---------------------------------------------------------------------------
// M1.1.9 / E2 — ray traversal (`queryRay`)
// ---------------------------------------------------------------------------

/// Ray sink over a scene whose `user_data` IS its index into `boxes`, so the
/// collector can resolve a candidate's box and turn it into a distance — the
/// stand-in, at broadphase level, for the exact kernel E4 will call.
///
/// `tighten` selects the two selection modes this gate can express: a `closest`
/// collector that lowers its bound on every accepted candidate, and an `all`
/// collector that never does.
const RayCollector = struct {
    gpa: std.mem.Allocator,
    boxes: []const Aabbf,
    ray: BvhF.RayT,
    tighten: bool,

    items: std.ArrayListUnmanaged(u32) = .empty,
    bound: f32 = std.math.inf(f32),
    best_distance: f32 = std.math.inf(f32),
    best_ud: ?u32 = null,

    pub fn add(self: *RayCollector, user_data: u32) void {
        self.items.append(self.gpa, user_data) catch @panic("collector OOM");
        const iv = self.boxes[user_data].rayInterval(self.ray.origin, self.ray.inv_dir, self.ray.dir_is_zero) orelse
            return; // a fat-box candidate the exact test rejects
        const distance = @max(iv.enter, 0); // origin inside → distance zero
        if (distance < self.best_distance) {
            self.best_distance = distance;
            self.best_ud = user_data;
            if (self.tighten) self.bound = distance;
        }
    }

    pub fn maxDistance(self: *const RayCollector) f32 {
        return self.bound;
    }

    /// Part of the required contract, like `maxDistance`. This collector expresses
    /// `closest` and `all`, neither of which stops early; the terminating `any`
    /// behaviour is exercised by `StoppingRayCollector` below.
    pub fn shouldStop(_: *const RayCollector) bool {
        return false;
    }

    fn deinit(self: *RayCollector) void {
        self.items.deinit(self.gpa);
    }
    fn sortedOwned(self: *RayCollector) []u32 {
        std.mem.sort(u32, self.items.items, {}, std.sort.asc(u32));
        return self.items.items;
    }
};

test "queryRay collects every proxy the ray crosses" {
    const gpa = std.testing.allocator;
    // margin 0 → stored box == tight box, so the brute-force reference is the
    // same slab predicate over every leaf.
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    var boxes: std.ArrayListUnmanaged(Aabbf) = .empty;
    defer boxes.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(0x2A11_D0C5);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < 800) : (i += 1) {
        const box = boxCe(.{
            rng.float(f32) * 60 - 30,
            rng.float(f32) * 60 - 30,
            rng.float(f32) * 60 - 30,
        }, 0.3 + rng.float(f32) * 1.5);
        _ = try tree.insert(gpa, box, i);
        try boxes.append(gpa, box);
    }
    tree.validate();

    const rays = [_]BvhF.RayT{
        BvhF.RayT.init(Vec3.fromArray(.{ -50, 0, 0 }), Vec3.unit_x), // axis-aligned, zero lanes
        BvhF.RayT.init(Vec3.fromArray(.{ -50, -50, -50 }), Vec3.one), // full diagonal
        BvhF.RayT.init(Vec3.zero, Vec3.fromArray(.{ 1, 2, -3 })), // from inside the cloud
        BvhF.RayT.init(Vec3.fromArray(.{ -50, 100, 0 }), Vec3.unit_x), // misses everything
        BvhF.RayT.init(Vec3.fromArray(.{ 50, 0, 0 }), Vec3.unit_x.neg()), // reversed
    };

    for (rays) |ray| {
        var got = RayCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .tighten = false };
        defer got.deinit();
        _ = tree.queryRay(ray, &got);

        var want: std.ArrayListUnmanaged(u32) = .empty;
        defer want.deinit(gpa);
        for (boxes.items, 0..) |box, ud| {
            const iv = box.rayInterval(ray.origin, ray.inv_dir, ray.dir_is_zero) orelse continue;
            if (iv.exit >= 0) try want.append(gpa, @intCast(ud));
        }

        std.mem.sort(u32, want.items, {}, std.sort.asc(u32));
        try std.testing.expectEqualSlices(u32, want.items, got.sortedOwned());
    }
}

test "queryRay prunes with the collector bound" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    // A line of 200 unit boxes along +X, spaced 4 apart, inserted FAR-TO-NEAR so
    // the tree's child order and the ray's near order genuinely disagree.
    var boxes: std.ArrayListUnmanaged(Aabbf) = .empty;
    defer boxes.deinit(gpa);
    try boxes.resize(gpa, 200);
    var ud: u32 = 200;
    while (ud > 0) {
        ud -= 1;
        const box = boxCe(.{ @as(f32, @floatFromInt(ud)) * 4, 0, 0 }, 0.5);
        boxes.items[ud] = box;
        _ = try tree.insert(gpa, box, ud);
    }
    tree.validate();

    const ray = BvhF.RayT.init(Vec3.fromArray(.{ -10, 0, 0 }), Vec3.unit_x);

    var all = RayCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .tighten = false };
    defer all.deinit();
    const visited_all = tree.queryRay(ray, &all);

    var closest = RayCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .tighten = true };
    defer closest.deinit();
    const visited_closest = tree.queryRay(ray, &closest);

    // DISCRIMINATION GUARD. Without this the test would pass on a traversal that
    // ignores `maxDistance()` entirely: both runs would return the same count and
    // agree on the winner, and nothing would be proven. The strict `<` is the
    // assertion AND the guard — it fails if the bound prunes nothing.
    //
    // MEASURED, by disabling each mechanism in turn: near-first + bound gives
    // 399 visited / 17 visited / 1 candidate. Forcing child1-first (the boxes
    // being inserted far-to-near, `child1` is then the far side) gives
    // 399 / 399 / 200 — the bound tightens only after everything has been
    // visited, so pruning vanishes and this line fails. This test therefore pins
    // BOTH the bound re-read and the near-first order, not just the former.
    try std.testing.expect(visited_closest < visited_all);

    // Pruning must not change the answer.
    try std.testing.expectEqual(all.best_ud, closest.best_ud);
    try std.testing.expectEqual(@as(?u32, 0), closest.best_ud);
    try std.testing.expectEqual(all.best_distance, closest.best_distance);

    // The `all` collector really did see the whole line — otherwise "strictly
    // fewer" would be measuring two prunings against each other.
    try std.testing.expectEqual(@as(usize, 200), all.items.items.len);
    try std.testing.expect(closest.items.items.len < all.items.items.len);
}

test "queryRay treats the collector bound as closed" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    // One box entered at exactly t == 10 for a unit ray from the origin.
    const box = Aabbf.fromMinMax(Vec3.fromArray(.{ 10, -1, -1 }), Vec3.fromArray(.{ 12, 1, 1 }));
    _ = try tree.insert(gpa, box, 0);
    const boxes = [_]Aabbf{box};
    const ray = BvhF.RayT.init(Vec3.zero, Vec3.unit_x);

    // A collector bounded exactly at the entry parameter still receives it.
    var at_bound = RayCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .tighten = false, .bound = 10 };
    defer at_bound.deinit();
    _ = tree.queryRay(ray, &at_bound);
    try std.testing.expectEqualSlices(u32, &.{0}, at_bound.sortedOwned());

    // One ulp below the entry parameter, it does not.
    var below = RayCollector{
        .gpa = gpa,
        .boxes = &boxes,
        .ray = ray,
        .tighten = false,
        .bound = @bitCast(@as(u32, @bitCast(@as(f32, 10))) - 1),
    };
    defer below.deinit();
    _ = tree.queryRay(ray, &below);
    try std.testing.expectEqual(@as(usize, 0), below.items.items.len);
}

test "queryRay visits all four layer trees" {
    const gpa = std.testing.allocator;
    var bph = BphF.init(.{ .margin = 0 });
    defer bph.deinit(gpa);

    // One proxy per layer, all on the +X axis at increasing distance. A query has
    // no second body, so the layer-pair matrix does not apply and all four must
    // come back — `static × static` and `trigger × trigger` being forbidden for
    // PAIRS is irrelevant here.
    var boxes: [broadphase.layer_count]Aabbf = undefined;
    for (0..broadphase.layer_count) |i| {
        boxes[i] = boxCe(.{ @as(f32, @floatFromInt(i)) * 10 + 5, 0, 0 }, 1);
    }
    _ = try bph.insert(gpa, .static, boxes[0], 0);
    _ = try bph.insert(gpa, .dynamic, boxes[1], 1);
    _ = try bph.insert(gpa, .debris, boxes[2], 2);
    _ = try bph.insert(gpa, .trigger, boxes[3], 3);

    const ray = BphF.RayT.init(Vec3.zero, Vec3.unit_x);
    var got = RayCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .tighten = false };
    defer got.deinit();
    const visited = bph.queryRay(ray, &got);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, got.sortedOwned());
    try std.testing.expect(visited >= broadphase.layer_count); // every tree entered

    // The bound carries ACROSS the trees: a closest collector keeps only the
    // nearest of the four and reports the static one, whatever the tree order.
    var closest = RayCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .tighten = true };
    defer closest.deinit();
    _ = bph.queryRay(ray, &closest);
    try std.testing.expectEqual(@as(?u32, 0), closest.best_ud);
}

test "queryRay is empty on an empty tree" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    const boxes = [_]Aabbf{};
    const ray = BvhF.RayT.init(Vec3.zero, Vec3.unit_x);
    var got = RayCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .tighten = false };
    defer got.deinit();

    try std.testing.expectEqual(@as(u32, 0), tree.queryRay(ray, &got));
    try std.testing.expectEqual(@as(usize, 0), got.items.items.len);

    // Same on the multi-layer aggregate, whose four trees are all empty.
    var bph = BphF.init(.{ .margin = 0 });
    defer bph.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), bph.queryRay(ray, &got));
    try std.testing.expectEqual(@as(usize, 0), got.items.items.len);
}

/// Build a `side³` grid of unit boxes spaced 2 apart, `user_data == index`, and
/// return the boxes. Used by the logarithmic-cost test at two decades of size.
fn buildGrid(gpa: std.mem.Allocator, tree: *BvhF, boxes: *std.ArrayListUnmanaged(Aabbf), side: usize) !void {
    var ud: u32 = 0;
    for (0..side) |x| {
        for (0..side) |y| {
            for (0..side) |z| {
                const box = boxCe(.{
                    @as(f32, @floatFromInt(x)) * 2,
                    @as(f32, @floatFromInt(y)) * 2,
                    @as(f32, @floatFromInt(z)) * 2,
                }, 0.5);
                _ = try tree.insert(gpa, box, ud);
                try boxes.append(gpa, box);
                ud += 1;
            }
        }
    }
}

test "queryRay node count grows logarithmically" {
    const gpa = std.testing.allocator;

    // A decade apart: 10³ = 1 000 and 22³ = 10 648 proxies.
    const sides = [_]usize{ 10, 22 };
    var visited_at: [sides.len]u32 = undefined;
    var counts: [sides.len]usize = undefined;

    for (sides, 0..) |side, k| {
        var tree = BvhF.init(.{ .margin = 0 });
        defer tree.deinit(gpa);
        var boxes: std.ArrayListUnmanaged(Aabbf) = .empty;
        defer boxes.deinit(gpa);
        try buildGrid(gpa, &tree, &boxes, side);
        counts[k] = boxes.items.len;

        // Closest-hit along −X into the row y = z = 0, from beyond the far end:
        // the tightening bound is what keeps the traversal off the rest of the
        // grid, so this measures branch and bound, not a plain slab filter.
        const far = @as(f32, @floatFromInt(side)) * 2 + 10;
        const ray = BvhF.RayT.init(Vec3.fromArray(.{ far, 0, 0 }), Vec3.unit_x.neg());
        var closest = RayCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .tighten = true };
        defer closest.deinit();
        visited_at[k] = tree.queryRay(ray, &closest);

        // It found the nearest box on that row: the last cell of the x range.
        try std.testing.expectEqual(@as(?u32, @intCast((side - 1) * side * side)), closest.best_ud);

        // Generous c·log2(n) envelope, same shape as the `queryAabb` cost test.
        // MEASURED: 31 nodes at n = 1 000 and 29 at n = 10 648 with near-first,
        // against 99 and 273 when the order is forced to child1-first — the
        // second of which breaks this envelope. So this test pins the near-first
        // descent at scale, and the envelope is not vacuous.
        const log2n = std.math.log2(@as(f32, @floatFromInt(counts[k])));
        const envelope: u32 = @intFromFloat(@ceil(log2n * 12));
        try std.testing.expect(visited_at[k] <= envelope);
    }

    // Ten times the proxies must not cost ten times the nodes. Asserted as a
    // BOUND on the growth, never as an exact count — the visited count depends
    // on the tree shape, hence on creation order (§1.11.6).
    try std.testing.expect(counts[1] >= counts[0] * 10);
    try std.testing.expect(visited_at[1] < visited_at[0] * 3);
}

// ---------------------------------------------------------------------------
// M1.1.10 / E2 — swept-volume traversal (`queryCast`)
// ---------------------------------------------------------------------------
//
// `queryCast` is `queryRay` with one difference: each node's stored box is inflated
// by the cast volume's half-extents before the slab test, and the ray starts at the
// CENTRE of the cast shape's initial world AABB (`engine-physics-forge.md` §1.11.10).
// `queryRay` is now that call at a zero extent, so the first test below is the
// refactor's proof and asserts counts MEASURED BEFORE it.

/// Cast sink: the swept counterpart of `RayCollector`, which is left untouched so
/// the bit-identity test exercises the M1.1.9 collector as delivered.
///
/// Its exact test is the same slab predicate on the INFLATED box — the brute-force
/// reference every test here compares against, and the stand-in for the exact kernel
/// E3 will write.
const CastCollector = struct {
    gpa: std.mem.Allocator,
    boxes: []const Aabbf,
    ray: BvhF.RayT,
    extent: Vec3,
    tighten: bool,

    items: std.ArrayListUnmanaged(u32) = .empty,
    bound: f32 = std.math.inf(f32),
    best_distance: f32 = std.math.inf(f32),
    best_ud: ?u32 = null,

    pub fn add(self: *CastCollector, user_data: u32) void {
        self.items.append(self.gpa, user_data) catch @panic("collector OOM");
        const inflated = self.boxes[user_data].inflate(self.extent);
        const iv = inflated.rayInterval(self.ray.origin, self.ray.inv_dir, self.ray.dir_is_zero) orelse
            return; // a fat-box candidate the exact test rejects
        const distance = @max(iv.enter, 0); // already overlapping at t = 0
        if (distance < self.best_distance) {
            self.best_distance = distance;
            self.best_ud = user_data;
            if (self.tighten) self.bound = distance;
        }
    }

    pub fn maxDistance(self: *const CastCollector) f32 {
        return self.bound;
    }

    pub fn shouldStop(_: *const CastCollector) bool {
        return false;
    }

    fn deinit(self: *CastCollector) void {
        self.items.deinit(self.gpa);
    }
    fn sortedOwned(self: *CastCollector) []u32 {
        std.mem.sort(u32, self.items.items, {}, std.sort.asc(u32));
        return self.items.items;
    }
};

/// The 800-box random cloud of `queryRay collects every proxy the ray crosses`,
/// reproduced construction for construction — same seed, same order, same zero
/// margin. The reproduction is not taken on trust: the visited counts baked into the
/// bit-identity test were measured through this exact sequence, so a divergence from
/// the M1.1.9 scene would show up there.
fn buildCloud(gpa: std.mem.Allocator, tree: *BvhF, boxes: *std.ArrayListUnmanaged(Aabbf)) !void {
    var prng = std.Random.DefaultPrng.init(0x2A11_D0C5);
    const rng = prng.random();
    var i: u32 = 0;
    while (i < 800) : (i += 1) {
        const box = boxCe(.{
            rng.float(f32) * 60 - 30,
            rng.float(f32) * 60 - 30,
            rng.float(f32) * 60 - 30,
        }, 0.3 + rng.float(f32) * 1.5);
        _ = try tree.insert(gpa, box, i);
        try boxes.append(gpa, box);
    }
}

/// The five rays that cloud is queried with: axis-aligned (two zero lanes), the full
/// diagonal, one starting inside the cloud, one that misses everything, and one
/// reversed.
const cloud_rays = [_]BvhF.RayT{
    BvhF.RayT.init(Vec3.fromArray(.{ -50, 0, 0 }), Vec3.unit_x),
    BvhF.RayT.init(Vec3.fromArray(.{ -50, -50, -50 }), Vec3.one),
    BvhF.RayT.init(Vec3.zero, Vec3.fromArray(.{ 1, 2, -3 })),
    BvhF.RayT.init(Vec3.fromArray(.{ -50, 100, 0 }), Vec3.unit_x),
    BvhF.RayT.init(Vec3.fromArray(.{ 50, 0, 0 }), Vec3.unit_x.neg()),
};

/// The 200-box line of `queryRay prunes with the collector bound`, inserted
/// FAR-TO-NEAR so the tree's child order and the ray's near order disagree.
fn buildLine(gpa: std.mem.Allocator, tree: *BvhF, boxes: *std.ArrayListUnmanaged(Aabbf)) !void {
    try boxes.resize(gpa, 200);
    var ud: u32 = 200;
    while (ud > 0) {
        ud -= 1;
        const box = boxCe(.{ @as(f32, @floatFromInt(ud)) * 4, 0, 0 }, 0.5);
        boxes.items[ud] = box;
        _ = try tree.insert(gpa, box, ud);
    }
}

test "queryRay at zero extent is bit-identical to M1.1.9" {
    const gpa = std.testing.allocator;

    // THE REFACTOR'S PROOF. `queryRay` is now `queryCast` at a zero extent, and a
    // zero added to a float is not unconditionally a no-op: `max + 0` maps a `−0.0`
    // bound to `+0.0` (`Bvh.queryRay` carries the full argument for why nothing
    // downstream can see the difference). The claim is settled by measurement, not
    // by the argument alone.
    //
    // The counts below were MEASURED on the pre-refactor traversal, through the
    // scene builders above, before `queryCast` existed. Two of them are independently
    // corroborated: the 399 / 17 of the line are the figures the M1.1.9 pruning test
    // already records in its own comment, and they were re-read off the running code
    // rather than copied from it.
    //
    // Visited counts are asserted as EXACT literals here and nowhere else. That is
    // legitimate precisely because the claim is "unchanged by this refactor" on a
    // fixed scene; §1.11.6's rule that a visited count is never invariant is about
    // creation order, which this test holds constant on purpose.
    const cloud_expect = [cloud_rays.len]struct { all_visited: u32, all_collected: usize, closest_visited: u32, closest_collected: usize }{
        .{ .all_visited = 91, .all_collected = 1, .closest_visited = 77, .closest_collected = 1 },
        .{ .all_visited = 181, .all_collected = 3, .closest_visited = 125, .closest_collected = 1 },
        .{ .all_visited = 115, .all_collected = 2, .closest_visited = 89, .closest_collected = 1 },
        .{ .all_visited = 1, .all_collected = 0, .closest_visited = 1, .closest_collected = 0 },
        .{ .all_visited = 91, .all_collected = 1, .closest_visited = 91, .closest_collected = 1 },
    };

    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);
    var boxes: std.ArrayListUnmanaged(Aabbf) = .empty;
    defer boxes.deinit(gpa);
    try buildCloud(gpa, &tree, &boxes);
    tree.validate();

    for (cloud_rays, cloud_expect) |ray, want| {
        inline for (.{ false, true }) |tighten| {
            const expect_visited = if (tighten) want.closest_visited else want.all_visited;
            const expect_collected = if (tighten) want.closest_collected else want.all_collected;

            var via_ray = RayCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .tighten = tighten };
            defer via_ray.deinit();
            const visited_ray = tree.queryRay(ray, &via_ray);

            // (1) the count and the set are what the pre-refactor traversal produced
            try std.testing.expectEqual(expect_visited, visited_ray);
            try std.testing.expectEqual(expect_collected, via_ray.items.items.len);

            // (2) and the explicit zero-extent cast agrees with it exactly — same
            // count, same set, so the delegation is not merely plausible
            var via_cast = CastCollector{
                .gpa = gpa,
                .boxes = boxes.items,
                .ray = ray,
                .extent = Vec3.zero,
                .tighten = tighten,
            };
            defer via_cast.deinit();
            const visited_cast = tree.queryCast(ray, Vec3.zero, &via_cast);
            try std.testing.expectEqual(visited_ray, visited_cast);
            try std.testing.expectEqualSlices(u32, via_ray.sortedOwned(), via_cast.sortedOwned());
        }
    }

    // The line scene, both selection modes, same two claims.
    var line = BvhF.init(.{ .margin = 0 });
    defer line.deinit(gpa);
    var lboxes: std.ArrayListUnmanaged(Aabbf) = .empty;
    defer lboxes.deinit(gpa);
    try buildLine(gpa, &line, &lboxes);
    line.validate();

    const lray = BvhF.RayT.init(Vec3.fromArray(.{ -10, 0, 0 }), Vec3.unit_x);
    const line_expect = [2]struct { visited: u32, collected: usize }{
        .{ .visited = 399, .collected = 200 }, // all
        .{ .visited = 17, .collected = 1 }, // closest
    };
    inline for (.{ false, true }, line_expect) |tighten, want| {
        var via_ray = RayCollector{ .gpa = gpa, .boxes = lboxes.items, .ray = lray, .tighten = tighten };
        defer via_ray.deinit();
        try std.testing.expectEqual(want.visited, line.queryRay(lray, &via_ray));
        try std.testing.expectEqual(want.collected, via_ray.items.items.len);

        var via_cast = CastCollector{
            .gpa = gpa,
            .boxes = lboxes.items,
            .ray = lray,
            .extent = Vec3.zero,
            .tighten = tighten,
        };
        defer via_cast.deinit();
        try std.testing.expectEqual(want.visited, line.queryCast(lray, Vec3.zero, &via_cast));
        try std.testing.expectEqualSlices(u32, via_ray.sortedOwned(), via_cast.sortedOwned());
    }

    // A COUNT AND A SET ARE NOT ENOUGH, and this was measured rather than reasoned:
    // delegating at an extent of 0.001 instead of zero left every count and every set
    // above unchanged — the cloud's boxes are far apart and the line's are spaced 4 —
    // so the two scenes are blind to a small non-zero extent. The M1.1.9 suite caught
    // it, on the one assertion in it that is sensitive at the ulp: a bound placed
    // exactly at a box's entry parameter.
    //
    // That sensitivity belongs in this test too, since this is the one that claims to
    // be the refactor's proof. A single box entered at exactly t == 10 by a unit ray
    // from the origin: any inflation lowers that entry, so a bound one ulp BELOW 10
    // stops rejecting it. Both entries are driven through the same two bounds.
    {
        var one = BvhF.init(.{ .margin = 0 });
        defer one.deinit(gpa);
        const box = Aabbf.fromMinMax(Vec3.fromArray(.{ 10, -1, -1 }), Vec3.fromArray(.{ 12, 1, 1 }));
        _ = try one.insert(gpa, box, 0);
        const single = [_]Aabbf{box};
        const uray = BvhF.RayT.init(Vec3.zero, Vec3.unit_x);
        const just_below: f32 = @bitCast(@as(u32, @bitCast(@as(f32, 10))) - 1);

        const bounds = [2]f32{ 10, just_below };
        const admitted = [2]usize{ 1, 0 }; // closed at the bound; one ulp below, out
        for (bounds, admitted) |bound, want_len| {
            var via_ray = RayCollector{ .gpa = gpa, .boxes = &single, .ray = uray, .tighten = false, .bound = bound };
            defer via_ray.deinit();
            _ = one.queryRay(uray, &via_ray);
            try std.testing.expectEqual(want_len, via_ray.items.items.len);

            var via_cast = CastCollector{
                .gpa = gpa,
                .boxes = &single,
                .ray = uray,
                .extent = Vec3.zero,
                .tighten = false,
                .bound = bound,
            };
            defer via_cast.deinit();
            _ = one.queryCast(uray, Vec3.zero, &via_cast);
            try std.testing.expectEqual(want_len, via_cast.items.items.len);
        }

        // And the entry parameter itself is exact: 10, not 10 minus an inflation.
        var exact = RayCollector{ .gpa = gpa, .boxes = &single, .ray = uray, .tighten = true };
        defer exact.deinit();
        _ = one.queryRay(uray, &exact);
        try std.testing.expectEqual(@as(f32, 10), exact.best_distance);
    }
}

test "queryCast collects every proxy the swept box crosses" {
    const gpa = std.testing.allocator;
    // margin 0 → stored box == tight box, so the brute-force reference is the same
    // inflated-slab predicate over every leaf.
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);
    var boxes: std.ArrayListUnmanaged(Aabbf) = .empty;
    defer boxes.deinit(gpa);
    try buildCloud(gpa, &tree, &boxes);
    tree.validate();

    // Zero (the ray case), isotropic, strongly anisotropic, and one large enough to
    // sweep a good fraction of the cloud — so the reference is exercised where the
    // candidate set is small AND where it is large.
    const extents = [_]Vec3{
        Vec3.zero,
        Vec3.splat(1),
        Vec3.fromArray(.{ 0.2, 2.5, 0.05 }),
        Vec3.splat(6),
    };

    var total_collected: usize = 0;
    for (extents) |extent| {
        for (cloud_rays) |ray| {
            var got = CastCollector{
                .gpa = gpa,
                .boxes = boxes.items,
                .ray = ray,
                .extent = extent,
                .tighten = false,
            };
            defer got.deinit();
            _ = tree.queryCast(ray, extent, &got);

            var want: std.ArrayListUnmanaged(u32) = .empty;
            defer want.deinit(gpa);
            for (boxes.items, 0..) |box, ud| {
                const iv = box.inflate(extent).rayInterval(ray.origin, ray.inv_dir, ray.dir_is_zero) orelse continue;
                if (iv.exit >= 0) try want.append(gpa, @intCast(ud));
            }

            std.mem.sort(u32, want.items, {}, std.sort.asc(u32));
            try std.testing.expectEqualSlices(u32, want.items, got.sortedOwned());
            total_collected += want.items.len;
        }
    }
    // The sweep really found things: an all-empty reference would satisfy every
    // `expectEqualSlices` above and prove nothing.
    try std.testing.expect(total_collected > 100);
}

test "the extent widens the candidate set by exactly the Minkowski sum" {
    const gpa = std.testing.allocator;
    // One unit box centred at (10, 2, 0): its Y span is [1.5, 2.5]. A ray from the
    // origin along +X travels at Y = 0 and misses it by 1.5 exactly.
    //
    // Inflating the node by `e` on Y moves its lower face to `1.5 − e`, so the ray
    // is admitted exactly when `e >= 1.5` — face-inclusive, like every other
    // predicate in `Aabb`. Below, at, and above that value are all asserted, which
    // is what makes this a two-sided test of the inflation rather than a
    // demonstration that a big extent collects more.
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);
    const box = boxCe(.{ 10, 2, 0 }, 0.5);
    _ = try tree.insert(gpa, box, 0);
    const boxes = [_]Aabbf{box};
    const ray = BvhF.RayT.init(Vec3.zero, Vec3.unit_x);

    const cases = [_]struct { e: f32, hit: bool }{
        .{ .e = 0, .hit = false }, // the ray case: misses
        .{ .e = 1.4, .hit = false }, // still short of the gap
        .{ .e = 1.5, .hit = true }, // exactly the gap → inclusive
        .{ .e = 1.6, .hit = true }, // past it
    };
    for (cases) |case| {
        const extent = Vec3.fromArray(.{ 0, case.e, 0 });
        var got = CastCollector{
            .gpa = gpa,
            .boxes = &boxes,
            .ray = ray,
            .extent = extent,
            .tighten = false,
        };
        defer got.deinit();
        _ = tree.queryCast(ray, extent, &got);
        try std.testing.expectEqual(@as(usize, if (case.hit) 1 else 0), got.items.items.len);
        // A hit at `e = 1.5` also has to arrive at the right PARAMETER: the swept box
        // first touches at x = 10 − 0.5 = 9.5, the ray starting at the origin.
        if (case.hit) try std.testing.expectApproxEqAbs(@as(f32, 9.5), got.best_distance, 1e-5);
    }

    // Inflation on an axis the gap is not on changes nothing — the widening is
    // per-axis, not a scalar radius.
    const wrong_axis = Vec3.fromArray(.{ 5, 0, 5 });
    var none = CastCollector{
        .gpa = gpa,
        .boxes = &boxes,
        .ray = ray,
        .extent = wrong_axis,
        .tighten = false,
    };
    defer none.deinit();
    _ = tree.queryCast(ray, wrong_axis, &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.items.len);
}

test "queryCast prunes with the collector bound" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);
    var boxes: std.ArrayListUnmanaged(Aabbf) = .empty;
    defer boxes.deinit(gpa);
    try buildLine(gpa, &tree, &boxes);
    tree.validate();

    // A non-zero extent, so the pruning being measured is the SWEPT traversal's and
    // not the ray path's. The boxes are half-extent 0.5 spaced 4 apart, so a 0.25
    // inflation leaves them disjoint and all 200 stay reachable.
    const extent = Vec3.splat(0.25);
    const ray = BvhF.RayT.init(Vec3.fromArray(.{ -10, 0, 0 }), Vec3.unit_x);

    var all = CastCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .extent = extent, .tighten = false };
    defer all.deinit();
    const visited_all = tree.queryCast(ray, extent, &all);

    var closest = CastCollector{ .gpa = gpa, .boxes = boxes.items, .ray = ray, .extent = extent, .tighten = true };
    defer closest.deinit();
    const visited_closest = tree.queryCast(ray, extent, &closest);

    // DISCRIMINATION GUARD. Without it the test would pass on a traversal that
    // ignores `maxDistance()` altogether: both runs would return the same count and
    // agree on the winner, and nothing would be proven. The strict `<` is both the
    // assertion and the guard — it fails if the bound prunes nothing.
    try std.testing.expect(visited_closest < visited_all);

    // Pruning must not change the answer: the nearest box is the one at x = 0, whose
    // inflated near face is at 0 − 0.75 = −0.75, reached from x = −10 at t = 9.25.
    try std.testing.expectEqual(all.best_ud, closest.best_ud);
    try std.testing.expectEqual(@as(?u32, 0), closest.best_ud);
    try std.testing.expectEqual(all.best_distance, closest.best_distance);
    try std.testing.expectApproxEqAbs(@as(f32, 9.25), closest.best_distance, 1e-5);

    // The `all` collector really did see the whole line — otherwise "strictly fewer"
    // would be measuring two prunings against each other.
    try std.testing.expectEqual(@as(usize, 200), all.items.items.len);
    try std.testing.expect(closest.items.items.len < all.items.items.len);
}

test "queryCast visits all four layer trees" {
    const gpa = std.testing.allocator;
    var bph = BphF.init(.{ .margin = 0 });
    defer bph.deinit(gpa);

    // One proxy per layer on the +X axis, all OFFSET to Y ∈ [1, 3]. A ray along +X
    // from the origin travels at Y = 0 and reaches none of them, so a zero extent
    // collects nothing and the extent is what carries the query into every tree —
    // this test cannot pass on a traversal that walks the four trees but drops the
    // inflation.
    var boxes: [broadphase.layer_count]Aabbf = undefined;
    for (0..broadphase.layer_count) |i| {
        boxes[i] = boxCe(.{ @as(f32, @floatFromInt(i)) * 10 + 5, 2, 0 }, 1);
    }
    _ = try bph.insert(gpa, .static, boxes[0], 0);
    _ = try bph.insert(gpa, .dynamic, boxes[1], 1);
    _ = try bph.insert(gpa, .debris, boxes[2], 2);
    _ = try bph.insert(gpa, .trigger, boxes[3], 3);

    const ray = BphF.RayT.init(Vec3.zero, Vec3.unit_x);
    const extent = Vec3.fromArray(.{ 0, 1.5, 0 });

    // Zero extent: nothing, in any tree.
    var flat = CastCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .extent = Vec3.zero, .tighten = false };
    defer flat.deinit();
    _ = bph.queryCast(ray, Vec3.zero, &flat);
    try std.testing.expectEqual(@as(usize, 0), flat.items.items.len);

    // With the extent: all four, one per layer. The layer-pair matrix does not
    // apply to a query — it has no second body (§1.11.1).
    var got = CastCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .extent = extent, .tighten = false };
    defer got.deinit();
    const visited = bph.queryCast(ray, extent, &got);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, got.sortedOwned());
    try std.testing.expect(visited >= broadphase.layer_count); // every tree entered

    // The bound carries ACROSS the trees: a closest collector keeps the nearest of
    // the four, the static one, whatever order the trees are walked in.
    var closest = CastCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .extent = extent, .tighten = true };
    defer closest.deinit();
    _ = bph.queryCast(ray, extent, &closest);
    try std.testing.expectEqual(@as(?u32, 0), closest.best_ud);
}

test "queryCast is empty on an empty tree" {
    const gpa = std.testing.allocator;
    var tree = BvhF.init(.{ .margin = 0 });
    defer tree.deinit(gpa);

    const boxes = [_]Aabbf{};
    const ray = BvhF.RayT.init(Vec3.zero, Vec3.unit_x);
    const extent = Vec3.splat(2);
    var got = CastCollector{ .gpa = gpa, .boxes = &boxes, .ray = ray, .extent = extent, .tighten = false };
    defer got.deinit();

    try std.testing.expectEqual(@as(u32, 0), tree.queryCast(ray, extent, &got));
    try std.testing.expectEqual(@as(usize, 0), got.items.items.len);

    // Same on the multi-layer aggregate, whose four trees are all empty.
    var bph = BphF.init(.{ .margin = 0 });
    defer bph.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), bph.queryCast(ray, extent, &got));
    try std.testing.expectEqual(@as(usize, 0), got.items.items.len);
}

// ---------------------------------------------------------------------------
// M1.1.11 / E5 — unbounded shapes live OUTSIDE the trees
// ---------------------------------------------------------------------------
//
// An unbounded AABB does not degrade the BVH, it destroys it
// (`engine-physics-forge.md` §1.11.15): the centre of an infinite box is
// `(−inf + inf)·0.5`, i.e. NaN — and that centre is the ray origin a shape cast
// derives from a box — the surface area is infinite so the SAH cost is infinite at
// every candidate, and the union propagates the infinity to the root, after which
// every query visits every node. A finite substitute box is refused too: it is a
// tuning constant that changes a query's answer.
//
// So a half-space is never asked for a box. It is asked the corner PREDICATE, and it
// lives in a flat insertion-ordered list per broad layer.

/// The ground half-space `{ y <= 0 }` in world space.
const ground = BphF.UnboundedShape{ .normal = Vec3.unit_y, .distance = 0 };

test "a plane inserted AFTER the bodies pairs with all of them" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);
    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);

    // THE DIRECTION A NAIVE SUITE OMITS, and the reason it omits it: pair generation is
    // driven by the MOVED proxies, so a test that creates the plane first and then the
    // bodies exercises only direction (1) — each body enters the moved log and is
    // crossed with the unbounded list. Create the plane LAST and direction (1) never
    // fires for it: the bodies moved before it existed, and their log was consumed. Only
    // direction (2) — inserting an unbounded shape enumerates the existing leaves of the
    // layers it may pair with — can produce these pairs, and without it a plane created
    // after the bodies collides with NOTHING.
    var bodies: [4]u32 = undefined;
    for (0..4) |i| {
        const x = @as(f32, @floatFromInt(i)) * 4;
        // Each box straddles y = 0, so every one of them genuinely meets the half-space.
        bodies[i] = (try bp.insert(gpa, .dynamic, boxCe(.{ x, 0, 0 }, 0.5), 100 + @as(u32, @intCast(i)))).id;
        _ = bodies[i];
    }
    // Consume the moved log, exactly as a tick would: after this the bodies have no
    // pending motion at all.
    try bp.computePairs(gpa, &pairs);

    // NOW the plane arrives.
    const plane_ud: u32 = 7;
    _ = try bp.insertUnbounded(gpa, .static, ground, plane_ud);
    try bp.computePairs(gpa, &pairs);

    // All four pairs, and nothing else involving the plane.
    for (0..4) |i| {
        try std.testing.expect(hasPair(pairs.items, plane_ud, 100 + @as(u32, @intCast(i))));
    }
    var involving: u32 = 0;
    for (pairs.items) |p| {
        if (p.a == plane_ud or p.b == plane_ud) involving += 1;
    }
    try std.testing.expectEqual(@as(u32, 4), involving);
}

test "a body inserted AFTER the plane pairs with it" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);
    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);

    // The other direction, and the one a naive suite DOES cover: the plane exists, the
    // body enters the moved log, and direction (1) crosses it with the unbounded list.
    const plane_ud: u32 = 7;
    _ = try bp.insertUnbounded(gpa, .static, ground, plane_ud);
    try bp.computePairs(gpa, &pairs);
    try std.testing.expectEqual(@as(usize, 0), pairs.items.len); // nothing to pair with yet

    _ = try bp.insert(gpa, .dynamic, boxCe(.{ 0, 0, 0 }, 0.5), 100);
    try bp.computePairs(gpa, &pairs);
    try std.testing.expect(hasPair(pairs.items, plane_ud, 100));
    try std.testing.expectEqual(@as(usize, 1), pairs.items.len);
}

test "an unbounded shape is crossed only with the layers the matrix allows" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);
    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);

    // `default_layer_pairs` applies to an unbounded shape with NO special case. Read off
    // the matrix: static×dynamic is allowed, static×debris is allowed, and
    // static×trigger is FORBIDDEN — which is the combination this test asserts emits
    // nothing, in both insertion orders, so the refusal is not an artefact of one
    // direction of the pairing.
    try std.testing.expect(broadphase.default_layer_pairs[@intFromEnum(Layer.static)][@intFromEnum(Layer.dynamic)]);
    try std.testing.expect(broadphase.default_layer_pairs[@intFromEnum(Layer.static)][@intFromEnum(Layer.debris)]);
    try std.testing.expect(!broadphase.default_layer_pairs[@intFromEnum(Layer.static)][@intFromEnum(Layer.trigger)]);

    // Plane on `static`; one body per layer, all straddling y = 0 so geometry never
    // explains an absent pair.
    _ = try bp.insertUnbounded(gpa, .static, ground, 7);
    _ = try bp.insert(gpa, .dynamic, boxCe(.{ 0, 0, 0 }, 0.5), 100);
    _ = try bp.insert(gpa, .debris, boxCe(.{ 4, 0, 0 }, 0.5), 200);
    _ = try bp.insert(gpa, .trigger, boxCe(.{ 8, 0, 0 }, 0.5), 300);
    try bp.computePairs(gpa, &pairs);

    try std.testing.expect(hasPair(pairs.items, 7, 100)); // static × dynamic
    try std.testing.expect(hasPair(pairs.items, 7, 200)); // static × debris
    try std.testing.expect(!hasPair(pairs.items, 7, 300)); // static × trigger: FORBIDDEN

    // The reverse insertion order, so direction (2) is the one under test as well.
    var bp2 = BphF.init(.{});
    defer bp2.deinit(gpa);
    _ = try bp2.insert(gpa, .trigger, boxCe(.{ 8, 0, 0 }, 0.5), 300);
    try bp2.computePairs(gpa, &pairs);
    _ = try bp2.insertUnbounded(gpa, .static, ground, 7);
    try bp2.computePairs(gpa, &pairs);
    try std.testing.expect(!hasPair(pairs.items, 7, 300));
}

test "the tree is untouched by an unbounded shape" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);

    // Three bodies on `static`, then a half-space on the SAME layer. The tree must be
    // bit-for-bit unaffected: same leaf count, same height, and every stored box still
    // finite. An infinite box would have propagated to the root and made `height` and
    // the SAH costs meaningless; a NaN centre would have poisoned every shape cast.
    for (0..3) |i| {
        _ = try bp.insert(gpa, .static, boxAt(@as(f32, @floatFromInt(i)) * 4), 100 + @as(u32, @intCast(i)));
    }
    const tree = &bp.trees[@intFromEnum(Layer.static)];
    const leaves_before = tree.leafCount();
    const height_before = tree.height();

    _ = try bp.insertUnbounded(gpa, .static, ground, 7);

    try std.testing.expectEqual(leaves_before, tree.leafCount());
    try std.testing.expectEqual(height_before, tree.height());
    tree.validate(); // every structural and metric invariant, including AABB containment

    // NO NaN and NO infinity anywhere in the node pool — checked on the stored boxes
    // themselves rather than inferred from the counts above.
    for (tree.nodes.items) |node| {
        if (node.height == -1) continue; // free-list slot, its box is not live
        for (node.aabb.min.toArray()) |v| try std.testing.expect(std.math.isFinite(v));
        for (node.aabb.max.toArray()) |v| try std.testing.expect(std.math.isFinite(v));
    }
    // And the unbounded shape is where it belongs: in the layer's list, not the tree.
    try std.testing.expectEqual(@as(usize, 1), bp.unbounded[@intFromEnum(Layer.static)].items.len);
    try std.testing.expectEqual(@as(u32, 3), tree.leafCount());
}

test "queryAabb, queryRay and queryCast all visit the unbounded list" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);

    // DISCRIMINATION GUARD: the scene holds exactly ONE unbounded shape and NO tree
    // proxy at all, so a collected `user_data` of 7 can have come from nowhere else.
    // With a body in the scene the tests would pass on the body and prove nothing about
    // the list.
    _ = try bp.insertUnbounded(gpa, .static, ground, 7);
    for (&bp.trees) |*t| try std.testing.expectEqual(@as(u32, 0), t.leafCount());

    const Collect = struct {
        seen: [8]u32 = undefined,
        count: u32 = 0,
        bound: f32 = 1e9,
        pub fn add(self: *@This(), ud: u32) void {
            if (self.count < self.seen.len) {
                self.seen[self.count] = ud;
                self.count += 1;
            }
        }
        pub fn maxDistance(self: *const @This()) f32 {
            return self.bound;
        }
        pub fn shouldStop(_: *const @This()) bool {
            return false;
        }
    };

    // (1) queryAabb — a box straddling y = 0 meets the half-space.
    var c1 = Collect{};
    _ = bp.queryAabb(boxCe(.{ 0, 0, 0 }, 0.5), &c1);
    try std.testing.expectEqual(@as(u32, 1), c1.count);
    try std.testing.expectEqual(@as(u32, 7), c1.seen[0]);
    // …and a box entirely ABOVE it does not, so the visit is a real test and not an
    // unconditional add.
    var c1b = Collect{};
    _ = bp.queryAabb(boxCe(.{ 0, 10, 0 }, 0.5), &c1b);
    try std.testing.expectEqual(@as(u32, 0), c1b.count);

    // (2) queryRay — the list has no box to prune on, so it is offered to the collector
    // and the exact kernel decides. The ray here points at the plane.
    var c2 = Collect{};
    _ = bp.queryRay(BphF.RayT.init(Vec3.fromArray(.{ 0, 5, 0 }), Vec3.unit_y.neg()), &c2);
    try std.testing.expectEqual(@as(u32, 1), c2.count);
    try std.testing.expectEqual(@as(u32, 7), c2.seen[0]);

    // (3) queryCast — same, with a non-zero extent.
    var c3 = Collect{};
    _ = bp.queryCast(BphF.RayT.init(Vec3.fromArray(.{ 0, 5, 0 }), Vec3.unit_y.neg()), Vec3.splat(0.5), &c3);
    try std.testing.expectEqual(@as(u32, 1), c3.count);
    try std.testing.expectEqual(@as(u32, 7), c3.seen[0]);

    // A collector that has stopped is honoured for the lists too, exactly as it is
    // between the four trees.
    const Stopper = struct {
        count: u32 = 0,
        pub fn add(self: *@This(), _: u32) void {
            self.count += 1;
        }
        pub fn maxDistance(_: *const @This()) f32 {
            return 1e9;
        }
        pub fn shouldStop(_: *const @This()) bool {
            return true;
        }
    };
    var s = Stopper{};
    _ = bp.queryRay(BphF.RayT.init(Vec3.fromArray(.{ 0, 5, 0 }), Vec3.unit_y.neg()), &s);
    try std.testing.expectEqual(@as(u32, 0), s.count);
}

test "removing an unbounded proxy retires it from the list and from pairing" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);
    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);

    const plane = try bp.insertUnbounded(gpa, .static, ground, 7);
    _ = try bp.insert(gpa, .dynamic, boxCe(.{ 0, 0, 0 }, 0.5), 100);
    try bp.computePairs(gpa, &pairs);
    try std.testing.expect(hasPair(pairs.items, 7, 100));

    // Removed: the slot is retired, not compacted — the list is insertion-ordered and a
    // later slot's index must not shift, so the entry is marked dead in place (the
    // `isLiveLeaf` discipline of the tree, one level up).
    bp.remove(plane);
    _ = try bp.insert(gpa, .dynamic, boxCe(.{ 4, 0, 0 }, 0.5), 200);
    try bp.computePairs(gpa, &pairs);
    for (pairs.items) |p| {
        try std.testing.expect(p.a != 7 and p.b != 7);
    }
    // A query no longer sees it either.
    const Collect = struct {
        count: u32 = 0,
        pub fn add(self: *@This(), _: u32) void {
            self.count += 1;
        }
        pub fn maxDistance(_: *const @This()) f32 {
            return 1e9;
        }
        pub fn shouldStop(_: *const @This()) bool {
            return false;
        }
    };
    var c = Collect{};
    _ = bp.queryAabb(boxCe(.{ 100, 0, 100 }, 0.5), &c); // meets the half-space geometrically
    try std.testing.expectEqual(@as(u32, 0), c.count);
}

test "the unbounded list is bounded by the LIVE count, not by the total ever created" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);
    const list = &bp.unbounded[@intFromEnum(Layer.static)];

    // MEASURED BOTH WAYS rather than asserted once (M1.1.11/E7-J3). Before the free-list,
    // `remove` only cleared the `live` flag, so 64 create/destroy cycles left 64 slots in
    // the list and `visitUnbounded` walked all of them for every query — a monotonic cost
    // in the number of planes ever created. With the LIFO free-list the same sequence
    // leaves exactly ONE.
    var live: BphF.Proxy = try bp.insertUnbounded(gpa, .static, ground, 0);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    var i: u32 = 1;
    while (i < 64) : (i += 1) {
        bp.remove(live);
        live = try bp.insertUnbounded(gpa, .static, ground, i);
        // The list never grows past the live count, at any point of the sequence — not
        // just at the end, which a single final assertion would not distinguish from a
        // list that grew and was compacted.
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        // …and the recycled slot is the SAME index every time: LIFO, one live entry.
        try std.testing.expectEqual(@as(u32, 0), live.id);
    }
    try std.testing.expectEqual(@as(usize, 1), list.items.len);

    // The surviving shape is the LAST one inserted, not a stale earlier one: a query sees
    // `user_data` 63 and nothing else. This is the discrimination that a reused slot
    // carries its new occupant's payload and not the dead one's.
    const Collect = struct {
        seen: [8]u32 = undefined,
        count: u32 = 0,
        pub fn add(self: *@This(), ud: u32) void {
            if (self.count < self.seen.len) {
                self.seen[self.count] = ud;
                self.count += 1;
            }
        }
        pub fn maxDistance(_: *const @This()) f32 {
            return 1e9;
        }
        pub fn shouldStop(_: *const @This()) bool {
            return false;
        }
    };
    var c = Collect{};
    _ = bp.queryAabb(boxCe(.{ 0, 0, 0 }, 0.5), &c);
    try std.testing.expectEqual(@as(u32, 1), c.count);
    try std.testing.expectEqual(@as(u32, 63), c.seen[0]);

    // N live at once still occupies N slots — the free-list recycles, it does not merge.
    var held: [8]BphF.Proxy = undefined;
    for (&held, 0..) |*h, k| h.* = try bp.insertUnbounded(gpa, .static, ground, 100 + @as(u32, @intCast(k)));
    try std.testing.expectEqual(@as(usize, 9), list.items.len); // 1 live + 8 new
    // Freeing them all and re-inserting one reuses a slot rather than appending a tenth.
    for (held) |h| bp.remove(h);
    _ = try bp.insertUnbounded(gpa, .static, ground, 200);
    try std.testing.expectEqual(@as(usize, 9), list.items.len);
}

test "a retired unbounded slot never surfaces in a pair after its index is reused" {
    const gpa = std.testing.allocator;
    var bp = BphF.init(.{});
    defer bp.deinit(gpa);
    var pairs: std.ArrayListUnmanaged(BphF.Pair) = .empty;
    defer pairs.deinit(gpa);

    // The stale-index exposure a free-list carries, exercised at its worst point: the
    // slot is logged as moved, then freed, then REUSED by a different shape, all before
    // `computePairs` runs. The moved entry now names the new occupant — which was itself
    // logged on insertion — so the effect is a duplicate log entry, and the output is
    // sorted and adjacent-deduped. The pair set must therefore name the NEW shape once
    // and the dead one never.
    _ = try bp.insert(gpa, .dynamic, boxCe(.{ 0, 0, 0 }, 0.5), 100);
    const doomed = try bp.insertUnbounded(gpa, .static, ground, 7);
    bp.remove(doomed);
    const reborn = try bp.insertUnbounded(gpa, .static, ground, 8);
    try std.testing.expectEqual(doomed.id, reborn.id); // the same slot, reused
    try bp.computePairs(gpa, &pairs);

    try std.testing.expect(hasPair(pairs.items, 8, 100));
    var involving_dead: u32 = 0;
    var involving_live: u32 = 0;
    for (pairs.items) |p| {
        if (p.a == 7 or p.b == 7) involving_dead += 1;
        if (p.a == 8 or p.b == 8) involving_live += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), involving_dead);
    try std.testing.expectEqual(@as(u32, 1), involving_live); // once, not twice
}
