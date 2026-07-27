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
    },
    /// Overlap of a world AABB: the body's TIGHT world AABB, faces included.
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
            .shape => |s| self.bm.overlapShapeBody(self.store, body, s.shape, s.position, s.rotation) orelse return,
            .aabb => |query_box| blk: {
                const tight = self.bm.bodyAabb(self.store, body) orelse return;
                break :blk tight.overlaps(query_box);
            },
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
pub fn closestPointCandidates(point: Vec3r, max_distance: Real) Aabbr {
    return Aabbr.fromMinMax(point, point).inflate(Vec3r.splat(max_distance));
}

/// The degenerate AABB of a single point — the point query's candidate set
/// (§1.11.12).
pub fn pointAabb(point: Vec3r) Aabbr {
    return Aabbr.fromMinMax(point, point);
}
