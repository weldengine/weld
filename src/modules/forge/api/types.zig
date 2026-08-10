//! `forge/api/types.zig` — the public Forge descriptor and handle types.
//!
//! These mirror `engine-tier-interfaces.md` §1 (the day-1 interface contract).
//! Type definitions only — no ECS registration, no module instantiation. When
//! `src/interfaces/PhysicsModule.zig` lands (a later milestone) these become
//! its canonical home and `api/` re-exports, touching zero call sites.
//!
//! Math types come from `foundation.math` (Notes decision 3d). Per the E1
//! naming scheme the descriptor fields use the f32 aliases: `Vec3`
//! (`math.Vec3`) and `Quatf` (`math.Quatf`).

const std = @import("std");
const math = @import("foundation").math;
const core = @import("weld_core");

const Vec3 = math.Vec3;
const Quatf = math.Quatf;

/// Generational ECS entity handle — re-export of `core.ecs.EntityId` so forge
/// solvers reach the core entity type through `api/` (brief §E3), not via a
/// direct `weld_core` import.
pub const EntityId = core.ecs.EntityId;

/// Opaque physics-body handle. `u32` at the interface boundary
/// (`engine-tier-interfaces.md` §1); internally `index:24 | generation:8`
/// (Notes decision 4) — 16.7 M live bodies, a 256-generation ABA window.
/// Pack/unpack via `PackedId`.
pub const BodyId = u32;

/// Opaque collision-shape handle — same `u32` boundary and `index:24 |
/// generation:8` packing as `BodyId`.
pub const ShapeId = u32;

/// Opaque character-controller handle (M1.1.12, `engine-physics-forge.md` §1.12) —
/// same `u32` boundary and `index:24 | generation:8` packing as `BodyId`.
///
/// The GENERATION is not decoration here: §1.12 requires a typed error on a stale
/// handle from `moveCharacter`, `resizeCharacter` and `getCharacterInnerBody`, and
/// a bare slot index cannot tell a recycled slot from the handle that used to own
/// it. Without the generation that contract would be unenforceable rather than
/// merely unenforced.
pub const CharacterId = u32;

/// The `index:24 | generation:8` bit layout shared by `BodyId`, `ShapeId` and
/// `CharacterId` (index in the low 24 bits, generation in the high 8).
/// Stale-handle detection for the free-list slot reuse in
/// `ShapeStore`/`BodyManager` (M1.1.0 E3), and for the character store from
/// M1.1.12.
pub const PackedId = packed struct(u32) {
    /// Slot index into the owning pool (low 24 bits).
    index: u24,
    /// Generation tag bumped on slot reuse (high 8 bits).
    generation: u8,

    /// Bit pattern reserved for "no handle", shared by `BodyId`, `ShapeId` and
    /// `CharacterId`. Never produced by a slot allocator — `index = maxInt(u24)`
    /// would require 16.7 M live slots, well past any milestone target. Same
    /// reservation `EntityId.dead` makes on the ECS side, and the same reason.
    pub const dead: u32 = pack(std.math.maxInt(u24), std.math.maxInt(u8));

    /// Pack an index + generation into the `u32` handle.
    pub fn pack(index: u24, generation: u8) u32 {
        return @bitCast(PackedId{ .index = index, .generation = generation });
    }

    /// Unpack a `u32` handle into its index + generation fields.
    pub fn unpack(id: u32) PackedId {
        return @bitCast(id);
    }
};

/// Simulation class of a rigid body (shared with `PhysicsModule2D`).
/// Explicit `u8` backing so it embeds in the `extern` `RigidBody` component
/// (values and order per `engine-tier-interfaces.md` §1).
pub const BodyType = enum(u8) {
    /// Immovable, never simulated (ground, walls, static geometry).
    static,
    /// Position driven by gameplay; affects dynamics but is not affected.
    kinematic,
    /// Fully simulated — gravity, forces, collision response.
    dynamic,
};

/// Collision-shape kind. `u8`-backed (component tag). C1.1-complete set —
/// the spec §1 enum is a subset; the extension (plane, tapered_cylinder,
/// height_field, mutable_compound, empty) is additive and pre-freeze
/// (Notes decision 3b). `createShape` constructs sphere/box/capsule (M1.1.0),
/// plane (M1.1.11) and triangle_mesh (M1.1.11.1 — the twelfth and LAST shape of the
/// C1.1 list); every other variant returns `error.UnsupportedShape` until its
/// own sub-milestone.
pub const ShapeType = enum(u8) {
    /// Sphere (radius).
    sphere,
    /// Axis-aligned box (half-extents).
    box,
    /// Capsule (radius + cylinder half-height, Y axis).
    capsule,
    /// Solid cylinder.
    cylinder,
    /// Tapered cylinder (cone frustum).
    tapered_cylinder,
    /// Convex hull of a point set.
    convex_hull,
    /// Infinite half-space plane.
    plane,
    /// Static triangle mesh.
    triangle_mesh,
    /// Terrain height field.
    height_field,
    /// Immutable compound of sub-shapes.
    compound,
    /// Mutable compound of sub-shapes.
    mutable_compound,
    /// Empty (no geometry).
    empty,
};

