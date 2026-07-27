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
//! **Only the two entries taking a caller-supplied SHAPE HANDLE carry an error**
//! (§1.11.7, M1.1.11): `shapeCast` and `overlapShape`. They separate a stale handle,
//! an inadmissible probe and a real miss — three outcomes a single `null` conflated.
//! The other six take no handle and are TOTAL. The three RAY entries carried
//! `error{UnsupportedShape}` until M1.1.11, latched per collector and surfaced by the
//! entry; the kernel's rounded-box refusal became an asserted precondition and the
//! latch went with it, since no body's shape could ever reach it.
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
const cast_mod = @import("cast.zig");
const overlap_mod = @import("overlap.zig");
const shape_mod = @import("../shape.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");

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
const Aabbr = config.Aabbr;
const Quatr = config.Quatr;
const ShapeId = api.ShapeId;

/// The world-space ray the broadphase traversal and the kernels share, at solver
/// precision.
pub const Ray = broadphase_mod.Ray(Real);

/// Number of object layers a 32-bit mask can address — the public contract's
/// constant, not a second copy of it. `addBody` rejects a body beyond this domain
/// with `error.InvalidCollisionLayer`, and the assert in `Filter.accepts` is the
/// defensive echo of that rejection.
pub const layer_bits: u8 = api.collision_layer_count;

/// Errors the two entries taking a caller-supplied SHAPE HANDLE can surface —
/// `shapeCast` and `overlapShape`, and no others (`engine-physics-forge.md`
/// §1.11.7). Together with a `null` / `0` answer they separate three outcomes a
/// single nullary value used to conflate, and each member is reachable from a
/// public entry by a caller mistake the caller can then diagnose:
///
///   - `InvalidShape` — the handle is stale or was never valid. Reachable by
///     destroying a shape and casting with its id; same name and same meaning as
///     `addBody`'s, not a second vocabulary for one situation.
///   - `UnsupportedShape` — the probe is a shape the exact kernel cannot express.
///     Reachable TODAY by passing a plane handle: the cast kernel is a ray march on
///     the Minkowski difference of the two cores (§1.11.11) and the shape overlap is
///     GJK on those cores (§1.11.12), and a half-space has no bounded core.
///
/// A real miss is `null` / `0`, and a ZERO DIRECTION is a miss too — a degenerate
/// query with an empty answer, not a malformed one (§1.11.11's domain table).
///
/// This is a RESHAPING, not an extension. Before E3 the set was
/// `error{UnsupportedShape}` on the three RAY entries, where it came from the
/// kernel's rounded-box latch and was reachable through no store shape at all; it
/// now lives on the two handle-taking entries, where a caller can cause both
/// members. The three members map one-for-one onto the frozen `WeldQueryStatus` of
/// `engine-c-api.md` — `WELD_QUERY_OK`, `WELD_QUERY_INVALID_SHAPE`,
/// `WELD_QUERY_UNSUPPORTED_SHAPE`.
pub const Error = error{ InvalidShape, UnsupportedShape };

/// Whether a caller-supplied probe shape is admissible for the two entries that take
/// one, i.e. a bounded convex the support map describes.
///
/// Exhaustive on the CLASS with no `else` arm: the mesh (M1.1.11.1) is a compile
/// error here and must state its own answer. A named function rather than an inline
/// comparison so both entries test the SAME condition and the tests can exercise it
/// on both answers without restating it.
fn probeAdmissible(record: shape_mod.Shape) bool {
    return switch (record.class()) {
        .convex => true,
        .half_space => false,
    };
}

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

/// A shape-cast query at solver precision — the mirror of the public
/// `ShapeCastQuery` (`engine-tier-interfaces.md` §1). `shape` is a store handle, as
/// the frozen public form has it: the cast shape is authored like any other, not
/// improvised at the call site. `direction` need not be unit (the kernel normalises
/// once) and `max_distance` is a CLOSED bound.
pub const CastQuery = struct {
    shape: ShapeId,
    origin: Vec3r,
    rotation: Quatr = Quatr.identity,
    direction: Vec3r,
    max_distance: Real,
    filter: Filter = .{},
};

