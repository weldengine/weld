//! `forge_3d/character.zig` — the kinematic character controller's store
//! (`engine-physics-forge.md` §1.12).
//!
//! **A controller is VIRTUAL and carries no simulated body.** It takes part in no solver
//! pass — no inverse mass, no inertia tensor, no contact constraint, no island membership —
//! and no impulse is ever applied to it. It appears in no step of the normative per-tick
//! cycle (§1.7), at the same title as a query (§1.11.1): the gameplay calls it, at whatever
//! frequency the gameplay chooses.
//!
//! What it DOES carry is a **presence**: a `.kinematic` body holding the controller's own
//! capsule, so the controller is visible to queries (§1.12.2). Without one, `collision_layer`
//! — the mechanism by which an object declares itself visible to other callers' queries
//! (§1.11.5) — would be a field with no observable effect. The presence is optional per
//! character through `CharacterDescriptor.inner_body`, whose default is `true`.
//!
//! **This milestone delivers the STORE and nothing that moves.** `moveCharacter`, the ground
//! verdict and its five quantities, `resizeCharacter`, the push and `setCharacterPosition`
//! belong to later gates of M1.1.12; none of their state is declared here, so that a field
//! arrives with the code that fills it.
//!
//! **No cache of any kind, and that is written down so the next sub-milestone does not
//! reopen it** (§1.12.8). The M1.1.11.1 `Body.world_aabb` pattern does not transfer:
//! nothing expensive is pose-invariant for a character, a capsule's support shape being two
//! scalars.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const shape_mod = @import("shape.zig");
const body_manager_mod = @import("body_manager.zig");
const broadphase_mod = @import("pipeline/broadphase.zig");
const narrowphase = @import("pipeline/narrowphase/root.zig");
const IdAllocator = @import("slot_alloc.zig").IdAllocator;
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = body_manager_mod.BodyManager;
const Broadphase = broadphase_mod.Broadphase(Real);
const Ray = broadphase_mod.Ray(Real);
const SupportShape = narrowphase.SupportShape(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const BodyId = api.BodyId;
const ShapeId = api.ShapeId;
const CharacterId = api.CharacterId;
const CharacterDescriptor = api.CharacterDescriptor;
const EntityId = api.EntityId;
const GroundState = api.GroundState;

/// The engine's up axis. `+Y` (`engine-coordinate-system.md`), which is also why
/// `CharacterDescriptor` carries no rotation field — the capsule is symmetric about it.
///
/// Named once here rather than written as a literal at each of the five sites that need it,
/// so "up" is one thing and not five agreeing by luck.
const up: Vec3r = Vec3r.unit_y;

/// Every way a `CharacterDescriptor` can be malformed, plus the stale handle — each refused
/// by its own typed error and NEVER sanitised.
///
/// The reason no value is ever clamped into range: silently clamping would make a caller's
/// mistake look like a modelling choice, and the caller would have no diagnostic at all.
/// `max_slope` is the case that makes this concrete — a value of `π` is a REJECTION, not a
/// clamp to `π/2`.
///
/// One error per malformation class, on the `MeshError` precedent (§1.11.17): a caller
/// fixing a bug wants to know which field, and a single `error.InvalidDescriptor` would
/// send it reading all of them.
pub const CharacterError = error{
    /// A length is out of domain: `radius` or `height` non-finite or not strictly positive,
    /// `height` less than twice `radius` (which asks for a negative cylinder half-height), or
    /// `predictive_contact_distance` non-finite or negative.
    InvalidDimensions,
    /// `max_slope` is non-finite or outside `[0, π/2]`.
    InvalidSlope,
    /// `padding` is non-finite or negative.
    InvalidPadding,
    /// `mass` is non-finite or not strictly positive, or `max_push_force` is non-finite or
    /// negative.
    InvalidPushParameters,
    /// `collision_layer` is outside `[0, collision_layer_count)`.
    InvalidCollisionLayer,
    /// The handle is stale: its slot was freed, or its generation does not match.
    StaleCharacter,
    /// `displacement` is out of domain: a non-finite component, or a COMPUTED norm greater than
    /// `floatMax(f32)` — computed in the evaluation arithmetic §1.12.6 fixes, and not the
    /// mathematical norm.
    ///
    /// NORMATIVE in `engine-physics-forge.md` §1.12.6 and mirrored on the frozen entry in
    /// `engine-tier-interfaces.md`: why widening moves the rounding threshold without removing it,
    /// why the domain is therefore declared on what is DECIDABLE, what that costs and what it
    /// protects, and the two ends the domain leaves served. Not restated here — a second formulation
    /// of a normative rule is a second source, and this module spends its length refusing those.
    InvalidDisplacement,
};

/// One stored controller. Authored parameters at solver precision, plus the two handles the
/// store owns the lifetime of.
///
/// **`position` is the BASE of the capsule, never its centre** (§1.12.3). This is not an
/// implementation detail: `CharacterMoveResult.position` is written into `Transform.position`
/// by gameplay and every probe of the caller starts there, while a body's pose is the CENTRE
/// of its shape — the capsule being symmetric about the origin. The offset between the two is
/// `baseToCentre`, and it exists in exactly that one named place.
///
/// **`max_slope` is stored as its COSINE**, computed once at creation. Not a
/// micro-optimisation: an `acos` per contact per frame is precisely what M1.1.14 would have
/// to make reproducible, `engine-phase-1-plan.md` naming internal trigonometric functions
/// among its determinism hazards, and storing the cosine moves the single trigonometric call
/// to creation time (§1.12.5).
pub const Character = struct {
    /// Owning ECS entity — the identity queries report, and the one the presence carries too.
    entity: EntityId,
    /// World-space BASE of the capsule (metres).
    position: Vec3r,
    /// Capsule radius (metres).
    radius: Real,
    /// Total capsule height, base to top (metres).
    height: Real,
    /// Tallest riser the controller climbs rather than being blocked by (metres). Consumed
    /// at gate E.
    step_height: Real,
    /// `cos(max_slope)`. The ground test is `n · up >= cos_max_slope`, so a LARGER cosine is
    /// a STRICTER slope limit — worth knowing before comparing two of these.
    cos_max_slope: Real,
    /// Distance the capsule is held off surfaces (metres). A named PHYSICAL parameter of the
    /// class of `restitution_threshold` and `penetration_slop`, not a numerical tolerance:
    /// §1.11.2's `k · floatEps(T) · coordScale` discipline does NOT govern it.
    padding: Real,
    /// How far outside the shape to sweep for contacts not yet touching (metres). Same
    /// parameter class as `padding`. Its FIRST consumer is the ground probe of gate C, which
    /// bounds its downward sweep at `padding + predictive_contact_distance`.
    predictive_contact_distance: Real,
    /// What the character IS, read by others through the mask of THEIR queries. Also the
    /// presence's layer, with no dedicated field (§1.12.2).
    collision_layer: u8,
    /// What the character SEES, read by itself alone in its own sweeps (§1.12.4). Consumed
    /// from gate C.
    layer_mask: u32,
    /// Mass serving the push impulse (kg). Consumed at gate F.
    mass: Real,
    /// Ceiling on the push force (N); zero disables pushing. Consumed at gate F.
    max_push_force: Real,
    /// The capsule in the `ShapeStore`, owned by this character for its whole life.
    shape: ShapeId,
    /// The presence, or null when the descriptor asked for none. Its `BodyId` is STABLE and
    /// stays so across a resize (gate F): a resize is not a re-creation, and an exclusion
    /// the caller memorised survives it.
    inner_body: ?BodyId,
    /// The ground verdict LAST REPORTED by a `moveCharacter` (§1.12.8).
    ///
    /// `setCharacterPosition` INVALIDATES it back to `.in_air`, because a teleport moves the
    /// character somewhere the previous verdict describes nothing about — and `.in_air` is the safe
    /// failure direction, one tick of gravity rather than a floating character. The poisoning
    /// discipline of §1.11.17 does not apply: `GroundState` has three values that four documents
    /// share, and inventing a fourth to mean "unknown" would cost more than the safe direction
    /// earns.
    reported_ground: GroundState = .in_air,
    /// The presence's broadphase proxy, once its owner has registered it through
    /// `setPresenceProxy`.
    ///
    /// `createCharacter` cannot insert the proxy itself: the broad layer is an INSERTION ARGUMENT
    /// and no `BodyType → BroadphaseLayer` wiring exists — that arrives with `PhysicsWorld` at
    /// M1.1.15. So whoever owns the broadphase inserts, then hands the handle back here, and from
    /// then on every pose write keeps it fresh. Null means "nobody registered one", and a pose
    /// write then updates the body and not the tree.
    presence_proxy: ?Broadphase.Proxy = null,
};

/// The offset from a character's BASE to the CENTRE of its capsule — half the height along
/// up, `up` being `+Y` (`engine-coordinate-system.md`).
///
/// **THE one named place this offset exists.** Computed a second time somewhere else, it will
/// disagree with this one exactly once, and the symptom is a character standing half its
/// height into the floor or above it. `engine-movement.md`'s former ground raycast implied
/// the base while `BodyDescriptor` means the centre, which is how a half-height discrepancy
/// hides in plain sight.
///
/// Generic over the scalar because both precisions need it: the `BodyDescriptor` the presence
/// is created from is `f32` (§1.12.11), while every later pose write is at `Real`. That is
/// safe rather than merely convenient — halving is exact in binary floating point, and
/// widening is exact, so `widen(h_f32 * 0.5)` and `widen(h_f32) * 0.5` are the same number.
pub fn baseToCentre(comptime T: type, height: T) math.Vec(3, T) {
    return math.Vec(3, T).unit_y.scale(height * 0.5);
}

/// The cylinder half-height of a capsule of total `height` and `radius`: the capsule spans
/// `2 · half_height + 2 · radius` along Y, so `half_height = height/2 − radius`.
///
/// Its non-negativity is why `height >= 2 · radius` is a domain condition and not a
/// suggestion — a smaller height describes no capsule at all.
pub fn capsuleHalfHeight(comptime T: type, radius: T, height: T) T {
    return height * 0.5 - radius;
}

/// Reject a malformed descriptor, allocating nothing and mutating nothing.
///
/// Called FIRST by `createCharacter`, before its first allocation, on the `MeshData.init`
/// precedent: a typed refusal must not have allocated. The order of the checks is readable
/// rather than normative — unlike `addBody`'s, whose ordering is load-bearing because the
/// body literal derives quantities from the local AABB.
///
/// **THIRTEEN guards, and the rule that decides which conditions earn one**: a value the code
/// would ACCEPT and that produces silently wrong geometry or dynamics is a domain error, and
/// refusing it costs one comparison. Non-finiteness is not the whole class — a finite value in
/// the wrong half of the line does the same damage without being detectable downstream.
fn validateDescriptor(desc: CharacterDescriptor) CharacterError!void {
    if (!std.math.isFinite(desc.radius) or desc.radius <= 0) return error.InvalidDimensions;
    if (!std.math.isFinite(desc.height) or desc.height <= 0) return error.InvalidDimensions;
    // A capsule shorter than its own diameter is not a capsule. Refused rather than clamped
    // to a sphere, which would silently deliver geometry the caller did not ask for.
    if (desc.height < 2 * desc.radius) return error.InvalidDimensions;

    // `[0, π/2]`, and `π` is the case that has to fail: a slope limit beyond vertical is
    // meaningless, and clamping it would read as a modelling choice.
    if (!std.math.isFinite(desc.max_slope)) return error.InvalidSlope;
    if (desc.max_slope < 0 or desc.max_slope > std.math.pi / 2.0) return error.InvalidSlope;

    if (!std.math.isFinite(desc.padding)) return error.InvalidPadding;
    // A NEGATIVE padding inflates the capsule INWARD: the character sinks `|padding|` into
    // every surface it stands on, and nothing anywhere reports it. Zero is legal — no margin.
    if (desc.padding < 0) return error.InvalidPadding;
    // **AND NO UPPER BOUND, which was ordered, written, then MEASURED AWAY.** A `padding >= radius`
    // guard shipped for one round on two motives and neither survived. The freeze motive fell first:
    // a large `padding` does stop the character short of an obstacle, but that IS the declared
    // stand-off being honoured — a character demanding 0.3 m of clearance cannot approach a riser
    // closer than 0.3 m. What remained was that a push larger than the shape might carry the capsule
    // THROUGH thin geometry. Measured across fourteen configurations — `padding` at `2 · radius` and
    // at `3.3 · radius`, against a 0.1 m wall, at seven entry depths straddling its mid-plane — and
    // the capsule exits on the side it entered from EVERY time: the push-out invariant reverts to the
    // entry pose the moment it finds a plane the base has crossed, so a larger push goes further out
    // and never through.
    //
    // So the guard rejected valid descriptors and valid resizes on no basis, and it is gone. Left as a
    // comment because a guard removed by measurement is worth more to the next reader than its absence.

    if (!std.math.isFinite(desc.mass)) return error.InvalidPushParameters;
    // Zero would DUPLICATE `max_push_force = 0`, which is the documented way to disable
    // pushing — two ways to express one thing is the duplication class refused elsewhere in
    // this module. Negative INVERTS the impulse: the character pulls instead of pushing.
    if (desc.mass <= 0) return error.InvalidPushParameters;

    if (!std.math.isFinite(desc.max_push_force)) return error.InvalidPushParameters;
    // A negative force ceiling has no meaning; zero is the disabler.
    if (desc.max_push_force < 0) return error.InvalidPushParameters;

    // `step_height` is a SWEEP DISTANCE — `tryStepUp`'s lift and `stepDown`'s probe both pass it
    // straight to `sweepNearest` — and every other stored physical parameter here is guarded, so its
    // absence was an omission and not a decision. A NaN reaches the cast kernel's own domain assert,
    // which holds in Debug only; a negative value would ask for a sweep backwards. Zero is legal and
    // is the disabler the suite already exercises: no climb, no floor-sticking.
    if (!std.math.isFinite(desc.step_height) or desc.step_height < 0) return error.InvalidDimensions;

    // Guarded even though no algorithm consumes it yet, because it is STORED at solver
    // precision: a NaN entered by the caller would live in the store, indistinguishable from
    // the DELIBERATE poison NaN this repository writes on purpose into fields that have no
    // meaning for a shape. That ambiguity is what cost M1.1.11.1 several rounds — not the NaN
    // itself. If gate D deletes the field, this guard leaves with it: one line.
    if (!std.math.isFinite(desc.predictive_contact_distance) or
        desc.predictive_contact_distance < 0) return error.InvalidDimensions;

    // A TYPED error and not an assert, for the same reason `addBody` uses one: the query
    // mask is 32 bits, so a character declared past that domain would be invisible to every
    // query with no diagnostic at all (§1.11.5, §1.12.4).
    if (desc.collision_layer >= api.collision_layer_count) return error.InvalidCollisionLayer;
}

/// The ground verdict and its four companion quantities, at SOLVER precision — the internal
/// mirror of `CharacterMoveResult`'s five `ground_*` fields (§1.12.5). Narrowing it to the
/// public `f32` form is the interface tier's business at M1.1.15; nothing here does it.
///
/// **Every default is the `.in_air` answer**, so that state is the struct's zero value rather
/// than something the code has to remember to write. `.in_air` is the safe failure direction:
/// a `.grounded` default on an unknown verdict means gravity not applied, hence a character
/// that floats, a symptom that does not correct itself.
///
/// `normal` is `up` on `.in_air` and NEVER a poisoned value — three documents read that field
/// inside a `@replicated` component and a NaN would cross the rollback. The two support
/// handles carry their explicit "no handle" sentinels instead.
pub const GroundInfo = struct {
    /// The VERDICT. A direction does not mix into it.
    state: GroundState = .in_air,
    /// Outward normal of the winning surface, pointing FROM the surface TOWARD the character.
    normal: Vec3r = up,
    /// Entity of the support. NON-NULL on `.on_steep_ground` as much as on `.grounded` — a
    /// steep slope is still a support — and `EntityId.dead` only on `.in_air`.
    entity: EntityId = EntityId.dead,
    /// Body of the support, `PackedId.dead` on `.in_air`.
    body: BodyId = api.PackedId.dead,
    /// Velocity AT THE CONTACT POINT, `v + ω × r`. Zero on `.in_air`.
    velocity: Vec3r = Vec3r.zero,
};

/// One surface that qualified as ground, before the winner is chosen.
const Candidate = struct {
    body: BodyId,
    subshape_id: u32,
    /// Outward, surface → character.
    normal: Vec3r,
    /// World contact point, from which the lever arm of `ground_velocity` is built.
    point: Vec3r,
    /// `normal · up`, the selection key. Cached because it decides both the winner and the
    /// verdict, and recomputing it is how the two would come to disagree.
    align_up: Real,
};

/// Gathers the ground candidates of one downward sweep and keeps the winner.
///
/// **The bound NEVER tightens**, unlike the query family's `closest` collector: the winner is
/// the FLATTEST surface within the band and not the nearest one, so a nearer steeper contact
/// must not prune a flatter one behind it. That is what lets a character straddling an edge
/// stand on the walkable face (§1.12.5).
const GroundCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    /// The character's capsule, as a support shape.
    probe: SupportShape,
    /// World CENTRE of that capsule — the pose the sweep starts from, base plus the offset.
    centre: Vec3r,
    /// How far down to look. Covers `padding` by construction; see `groundSweepDistance`.
    max_sweep: Real,
    /// What the character SEES (§1.12.4).
    layer_mask: u32,
    /// The character's OWN presence, excluded from its own sweeps. Self-exclusion is
    /// UNILATERAL: no other character's presence is excluded, which is what gives
    /// character-versus-character collision for free (§1.12.2).
    exclude: ?BodyId,
    best: ?Candidate = null,
    /// Whether any contact at all faced upward — the difference between `.on_steep_ground`
    /// and `.in_air` once no candidate passes the slope test.
    any_candidate: bool = false,

    pub fn add(self: *GroundCollector, user_data: u32) void {
        const body: BodyId = user_data;
        if (self.exclude) |own| {
            if (own == body) return;
        }
        // The layer getter answers staleness too: a freed handle has no layer.
        const layer = self.bm.collisionLayer(body) orelse return;
        if ((@as(u32, 1) << @intCast(layer)) & self.layer_mask == 0) return;

        const hit = self.bm.castShapeBody(
            self.store,
            body,
            self.probe,
            self.centre,
            Quatr.identity,
            up.neg(),
            self.max_sweep,
            .ignore,
        ) orelse return;

        // **THE TWO PATHS, and the whole reason gate B delivered two entries.**
        //
        // A sweep that TRAVELLED returns the outward normal of the surface it met
        // (§1.11.11), which is exactly what `ground_normal` means — no sign work at all.
        //
        // At distance ZERO the capsule already overlaps, and the cast's normal is
        // `−direction`, i.e. `+up` (§1.11.4). That value is not wrong — it preserves
        // `normal · direction <= 0` — it is UNUSABLE: on a slope it would answer "perfectly
        // horizontal" and a slope test against it would always pass. So the normal comes from
        // the manifold at the current pose instead, which carries a real surface.
        if (hit.distance > 0) {
            self.consider(body, hit.subshape_id, hit.normal, hit.position);
            return;
        }
        var sink = ManifoldSink{ .ground = self, .body = body };
        self.bm.collideShapeBody(self.store, body, self.probe, self.centre, Quatr.identity, &sink);
    }

    /// Offer one surface to the selection.
    fn consider(self: *GroundCollector, body: BodyId, subshape_id: u32, normal: Vec3r, point: Vec3r) void {
        const align_up = normal.dot(up);
        // A candidate is a contact whose normal has a STRICTLY positive component on up. A
        // perfectly vertical wall is therefore never ground, whatever `max_slope` says — which
        // is deliberate: `cos(π/2)` is zero to float noise, so admitting `align_up == 0` would
        // make "can I stand on this wall" depend on that noise.
        if (align_up <= 0) return;
        self.any_candidate = true;

        if (self.best) |b| {
            // FLATTEST wins, not nearest.
            if (align_up < b.align_up) return;
            // Exact tie: the smaller `(BodyId, subshape_id)`, which is §1.11.14's total order.
            // Without it the answer would follow the traversal order, hence the tree's shape.
            if (align_up == b.align_up) {
                if (body > b.body) return;
                if (body == b.body and subshape_id >= b.subshape_id) return;
            }
        }
        self.best = .{
            .body = body,
            .subshape_id = subshape_id,
            .normal = normal,
            .point = point,
            .align_up = align_up,
        };
    }

    /// Never tightens — see the type doc.
    pub fn maxDistance(self: *const GroundCollector) Real {
        return self.max_sweep;
    }

    /// Never stops early: the flattest surface is only known once the walk is done.
    pub fn shouldStop(_: *const GroundCollector) bool {
        return false;
    }
};