/// Shape parameters, a tagged union discriminated by `ShapeType`. The spec §1
/// flat struct self-describes as a simplification of a discriminated union;
/// the union IS the specified design (Notes decision 3a).
/// M1.1.0 carries payloads for sphere/box/capsule and M1.1.11 adds plane; the
/// rest are `void` placeholders whose payloads land at their own sub-milestones —
/// a pre-freeze extension of the union that `engine-tier-interfaces.md` §1
/// explicitly permits, each payload-less variant receiving its payload at the
/// sub-milestone that delivers the shape.
pub const ShapeDescriptor = union(ShapeType) {
    /// Sphere of `radius` metres.
    sphere: struct { radius: f32 = 0.5 },
    /// Box with the given half-extents (metres).
    box: struct { half_extents: Vec3 = Vec3.splat(0.5) },
    /// Capsule of `radius` and cylinder `half_height` (metres), Y axis.
    capsule: struct { radius: f32 = 0.3, half_height: f32 = 0.5 },
    /// Placeholder — payload lands at the cylinder sub-milestone.
    cylinder: void,
    /// Placeholder — payload lands at the tapered-cylinder sub-milestone.
    tapered_cylinder: void,
    /// Placeholder — payload lands at the convex-hull sub-milestone.
    convex_hull: void,
    /// Solid half-space `n·x <= d`: `normal` unit, `distance` in metres, both in
    /// the shape's local frame and transported by the body pose (M1.1.11,
    /// `engine-physics-forge.md` §1.11.15).
    ///
    /// The body carrying it must be STATIC: a half-space has neither a finite
    /// volume, nor an inertia tensor, nor a local AABB, so mass, inertia and sleep
    /// radius are undefined on it. `addBody` rejects a dynamic or kinematic body
    /// carrying one with `error.ShapeMustBeStatic`, BEFORE any computation derived
    /// from a local AABB or an inertia — the ordering is normative, both of those
    /// living in the body literal with no branch on body type of their own. Same
    /// invariant as the reference, whose plane declares `MustBeStatic`.
    ///
    /// **Domain, asserted at creation.** Both fields carry a precondition and they are of
    /// the same class, so they are declared TOGETHER and in the same place — on the public
    /// surface the caller reads, not only at the site that checks them (§1.11.15).
    /// `normal` is ALREADY unit, to the tolerance of its own precision — it is `f32`
    /// whatever the solver scalar is — and `distance` is FINITE. Both are checked in
    /// `createShape`; the stored normal is normalised once there, so no call site ever
    /// re-normalises.
    ///
    /// `distance` earns its own clause because a non-finite one is not caught downstream
    /// by anything — it is silently accepted, and two consumers then disagree about it.
    /// MEASURED with a NaN distance, identically at f32 and f64: the contact generator
    /// reported a contact point for a unit sphere 1000 m OUTSIDE the solid, since its
    /// `sep > 0` skip is FALSE when `sep` is NaN; while the broadphase corner predicate
    /// reported no overlap for a box at the origin AND for a box 5000 m INSIDE, since its
    /// `<=` is false in the other direction. One malformed field, two silent behaviours
    /// that contradict each other, and no diagnostic — which is why this is a precondition
    /// and not a tolerance, the same pattern the typed rejection of a `collision_layer`
    /// outside `[0, 32)` exists to close (§1.11.4).
    plane: struct { normal: Vec3 = Vec3.unit_y, distance: f32 = 0 },
    /// Static triangle mesh (M1.1.11.1, `engine-physics-forge.md` §1.11.17). A
    /// SURFACE and not a solid, and that is CATEGORICAL rather than a setting:
    /// membership is false everywhere, `pointQuery` never returns a body carrying
    /// one, and `closestPoint` measures to the surface and is never zero by
    /// interiority. There is no mesh counterpart to `treat_convex_as_solid`.
    ///
    /// The body carrying it must be STATIC: `addBody` rejects a dynamic or kinematic
    /// one with `error.ShapeMustBeStatic`. The motive is NOT the half-space's — a mesh
    /// has a valid local AABB, hence a defined sleep radius; what it lacks is a
    /// VOLUME, an open surface enclosing nothing, so no inertia tensor derives from it
    /// and `unit_inertia` is NaN.
    ///
    /// `vertices` and `indices` are BORROWED for the duration of the call:
    /// `createShape` takes an owned copy, and the caller is free to release them on
    /// return. WINDING is counter-clockwise seen from the front face, and the outward
    /// normal is `normalize((v₁−v₀) × (v₂−v₀))` in that FIXED order, so its value is a
    /// deterministic function of the stored vertices (§1.5).
    ///
    /// **Domain, refused by typed error and never sanitised.** Rejected at creation: an
    /// index count that is not a multiple of three, an index outside the vertex array, a
    /// non-finite vertex, a mesh with no triangle, and a triangle whose cross product is
    /// EXACTLY zero — the true-zero guard of §1.11.4 on its largest absolute component,
    /// applied verbatim. A sliver of tiny but non-zero area normalises exactly and MUST
    /// be served; no area threshold appears anywhere.
    ///
    /// The refusal never REMOVES the offending triangle. The reference sanitises
    /// (`MeshShapeSettings::Sanitize` drops duplicate and degenerate triangles); Weld
    /// refuses, because a removal RENUMBERS and that number IS the `subshape_id`
    /// (§1.11.16) — caller and engine would then designate different triangles with no
    /// diagnostic at all, the same silent-wrong-answer class the `[0, 32)` bound on
    /// `collision_layer` already exists to close.
    ///
    /// `active_edge_cos_threshold` is the cosine below which a CONVEX edge is treated as
    /// ACTIVE, and it is authored HERE because the flags are baked at creation: this is
    /// the only path a caller has to them, and after the M1.1.15 freeze the field could
    /// not land at all. Same pre-freeze window as `BackFaceMode`, and it closes at this
    /// shape. A named PHYSICAL parameter of the same class as `restitution_threshold` and
    /// `penetration_slop` — it selects a modelling behaviour, not a numerical tolerance,
    /// so §1.11.2's `k · floatEps(T) · coordScale` discipline does not apply to it. It is
    /// `f32` like the rest of this surface (§1.11.8), so the same descriptor names the
    /// same threshold in an `f32` and an `f64` build; the solver widens it once.
    /// `forge_3d/mesh.zig`'s `default_active_edge_cos_threshold` is the source of truth
    /// for this default, and the equality of the two is pinned by a test there.
    triangle_mesh: struct {
        vertices: []const Vec3,
        indices: []const u32,
        /// `cos(5°)`, whose nearest `f32` is `0.9961947202682495` — the reference's
        /// `mActiveEdgeCosThresholdAngle` default.
        active_edge_cos_threshold: f32 = 0.99619472,
    },
    /// Placeholder — payload lands at the height-field sub-milestone.
    height_field: void,
    /// Placeholder — payload lands at the compound sub-milestone.
    compound: void,
    /// Placeholder — payload lands at the mutable-compound sub-milestone.
    mutable_compound: void,
    /// Placeholder — the empty shape carries no parameters.
    empty: void,
};

/// Everything needed to create one body (`engine-tier-interfaces.md` §1).
/// `linear_damping` defaults to 0.05 to agree with the `RigidBody` component
/// and Jolt (spec §1 says 0.01, §2 says 0.05 — Notes decision 3c).
pub const BodyDescriptor = struct {
    /// Owning ECS entity.
    entity: EntityId,
    /// Simulation class.
    body_type: BodyType,
    /// Collision shape (created via `ShapeStore.createShape`).
    shape: ShapeId,
    /// World-space position (metres).
    position: Vec3 = Vec3.zero,
    /// World-space orientation.
    rotation: Quatf = Quatf.identity,
    /// Mass (kg).
    mass: f32 = 1.0,
    /// Coulomb friction coefficient.
    friction: f32 = 0.5,
    /// Restitution (bounciness).
    restitution: f32 = 0.3,
    /// Linear velocity damping per second.
    linear_damping: f32 = 0.05,
    /// Angular velocity damping per second.
    angular_damping: f32 = 0.05,
    /// Collision-layer index. Bounded to `[0, collision_layer_count)`: the query
    /// mask is 32 bits, so `addBody` REJECTS anything beyond with
    /// `error.InvalidCollisionLayer` instead of creating a body no query could
    /// ever see (§1.11.5).
    collision_layer: u8 = 0,
    /// Per-body gravity multiplier.
    gravity_factor: f32 = 1.0,
    /// Continuous collision detection for fast movers.
    continuous: bool = false,
    /// Whether the body is allowed to fall asleep. Mirrors `RigidBody.can_sleep`
    /// (`engine-physics-forge.md` §2), which the descriptor dropped until M1.1.8 —
    /// the same gap class as the `friction`/`restitution` drop closed at M1.1.6.
    can_sleep: bool = true,
    /// SENSOR role: the body detects without responding (`engine-physics-solver.md`
    /// §1.13). It is inserted into the `trigger` broad class, whose matrix row and
    /// column are `false` in full — so it never reaches constraint construction —
    /// and it is ignored BY CONSTRUCTION by the character controller's three
    /// collection paths (§1.13.7).
    ///
    /// The role is a property of the INSTANCE and not of the geometry: the shape
    /// store is shared, so carrying this field on `ShapeDescriptor` would force two
    /// bodies sharing a sphere to share their nature (§1.13.1). The ECS authoring
    /// surface is `CollisionShape.is_trigger` (`engine-physics-forge.md` §2),
    /// translated here.
    ///
    /// PRE-FREEZE EXTENSION, second-to-last window: after the M1.1.15 freeze of
    /// `PhysicsModule` this field could no longer land, and nothing would let a
    /// caller declare a trigger at all.
    is_trigger: bool = false,
    /// OBJECT layers this trigger detects: a candidate passes when
    /// `(1 << candidate_layer) & trigger_layer_mask` is non-zero. Same mechanism
    /// and same semantics as `PhysicsQueryFilter.layer_mask`, the only object-layer
    /// filtering the engine owns (§1.11.5).
    ///
    /// UNILATERAL: the mask belongs to the trigger and describes what IT sees, so
    /// two overlapping triggers are two relations evaluated separately and A may
    /// see B without B seeing A (§1.13.5).
    ///
    /// INERT on a non-trigger body, and the field exists anyway: without it a
    /// damage zone detects projectiles, debris and scenery, and the only substitute
    /// would be reserving an object layer for triggers, which would make a
    /// technical class carry a gameplay policy. Same arbitrage as `back_face_mode`
    /// on `OverlapQuery` — an almost-inert field against a permanent dead end.
    /// PRE-FREEZE EXTENSION, second-to-last window.
    trigger_layer_mask: u32 = 0xFFFFFFFF,
};