/// One cast hit at solver precision — the mirror of the public `ShapeCastHit`.
/// Distinct from `RayHit` for the reason the public pair is distinct: a cast has TWO
/// sub-shapes, the one cast and the one hit.
pub const CastHit = struct {
    /// The body hit.
    body: BodyId,
    /// The ECS entity owning it — the ordering key's leading identity (§1.11.14).
    entity: EntityId,
    /// Which sub-shape of the hit body; 0 while one shape is one body.
    subshape_id: u32 = 0,
    /// Which sub-shape of the CAST shape; 0 for the same reason.
    cast_subshape_id: u32 = 0,
    /// World-space witness on the hit body's surface.
    position: Vec3r,
    /// World-space outward unit normal of the hit body; `normal · direction <= 0`.
    normal: Vec3r,
    /// Distance along the cast direction, in `[0, max_distance]`.
    distance: Real,
};

/// A shape-overlap request at solver precision — the mirror of the public
/// `OverlapQuery`. No distance, no bound: the three overlaps have nothing to tighten
/// (§1.11.12).
pub const OverlapRequest = struct {
    shape: ShapeId,
    position: Vec3r,
    rotation: Quatr = Quatr.identity,
    filter: Filter = .{},
};

/// The closest point on the closest body at solver precision — the mirror of the
/// public `ClosestPointResult`. `distance` is to the SOLID, so it is 0 for a point
/// inside one, boundary included (§1.11.13).
pub const ClosestPointHit = struct {
    /// The body whose surface is nearest.
    body: BodyId,
    /// The ECS entity owning it.
    entity: EntityId,
    /// Which sub-shape; 0 while one shape is one body.
    subshape_id: u32 = 0,
    /// World-space point on that body's surface, or the queried point when inside.
    position: Vec3r,
    /// Distance from the queried point to the body's solid.
    distance: Real,
};

/// Nearest hit along the ray, or `null` when nothing is hit within
/// `max_distance`.
pub fn raycast(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    query: RayQuery,
) ?RayHit {
    const ray = prepare(query) orelse return null;
    var collector = ClosestCollector{
        .bm = bm,
        .store = store,
        .filter = query.filter,
        .ray = ray,
        .bound = query.max_distance,
    };
    _ = bp.queryRay(ray, &collector);
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
) bool {
    const ray = prepare(query) orelse return false;
    var collector = AnyCollector{
        .bm = bm,
        .store = store,
        .filter = query.filter,
        .ray = ray,
        .bound = query.max_distance,
    };
    _ = bp.queryRay(ray, &collector);
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
) u32 {
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
    const written = collector.count;
    std.mem.sort(RayHit, out[0..written], {}, hitLess);
    return written;
}

// --- The rest of the family, implemented at `Real` (M1.1.10 / E5) ---
//
// These five carried FROZEN `f32` signatures and `@panic` bodies since M1.1.9,
// because a comptime strategy interface cannot gain a method after its freeze.
// They now take the SOLVER scalar and return `[]BodyId`, for the reason
// `engine-physics-forge.md` §1.11.8 gives as a structural corollary: an entry typed
// `f32` INSIDE the solver would force the conversion into the solver — under
// `-Dphysics_f64`, a time of impact and a contact point narrowed to `f32` before
// even leaving the kernel and widened again at the interface tier, two conversions
// of which one is invisible, and the loss of exactly what the flag buys. The
// boundary is single and lives at the interface tier (M1.1.15).
//
// The PUBLIC types of `api/types.zig` and `engine-tier-interfaces.md` §1 are
// untouched by that move: they are the frozen surface, and `raycast_test.zig` still
// pins them as a change detector.
//
// No deduplication happens here. The solver's identity is the BODY and it returns
// bodies; two bodies of one entity are two answers. Projecting onto entities, and
// deduplicating, is owed by the tier that owns entities (§13, §1.11.14).

