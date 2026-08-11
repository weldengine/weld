//! `forge_3d/pipeline/sensor.zig` — the sensor traversal: which bodies a trigger
//! currently overlaps (`engine-physics-solver.md` §1.13).
//!
//! A sensor DETECTS WITHOUT RESPONDING. It occupies space, it is paired, it is tested
//! exactly like any other body — and it produces no constraint, no impulse and no wake
//! cause. Sibling of `sleep.zig`: a pipeline-level sweep over bodies, with no `rigid/`
//! type and no constraint anywhere in it.
//!
//! **THE PASS DOES NOT REUSE `computePairs`, AND THAT IS AN IMPOSSIBILITY RATHER THAN A
//! PREFERENCE** (§1.13.5). Pair generation is MOVED-DRIVEN — it enumerates the proxies
//! that left their fat AABB since the last call — so it returns a DELTA and never a
//! snapshot. Two motionless bodies overlapping for a hundred ticks do not appear in it,
//! and a state rebuilt from that output would be empty on the first resting frame. A
//! second call after step 10 does not repair it either: proxy updates may repopulate the
//! moved logs, so the result is not reliably empty — it is simply not the current set.
//! Neither state is a snapshot.
//!
//! **The direction is triggers-outward, and it is the cheap one.** The pass enumerates the
//! TRIGGER proxies and, for each, descends the trees and the unbounded lists for its
//! candidates. Triggers are rare against bodies and the set is indexed by them.
//!
//! **The filter is the trigger's own UNILATERAL mask** over the candidate's OBJECT layer —
//! same mechanism and same semantics as the object-layer mask of the eight query entries
//! (§1.11.5), the only object-layer filtering the engine owns. It belongs to the trigger
//! and describes what IT sees, so two overlapping triggers are two relations evaluated
//! separately and A may see B without B seeing A. It is therefore never a pair predicate
//! and must never be consulted symmetrically.
//!
//! **The pass cannot consult `default_layer_pairs`**: after M1.1.13 that matrix reads
//! `false` on the whole `trigger` row and column (§1.13.3), which is what keeps a trigger
//! out of constraint construction. The two mechanisms never substitute for each other —
//! the matrix governs the physical RESPONSE, absolutely, and the mask governs what is SEEN
//! (§1.13.2).
//!
//! **Detection is EXACT, never AABB.** The tree descent BOUNDS the candidates; the AABB
//! never decides membership. A candidate retained by the mask is confirmed by the same
//! predicate the shape-overlap query uses — GJK on the cores, accepted as soon as the
//! regime is not `separated` (§1.11.12). No threshold of its own is introduced anywhere in
//! this file: the boundary is GJK's contact margin and not a second margin invented for
//! sensors, and the consequence — a body resting exactly on a trigger's surface, inside
//! that few-ULP band, may flip between ticks — is accepted rather than damped, a hysteresis
//! needing a length-dimensioned, therefore tuned, therefore scale-dependent threshold
//! (§1.13.6).
//!
//! **The pass is filtered by NO SLEEP STATE, on either side.** Nothing here reads
//! `isSleeping`, and the absence is the mechanism: membership derived from anything the
//! sleep system filters would make a body that falls asleep inside a trigger leave the set
//! without having moved by one ULP (§1.13.9). The price is explicit — a fully resting scene
//! pays this pass every tick.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("../config.zig");
const body_manager = @import("../body_manager.zig");
const shape_mod = @import("../shape.zig");
const narrowphase = @import("narrowphase/root.zig");
const broadphase = @import("broadphase.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const BodyId = api.BodyId;
const EntityId = api.EntityId;
const BodyManager = body_manager.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const Broadphase = broadphase.Broadphase(Real);
const SupportShape = narrowphase.SupportShape(Real);

/// One confirmed overlap, ORIENTED from the trigger. Body-level: the mapping onto entity
/// pairs — aggregation, reflexive suppression, the total order — is a separate step, and
/// the public state is expressed in entities and never in body handles (§1.13.8).
pub const BodyOverlap = struct {
    /// The body carrying the sensor role.
    trigger: BodyId,
    /// The body it detects. Never equal to `trigger`.
    other: BodyId,
};

/// A body's convex probe: its support shape and its world pose.
const Probe = struct {
    shape: SupportShape,
    position: Vec3r,
    rotation: Quatr,
};

/// The convex probe of a body, or null when the handle or its shape is stale, or when the
/// shape is not a bounded convex — a half-space has an unbounded support map and a triangle
/// SOUP has none at all (§1.11.3), so neither can be a probe.
fn probeOf(bm: *const BodyManager, store: *const ShapeStore, id: BodyId) ?Probe {
    const shape_id = bm.shapeOf(id) orelse return null;
    const shape = store.get(shape_id) orelse return null;
    if (shape.class() != .convex) return null;
    return .{
        .shape = shape_mod.supportShape(shape),
        .position = bm.position(id).?,
        .rotation = bm.rotation(id).?,
    };
}

/// The shape class of a live body, or null when the handle or its shape is stale.
fn classOf(bm: *const BodyManager, store: *const ShapeStore, id: BodyId) ?shape_mod.ShapeClass {
    const shape_id = bm.shapeOf(id) orelse return null;
    const shape = store.get(shape_id) orelse return null;
    return shape.class();
}

/// Rebuild `out` with every body-level overlap of every trigger, from the LIVE proxies.
///
/// The set is rebuilt in full, from scratch, every call — nothing is carried forward
/// (§1.13.8 rule 4). That is what makes body-handle recycling harmless: a reissued
/// `BodyId` inherits nothing, because no membership survives the call that observed it.
/// The immunity is a property of the RECONSTRUCTION and not of the type; a state held by
/// increments would lose it.
///
/// No duplicate is possible and no dedup step is needed: each trigger is enumerated once,
/// and each candidate proxy is offered once per descent, one proxy naming one body.
///
/// Order is the enumeration order — pool index, then unbounded slot index, both
/// deterministic functions of the operation sequence (§1.11.15). It is deliberately NOT
/// the normative order: the state and its deltas are sorted by the complete ENTITY key,
/// which belongs to the step that maps bodies onto entities (§1.13.11).
pub fn collectOverlaps(
    gpa: std.mem.Allocator,
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    out: *std.ArrayListUnmanaged(BodyOverlap),
) !void {
    out.clearRetainingCapacity();
    var visitor = TriggerVisitor{ .gpa = gpa, .bp = bp, .bm = bm, .store = store, .out = out };
    bp.forEachInLayer(.trigger, &visitor);
    if (visitor.err) |e| return e;
}

/// Enumerates the trigger proxies and launches one candidate descent per trigger.
const TriggerVisitor = struct {
    gpa: std.mem.Allocator,
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    out: *std.ArrayListUnmanaged(BodyOverlap),
    /// OOM latched here: the collector contract's `add` returns void.
    err: ?std.mem.Allocator.Error = null,

    pub fn add(self: *TriggerVisitor, user_data: u32) void {
        const trigger: BodyId = user_data;
        // A stale proxy id names a freed body, and the getter answers that by returning
        // null. The role is re-read rather than assumed from the layer: the class is a
        // DERIVED quantity (`broadLayerFor`), so the flag is the source of truth and the
        // layer is its consequence.
        if (!(self.bm.isTrigger(trigger) orelse return)) return;
        const trigger_class = classOf(self.bm, self.store, trigger) orelse return;

        var sink = CandidateSink{
            .gpa = self.gpa,
            .bm = self.bm,
            .store = self.store,
            .out = self.out,
            .trigger = trigger,
            .trigger_class = trigger_class,
            .trigger_probe = probeOf(self.bm, self.store, trigger),
            .mask = self.bm.triggerLayerMask(trigger) orelse return,
        };

        // A DISPATCH on the class, exhaustive and with no `else` arm: the question "how is
        // this trigger's candidate set bounded" has an answer for every category, so a
        // fourth one is a compile error here and must give it.
        switch (trigger_class) {
            // A BOUNDED shape has a world box, and `queryAabb` visits all four trees AND
            // every unbounded list — the same traversal the query family uses, for the same
            // reason: the pass has no second body, so no row of the pair matrix applies and
            // every structure is visited (§1.11.1 point 3).
            .convex, .triangle_soup => {
                const box = self.bm.bodyAabb(self.store, trigger) orelse return;
                _ = self.bp.queryAabb(box, &sink);
            },
            // A HALF-SPACE has no box at all — `bodyAabb` asserts on it — so the candidate
            // set is the corner predicate, over the trees AND the unbounded lists. Both
            // halves: a half-space trigger against another half-space is a legal pair with a
            // two-line kernel, and the bound that once excluded it is retracted (§1.13.6).
            .half_space => {
                const shape = self.store.get(self.bm.shapeOf(trigger).?).?;
                const world = shape_mod.halfSpace(shape).transformed(
                    self.bm.rotation(trigger).?,
                    self.bm.position(trigger).?,
                );
                _ = self.bp.queryHalfSpace(world.normal, world.distance, &sink);
            },
        }
        if (sink.err) |e| self.err = e;
    }
};

/// One trigger's candidates: the mask, the domain bound, the probe rule, and the exact
/// confirmation.
const CandidateSink = struct {
    gpa: std.mem.Allocator,
    bm: *const BodyManager,
    store: *const ShapeStore,
    out: *std.ArrayListUnmanaged(BodyOverlap),
    trigger: BodyId,
    trigger_class: shape_mod.ShapeClass,
    /// Null when the trigger is not a bounded convex, which is exactly when it cannot be
    /// the probe.
    trigger_probe: ?Probe,
    mask: u32,
    err: ?std.mem.Allocator.Error = null,

    pub fn add(self: *CandidateSink, user_data: u32) void {
        const other: BodyId = user_data;
        // A trigger does not detect itself. This is the BODY-level self-match; the
        // reflexive rule on ENTITIES — one entity carrying both a trigger and a solid body
        // — is a separate rule and belongs to the entity mapping (§1.13.8 rule 2).
        if (other == self.trigger) return;

        // THE MASK, on the candidate's OBJECT layer. The getter answers staleness too.
        const layer = self.bm.collisionLayer(other) orelse return;
        if ((@as(u32, 1) << @intCast(layer)) & self.mask == 0) return;

        // **THE PROBE IS FIXED BY A RULE, never by availability** (§1.13.6). Trigger when the
        // trigger is convex, candidate otherwise — and when BOTH are convex it is ALWAYS the
        // trigger. The overlap boolean is symmetric in exact arithmetic, so no orientation
        // changes the answer there; but nothing guarantees bit equality of the two orders in
        // floating point, and a rule left to whichever side happened to be usable would make
        // the boundary depend on a choice the spec does not state. M1.1.14 must be able to
        // VERIFY this order, not establish it.
        //
        // **THE DISPATCH IS TOTAL, and no pair is out of domain.** A trigger is convex or a
        // half-space and never a triangle soup — `addBody` refuses the role on one, a surface
        // having no interior for a sensor to ask about (§1.11.17) — so the three arms below
        // cover every reachable pair. An earlier version carried a DOMAIN BOUND here that
        // refused {half-space, mesh} × {half-space, mesh}; it rested on a partition that
        // grouped the two by BODY TYPE where the question is whether the shape has an
        // INTERIOR, and the cell that made it look unavoidable — mesh against mesh — is
        // unreachable once a mesh cannot be a trigger. The bound is gone, not narrowed.
        const overlaps = if (self.trigger_probe) |p|
            // (1) convex trigger: it is the probe, against a body of any class.
            self.bm.overlapShapeBody(self.store, other, p.shape, p.position, p.rotation, .ignore)
        else if (probeOf(self.bm, self.store, other)) |p|
            // (2) half-space trigger, convex candidate: the candidate is the probe.
            self.bm.overlapShapeBody(self.store, self.trigger, p.shape, p.position, p.rotation, .ignore)
        else
            // (3) half-space trigger, non-convex candidate — the two analytic kernels. Neither
            // iterates: two half-spaces meet unless their normals are exactly opposite with
            // disjoint boundaries, and a surface meets a half-space iff one of its vertices
            // does, a triangle being the convex hull of its three.
            self.bm.halfSpaceOverlapsBody(self.store, self.trigger, other);

        if (!(overlaps orelse return)) return;
        self.out.append(self.gpa, .{ .trigger = self.trigger, .other = other }) catch |e| {
            self.err = e;
        };
    }
};

// ---------------------------------------------------------------------------
// The observable state, and the two deltas
// ---------------------------------------------------------------------------

/// One ORIENTED pair of the observable state, in ENTITY identities and never in body
/// handles (§1.13.8). The public payload of `engine-physics-forge.md` §5 carries entities:
/// a state expressed in bodies would produce two `enter` where one entity carries two
/// colliders, for a single observable crossing.
pub const EntityPair = struct {
    /// The entity owning the trigger body.
    trigger: EntityId,
    /// The entity it detects. Never equal to `trigger` (§1.13.8 rule 2).
    other: EntityId,
};

/// Strict order on an entity identity: index first, then generation.
///
/// **Written out rather than bitcast to the packed `u64`.** `EntityId` is a
/// `packed struct(u64)`, so a bitcast comparison would order by whichever field the layout
/// happens to place high — a property of the layout and not a decision — and a later field
/// reorder would silently reorder this. Both fields are compared, which is what §1.13.11
/// requires: never the index alone, two successive occupants of one index having to be
/// distinct AND ordered.
fn entityLess(a: EntityId, b: EntityId) bool {
    if (a.index != b.index) return a.index < b.index;
    return a.generation < b.generation;
}

fn entityEql(a: EntityId, b: EntityId) bool {
    return a.index == b.index and a.generation == b.generation;
}

/// The lexicographic order of §1.13.11: `(trigger_entity, other_entity)`, each compared on
/// its complete identity value.
fn pairLess(_: void, a: EntityPair, b: EntityPair) bool {
    if (!entityEql(a.trigger, b.trigger)) return entityLess(a.trigger, b.trigger);
    return entityLess(a.other, b.other);
}

fn pairEql(a: EntityPair, b: EntityPair) bool {
    return entityEql(a.trigger, b.trigger) and entityEql(a.other, b.other);
}

/// The overlap state and its two deltas, rebuilt in full every tick.
///
/// **No hashed container appears on this path**, here as in the broadphase and the
/// warm-start cache (§1.13.11): the set is a sorted flat array, deduplication is an
/// adjacent pass, and the two differences are linear merges. The output order is therefore a
/// pure function of the SET — independent of tree visit order, of worker count and of body
/// insertion order — which is the condition for M1.1.14 to VERIFY it rather than establish
/// it.
pub const SensorState = struct {
    /// The current set, sorted and deduplicated by the §1.13.11 key.
    current: std.ArrayListUnmanaged(EntityPair) = .empty,
    /// The previous tick's set, kept for the comparison and for nothing else.
    previous: std.ArrayListUnmanaged(EntityPair) = .empty,
    /// `current` minus `previous`, in the same order.
    entered: std.ArrayListUnmanaged(EntityPair) = .empty,
    /// `previous` minus `current`, in the same order. There is no third list: the
    /// maintained state is readable in `current` at any instant, and an event per tick per
    /// maintained pair would be the bus's largest producer for information already
    /// available without it (§1.13.12).
    exited: std.ArrayListUnmanaged(EntityPair) = .empty,
    /// Body-level scratch, retained across ticks for its capacity alone.
    overlaps: std.ArrayListUnmanaged(BodyOverlap) = .empty,

    pub fn deinit(self: *SensorState, gpa: std.mem.Allocator) void {
        self.current.deinit(gpa);
        self.previous.deinit(gpa);
        self.entered.deinit(gpa);
        self.exited.deinit(gpa);
        self.overlaps.deinit(gpa);
        self.* = undefined;
    }

    /// Rebuild the current set from the live proxies and recompute the two deltas.
    ///
    /// **RESERVE-THEN-MUTATE.** Every fallible step — the body-level collection and the
    /// three reservations — precedes the first observable mutation of the state, so an
    /// allocation failure leaves `current`, `previous` and the two deltas exactly as they
    /// were and the call is retryable. The same invariant the ECS slot allocator holds.
    ///
    /// **The state is rebuilt IN FULL and nothing is carried forward but the comparison
    /// copy.** That is what makes body-handle recycling harmless: no handle appears in the
    /// state and no membership is carried, so a reissued `BodyId` inherits nothing. The
    /// immunity is a property of the reconstruction and not of the type — a state held by
    /// increments would lose it, which is why it is stated here and not left implicit
    /// (§1.13.8).
    ///
    /// **Filtered by NO sleep state, on either side.** A body that falls asleep inside a
    /// trigger stays in the set, so falling asleep never produces an exit (§1.13.9). The
    /// price is that a fully resting scene pays this every tick.
    pub fn update(
        self: *SensorState,
        gpa: std.mem.Allocator,
        bp: *const Broadphase,
        bm: *const BodyManager,
        store: *const ShapeStore,
    ) !void {
        try collectOverlaps(gpa, bp, bm, store, &self.overlaps);

        // All three reservations before any swap, and the FIRST one is on `previous` and not
        // on `current`: the swap below makes the previous buffer the new `current`, so
        // reserving on `current` here would grow the buffer that is about to become the
        // comparison copy and leave the rebuilt one short. A first version did exactly that
        // and papered over it with a post-swap `catch unreachable` on a path that really can
        // fail — the reservation is simply moved to the right buffer instead.
        // Each delta holds at most the sum of the two sets.
        try self.previous.ensureTotalCapacity(gpa, self.overlaps.items.len);
        const delta_bound = self.overlaps.items.len + self.current.items.len;
        try self.entered.ensureTotalCapacity(gpa, delta_bound);
        try self.exited.ensureTotalCapacity(gpa, delta_bound);

        // From here on nothing can fail.
        std.mem.swap(std.ArrayListUnmanaged(EntityPair), &self.current, &self.previous);
        self.current.clearRetainingCapacity();

        for (self.overlaps.items) |o| {
            const t = bm.entity(o.trigger) orelse continue;
            const e = bm.entity(o.other) orelse continue;
            // REFLEXIVE SUPPRESSION (§1.13.8 rule 2): one entity carrying a trigger body and
            // a solid body would otherwise detect itself. Distinct from the body-level
            // self-match, which the traversal already excludes — this one is about two
            // DIFFERENT bodies of one entity.
            if (entityEql(t, e)) continue;
            self.current.appendAssumeCapacity(.{ .trigger = t, .other = e });
        }

        // AGGREGATION (§1.13.8 rule 1) IS this dedup: several body overlaps between the same
        // two entities collapse to one pair, so the exit fires only when the last of them
        // disappears — which falls out of the set difference below without a special case.
        std.mem.sort(EntityPair, self.current.items, {}, pairLess);
        dedupAdjacent(&self.current);

        difference(self.current.items, self.previous.items, &self.entered);
        difference(self.previous.items, self.current.items, &self.exited);
    }

    /// `a \ b` over two SORTED, deduplicated lists, written into `out` in the same order.
    /// A linear merge — no hashed container, and no allocation, the capacity having been
    /// reserved by the caller.
    fn difference(
        a: []const EntityPair,
        b: []const EntityPair,
        out: *std.ArrayListUnmanaged(EntityPair),
    ) void {
        out.clearRetainingCapacity();
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.len) {
            if (j == b.len or pairLess({}, a[i], b[j])) {
                out.appendAssumeCapacity(a[i]);
                i += 1;
            } else if (pairEql(a[i], b[j])) {
                i += 1;
                j += 1;
            } else {
                j += 1;
            }
        }
    }

    fn dedupAdjacent(list: *std.ArrayListUnmanaged(EntityPair)) void {
        if (list.items.len == 0) return;
        var w: usize = 1;
        var i: usize = 1;
        while (i < list.items.len) : (i += 1) {
            if (!pairEql(list.items[i], list.items[w - 1])) {
                list.items[w] = list.items[i];
                w += 1;
            }
        }
        list.shrinkRetainingCapacity(w);
    }
};