// --- Body pose and velocity entries — semantics frozen here ---
//
// `PhysicsModule`'s function declarations live in `src/interfaces/PhysicsModule.zig`,
// which does not exist yet: it lands at M1.1.15 with `ModuleContext`, and this file is
// the day-1 mirror of `engine-tier-interfaces.md` §1 until then (see the file header).
// So the SEMANTICS of three body entries are recorded here, next to the frozen types
// they traffic in, and they move with the declarations when that file lands.
//
// DESTINATION: M1.1.15 MOVES this block onto those three declarations in
// `src/interfaces/PhysicsModule.zig`. It is not duplicated there — two copies of a
// contract are two things that can disagree, which is the whole subject of the block.
//
//   - `setBodyTransform(id, position, rotation)` is a TELEPORTATION. It writes the pose
//     and derives NO velocity: a kinematic body moved through it keeps velocity columns
//     of exactly zero. That is not an oversight to be repaired — it is the same split the
//     reference draws between `SetPositionAndRotation` and `MoveKinematic`.
//
//     The consequence is load-bearing for the character controller and it is why this
//     note exists: `CharacterMoveResult.ground_velocity` is measured AT THE CONTACT
//     POINT, so it reads the support's `v + ω × r`. A platform teleported through this
//     entry therefore reports a ground velocity of ZERO while visibly moving
//     (`engine-physics-forge.md` §1.12.5). The fix is to drive such a platform with
//     `moveKinematic`, never to make this entry guess a velocity from two poses it was
//     not given a `dt` for.
//
//   - `moveKinematic(id, target_position, target_rotation, dt)` is what DERIVES both
//     velocities from a target pose over a `dt`, on the shape of
//     `BodyInterface::MoveKinematic`. Its signature freezes at M1.1.12; its body is a
//     typed stub until M1.1.15, deriving a velocity belonging to the tick cycle and the
//     wake composition, which arrive with `PhysicsWorld`. Same pattern C1.1 authorises by
//     name for `createJoint` and M1.1.9 already executed on five query entries.
//
//   - `setAngularVelocity(id, ω)` closes a gap dating from M1.1.0: `PhysicsModule2D`
//     carries `setAngularVelocity2D` and the reference carries both, while 3D carried only
//     the linear setter — so `ω` was authorable by NO caller at all, and the rotational
//     term of `ground_velocity` had no source. `BodyManager` has had the column setter
//     since M1.1.8; what was missing is the interface entry.
//
// Write intent, unchanged from §1.8.4: a pose or velocity WRITE is non-activating (it is
// the solver's own path), while an external mutation — force, torque, impulse — wakes. The
// interface tier composes wake + write for every setter it exposes to gameplay, and a
// character presence moved by pose write is wake cause W4, never W3 (§1.12.10).

/// Everything needed to create one character controller
/// (`engine-physics-forge.md` §1.12). A controller is VIRTUAL: it takes part in no
/// solver pass — no inverse mass, no inertia tensor, no contact constraint, no island
/// membership — and its pose is written by `moveCharacter` and by that entry alone.
///
/// There is NO rotation field, and the absence is argued rather than suffered: the
/// capsule is symmetric about Y, the engine's up is Y
/// (`engine-coordinate-system.md`), so no orientation changes a collision answer. That
/// validity is CONDITIONAL on the presence carrying the same capsule — were an
/// arbitrary presence shape ever admitted, rotation would become necessary again,
/// which is one more reason not to admit one (§1.12.3).
///
/// Absent for reasons recorded rather than forgotten: `max_speed` is kinematics and
/// belongs to `MovementConfig` (`engine-movement.md`) — `moveCharacter` takes a
/// displacement already computed; and `friction` has no meaning on a body that never
/// reaches the contact solver, ground braking being `MovementConfig.ground_friction`.
pub const CharacterDescriptor = struct {
    /// Owning ECS entity.
    entity: EntityId,

    /// Position of the capsule's BASE, NEVER its centre (§1.12.3). A body's pose is the
    /// centre of its shape — the capsule being symmetric about the origin — so the
    /// presence sits at this position plus half the height along up. That offset exists in
    /// exactly ONE named place in the solver: computed twice, it will diverge once.
    ///
    /// The anchor is FIXED where the reference PARAMETERISES it through `mShapeOffset` —
    /// a deliberate divergence, this descriptor carrying only `radius` and `height`, hence
    /// a capsule and nothing else.
    ///
    /// The DEFAULT is `Vec3.zero`, and a base placed exactly tangent to a surface — which that default
    /// is, over a floor at `y = 0` — is served: `depenetrate` establishes the `padding` stand-off
    /// §1.12.6 requires. An earlier version documented that configuration as a degenerate input the
    /// caller had to avoid, which was a bug with an apology attached: a precondition the field's own
    /// default violates is not a precondition.
    position: Vec3 = Vec3.zero,

    /// Capsule radius (metres).
    radius: f32 = 0.3,
    /// Total capsule height, base to top (metres).
    height: f32 = 1.8,
    /// Tallest riser the controller climbs rather than being blocked by (metres).
    step_height: f32 = 0.3,

    /// Steepest walkable slope, in RADIANS. A named PHYSICAL parameter of the class of
    /// `restitution_threshold`, `penetration_slop` and `active_edge_cos_threshold`: it
    /// selects a modelling behaviour, not a numerical tolerance, so §1.11.2's
    /// `k · floatEps(T) · coordScale` discipline DOES NOT GOVERN IT. A reviewer applying
    /// that rule here will be wrong.
    ///
    /// RADIANS here and DEGREES in the Etch components, the conversion belonging to the
    /// `@unit(.degrees)` annotation — the divergence is written down so that nobody
    /// "corrects" either side. The solver stores its COSINE, computed once at creation,
    /// and tests `n · up >= cos_max_slope`: an `acos` per contact per frame is exactly
    /// what M1.1.14 would have to make reproducible, `engine-phase-1-plan.md` naming
    /// internal trigonometric functions among its determinism hazards (§1.12.5).
    ///
    /// A value outside `[0, π/2]` is a DOMAIN ERROR and is never clamped: silently
    /// clamping would make a caller's mistake look like a modelling choice.
    max_slope: f32 = 0.785, // ~45°

    /// Distance the capsule is held off surfaces (metres). Same class as `max_slope` — a
    /// physical parameter, not a tolerance, and §1.11.2 governs it no more than the
    /// other. Without a margin the capsule sits flush and GJK's own contact-margin band
    /// then decides the verdict from one frame to the next. The reference's
    /// `mCharacterPadding` value.
    ///
    /// Domain `[0, ∞)`, and the lower end is the one that took work. ZERO is legal and means no
    /// PHYSICAL margin; the solver then holds the capsule off by a numerical floor so the
    /// classification band cannot decide the verdict from one frame to the next, and that floor
    /// applies ONLY at zero — a `padding` the caller asked for is honoured exactly, at every
    /// scale, invariant under translation.
    ///
    /// There is deliberately NO upper bound. A large value stops the character further from
    /// obstacles, which is what a large stand-off means, and it was measured NOT to push the
    /// capsule through thin geometry: at `2 ·` and `3.3 · radius`, against a 0.1 m wall, at seven
    /// entry depths straddling its mid-plane, it exits on the side it entered from every time.
    padding: f32 = 0.02,

    /// How far OUTSIDE the shape to sweep for contacts not yet touching (metres). The
    /// reference documents that a value of zero most likely gets the character stuck, the
    /// sliding direction no longer being computable (`mPredictiveContactDistance`).
    ///
    /// THE ONE FIELD OF THIS DESCRIPTOR THE ALGORITHM HAS NOT YET JUSTIFIED. It ships
    /// because the pre-freeze window closes at M1.1.15 and the only known production
    /// realisation of this algorithm declares it load-bearing. The gate that writes
    /// sliding CONSUMES it or DELETES it — both stay inside the window; leaving it inert
    /// does not.
    predictive_contact_distance: f32 = 0.1,

    /// What the character IS, read by others through the mask of THEIR queries.
    ///
    /// Bounded to `[0, collision_layer_count)`: `createCharacter` rejects anything beyond
    /// with `error.InvalidCollisionLayer`, the same error and the same reason as `addBody`
    /// (§1.11.5) — the mask is 32 bits, and a character declared past it would be
    /// invisible to every query with no diagnostic at all.
    ///
    /// It serves as the PRESENCE layer too, with no dedicated field: the reference carries
    /// a separate `mInnerBodyLayer` because it does not split the character's layer, and
    /// our split with `layer_mask` already does that work (§1.12.2).
    collision_layer: u8 = 0,

    /// What the character SEES, read by itself alone in its own sweeps. Two questions
    /// with no shared path (§1.12.4). The object-layer matrix of
    /// `engine-physics-forge.md` §3 does not govern a controller: it filters simulation
    /// PAIRS, which a sweep is not (§1.11.1).
    layer_mask: u32 = 0xFFFFFFFF,

    /// Mass serving the push impulse (kg). The character receives NOTHING in return: it
    /// is kinematic, so the push is unilateral by construction (§1.12.9). The reference's
    /// `mMass` value.
    mass: f32 = 70.0,

    /// Ceiling on the push force (N). Zero disables pushing with no special case. The
    /// reference's `mMaxStrength` value.
    max_push_force: f32 = 100.0,

    /// Whether the character carries a broadphase PRESENCE — a kinematic body holding ITS
    /// OWN capsule (§1.12.2). Without one it is invisible to every query, and the argument
    /// for that being unacceptable is internal to this descriptor rather than borrowed from
    /// any scene: `collision_layer` above is the mechanism by which an object declares
    /// itself VISIBLE to other callers' queries (§1.11.5 — the layer tested is the touched
    /// shape's, and the caller declares by mask what it wants to see). So either the
    /// character carries a presence, or `collision_layer` is a field with no observable
    /// effect. This surface has promised query visibility since it was written.
    ///
    /// There is NO `inner_body_shape` field: two shapes that can diverge are a
    /// synchronisation contract with no counterpart, and `resizeCharacter` would have to
    /// resize both. That absence is also what keeps the missing rotation field valid.
    ///
    /// DEFAULT `true`, a deliberate divergence from the reference, which defaults to
    /// `nullptr`: the failure mode of a default-off is a character nobody can shoot,
    /// discovered late.
    inner_body: bool = true,
};

