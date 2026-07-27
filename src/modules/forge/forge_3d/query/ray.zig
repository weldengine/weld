//! `forge_3d/query/ray.zig` — the three ray collectors and the per-candidate test
//! they share (M1.1.10 / E5).
//!
//! **Moved out of `query.zig` TEXTUALLY UNCHANGED.** Everything below this prelude is
//! the M1.1.9 code as delivered, including the E1 ordering-key edit: the only
//! alterations are the three `pub` markers the split requires, so that `root.zig` can
//! name the collectors it constructs. Nothing was reworded, renamed or reflowed —
//! the point of splitting in its own commit is that the diff can be read at `-M` and
//! seen to move rather than change.
//!
//! `root.zig` owns the shared vocabulary (`Filter`, `Ray`, `RayHit`, `Error`) and the
//! ordering key; this file owns only the three selection modes and the exact
//! per-candidate test. The two import each other, which Zig resolves lazily at file
//! granularity — the same shape the narrowphase package already has between
//! `epa.zig` and `gjk.zig`.

const std = @import("std");
const config = @import("../config.zig");
const body_manager_mod = @import("../body_manager.zig");
const api = @import("weld_forge");
const root = @import("root.zig");

const Real = config.Real;
const BodyId = api.BodyId;
const BodyManager = body_manager_mod.BodyManager;
const ShapeStore = body_manager_mod.ShapeStore;
const Ray = root.Ray;
const Filter = root.Filter;
const RayHit = root.RayHit;
const Error = root.Error;
const hitLess = root.hitLess;

/// The exact per-candidate test every collector runs: filter, then kernel, then
/// world-space assembly. `null` means "no hit to offer" — a filtered candidate, a
/// stale handle, or a genuine miss; an error means the shape is unsupported and
/// is latched by the caller.
fn evaluate(
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    ray: Ray,
    user_data: u32,
) Error!?RayHit {
    const body: BodyId = user_data;
    // The layer getter also answers staleness: a freed handle has no layer.
    const layer = bm.collisionLayer(body) orelse return null;
    if (!filter.accepts(layer, body)) return null;

    const local = (try bm.raycastBody(store, body, ray)) orelse return null;
    const rotation = bm.rotation(body) orelse return null;
    const owner = bm.entity(body) orelse return null;
    return .{
        .body = body,
        .entity = owner,
        .position = ray.origin.add(ray.direction.scale(local.distance)),
        // The kernel answers in the body's local frame; the distance is invariant
        // under a rigid transform (a rotation and a translation preserve it, and
        // the direction is unit in both frames), so only the normal is carried
        // back to world.
        .normal = rotation.rotateVec3(local.normal),
        .distance = local.distance,
    };
}

/// `closest`: tightens its bound to every accepted hit, so the rest of the
/// traversal is pruned against the best distance so far.
pub const ClosestCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    ray: Ray,
    bound: Real,
    best: ?RayHit = null,
    err: ?Error = null,

    pub fn add(self: *ClosestCollector, user_data: u32) void {
        const hit = (evaluate(self.bm, self.store, self.filter, self.ray, user_data) catch |e| {
            self.err = e;
            return;
        }) orelse return;
        if (hit.distance > self.bound) return; // beyond the window, closed at the bound
        if (self.best) |best| {
            // The SAME total order the sort uses (`(distance, entity, BodyId)`,
            // §1.11.14), so `closest` and an `all` truncated to one slot cannot
            // disagree — sharing the comparator is what makes that structural rather
            // than a coincidence of two hand-written comparisons.
            if (!hitLess(void{}, hit, best)) return;
        }
        self.best = hit;
        // Tightened TO the hit distance, not below it, so a body at exactly the
        // same distance still reaches the tie-break above.
        self.bound = hit.distance;
    }

    pub fn maxDistance(self: *const ClosestCollector) Real {
        return self.bound;
    }

    /// Never stops early: the minimum is only known once the traversal is done.
    pub fn shouldStop(_: *const ClosestCollector) bool {
        return false;
    }
};

/// `any`: STOPS at the first accepted hit. It also drops its bound to zero, which
/// prunes anything still in flight, but the bound alone would not terminate — a
/// zero bound still admits every node whose interval contains the ray origin, and
/// says nothing about the layer trees not yet walked. `shouldStop` is what makes
/// "terminates at the first candidate" true.
pub const AnyCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    ray: Ray,
    bound: Real,
    found: bool = false,
    err: ?Error = null,

    pub fn add(self: *AnyCollector, user_data: u32) void {
        if (self.found) return;
        const hit = (evaluate(self.bm, self.store, self.filter, self.ray, user_data) catch |e| {
            self.err = e;
            return;
        }) orelse return;
        if (hit.distance > self.bound) return;
        self.found = true;
        self.bound = 0;
    }

    pub fn maxDistance(self: *const AnyCollector) Real {
        return self.bound;
    }

    /// True from the first accepted hit — the traversal ends, trees included.
    pub fn shouldStop(self: *const AnyCollector) bool {
        return self.found;
    }
};

/// `all`: never tightens. Keeps the nearest `out.len` hits (see `raycastAll`).
pub const AllCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    ray: Ray,
    bound: Real,
    out: []RayHit,
    count: u32 = 0,
    err: ?Error = null,

    pub fn add(self: *AllCollector, user_data: u32) void {
        const hit = (evaluate(self.bm, self.store, self.filter, self.ray, user_data) catch |e| {
            self.err = e;
            return;
        }) orelse return;
        if (hit.distance > self.bound) return;

        if (self.count < self.out.len) {
            self.out[self.count] = hit;
            self.count += 1;
            return;
        }
        if (self.out.len == 0) return;

        // Full: replace the current worst under `(distance, entity, BodyId)` if this
        // hit is better, so the retained set is the best `out.len` whatever the order
        // of arrival. Linear in the buffer, which only matters once the caller has
        // already accepted a truncated answer.
        var worst: usize = 0;
        for (self.out[1..], 1..) |candidate, i| {
            if (hitLess(void{}, self.out[worst], candidate)) worst = i;
        }
        if (hitLess(void{}, hit, self.out[worst])) self.out[worst] = hit;
    }

    pub fn maxDistance(self: *const AllCollector) Real {
        return self.bound;
    }

    /// Never stops early — every hit within the window is wanted.
    pub fn shouldStop(_: *const AllCollector) bool {
        return false;
    }
};