/// Nearest body the swept `query.shape` reaches, or `null` when nothing is hit
/// within `max_distance`.
///
/// The traversal is the swept one (§1.11.10): each node's box is inflated by the
/// half-extents of the cast shape's INITIAL world AABB, and the ray starts at that
/// AABB's CENTRE — not at `query.origin`. The two coincide for the three bounded
/// convexes the store builds, whose local AABB is centred on the origin, but that is a
/// property of those shapes and not of the model, so the centre is what is computed.
/// (The store also builds a plane since M1.1.11, which has no world AABB at all and is
/// refused as a probe above, before this box is ever built.) The AABB is a constant of
/// the query: a sweep is a pure translation.
pub fn shapeCast(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    query: CastQuery,
) Error!?CastHit {
    // The full §1.11.11 domain, asserted BEFORE the handle is resolved so a stale
    // shape cannot short-circuit it: origin, rotation unitary, direction finite, bound
    // finite and non-negative.
    std.debug.assert(std.math.isFinite(query.max_distance) and query.max_distance >= 0);
    assertFiniteVec(query.origin);
    assertFiniteVec(query.direction);
    assertUnitRotation(query.rotation);
    const record = store.get(query.shape) orelse return error.InvalidShape;
    // PROBE ADMISSIBILITY, before ANY use of the record and before the direction is
    // even looked at. Two reasons it cannot be moved later:
    //
    //   - `worldAabb` (below) and `shape_mod.supportShape` both carry a class
    //     precondition, and a `std.debug.assert` is compiled OUT of ReleaseFast — so
    //     without this check a plane probe is not a panic there but UNDEFINED
    //     BEHAVIOUR, `worldAabb` falling through to its `unreachable`. The two
    //     entries also touch those two in OPPOSITE orders, so no single downstream
    //     guard covers both.
    //   - A malformed probe outranks a degenerate direction. Both could hold at once,
    //     and the shape being inexpressible is the caller's error, whereas a zero
    //     direction is a legal query with an empty answer.
    if (!probeAdmissible(record)) return error.UnsupportedShape;
    const direction = unitDirection(query.direction) orelse return null;

    const box = body_manager_mod.worldAabb(record, query.origin, query.rotation);
    var collector = cast_mod.CastCollector{
        .bm = bm,
        .store = store,
        .filter = query.filter,
        .shape = shape_mod.supportShape(record),
        .origin = query.origin,
        .rotation = query.rotation,
        .direction = direction,
        .bound = query.max_distance,
    };
    _ = bp.queryCast(Ray.init(box.center(), direction), box.halfExtents(), &collector);
    return collector.best;
}

/// Bodies overlapping the posed `request.shape`, written into `out` and sorted by
/// `(entity, BodyId)`. Returns the number WRITTEN, never more than `out.len`.
///
/// The candidate set is the query shape's world AABB and the exact kernel is GJK on
/// the cores, accepted when the regime is not `separated` — no threshold of this
/// entry's own (§1.11.12).
pub fn overlapShape(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    request: OverlapRequest,
    out: []BodyId,
) Error!u32 {
    // Before the handle resolution, for the reason `assertFiniteVec` gives.
    assertFiniteVec(request.position);
    assertUnitRotation(request.rotation);
    const record = store.get(request.shape) orelse return error.InvalidShape;
    // PROBE ADMISSIBILITY, before any use of the record — see `shapeCast`, whose
    // argument applies here with the two downstream guards in the opposite order
    // (`supportShape` first, `worldAabb` second).
    if (!probeAdmissible(record)) return error.UnsupportedShape;
    var collector = overlap_mod.OverlapCollector{
        .bm = bm,
        .store = store,
        .filter = request.filter,
        .probe = .{ .shape = .{
            .shape = shape_mod.supportShape(record),
            .position = request.position,
            .rotation = request.rotation,
        } },
        .out = out,
    };
    _ = bp.queryAabb(body_manager_mod.worldAabb(record, request.position, request.rotation), &collector);
    return collector.finish();
}