/// The ground verdict, TERNARY (`engine-physics-forge.md` §1.12.5). Zig mirror of the
/// Etch enum declared in `engine-movement.md` §2 — same order, same values, the same
/// mirror contract `BodyType` keeps with the `body_type` field of the `RigidBody`
/// component.
///
/// A boolean would force the consumer to re-derive the angle from the normal, hence to
/// recompute `max_slope` OUTSIDE the engine that holds it, hence to be able to disagree
/// with it. It also could not carry `on_steep_ground`, which is precisely the state
/// `engine-movement.md` §5 transitions on.
pub const GroundState = enum(u8) {
    /// On ground whose slope is walkable.
    grounded,
    /// Bearing on a slope too steep to walk.
    on_steep_ground,
    /// No ground. THE DEFAULT EVERYWHERE, and it is a failure DIRECTION: a `.grounded`
    /// default on an unknown verdict means gravity not applied, hence a character that
    /// floats — a symptom that does not correct itself; `.in_air` means one tick of
    /// gravity, hence a sub-millimetre sink that does. Same reasoning as the
    /// contact-announced-early of §1.11.11.
    in_air,
};

/// Result of one `moveCharacter`.
///
/// The former `collisions: u8` field is DELETED: a counter with no named consumer in the
/// corpus, saturating at 255, and a counter belongs only to a shape that is allowed to
/// fail. `CharacterMoveResult2D` carries the same field and SURVIVES this removal — the
/// 2D symmetry is consigned for M1.8.11, where `PhysicsModule2D` freezes, on the M1.1.11
/// precedent of listing a 2D symmetry in OUT with its freeze date rather than touching 2D
/// from a 3D milestone.
///
/// **`ground_state` is the discriminator, and the two support handles carry an explicit
/// "no support" value rather than relying on it.** `ground_entity` is `EntityId.dead` and
/// `ground_body` is `PackedId.dead` outside `.grounded` / `.on_steep_ground`, so a caller
/// that reads one without consulting the verdict gets an unmistakably absent handle
/// instead of a plausible wrong answer. `ground_normal` is the one field carrying a
/// meaningful value in every state, and that is deliberate (see its own doc).
pub const CharacterMoveResult = struct {
    /// Position of the BASE after resolution (§1.12.3) — what gameplay writes into
    /// `Transform.position`, and where every probe of the caller starts from.
    position: Vec3,

    /// The VERDICT. A direction does not mix into it.
    ground_state: GroundState = .in_air,

    /// The DIRECTION. `Vec3.up` on `.in_air` — spelled `Vec3.unit_y` here, `foundation`
    /// math naming its basis vectors by axis while `engine-coordinate-system.md` names
    /// this one semantically; under the engine's Y-up convention the two are the same
    /// value, `(0, 1, 0)`.
    ///
    /// NEVER a poisoned value, and this is the one `ground_*` field that holds in every
    /// state: three documents read it inside a `@replicated` component
    /// (`engine-movement.md`, `engine-animation-kinesis.md`,
    /// `engine-gameplay-systems.md`) and a NaN here would cross the rollback. The
    /// poisoning discipline of §1.11.17 does not extend to this struct.
    ground_normal: Vec3 = Vec3.unit_y,

    /// Entity of the support. `EntityId.dead` outside `.grounded` / `.on_steep_ground`.
    /// Required by the moving-platform velocity inheritance of `engine-movement.md` §4.
    ///
    /// NON-NULL on `.on_steep_ground` as much as on `.grounded`: a steep slope is still a
    /// support, and the field is null only on `.in_air` (§1.12.5).
    ground_entity: EntityId,

    /// Body of the support — what the caller interrogates it through without searching for
    /// it. `PackedId.dead` outside `.grounded` / `.on_steep_ground`, in step with
    /// `ground_entity`.
    ///
    /// The default is the SENTINEL and not `0`, and the reason is structural:
    /// `PackedId.pack(0, 0)` is `0`, so with `0` as the default NO bit configuration of this
    /// field would mean absence. The field would be unreadable without consulting a
    /// neighbouring one — and that coupling is invisible at the C ABI level. `engine-c-api.md`
    /// carries neither `struct_size` nor a minor version, so a Tier 3 caller reading
    /// `ground_body` alone has no way to learn it was supposed to read `ground_state` first,
    /// and no future version can teach it.
    ground_body: BodyId = PackedId.dead,

    /// Velocity AT THE CONTACT POINT, hence `v + ω × r` and not the support's linear
    /// velocity: without the rotational term a character standing at the rim of a
    /// rotating platform drifts. Zero on `.in_air`.
    ///
    /// This field is the reason `setAngularVelocity` and `moveKinematic` ship at all —
    /// without them `ω` has no authorable source (see the body-entry block above).
    ground_velocity: Vec3 = Vec3.zero,
};

