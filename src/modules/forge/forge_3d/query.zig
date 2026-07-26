//! `forge_3d/query.zig` — the `Real`-bound spatial-query orchestration (M1.1.9).
//!
//! **Owns no state.** It takes `(bp, bm, store)` as parameters, the shape of
//! `rigid.build`. A query mutates nothing, wakes nobody, and appears nowhere in
//! the eleven-step tick cycle: it reads the poses and the broadphase trees as
//! they stand (`engine-physics-forge.md` §1.11.1). A sleeping body answers
//! queries — its proxy is still in the tree, step 10 skips its *update*, not its
//! presence — and being read is not a solicitation in the §1.8.4 sense.
//!
//! **Two filtering axes, never substituted for one another.** The simulation
//! filters PAIRS through the broad-layer matrix; a query has no second body, so
//! it visits all four trees and filters candidates on their OBJECT layer with a
//! 32-bit mask plus a per-body exclusion list (§1.11.5). The predicate is written
//! per SUB-SHAPE and merely degenerates to per-body while one shape is one body,
//! so compound shapes will extend it instead of rewriting it.
//!
//! **Three selection modes, one traversal, three collectors** (§1.11.6):
//! `closest` tightens its bound on every accepted hit, `any` drops it to zero at
//! the first, `all` never tightens. On an exactly equal distance — compared
//! exactly, with no tolerance — the smaller `BodyId` wins, the only total order
//! this engine has established.
//!
//! **The exact kernel can fail, and the collector contract cannot.**
//! `queryRay`'s collector exposes `add(u32) void`, so a kernel error is LATCHED
//! in a collector field and surfaced by the entry function — the `PairSink.err`
//! pattern `computePairs` already uses for OOM. Never swallowed, never
//! `catch unreachable`, and the collector contract stays as the traversal
//! defines it.
//!
//! **Precision.** Everything here is at the solver scalar. The public surface
//! stays `f32` (§1.11.8); that boundary lives at the interface tier (M1.1.15),
//! not in this file.

const std = @import("std");
const config = @import("config.zig");
const broadphase_mod = @import("pipeline/broadphase.zig");
const narrowphase = @import("pipeline/narrowphase/root.zig");
const body_manager_mod = @import("body_manager.zig");
const api = @import("weld_forge");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyId = api.BodyId;
const BodyManager = body_manager_mod.BodyManager;
const ShapeStore = body_manager_mod.ShapeStore;
const Broadphase = broadphase_mod.Broadphase(Real);

/// The world-space ray the broadphase traversal and the kernels share, at solver
/// precision.
pub const Ray = broadphase_mod.Ray(Real);

/// Number of object layers a 32-bit mask can address. A body declared outside
/// `[0, layer_bits)` would be invisible to every query with no diagnostic, so
/// `addBody` rejects it (`error.InvalidCollisionLayer`, E5) — the assert in
/// `Filter.accepts` is the defensive echo of that.
pub const layer_bits: u8 = 32;

/// Errors a query can surface. `UnsupportedShape` comes from the exact kernel —
/// a rounded box today — and is propagated rather than read as a miss.
pub const Error = error{UnsupportedShape};

/// Query filtering, shared by the whole family (§1.11.5): a mask over OBJECT
/// layers and a list of bodies to ignore.
pub const Filter = struct {
    /// A candidate passes when `(1 << layer) & layer_mask` is non-zero.
    layer_mask: u32 = 0xFFFF_FFFF,
    /// Bodies to ignore. The dominant case, by far, is "myself".
    exclude: []const BodyId = &.{},

    /// Whether a candidate sub-shape on `layer`, belonging to `body`, passes.
    ///
    /// The layer is the SUB-SHAPE's, not the body's: they coincide while one
    /// shape is one body, and writing it this way is what keeps compound shapes
    /// from forcing a rewrite. Exclusions are tested on the body, upstream of the
    /// exact kernel, because that is the whole point of excluding it.
    pub fn accepts(self: Filter, subshape_layer: u8, body: BodyId) bool {
        // Defensive: `addBody` rejects a layer outside the mask's domain, so this
        // cannot fire. Kept because the alternative to failing here is a silent
        // miss, which is the one outcome the domain rule exists to prevent.
        std.debug.assert(subshape_layer < layer_bits);
        const bit = @as(u32, 1) << @intCast(subshape_layer);
        if (bit & self.layer_mask == 0) return false;
        for (self.exclude) |excluded| {
            if (excluded == body) return false;
        }
        return true;
    }
};

/// A ray query at solver precision. `direction` need not be unit — the entry
/// normalises it once — and `max_distance` is a CLOSED bound: a hit exactly at
/// it counts. `max_distance == 0` is legal and degenerates into a point test.
pub const RayQuery = struct {
    origin: Vec3r,
    direction: Vec3r,
    max_distance: Real,
    filter: Filter = .{},
};

