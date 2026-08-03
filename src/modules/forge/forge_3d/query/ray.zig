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
//! `root.zig` owns the shared vocabulary (`Filter`, `Ray`, `RayHit`) and the
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
const hitLess = root.hitLess;
const BackFaceMode = api.BackFaceMode;

/// The exact per-candidate test every collector runs: filter, then kernel, then
/// world-space assembly. `null` means "no hit to offer" — a filtered candidate, a
/// stale handle, or a genuine miss.
///
/// **Total since M1.1.11.** It returned `Error!?RayHit` because the kernel could
/// answer `error.UnsupportedShape`, and each collector latched that error in a field
/// for its entry to surface. The kernel's rounded-box refusal is an asserted
/// precondition now, and it was reachable through no body anyway — every stored box
/// converts with `radius = 0`. Nothing a candidate BODY can be makes this test fail,
/// so there is no latch left to keep (§1.11.7).
fn evaluate(
    bm: *const BodyManager,
    store: *const ShapeStore,
    filter: Filter,
    ray: Ray,
    back_face_mode: BackFaceMode,
    user_data: u32,
) ?RayHit {
    const body: BodyId = user_data;
    // The layer getter also answers staleness: a freed handle has no layer.
    const layer = bm.collisionLayer(body) orelse return null;
    if (!filter.accepts(layer, body)) return null;

    // ONE hit per body, whatever the shape: the adapter resolves a mesh's nearest accepted
    // triangle itself, so nothing here changed for the mesh and nothing had to (§1.11.17).
    // The mode is passed through because a mesh is the only shape whose ANSWER depends on
    // it.
    const local = bm.raycastBody(store, body, ray, back_face_mode) orelse return null;
    const rotation = bm.rotation(body) orelse return null;
    const owner = bm.entity(body) orelse return null;
    return .{
        .body = body,
        .entity = owner,
        // The SUB-SHAPE the kernel hit — a mesh's triangle index, and `0` for every other
        // shape, which consumes zero bits of the path (§1.11.16). Filled for the FIRST
        // time here: until M1.1.11.1 nothing wrote it and the default WAS the value.
        .subshape_id = local.subshape_id,
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
    back_face_mode: BackFaceMode = .ignore,
    best: ?RayHit = null,

    pub fn add(self: *ClosestCollector, user_data: u32) void {
        const hit = evaluate(self.bm, self.store, self.filter, self.ray, self.back_face_mode, user_data) orelse return;
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
    back_face_mode: BackFaceMode = .ignore,
    found: bool = false,

    pub fn add(self: *AnyCollector, user_data: u32) void {
        if (self.found) return;
        const hit = evaluate(self.bm, self.store, self.filter, self.ray, self.back_face_mode, user_data) orelse return;
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
    back_face_mode: BackFaceMode = .ignore,
    out: []RayHit,
    count: u32 = 0,

    pub fn add(self: *AllCollector, user_data: u32) void {
        const hit = evaluate(self.bm, self.store, self.filter, self.ray, self.back_face_mode, user_data) orelse return;
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