// --- Queries (the complete family, frozen before the interface freeze) ---
//
// Mirrors `engine-tier-interfaces.md` §1 verbatim. The family is settled IN FULL
// here even where the body is a Phase-1 stub: adding a method to a comptime
// strategy interface after its freeze (M1.1.15) breaks every Tier 3 solver, so
// deferring a signature is not admissible (`engine-physics-forge.md` §1.11.7).
//
// These types are the f32 PUBLIC boundary, deliberately distinct from their
// solver-side counterparts in `forge_3d/query.zig` (`Filter`, `RayQuery`,
// `RayHit`) which carry the solver scalar. Two levels by design, not duplication:
// §1.11.8 makes the public surface f32 — consistent with `BodyDescriptor`, the
// interface `Transform` and the ECS `Transform` — and widening it is one decision
// over all of them at once, at M1.1.15. The conversion between the two levels is
// the interface tier's, and it is the only place that ever knows both.

/// Number of object layers a query mask can address. The mask is 32 bits, so a
/// body on a layer outside `[0, collision_layer_count)` would be invisible to
/// EVERY query with no diagnostic — which is why `addBody` rejects it with
/// `error.InvalidCollisionLayer` rather than accepting it (§1.11.5). Consistent
/// with the eight default layers of `engine-physics-forge.md` §3.
pub const collision_layer_count: u8 = 32;

/// Filtering shared by the whole query family (`engine-physics-forge.md`
/// §1.11.5). The mask applies to the OBJECT layer of the shape hit, never to the
/// broadphase's broad layers, and a layer is bounded to
/// `[0, collision_layer_count)`.
///
/// Named `PhysicsQueryFilter`, not `QueryFilter`: §6 `AIModule` already carries a
/// `QueryFilter` for its spatial queries. The two are distinct types and neither
/// renames the other.
pub const PhysicsQueryFilter = struct {
    /// A candidate passes when `(1 << layer) & layer_mask` is non-zero.
    layer_mask: u32 = 0xFFFFFFFF,
    /// Bodies ignored. Dominant case: myself.
    exclude: []const BodyId = &.{},
};

/// Which side of a TRIANGLE an entry answers on (`engine-physics-forge.md` §1.11.17).
/// The front face is the side the outward normal points to.
///
/// Carried only by the entries whose ANSWER differs between the two modes. It is
/// meaningless outside a mesh: a convex is SOLID and has no back (§1.11.4), and neither
/// has a half-space. It is absent from `overlapAabb`, which sees no triangle, from
/// `pointQuery`, which never returns a mesh, and from `closestPoint`, whose distance to
/// a surface is not signed.
///
/// Weld carries ONE field where the reference carries two — `RayCastSettings` and
/// `ShapeCastSettings` each declare a triangle mode AND a convex mode, both at
/// `IgnoreBackFaces`. The convex half is already settled here, and not by a setting.
///
/// PRE-FREEZE EXTENSION, last window: after the M1.1.15 freeze of `PhysicsModule` this
/// field could not land at all.
pub const BackFaceMode = enum(u8) {
    /// A triangle met from behind does not answer. The default, aligned with the
    /// reference and with the three real consumers — line of sight, ground probe,
    /// step probe.
    ignore,
    /// It answers, and the returned normal is FLIPPED. §1.11.4 declares
    /// `normal · direction <= 0` on EVERY hit, and the `−direction` choice at distance
    /// zero draws its justification from that invariant; returning the outward normal
    /// unchanged would puncture it. Assumed divergence from the reference, which returns
    /// it unchanged. Nothing is lost — the caller ASKED for this mode, and the real side
    /// stays reachable through `subshape_id`.
    collide,
};

/// A world-space ray query. `direction` need not be normalised — it is at the
/// entry. The tested interval is CLOSED, `[0, max_distance]`, and an origin
/// inside a shape produces a hit at distance zero (convexes are solid, §1.11.4).
pub const RaycastQuery = struct {
    /// Ray origin (metres).
    origin: Vec3,
    /// Ray direction.
    direction: Vec3,
    /// Maximum distance; finite and `>= 0`, and `0` degenerates to a point test.
    max_distance: f32,
    /// Object-layer mask + exclusions.
    filter: PhysicsQueryFilter = .{},
    /// Which side of a mesh triangle answers. Vacuous on every other shape.
    back_face_mode: BackFaceMode = .ignore,
};

/// A cast of an arbitrary shape. Replaces the former `SphereCastQuery`: ONE entry
/// serves sphere, box and capsule, and the three Etch forms of
/// `engine-physics-forge.md` §13 are wrappers over it (§1.11.7). Symmetric with
/// `ShapeCastQuery2D`.
pub const ShapeCastQuery = struct {
    /// The shape being cast.
    shape: ShapeId,
    /// Start position of the cast shape (metres).
    origin: Vec3,
    /// Orientation of the cast shape.
    rotation: Quatf = Quatf.identity,
    /// Sweep direction.
    direction: Vec3,
    /// Maximum sweep distance.
    max_distance: f32,
    /// Object-layer mask + exclusions.
    filter: PhysicsQueryFilter = .{},
    /// Which side of a mesh triangle answers. Vacuous on every other shape. Under
    /// `.collide` the normal a back-face hit returns FACES the sweep, which is what the two
    /// real consumers — slope and ground probe — read.
    back_face_mode: BackFaceMode = .ignore,
};

/// An overlap test of an arbitrary shape. Same construction as the cast: the
/// sphere and box overlaps of §13 are wrappers over this one entry.
pub const OverlapQuery = struct {
    /// The shape being tested.
    shape: ShapeId,
    /// Its position (metres).
    position: Vec3,
    /// Its orientation.
    rotation: Quatf = Quatf.identity,
    /// Object-layer mask + exclusions.
    filter: PhysicsQueryFilter = .{},
    /// Which side of a mesh triangle answers: under `.ignore` a triangle whose probe lies
    /// ENTIRELY in the rear half-space of its plane is discarded, while a probe STRADDLING the
    /// plane touches from the front and counts in both modes (§1.11.17).
    ///
    /// **MEASURED INERTIA, and you should know it before setting this.** On THIS entry the two
    /// modes agree on the answer except inside GJK's own contact margin. A triangle lies IN its
    /// plane, so any probe that overlaps a triangle necessarily reaches that plane and
    /// straddles it; and a probe entirely behind the plane cannot overlap the triangle at all,
    /// so every triangle the predicate discards is one GJK already classifies `separated`. What
    /// is left is a band a few ULPs wide, where a core sitting just behind the plane reads as
    /// `.shallow`. Setting this field expecting a different set of bodies back will disappoint.
    ///
    /// **It exists anyway, and not for symmetry.** This entry returns BODIES, which is a Weld
    /// choice and not a fact of the world; the reference carries the same field on
    /// `CollideShapeSettings` precisely because its equivalent returns points and normals. The
    /// day this entry gains a normal, the field becomes load-bearing — and after the M1.1.15
    /// freeze of `PhysicsModule` it could not be added at all. So the cost is one nearly inert
    /// field, against a dead end that would be permanent.
    ///
    /// On the SWEEP (`ShapeCastQuery`) the mode is fully observable: a cast reaches a back face
    /// from a distance, and the two modes return different answers on the same geometry.
    back_face_mode: BackFaceMode = .ignore,
};

