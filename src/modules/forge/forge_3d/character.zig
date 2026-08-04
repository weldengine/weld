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
const IdAllocator = @import("slot_alloc.zig").IdAllocator;
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = body_manager_mod.BodyManager;
const BodyId = api.BodyId;
const ShapeId = api.ShapeId;
const CharacterId = api.CharacterId;
const CharacterDescriptor = api.CharacterDescriptor;
const EntityId = api.EntityId;

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
fn capsuleHalfHeight(comptime T: type, radius: T, height: T) T {
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

    if (!std.math.isFinite(desc.mass)) return error.InvalidPushParameters;
    // Zero would DUPLICATE `max_push_force = 0`, which is the documented way to disable
    // pushing — two ways to express one thing is the duplication class refused elsewhere in
    // this module. Negative INVERTS the impulse: the character pulls instead of pushing.
    if (desc.mass <= 0) return error.InvalidPushParameters;

    if (!std.math.isFinite(desc.max_push_force)) return error.InvalidPushParameters;
    // A negative force ceiling has no meaning; zero is the disabler.
    if (desc.max_push_force < 0) return error.InvalidPushParameters;

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
    /// **TRANSACTIONAL.** Three resources are acquired — the capsule in `store`, the
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

    /// Destroy a controller, releasing all three of its resources. No-op on a stale/invalid
    /// handle, like `removeBody` — and in particular it releases NOTHING there, which is what
    /// keeps a double destroy from double-freeing the capsule.
    pub fn destroyCharacter(
        self: *CharacterStore,
        gpa: std.mem.Allocator,
        store: *ShapeStore,
        bm: *BodyManager,
        id: CharacterId,
    ) void {
        const idx = self.alloc.validate(id) orelse return;
        const record = self.characters.items[idx];
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
};

/// Widen a descriptor `f32` `Vec3` to solver precision. The public surface is `f32`
/// (§1.11.8, §1.12.11) and widening it is one grouped decision at M1.1.15; this is the
/// abstraction point, so that decision touches the conversions and no call site.
fn convVec3(v: math.Vec3) Vec3r {
    if (Real == f32) return v;
    const a = v.toArray();
    return Vec3r.fromArray(.{ a[0], a[1], a[2] });
}
