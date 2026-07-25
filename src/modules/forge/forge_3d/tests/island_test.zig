//! M1.1.8 acceptance suite for island partitioning.
//!
//! Two layers, matching the two layers of the design
//! (`engine-physics-forge.md` §1.8.1): the branch-neutral union-find core of
//! `pipeline/island.zig` exercised in isolation — no physics type involved at all —
//! and, above it, the rigid adapter's partition of real bodies and contact
//! constraints.

const std = @import("std");
const island = @import("../pipeline/island.zig");

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