/// One ray hit.
///
/// `subshape_id` is an OPAQUE PATH decoded by the ROOT shape, never a global index: its
/// width is a property of the SHAPE and not of the value, and a shape with no sub-shape
/// consumes ZERO BITS, so the `0` default is not read at all (§1.11.16). Sphere, box,
/// capsule and plane all carry zero sub-shapes. That is NOT the same statement as the
/// M1.1.9/M1.1.10 wording it replaces ("0 while one shape is one body"), and the
/// difference is what makes the encoding forward-compatible: wrapping a shape in a
/// compound shifts its index up and inserts the child's below, extending the encoding
/// without reinterpreting any value already written.
///
/// The service derives `physics_material` from it, because the solver result carries the
/// sub-shape identity and never the material itself (§1.11.7 — the same construction as
/// the reference's `CastResult.h`).
pub const RaycastHit = struct {
    /// Entity owning the body hit.
    entity: EntityId,
    /// The body hit.
    body: BodyId,
    /// Sub-shape hit — an opaque path, zero bits wide for a shape with no sub-shape,
    /// so the `0` is not read (§1.11.16; the type doc above carries the reasoning).
    subshape_id: u32 = 0,
    /// World-space hit point.
    position: Vec3,
    /// World-space outward surface normal at the hit point.
    normal: Vec3,
    /// Distance from the ray origin — a distance, never a fraction (§1.11.4).
    distance: f32,
};

/// One shape-cast hit. Distinct from `RaycastHit` (parity with `ShapeCastHit2D`):
/// a cast has TWO sub-shapes, the one being cast and the one hit.
pub const ShapeCastHit = struct {
    /// Entity owning the body hit.
    entity: EntityId,
    /// The body hit.
    body: BodyId,
    /// Sub-shape of the body that was hit.
    subshape_id: u32 = 0,
    /// Sub-shape of the CAST shape that made contact.
    cast_subshape_id: u32 = 0,
    /// World-space contact point.
    position: Vec3,
    /// World-space contact normal.
    normal: Vec3,
    /// Sweep distance at contact.
    distance: f32,
};

/// Result of `closestPoint`: the closest point on the closest collider within the
/// requested radius.
pub const ClosestPointResult = struct {
    /// Entity owning the collider.
    entity: EntityId,
    /// The body.
    body: BodyId,
    /// Sub-shape carrying the closest point.
    subshape_id: u32 = 0,
    /// World-space closest point on the collider.
    position: Vec3,
    /// Distance from the queried point.
    distance: f32,
};

/// A physics pose — position + orientation, no scale. Distinct from the ECS
/// `Transform` component (which carries scale): physics bakes scale into the
/// collider, so runtime scale has no stable physical meaning. Verbatim per
/// `engine-tier-interfaces.md` §1.
pub const Transform = struct {
    /// World-space position (metres).
    position: Vec3,
    /// World-space orientation.
    rotation: Quatf,
};

const testing = std.testing;

test "BodyId pack/unpack round-trip" {
    const id = PackedId.pack(0x123456, 0xAB);
    // index in the low 24 bits, generation in the high 8.
    try testing.expectEqual(@as(u32, (0xAB << 24) | 0x123456), id);
    const u = PackedId.unpack(id);
    try testing.expectEqual(@as(u24, 0x123456), u.index);
    try testing.expectEqual(@as(u8, 0xAB), u.generation);

    const maxed = PackedId.pack(std.math.maxInt(u24), std.math.maxInt(u8));
    try testing.expectEqual(@as(u24, std.math.maxInt(u24)), PackedId.unpack(maxed).index);
    try testing.expectEqual(@as(u8, std.math.maxInt(u8)), PackedId.unpack(maxed).generation);
    try testing.expectEqual(@as(u32, 0), PackedId.pack(0, 0));
}

test "PackedId.dead is the all-ones no-handle reservation" {
    // All ones in both fields, so the whole `u32` is `0xFFFFFFFF`. Reserved rather than
    // merely unlikely: a slot allocator would have to reach 16.7 M live slots to produce
    // this index, which is the same argument `EntityId.dead` makes with 4 G on the ECS side.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), PackedId.dead);
    try testing.expectEqual(@as(u24, std.math.maxInt(u24)), PackedId.unpack(PackedId.dead).index);
    try testing.expectEqual(@as(u8, std.math.maxInt(u8)), PackedId.unpack(PackedId.dead).generation);

    // ONE constant for the three handles, because they share the packing. A per-type
    // sentinel would be three values to keep equal, hence one to get wrong.
    const as_body: BodyId = PackedId.dead;
    const as_shape: ShapeId = PackedId.dead;
    const as_character: CharacterId = PackedId.dead;
    try testing.expectEqual(as_body, as_shape);
    try testing.expectEqual(as_body, as_character);
}

test "ShapeDescriptor payload defaults" {
    const s = ShapeDescriptor{ .sphere = .{} };
    try testing.expectEqual(@as(f32, 0.5), s.sphere.radius);

    const b = ShapeDescriptor{ .box = .{} };
    try testing.expect(b.box.half_extents.approxEql(Vec3.splat(0.5), 0));

    const c = ShapeDescriptor{ .capsule = .{} };
    try testing.expectEqual(@as(f32, 0.3), c.capsule.radius);
    try testing.expectEqual(@as(f32, 0.5), c.capsule.half_height);

    // The plane payload (M1.1.11), on the same footing as the other three: its
    // default is `{x : y <= 0}`, a ground plane through the origin, and the default
    // normal is EXACTLY unit — which is what lets `.plane = .{}` pass the
    // creation-time domain assert of `forge_3d/shape.zig` unchanged.
    const p = ShapeDescriptor{ .plane = .{} };
    try testing.expect(p.plane.normal.eql(Vec3.unit_y));
    try testing.expectEqual(@as(f32, 0), p.plane.distance);
    try testing.expectEqual(@as(f32, 1), p.plane.normal.lengthSq());

    // The mesh payload (M1.1.11.1) carries NO default, and that is deliberate rather
    // than an omission: both fields are BORROWED slices, an empty one would describe a
    // mesh with no triangle, and that is precisely what `createShape` refuses. So the
    // pin is on the field NAMES and the ELEMENT types — the public boundary is f32
    // (§1.11.8), so the vertices are `math.Vec3` and not the solver scalar, and the
    // indices are `u32` because that is the width `subshape_id` carries.
    const verts = [_]Vec3{ Vec3.zero, Vec3.unit_x, Vec3.unit_y };
    const idx = [_]u32{ 0, 1, 2 };
    const m = ShapeDescriptor{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } };
    try testing.expectEqual([]const Vec3, @TypeOf(m.triangle_mesh.vertices));
    try testing.expectEqual([]const u32, @TypeOf(m.triangle_mesh.indices));
    try testing.expectEqual(@as(usize, 3), m.triangle_mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), m.triangle_mesh.indices.len);
}