/// Bodies whose TIGHT world AABB overlaps `[min, max]`, faces included, written into
/// `out` and sorted by `(entity, BodyId)`.
///
/// An INVERTED box — any component with `min > max` — denotes the empty set and
/// returns 0 without traversing (§1.11.12). A DEGENERATE box, `min == max`, is a legal
/// region and is answered normally.
///
/// **This is why the entry takes `store`.** The trees hold FAT boxes
/// (`BroadphaseConfig.margin`, default 0.1 m), so returning the candidate set would
/// report bodies that do not overlap the query — and the error would be a function
/// of a TUNING CONSTANT, so changing the margin would change a query's answer. The
/// exact kernel is therefore the body's tight world AABB, which `bodyAabb` computes
/// from the shape and the pose and which consequently needs the store. The entry
/// stops at AABB GRANULARITY, which is not the same thing as stopping at the
/// broadphase (§1.11.12).
pub fn overlapAabb(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    min: Vec3r,
    max: Vec3r,
    filter: Filter,
    out: []BodyId,
) u32 {
    assertFiniteVec(min);
    assertFiniteVec(max);
    // An INVERTED query box denotes the EMPTY SET and returns zero bodies, by an
    // explicit rejection here (§1.11.12). A component with `min > max` describes an
    // empty region on that axis, hence an empty region outright, so the entry answers
    // `0` WITHOUT TRAVERSING.
    //
    // Three things this is not, each for its own reason:
    //
    //   - Not an ASSERTION. It holds in debug only, and would leave the answer
    //     arbitrary where the engine actually runs — on an entry that returns a `u32`
    //     with no error channel, so a caller could not learn of the malformation even
    //     if it wanted to.
    //   - Not the overlap PREDICATE's job. `Aabb.overlaps` is written for well-formed
    //     boxes and serves the broadphase's hot path; on an inverted box it reduces to
    //     "does the body enclose both bounds", which is not a rejection at all.
    //   - Not defensive padding. It is the SEMANTICS of the region the caller
    //     described, and the rejection lives at the entry because that is where the
    //     caller's bounds cross the boundary.
    //
    // MEASURED before the fix, against a body whose tight AABB is `[−2, 2]³`: the box
    // `min = (1,1,1)`, `max = (−1,−1,−1)` returned ONE body, `min = (9,9,9)`,
    // `max = (−9,−9,−9)` returned ZERO, and an inversion on two axes only returned
    // ONE — the answer followed the amplitude and the axes of the malformation. A
    // DEGENERATE box (`min == max` on some or all axes) is a legal region, a point or
    // a slice, and is deliberately NOT rejected: the test is strict `>`.
    if (@reduce(.Or, min.data > max.data)) return 0;
    const query_box = Aabbr.fromMinMax(min, max);
    var collector = overlap_mod.OverlapCollector{
        .bm = bm,
        .store = store,
        .filter = filter,
        .probe = .{ .aabb = query_box },
        .out = out,
    };
    _ = bp.queryAabb(query_box, &collector);
    return collector.finish();
}

/// Bodies containing `point` — shapes SOLID, boundary included (§1.11.4) — written
/// into `out` and sorted by `(entity, BodyId)`. The candidate set is the degenerate
/// AABB `min = max = point`.
pub fn pointQuery(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    point: Vec3r,
    filter: Filter,
    out: []BodyId,
) u32 {
    assertFiniteVec(point);
    var collector = overlap_mod.OverlapCollector{
        .bm = bm,
        .store = store,
        .filter = filter,
        .probe = .{ .point = point },
        .out = out,
    };
    _ = bp.queryAabb(overlap_mod.pointAabb(point), &collector);
    return collector.finish();
}

/// The closest point on the closest body within `max_distance`, or `null` when no
/// body is that near.
///
/// The distance is to the SOLID: a point inside a body — boundary included — is at
/// distance 0 and its closest point is itself, and solidity is decided upstream of
/// any GJK classification. `shallow` is NOT an interior; it is a real separation
/// absorbed by the numeric margin, and its closest points are valid (§1.11.13).
pub fn closestPoint(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    point: Vec3r,
    max_distance: Real,
    filter: Filter,
) ?ClosestPointHit {
    std.debug.assert(std.math.isFinite(max_distance) and max_distance >= 0);
    assertFiniteVec(point);
    var collector = overlap_mod.ClosestPointCollector{
        .bm = bm,
        .store = store,
        .filter = filter,
        .point = point,
        .max_distance = max_distance,
    };
    _ = bp.queryAabb(overlap_mod.closestPointCandidates(point, max_distance), &collector);
    return collector.best;
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
    return keyLess(x.entity, x.body, y.entity, y.body);
}

