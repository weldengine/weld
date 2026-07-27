//! `forge_3d/query/cast.zig` — the shape-cast collector and its per-candidate
//! evaluation (M1.1.10 / E5).
//!
//! The cast's selection is the ray's `closest` and nothing else: one hit, the
//! nearest, with the bound tightened TO each accepted time of impact so the rest of
//! the swept traversal is pruned against it. That tightening is sound because the
//! entry parameter of an inflated node is a LOWER BOUND of the true time of impact
//! against any leaf it contains (`engine-physics-forge.md` §1.11.10).
//!
//! Ordering is the family's, `(distance, entity, BodyId)` — §1.11.14 — through the
//! same comparator `root.zig` gives the ray family, so the two cannot drift.
//!
//! No error channel: the cast kernel covers every bounded convex through its support
//! map and has no shape to reject (§1.11.11). That is why this collector needs no
//! `err` latch, unlike `ray.zig`'s.

const config = @import("../config.zig");
const body_manager_mod = @import("../body_manager.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const api = @import("weld_forge");
const root = @import("root.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const BodyId = api.BodyId;
const BodyManager = body_manager_mod.BodyManager;
const ShapeStore = body_manager_mod.ShapeStore;
const Filter = root.Filter;
const CastHit = root.CastHit;

/// `closest` over a swept volume: tightens its bound to every accepted time of
/// impact, so the rest of the traversal is pruned against the best so far.
pub const CastCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    /// The cast shape's support form, resolved once at the entry.
    shape: narrowphase.SupportShape(Real),
    /// The cast shape's pose at the START of the sweep. A sweep is a pure
    /// translation, so this is a constant of the whole query.
    origin: Vec3r,
    rotation: Quatr,
    /// World-space unit direction, normalised once at the entry.
    direction: Vec3r,
    bound: Real,
    best: ?CastHit = null,

    pub fn add(self: *CastCollector, user_data: u32) void {
        const body: BodyId = user_data;
        // The layer getter also answers staleness: a freed handle has no layer.
        const layer = self.bm.collisionLayer(body) orelse return;
        if (!self.filter.accepts(layer, body)) return;

        // The bound is handed to the kernel too, so a candidate beyond the best so
        // far is refused inside the march rather than after it.
        const local = self.bm.castShapeBody(
            self.store,
            body,
            self.shape,
            self.origin,
            self.rotation,
            self.direction,
            self.bound,
        ) orelse return;
        const owner = self.bm.entity(body) orelse return;

        const hit: CastHit = .{
            .body = body,
            .entity = owner,
            .position = local.position,
            .normal = local.normal,
            .distance = local.distance,
        };
        if (self.best) |best| {
            // The SAME total order the family sorts on, so `closest` here and a
            // one-slot `all` elsewhere cannot disagree.
            if (!root.castLess(void{}, hit, best)) return;
        }
        self.best = hit;
        // Tightened TO the distance, not below it, so a body at exactly the same
        // distance still reaches the tie-break above.
        self.bound = hit.distance;
    }

    pub fn maxDistance(self: *const CastCollector) Real {
        return self.bound;
    }

    /// Never stops early: the minimum is only known once the traversal is done.
    pub fn shouldStop(_: *const CastCollector) bool {
        return false;
    }
};