/// Feeds every manifold of one body into the ground selection.
///
/// **THE one sign negation of this module.** `collideShapeBody` returns the normal
/// probe → body: for a character on a floor it points from the capsule DOWN toward the floor.
/// `ground_normal` is what the caller reads to know which way is up the slope, so it points
/// from the surface TOWARD the character. Hence one negation, in this one named place — the
/// class of error that cost M1.1.11.1 a spec correction on its own overlap predicate.
const ManifoldSink = struct {
    ground: *GroundCollector,
    body: BodyId,

    pub fn add(self: *ManifoldSink, subshape_id: u32, manifold: ContactManifold) void {
        // The DEEPEST point represents the manifold, which is the convention §3 already uses
        // when it maps a manifold onto the single `contact_point` of a gameplay event.
        var deepest = manifold.points[0];
        for (manifold.points[1..manifold.count]) |p| {
            if (p.penetration > deepest.penetration) deepest = p;
        }
        // The SAME single negation the ground probe makes: `collideShapeBody` returns probe → body,
        // and every consumer here wants surface → character.
        const outward = manifold.normal.neg();
        // **THE MANIFOLD POINT IS THE MIDPOINT OF THE TWO SURFACE POINTS, NOT THE GROUND'S SURFACE**,
        // and `ground_velocity` is read at the point the CHARACTER stands on. For a capsule sunk `p`
        // into a floor the midpoint sits at `−p/2` while the body's surface is at `0`, so the lever
        // arm was short by half the penetration and a rotating platform reported a velocity taken
        // half a penetration inside itself. Moved out along the outward normal by `p/2`, which is
        // the same reconstruction `prepare` performs on the same field (§1.7.2).
        const surface = deepest.position.add(outward.scale(deepest.penetration / 2));
        self.ground.consider(self.body, subshape_id, outward, surface);
    }
};

/// How far down the ground probe looks: `padding + predictive_contact_distance`.
///
/// **This is `predictive_contact_distance`'s FIRST consumer**, which settles in advance the
/// question the brief left to gate D. The two terms are the two reasons the ground is not at
/// distance zero when a character rests on it: `padding` is how far the capsule is held OFF
/// surfaces, so a resting character is at least that far above its floor; and
/// `predictive_contact_distance` is, by its own definition, how far outside the shape to look
/// for contacts not yet touching. Their sum is exactly the band in which "the ground I am
/// standing on" is a meaningful question.
///
/// The bound has to be SMALL, and that is what makes "flattest wins" well posed rather than
/// absurd: within 12 cm at the defaults, every candidate is genuinely underfoot, so preferring
/// the flatter of two is choosing a face of the ground. Over metres it would let a distant
/// flat floor outrank the steep slope actually under the character.
pub fn groundSweepDistance(c: Character) Real {
    return c.padding + c.predictive_contact_distance;
}

// --- The move (M1.1.12 gate D) ---

/// How many times the slide loop may sweep before giving up. NAMED and mandatory: M1.1.14 forbids
/// an unbounded loop on a path that must be reproducible, and the reference's own controller
/// carries the same kind of ceiling.
///
/// Exhausting it stops the character SHORT of where it asked to go — it never moves further. That
/// is the safe failure direction, the same one §1.11.11 chose for the cast kernel: a character that
/// does not finish its step is a visible stutter, a character that finishes it through a wall is a
/// hole in the world.
pub const max_slide_iterations: u32 = 4;

/// The multiplier of the DEPENETRATION STAND-OFF FLOOR, and it must exceed
/// `narrowphase.contact_margin_conv_k` (16) rather than merely equal it: the floor exists to put the
/// capsule OUT of the contact margin, not to place it on the margin's edge.
///
/// **THIS ONE IS A NUMERICAL TOLERANCE AND §1.11.2 GOVERNS IT — the opposite of every other constant
/// in this file, and worth saying because this module spends its length saying the opposite.**
/// `padding`, `max_slope` and `predictive_contact_distance` are named PHYSICAL parameters that select a
/// modelling behaviour, and the `k · floatEps(T) · coordScale` discipline deliberately does not reach
/// them. This floor selects nothing: it absorbs float noise, and it is written in that discipline's own
/// form for that reason.
const standoff_floor_k: Real = 64;

/// How many times depenetration may push before giving up. Same ceiling discipline, same safe
/// failure direction: a character left slightly overlapping is corrected next call, a character
/// pushed by an unbounded loop is a hang.
pub const max_depenetration_iterations: u32 = 4;

