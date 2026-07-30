//! `forge_3d/rigid/contact_cache.zig` — the Sequential Impulses warm-start cache.
//!
//! A per-tick, double-buffered flat cache of accumulated contact impulses keyed
//! by contact feature. The solver seeds each new tick's constraints from the
//! previous tick's solved impulses (warm start; `velocity_solver.warmStart`),
//! which is what makes the iterative solver converge in a handful of iterations.
//!
//! Determinism by construction (M1.1.14): sorted flat arrays only, NO hash
//! containers. The `prev` buffer is sorted ascending by the full key; matching is
//! a binary search per individual feature key. Contact topology legitimately
//! changes between frames (a manifold gaining/losing points, an MTV-tie count
//! divergence), so matching is per-key — a point without a match cold-starts; the
//! manifold count is never assumed stable.
//!
//! Lifecycle, exactly once per tick (independent of any per-range solve calls):
//!   - `beginTick`  — clear the current buffer, reset the hit/miss counters.
//!   - `store`      — record a solved contact impulse into the current buffer
//!                    (the solver harvests every constraint point after the
//!                    velocity iterations).
//!   - `endTick`    — sort the current buffer by the full key, then swap it with
//!                    `prev`. Eviction is implicit: entries in the old `prev` that
//!                    were not re-stored do not survive the swap.
//!
//! The value's tangent impulse is stored in WORLD space (a `Vec3r`), NOT as two
//! basis scalars: the tangent basis flips discontinuously across a dominant-axis
//! change, so basis scalars would rotate arbitrarily in the tangent plane. A
//! world vector is reprojected onto the new basis at warm start instead.

const std = @import("std");
const config = @import("../config.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;

/// A contact's warm-start identity. `subshape_id` is 0 for every shape delivered so
/// far, and the full triple is the sort/match key so it extends without a format
/// change.
pub const CacheKey = struct {
    /// Packed canonical body pair `min(BodyId)<<32 | max`.
    pair_key: u64,
    /// Sub-shape of the pair — an OPAQUE PATH decoded by the root shape, NOT a global
    /// index (`engine-physics-forge.md` §1.11.16). A shape with no sub-shape consumes
    /// zero bits, so this is 0 and unread for sphere, box, capsule and plane; a compound
    /// (M1.1.20) shifts its own index up and inserts the child's below, which extends the
    /// encoding without reinterpreting a value already cached.
    subshape_id: u32 = 0,
    /// Per-contact feature id (from the manifold), unique within a manifold.
    feature_id: u32,
};

/// The accumulated impulses carried between ticks for one contact feature.
pub const CacheValue = struct {
    /// Accumulated normal impulse λₙ.
    lambda_n: Real,
    /// Accumulated tangent impulse in WORLD space (reprojected at warm start).
    tangent_impulse: Vec3r,
};

const Entry = struct {
    key: CacheKey,
    value: CacheValue,
};

/// Double-buffered warm-start cache. `prev` (sorted) is read at warm start;
/// `current` collects this tick's solved impulses and becomes `prev` at `endTick`.
pub const ContactCache = struct {
    /// Last tick's impulses, sorted ascending by the full key (read at warm start).
    prev: std.ArrayListUnmanaged(Entry) = .empty,
    /// This tick's impulses, filled by `store`, sorted + promoted at `endTick`.
    current: std.ArrayListUnmanaged(Entry) = .empty,
    /// Warm-start matches since the last `beginTick` (debug/telemetry feed).
    hits: u32 = 0,
    /// Warm-start cold-starts since the last `beginTick`.
    misses: u32 = 0,

    /// Release both buffers.
    pub fn deinit(self: *ContactCache, gpa: std.mem.Allocator) void {
        self.prev.deinit(gpa);
        self.current.deinit(gpa);
        self.* = undefined;
    }

    /// Start a tick: clear the current buffer (retaining capacity) and reset the
    /// hit/miss counters. `prev` (last tick's sorted impulses) is untouched.
    pub fn beginTick(self: *ContactCache) void {
        self.current.clearRetainingCapacity();
        self.hits = 0;
        self.misses = 0;
    }

    /// Record a solved contact impulse into the current buffer.
    pub fn store(self: *ContactCache, gpa: std.mem.Allocator, key: CacheKey, value: CacheValue) !void {
        try self.current.append(gpa, .{ .key = key, .value = value });
    }

    /// Look `key` up in the sorted `prev` buffer (binary search). Returns the
    /// cached value on a hit (and counts it) or null on a cold start (miss).
    pub fn lookup(self: *ContactCache, key: CacheKey) ?CacheValue {
        var lo: usize = 0;
        var hi: usize = self.prev.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (orderKey(self.prev.items[mid].key, key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    self.hits += 1;
                    return self.prev.items[mid].value;
                },
            }
        }
        self.misses += 1;
        return null;
    }

    /// End a tick: sort the current buffer by the full key, then swap it into
    /// `prev`. The old `prev` becomes the scratch buffer that `beginTick` clears;
    /// entries not re-stored this tick are implicitly evicted.
    pub fn endTick(self: *ContactCache) void {
        std.mem.sort(Entry, self.current.items, {}, lessByKey);
        std.mem.swap(std.ArrayListUnmanaged(Entry), &self.prev, &self.current);
    }
};

