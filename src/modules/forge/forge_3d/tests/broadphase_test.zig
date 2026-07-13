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