/// Bodies whose wake this call owes. The bound is EXACT rather than a guess, and it is accounted
/// sweep by sweep: `max_depenetration_iterations` pushes, `max_slide_iterations` slide sweeps, the
/// THREE sweeps of the single step-up attempt (lift, forward, land), and the one step-down sweep.
/// A step is attempted at most once per call, which is what keeps this a small constant.
const max_touched = max_depenetration_iterations + max_slide_iterations + 3 + 1;

/// The bodies one move touched, accumulated rather than woken on the spot.
///
/// The collectors hold a `*const BodyManager` — `castShapeBody` and `collideShapeBody` both take
/// one — so nothing inside them can wake anything. The same ordering M1.1.11.1 was forced into when
/// its wake moved after `prepare`, and for the same reason.
const TouchedBodies = struct {
    items: [max_touched]BodyId = @splat(0),
    len: u32 = 0,

    fn add(self: *TouchedBodies, body: BodyId) void {
        // The capacity is EXACT, one slot per iteration of each bounded phase, so this cannot
        // overflow. Asserted rather than silently clamped: a DROPPED wake is precisely the defect
        // W4 exists to prevent, so it must be loud and not absorbed.
        std.debug.assert(self.len < max_touched);
        if (self.len >= max_touched) return;
        self.items[self.len] = body;
        self.len += 1;
    }

    fn slice(self: *const TouchedBodies) []const BodyId {
        return self.items[0..self.len];
    }
};

/// The pushes one move owes, accumulated rather than applied on the spot.
///
/// **Applied AFTER the publication, for the reason the wake already is.** `syncPresenceTo` can still
/// fail after the slide loop has run, and a failure returns an error with the record deliberately
/// intact — so a push applied inside the loop survived a call that reported having done nothing, and
/// the caller's retry applied it a second time. Held here and drained beside the `wakeBody` loop,
/// which sits post-publication for exactly that reason.
///
/// The bound is `max_touched` and it is EXACT, not a guess: a push can only target a body the move
/// TOUCHED, and only the dynamic ones that yield, so this set is a subset of one already bounded
/// slot for slot. Asserted rather than clamped — a dropped push is a silent divergence between what
/// the character resolved against and what the world did.
///
/// **COALESCED BY BODY, and the first version was not — which broke the force ceiling.** `add` used
/// to append unconditionally and `apply` called `addImpulse` once per entry, each entry capped at
/// `max_push_force · dt`. So two contacts on one body in one call delivered TWICE the declared
/// ceiling, three would deliver three times, and nothing bounded the factor. A ceiling one can exceed
/// by being touched twice is not a ceiling — `max_push_force` is documented in newtons, and the
/// per-entry cap being "unchanged" WAS the defect rather than a mitigation of it.
///
/// Summing per body and capping the sum ONCE closes three things at once: the ceiling means what it
/// says, the atomicity is untouched since nothing leaves before the publication, and the answer stops
/// depending on how many contacts the sweep happened to make against one body — an iteration detail,
/// not a physical quantity.
const PendingPushes = struct {
    const Entry = struct { body: BodyId, impulse: Vec3r };

    items: [max_touched]Entry = @splat(.{ .body = 0, .impulse = Vec3r.zero }),
    len: u32 = 0,

    /// Accumulate onto `body`'s entry if it already has one. The scan is linear over at most
    /// `max_touched` entries, which is twelve — a hash container on a path M1.1.14 must make
    /// reproducible would be the wrong trade even if the set were large.
    fn add(self: *PendingPushes, body: BodyId, impulse: Vec3r) void {
        for (self.items[0..self.len]) |*e| {
            if (e.body == body) {
                e.impulse = e.impulse.add(impulse);
                return;
            }
        }
        std.debug.assert(self.len < max_touched);
        if (self.len >= max_touched) return;
        self.items[self.len] = .{ .body = body, .impulse = impulse };
        self.len += 1;
    }

    /// One impulse per body, its MAGNITUDE capped at `max_impulse = max_push_force · dt`.
    ///
    /// The division is reached only when `mag_sq > max_impulse²`, which forces `mag_sq > 0` since the
    /// right-hand side is non-negative — so the true-zero guard is structural here and no epsilon is
    /// invented for it.
    fn apply(self: *const PendingPushes, bm: *BodyManager, max_impulse: Real) void {
        for (self.items[0..self.len]) |e| {
            var impulse = e.impulse;
            const mag_sq = impulse.lengthSq();
            if (mag_sq > max_impulse * max_impulse) {
                impulse = impulse.scale(max_impulse / @sqrt(mag_sq));
            }
            // ACTIVATING by contract (§1.8.4) — an external mutation, and W1 rather than W4.
            bm.addImpulse(e.body, impulse);
        }
    }
};

/// What one `moveCharacter` returns, at solver precision.
///
/// **No remaining displacement and no collision counter.** A caller that wants to know whether it
/// was blocked compares the position it asked for against the one it got — a caller-side
/// derivation, not an engine quantity, and precisely why the former `collisions` field was deleted
/// from the frozen `CharacterMoveResult`.
pub const MoveResult = struct {
    /// The resolved BASE position (§1.12.3) — what gameplay writes into `Transform.position`.
    position: Vec3r,
    /// The ground verdict at that NEW pose, by the same probe gate C delivered.
    ground: GroundInfo,
};

/// One contact the move must react to: where it is and which way the surface faces.
const Contact = struct {
    body: BodyId,
    /// The sub-shape the normal came from. **Discarded by an earlier version, and that was the whole
    /// defect**: `DeepestManifold` selects the deepest point over ALL sub-shapes of the body, so the
    /// normal justifying a set-aside could come from one triangle while the cast had returned another
    /// — a ceiling's normal excluding a wall.
    subshape_id: u32 = 0,
    /// Outward, surface → character — the same orientation `GroundInfo.normal` carries.
    normal: Vec3r,
    /// Overlap along `normal`, for the depenetration push. Zero for a swept contact.
    penetration: Real = 0,
    /// The manifold point, which is the MIDPOINT of the two surface points — so the body's own
    /// surface lies half the penetration further along `normal`. Zero for a swept contact, which
    /// has no manifold; only the depenetration reads it.
    position: Vec3r = Vec3r.zero,
};

/// Nearest swept contact over every candidate body, with the character's own filter.
///
/// Tightens its bound TO each accepted distance, like the query family's `closest` — here that IS
/// correct, unlike the ground probe's: a nearer surface genuinely stops the motion sooner, so
/// pruning what is behind it loses nothing.
/// One sub-shape of one body — the grain a contact verdict actually has. A body handle alone is
/// coarser than any statement about a contact, and a mesh is the case where that difference is a
/// traversable wall rather than a nuance.
const SweepCollector = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    probe: SupportShape,
    origin: Vec3r,
    direction: Vec3r,
    bound: Real,
    layer_mask: u32,
    exclude: ?BodyId,
    /// Whether to skip contacts whose surface does not OPPOSE the sweep. See `castShapeBodyOpposing`.
    skip_non_opposing: bool = false,
    best: ?struct {
        body: BodyId,
        subshape_id: u32,
        distance: Real,
        normal: Vec3r,
        contact_normal: ?Vec3r,
    } = null,

    pub fn add(self: *SweepCollector, user_data: u32) void {
        const body: BodyId = user_data;
        if (self.exclude) |own| {
            if (own == body) return;
        }
        const layer = self.bm.collisionLayer(body) orelse return;
        if ((@as(u32, 1) << @intCast(layer)) & self.layer_mask == 0) return;

        // **THE EXCLUSION GOES INTO THE CAST, not around it.** `castShapeBody` returns ONE hit — the
        // nearest sub-shape — so filtering its RESULT discards that sub-shape and, with it, every other
        // sub-shape of the body the cast never returned. Measured on a mesh carrying a floor, a wall
        // and a ceiling: filtering afterwards let the character walk through the wall to `x = 12`;
        // excluding inside the traversal blocks it at `1.7`. Three rounds put this filter one level
        // too high — body, then pair above the cast — while the sub-shape is chosen one level below.
        const hit = self.bm.castShapeBodyOpposing(
            self.store,
            body,
            self.probe,
            self.origin,
            Quatr.identity,
            self.direction,
            self.bound,
            .ignore,
            self.skip_non_opposing,
        ) orelse return;

        if (self.best) |b| {
            if (hit.distance > b.distance) return;
            // The same total order the ground selection uses, for the same reason: without it the
            // answer would follow the traversal, hence the tree's shape.
            if (hit.distance == b.distance) {
                if (body > b.body) return;
                if (body == b.body and hit.subshape_id >= b.subshape_id) return;
            }
        }
        self.best = .{
            .body = body,
            .subshape_id = hit.subshape_id,
            .distance = hit.distance,
            .normal = hit.normal,
            .contact_normal = hit.contact_normal,
        };
        // Tightened TO, not below, so an equal distance still reaches the tie-break.
        self.bound = hit.distance;
    }

    pub fn maxDistance(self: *const SweepCollector) Real {
        return self.bound;
    }

    pub fn shouldStop(_: *const SweepCollector) bool {
        return false;
    }
};

/// The DEEPEST manifold of one body against the probe — the depenetration push direction, and the
/// slide normal when a sweep reports distance zero.
const DeepestManifold = struct {
    best: ?Contact = null,
    body: BodyId,

    pub fn add(self: *DeepestManifold, subshape_id: u32, manifold: ContactManifold) void {
        var deepest = manifold.points[0];
        for (manifold.points[1..manifold.count]) |p| {
            if (p.penetration > deepest.penetration) deepest = p;
        }
        if (self.best) |b| {
            if (deepest.penetration <= b.penetration) return;
        }
        // The SAME single negation the ground probe makes: `collideShapeBody` returns probe → body,
        // and every consumer here wants surface → character.
        self.best = .{
            .body = self.body,
            .subshape_id = subshape_id,
            .normal = manifold.normal.neg(),
            .penetration = deepest.penetration,
            .position = deepest.position,
        };
    }
};

/// The deepest overlap over every candidate body — what depenetration pushes out of first.
const WorstOverlap = struct {
    bm: *const BodyManager,
    store: *const ShapeStore,
    probe: SupportShape,
    centre: Vec3r,
    layer_mask: u32,
    exclude: ?BodyId,
    best: ?Contact = null,

    pub fn add(self: *WorstOverlap, user_data: u32) void {
        const body: BodyId = user_data;
        if (self.exclude) |own| {
            if (own == body) return;
        }
        const layer = self.bm.collisionLayer(body) orelse return;
        if ((@as(u32, 1) << @intCast(layer)) & self.layer_mask == 0) return;

        var one = DeepestManifold{ .body = body };
        self.bm.collideShapeBody(self.store, body, self.probe, self.centre, Quatr.identity, &one);
        const c = one.best orelse return;
        if (self.best) |b| {
            if (c.penetration < b.penetration) return;
            // Exact tie on depth: the smaller `BodyId`, so the push is not a function of the
            // traversal order.
            if (c.penetration == b.penetration and body >= b.body) return;
        }
        self.best = c;
    }
};

/// The real outward normal at a swept contact.
///
/// **The distance-zero trap, met a second time.** A sweep that TRAVELLED returns the surface's own
/// outward normal (§1.11.11), already the orientation every consumer here wants. At distance ZERO
/// it returns `−direction` — the direction travelled FROM, not the surface — which preserves
/// `normal · direction <= 0` and is nonetheless useless for sliding: on a slope it would answer
/// "perfectly horizontal". So the normal comes from the MANIFOLD instead, exactly as the ground
/// probe does, and null when even that finds nothing.
/// The slide normal AND the sub-shape it belongs to.
///
/// **The pair, and not the normal alone**: a caller that sets a contact aside on the strength of this
/// normal must set aside the sub-shape the normal actually came from.
///
/// **AND AT DISTANCE ZERO THE CAST'S OWN ANSWER IS PREFERRED TO A SECOND OPINION.** The whole-body
/// fallback below collects the manifold over EVERY sub-shape and keeps the deepest, which need not be
/// the one the cast retained — measured as a ceiling's normal displacing a wall's on the same mesh,
/// with the body's YAW deciding which won, and a character frozen at six of fourteen angles as a
/// result. That was never "no answer is correct in an insoluble squeeze": the right answer had been
/// computed, one call earlier, and dropped. A caller that asked the cast for an opposing verdict now
/// receives the normal that verdict was rendered on, and this function asks nobody.
///
/// The fallback remains for the callers that ask for no verdict — the ground probe and the step's
/// sweeps — where it is the ONLY source and therefore not a second one.
const SlideNormal = struct { normal: Vec3r, subshape_id: u32 };