/// Total order over keys: `pair_key`, then `subshape_id`, then `feature_id`.
fn orderKey(a: CacheKey, b: CacheKey) std.math.Order {
    if (a.pair_key != b.pair_key) return std.math.order(a.pair_key, b.pair_key);
    if (a.subshape_id != b.subshape_id) return std.math.order(a.subshape_id, b.subshape_id);
    return std.math.order(a.feature_id, b.feature_id);
}

fn lessByKey(_: void, x: Entry, y: Entry) bool {
    return orderKey(x.key, y.key) == .lt;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "lookup finds stored keys after endTick and records hits and misses" {
    const gpa = testing.allocator;
    var cache = ContactCache{};
    defer cache.deinit(gpa);

    // Store three entries out of key order, then finalize (sort + promote to prev).
    try cache.store(gpa, .{ .pair_key = 5, .feature_id = 2 }, .{ .lambda_n = 2, .tangent_impulse = Vec3r.zero });
    try cache.store(gpa, .{ .pair_key = 1, .feature_id = 9 }, .{ .lambda_n = 1, .tangent_impulse = Vec3r.zero });
    try cache.store(gpa, .{ .pair_key = 5, .feature_id = 1 }, .{ .lambda_n = 3, .tangent_impulse = Vec3r.zero });
    cache.endTick();

    try testing.expectEqual(@as(Real, 1), cache.lookup(.{ .pair_key = 1, .feature_id = 9 }).?.lambda_n);
    try testing.expectEqual(@as(Real, 3), cache.lookup(.{ .pair_key = 5, .feature_id = 1 }).?.lambda_n);
    try testing.expectEqual(@as(Real, 2), cache.lookup(.{ .pair_key = 5, .feature_id = 2 }).?.lambda_n);
    try testing.expect(cache.lookup(.{ .pair_key = 9, .feature_id = 0 }) == null);
    try testing.expectEqual(@as(u32, 3), cache.hits);
    try testing.expectEqual(@as(u32, 1), cache.misses);
}

test "endTick swaps buffers and evicts entries not re-stored" {
    const gpa = testing.allocator;
    var cache = ContactCache{};
    defer cache.deinit(gpa);

    // Tick 1: two contacts persist.
    try cache.store(gpa, .{ .pair_key = 1, .feature_id = 1 }, .{ .lambda_n = 1, .tangent_impulse = Vec3r.zero });
    try cache.store(gpa, .{ .pair_key = 2, .feature_id = 1 }, .{ .lambda_n = 2, .tangent_impulse = Vec3r.zero });
    cache.endTick();

    // Tick 2: only the first is re-stored — the second must be evicted by the swap.
    cache.beginTick();
    try cache.store(gpa, .{ .pair_key = 1, .feature_id = 1 }, .{ .lambda_n = 10, .tangent_impulse = Vec3r.zero });
    cache.endTick();

    try testing.expectEqual(@as(Real, 10), cache.lookup(.{ .pair_key = 1, .feature_id = 1 }).?.lambda_n);
    try testing.expect(cache.lookup(.{ .pair_key = 2, .feature_id = 1 }) == null);
}

test "lookup distinguishes feature_id within one pair_key" {
    const gpa = testing.allocator;
    var cache = ContactCache{};
    defer cache.deinit(gpa);

    try cache.store(gpa, .{ .pair_key = 7, .feature_id = 20 }, .{ .lambda_n = 20, .tangent_impulse = Vec3r.zero });
    try cache.store(gpa, .{ .pair_key = 7, .feature_id = 10 }, .{ .lambda_n = 10, .tangent_impulse = Vec3r.zero });
    cache.endTick();

    try testing.expectEqual(@as(Real, 10), cache.lookup(.{ .pair_key = 7, .feature_id = 10 }).?.lambda_n);
    try testing.expectEqual(@as(Real, 20), cache.lookup(.{ .pair_key = 7, .feature_id = 20 }).?.lambda_n);
}
