//! `forge_3d/query/overlap.zig` — the overlap, point-query and closest-point
//! collectors (M1.1.10 / E5).
//!
//! **The three overlaps have no bound to tighten**, so they take the FIRST collector
//! contract — `add(user_data)` and nothing more, the one the existing overlap
//! traversal defines — and do not complete it (`engine-physics-forge.md` §1.11.12).
//! One collector serves all three; only the per-candidate predicate differs, and it
//! is carried as a `Probe` rather than by three near-identical structs.
//!
//! **Ordering is `(entity, BodyId)`** and the retention on overflow is replace-worst
//! under that key (§1.11.14). It cannot be `BodyId` alone: a slot index encodes
//! creation order, so keeping the smallest would keep the bodies created first —
//! the inverse of the invariance the family claims. And there is NO deduplication
//! here: the solver's identity is the body and it returns bodies; projecting them
//! onto entities, and deduplicating, belongs to the tier that owns entities (§13).
//!
//! **Closest point** does have a distance, so it ranks on the full
//! `(distance, entity, BodyId)`; its candidate set is the queried point's AABB
//! inflated by `max_distance`, and a bounded nearest-neighbour descent is an
//! additive optimisation §1.11.13 explicitly leaves out — `max_distance` being a
//! required parameter, the caller has already bounded the set.

const std = @import("std");
const config = @import("../config.zig");
const body_manager_mod = @import("../body_manager.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const api = @import("weld_forge");
const root = @import("root.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Aabbr = config.Aabbr;
const BodyId = api.BodyId;
const BodyManager = body_manager_mod.BodyManager;
const ShapeStore = body_manager_mod.ShapeStore;
const Filter = root.Filter;
const ClosestPointHit = root.ClosestPointHit;

/// What a candidate is tested against — the only thing that differs between the
/// three overlap entries (§1.11.12's table of exact kernels).
pub const Probe = union(enum) {
    /// Overlap of a posed shape: GJK on the cores, accepted when the regime is not
    /// `separated`. NO threshold of its own — the contact margin is GJK's
    /// classification margin, and a second margin proper to queries is exactly what
    /// §1.11.12 forbids.
    shape: struct {
        shape: narrowphase.SupportShape(Real),
        position: Vec3r,
        rotation: Quatr,
        /// Which side of a mesh TRIANGLE answers. For an overlap the test is whether the
        /// probe lies ENTIRELY in the rear half-space of the triangle's plane; a probe
        /// STRADDLING it touches from the front and counts in both modes (§1.11.17).
        back_face_mode: api.BackFaceMode = .ignore,
    },
    /// Overlap of a world AABB: the body's TIGHT world AABB, faces included — or, for
    /// an unbounded body, the corner predicate, which has no box to compare
    /// (`BodyManager.aabbOverlapsBody` dispatches).
    /// Deliberately not the leaf's stored box, which is FAT by
    /// `BroadphaseConfig.margin` — returning the candidate set would report bodies
    /// that do not overlap the query, and the error would be a function of a TUNING
    /// CONSTANT, so changing the margin would change a query's answer. This entry
    /// stops at AABB granularity, which is not the same thing as stopping at the
    /// candidate set.
    aabb: Aabbr,
    /// Point membership in the solid, boundary included (§1.11.4's solidity
    /// convention, the same predicate `closestPointBody` consults first).
    point: Vec3r,
};

/// Gathers the bodies a probe accepts, keeping the best `out.len` under
/// `(entity, BodyId)`.
pub const OverlapCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    probe: Probe,
    out: []BodyId,
    count: u32 = 0,

    pub fn add(self: *OverlapCollector, user_data: u32) void {
        const body: BodyId = user_data;
        const layer = self.bm.collisionLayer(body) orelse return;
        if (!self.filter.accepts(layer, body)) return;

        const accepted = switch (self.probe) {
            .shape => |s| self.bm.overlapShapeBody(self.store, body, s.shape, s.position, s.rotation, s.back_face_mode) orelse return,
            // Through the adapter, NOT `bodyAabb`: a candidate may be a half-space, which
            // has no world AABB at all, and `bodyAabb` asserts the convex class (E5 item
            // 6). The adapter's convex arm is still the body's TIGHT world box — the fat
            // leaf box would make the answer a function of a tuning constant (§1.11.12) —
            // and its half-space arm is the corner predicate.
            .aabb => |query_box| self.bm.aabbOverlapsBody(self.store, body, query_box) orelse return,
            .point => |p| self.bm.containsPointBody(self.store, body, p) orelse return,
        };
        if (!accepted) return;

        if (self.count < self.out.len) {
            self.out[self.count] = body;
            self.count += 1;
            return;
        }
        if (self.out.len == 0) return;

        // Full: replace the current worst under `(entity, BodyId)` if this body is
        // better, so the retained set is the best `out.len` whatever the order of
        // arrival — which is what keeps a truncated answer invariant under a
        // permutation of creation order. Linear in the buffer, which only matters
        // once the caller has already accepted a truncated answer.
        var worst: usize = 0;
        for (self.out[1..], 1..) |candidate, i| {
            if (self.bodyLess(self.out[worst], candidate)) worst = i;
        }
        if (self.bodyLess(body, self.out[worst])) self.out[worst] = body;
    }

    /// `(entity, BodyId)` on two live bodies. A body whose handle went stale between
    /// its acceptance and this comparison sorts LAST, so it is the first thing a full
    /// buffer evicts — it can no longer be part of a correct answer.
    fn bodyLess(self: *const OverlapCollector, x: BodyId, y: BodyId) bool {
        const ex = self.bm.entity(x) orelse return false;
        const ey = self.bm.entity(y) orelse return true;
        return root.keyLess(ex, x, ey, y);
    }

    /// Sort the written prefix on the retention key. Called once by the entry.
    pub fn finish(self: *OverlapCollector) u32 {
        const written = self.count;
        const Ctx = struct {
            bm: *const BodyManager,
            fn less(ctx: @This(), x: BodyId, y: BodyId) bool {
                const ex = ctx.bm.entity(x) orelse return false;
                const ey = ctx.bm.entity(y) orelse return true;
                return root.keyLess(ex, x, ey, y);
            }
        };
        std.mem.sort(BodyId, self.out[0..written], Ctx{ .bm = self.bm }, Ctx.less);
        return written;
    }
};

/// `closest` over the closest-point kernel: one body, the nearest surface, ranked on
/// the full `(distance, entity, BodyId)`.
pub const ClosestPointCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    point: Vec3r,
    max_distance: Real,
    best: ?ClosestPointHit = null,

    pub fn add(self: *ClosestPointCollector, user_data: u32) void {
        const body: BodyId = user_data;
        const layer = self.bm.collisionLayer(body) orelse return;
        if (!self.filter.accepts(layer, body)) return;

        const local = self.bm.closestPointBody(self.store, body, self.point) orelse return;
        // A CLOSED bound, like every other distance window in the family.
        if (local.distance > self.max_distance) return;
        const owner = self.bm.entity(body) orelse return;

        const hit: ClosestPointHit = .{
            .body = body,
            .entity = owner,
            // The sub-shape carrying the closest point — a mesh's triangle index (§1.11.16).
            .subshape_id = local.subshape_id,
            .position = local.position,
            .distance = local.distance,
        };
        if (self.best) |best| {
            if (!root.closestLess(void{}, hit, best)) return;
        }
        self.best = hit;
    }
};