fn slideNormal(
    bm: *const BodyManager,
    store: *const ShapeStore,
    probe: SupportShape,
    centre: Vec3r,
    body: BodyId,
    distance: Real,
    swept_normal: Vec3r,
    swept_subshape: u32,
    swept_contact_normal: ?Vec3r,
) ?SlideNormal {
    if (distance > 0) return .{ .normal = swept_normal, .subshape_id = swept_subshape };
    if (swept_contact_normal) |n| return .{ .normal = n, .subshape_id = swept_subshape };
    var deepest = DeepestManifold{ .body = body };
    bm.collideShapeBody(store, body, probe, centre, Quatr.identity, &deepest);
    const c = deepest.best orelse return null;
    return .{ .normal = c.normal, .subshape_id = c.subshape_id };
}

/// Remove the component of `motion` that goes INTO the surface whose outward normal is `normal`.
///
/// The normal points from the surface toward the character, so moving into it is a NEGATIVE dot
/// product; subtracting that component zeroes it exactly and leaves the tangential part untouched.
/// Zeroing both would pass a "the normal component is zero" test and be wrong, which is why the
/// wall test asserts the tangential part against a closed form as well.
fn slideAlongPlane(motion: Vec3r, normal: Vec3r, cos_max_slope: Real) Vec3r {
    const into = motion.dot(normal);
    if (into >= 0) return motion; // already leaving the surface
    const slid = motion.sub(normal.scale(into));

    // **THE SLOPE CONSTRAINT (§1.12.6).** A contact plane whose normal FAILS the slope test may not
    // be used to GAIN height: the up component of the projected motion is capped at the up component
    // of the motion BEFORE projection. Without it a character climbs any face up to 90°−ε simply by
    // walking into it — measured before the rule existed: 0.583 m of rise in one call against a 50°
    // face under a 45° limit, and the verdict said `.on_steep_ground` throughout, so the engine was
    // telling the truth while the pose climbed.
    //
    // A CAP and not a cancellation, which is what makes the four cases right at once: a walkable
    // plane is untouched; a caller that ASKS to rise keeps its rise, because the cap is on the
    // increase; and a motion already leaving the surface never reaches here at all.
    //
    // **THE BOUND IS `max(before, 0)` AND NOT `before`, and the difference is a defect the first
    // form shipped.** Capping at `before` PENETRATES the plane on a sloped face, computed on a 50°
    // ramp with normal `(−0.766, 0.643, 0)` and a pure gravity step `(0, −1, 0)`: the projection is
    // `(−0.4925, −0.5866, 0)`, so `after = −0.5866` exceeds `before = −1`, the cap bit, and the
    // output `(−0.4925, −1, 0)` had a dot of `−0.2657` with the normal — driving INTO the surface.
    // And the projection was the physically right answer: a body sliding down a 50° slope descends
    // more slowly than in free fall, the surface carrying part of the motion, and capping at
    // `before` annulled exactly that. Bounding at zero instead makes the rule what it is meant to
    // be — the ENGINE does not climb on the character's behalf — while leaving every descent the
    // geometry produces untouched.
    if (normal.dot(up) >= cos_max_slope) return slid;
    const cap = @max(motion.dot(up), 0);
    const after = slid.dot(up);
    if (after <= cap) return slid;
    return slid.sub(up.scale(after - cap));
}

/// Constrain `motion` against a crease formed by two contact planes.
///
/// Returns null when the two normals are EXACTLY parallel — which is a THIRD answer and not an
/// absence of edge. Two exactly parallel normals and a single contact plane are different
/// situations, and conflating them is the false-negative class this module refuses; it is the
/// `Attempt` lesson of §1.11.17 applied to a crease. The exact tier is what makes that null
/// trustworthy: `math.triangleCross`'s float `.direction` would return a rounding residue here and
/// read as a valid crease.
fn slideAlongCrease(motion: Vec3r, n0: Vec3r, n1: Vec3r, cos_max_slope: Real) ?Vec3r {
    const edge = math.triangleCrossDirection(Real, Vec3r.zero, n0, n1) orelse return null;
    // The magnitude carries no meaning by contract — only the direction — so it is normalised here
    // and never used as a length.
    //
    // **No zero-length guard, and its absence is PROVEN rather than assumed.** A non-null return
    // always has a component in `[0.5, 1)`: the function brings its three exact determinants onto
    // one common power of two chosen so the DOMINANT lane keeps a full mantissa, and for that lane
    // `shift = bitLen − keep < bitLen`, so it is never dropped by the below-scale skip and never
    // rounds to zero. Verified in `exact.zig`'s implementation, not inferred from its doc. So
    // `lengthSq()` lies in `[0.25, 3)` and a guard on it could not fire — and a guard that cannot
    // fire tells the reader the exact tier may return a zero vector, which that tier documents as
    // impossible.
    var axis = edge.scale(1 / @sqrt(edge.lengthSq()));
    // Oriented to agree with the motion, so the character slides ALONG the edge in the direction
    // it was already going and not backwards along it.
    const along = motion.dot(axis);
    if (along < 0) axis = axis.neg();
    const slid = axis.scale(@abs(along));

    // **THE SLOPE CONSTRAINT APPLIES TO A CREASE TOO, and it has to.** §1.12.6 governs the slide, and
    // an edge between two planes of which at least one is unwalkable is as much a way to gain height
    // as the plane itself — measured: against a 50° ramp built as a ROTATED BOX, the character
    // contacts both its top face and a side feature, giving two normals whose crease has an upward
    // component, and it rose 0.0186 m per call through that path while the single-plane cap held its
    // own path at exactly zero. Capping only the plane would have left the rule true of one branch
    // and false of the other.
    //
    // The bound is `max(before, 0)`, exactly as on the plane branch and for the same measured
    // reason: capping at `before` cancels a descent the geometry produced and drives the motion into
    // the surface.
    //
    // **On THIS branch that bound is UNDISCRIMINATED by the suite, and the honest statement is
    // weaker than the plane's.** Capping at `before` here breaks nothing, at either precision — and
    // unlike the step lift's padding, which is provably unobservable because it cancels against the
    // landing drop, this one is merely a case no scene built for it produced. Five were tried: a pure
    // descent at the foot of a ramp never reaches the crease at all, the first plane being the
    // walkable ground whose earlier branch cancels the downward component; and four mixed
    // descend-and-push motions against a rotated box gave outcomes identical under both bounds to
    // six decimals. So it stands on consistency with the plane branch, which is a reason and not a
    // proof.
    if (n0.dot(up) >= cos_max_slope and n1.dot(up) >= cos_max_slope) return slid;
    const cap = @max(motion.dot(up), 0);
    const after = slid.dot(up);
    if (after <= cap) return slid;
    return slid.sub(up.scale(after - cap));
}

/// Wakes every broadphase CANDIDATE of a volume, without consulting the narrowphase.
///
/// A SUPERSET of what is actually touched, and that is the safe direction for a wake: W4 exists so a
/// sleeper is never MISSED, and waking one that turns out not to be in contact costs it a tick of
/// simulation and nothing else. Being a superset also removes the capacity question entirely —
/// nothing is accumulated, so there is no bound to overflow, which is what lets the two pose-writing
/// entries handle an unbounded number of overlaps where the move's exact-capacity list could not.
///
/// It can hold a MUTABLE `BodyManager` precisely because it calls no adapter: `castShapeBody` and
/// `collideShapeBody` both take a `*const`, which is what forces the move to accumulate instead.
const CandidateWaker = struct {
    bm: *BodyManager,
    exclude: ?BodyId,

    pub fn add(self: *CandidateWaker, user_data: u32) void {
        const body: BodyId = user_data;
        if (self.exclude) |own| {
            if (own == body) return;
        }
        self.bm.wakeBody(body);
    }
};

/// One swept contact, resolved over every candidate body.
const SweepHit = struct {
    body: BodyId,
    subshape_id: u32,
    distance: Real,
    /// As the CAST reports it — the surface's outward normal when the sweep travelled, and
    /// `−direction` at distance zero. Pass it through `slideNormal` before using it.
    normal: Vec3r,
    /// The contact's own normal at distance zero, from the manifold the cast's own verdict was
    /// rendered on. Null when the sweep travelled, and null for a caller that asked for no verdict.
    contact_normal: ?Vec3r,
};

/// Nearest contact of the capsule swept from `origin` along `direction` for at most `distance`.
///
/// Factored out because four callers need exactly this — the slide loop and the step's three
/// sweeps — and a second copy is how two of them would come to disagree about the filter.
fn sweepNearest(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    record: shape_mod.Shape,
    probe: SupportShape,
    origin: Vec3r,
    direction: Vec3r,
    distance: Real,
    layer_mask: u32,
    exclude: ?BodyId,
    /// Whether to skip contacts whose surface does not oppose the sweep — the slide loop passes true,
    /// every other caller false, so their contract is unchanged in meaning.
    skip_non_opposing: bool,
) ?SweepHit {
    var collector = SweepCollector{
        .bm = bm,
        .store = store,
        .probe = probe,
        .origin = origin,
        .direction = direction,
        .bound = distance,
        .layer_mask = layer_mask,
        .exclude = exclude,
        .skip_non_opposing = skip_non_opposing,
    };
    const box = body_manager_mod.worldAabb(record, origin, Quatr.identity);
    _ = bp.queryCast(Ray.init(box.center(), direction), box.halfExtents(), &collector);
    const best = collector.best orelse return null;
    return .{
        .body = best.body,
        .subshape_id = best.subshape_id,
        .distance = best.distance,
        .normal = best.normal,
        .contact_normal = best.contact_normal,
    };
}

/// How far the capsule may actually travel toward a contact: up to `padding` short of it, and the
/// whole distance when nothing is in the way. Clamped at zero so a contact already inside the
/// margin never pushes the character backwards.
fn paddedAdvance(hit: ?SweepHit, distance: Real, padding: Real) Real {
    const h = hit orelse return distance;
    return @max(0, h.distance - padding);
}

/// What a successful step-up produced: where the capsule ended up, and how much of the horizontal
/// request it consumed getting there.
const StepUp = struct {
    centre: Vec3r,
    advance: Real,
};

/// Try to climb an obstacle instead of stopping at it: lift, advance, land, and accept only if what
/// was landed on is WALKABLE.
///
/// **Where `padding` enters the geometry, and it is not only the stopping distance.** A character
/// resting on the ground has its base `padding` above it, and after the climb it must be `padding`
/// above the step's top — so the rise between the two resting configurations is exactly the step's
/// height, and the lift to attempt is exactly `step_height` with no padding term. The padding
/// reappears in each of the three sweeps, which each stop short of what they meet.
///
/// **A STEP IS NOT A SLOPE, and step 4 is the whole reason this returns an optional.** Without that
/// check a character climbs an 80° ramp in increments the size of a stair, each increment
/// individually legitimate, and the slope limit it holds becomes unenforceable. That is a case in
/// the suite and not a remark.
///
/// Returns null — and moves NOTHING, so no lift survives a failed attempt — when there is no
/// headroom, when the obstacle is taller than the lift, when nothing is under the far side (a ledge,
/// not a step), or when the landing is too steep to stand on.
fn tryStepUp(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    record: shape_mod.Shape,
    probe: SupportShape,
    centre: Vec3r,
    direction: Vec3r,
    remaining_distance: Real,
    c: Character,
    touched: *TouchedBodies,
) ?StepUp {
    // 1 — lift.
    const up_hit = sweepNearest(bp, bm, store, record, probe, centre, up, c.step_height, c.layer_mask, c.inner_body, false);
    if (up_hit) |h| touched.add(h.body);
    const lift = paddedAdvance(up_hit, c.step_height, standoffTarget(c.padding, probe, centre));
    if (lift <= 0) return null;
    const lifted = centre.add(up.scale(lift));

    // 2 — forward, from the lifted pose. An advance of zero means the obstacle reaches above the
    // lift, which is exactly the `step_height + ε` case: the climb must fail and the caller slides.
    const fwd_hit = sweepNearest(bp, bm, store, record, probe, lifted, direction, remaining_distance, c.layer_mask, c.inner_body, false);
    if (fwd_hit) |h| touched.add(h.body);
    const forward_advance = paddedAdvance(fwd_hit, remaining_distance, standoffTarget(c.padding, probe, lifted));
    if (forward_advance <= 0) return null;
    const forward = lifted.add(direction.scale(forward_advance));

    // 3 — land. The drop budget is the lift plus one more step height, so a step DOWN on the far
    // side is still caught; finding nothing means there is no floor over there at all.
    const down_hit = sweepNearest(bp, bm, store, record, probe, forward, up.neg(), lift + c.step_height, c.layer_mask, c.inner_body, false) orelse return null;
    touched.add(down_hit.body);
    const drop = paddedAdvance(down_hit, lift + c.step_height, standoffTarget(c.padding, probe, forward));
    const landed = forward.sub(up.scale(drop));

    // 4 — the landing must be walkable.
    const sn = slideNormal(bm, store, probe, landed, down_hit.body, down_hit.distance, down_hit.normal, down_hit.subshape_id, down_hit.contact_normal) orelse return null;
    if (sn.normal.dot(up) < c.cos_max_slope) return null;

    // 5 — **THE CAPSULE MUST HAVE COME DOWN ONTO A SURFACE, and this is the reference's v5.6.0 bug
    // class.** MEASURED on an obstacle of `step_height + ε`: lift 0.3, forward 0.169, and a
    // down-sweep finding the obstacle only 0.0106 below, so `drop = max(0, 0.0106 − padding) = 0` —
    // the character lands WEDGED against the obstacle's top edge at the lifted height, standing on
    // nothing. The following slide then rides it up that edge's tilted normal onto a step it was
    // never allowed to climb: 0.37 where 0.02 is correct.
    //
    // **A second condition — "the landing must be HIGHER than the start" — was written here and then
    // REMOVED, measured in both directions.** Its purpose was the other squeeze mode: rise, advance
    // at a pose where the capsule's cross-section is narrower, and drop back to where you began. But
    // that is INDISTINGUISHABLE from stepping over a kerb onto level ground, which is legitimate and
    // which it forbade — measured on a 0.2 m kerb with flat ground either side: with the condition
    // the character stopped at x = 0.912 and ended 0.495 m in the AIR, having ratcheted up the
    // kerb's edge; without it, x = 2.0 at its original height, which is the whole requested move
    // served correctly.
    //
    // So the squeeze-onto-level-ground mode is NOT guarded, and that is recorded rather than
    // papered over: telling it from a legitimate step-over needs a test that the landed pose is
    // clear of the obstacle it was blocked by, which is a different mechanism from a height
    // comparison. Named for whoever ports the reference's stair-walking in full.
    if (drop <= 0) return null;

    return .{ .centre = landed, .advance = forward_advance };
}

