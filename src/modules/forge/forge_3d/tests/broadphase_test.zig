//! Acceptance suite for `forge_3d/pipeline/broadphase.zig`.
//!
//! Grows gate by gate with M1.1.1: E1 covers `Bvh(T)` insert/remove invariants
//! and deterministic LIFO free-list reuse. Later gates add update hysteresis,
//! `queryAabb`, determinism, the layer-pair matrix, `computePairs`, and the
//! `BodyManager`→`Broadphase` integration.

const std = @import("std");
const broadphase = @import("../pipeline/broadphase.zig");
const math = @import("foundation").math;

const Aabbf = math.Aabbf;
const Vec3 = math.Vec3;
const BvhF = broadphase.Bvh(f32);

/// Unit-half-extent box centred at (x, 0, 0).
fn boxAt(x: f32) Aabbf {
    return Aabbf.fromCenterHalfExtents(Vec3.fromArray(.{ x, 0, 0 }), Vec3.splat(0.5));
}

/// Box centred at `c` with uniform half-extent `he`.
fn boxCe(c: [3]f32, he: f32) Aabbf {
    return Aabbf.fromCenterHalfExtents(Vec3.fromArray(c), Vec3.splat(he));
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