/// The queried point's degenerate AABB, inflated by `max_distance` — the candidate
/// set of §1.11.13.
///
/// Well-formed (`min <= max`) BECAUSE the entry asserts `max_distance >= 0`: a negative
/// bound would invert this box on every axis. The two are one statement — an inverted
/// box denotes the empty set (§1.11.12), which is not what a negative radius should
/// silently mean. `pointAabb` needs no such condition, being degenerate by
/// construction, and the two shape-posed entries build theirs from `worldAabb`, whose
/// extents are sums of non-negative terms.
pub fn closestPointCandidates(point: Vec3r, max_distance: Real) Aabbr {
    return Aabbr.fromMinMax(point, point).inflate(Vec3r.splat(max_distance));
}

/// The degenerate AABB of a single point — the point query's candidate set
/// (§1.11.12).
pub fn pointAabb(point: Vec3r) Aabbr {
    return Aabbr.fromMinMax(point, point);
}

// ─── M1.1.15.2 G5a — the entity-major ordering proof ────────────────────────

const testing = std.testing;

/// A `BodyManager` + `ShapeStore` holding `n` unit spheres, each on the entity
/// index the caller names. No broadphase and no world: the subject is the
/// COLLECTOR, so the instrument drives `add` directly and controls the order of
/// arrival, which is the one thing a traversal would take away.
const Fixture = struct {
    bm: BodyManager = .{},
    store: ShapeStore = .{},
    bodies: [8]BodyId = undefined,
    len: usize = 0,

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.bm.deinit(gpa);
        self.store.deinit(gpa);
    }

    fn addOn(self: *Fixture, gpa: std.mem.Allocator, entity_index: u32) !BodyId {
        const shape = try self.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
        const id = try self.bm.addBody(gpa, &self.store, .{
            .shape = shape,
            // `WorldVec3` and NOT `Vec3r`: `BodyDescriptor` is the FROZEN public surface and
            // its pose is the world scalar, which is `f32` until `large_world`. Spelling it
            // `Vec3r` compiled at the default precision and broke the build under
            // `-Dphysics_f64` — the half of the precision guard the type system carries
            // (M1.1.15), and the reason the six f64 cells exist.
            .position = api.precision.WorldVec3.zero,
            .body_type = .static,
            .entity = .{ .index = entity_index, .generation = 0 },
        });
        self.bodies[self.len] = id;
        self.len += 1;
        return id;
    }

    /// A collector over an origin-containing point probe, so every body added is a
    /// candidate and the ordering is the only thing under test.
    fn collector(self: *Fixture, out: []BodyId) OverlapCollector {
        return .{
            .bm = &self.bm,
            .store = &self.store,
            .filter = .{},
            .probe = .{ .point = Vec3r.zero },
            .out = out,
        };
    }
};