/// Stick to the floor when walking off a ledge, if it is within `step_height`.
///
/// **The engine cannot guess INTENTION, so it uses the one fact it has**: the ground state at the
/// START of the move. A character that entered `.grounded` and walked off an edge is descending a
/// step; a character that entered `.in_air` is falling and must not be dragged down. That is the
/// reference's own condition for its floor-sticking.
///
/// A second condition is added and it is MEASURED, not stylistic: the move must not have asked to
/// go UP. `engine-movement.md`'s default `jump_velocity` is 8 m/s, so a jump's first tick rises
/// `8/60 = 0.133 m` — well inside the 0.3 m default `step_height`. On the entering tick the
/// character is still grounded, so without this guard floor-sticking cancels every jump on its
/// first frame, which is a behaviour nobody would attribute to a step-down feature.
///
/// A landing too steep to stand on is not a floor to stick to, so it is left alone.
fn stepDown(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    record: shape_mod.Shape,
    probe: SupportShape,
    centre: Vec3r,
    c: Character,
    touched: *TouchedBodies,
) Vec3r {
    const hit = sweepNearest(bp, bm, store, record, probe, centre, up.neg(), c.step_height, c.layer_mask, c.inner_body, false) orelse return centre;
    const sn = slideNormal(bm, store, probe, centre, hit.body, hit.distance, hit.normal, hit.subshape_id, hit.contact_normal) orelse return centre;
    if (sn.normal.dot(up) < c.cos_max_slope) return centre;
    touched.add(hit.body);
    // The SAME stand-off the depenetration establishes, not a bare `c.padding`: at `padding = 0` the
    // bare value descends the full distance to the floor and re-seats the capsule exactly tangent,
    // which froze the next call. See `standoffTarget`.
    return centre.sub(up.scale(paddedAdvance(hit, c.step_height, standoffTarget(c.padding, probe, centre))));
}

/// Push a DYNAMIC body the character walked into, and take nothing in return.
///
/// **Unilateral by construction** (§1.12.9): the character is kinematic, so no impulse is ever
/// applied to it and its own resolution is untouched — it stops `padding` short of the body whether
/// the body yields or not. That is what distinguishes a push from an elastic collision, and it is
/// asserted as a differential rather than described.
///
/// The impulse is what it would take to bring the body up to the character's own speed along the push
/// direction, clamped to `max_push_force · dt` — a force ceiling times a time IS an impulse, which is
/// what makes `max_push_force` a force in newtons rather than a fudge factor. `max_push_force = 0`
/// disables pushing with no special case, and so does a body already moving away faster than the
/// character.
///
/// `dt` is one of the two DERIVED terms §1.12.1 reserves it for; the character is never integrated
/// with it.
/// The impulse this contact owes the body, or null if it owes none. PLANS, never applies —
/// `PendingPushes.apply` is the only writer, and it runs after the publication.
///
/// If two slide iterations hit the SAME body, both plan against the velocity it had at the start of
/// the call — re-reading a velocity that has not been written yet is not available to a planner.
/// `PendingPushes` then SUMS the plans for one body and caps the magnitude of that sum ONCE, so the
/// applied total is at most `max_push_force · dt` however many contacts a body took. An earlier
/// paragraph here stated a worst case of `n · max_push_force · dt` and a sum that could come out
/// "slightly larger"; coalescing made that false, and it is deleted rather than qualified.
fn plannedPush(
    bm: *const BodyManager,
    body: BodyId,
    normal: Vec3r,
    character_velocity: Vec3r,
    c: Character,
    dt: Real,
) ?Vec3r {
    if (c.max_push_force <= 0 or dt <= 0) return null;
    if (bm.bodyType(body) != .dynamic) return null;
    // `normal` runs surface → character, so the character pushes along its negation.
    const direction = normal.neg();
    const body_velocity = bm.linearVelocity(body) orelse return null;
    const closing = character_velocity.dot(direction) - body_velocity.dot(direction);
    if (closing <= 0) return null; // the body is already leaving at least as fast
    const impulse = @min(c.mass * closing, c.max_push_force * dt);
    return direction.scale(impulse);
}

/// Push the capsule out of everything it overlaps, deepest first, and record whose wake that owes.
///
/// Bounded by `max_depenetration_iterations`. **Depenetration goes through the MANIFOLD and never
/// through the sweep** (§1.12.6): at distance zero a cast returns `−direction`, the direction
/// travelled from rather than the surface, which is correct for the cast's own invariant and
/// unusable for pushing out.
/// Push the character out of whatever it overlaps, deepest first, at most
/// `max_depenetration_iterations` times.
///
/// **IT PUSHES OUT, NEVER THROUGH (§1.12.6).** The pass resolves one body at a time, so in a squeeze
/// it alternates between two opposing surfaces and where it stops is the ITERATION COUNT'S PARITY —
/// MEASURED: with a capsule needing 1.8 m of headroom under a ceiling offering 1.0 m, a count of 3
/// or 5 leaves the base at −0.800000, the full depth of the squeeze and on the far side of the ground
/// plane, while 4 or 8 leaves it at 0. A guarantee cannot rest on the parity of a constant, and an
/// assertion on that parity protects the constant while saying nothing about the algorithm. So the
/// pass carries an invariant instead:
///
///   The depenetration NEVER moves the character to the far side of a contact plane it was on the
///   good side of at the ENTRY of the call.
///
/// Written that way the failure direction of an unresolvable squeeze is sayable, which is what the
/// brief requires of a guarantee: the character keeps the pose it came in with, and a residual
/// overlap, and does not tunnel. Enforced by reverting to the entry pose the moment a contact is
/// found whose plane the BASE has crossed since entry — resolving further would be tunnelling and
/// not depenetration. The base and not the centre: it is the reference point gameplay writes
/// (§1.12.3), and it is what "under the floor" means; the centre of a 1.8 m capsule is still 0.10 m
/// above a plane its feet have passed 0.80 m below, so a centre-based test does not fire at all.
///
/// The side test does NOT fire for a character that entered ALREADY on the wrong side — which is the
/// ordinary case of resting a few millimetres sunk into the ground — so no legitimate resolution is
/// refused. And it cannot refuse one by accident either: pushing out of a floor raises the base and
/// pushing out of a wall moves it sideways, so no push a resolvable overlap needs can cross a plane
/// the character was above.
///
/// A narrow door was examined as a second instance and is NOT one, measured rather than assumed: at
/// widths of 0.40, 0.50 and 0.58 m against a 0.60 m capsule, and at counts of 3, 4 and 5, the
/// character oscillates between ±(radius − half-width) and NEVER leaves the doorway. The two walls
/// are symmetric about its entry pose, so the alternation stays bounded; the ceiling case tunnels
/// because the floor is NOT a contact at entry, which makes the first push large and unopposed.
/// The coordinate scale the stand-off floor is measured in: the capsule's own extent plus its distance
/// from the origin, which is where float noise at this pose actually lives.
///
/// It is NOT `gjk.zig`'s symmetric pair scale, which also carries the other body's core extent — that
/// quantity is not reachable from here, the other side being a half-space or a per-triangle support
/// shape as often as a convex. The consequence is bounded and MEASURED rather than argued: see the
/// large-collider case in the acceptance suite.
fn coordScale(probe: SupportShape, centre: Vec3r) Real {
    return @sqrt(centre.lengthSq()) + narrowphase.coreExtent(Real, probe) + probe.radius;
}

/// The stand-off this controller leaves between the capsule and a surface it resolves against:
/// `padding` when the caller asked for one, and the numerical floor otherwise.
///
/// **BOTH the depenetration and the floor-sticking descent use it, and using it in only one place was
/// a defect found by enumerating the domain's bounds.** With `padding = 0`, `stepDown` passed a bare
/// zero to `paddedAdvance` and therefore descended the FULL distance to the floor, re-seating the
/// capsule exactly tangent — so the next call with any downward component in its displacement met a
/// contact at distance zero and froze, undoing what the depenetration had just established. Measured:
/// 0.2 m served on the first call and 0.0001 on every one after.
fn standoffTarget(padding: Real, probe: SupportShape, centre: Vec3r) Real {
    // **NOT `@max`, and the difference is a silent lie against a loud failure.** `@max` let the floor
    // OVERRIDE a padding the caller asked for: `64 · floatEps(f32) = 7.6e-6`, so the floor crosses the
    // 0.02 default at 2 632 m and reaches 3.8 cm at 5 km. A caller asking for 2 cm silently got 3.8, and
    // two identical scenes translated apart stopped at different distances — a supported region
    // answering wrongly without saying so.
    //
    // The floor exists to serve a caller who asked for NO stand-off, not to overwrite one who asked for
    // some. So a non-zero `padding` is honoured EXACTLY, at every scale, invariant under translation.
    //
    // The freeze regime returns where `padding` itself falls under the contact margin, which at the 0.02
    // default is a `coordScale` beyond about 10 km — inside the region §1.11.4 bis already declares f64.
    // And that failure is LOUD: the character does not move. A loud failure in a region declared
    // unsupported beats a silently wrong answer in a supported one, which is the direction of failure
    // this whole milestone has been choosing.
    if (padding > 0) return padding;
    return standoff_floor_k * std.math.floatEps(Real) * coordScale(probe, centre);
}

