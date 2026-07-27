//! `forge_3d/query/root.zig` — the `Real`-bound spatial-query orchestration
//! (M1.1.9; moved into the `query/` package unchanged at M1.1.10 / E5).
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
//! the first, `all` never tightens.
//!
//! **The order is `(distance, entity, BodyId)`** (§1.11.14). Distances are compared
//! EXACTLY, with no tolerance; the owning entity breaks an exact tie, and `BodyId`
//! only breaks a tie between two bodies of the same entity. `BodyId` cannot lead
//! that key: it is a slot index, so it encodes creation order, and preferring the
//! smallest prefers the bodies created first — the inverse of the invariance
//! §1.11.6 claims.
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
const config = @import("../config.zig");
const broadphase_mod = @import("../pipeline/broadphase.zig");
const body_manager_mod = @import("../body_manager.zig");
const api = @import("weld_forge");
// The ray collectors, split out at M1.1.10/E5 and moved unchanged. Aliased here so
// every construction site below stays textually identical to the M1.1.9 code.
const ray_mod = @import("ray.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyId = api.BodyId;
const EntityId = api.EntityId;
const BodyManager = body_manager_mod.BodyManager;
const ShapeStore = body_manager_mod.ShapeStore;
const Broadphase = broadphase_mod.Broadphase(Real);
const ClosestCollector = ray_mod.ClosestCollector;
const AnyCollector = ray_mod.AnyCollector;
const AllCollector = ray_mod.AllCollector;

/// The world-space ray the broadphase traversal and the kernels share, at solver
/// precision.
pub const Ray = broadphase_mod.Ray(Real);

/// Number of object layers a 32-bit mask can address — the public contract's
/// constant, not a second copy of it. `addBody` rejects a body beyond this domain
/// with `error.InvalidCollisionLayer`, and the assert in `Filter.accepts` is the
/// defensive echo of that rejection.
pub const layer_bits: u8 = api.collision_layer_count;

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

/// One ray hit at solver precision — the mirror of the public `RaycastHit`
/// (`engine-tier-interfaces.md` §1) at `Real`. Converting to that f32 form is the
/// interface tier's business (M1.1.15); nothing in this milestone does it.
pub const RayHit = struct {
    /// The body hit.
    body: BodyId,
    /// The ECS entity owning that body — the ordering key's leading identity
    /// (§1.11.14), carried here rather than resolved at every comparison. The public
    /// `RaycastHit` carries it too, so the mirror is not widened by holding it.
    entity: EntityId,
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
/// `(distance, entity, BodyId)`. Returns the number WRITTEN, never more than
/// `out.len`.
///
/// When more bodies are hit than `out` can hold, the ones kept are the BEST under
/// that key — a full buffer replaces its current worst entry rather than dropping
/// whatever arrives late. That is what keeps the result invariant under a
/// permutation of creation order (§1.11.6, §1.11.14), which a traversal-order
/// truncation would not be. The bound is still never tightened, so the traversal
/// cost is the same as an unbounded `all`.
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

// --- The rest of the frozen family: Phase-1 stubs ---
//
// The five entries below carry their FROZEN signatures — `engine-tier-interfaces.md`
// §1, at the f32 public boundary — and are owned by M1.1.10. They exist here, now,
// because a comptime strategy interface cannot gain a method after its freeze
// without breaking every Tier 3 solver (§1.11.7).
//
// Their bodies `@panic`, and that is a decision rather than laziness. The
// `error.NotImplemented` pattern of §1.5 works for `createJoint` because it
// returns `anyerror!JointId` and therefore HAS somewhere to put the error. These
// signatures have no error channel — `shapeCast` returns `?ShapeCastHit`, the
// three others return a `u32` count — so a stub returning `null` or `0` would be
// a silent lie in the caller's own vocabulary ("no hit", "no entities"), the exact
// class this milestone has been closing since E3. Failing loud costs nothing and
// touches nothing that freezes.
//
// The raycast trio is NOT stubbed here: it is implemented, at `Real`, above. Its
// f32 wrapper belongs to the interface tier (M1.1.15), which is the only place
// that ever knows both scalars.

/// Cast a shape along a direction — **M1.1.10**. Signature frozen here.
pub fn shapeCast(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    q: api.ShapeCastQuery,
) ?api.ShapeCastHit {
    _ = .{ bp, bm, store, q };
    @panic("shapeCast is M1.1.10; its signature freezes at M1.1.9");
}

/// Entities overlapping a shape — **M1.1.10**. Signature frozen here.
pub fn overlapShape(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    q: api.OverlapQuery,
    out: []api.EntityId,
) u32 {
    _ = .{ bp, bm, store, q, out };
    @panic("overlapShape is M1.1.10; its signature freezes at M1.1.9");
}

/// Entities overlapping a world AABB — **M1.1.10**. Signature frozen here. The
/// cheapest query of the family: it stops at the broadphase, and
/// `Bvh.queryAabb` already implements the traversal it needs.
pub fn overlapAabb(
    bp: *const Broadphase,
    bm: *const BodyManager,
    min: Vec3r,
    max: Vec3r,
    filter: api.PhysicsQueryFilter,
    out: []api.EntityId,
) u32 {
    _ = .{ bp, bm, min, max, filter, out };
    @panic("overlapAabb is M1.1.10; its signature freezes at M1.1.9");
}

/// Entities containing a point (shapes solid, §1.11.4) — **M1.1.10**. Signature
/// frozen here.
pub fn pointQuery(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    point: Vec3r,
    filter: api.PhysicsQueryFilter,
    out: []api.EntityId,
) u32 {
    _ = .{ bp, bm, store, point, filter, out };
    @panic("pointQuery is M1.1.10; its signature freezes at M1.1.9");
}

/// Closest point on the closest collider within `max_distance` — **M1.1.10**.
/// Signature frozen here.
pub fn closestPoint(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    point: Vec3r,
    max_distance: Real,
    filter: api.PhysicsQueryFilter,
) ?api.ClosestPointResult {
    _ = .{ bp, bm, store, point, max_distance, filter };
    @panic("closestPoint is M1.1.10; its signature freezes at M1.1.9");
}

/// Total order on entity identity, as one sortable integer: `index` major,
/// `generation` minor.
///
/// Deliberately NOT `@bitCast`. `EntityId` is a `packed struct(u64)` whose `index`
/// occupies the LOW 32 bits, so a bitcast would order by `generation` first — a
/// layout accident, not a decision. What the key actually has to be is a function of
/// the entity identity ALONE, so that it is invariant under a permutation of
/// creation order (§1.11.14); both orders satisfy that, and this one also reads the
/// way entities are named.
///
/// `EntityId.dead` (both fields `maxInt`) sorts last and needs no special case.
fn entityKey(e: EntityId) u64 {
    return (@as(u64, e.index) << 32) | @as(u64, e.generation);
}

/// Total order on hits: distance, then the OWNING ENTITY, then `BodyId`. The
/// composite key makes the sort's outcome independent of its stability.
///
/// **Why `BodyId` cannot lead this key.** It is a slot index, so it encodes creation
/// order; retaining the smallest retains the bodies created FIRST, which is the
/// inverse of the invariance §1.11.6 claims for the family. The only identity stable
/// under a permutation of creation order is the scene's, that is the owning entity
/// (§1.11.14). MEASURED on `main` at the M1.1.9 tag, at f32: two unit spheres at
/// `(20, ±0.5, 0)` against a ray from the origin along +X both return
/// `19.133974075`, bit-identical because the squared perpendicular offset is `0.25`
/// on either side, and exchanging the two creation orders exchanged the entity
/// answered — for the closest hit as much as for the answer truncated to one slot.
/// A symmetric scene is not a measure-zero case: mirrored cover, or props on a grid,
/// produce it.
///
/// The distance comparison is EXACT, with no tolerance: a tie here means
/// bit-identical, and any tolerance would make the order depend on a threshold.
///
/// `BodyId` survives as the FINAL tie-break, for the residual §1.11.14 names:
/// nothing forces one body per entity, and two bodies of the same entity at an
/// exactly equal distance are not invariant under creation order.
pub fn hitLess(_: void, x: RayHit, y: RayHit) bool {
    if (x.distance != y.distance) return x.distance < y.distance;
    const x_entity = entityKey(x.entity);
    const y_entity = entityKey(y.entity);
    if (x_entity != y_entity) return x_entity < y_entity;
    return x.body < y.body;
}

/// Validate the query domain and build the traversal ray, or `null` when the
/// query is degenerate and its result is empty by definition.
///
/// The domain assert mirrors the solver passes (§1.11.4): finite origin and
/// direction, finite `max_distance >= 0`.
///
/// The direction is reduced by its LARGEST COMPONENT before anything is squared,
/// which is what keeps both ends of the float range safe. Squaring first is unsafe
/// at both: `(1e20, 0, 0)` is perfectly finite and passes the domain assert, yet
/// `lengthSq()` overflows to infinity at f32; and a direction so small that its
/// square underflows would read as zero. After the reduction every component is in
/// `[0, 1]`, so the squared length lies in `[1, 3]` and can do neither.
///
/// The reduction is a component-wise DIVISION, deliberately not a multiplication by
/// `1 / scale`: for a denormal direction that reciprocal overflows to infinity and
/// the defect reappears at the other end of the range.
///
/// The `scale == 0` test is at TRUE ZERO and subsumes the old `d · d == 0` guard —
/// the largest absolute component is zero exactly when all three are. A zero
/// direction is a degenerate query, not a programming error, so it returns an empty
/// result rather than firing.
fn prepare(query: RayQuery) ?Ray {
    std.debug.assert(std.math.isFinite(query.max_distance) and query.max_distance >= 0);
    std.debug.assert(@reduce(.And, @abs(query.origin.data) < @as(@Vector(3, Real), @splat(std.math.inf(Real)))));
    std.debug.assert(@reduce(.And, @abs(query.direction.data) < @as(@Vector(3, Real), @splat(std.math.inf(Real)))));

    const scale = @reduce(.Max, @abs(query.direction.data));
    if (scale == 0) return null;
    const reduced: Vec3r = .{ .data = query.direction.data / @as(@Vector(3, Real), @splat(scale)) };
    // Normalised ONCE, here. Everything downstream — the traversal, the kernels,
    // the returned distance — is in units of this unit direction, which is why a
    // hit carries a distance and never a fraction.
    return Ray.init(query.origin, reduced.scale(1 / reduced.length()));
}