test "BodyDescriptor defaults match the brief" {
    const d = BodyDescriptor{
        .entity = EntityId{ .index = 0, .generation = 0 },
        .body_type = .dynamic,
        .shape = 0,
    };
    try testing.expectEqual(@as(f32, 1.0), d.mass);
    try testing.expectEqual(@as(f32, 0.5), d.friction);
    try testing.expectEqual(@as(f32, 0.3), d.restitution);
    try testing.expectEqual(@as(f32, 0.05), d.linear_damping);
    try testing.expectEqual(@as(f32, 0.05), d.angular_damping);
    try testing.expectEqual(@as(u8, 0), d.collision_layer);
    try testing.expectEqual(@as(f32, 1.0), d.gravity_factor);
    try testing.expectEqual(false, d.continuous);
    try testing.expectEqual(true, d.can_sleep);
    try testing.expect(d.position.eql(Vec3.zero));
    try testing.expect(d.rotation.approxEql(Quatf.identity, 0));

    // The two SENSOR fields (M1.1.13), transcribed from `engine-tier-interfaces.md` §1
    // at version 0.9 name for name and default for default. `is_trigger` defaults OFF —
    // the role is opt-in, and a default of `true` would make every body that forgot the
    // field stop responding physically. `trigger_layer_mask` defaults to ALL layers, the
    // same value and the same reason as `PhysicsQueryFilter.layer_mask`: a mask that
    // defaulted to zero would make a declared trigger detect nothing, which reads as
    // "sensors do not work" rather than as "you forgot the mask" (§1.13.5).
    try testing.expectEqual(false, d.is_trigger);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), d.trigger_layer_mask);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), (PhysicsQueryFilter{}).layer_mask);

    // The mask is 32 bits WIDE, which is what makes it the same object-layer mechanism as
    // the query filter's and what bounds `collision_layer` to `[0, collision_layer_count)`.
    // A `u16` here would silently make every body above layer 15 undetectable.
    try testing.expectEqual(u32, @TypeOf(d.trigger_layer_mask));
    try testing.expectEqual(@as(usize, collision_layer_count), @bitSizeOf(@TypeOf(d.trigger_layer_mask)));

    // Referencing every field by name makes a rename or a removal a COMPILE error; this
    // count is what makes an ADDITION visible, which no by-name reference can catch. Same
    // shape as `CharacterDescriptor`'s below, and for the same reason: after the M1.1.15
    // freeze, `engine-c-api.md` carrying no `struct_size` and no minor version, appending
    // one defaulted field here is an ABI break and not a source-compatible addition.
    try testing.expectEqual(@as(usize, 16), @typeInfo(BodyDescriptor).@"struct".fields.len);

    // The role is a property of the INSTANCE and never of the geometry (§1.13.1): the
    // shape store is shared and one `ShapeId` is referenceable by several bodies, so the
    // field on `ShapeDescriptor` would force two bodies sharing a sphere to share their
    // nature. Pinned as an ABSENCE, because that is the form the error would take — a
    // later milestone moving it there has to delete this line first.
    inline for (@typeInfo(ShapeDescriptor).@"union".fields) |f| {
        if (@typeInfo(f.type) == .@"struct") {
            try testing.expect(!@hasField(f.type, "is_trigger"));
            try testing.expect(!@hasField(f.type, "trigger_layer_mask"));
        }
    }
}

test "ShapeType and BodyType are u8-backed" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ShapeType.sphere));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ShapeType.capsule));
    try testing.expectEqual(@as(u8, 11), @intFromEnum(ShapeType.empty));
    try testing.expectEqual(@as(u8, 0), @intFromEnum(BodyType.static));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(BodyType.dynamic));
}

test "the frozen query family mirrors engine-tier-interfaces.md §1" {
    // Field NAMES and defaults are the contract: this is a verbatim mirror, and a
    // rename here is a break for every Tier 3 solver after the M1.1.15 freeze.
    const f = PhysicsQueryFilter{};
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), f.layer_mask);
    try testing.expectEqual(@as(usize, 0), f.exclude.len);
    try testing.expectEqual(@as(u8, 32), collision_layer_count);

    const ray = RaycastQuery{ .origin = Vec3.zero, .direction = Vec3.unit_x, .max_distance = 10 };
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), ray.filter.layer_mask);

    const cast = ShapeCastQuery{ .shape = 0, .origin = Vec3.zero, .direction = Vec3.unit_x, .max_distance = 1 };
    try testing.expect(cast.rotation.approxEql(Quatf.identity, 0));

    const overlap = OverlapQuery{ .shape = 0, .position = Vec3.zero };
    try testing.expect(overlap.rotation.approxEql(Quatf.identity, 0));

    // `subshape_id` defaults to 0, and §1.11.16 is why that default is safe rather than
    // provisional: it is an opaque PATH whose width the shape declares, and a shape with
    // no sub-shape consumes zero bits, so the value is not read. It is by this field that
    // the service derives the material, never from the solver result.
    const hit = RaycastHit{
        .entity = .{ .index = 0, .generation = 0 },
        .body = 0,
        .position = Vec3.zero,
        .normal = Vec3.unit_y,
        .distance = 1,
    };
    try testing.expectEqual(@as(u32, 0), hit.subshape_id);

    const cast_hit = ShapeCastHit{
        .entity = .{ .index = 0, .generation = 0 },
        .body = 0,
        .position = Vec3.zero,
        .normal = Vec3.unit_y,
        .distance = 1,
    };
    // A cast has TWO sub-shapes; that second field is what distinguishes this
    // type from `RaycastHit` and why they are not merged.
    try testing.expectEqual(@as(u32, 0), cast_hit.subshape_id);
    try testing.expectEqual(@as(u32, 0), cast_hit.cast_subshape_id);

    const closest = ClosestPointResult{
        .entity = .{ .index = 0, .generation = 0 },
        .body = 0,
        .position = Vec3.zero,
        .distance = 2,
    };
    try testing.expectEqual(@as(u32, 0), closest.subshape_id);

    // The public boundary is f32 (§1.11.8) — pinned, because widening it is a
    // single decision over `BodyDescriptor`, the interface pose, the query results
    // and the ECS `Transform` together, at M1.1.15, and never one of them alone.
    try testing.expectEqual(f32, @TypeOf(hit.distance));
    try testing.expectEqual(f32, @TypeOf(ray.max_distance));
    try testing.expectEqual(f32, @TypeOf(closest.distance));
}

test "CharacterId carries the PackedId layout, so a stale handle is detectable" {
    // `u32` at the interface boundary, `index:24 | generation:8` inside — the same
    // packing as `BodyId` and `ShapeId`, reached through the same one helper.
    try testing.expectEqual(u32, CharacterId);

    const id: CharacterId = PackedId.pack(7, 3);
    try testing.expectEqual(@as(u24, 7), PackedId.unpack(id).index);
    try testing.expectEqual(@as(u8, 3), PackedId.unpack(id).generation);

    // THE property §1.12 needs from this handle: a recycled slot and the handle that used
    // to own it differ, so `moveCharacter` can answer with a typed error instead of
    // silently moving whoever took the slot over. Without the generation the two are the
    // same integer and that contract is unenforceable, not merely unenforced.
    try testing.expect(PackedId.pack(7, 3) != PackedId.pack(7, 4));

    // And the limit of that, stated rather than discovered: all three handles are `u32`,
    // so they are NOT distinct types and the compiler cannot stop a `BodyId` being passed
    // where a `CharacterId` is wanted. That is the frozen boundary's own choice
    // (`engine-tier-interfaces.md` §1 declares all of them `u32`); the generation guards
    // slot recycling, never handle confusion.
    try testing.expectEqual(BodyId, CharacterId);
}