fn depenetrate(
    bp: *const Broadphase,
    bm: *const BodyManager,
    store: *const ShapeStore,
    record: shape_mod.Shape,
    probe: SupportShape,
    start: Vec3r,
    base_start: Vec3r,
    layer_mask: u32,
    exclude: ?BodyId,
    padding: Real,
    touched: *TouchedBodies,
) Vec3r {
    var centre = start;
    var i: u32 = 0;
    while (i < max_depenetration_iterations) : (i += 1) {
        var worst = WorstOverlap{
            .bm = bm,
            .store = store,
            .probe = probe,
            .centre = centre,
            .layer_mask = layer_mask,
            .exclude = exclude,
        };
        _ = bp.queryAabb(body_manager_mod.worldAabb(record, centre, Quatr.identity), &worst);
        const c = worst.best orelse break;
        touched.add(c.body);

        // THE INVARIANT. The manifold point is the MIDPOINT of the two surface points, so the body's
        // surface is half the penetration further along the outward normal. `s` is the base's signed
        // clearance from that surface, and the accumulated push changes it by exactly its projection
        // on the normal — so the entry value is the only thing this needs to carry. Both comparisons
        // are at TRUE ZERO: no tolerance can be right here, the question being which side of a plane
        // a point is on and not how far.
        const surface = c.position.add(c.normal.scale(c.penetration / 2));
        const s_entry = base_start.sub(surface).dot(c.normal);
        const s_now = s_entry + centre.sub(start).dot(c.normal);
        if (s_entry >= 0 and s_now < 0) return start;

        // **OUT TO `padding` OF CLEARANCE, NOT TO TOUCHING — and pushing to touching FROZE a character
        // permanently.** §1.12.6 makes the stand-off an obligation of the controller, and nothing
        // established it: `paddedAdvance` cannot, having nothing to subtract it from when the advance
        // is zero.
        //
        // A capsule left exactly tangent serves NO horizontal motion at all. The sweep reports a
        // contact at distance zero, the padded advance clamps to zero, and the slide returns a
        // horizontal motion projected on a horizontal plane unchanged — all four slide iterations are
        // consumed with no progress and the remainder is dropped. TRACED: `pen = −0.000000000`, normal
        // `+Y`, four identical rounds, final `x = 0`.
        //
        // And this pass MANUFACTURED that state rather than merely failing to leave it: a character
        // starting 0.05 m inside the floor was resolved to a base of exactly `0.000000000` and then
        // froze. The reachability is therefore not authoring alone — any interpenetration at all, from
        // a spawn, a teleport, a resize or a platform pushing the character in, ended frozen.
        //
        // A capsule already standing off is not moved: a manifold exists only within the contact margin,
        // so anything clear of it is `.separated` and invisible to this query. TRACED: 0.005 and 0.02
        // produce no contact at all, and 0.005 already serves a whole metre.
        //
        // That is the contract, not a limitation. `engine-physics-forge.md` §1.12.6: `padding` is what a
        // SWEEP RESERVES and not an invariant of pose, an authored pose closer than `padding` but clear
        // of the contact margin is deliberately not normalised, and the invariant actually held is the
        // narrower one — the controller never leaves the capsule inside the contact margin, where the
        // GJK band would decide the verdict from one frame to the next.
        const target = standoffTarget(padding, probe, centre);
        centre = centre.add(c.normal.scale(c.penetration + target));
    }
    return centre;
}