/// One ray hit at solver precision. The public `RaycastHit` (f32, with the
/// entity) is the interface tier's business; nothing in this milestone converts
/// to it.
pub const RayHit = struct {
    /// The body hit.
    body: BodyId,
    /// Which sub-shape of that body was hit; 0 while one shape is one body.
    subshape_id: u32 = 0,
    /// World-space hit point.
    position: Vec3r,
    /// World-space outward unit surface normal at the hit point.
    normal: Vec3r,
    /// Distance from the ray origin, in `[0, max_distance]`.
    distance: Real,
};

/// Nearest hit along the ray, or `null` when nothing is hit within
/// `max_distance`.
pub fn raycast(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    query: RayQuery,
) Error!?RayHit {
    const ray = prepare(query) orelse return null;
    var collector = ClosestCollector{
        .bm = bm,
        .store = store,
        .filter = query.filter,
        .ray = ray,
        .bound = query.max_distance,
    };
    _ = bp.queryRay(ray, &collector);
    if (collector.err) |e| return e;
    return collector.best;
}

/// Whether ANYTHING is hit within `max_distance`. Terminates at the first
/// accepted candidate instead of searching for the minimum, which is a different
/// traversal termination and not sugar over `raycast` — the dominant consumer
/// (Cortex line of sight) only ever reads this bit.
pub fn raycastAny(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    query: RayQuery,
) Error!bool {
    const ray = prepare(query) orelse return false;
    var collector = AnyCollector{
        .bm = bm,
        .store = store,
        .filter = query.filter,
        .ray = ray,
        .bound = query.max_distance,
    };
    _ = bp.queryRay(ray, &collector);
    if (collector.err) |e| return e;
    return collector.found;
}

/// Every hit within `max_distance`, written into `out` and sorted by
/// `(distance, BodyId)`. Returns the number WRITTEN, never more than `out.len`.
///
/// When more bodies are hit than `out` can hold, the ones kept are the NEAREST —
/// a full buffer replaces its current worst entry rather than dropping whatever
/// arrives late. That is what keeps the result invariant under a permutation of
/// creation order (§1.11.6), which a traversal-order truncation would not be. The
/// bound is still never tightened, so the traversal cost is the same as an
/// unbounded `all`.
pub fn raycastAll(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    query: RayQuery,
    out: []RayHit,
) Error!u32 {
    const ray = prepare(query) orelse return 0;
    var collector = AllCollector{
        .bm = bm,
        .store = store,
        .filter = query.filter,
        .ray = ray,
        .bound = query.max_distance,
        .out = out,
    };
    _ = bp.queryRay(ray, &collector);
    if (collector.err) |e| return e;
    const written = collector.count;
    std.mem.sort(RayHit, out[0..written], {}, hitLess);
    return written;
}

/// Total order on hits: distance first, then `BodyId`. The composite key makes
/// the sort's outcome independent of its stability.
fn hitLess(_: void, x: RayHit, y: RayHit) bool {
    if (x.distance != y.distance) return x.distance < y.distance;
    return x.body < y.body;
}

/// Validate the query domain and build the traversal ray, or `null` when the
/// query is degenerate and its result is empty by definition.
///
/// The domain assert mirrors the solver passes (§1.11.4): finite origin and
/// direction, finite `max_distance >= 0`. The zero-direction guard is at TRUE
/// ZERO on `d · d` — the square underflows for any unusably small direction at
/// both precisions, so the true-zero test covers the denormal case for free and
/// no epsilon is needed. A zero direction is a degenerate query, not a
/// programming error, so it returns an empty result rather than firing.
fn prepare(query: RayQuery) ?Ray {
    std.debug.assert(std.math.isFinite(query.max_distance) and query.max_distance >= 0);
    std.debug.assert(@reduce(.And, @abs(query.origin.data) < @as(@Vector(3, Real), @splat(std.math.inf(Real)))));
    std.debug.assert(@reduce(.And, @abs(query.direction.data) < @as(@Vector(3, Real), @splat(std.math.inf(Real)))));

    const len_sq = query.direction.lengthSq();
    if (len_sq == 0) return null;
    // Normalised ONCE, here. Everything downstream — the traversal, the kernels,
    // the returned distance — is in units of this unit direction, which is why a
    // hit carries a distance and never a fraction.
    return Ray.init(query.origin, query.direction.scale(1 / @sqrt(len_sq)));
}

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
    return .{
        .body = body,
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
const ClosestCollector = struct {
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
            // Exact comparison, no tolerance. On a bit-identical distance the
            // smaller `BodyId` wins (§1.11.6).
            if (hit.distance > best.distance) return;
            if (hit.distance == best.distance and hit.body >= best.body) return;
        }
        self.best = hit;
        // Tightened TO the hit distance, not below it, so a body at exactly the
        // same distance still reaches the tie-break above.
        self.bound = hit.distance;
    }

    pub fn maxDistance(self: *const ClosestCollector) Real {
        return self.bound;
    }
};

/// `any`: drops its bound to zero at the first accepted hit, which prunes every
/// remaining descent that does not contain the ray origin.
const AnyCollector = struct {
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
};

/// `all`: never tightens. Keeps the nearest `out.len` hits (see `raycastAll`).
const AllCollector = struct {
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

        // Full: replace the current worst by `(distance, BodyId)` if this hit is
        // better, so the retained set is the nearest `out.len` whatever the order
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
};