test "GroundState is the ternary verdict, u8-backed, in engine-movement.md's order" {
    // The Etch enum in `engine-movement.md` §2 is the owner declaration and this is its
    // Zig mirror: same order, same values. Four documents read this verdict, so a
    // reordering here is a silent change of meaning in all of them.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(GroundState.grounded));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(GroundState.on_steep_ground));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(GroundState.in_air));
    try testing.expectEqual(u8, @typeInfo(GroundState).@"enum".tag_type);

    // THREE values, and the count is asserted because §1.12.8 REFUSES a fourth: inventing
    // an `unknown` to report an invalidated verdict would cost more than the safe failure
    // direction earns, `.in_air` already being that direction. Counter-factual: appending a
    // fourth value leaves the three asserts above passing and fails HERE (measured).
    try testing.expectEqual(@as(usize, 3), @typeInfo(GroundState).@"enum".fields.len);
}

test "CharacterDescriptor mirrors engine-tier-interfaces.md §1 field for field" {
    // Field NAMES and defaults are the contract. Referencing each field by name makes a
    // rename or a removal a COMPILE error; the field-COUNT assert is what makes an
    // ADDITION visible, which no by-name reference can catch. Both directions matter here
    // and not merely in principle: after the M1.1.15 freeze, `engine-c-api.md` carrying no
    // `struct_size` and no minor version, adding one defaulted field to this descriptor is
    // an ABI break for every Tier 3 plugin rather than a source-compatible addition.
    const d = CharacterDescriptor{ .entity = EntityId.dead };

    try testing.expect(d.position.eql(Vec3.zero));
    try testing.expectEqual(@as(f32, 0.3), d.radius);
    try testing.expectEqual(@as(f32, 1.8), d.height);
    try testing.expectEqual(@as(f32, 0.3), d.step_height);
    try testing.expectEqual(@as(f32, 0.785), d.max_slope);
    try testing.expectEqual(@as(f32, 0.02), d.padding);
    try testing.expectEqual(@as(f32, 0.1), d.predictive_contact_distance);
    try testing.expectEqual(@as(u8, 0), d.collision_layer);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), d.layer_mask);
    try testing.expectEqual(@as(f32, 70.0), d.mass);
    try testing.expectEqual(@as(f32, 100.0), d.max_push_force);
    try testing.expectEqual(true, d.inner_body);

    // `entity` carries NO default, and that is transcribed rather than improved: a
    // controller belonging to no entity is not a thing this descriptor should be able to
    // express by omission.
    try testing.expectEqual(EntityId, @TypeOf(d.entity));

    // Counter-factual measured: appending one field leaves every assert above passing and
    // fails HERE, which is the only reason this line is not decoration.
    try testing.expectEqual(@as(usize, 13), @typeInfo(CharacterDescriptor).@"struct".fields.len);

    // Four absences, each argued in the spec and each pinned so that a later milestone
    // re-adding one has to delete the argument first rather than quietly outvote it:
    // rotation (§1.12.3 — the capsule is symmetric about the engine's Y up),
    // `inner_body_shape` (§1.12.2 — two shapes that can diverge), and `max_speed` /
    // `friction` (§9 — kinematics and a solver coefficient a virtual controller never
    // reaches).
    try testing.expect(!@hasField(CharacterDescriptor, "rotation"));
    try testing.expect(!@hasField(CharacterDescriptor, "inner_body_shape"));
    try testing.expect(!@hasField(CharacterDescriptor, "max_speed"));
    try testing.expect(!@hasField(CharacterDescriptor, "friction"));

    // The public surface is f32 (§1.11.8, §1.12.11) — pinned, because widening it is ONE
    // decision over `BodyDescriptor`, the interface pose, the query results and the ECS
    // `Transform` together, at M1.1.15, and never over one member of that set alone.
    try testing.expectEqual(f32, @TypeOf(d.radius));
    try testing.expectEqual(f32, @TypeOf(d.height));
    try testing.expectEqual(f32, @TypeOf(d.max_slope));
    try testing.expectEqual(f32, @TypeOf(d.padding));
    try testing.expectEqual(math.Vec3, @TypeOf(d.position));

    // `collision_layer` is bounded by the SAME constant `addBody` reads, not by a second
    // copy of 32 (§1.12.4): the mask is 32 bits, and a character declared past it would be
    // invisible to every query with no diagnostic.
    try testing.expect(d.collision_layer < collision_layer_count);
    try testing.expectEqual(@as(u8, 32), collision_layer_count);
}

test "CharacterMoveResult mirrors engine-tier-interfaces.md §1 field for field" {
    const r = CharacterMoveResult{ .position = Vec3.zero, .ground_entity = EntityId.dead };

    // The verdict, and its default is the safe failure direction in every state (§1.12.5).
    try testing.expectEqual(GroundState.in_air, r.ground_state);

    // The direction, and the ONE `ground_*` field that holds a meaningful value even on
    // `.in_air`. Asserted EXACTLY unit rather than approximately: three documents read it
    // inside a `@replicated` component and a NaN would cross the rollback, so `lengthSq`
    // being exactly 1 is the strongest available statement that it is never poisoned —
    // `Vec3.unit_y` is `engine-coordinate-system.md`'s `Vec3.up` under Y-up, the same
    // value `(0, 1, 0)`.
    try testing.expect(r.ground_normal.eql(Vec3.unit_y));
    try testing.expectEqual(@as(f32, 1), r.ground_normal.lengthSq());

    // The support handle's default is the SENTINEL, asserted in BOTH directions: equal to
    // `PackedId.dead`, and DIFFERENT FROM 0. The second half is the one that catches a
    // regression to the old default, which was `0` — a valid handle to slot 0 generation 0,
    // hence a field with no bit configuration meaning absence, readable only in company of
    // `ground_state` and silently so across the C ABI. `engine-c-api.md` carries no
    // `struct_size` and no minor version, so after the M1.1.15 freeze that default would
    // have been frozen into the ABI.
    try testing.expectEqual(@as(BodyId, PackedId.dead), r.ground_body);
    try testing.expect(r.ground_body != 0);
    try testing.expect(r.ground_velocity.eql(Vec3.zero));

    // `position` and `ground_entity` carry no default — transcribed as frozen.
    try testing.expectEqual(math.Vec3, @TypeOf(r.position));
    try testing.expectEqual(EntityId, @TypeOf(r.ground_entity));

    // Counter-factual measured, same shape as the descriptor's.
    try testing.expectEqual(@as(usize, 6), @typeInfo(CharacterMoveResult).@"struct".fields.len);

    // `collisions: u8` is DELETED and its absence is pinned: an aggregated counter with no
    // named consumer in the corpus, saturating at 255. `CharacterMoveResult2D` still
    // carries it, and that asymmetry is consigned for M1.8.11 rather than resolved from a
    // 3D milestone.
    try testing.expect(!@hasField(CharacterMoveResult, "collisions"));

    // f32 boundary, same single decision as the descriptor above.
    try testing.expectEqual(math.Vec3, @TypeOf(r.ground_normal));
    try testing.expectEqual(math.Vec3, @TypeOf(r.ground_velocity));
}