/// The identity half of the key: `(entity, BodyId)`. It IS the whole key for the
/// three overlaps, which have no distance to rank by (§1.11.14), and the tail of it
/// for the three distance-ranked families. Written once so the two cannot drift.
pub fn keyLess(entity_x: EntityId, body_x: BodyId, entity_y: EntityId, body_y: BodyId) bool {
    const kx = entityKey(entity_x);
    const ky = entityKey(entity_y);
    if (kx != ky) return kx < ky;
    return body_x < body_y;
}

/// `hitLess` for a cast hit — the same key on the same three fields.
pub fn castLess(_: void, x: CastHit, y: CastHit) bool {
    if (x.distance != y.distance) return x.distance < y.distance;
    return keyLess(x.entity, x.body, y.entity, y.body);
}

/// `hitLess` for a closest-point hit — likewise.
pub fn closestLess(_: void, x: ClosestPointHit, y: ClosestPointHit) bool {
    if (x.distance != y.distance) return x.distance < y.distance;
    return keyLess(x.entity, x.body, y.entity, y.body);
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

    // Normalised ONCE, here. Everything downstream — the traversal, the kernels,
    // the returned distance — is in units of this unit direction, which is why a
    // hit carries a distance and never a fraction.
    return Ray.init(query.origin, unitDirection(query.direction) orelse return null);
}

/// Slack on a rotation's unit norm, in ULPs of 1. The comparison is against 1, so
/// this is pure float noise — the same constant and the same role as
/// `body_manager.zig`'s `descriptor_rotation_unit_k` and `shapecast.zig`'s
/// `unit_dir_k`.
const rotation_unit_k: comptime_int = 16;

/// Every geometric input of a query is FINITE. §1.11.11 requires the domain "verified
/// by a domain assertion at the entry", and the entry is BEFORE the handle resolution:
/// a `store.get(...) orelse return null` on a stale shape would otherwise
/// short-circuit the check, so a NaN pose would pass unnoticed on every call that
/// happened to carry a dead handle and then reach the kernel on the next one that did
/// not. `@abs(NaN) < inf` is false, so this catches NaN as well as infinity.
fn assertFiniteVec(vector: Vec3r) void {
    std.debug.assert(@reduce(.And, @abs(vector.data) < @as(@Vector(3, Real), @splat(std.math.inf(Real)))));
}

/// A rotation is UNIT. Not cosmetic: every one of these rotations is used as an
/// inverse BY CONJUGATION, and the conjugate is the inverse only for a unit
/// quaternion. M1.1.9 burned on exactly this — an f32-unit quaternion widened to f64
/// is off by `3.4e-8`, which scaled a static collider's frame by that factor, 0.34 mm
/// at 10 km, the regime `-Dphysics_f64` exists for.
fn assertUnitRotation(rotation: Quatr) void {
    const q = rotation.toArray();
    const norm_sq = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    std.debug.assert(@abs(norm_sq - 1) <= rotation_unit_k * std.math.floatEps(Real));
}

/// Unit direction, or `null` when the input is EXACTLY zero — the §1.11.4 guard,
/// shared by the ray entry and the cast entry so one family cannot acquire a
/// different degenerate-direction rule from the other.
///
/// The vector is reduced by its LARGEST COMPONENT before anything is squared, which
/// is what keeps both ends of the float range safe. Squaring first is unsafe at
/// both: `(1e20, 0, 0)` is perfectly finite yet its squared length overflows to
/// infinity at f32, and a direction so small that its square underflows would read
/// as zero though it normalises exactly. After the reduction every component is in
/// `[0, 1]`, so the squared length lies in `[1, 3]` and can do neither.
///
/// The reduction is a component-wise DIVISION, deliberately not a multiplication by
/// `1 / scale`: for a denormal direction that reciprocal overflows to infinity and
/// the defect reappears at the other end of the range. The `scale == 0` test is at
/// TRUE ZERO — the largest absolute component is zero exactly when all three are.
pub fn unitDirection(direction: Vec3r) ?Vec3r {
    const scale = @reduce(.Max, @abs(direction.data));
    if (scale == 0) return null;
    const reduced: Vec3r = .{ .data = direction.data / @as(@Vector(3, Real), @splat(scale)) };
    return reduced.scale(1 / reduced.length());
}
