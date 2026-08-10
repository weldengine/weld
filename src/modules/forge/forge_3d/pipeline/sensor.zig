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
            // set is the corner predicate against the trees. The unbounded lists are not
            // visited, and that is the domain bound below rather than an omission: the only
            // pair it could yield is half-space against half-space, which is static on both
            // sides.
            .half_space => {
                const shape = self.store.get(self.bm.shapeOf(trigger).?).?;
                const world = shape_mod.halfSpace(shape).transformed(
                    self.bm.rotation(trigger).?,
                    self.bm.position(trigger).?,
                );
                _ = self.bp.queryHalfSpaceTrees(world.normal, world.distance, &sink);
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

        const other_class = classOf(self.bm, self.store, other) orelse return;

        // **THE DOMAIN BOUND (§1.13.6), and it is a written bound rather than a tolerated
        // gap.** Neither a half-space nor a triangle soup can be a probe, so a pair whose
        // two sides carry a static-only shape has no exact predicate available in either
        // direction. It produces NO membership.
        //
        // The motive is that the combination carries nothing. `addBody` forces `.static` on
        // both classes (`error.ShapeMustBeStatic`), so such a pair is static on both sides:
        // its overlap does not vary under simulation, and it would yield one entry on the
        // first tick and never a transition again. A sensor whose only possible signal is a
        // permanent state has no information to carry — a kill plane announcing the level
        // geometry is noise, not an event.
        //
        // Writing the missing kernels would not remove the bound: half-space against
        // half-space and half-space against mesh are cheap, mesh against mesh is not, so the
        // bound would still be needed and the two cheap kernels would be code avoiding no
        // decision. And refusing the sensor role to non-convex shapes would cost more: a
        // half-space trigger against a convex WORKS — that is the kill plane under the level
        // — so forbidding it would remove a case that carries a signal to eliminate one that
        // does not. The role stays a property of the instance (§1.13.1); it is the PAIR that
        // is bounded.
        if (self.trigger_class != .convex and other_class != .convex) return;

        // **THE PROBE IS FIXED BY A RULE, never by availability.** Trigger when the trigger
        // is convex, candidate otherwise — and when BOTH are convex it is ALWAYS the
        // trigger. The overlap boolean is symmetric in exact arithmetic, so no orientation
        // changes the answer there; but nothing guarantees bit equality of the two orders in
        // floating point, and a rule left to whichever side happened to be usable would make
        // the boundary depend on a choice the spec does not state. M1.1.14 must be able to
        // VERIFY this order, not establish it.
        const overlaps = if (self.trigger_probe) |p|
            self.bm.overlapShapeBody(self.store, other, p.shape, p.position, p.rotation, .ignore)
        else blk: {
            // **UNWRAPPED, and that is what makes the bound above LOAD-BEARING rather than
            // decorative.** The trigger is not convex here, so the domain bound has already
            // guaranteed the candidate is; and `classOf` succeeded one branch above, so the
            // handle and its shape are live and the only way `probeOf` could answer null —
            // a non-convex class — is the one the bound excludes.
            //
            // Written as an unwrap and not as an `orelse return`: that fallback would return
            // the same answer for the same pair, so the bound would change no behaviour and
            // could be deleted without a single test noticing. Here its removal fires in
            // Debug and ReleaseSafe, which is the difference between a rule the code STATES
            // and a rule the code merely happens to agree with.
            const p = probeOf(self.bm, self.store, other).?;
            break :blk self.bm.overlapShapeBody(self.store, self.trigger, p.shape, p.position, p.rotation, .ignore);
        };

        if (!(overlaps orelse return)) return;
        self.out.append(self.gpa, .{ .trigger = self.trigger, .other = other }) catch |e| {
            self.err = e;
        };
    }
};