test "OverlapCollector yields entity-major order" {
    const gpa = testing.allocator;
    var f: Fixture = .{};
    defer f.deinit(gpa);

    // FOUR bodies over THREE entities, with entity 1 carrying two — which is the
    // shape that matters, since `Forge3DModule`'s adjacent deduplication is only
    // correct if one entity's bodies come out CONTIGUOUS.
    const e2 = try f.addOn(gpa, 2);
    const e1a = try f.addOn(gpa, 1);
    const e0 = try f.addOn(gpa, 0);
    const e1b = try f.addOn(gpa, 1);

    // Creation order is 2, 1, 0, 1 — adversarial on purpose: a collector that
    // returned arrival order would pass an "is it sorted" check written on an
    // already-sorted input.
    var out: [8]BodyId = undefined;
    var c = f.collector(&out);
    for ([_]BodyId{ e2, e1a, e0, e1b }) |b| c.add(b);
    const n = c.finish();
    try testing.expectEqual(@as(u32, 4), n);

    // Entity-major, and asserted as CONTIGUITY rather than as a sorted sequence:
    // the property the deduplication depends on is that one entity's run is
    // unbroken, which "non-decreasing" implies but does not name.
    try testing.expectEqual(e0, out[0]);
    try testing.expect((out[1] == e1a and out[2] == e1b) or (out[1] == e1b and out[2] == e1a));
    try testing.expectEqual(e2, out[3]);

    // The FULL key, not the entity alone: within one entity the two bodies are
    // ordered by `BodyId`, which is what makes the answer a function of the set and
    // not of the arrival order.
    try testing.expectEqual(@min(e1a, e1b), out[1]);
    try testing.expectEqual(@max(e1a, e1b), out[2]);

    // INVARIANCE: the reverse arrival order gives the identical sequence. Without
    // this the assertions above would also hold for a collector that happened to
    // receive its candidates already sorted.
    var out2: [8]BodyId = undefined;
    var c2 = f.collector(&out2);
    for ([_]BodyId{ e1b, e0, e1a, e2 }) |b| c2.add(b);
    try testing.expectEqual(@as(u32, 4), c2.finish());
    try testing.expectEqualSlices(BodyId, out[0..4], out2[0..4]);
}

test "OverlapCollector retains the best under the key when the buffer overflows" {
    const gpa = testing.allocator;
    var f: Fixture = .{};
    defer f.deinit(gpa);

    // THE OTHER HALF, and the one a proof written on `finish` alone would miss:
    // `add` carries the replace-worst and decides what is RETAINED; `finish` only
    // orders a prefix that was already chosen. A collector that kept the first two
    // arrivals and sorted them would pass every assertion of the test above.
    const e3 = try f.addOn(gpa, 3);
    const e1 = try f.addOn(gpa, 1);
    const e2 = try f.addOn(gpa, 2);
    const e0 = try f.addOn(gpa, 0);

    // The two WORST arrive first, so a first-come collector would keep exactly the
    // wrong pair.
    var out: [2]BodyId = undefined;
    var c = f.collector(&out);
    for ([_]BodyId{ e3, e2, e1, e0 }) |b| c.add(b);
    try testing.expectEqual(@as(u32, 2), c.finish());
    try testing.expectEqual(e0, out[0]);
    try testing.expectEqual(e1, out[1]);

    // And the retained set does not depend on the arrival order — the property that
    // makes a TRUNCATED answer invariant under a permutation of creation order.
    var out2: [2]BodyId = undefined;
    var c2 = f.collector(&out2);
    for ([_]BodyId{ e0, e1, e2, e3 }) |b| c2.add(b);
    try testing.expectEqual(@as(u32, 2), c2.finish());
    try testing.expectEqualSlices(BodyId, out[0..2], out2[0..2]);

    // NON-VACUITY: with room for everything, all four come back — so the pair above
    // is a retention decision and not a collector that only ever accepts two.
    var big: [8]BodyId = undefined;
    var c3 = f.collector(&big);
    for ([_]BodyId{ e3, e2, e1, e0 }) |b| c3.add(b);
    try testing.expectEqual(@as(u32, 4), c3.finish());
    try testing.expectEqual(e0, big[0]);
    try testing.expectEqual(e3, big[3]);

    // A ZERO-length buffer accepts nothing and does not index out of bounds.
    var none: [0]BodyId = undefined;
    var c4 = f.collector(&none);
    for ([_]BodyId{ e3, e2, e1, e0 }) |b| c4.add(b);
    try testing.expectEqual(@as(u32, 0), c4.finish());
}