/// Generational store of character controllers.
///
/// The `ShapeStore` pattern verbatim: stable slots, LIFO recycling, a generation on the
/// handle. A plain column rather than a `MultiArrayList` because a character is addressed by
/// handle and never swept — which is what distinguishes it from `BodyManager`, whose SoA
/// exists for the per-tick integrator pass.
///
/// The generation is what makes §1.12's typed error on a stale handle implementable at all:
/// a bare slot index cannot tell a recycled slot from the handle that used to own it.
pub const CharacterStore = struct {
    alloc: IdAllocator = .{},
    characters: std.ArrayListUnmanaged(Character) = .empty,

    /// Release this store's own storage.
    ///
    /// It frees no shape and no body: those are owned by the `ShapeStore` and the
    /// `BodyManager`, whose own `deinit` releases them. A live character at teardown
    /// therefore leaks nothing — but its presence outlives it until that `BodyManager` is
    /// torn down, which is why `destroyCharacter` exists and why a test that checks for
    /// orphans checks the other two stores' counts.
    pub fn deinit(self: *CharacterStore, gpa: std.mem.Allocator) void {
        self.alloc.deinit(gpa);
        self.characters.deinit(gpa);
        self.* = undefined;
    }

    /// Number of live characters.
    pub fn count(self: *const CharacterStore) u32 {
        return self.alloc.live_count;
    }

    /// Create a controller, returning its handle.
    ///
    /// **TRANSACTIONAL.** Three resources are acquired here — the capsule in `store`, the
    /// presence in `bm` when `desc.inner_body` is set, and this store's own slot — and a
    /// failure at any of them leaves NO live slot, NO orphan shape and NO orphan body. The
    /// discipline is the `createShape` one applied across three stores: validate first
    /// (allocating nothing), then acquire each resource under an `errdefer` that releases
    /// it, and leave the two infallible commits last.
    ///
    /// The slot and the column are reserved LAST because they are the only remaining
    /// fallible steps once the two external resources are held; after them,
    /// `allocateAssumeCapacity` and the column write cannot fail, so there is no window in
    /// which a live slot exists without its shape or its presence.
    ///
    /// The presence is a `.kinematic` body carrying the controller's OWN capsule — the very
    /// `ShapeId` this call created, never a second shape (§1.12.2). Its layer is
    /// `collision_layer`. It is NOT inserted into the broadphase here: no
    /// `BodyType → BroadphaseLayer` wiring exists, the layer being an insertion argument, and
    /// that wiring arrives with `PhysicsWorld` at M1.1.15 — the same reason the query suites
    /// insert their own proxies.
    pub fn createCharacter(
        self: *CharacterStore,
        gpa: std.mem.Allocator,
        store: *ShapeStore,
        bm: *BodyManager,
        desc: CharacterDescriptor,
    ) !CharacterId {
        try validateDescriptor(desc);

        const shape_id = try store.createShape(gpa, .{ .capsule = .{
            .radius = desc.radius,
            .half_height = capsuleHalfHeight(f32, desc.radius, desc.height),
        } });
        errdefer store.destroyShape(gpa, shape_id);

        const presence: ?BodyId = if (desc.inner_body) try bm.addBody(gpa, store, .{
            .entity = desc.entity,
            // KINEMATIC: the controller's pose is written by `moveCharacter` and by that
            // entry alone, so the presence must never be integrated or solved.
            .body_type = .kinematic,
            .shape = shape_id,
            // The body's pose is the CENTRE of its shape; the descriptor gives the BASE.
            .position = desc.position.add(baseToCentre(f32, desc.height)),
            // No rotation field on the descriptor, and the absence is argued: the capsule is
            // symmetric about Y and the engine's up is Y, so no orientation changes a
            // collision answer (§1.12.3).
            .rotation = math.Quatf.identity,
            .collision_layer = desc.collision_layer,
            // `can_sleep` is left at its default and is INERT here: only dynamic bodies are
            // island members, and the sleep window sweep skips a non-dynamic body before it
            // touches it (§1.8.1, §1.8.3).
        }) else null;
        errdefer if (presence) |b| bm.removeBody(b);

        try self.alloc.ensureUnusedCapacity(gpa, 1);
        try self.characters.ensureUnusedCapacity(gpa, 1);

        // Infallible from here.
        const record = Character{
            .entity = desc.entity,
            .position = convVec3(desc.position),
            .radius = desc.radius,
            .height = desc.height,
            .step_height = desc.step_height,
            // The SINGLE trigonometric call of this module's whole life. Taken at `Real` on
            // the widened angle rather than in `f32` and widened after, so its accuracy is
            // bounded only by the angle the caller authored.
            .cos_max_slope = @cos(@as(Real, desc.max_slope)),
            .padding = desc.padding,
            .predictive_contact_distance = desc.predictive_contact_distance,
            .collision_layer = desc.collision_layer,
            .layer_mask = desc.layer_mask,
            .mass = desc.mass,
            .max_push_force = desc.max_push_force,
            .shape = shape_id,
            .inner_body = presence,
        };
        const a = self.alloc.allocateAssumeCapacity();
        if (a.is_new) {
            self.characters.appendAssumeCapacity(record);
        } else {
            self.characters.items[a.index] = record;
        }
        return a.id;
    }

    /// Destroy a controller, releasing all FOUR of its resources: the broadphase proxy, the presence
    /// body, the capsule in `store`, and the handle slot. No-op on a stale/invalid handle, like
    /// `removeBody` — and in particular it releases NOTHING there, which is what keeps a double
    /// destroy from double-freeing the capsule.
    pub fn destroyCharacter(
        self: *CharacterStore,
        gpa: std.mem.Allocator,
        bp: *Broadphase,
        store: *ShapeStore,
        bm: *BodyManager,
        id: CharacterId,
    ) void {
        const idx = self.alloc.validate(id) orelse return;
        const record = self.characters.items[idx];
        // **FOUR resources, and an earlier version released three.** The broadphase proxy was the one
        // left behind, and its own doc comment counted three — a number the code contradicted. A
        // leaked proxy is not merely untidy: the leaf stays in its tree with the last box the
        // presence had, so every query along that region still visits it and pair generation still
        // offers it, against a body handle that has been freed and whose slot will be recycled.
        //
        // Removed FIRST, and the order is not arbitrary: `Broadphase.remove` is INFALLIBLE, so this
        // entry stays `void` and there is no partial-teardown state to reason about.
        if (record.presence_proxy) |proxy| bp.remove(proxy);
        if (record.inner_body) |b| bm.removeBody(b);
        store.destroyShape(gpa, record.shape);
        _ = self.alloc.free(id);
    }

    /// The presence's `BodyId`, without which no caller can exclude itself from its own
    /// sweeps — the anti-wall sweep of a follow camera starts from the player, and
    /// `PhysicsQueryFilter.exclude` takes `BodyId` alone (§1.12.2).
    ///
    /// THREE outcomes, and none of them is confusable with another: a typed error on a stale
    /// handle, `null` for a character created without a presence, and the handle otherwise.
    /// Returning `null` for the stale case would conflate a dead handle with a live
    /// presence-less character, which is the false-negative class this module refuses.
    pub fn getCharacterInnerBody(self: *const CharacterStore, id: CharacterId) CharacterError!?BodyId {
        const idx = self.alloc.validate(id) orelse return error.StaleCharacter;
        return self.characters.items[idx].inner_body;
    }

    /// Safe getter — the stored record, or null if `id` is stale/invalid.
    pub fn get(self: *const CharacterStore, id: CharacterId) ?Character {
        const idx = self.alloc.validate(id) orelse return null;
        return self.characters.items[idx];
    }

    /// Register the broadphase proxy of a character's presence, so every later pose write keeps
    /// the tree fresh as well as the body. No-op on a stale handle.
    ///
    /// A seam and not a design preference: the broad LAYER is an insertion argument and the
    /// `BodyType → BroadphaseLayer` wiring arrives with `PhysicsWorld` at M1.1.15, so the store
    /// cannot choose where the proxy goes. Whoever does the insertion — the orchestrator later, the
    /// test harness now — hands the handle back through here.
    pub fn setPresenceProxy(self: *CharacterStore, id: CharacterId, proxy: Broadphase.Proxy) void {
        const idx = self.alloc.validate(id) orelse return;
        self.characters.items[idx].presence_proxy = proxy;
    }

    /// Move character `id` by `displacement` metres, resolving collisions, and return its new BASE
    /// position together with the ground verdict at that new pose.
    ///
    /// **A DISPLACEMENT, not a velocity** (§1.12.1). The kinematics belong to the caller
    /// (`engine-movement.md`) and the geometry to the engine, and `dt` serves only the DERIVED
    /// terms — the support velocity, and the push impulse at gate F — never to integrate the
    /// character. It is accepted here so the signature is the frozen one and the derived terms have
    /// their input the day they land.
    ///
    /// The algorithm, in the order it runs:
    ///
    ///   1. **Depenetrate** through the manifold, deepest overlap first, bounded.
    ///   2. **Sweep and slide**, bounded: sweep along what remains, advance to `padding` short of
    ///      the first contact, then constrain the rest against the accumulated contact planes —
    ///      one plane projects, two slide along their crease, and anything more stops.
    ///   3. **Publish**: write the record, mirror the pose onto the presence and its broadphase
    ///      proxy, wake what was touched, and recompute the ground verdict at the new pose.
    ///
    /// Both loops are bounded by NAMED ceilings and exhausting either stops the character SHORT of
    /// where it asked to go, never further — the safe failure direction (§1.11.11).
    ///
    /// Errors: `error.StaleCharacter` on a dead handle, `error.InvalidDisplacement` when
    /// `displacement` is outside the domain §1.12.6 gives it, and whatever the broadphase proxy
    /// update allocates.
    pub fn moveCharacter(
        self: *CharacterStore,
        gpa: std.mem.Allocator,
        bp: *Broadphase,
        bm: *BodyManager,
        store: *const ShapeStore,
        id: CharacterId,
        displacement: Vec3r,
        dt: Real,
    ) !MoveResult {
        const idx = self.alloc.validate(id) orelse return error.StaleCharacter;
        // The call parameter's domain (§1.12.6), at the entry and not mid-loop. `f64` is not a choice
        // made here: it is the evaluation arithmetic §1.12.6 FIXES, and the bound is on the norm as
        // computed in it.
        //
        // What IS decided here, and is written because it is nowhere else: no reduction by the
        // largest component is needed at this one site, unlike everywhere else this norm is taken.
        // The widening makes the square safe for every `f32`-origin input, and a square that
        // overflows `f64` can only come from a component already past the bound — the same verdict
        // by a shorter route.
        const displacement_limit: f64 = std.math.floatMax(f32);
        var displacement_norm_sq: f64 = 0;
        for (displacement.toArray()) |component| {
            if (!std.math.isFinite(component)) return error.InvalidDisplacement;
            const wide: f64 = component;
            displacement_norm_sq += wide * wide;
        }
        if (!(@sqrt(displacement_norm_sq) <= displacement_limit)) return error.InvalidDisplacement;
        const c = self.characters.items[idx];
        const record = store.get(c.shape) orelse unreachable;
        const probe = shape_mod.supportShape(record);

        var touched = TouchedBodies{};
        var pushes = PendingPushes{};
        // The character's own speed, DERIVED from the displacement and `dt` — the caller owns the
        // kinematics, so this is the only place the engine reconstructs a velocity, and it exists
        // solely to size the push impulse (§1.12.1).
        const character_velocity = if (dt > 0) displacement.scale(1 / dt) else Vec3r.zero;

        // 0 — the ground state BEFORE anything moves, which is the only thing the engine knows
        // about the caller's intention (see `stepDown`). Read here and not after, because after the
        // move it is a different question.
        const entered_grounded = (try self.groundOf(bp, bm, store, id)).state == .grounded;

        // 1 — depenetration.
        var centre = depenetrate(
            bp,
            bm,
            store,
            record,
            probe,
            c.position.add(baseToCentre(Real, c.height)),
            c.position,
            c.layer_mask,
            c.inner_body,
            c.padding,
            &touched,
        );

        // 2 — sweep and slide.
        var remaining = displacement;
        var planes: [2]Vec3r = @splat(Vec3r.zero);
        var plane_count: u32 = 0;
        var step_attempted = false;
        // **A CONTACT THAT DOES NOT OPPOSE THE MOTION MUST NOT CONSUME THE BUDGET.**
        //
        // This is the CONSEQUENCE the last four rounds kept approaching by its arrival paths. Each of
        // them closed one way of ending up exactly tangent — the depenetration's stand-off, then the
        // same stand-off at all five advance sites, then scoping it to `padding == 0` — and each time
        // another path appeared, because arrival at tangency is a float-resolution phenomenon and there
        // are as many paths as one likes: a 500 m collider whose resolution reseats the capsule
        // whatever the floor, a `padding` of `floatMin` whose addition changes no bit. What is FINITE
        // is what tangency then does — a zero advance against a surface that does not oppose the travel
        // direction obstructs nothing, yet the slide leaves the motion unchanged and the budget burns
        // with the remainder dropped.
        //
        // It is closed one level down: `sweepNearest` is asked for the nearest OPPOSING contact rather
        // than the nearest one, so a non-obstructing surface never becomes a candidate and this loop
        // needs no set, no budget and no expiry of its own. Four earlier forms lived here — a body slot,
        // a pair key, a bounded set, and their retry accounting — and each was a filter placed above the
        // data it judged.
        var iteration: u32 = 0;
        while (iteration < max_slide_iterations) : (iteration += 1) {
            // **THE EMPTINESS TEST, THE DIRECTION AND THE DISTANCE COME FROM ONE REDUCTION.** Asking
            // three times gave three different domains: `lengthSq() == 0` UNDERFLOWS for a denormal
            // remainder, so a real displacement read as nothing and was silently dropped; and
            // `@sqrt(lengthSq())` OVERFLOWS for a large one, so an INFINITE distance went on to become
            // the cast's `max_distance` and tripped the kernel's finiteness assert. Reducing by the
            // largest absolute component has neither failure, and taking all three answers from it is
            // what stops one of them being reconstructed the unsafe way.
            //
            // `null` is EXACT zero — a displacement of exactly nothing is done, and any representable
            // non-zero displacement is a real request to be served. No epsilon, and no threshold that
            // could disagree with the direction the same call is about to use.
            const step = remaining.unitAndLength() orelse break;
            const direction = step.unit;
            // Within the bound by INVARIANT, not by hope: the entry refused a norm past it, and
            // `remaining` only ever shrinks from there — both slide forms are PROJECTIONS, which
            // cannot lengthen a vector. `.?` is that invariant, checked in Debug and ReleaseSafe.
            const distance = step.length.?;

            const maybe_hit = sweepNearest(
                bp,
                bm,
                store,
                record,
                probe,
                centre,
                direction,
                distance,
                c.layer_mask,
                c.inner_body,
                true,
            );
            const hit = maybe_hit orelse {
                // Nothing in the way: the whole remaining displacement is served.
                centre = centre.add(remaining);
                remaining = Vec3r.zero;
                break;
            };
            touched.add(hit.body);

            // Advance to the STAND-OFF short of the surface, clamped at zero so a contact already
            // inside the margin does not push the character backwards.
            //
            // **`standoffTarget` and not a bare `c.padding`, and this is the site that made it a CLASS
            // rather than an instance.** With `padding = 0` a DIAGONAL advance stops exactly at contact,
            // so the capsule lands exactly tangent INSIDE this loop, and every later iteration then
            // finds distance zero and advances nothing — the freeze, re-manufactured per call from the
            // stand-off the depenetration had just established. Traced: `hit = 0.000000000`,
            // `adv = 0.000000000`, three dead iterations, 0.3 m of the request dropped.
            //
            // Fixing the depenetration and the descent alone left this path open, which is the third
            // instance of one class in this file: EVERY `paddedAdvance` call site owes the stand-off,
            // so the target belongs to all five and not to whichever one a probe happened to catch.
            const advance = paddedAdvance(hit, distance, standoffTarget(c.padding, probe, centre));
            centre = centre.add(direction.scale(advance));
            remaining = remaining.sub(direction.scale(advance));

            const sn = slideNormal(bm, store, probe, centre, hit.body, hit.distance, hit.normal, hit.subshape_id, hit.contact_normal) orelse {
                // No usable normal: stop rather than guess a direction. Short, never further.
                remaining = Vec3r.zero;
                break;
            };
            const normal = sn.normal;

            // The non-opposing zero-advance contact: set it aside and retry for free. `>= 0` is the
            // exact test — a surface the motion runs ALONG (dot exactly zero) obstructs nothing, and
            // one it runs away from even less.

            // PLAN the push on what was hit, if it is dynamic and yields. Planned here and applied
            // after the publication (see `PendingPushes`); the position in the loop is readability
            // alone, since the push is unilateral and cannot change the character's own resolution.
            if (plannedPush(bm, hit.body, normal, character_velocity, c, dt)) |impulse| {
                pushes.add(hit.body, impulse);
            }

            // **CLIMB BEFORE SLIDING**, once per call. Attempted only against a surface too steep
            // to walk on: something walkable is ground to stand on, not an obstacle to step over.
            // On failure NOTHING has moved — `tryStepUp` returns the landing pose or nothing at all
            // — so no lift survives a failed attempt, which is the reference's v5.6.0 bug class.
            if (!step_attempted and normal.dot(up) < c.cos_max_slope) {
                step_attempted = true;
                // The SAME reduction as the loop head, and for the same reason: `@sqrt(lengthSq())`
                // here overflowed to an infinite step distance, which reached the kernel's
                // `max_distance` assert. A second site of one class, on the only other path that
                // derives a length from the remainder.
                if (remaining.unitAndLength()) |step_left| {
                    // The same invariant as the loop head, and for the same reason.
                    if (tryStepUp(bp, bm, store, record, probe, centre, direction, step_left.length.?, c, &touched)) |stepped| {
                        centre = stepped.centre;
                        remaining = remaining.sub(direction.scale(stepped.advance));
                        // No plane is recorded: the character went OVER the obstacle, not along it,
                        // so it is not a wall to slide on.
                        continue;
                    }
                }
            }

            // Record the plane. A normal parallel to one already held replaces it rather than
            // filling the second slot, so a re-contact with the same wall does not read as a crease.
            if (plane_count == 1 and math.triangleCrossDirection(Real, Vec3r.zero, planes[0], normal) == null) {
                planes[0] = normal;
            } else if (plane_count < 2) {
                planes[plane_count] = normal;
                plane_count += 1;
            } else {
                // A third distinct plane is a corner: nothing left to slide along.
                remaining = Vec3r.zero;
                break;
            }

            if (plane_count == 1) {
                remaining = slideAlongPlane(remaining, planes[0], c.cos_max_slope);
            } else {
                remaining = slideAlongCrease(remaining, planes[0], planes[1], c.cos_max_slope) orelse {
                    // EXACTLY parallel normals — a third answer, not an absent edge. There is no
                    // crease to slide along, so the motion stops.
                    remaining = Vec3r.zero;
                    break;
                };
                // NO "still driving into a plane" check here, and its absence is a decision.
                // The crease axis is the CROSS PRODUCT of the two normals, so it is perpendicular
                // to both of them by construction and the motion projected onto it has a
                // mathematically ZERO dot with each. Testing that dot against zero would be
                // testing the SIGN OF FLOAT NOISE — measured: the box contact normals carry
                // components a few ULPs off their exact axis, and a strict `< 0` on that noise
                // stopped a legitimate edge slide dead. The corner case is already the third-plane
                // branch above, which is a structural condition rather than a numerical one.
            }
        }

        // 3 — stick to the floor on the way DOWN, under the two conditions `stepDown` argues: the
        // character entered grounded, and it did not ask to go up.
        if (entered_grounded and displacement.dot(up) <= 0) {
            centre = stepDown(bp, bm, store, record, probe, centre, c, &touched);
        }

        // 4 — publish. The record is AUTHORITATIVE and the presence mirrors it; the two are written
        // in one place so they cannot drift (see the Notes on this being the likeliest silent bug).
        const new_base = centre.sub(baseToCentre(Real, c.height));
        // The presence FIRST, because its proxy update is the one step that can fail: on OOM the
        // record must be left exactly as it was and the call retryable (see `syncPresenceTo`).
        try self.syncPresenceTo(gpa, bp, bm, store, idx, new_base, c.shape, c.height);
        self.characters.items[idx].position = new_base;

        // The wake this call owes. W4 and not W3: a presence moved by POSE WRITE keeps velocity
        // columns of exactly zero while it crosses the scene, so W3's true-zero velocity test never
        // sees it move (§1.12.10). Woken here rather than inside the collectors, which hold a
        // `*const BodyManager`.
        for (touched.slice()) |body| bm.wakeBody(body);

        // The pushes this call owes, drained here and not in the loop: everything above this line can
        // still fail, and a failure must leave the world untouched so the retry is not a second push.
        // One impulse per body, the per-body SUM capped once — see `PendingPushes`.
        pushes.apply(bm, c.max_push_force * dt);

        const ground = try self.groundOf(bp, bm, store, id);
        // Recorded so `setCharacterPosition` has something to INVALIDATE (§1.12.8).
        self.characters.items[idx].reported_ground = ground.state;
        return .{ .position = new_base, .ground = ground };
    }

    /// Resize a character, ATOMICALLY and ANCHORED AT THE FEET: the base does not move, the volume
    /// grows or shrinks upward, and the controller and its presence change together or not at all.
    ///
    /// **The presence's `BodyId` is KEPT** (§1.12.2): a resize is not a re-creation, so an exclusion
    /// the caller memorised survives it. That is what `BodyManager.setShape` exists for.
    ///
    /// THREE outcomes, which a bare `bool` would conflate — the same split as `shapeCast` (§1.11.7):
    /// a typed ERROR for the caller's fault (stale handle, or the SAME domain bounds
    /// `createCharacter` applies, `height >= 2 · radius` included); `false` for a target volume that
    /// is OCCUPIED, which is a legitimate gameplay answer and not an error; `true` for success.
    ///
    /// A refusal changes NOTHING — not the pose, not the dimensions, not the presence — and the new
    /// capsule it had to build to ask the question is destroyed on the way out.
    ///
    /// Shrinking always succeeds: the target volume is contained in the current one. Growing under a
    /// low ceiling returns `false`.
    pub fn resizeCharacter(
        self: *CharacterStore,
        gpa: std.mem.Allocator,
        bp: *Broadphase,
        bm: *BodyManager,
        store: *ShapeStore,
        id: CharacterId,
        radius: f32,
        height: f32,
    ) !bool {
        const idx = self.alloc.validate(id) orelse return error.StaleCharacter;
        // The same three length bounds `validateDescriptor` applies, and for the same reasons — a
        // resize is a second door onto the same domain, so it cannot be a laxer one.
        if (!std.math.isFinite(radius) or radius <= 0) return error.InvalidDimensions;
        if (!std.math.isFinite(height) or height <= 0) return error.InvalidDimensions;
        if (height < 2 * radius) return error.InvalidDimensions;

        const c = self.characters.items[idx];
        const new_shape = try store.createShape(gpa, .{ .capsule = .{
            .radius = radius,
            .half_height = capsuleHalfHeight(f32, radius, height),
        } });
        errdefer store.destroyShape(gpa, new_shape);
        const new_record = store.get(new_shape) orelse unreachable;
        const new_probe = shape_mod.supportShape(new_record);
        // ANCHORED AT THE FEET: the base is unchanged, so the new centre is derived from the NEW
        // height through the one named offset.
        const new_centre = c.position.add(baseToCentre(Real, height));

        // Is the target volume free? The character's OWN presence is excluded — it still carries the
        // old capsule, which the new one overlaps by construction, so including it would refuse
        // every resize.
        var probe_overlap = WorstOverlap{
            .bm = bm,
            .store = store,
            .probe = new_probe,
            .centre = new_centre,
            .layer_mask = c.layer_mask,
            .exclude = c.inner_body,
        };
        _ = bp.queryAabb(body_manager_mod.worldAabb(new_record, new_centre, Quatr.identity), &probe_overlap);
        if (probe_overlap.best != null) {
            store.destroyShape(gpa, new_shape);
            return false;
        }

        // The presence FIRST, with the NEW shape and height passed explicitly — so the proxy box
        // reflects the new SIZE and not only the new centre, and so the one fallible step of the
        // whole commit happens while the character is still entirely unchanged. A failure here
        // reaches the `errdefer` above with nothing to undo but the new capsule itself.
        try self.syncPresenceTo(gpa, bp, bm, store, idx, c.position, new_shape, height);

        // Infallible commit.
        const old_shape = c.shape;
        self.characters.items[idx].radius = radius;
        self.characters.items[idx].height = height;
        self.characters.items[idx].shape = new_shape;
        if (c.inner_body) |body| bm.setShape(store, body, new_shape);
        store.destroyShape(gpa, old_shape);

        // W4: whatever the NEW volume reaches. A superset, which is the safe direction.
        var waker = CandidateWaker{ .bm = bm, .exclude = c.inner_body };
        _ = bp.queryAabb(body_manager_mod.worldAabb(new_record, new_centre, Quatr.identity), &waker);
        return true;
    }

    /// Teleport a character: move it WITHOUT sweeping and without resolving (§1.12.8).
    ///
    /// It may leave the character interpenetrated, and that is the contract rather than a limitation
    /// — the caller asked to be somewhere, not to be moved toward somewhere. It INVALIDATES the
    /// reported ground verdict, which returns to `.in_air`.
    ///
    /// **NO-OP on a stale handle, and the discriminant is whether the entry RETURNS A VALUE.**
    /// `createCharacter`, `moveCharacter`, `resizeCharacter` and `getCharacterInnerBody` all return
    /// something, so a dead handle has no honest answer and they carry an error channel;
    /// `destroyCharacter` and this entry return nothing, so the no-op IS a coherent answer. Without
    /// exception across the repository, and it is why `moveCharacter` has a channel and this does not.
    ///
    /// A version of this shipped `error.StaleCharacter` here, argued from "a write the caller has to
    /// know did not happen". That argument proves too much: it holds identically for
    /// `setBodyTransform`, `setLinearVelocity` and `setAngularVelocity`, all `void` in the frozen
    /// surface, so applied to its end it makes every setter fallible — a decision about the whole
    /// Tier 0 surface and not about one entry. Whether setters should be fallible is recorded for
    /// M1.1.15, where the interface layer is built and the question covers all of it at once.
    ///
    /// **The frozen signature is `void` and this one is `!void`, and the residual `!` is NOT a
    /// semantic refusal — it is the broadphase's allocation.** Keeping the proxy fresh is part of this
    /// entry's contract (§1.12.2), `Broadphase.update` reserves a slot on its layer's moved log, and a
    /// `void` entry has nowhere to put that failure; making it truly `void` needs a reservation seam
    /// in the broadphase, which this milestone does not own. So the gap is in the frozen surface
    /// rather than a liberty taken here, it is disjoint from the stale-handle question settled above,
    /// and §1.11.7 forbids the easy answer of converting an error into an absent result. Recorded so
    /// the freeze meets it knowingly, alongside the setter-fallibility convention.
    pub fn setCharacterPosition(
        self: *CharacterStore,
        gpa: std.mem.Allocator,
        bp: *Broadphase,
        bm: *BodyManager,
        store: *const ShapeStore,
        id: CharacterId,
        position: Vec3r,
    ) !void {
        const idx = self.alloc.validate(id) orelse return;
        const c = self.characters.items[idx];
        // The presence FIRST — same reason as the other two write paths.
        try self.syncPresenceTo(gpa, bp, bm, store, idx, position, c.shape, c.height);
        self.characters.items[idx].position = position;
        self.characters.items[idx].reported_ground = .in_air;

        const record = store.get(c.shape) orelse unreachable;
        var waker = CandidateWaker{ .bm = bm, .exclude = c.inner_body };
        _ = bp.queryAabb(
            body_manager_mod.worldAabb(record, position.add(baseToCentre(Real, c.height)), Quatr.identity),
            &waker,
        );
    }

    /// The verdict the last `moveCharacter` reported, or null on a stale handle. `.in_air` after a
    /// `setCharacterPosition`, which invalidates it.
    pub fn reportedGround(self: *const CharacterStore, id: CharacterId) ?GroundState {
        const idx = self.alloc.validate(id) orelse return null;
        return self.characters.items[idx].reported_ground;
    }

    /// Mirror a TARGET pose and size onto the presence — the body AND its broadphase proxy — for a
    /// target the caller has not yet written into the record.
    ///
    /// **The one place that mirror is written.** The pose lives twice, in the record and in the
    /// body, and three entries write both; miss the proxy on any one of them and queries answer at
    /// the previous pose, which no test on a stationary character would find. So the three entries
    /// call this, and the freshness test is per write path rather than once on the move.
    ///
    /// **It takes the target rather than reading the record, so that the ONE FALLIBLE STEP RUNS
    /// BEFORE ANY MUTATION.** `Broadphase.update` allocates, and an earlier version called it AFTER
    /// the commit. Two distinct consequences, both real:
    ///
    ///  - In `resizeCharacter` the record and the presence body already pointed at the new shape,
    ///    which the `errdefer` then destroyed — the character was left holding a freed shape, a
    ///    use-after-free on its next move.
    ///  - On the two pose paths the record and the body had moved while the proxy had not, so the
    ///    stored box no longer contained the body and pairs were silently lost.
    ///
    /// The box published is the NEW one alone. An interim form published the UNION of the old and the
    /// new, and it was wrong twice. `Bvh.update` returns WITHOUT refitting as soon as its stored fat
    /// box already contains the new tight one, so a teleport's leaf covered the whole trajectory and
    /// no later call ever shrank it — permanent false positives in queries and in pair generation all
    /// along the path, from a form whose own comment claimed the next call would refit it. And the
    /// failure mode the union was guarding does not exist: `Broadphase.update` RESERVES its moved-log
    /// slot before touching the node, so on OOM neither the node's box nor the log has moved. That
    /// entry is already atomic and already satisfies the reserve-then-mutate invariant
    /// (M1.1.1-HF1 D3/D4) this one leans on.
    ///
    /// The containment short-circuit is therefore not a hazard but the fat margin's normal regime: a
    /// small advance does not refit, and does not need to, because the stored box still contains the
    /// body.
    fn syncPresenceTo(
        self: *const CharacterStore,
        gpa: std.mem.Allocator,
        bp: *Broadphase,
        bm: *BodyManager,
        store: *const ShapeStore,
        idx: u24,
        base: Vec3r,
        shape: api.ShapeId,
        height: Real,
    ) !void {
        const c = self.characters.items[idx];
        const body = c.inner_body orelse return;
        const record = store.get(shape) orelse unreachable;
        const centre = base.add(baseToCentre(Real, height));
        if (c.presence_proxy) |proxy| {
            try bp.update(gpa, proxy, body_manager_mod.worldAabb(record, centre, Quatr.identity));
        }
        // Infallible from here. NON-ACTIVATING by contract (§1.8.4) — this is the controller's own
        // write path, and the wake it owes is composed by the caller from the bodies it TOUCHED.
        bm.setPosition(body, centre);
    }

    /// The ground verdict for character `id` at its CURRENT pose — the controller is the
    /// engine's single source of the ground (§1.12.5), and no system re-derives one by a
    /// parallel raycast.
    ///
    /// **The verdict cannot come from manifolds at the current pose, and that is the trap of
    /// this mechanism.** `collideOrdered` returns null on a separated pair, and a character at
    /// rest is `padding` ABOVE its floor — so a manifold-only probe reports `.in_air` for a
    /// character plainly standing up. The ground is found by a bounded DOWNWARD SWEEP of the
    /// capsule instead, and the manifold is the fallback for the one case a sweep cannot answer
    /// (see `GroundCollector.add`).
    ///
    /// Selection: candidates are contacts whose outward normal has a strictly positive
    /// component on up; the winner is the FLATTEST of them, ties broken by the smaller
    /// `(BodyId, subshape_id)`. Verdict: the winner passing `normal · up >= cos_max_slope` is
    /// `.grounded`; a candidate existing but not passing is `.on_steep_ground`; no candidate at
    /// all is `.in_air`.
    ///
    /// Errors: `error.StaleCharacter` on a dead handle. A live character whose capsule has
    /// somehow left the store is a programming error rather than a caller's, and is asserted.
    pub fn groundOf(
        self: *const CharacterStore,
        bp: *const Broadphase,
        bm: *const BodyManager,
        store: *const ShapeStore,
        id: CharacterId,
    ) CharacterError!GroundInfo {
        const idx = self.alloc.validate(id) orelse return error.StaleCharacter;
        const c = self.characters.items[idx];
        // The store owns this capsule for the character's whole life, so its absence is an
        // internal invariant violation and not something a caller can provoke.
        const record = store.get(c.shape) orelse unreachable;

        const centre = c.position.add(baseToCentre(Real, c.height));
        var collector = GroundCollector{
            .bm = bm,
            .store = store,
            .probe = shape_mod.supportShape(record),
            .centre = centre,
            .max_sweep = groundSweepDistance(c),
            .layer_mask = c.layer_mask,
            .exclude = c.inner_body,
        };
        // The swept traversal of §1.11.10, in the form the query family already uses: nodes
        // inflated by the probe's half-extents, and the ray starting at the CENTRE of the
        // probe's world box. For a capsule that centre IS `centre`, the local box being
        // origin-centred — but it is read from the box rather than assumed, because that
        // equality is a property of this shape and not of the model.
        const box = body_manager_mod.worldAabb(record, centre, Quatr.identity);
        _ = bp.queryCast(Ray.init(box.center(), up.neg()), box.halfExtents(), &collector);

        const winner = collector.best orelse return .{};
        return .{
            .state = if (winner.align_up >= c.cos_max_slope) .grounded else .on_steep_ground,
            .normal = winner.normal,
            .entity = bm.entity(winner.body) orelse EntityId.dead,
            .body = winner.body,
            .velocity = contactPointVelocity(bm, winner.body, winner.point),
        };
    }
};

/// Velocity of the support AT the contact point: `v + ω × r`, with `r` running from the
/// support's centre of mass to that point.
///
/// **Without the rotational term a character standing at the rim of a rotating platform
/// drifts** (§1.12.5) — the platform's linear velocity is zero there while the surface under
/// the character is plainly moving. The centre of mass is the body's stored pose: every shape
/// the store builds is centred on its own origin.
///
/// Zero for a body whose handle went stale between the traversal and here, which cannot happen
/// within one call and is answered rather than asserted because zero is the correct velocity
/// of a support that is not there.
fn contactPointVelocity(bm: *const BodyManager, body: BodyId, point: Vec3r) Vec3r {
    const linear = bm.linearVelocity(body) orelse return Vec3r.zero;
    const angular = bm.angularVelocity(body) orelse return Vec3r.zero;
    const centre_of_mass = bm.position(body) orelse return Vec3r.zero;
    return linear.add(angular.cross(point.sub(centre_of_mass)));
}

/// Widen a descriptor `f32` `Vec3` to solver precision. The public surface is `f32`
/// (§1.11.8, §1.12.11) and widening it is one grouped decision at M1.1.15; this is the
/// abstraction point, so that decision touches the conversions and no call site.
fn convVec3(v: math.Vec3) Vec3r {
    if (Real == f32) return v;
    const a = v.toArray();
    return Vec3r.fromArray(.{ a[0], a[1], a[2] });
}
