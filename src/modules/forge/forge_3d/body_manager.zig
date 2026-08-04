//! `forge_3d/body_manager.zig` — the SoA rigid-body store.
//!
//! Bodies live in a `std.MultiArrayList` (SoA) keyed by a generational
//! `IdAllocator` (LIFO free-list, generation bump on remove; identical
//! mechanism to `ShapeStore`). Each element is 16 bytes at the default
//! `Real = f32` (32 bytes at `f64`) — `Vec3r` position (16-aligned) and `Quatr`
//! rotation (4×f32, matching the element layout of
//! `core.ecs.components.Transform.rot`) — so element-wise copy to/from the ECS
//! `Transform` is layout-clean (Notes decision 7). Caveat: `Quatr` is align-4
//! (the E1-frozen `Quat` storage), so the rotation column matches
//! `Transform.rot`'s 16-byte stride but not its 16-byte alignment; see the
//! Execution-log note flagging this against decision 7. Id allocation is
//! deterministic (no hash-map on the path — M1.1.14). World AABBs are computed
//! exactly per primitive on demand.
//!
//! Velocity/force/torque mutators (`setLinearVelocity`/`setAngularVelocity`,
//! `addForce`/`addTorque`/`addImpulse`) and their getters validate the handle
//! and no-op / return null on a stale one (parity with `position`/`rotation`).
//! `addForce`/`addTorque` accumulate into the per-tick `force`/`torque` columns
//! (cleared by `integrate`); `addImpulse` is an immediate `Δv = impulse·inv_mass`
//! (a natural no-op on static/kinematic bodies, `inv_mass == 0`). The pose
//! mutators `setPosition`/`setRotation` (M1.1.7, written by the NGS position
//! solver) validate the handle the same way. `addTorque`, `setAngularVelocity`,
//! `setPosition` and `setRotation` are INTERNAL — the public `PhysicsModule` 3D
//! interface (frozen M1.1.15) carries no angular and no pose mutators.
//!
//! Those mutators split into two INTENTS, and the split is a contract, not an
//! implementation detail (`engine-physics-forge.md` §1.8.4). The four setters
//! (`setLinearVelocity`, `setAngularVelocity`, `setPosition`, `setRotation`) are the
//! SOLVER's own write path and are NON-ACTIVATING: they neither wake a body nor
//! restart its sleep window. Both solver passes write velocities and poses on every
//! contacting body every tick, so were those writes counted as external mutations,
//! nothing in contact would ever sleep. `addForce`, `addTorque` and `addImpulse`
//! come from outside the simulation and are ACTIVATING: they wake and restart the
//! window, even on an already-awake body. `wakeBody` and `setCanSleep` are the two
//! explicit primitives. Composing a wake with a write for the gameplay-facing
//! setters is the interface boundary's job at M1.1.15 — the Jolt split between
//! `Body::SetLinearVelocity` and `BodyInterface::SetLinearVelocity`.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const shape_mod = @import("shape.zig");
const body_mod = @import("body.zig");
const narrowphase = @import("pipeline/narrowphase/root.zig");
// M1.1.9 — only for the `Ray` type `raycastBody` takes; the broadphase itself is
// the caller's, not this store's.
const broadphase_mod = @import("pipeline/broadphase.zig");
const IdAllocator = @import("slot_alloc.zig").IdAllocator;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const Aabbr = config.Aabbr;
const BodyId = api.BodyId;
const BodyDescriptor = api.BodyDescriptor;
const EntityId = api.EntityId;
/// Generational store of collision shapes. Re-exported so sibling packages (the
/// `rigid/` solver) can name the `collidePair` store parameter type without
/// importing `shape.zig` directly (import-discipline boundary).
pub const ShapeStore = shape_mod.ShapeStore;
const Shape = shape_mod.Shape;
/// The owned triangle-mesh payload, for the mesh arms below (M1.1.11.1).
const MeshData = @import("mesh.zig").MeshData;
const Body = body_mod.Body;
const MotionProperties = body_mod.MotionProperties;
const GjkResult = narrowphase.GjkResult(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const RayR = broadphase_mod.Ray(Real);

const ApiVec3 = @import("foundation").math.Vec3;
const ApiQuat = @import("foundation").math.Quatf;

/// A shape cast against ONE body, in WORLD space (`castShapeBody`). Distinct from
/// the kernel's `CastHit`, whose fields are in the cast shape's frame: the frames
/// differ, so the types do too rather than one being quietly reinterpreted.
pub const BodyCastHit = struct {
    /// Distance along the cast direction at first touch, in `[0, max_distance]`.
    distance: Real,
    /// Which SUB-SHAPE of the hit body was touched — a mesh's triangle index, and `0` for a
    /// shape with no sub-shape, which consumes zero bits of the path (§1.11.16).
    subshape_id: u32 = 0,
    /// World-space witness on the HIT BODY's inflated surface.
    position: Vec3r,
    /// World-space outward unit normal of the hit body; `normal · direction <= 0`.
    normal: Vec3r,
};

/// The closest point on ONE body to a queried point, in WORLD space
/// (`closestPointBody`). `distance` is to the SOLID, so it is 0 for an interior
/// point — boundary included — and the position is then the queried point itself
/// (`engine-physics-forge.md` §1.11.13).
pub const BodyClosestPoint = struct {
    /// Distance from the queried point to the body's solid; 0 inside it.
    distance: Real,
    /// Which SUB-SHAPE carries the closest point — a mesh's triangle index, `0` otherwise
    /// (§1.11.16).
    subshape_id: u32 = 0,
    /// World-space point on the body's surface, or the queried point when inside.
    position: Vec3r,
};

/// Slack allowed on the descriptor rotation's unit norm, in ULPs of 1 at `f32` —
/// the precision the descriptor is expressed in. A quaternion built by
/// `fromAxisAngle` from f32 trigonometry lands a few ULPs off unit; anything
/// further out is a caller error, not rounding.
const descriptor_rotation_unit_k: comptime_int = 16;

/// SoA store of rigid bodies with generational, deterministic handles.
pub const BodyManager = struct {
    alloc: IdAllocator = .{},
    bodies: std.MultiArrayList(Body) = .empty,

    /// Release all storage.
    pub fn deinit(self: *BodyManager, gpa: std.mem.Allocator) void {
        self.alloc.deinit(gpa);
        self.bodies.deinit(gpa);
        self.* = undefined;
    }

    /// Number of live bodies.
    pub fn count(self: *const BodyManager) u32 {
        return self.alloc.live_count;
    }

    /// Create a body from `desc`, resolving its shape in `store` for the
    /// inertia. Returns the new handle. Velocity starts at zero.
    ///
    /// Three typed failures, in the order they are tested: `error.InvalidShape` on a
    /// stale/invalid `desc.shape`; `error.ShapeMustBeStatic` when the shape is
    /// static-only — a half-space (§1.11.15) or a mesh (§1.11.17) — and
    /// `desc.body_type` is not `.static`; and `error.InvalidCollisionLayer` outside
    /// `[0, collision_layer_count)` (§1.11.5). On any of them nothing is mutated and no
    /// handle is allocated.
    pub fn addBody(self: *BodyManager, gpa: std.mem.Allocator, store: *const ShapeStore, desc: BodyDescriptor) !BodyId {
        const shape = store.get(desc.shape) orelse return error.InvalidShape;
        // TWO CATEGORIES FORCE A STATIC BODY, and the refusal is a TYPED error. It is a
        // DISPATCH on the class and not an `if` on one variant of it (M1.1.11.1): the
        // question "may this shape move" has an answer for every category, so a fourth
        // one is a compile error here and must give it.
        //
        // The two static-only categories say NO for DIFFERENT reasons, and neither is
        // the other's. A half-space has no finite volume, no inertia tensor and no local
        // AABB, so mass, inertia and sleep radius are all undefined on it (§1.11.15). A
        // mesh HAS a valid local AABB, hence a defined sleep radius; what it lacks is a
        // VOLUME — an open surface encloses nothing — so no inertia derives from it and
        // no mass can be deduced (§1.11.17). The reference says exactly that of its own
        // mesh and draws the opposite conclusion, letting the caller supply a mass; Weld
        // refuses instead of asking.
        //
        // **The ORDER is normative, not stylistic.** It sits immediately after the
        // shape resolution — which it depends on — and BEFORE every computation
        // derived from the local AABB or the inertia: both `computeMotion` (on its
        // dynamic path) and the sleep radius live in the `Body` literal below, with no
        // branch on body type of their own. Moved after that literal, a dynamic
        // half-space or mesh would reach `computeMotion`'s class dispatch in a safe
        // build and, in ReleaseFast where that dispatch compiles out, would silently
        // store a NaN inverse inertia.
        //
        // The error is named for the INVARIANT rather than for the shape, at M1.1.11 and
        // precisely so that M1.1.11.1 could reuse it instead of minting a second one.
        const must_be_static = switch (shape.class()) {
            .convex => false,
            .half_space, .triangle_soup => true,
        };
        if (must_be_static and desc.body_type != .static) {
            return error.ShapeMustBeStatic;
        }
        // A TYPED error, not a debug assert: the query mask is 32 bits, so a body
        // beyond that domain would be invisible to every query with no diagnostic
        // at all — the silent-miss class the shape invariant forbids
        // (`engine-physics-forge.md` §1.11.5). Distinct from the deferred
        // descriptor-validation policy for degenerate mass and geometry, which
        // stays a debug assert below.
        if (desc.collision_layer >= api.collision_layer_count) return error.InvalidCollisionLayer;
        // Material domain guards (debug-only; the M1.1.0 `mass > 0` precedent).
        // Friction is a non-negative Coulomb coefficient; restitution is a [0, 1]
        // ratio. Both must be finite. Typed-error descriptor validation is a later
        // milestone; this guards the otherwise-unchecked material path.
        std.debug.assert(std.math.isFinite(desc.friction) and desc.friction >= 0);
        std.debug.assert(std.math.isFinite(desc.restitution) and desc.restitution >= 0 and desc.restitution <= 1);
        // The descriptor rotation must already be a unit quaternion, to `f32`
        // tolerance — it IS `f32`. Without this guard the normalisation below
        // would silently repair ANY input, turning a zero quaternion into NaN;
        // with it, the normalisation is total in what it does: it corrects the
        // widening, it does not rescue an invalid input.
        {
            const q = desc.rotation.toArray();
            const norm_sq = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
            std.debug.assert(@abs(norm_sq - 1) <= descriptor_rotation_unit_k * std.math.floatEps(f32));
        }
        // Normalised ONCE, here, and shared by both rotation fields below (see
        // `Body.rotation` for the invariant this establishes). Deliberately NOT
        // folded into `convQuat`: that name says "convert", and hiding a semantic
        // operation behind it would make the invariant invisible at the call site.
        const rotation_r = convQuat(desc.rotation).normalize();
        const body = Body{
            .position = convVec3(desc.position),
            .rotation = rotation_r,
            .linear_velocity = Vec3r.zero,
            .angular_velocity = Vec3r.zero,
            .force = Vec3r.zero,
            .torque = Vec3r.zero,
            .motion = body_mod.computeMotion(desc, shape),
            .friction = desc.friction,
            .restitution = desc.restitution,
            .shape = desc.shape,
            .body_type = desc.body_type,
            .collision_layer = desc.collision_layer,
            .flags = .{ .continuous = desc.continuous, .can_sleep = desc.can_sleep },
            // The sleep window opens at the creation pose, closed (`sleep_time`
            // zero) — a fresh body has not yet stood still for any length of time.
            .sleep_time = 0,
            .sleep_ref_position = convVec3(desc.position),
            // The SAME normalised value as `.rotation`, not a second conversion.
            // Were the reference left un-normalised, the first window sweep would
            // read `Δq = q ⊗ conj(q_ref)` as a near-identity offset by the
            // widening error and report a phantom displacement — tiny against the
            // 15 mm bound, and wrong regardless.
            .sleep_ref_rotation = rotation_r,
            // A switch on the CLASS, exhaustive and with no `else` arm.
            //
            // A half-space has no local AABB, hence no sleep radius — and needs none:
            // it can only be STATIC (rejected above otherwise), and nothing ever reads
            // a static body's radius, both `sleep.updateWindows` and the island seeding
            // skipping a non-dynamic body before they touch it. NaN rather than a
            // plausible zero, for the reason the two shape fields it derives from carry
            // NaN: the class dispatches guarding them compile out of ReleaseFast, and a
            // finite placeholder there would pass unnoticed.
            //
            // A MESH takes the same arm as a convex, and that is the whole point of the
            // two being distinguished: it is bounded, so its local AABB is valid and the
            // radius is DEFINED. It is equally never read — a mesh forces a static body
            // too — but a defined quantity is answered rather than poisoned, poisoning
            // being what one does when there is no answer.
            .sleep_radius = switch (shape.class()) {
                .convex, .triangle_soup => body_mod.computeSleepRadius(shape),
                .half_space => std.math.nan(Real),
            },
            .entity = desc.entity,
            // Filled ONLY for a mesh, whose pose is frozen by `error.ShapeMustBeStatic` and
            // whose world box is an O(V) pass the query path would otherwise repeat per
            // candidate (see `Body.world_aabb` for the measurement). NaN elsewhere, so a
            // wrong read is loud rather than plausible. Exhaustive on the class, no `else`.
            .world_aabb = switch (shape.class()) {
                .triangle_soup => worldAabb(shape, convVec3(desc.position), rotation_r),
                .convex, .half_space => Aabbr.fromMinMax(
                    Vec3r.splat(std.math.nan(Real)),
                    Vec3r.splat(std.math.nan(Real)),
                ),
            },
        };
        try self.alloc.ensureUnusedCapacity(gpa, 1);
        try self.bodies.ensureUnusedCapacity(gpa, 1);
        const a = self.alloc.allocateAssumeCapacity();
        if (a.is_new) {
            self.bodies.appendAssumeCapacity(body);
        } else {
            self.bodies.set(a.index, body);
        }
        return a.id;
    }

    /// Remove a body. No-op on a stale/invalid handle. Bumps the slot
    /// generation so the freed index can be reused with a fresh handle.
    pub fn removeBody(self: *BodyManager, id: BodyId) void {
        _ = self.alloc.free(id);
    }

    /// Whether `id` refers to a live body.
    pub fn isValid(self: *const BodyManager, id: BodyId) bool {
        return self.alloc.validate(id) != null;
    }

    /// Safe getter: world-space position, or null if `id` is stale/invalid.
    pub fn position(self: *const BodyManager, id: BodyId) ?Vec3r {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.position)[idx];
    }

    /// Safe getter: world-space orientation, or null if `id` is stale/invalid
    /// (symmetric to `position`).
    pub fn rotation(self: *const BodyManager, id: BodyId) ?Quatr {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.rotation)[idx];
    }

    /// Safe getter: derived motion properties, or null if `id` is stale/invalid.
    pub fn motionProperties(self: *const BodyManager, id: BodyId) ?MotionProperties {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.motion)[idx];
    }

    /// Safe getter: the Coulomb friction coefficient, or null if `id` is
    /// stale/invalid. Consumed by the Sequential Impulses contact solver (M1.1.6).
    pub fn friction(self: *const BodyManager, id: BodyId) ?Real {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.friction)[idx];
    }

    /// Safe getter: the restitution / bounciness, or null if `id` is
    /// stale/invalid. Consumed by the Sequential Impulses contact solver (M1.1.6).
    pub fn restitution(self: *const BodyManager, id: BodyId) ?Real {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.restitution)[idx];
    }

    /// Safe getter: the body's object collision-layer index, or null if `id` is
    /// stale/invalid.
    pub fn collisionLayer(self: *const BodyManager, id: BodyId) ?u8 {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.collision_layer)[idx];
    }

    /// Safe getter: the body's simulation class, or null if `id` is stale/invalid.
    ///
    /// The column has existed since M1.1.0 and was never exposed. What needs it is
    /// M1.1.12: §1.12.2 states normatively that a character's presence is a KINEMATIC body,
    /// and `motionProperties` cannot answer that — a static and a kinematic body both carry
    /// an inverse mass of exactly zero. A normative property nothing can assert is one that
    /// regresses silently, which is the same argument that exposed `entity` at M1.1.10.
    pub fn bodyType(self: *const BodyManager, id: BodyId) ?api.BodyType {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.body_type)[idx];
    }

    /// Safe getter: the handle of the shape this body carries, or null if `id` is
    /// stale/invalid.
    ///
    /// Named `shapeOf` and not `shape` because it returns a `ShapeId` and not a `Shape`, and
    /// the two live one `store.get` apart. Exposed for the same reason as `bodyType` above:
    /// §1.12.2 states that a character's presence carries the CONTROLLER'S OWN capsule and
    /// never a second shape, and handle equality is the direct form of that statement.
    pub fn shapeOf(self: *const BodyManager, id: BodyId) ?api.ShapeId {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.shape)[idx];
    }

    /// Replace the shape a body carries, KEEPING its `BodyId`. Stale-safe no-op.
    ///
    /// **Restricted to a NON-DYNAMIC body, asserted.** `computeMotion` returns an inverse mass and
    /// an inverse inertia of exactly zero for anything but `.dynamic`, INDEPENDENT of the shape, so
    /// a swap leaves `motion` correct with nothing to recompute. On a dynamic body the same swap
    /// would silently keep an inertia tensor belonging to the old geometry, so that case is refused
    /// rather than half-handled.
    ///
    /// Added at M1.1.12 for `resizeCharacter`, which MUST keep the presence's handle (§1.12.2) — a
    /// resize is not a re-creation, and an exclusion the caller memorised survives it.
    /// Destroy-and-add is the only alternative and it changes the `BodyId`.
    ///
    /// NON-ACTIVATING, like the other write paths of §1.8.4: the wake the caller owes is composed by
    /// the caller from what the new volume touches.
    pub fn setShape(self: *BodyManager, store: *const ShapeStore, id: BodyId, shape_id: api.ShapeId) void {
        const idx = self.alloc.validate(id) orelse return;
        std.debug.assert(self.bodies.items(.body_type)[idx] != .dynamic);
        const shape = store.get(shape_id) orelse return;
        self.bodies.items(.shape)[idx] = shape_id;
        // The sleep radius is geometry-derived, so it is recomputed even though a non-dynamic body's
        // is never read — a stale derived value is worse than a redundant assignment.
        self.bodies.items(.sleep_radius)[idx] = body_mod.computeSleepRadius(shape);
    }

    /// Safe getter: the ECS entity owning this body, or null if `id` is
    /// stale/invalid.
    ///
    /// The column has existed since M1.1.0 and was never exposed, because nothing
    /// needed it: the solver's identity is the BODY. What needs it is the query
    /// ORDER (`engine-physics-forge.md` §1.11.14). `BodyId` is a slot index, so it
    /// encodes creation order and cannot rank a result without making the answer a
    /// function of the order the scene was built in; the owning entity is the only
    /// identity that survives a permutation of that order, so it is the key, and
    /// `BodyId` is only the final tie-break.
    ///
    /// Nothing here forces one body per entity, which is exactly why that final
    /// tie-break exists (the residual §1.11.14 names).
    pub fn entity(self: *const BodyManager, id: BodyId) ?EntityId {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.entity)[idx];
    }

    /// Safe getter: whether the body is currently asleep, or null if `id` is
    /// stale/invalid.
    pub fn isSleeping(self: *const BodyManager, id: BodyId) ?bool {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.flags)[idx].sleeping;
    }

    /// Safe getter: seconds accumulated in the body's current sleep window, or null
    /// if `id` is stale/invalid. Eligibility compares it against
    /// `SleepConfig.time_before_sleep`; it also feeds the Sleep-state debug overlay
    /// (`engine-physics-forge.md` §1.8.9).
    pub fn sleepTime(self: *const BodyManager, id: BodyId) ?Real {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.sleep_time)[idx];
    }

    /// Safe getter: whether the body is allowed to fall asleep, or null if `id` is
    /// stale/invalid.
    pub fn canSleep(self: *const BodyManager, id: BodyId) ?bool {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.flags)[idx].can_sleep;
    }

    /// Safe getter: the body's sleep radius (distance from its centre to the
    /// furthest corner of its shape's local AABB), or null if `id` is
    /// stale/invalid. Pose-invariant, computed once at creation. NaN for a body
    /// carrying a half-space, which has no local AABB and no sleep window — see
    /// `Body.sleep_radius`.
    pub fn sleepRadius(self: *const BodyManager, id: BodyId) ?Real {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.sleep_radius)[idx];
    }

    /// Wake the body and restart its sleep window at the current pose. Idempotent
    /// on an already-awake body (the window still restarts — an external
    /// solicitation is a solicitation either way, §1.8.4). No-op on a
    /// stale/invalid handle.
    ///
    /// This is one of the two EXPLICIT sleep primitives (`setCanSleep` is the
    /// other): every other wake in the engine either calls it or is one of the
    /// activating mutators below.
    pub fn wakeBody(self: *BodyManager, id: BodyId) void {
        const idx = self.alloc.validate(id) orelse return;
        self.wakeIndex(idx);
    }

    /// Allow or forbid this body falling asleep. Forbidding it also WAKES it
    /// (`engine-physics-forge.md` §1.8.5, wake cause W1): a body that may no longer
    /// sleep must not stay asleep. Allowing it does not put it to sleep — that is
    /// the island arbitration's decision, and only at step 11 of the cycle. No-op
    /// on a stale/invalid handle.
    pub fn setCanSleep(self: *BodyManager, id: BodyId, value: bool) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.flags)[idx].can_sleep = value;
        if (!value) self.wakeIndex(idx);
    }

    /// Clear the sleeping flag and restart the sleep window at the current pose.
    /// The index form both explicit primitives and the activating mutators share.
    fn wakeIndex(self: *BodyManager, idx: u24) void {
        self.bodies.items(.flags)[idx].sleeping = false;
        self.bodies.items(.sleep_time)[idx] = 0;
        self.bodies.items(.sleep_ref_position)[idx] = self.bodies.items(.position)[idx];
        self.bodies.items(.sleep_ref_rotation)[idx] = self.bodies.items(.rotation)[idx];
    }

    /// Safe getter: world-space linear velocity, or null if `id` is stale/invalid.
    pub fn linearVelocity(self: *const BodyManager, id: BodyId) ?Vec3r {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.linear_velocity)[idx];
    }

    /// Safe getter: world-space angular velocity, or null if `id` is stale/invalid.
    pub fn angularVelocity(self: *const BodyManager, id: BodyId) ?Vec3r {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.angular_velocity)[idx];
    }

    /// Set the world-space linear velocity. No-op on a stale/invalid handle.
    ///
    /// NON-ACTIVATING BY CONTRACT (`engine-physics-forge.md` §1.8.4): it neither
    /// wakes the body nor restarts its sleep window. This is the SOLVER's own write
    /// path — both passes write velocities and poses on every body in contact,
    /// every tick, so treating those writes as external mutations would mean no
    /// body in contact ever sleeps. Composing the wake with the write for the
    /// gameplay-facing setters is the interface boundary's job
    /// (`PhysicsModule`/`PhysicsWorld`, frozen M1.1.15) — exactly Jolt's
    /// `Body::SetLinearVelocity` (inert) versus `BodyInterface::SetLinearVelocity`
    /// (activating).
    pub fn setLinearVelocity(self: *BodyManager, id: BodyId, velocity: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.linear_velocity)[idx] = velocity;
    }

    /// Set the world-space angular velocity. No-op on a stale/invalid handle.
    /// Internal to `BodyManager`: the public `PhysicsModule` 3D interface has no
    /// angular-velocity mutator (frozen decision at M1.1.15).
    ///
    /// NON-ACTIVATING BY CONTRACT — see `setLinearVelocity`.
    pub fn setAngularVelocity(self: *BodyManager, id: BodyId, velocity: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.angular_velocity)[idx] = velocity;
    }

    /// Set the world-space position. No-op on a stale/invalid handle. INTERNAL to
    /// `forge_3d` (like `addTorque`/`setAngularVelocity`): the day-1
    /// `PhysicsModule` 3D surface carries no pose mutator — flagged for the M1.1.15
    /// freeze review. The NGS position solver (M1.1.7) writes its corrected poses
    /// through it.
    ///
    /// NON-ACTIVATING BY CONTRACT — see `setLinearVelocity`. Teleporting a body
    /// from gameplay is `wakeBody` composed with this call, never this call alone.
    pub fn setPosition(self: *BodyManager, id: BodyId, new_position: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.position)[idx] = new_position;
        self.poisonCachedBox(idx);
    }

    /// Set the world-space orientation (mirror of `setPosition`; the caller owns
    /// normalization). No-op on a stale/invalid handle. INTERNAL — see
    /// `setPosition`.
    ///
    /// NON-ACTIVATING BY CONTRACT — see `setLinearVelocity`.
    pub fn setRotation(self: *BodyManager, id: BodyId, new_rotation: Quatr) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.rotation)[idx] = new_rotation;
        self.poisonCachedBox(idx);
    }

    /// Invalidate the cached world box of a NON-DYNAMIC body whose pose has just been
    /// written — see `Body.world_aabb`.
    ///
    /// Gated on the body type so the hot path pays nothing that matters: the two pose
    /// setters are called every tick by the NGS pass, and always on DYNAMIC bodies, whose
    /// cache is NaN already and is left untouched. A non-dynamic body reaching here means an
    /// external teleport, which is the one thing that can stale the cache; poisoning it makes
    /// the mesh arm fall back to the O(V) pass, which is correct and merely slower.
    fn poisonCachedBox(self: *BodyManager, idx: u24) void {
        if (self.bodies.items(.body_type)[idx] == .dynamic) return;
        self.bodies.items(.world_aabb)[idx] = Aabbr.fromMinMax(
            Vec3r.splat(std.math.nan(Real)),
            Vec3r.splat(std.math.nan(Real)),
        );
    }

    /// Accumulate a world-space force (N) into the body's per-tick force
    /// accumulator. No-op on a stale/invalid handle. Any live body accumulates
    /// (the per-tick clear in `integrate` is uniform); a force must be
    /// re-applied every tick it should act.
    ///
    /// ACTIVATING (`engine-physics-forge.md` §1.8.4, wake cause W1): an externally
    /// applied force is a solicitation, so it wakes the body and restarts its sleep
    /// window — even if the body was already awake. This is the intent boundary the
    /// non-activating setters above sit on the other side of.
    pub fn addForce(self: *BodyManager, id: BodyId, force: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        const forces = self.bodies.items(.force);
        forces[idx] = forces[idx].add(force);
        self.wakeIndex(idx);
    }

    /// Accumulate a world-space torque (N·m) into the body's per-tick torque
    /// accumulator. No-op on a stale/invalid handle. Internal to `BodyManager`
    /// (the interface has no torque mutator — see `setAngularVelocity`).
    ///
    /// ACTIVATING — see `addForce`.
    pub fn addTorque(self: *BodyManager, id: BodyId, torque: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        const torques = self.bodies.items(.torque);
        torques[idx] = torques[idx].add(torque);
        self.wakeIndex(idx);
    }

    /// Apply an instantaneous linear impulse (N·s) as an IMMEDIATE velocity
    /// change `Δv = impulse · inv_mass`. No-op on a stale/invalid handle, and
    /// naturally a no-op on a static/kinematic body (`inv_mass == 0`) — no
    /// `body_type` branch needed.
    ///
    /// ACTIVATING — see `addForce`. Note the asymmetry with `setLinearVelocity`,
    /// which writes the same column and does NOT wake: the difference is the
    /// INTENT, not the field touched. An impulse comes from outside the simulation;
    /// a solver velocity write is the simulation itself.
    pub fn addImpulse(self: *BodyManager, id: BodyId, impulse: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        const inv_mass = self.bodies.items(.motion)[idx].inv_mass;
        const vel = self.bodies.items(.linear_velocity);
        vel[idx] = vel[idx].add(impulse.scale(inv_mass));
        self.wakeIndex(idx);
    }

    /// Safe getter: the exact world-space AABB of the body's shape, or null if
    /// `id` (or its shape) is stale/invalid.
    pub fn bodyAabb(self: *const BodyManager, store: *const ShapeStore, id: BodyId) ?Aabbr {
        const idx = self.alloc.validate(id) orelse return null;
        const pos = self.bodies.items(.position)[idx];
        const rot = self.bodies.items(.rotation)[idx];
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        // The same precondition `worldAabb` carries, re-stated at the BODY grain — this
        // is where a caller holds a `BodyId` and can be told which body it asked about.
        // A DISPATCH on the class and not an assert on one variant of it (M1.1.11.1):
        // both bounded categories have a box, and a body carrying a half-space is asked
        // a PREDICATE ("do you overlap this box") instead, never a box (§1.11.15).
        switch (shape.class()) {
            .convex, .triangle_soup => {},
            .half_space => unreachable,
        }
        return worldAabb(shape, pos, rot);
    }

    /// Ray against one body's shape, resolving its world pose and support shape
    /// (via `store`). Returns null if the handle — or its shape — is
    /// stale/invalid, or if the ray misses. The `BodyId`-level ray
    /// adapter for the broadphase→kernel flow, mirroring `gjkPair` /
    /// `collidePair`: unpack a `queryRay` candidate's `user_data` as a `BodyId`
    /// and call this per candidate.
    ///
    /// **No error channel since M1.1.11.** It carried `error.UnsupportedShape` from
    /// the kernel's rounded-box latch, and no path could reach it: `supportShape`
    /// gives every stored box `radius = 0`, so a `SupportShape` built from a body is
    /// never a rounded box. The kernel's refusal is an asserted precondition now
    /// (`narrowphase.raySupportsShape`) and the typed refusal lives at the two query
    /// entries taking a caller-supplied shape handle (§1.11.7). What this adapter
    /// resolves is a BODY's shape, which the store validated at creation, so there is
    /// nothing here for a caller to get wrong.
    ///
    /// The hit comes back in the shape's LOCAL frame, which is enough: a rigid
    /// transform preserves distances and the direction is unit on both sides, so
    /// `distance` is already the world distance and only the normal needs
    /// rotating — which the caller does, having its own reason to hold the pose.
    ///
    /// The local direction is NOT re-normalised after the inverse rotation. A
    /// quaternion conjugate rotation preserves the norm to within a few ULPs,
    /// which is exactly what the kernel's unit-direction assert budgets; a
    /// re-normalisation would cost a square root per body AND mask a genuine
    /// drift, so if that assert ever fires it is a signal, not a threshold to
    /// widen.
    pub fn raycastBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        ray: RayR,
        back_face_mode: api.BackFaceMode,
    ) ?narrowphase.LocalHit(Real) {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        const inv_rot = self.bodies.items(.rotation)[idx].conjugate();
        const local_origin = inv_rot.rotateVec3(ray.origin.sub(self.bodies.items(.position)[idx]));
        const local_direction = inv_rot.rotateVec3(ray.direction);
        // Dispatch by CATEGORY, above the support map and never inside it (§1.11.15).
        // Exhaustive with no `else`.
        // The half-space arm needs no transport of its own — the plane is stored in
        // this body's local frame, which is the frame the ray has just been brought
        // into, and all three kernels return the SAME `LocalHit` so this adapter has one
        // return type rather than a union of three.
        return switch (shape.class()) {
            .convex => narrowphase.rayShape(Real, shape_mod.supportShape(shape), local_origin, local_direction),
            .half_space => narrowphase.plane.rayShape(Real, shape_mod.halfSpace(shape), local_origin, local_direction),
            // ONE HIT PER BODY, decided HERE, which is where the body's identity lives —
            // so the three collectors above are untouched by the mesh and receive one hit
            // per candidate as they always have (§1.11.17). It is not an optimisation: the
            // §1.11.14 ordering key `(distance, entity, BodyId)` does not discriminate two
            // triangles of one body, so two hits would be neither ordered nor invariant
            // and their truncation would be arbitrary.
            //
            // The traversal's bound starts at infinity and tightens to the best accepted
            // hit, so branch and bound prunes WITHIN the body too; the kernel-level
            // contract is unchanged — no `max_distance` here, the caller intersects with
            // its own window, exactly as for a convex.
            .triangle_soup => blk: {
                var collector = MeshRayCollector{
                    .data = shape.mesh.?,
                    .origin = local_origin,
                    .direction = local_direction,
                    .back_face_mode = back_face_mode,
                };
                _ = collector.data.traverseRay(RayR.init(local_origin, local_direction), &collector);
                break :blk collector.best;
            },
        };
    }

    /// Run distance-based GJK on the pair `a`/`b`, resolving each body's world
    /// pose and support shape (via `store`). Returns null if either handle — or
    /// its shape — is stale/invalid. This is the `BodyId`-level narrowphase
    /// adapter for the broadphase→narrowphase flow: unpack a `computePairs`
    /// candidate's `user_data` as a `BodyId` and call this per pair.
    pub fn gjkPair(self: *const BodyManager, store: *const ShapeStore, a: BodyId, b: BodyId) ?GjkResult {
        const ia = self.alloc.validate(a) orelse return null;
        const ib = self.alloc.validate(b) orelse return null;
        const shape_a = store.get(self.bodies.items(.shape)[ia]) orelse return null;
        const shape_b = store.get(self.bodies.items(.shape)[ib]) orelse return null;
        // **PRECONDITION, ASSERTED AT THIS SITE: both bodies carry BOUNDED CONVEXES.** It was
        // inherited in silence from `supportShape` three levels down, which meant a half-space or
        // a mesh reaching here panicked in a safe build and was UNDEFINED BEHAVIOUR in ReleaseFast
        // — the FIFTH hole in the `ShapeClass` net, of the same class as the four closed at the
        // start of M1.1.11.1, and open for a half-space since M1.1.11.
        //
        // A precondition and not an error channel, because neither refused shape has an answer to
        // give: a mesh has no single GJK result — one per contacting triangle, which is what
        // `collidePairEach` is for — and a half-space has no bounded support map at all. Same form
        // as `supportShape`'s own, now stated where a caller can read it against the handles it
        // holds.
        std.debug.assert(shape_a.class() == .convex);
        std.debug.assert(shape_b.class() == .convex);
        return narrowphase.gjk(
            Real,
            shape_mod.supportShape(shape_a),
            self.bodies.items(.position)[ia],
            self.bodies.items(.rotation)[ia],
            shape_mod.supportShape(shape_b),
            self.bodies.items(.position)[ib],
            self.bodies.items(.rotation)[ib],
        );
    }

    /// Cast `cast_shape`, posed at (`cast_origin`, `cast_rotation`), along
    /// `direction` against body `id`. Returns the first touch within
    /// `[0, max_distance]` (a CLOSED interval), or null on a miss — and null on a
    /// stale/invalid handle OR a stale/invalid shape, which are two distinct ways to
    /// be gone and are both checked. The `BodyId`-level cast adapter for the
    /// broadphase→kernel flow, mirroring `raycastBody` / `gjkPair` / `collidePair`:
    /// unpack a `queryCast` candidate's `user_data` as a `BodyId` and call this per
    /// candidate.
    ///
    /// **The core + inflation-radius convention is honoured HERE**, at the one place
    /// a second convention could slip in unseen: the body's `Shape` becomes a
    /// `SupportShape` through `shape_mod.supportShape` — core plus radius, the same
    /// translation `gjkPair`, `collidePair` and `raycastBody` all use — and nothing
    /// on this path adds a margin of its own. `cast_shape` arrives already in that
    /// form because the CALLER owns it; it is not a body.
    ///
    /// **Frames.** The kernel works in the cast shape's frame; this adapter takes and
    /// returns WORLD space. The direction is rotated in by the conjugate and is NOT
    /// re-normalised — the kernel normalises once itself, which absorbs the few ULPs
    /// a conjugate rotation costs. Unlike `raycastBody`, whose local frame is the
    /// BODY's and differs per candidate, the cast's frame is the QUERY's and is a
    /// constant of the whole traversal, so returning it would hand the caller a
    /// contract in a frame that has nothing to do with the body it just asked about.
    pub fn castShapeBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        cast_shape: narrowphase.SupportShape(Real),
        cast_origin: Vec3r,
        cast_rotation: Quatr,
        direction: Vec3r,
        max_distance: Real,
        back_face_mode: api.BackFaceMode,
    ) ?BodyCastHit {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        const relpose = narrowphase.RelativePose(Real).init(
            cast_origin,
            cast_rotation,
            self.bodies.items(.position)[idx],
            self.bodies.items(.rotation)[idx],
        );
        const local_dir = cast_rotation.conjugate().rotateVec3(direction);
        // The CAST shape is always a bounded convex — the query entry refuses an
        // unbounded probe with a typed error (§1.11.7) — so only the HIT body's
        // category is dispatched on. Exhaustive, no `else`.
        //
        // The half-space arm transports the plane INTO A's frame rather than
        // transporting A: the sweep is a pure translation of A, so A's support in the
        // fixed direction `−n` is a constant of the whole sweep, and one support call
        // answers it in closed form. `RelativePose` already carries B-relative-to-A,
        // which is exactly the pose the transport needs.
        // The sub-shape the mesh arm resolves, and zero for the two arms whose shapes carry
        // no sub-shape at all (§1.11.16).
        var subshape_id: u32 = 0;
        const hit = switch (shape.class()) {
            .convex => narrowphase.castShape(
                Real,
                cast_shape,
                relpose,
                shape_mod.supportShape(shape),
                local_dir,
                max_distance,
            ),
            .half_space => narrowphase.plane.castShape(
                Real,
                shape_mod.halfSpace(shape).transformed(relpose.rot_rel, relpose.pos_rel),
                cast_shape,
                local_dir,
                max_distance,
            ),
            // THREE FRAMES are in play here, and naming them is what keeps the arm readable:
            // the KERNEL works in the cast shape's frame (A's), where `relpose` and
            // `local_dir` already live; the TRAVERSAL works in the BODY's local frame, where
            // the mesh's vertices and node boxes live; and the caller works in WORLD. So the
            // probe's box and the sweep direction are transported into the body's frame for
            // the traversal, while the kernel call is untouched — `castShape` takes B in B's
            // own frame plus `relpose`, which is exactly what a triangle support shape is.
            //
            // The swept traversal is §1.11.10's, verbatim: nodes inflated by the probe's
            // half-extents, the ray starting at the CENTRE of the probe's box — not at its
            // position, which for a decentred probe is a different point.
            .triangle_soup => blk: {
                const data = shape.mesh.?;
                const inv_rot = self.bodies.items(.rotation)[idx].conjugate();
                const probe_box = supportShapeAabb(
                    cast_shape,
                    inv_rot.rotateVec3(cast_origin.sub(self.bodies.items(.position)[idx])),
                    inv_rot.mul(cast_rotation),
                );
                const sweep_dir = inv_rot.rotateVec3(direction);
                var collector = MeshCastCollector{
                    .data = data,
                    .cast_shape = cast_shape,
                    .relpose = relpose,
                    .direction_in_a = local_dir,
                    .sweep_direction_local = sweep_dir,
                    .back_face_mode = back_face_mode,
                    .bound = max_distance,
                };
                _ = data.traverseCast(RayR.init(probe_box.center(), sweep_dir), probe_box.halfExtents(), &collector);
                subshape_id = collector.best_triangle;
                break :blk collector.best;
            },
        } orelse return null;
        return .{
            // A distance is invariant under a rigid transform, so it needs no mapping.
            .distance = hit.distance,
            // The mesh arm is the only one that fills this; the other two carry zero
            // sub-shapes, so the default IS the value there (§1.11.16).
            .subshape_id = subshape_id,
            .position = cast_rotation.rotateVec3(hit.point).add(cast_origin),
            .normal = cast_rotation.rotateVec3(hit.normal),
        };
    }

    /// Whether `query_shape`, posed at (`query_position`, `query_rotation`),
    /// overlaps body `id`. Null on a stale/invalid handle or shape — distinct from
    /// `false`, which is a real answer.
    ///
    /// The exact kernel is GJK on the cores and the predicate is "the regime is not
    /// `separated`" (`engine-physics-forge.md` §1.11.12). No threshold is introduced
    /// here: the contact margin is the one GJK's own classification carries, and a
    /// second margin proper to queries is exactly what §1.11.12 forbids.
    pub fn overlapShapeBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        query_shape: narrowphase.SupportShape(Real),
        query_position: Vec3r,
        query_rotation: Quatr,
        back_face_mode: api.BackFaceMode,
    ) ?bool {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        switch (shape.class()) {
            .convex => {
                const result = narrowphase.gjk(
                    Real,
                    query_shape,
                    query_position,
                    query_rotation,
                    shape_mod.supportShape(shape),
                    self.bodies.items(.position)[idx],
                    self.bodies.items(.rotation)[idx],
                );
                return result.status != .separated;
            },
            // The half-space is A and the probe is B, which is the orientation
            // §1.11.15's separation formula is written in — `sep = n · supportCore_B(−n)
            // − r_b − d`, one support call. The SIGN of that separation is the whole
            // classification, exactly: no GJK margin enters, and none should, since
            // there is no accumulated rounding here to absorb.
            .half_space => return narrowphase.plane.separation(
                Real,
                shape_mod.halfSpace(shape),
                narrowphase.RelativePose(Real).init(
                    self.bodies.items(.position)[idx],
                    self.bodies.items(.rotation)[idx],
                    query_position,
                    query_rotation,
                ),
                query_shape,
            ) <= 0,
            // The candidate set is the probe's box in the BODY's local frame and the exact
            // kernel is GJK on the cores, one triangle at a time — the probe against
            // `Core.triangle`, with no kernel of its own and no threshold of its own
            // (§1.11.12: the contact margin is GJK's classification margin).
            .triangle_soup => {
                const data = shape.mesh.?;
                const inv_rot = self.bodies.items(.rotation)[idx].conjugate();
                const probe_box = meshCandidateBox(
                    data,
                    query_shape,
                    inv_rot.rotateVec3(query_position.sub(self.bodies.items(.position)[idx])),
                    inv_rot.mul(query_rotation),
                );
                var collector = MeshOverlapCollector{
                    .data = data,
                    .probe = query_shape,
                    .probe_position = query_position,
                    .probe_rotation = query_rotation,
                    // B is the PROBE expressed in A = the body's frame, which is the frame the
                    // triangle's normal and its `v₀` are in — so the back-face predicate's
                    // three operands all live in one frame and none is converted twice.
                    .probe_in_body = narrowphase.RelativePose(Real).init(
                        self.bodies.items(.position)[idx],
                        self.bodies.items(.rotation)[idx],
                        query_position,
                        query_rotation,
                    ),
                    .body_position = self.bodies.items(.position)[idx],
                    .body_rotation = self.bodies.items(.rotation)[idx],
                    .back_face_mode = back_face_mode,
                };
                _ = data.traverseAabb(probe_box, &collector);
                return collector.found;
            },
        }
    }

    /// Whether body `id`'s exact geometry meets the world AABB `query_box`, faces
    /// included. Null on a stale/invalid handle or shape — distinct from `false`, which
    /// is a real answer.
    ///
    /// **A SIXTH adapter, and item 6 of E5 is why it exists.** `overlapAabb`'s collector
    /// used to call `bodyAabb` on every candidate, which is correct for a bounded convex
    /// and PANICS on a half-space — the class assert — and in ReleaseFast, where that
    /// assert is compiled out, would fall through to `worldAabb`'s `unreachable`. Putting
    /// the dispatch here rather than in the collector keeps all class dispatch in one
    /// file, beside the other five, and keeps `query/overlap.zig` from needing the
    /// half-space transport.
    ///
    /// The convex arm is the body's TIGHT world AABB and never the broadphase leaf's fat
    /// box, so the answer is not a function of a tuning constant (§1.11.12). The
    /// half-space arm is the corner PREDICATE, which never builds a box at all — the two
    /// arms agree on what "meets" means without sharing a representation.
    pub fn aabbOverlapsBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        query_box: Aabbr,
    ) ?bool {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        return switch (shape.class()) {
            // A MESH ANSWERS EXACTLY AS A BOUNDED CONVEX DOES, and the two arms are written
            // as one because they are one answer: the body's TIGHT world AABB against the
            // queried box, faces included. This entry stops at AABB GRANULARITY and does NOT
            // descend into the mesh (§1.11.17) — so a box that meets the mesh's own box
            // without touching a triangle DOES return the body, and that approximation is
            // pinned by a test rather than tightened by accident. What §1.11.12 forbids is an
            // answer that depends on a tuning constant, and the mesh's own box is not one.
            // A CONVEX recomputes: its pose moves every tick, so a cache would need an
            // invalidation this design deliberately does not have, and the four primitives
            // cost a handful of operations anyway.
            .convex => worldAabb(shape, self.bodies.items(.position)[idx], self.bodies.items(.rotation)[idx])
                .overlaps(query_box),
            // A MESH reads its CACHE, and falls back to the pass when that cache has been
            // poisoned by an external teleport. Measured at 72.8 µs against 11.5 ns on a
            // 16 000-triangle mesh (`Body.world_aabb`), which is why the fast path is the
            // default and the slow one the exception rather than the reverse.
            .triangle_soup => blk: {
                const cached = self.bodies.items(.world_aabb)[idx];
                const box = if (std.math.isNan(cached.min.toArray()[0]))
                    worldAabb(shape, self.bodies.items(.position)[idx], self.bodies.items(.rotation)[idx])
                else
                    cached;
                break :blk box.overlaps(query_box);
            },
            .half_space => narrowphase.plane.aabbOverlaps(
                Real,
                shape_mod.halfSpace(shape).transformed(
                    self.bodies.items(.rotation)[idx],
                    self.bodies.items(.position)[idx],
                ),
                query_box,
            ),
        };
    }

    /// Whether the world-space `point` lies inside body `id`, boundary INCLUDED —
    /// the same solidity convention as a ray origin inside a shape (§1.11.4). Null
    /// on a stale/invalid handle or shape.
    ///
    /// The point is transported into the body's local frame by the inverse pose, the
    /// way `raycastBody` transports a ray, and the membership predicate runs there.
    pub fn containsPointBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        point: Vec3r,
    ) ?bool {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        const local = self.bodies.items(.rotation)[idx].conjugate()
            .rotateVec3(point.sub(self.bodies.items(.position)[idx]));
        return switch (shape.class()) {
            .convex => narrowphase.containsPoint(Real, shape_mod.supportShape(shape), local),
            .half_space => narrowphase.plane.containsPoint(Real, shape_mod.halfSpace(shape), local),
            // A MESH IS A SURFACE: membership is FALSE everywhere, and that is CATEGORICAL
            // rather than a setting (§1.11.17). It holds for a point inside the volume a
            // CLOSED mesh encloses too — nothing validates closure, so there is no volume to
            // be inside of. There is no mesh counterpart to `treat_convex_as_solid`: the
            // reference has one, by hit-count parity along a `+Y` ray, and Weld refuses it
            // because parity presumes closure, on an open mesh the answer would depend on an
            // arbitrary ray direction, and a membership test would cost a full raycast.
            //
            // The consequence a caller sees: `pointQuery` never returns a body carrying a
            // mesh. This one line is what makes that true.
            .triangle_soup => false,
        };
    }

    /// Closest point on body `id`'s SURFACE to the world-space `point`, with the
    /// distance to the SOLID. Null on a stale/invalid handle or shape.
    ///
    /// `engine-physics-forge.md` §1.11.13, in its order and for its reasons:
    ///
    ///   - Solidity is decided FIRST, by the same per-sub-shape membership predicate
    ///     the point query uses, UPSTREAM of any classification. A point inside —
    ///     boundary included — is at distance 0 and its closest point is ITSELF.
    ///   - Outside, GJK runs between a degenerate POINT core placed at the queried
    ///     point and the body, and the surface quantities are derived from the CORE
    ///     ones: `distance = max(0, core_distance − r_b)` and
    ///     `position = closest_b + r_b · normalize(point − closest_b)`. `closest_a`
    ///     needs no lookup: A's core is a single point, so it IS the queried point in
    ///     every regime.
    ///   - The closest points are valid for `separated` AND `shallow`, and that
    ///     second inclusion is normative: `shallow` is NOT an interior, it is a real
    ///     separation absorbed by the numeric margin, and treating it as one would
    ///     return 0 for a measurably external point.
    ///   - `.deep` is REACHABLE for an exterior point, and its closest points are
    ///     UNSPECIFIED (`gjk.zig`: `closest_b` is the zero vector, `distance` is 0).
    ///     The regime fires whenever the core distance falls inside
    ///     `conv_k · floatEps · coordScale`, and for a point probe `coordScale` is
    ///     relative geometry — `|body_pos − point| + coreExtent(b)` — so a point a few
    ///     ULPs outside a hard core lands there while the membership test above, which
    ///     is the AUTHORITY on solidity, says outside. The witness is then
    ///     reconstructed from the one thing `.deep` does specify, the terminal simplex,
    ///     whose vertices carry `support_b`; the answer stays an EXTERIOR answer, with
    ///     `position` on the body's surface and never the queried point.
    pub fn closestPointBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        point: Vec3r,
    ) ?BodyClosestPoint {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;

        // A DISPATCH on the class, exhaustive and with no `else` arm (M1.1.11.1). It was
        // an `if` on the half-space falling through to the convex path, and that was the
        // most dangerous of the four holes in the M1.1.11 safety net: a third-category
        // shape did not fail here, it FELL THROUGH into `supportShape`, which panics in
        // a safe build and is undefined behaviour in ReleaseFast. The convex arm is
        // written as an empty arm followed by the body of the function, so the
        // fall-through is now something the code STATES rather than something it does.
        switch (shape.class()) {
            .convex => {},
            // The half-space answers in closed form, and it answers BOTH regimes at
            // once: `closestPoint` carries the solidity convention itself, returning
            // distance 0 and the queried point for an interior point rather than
            // projecting it onto the boundary. The point is transported into the body's
            // local frame the way `containsPointBody` transports one, and only the
            // POSITION needs mapping back — a distance is invariant under a rigid
            // transform.
            .half_space => {
                const projection = narrowphase.plane.closestPoint(
                    Real,
                    shape_mod.halfSpace(shape),
                    self.bodies.items(.rotation)[idx].conjugate()
                        .rotateVec3(point.sub(self.bodies.items(.position)[idx])),
                );
                return .{
                    .distance = projection.distance,
                    .position = self.bodies.items(.rotation)[idx].rotateVec3(projection.position)
                        .add(self.bodies.items(.position)[idx]),
                };
            },
            // A MESH MEASURES TO ITS SURFACE, and never zero by interiority — there is no
            // interior (§1.11.17). So there is no membership test on this arm at all: the
            // convex path below runs one FIRST because a convex is solid, and a mesh has
            // nothing for it to answer. A distance of zero here means the point is ON a
            // triangle, which is a surface answer and not an interior one.
            //
            // The traversal is the bounded-distance one, tightening from infinity to the best
            // triangle found (§1.11.13's branch-and-bound analogue for a distance). The
            // per-triangle kernel is `closestPointOnCore`, the same one the convex arm uses
            // below — a point core against a `Core.triangle`, no new kernel.
            .triangle_soup => {
                const data = shape.mesh.?;
                var collector = MeshClosestPointCollector{
                    .data = data,
                    .point = point,
                    .body_position = self.bodies.items(.position)[idx],
                    .body_rotation = self.bodies.items(.rotation)[idx],
                };
                _ = data.traverseDistance(
                    self.bodies.items(.rotation)[idx].conjugate()
                        .rotateVec3(point.sub(self.bodies.items(.position)[idx])),
                    &collector,
                );
                return collector.best;
            },
        }
        const shape_b = shape_mod.supportShape(shape);

        // Inside the solid — boundary included — is distance 0 at the point itself.
        const local = self.bodies.items(.rotation)[idx].conjugate()
            .rotateVec3(point.sub(self.bodies.items(.position)[idx]));
        if (narrowphase.containsPoint(Real, shape_b, local)) {
            return .{ .distance = 0, .position = point };
        }

        // Outside: the shared point-core kernel, which is also what the mesh arm above runs
        // per triangle.
        return closestPointOnCore(
            point,
            shape_b,
            self.bodies.items(.position)[idx],
            self.bodies.items(.rotation)[idx],
        );
    }

    /// Full narrowphase for the pair `a`/`b`, calling `collector.add(subshape_id, manifold)`
    /// for EVERY manifold the pair produces. Nothing is called when the pair is separated, or
    /// when either handle — or its shape — is stale/invalid.
    ///
    /// **A mesh pair produces SEVERAL manifolds, one per contacting triangle, and that is the
    /// only shape change the mesh imposes on the rigid solver** (§1.11.17). A pair with no
    /// sub-shapes produces at most one and tags it `0`, so `collidePair` below is this entry
    /// with a single-slot collector — one implementation of the 3×3 dispatch, not two.
    ///
    /// The pipeline is driven in a canonical BODY-ID order (`min(a, b)` first), negating the
    /// normal for the `a > b` caller. That makes the whole narrowphase order-independent even
    /// for the measure-zero case `collide`'s pose key cannot break — two bodies with
    /// bit-identical shape AND pose — and gives the body-id-keyed order M1.1.6 warm-starting
    /// needs.
    pub fn collidePairEach(
        self: *const BodyManager,
        store: *const ShapeStore,
        a: BodyId,
        b: BodyId,
        collector: anytype,
    ) void {
        if (a > b) {
            var negating = NegatingManifoldCollector(@TypeOf(collector)){ .inner = collector };
            self.collidePairEachOrdered(store, b, a, &negating);
            return;
        }
        self.collidePairEachOrdered(store, a, b, collector);
    }

    /// Full narrowphase (GJK → shallow/deep contact manifold) for the pair `a`/`b`, resolving
    /// each body's world pose and support shape (via `store`). Returns null if the pair is
    /// separated, or if either handle — or its shape — is stale/invalid.
    ///
    /// **PRECONDITION: neither body carries SUB-SHAPES**, i.e. neither is a mesh. A mesh pair
    /// yields one manifold per contacting triangle and there is no single answer to return;
    /// `collidePairEach` is the entry for it. Asserted rather than answered, because a caller
    /// holding a mesh handle and asking for "the" manifold has a bug at its own call site, and
    /// returning the first triangle's would be a silent wrong answer.
    pub fn collidePair(self: *const BodyManager, store: *const ShapeStore, a: BodyId, b: BodyId) ?ContactManifold {
        if (std.debug.runtime_safety) {
            for ([_]BodyId{ a, b }) |id| {
                const idx = self.alloc.validate(id) orelse continue;
                const shape = store.get(self.bodies.items(.shape)[idx]) orelse continue;
                std.debug.assert(shape.class() != .triangle_soup);
            }
        }
        var single = SingleManifoldCollector{};
        self.collidePairEach(store, a, b, &single);
        return single.manifold;
    }

    /// Full narrowphase between a caller-supplied convex `probe` posed at
    /// (`probe_position`, `probe_rotation`) and body `id`, calling
    /// `collector.add(subshape_id, manifold)` for EVERY manifold the pair produces. Nothing
    /// is called when the two are separated, or when the handle — or its shape — is
    /// stale/invalid.
    ///
    /// **The seventh body-level adapter, and the one a VIRTUAL controller needs.** A
    /// controller owns no body, so `collidePairEach` — which resolves both sides from
    /// handles — cannot serve it at all. This is `castShapeBody`'s shape without the
    /// direction: shape plus pose against a body, dispatched on the BODY's category alone,
    /// the probe being a bounded convex by its type.
    ///
    /// **Only the general "Each" form exists.** There is deliberately no convenience
    /// sibling asserting the body carries no sub-shape, the way `collidePair` wraps
    /// `collidePairEach`: the controller is this entry's only consumer and it needs the
    /// general form, a mesh floor being exactly the case it cannot afford to lose. Such a
    /// wrapper is purely additive — zero call sites to touch — so the deferral rule lets it
    /// wait for a caller that wants it.
    ///
    /// **Normal orientation: probe → body.** The probe is A and the body is B, in all three
    /// arms. The half-space arm computes body→probe, §1.11.15's formulas being stated with
    /// the plane as A, and negates; the mesh arm passes `mesh_is_a = false` so the shared
    /// helper hands `collideOrdered` its arguments in that same order and needs no mirroring.
    ///
    /// **No `back_face_mode` parameter, and that is a decision rather than an omission.**
    /// Contact generation culls back faces unconditionally: the mode is a solver-internal
    /// setting and not part of the frozen surface (§1.11.17), because a contact generated on
    /// the back of a wall pushes the body through it. The mesh arm therefore inherits both
    /// the cull and the internal-edge correction from `collideConvexMesh` — which is the
    /// whole reason this entry reuses that helper instead of walking the mesh itself.
    ///
    /// Internal: no interface entry corresponds to it, and it knows nothing about
    /// characters. Self-exclusion belongs to the controller — the broadphase will offer a
    /// character its own presence among the candidates of its own sweeps, and filtering that
    /// out is the controller's business, not this adapter's.
    pub fn collideShapeBody(
        self: *const BodyManager,
        store: *const ShapeStore,
        id: BodyId,
        probe: narrowphase.SupportShape(Real),
        probe_position: Vec3r,
        probe_rotation: Quatr,
        collector: anytype,
    ) void {
        const idx = self.alloc.validate(id) orelse return;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return;
        const body_position = self.bodies.items(.position)[idx];
        const body_rotation = self.bodies.items(.rotation)[idx];

        // Exhaustive on the body's class, no `else` — a fourth category is a compile error
        // here and owes its own decision (§1.11.15, §1.11.17).
        switch (shape.class()) {
            .convex => {
                const m = narrowphase.collideOrdered(
                    Real,
                    probe,
                    probe_position,
                    probe_rotation,
                    shape_mod.supportShape(shape),
                    body_position,
                    body_rotation,
                ) orelse return;
                collector.add(0, m);
            },
            .half_space => {
                var m = narrowphase.collidePlane(
                    Real,
                    shape_mod.halfSpace(shape),
                    body_position,
                    body_rotation,
                    narrowphase.RelativePose(Real).init(
                        body_position,
                        body_rotation,
                        probe_position,
                        probe_rotation,
                    ),
                    probe,
                ) orelse return;
                m.normal = m.normal.neg(); // computed body→probe; the caller asked probe→body
                collector.add(0, m);
            },
            // SEVERAL manifolds, one per contacting triangle — the one shape change a mesh
            // imposes, and the reason this entry has no single-manifold form.
            .triangle_soup => self.collideConvexMesh(
                probe,
                probe_position,
                probe_rotation,
                shape.mesh.?,
                body_position,
                body_rotation,
                false, // the mesh is B, so the normal comes out probe→body already
                collector,
            ),
        }
    }

    /// `collidePairEach` for a fixed (already-canonical body-id) order — validates both
    /// handles/shapes then runs the manifold pipeline in THIS order. Calls `collideOrdered`
    /// (not `collide`): `collide` would re-canonicalize by pose, so the `feature_id`
    /// reference/incident ownership would follow the pose and flip across a lexicographic pose
    /// boundary (Codex P1b). Driving by the fixed body-id order instead keeps the feature_id
    /// frame-stable; `collidePairEach`'s normal negation still gives order-independence.
    fn collidePairEachOrdered(
        self: *const BodyManager,
        store: *const ShapeStore,
        a: BodyId,
        b: BodyId,
        collector: anytype,
    ) void {
        const ia = self.alloc.validate(a) orelse return;
        const ib = self.alloc.validate(b) orelse return;
        const shape_a = store.get(self.bodies.items(.shape)[ia]) orelse return;
        const shape_b = store.get(self.bodies.items(.shape)[ib]) orelse return;
        const pos_a = self.bodies.items(.position)[ia];
        const rot_a = self.bodies.items(.rotation)[ia];
        const pos_b = self.bodies.items(.position)[ib];
        const rot_b = self.bodies.items(.rotation)[ib];

        // Dispatch on the pair of CATEGORIES, nested and exhaustive with no `else` on either
        // level — nine arms, each owing its own decision.
        //
        // The half-space arms are written with the PLANE as A, which is the orientation
        // §1.11.15's formulas are stated in. When the plane is B — reachable, since this order
        // is the body-id order and the plane may have been created either side — the pair is
        // computed the other way round and the normal negated, which is exactly what
        // `collidePairEach` does one level up for the caller's order. Position and penetration
        // are order-independent, so nothing else needs mirroring, and
        // `contact_constraint.prepare` reconstructs the two anchors from
        // `position ± ½·penetration·normal` with no case for either shape.
        switch (shape_a.class()) {
            .convex => switch (shape_b.class()) {
                .convex => {
                    const m = narrowphase.collideOrdered(
                        Real,
                        shape_mod.supportShape(shape_a),
                        pos_a,
                        rot_a,
                        shape_mod.supportShape(shape_b),
                        pos_b,
                        rot_b,
                    ) orelse return;
                    collector.add(0, m);
                },
                .half_space => {
                    var m = narrowphase.collidePlane(
                        Real,
                        shape_mod.halfSpace(shape_b),
                        pos_b,
                        rot_b,
                        narrowphase.RelativePose(Real).init(pos_b, rot_b, pos_a, rot_a),
                        shape_mod.supportShape(shape_a),
                    ) orelse return;
                    m.normal = m.normal.neg(); // computed B→A; the caller asked A→B
                    collector.add(0, m);
                },
                .triangle_soup => self.collideConvexMesh(
                    shape_mod.supportShape(shape_a),
                    pos_a,
                    rot_a,
                    shape_b.mesh.?,
                    pos_b,
                    rot_b,
                    false,
                    collector,
                ),
            },
            .half_space => switch (shape_b.class()) {
                .convex => {
                    const m = narrowphase.collidePlane(
                        Real,
                        shape_mod.halfSpace(shape_a),
                        pos_a,
                        rot_a,
                        narrowphase.RelativePose(Real).init(pos_a, rot_a, pos_b, rot_b),
                        shape_mod.supportShape(shape_b),
                    ) orelse return;
                    collector.add(0, m);
                },
                // Two half-spaces, and a half-space against a MESH, have NO narrowphase kernel
                // and will not get one — §1.11.15's table pairs a half-space with a BOUNDED
                // CONVEX, and §1.11.17's with one too.
                //
                // **The motive is a PRECONDITION OF THIS ADAPTER, not a property of the
                // engine.** It presumes its pair came from `computePairs` under a correct layer
                // assignment, and a static↔static pair is a programming error at the call site.
                // It is NOT that `BodyType` determines the broad layer: no
                // `BodyType → BroadphaseLayer` wiring exists — the layer is an insertion
                // argument, and `gjk_test.zig` inserts static bodies into `.dynamic` — and that
                // wiring arrives with `PhysicsWorld` at M1.1.15. Justifying the assertion by a
                // property the code does not carry would be the costliest defect class there
                // is: the one that survives review by resembling an argument.
                .half_space, .triangle_soup => unreachable,
            },
            .triangle_soup => switch (shape_b.class()) {
                .convex => self.collideConvexMesh(
                    shape_mod.supportShape(shape_b),
                    pos_b,
                    rot_b,
                    shape_a.mesh.?,
                    pos_a,
                    rot_a,
                    true,
                    collector,
                ),
                // Mesh against mesh, and mesh against half-space — the same asserted
                // precondition, for the same reason as the arm above.
                .half_space, .triangle_soup => unreachable,
            },
        }
    }

    /// The mesh↔convex arm, shared by both orders: traverse the mesh with the convex's box in
    /// the MESH's local frame and run the ordinary convex narrowphase against each candidate
    /// triangle's `Core.triangle`.
    ///
    /// `mesh_is_a` says which side of the canonical pair the mesh is on, which decides both the
    /// argument order handed to `collideOrdered` — so the manifold normal comes out A→B without
    /// a negation — and the sign of the back-face test.
    fn collideConvexMesh(
        self: *const BodyManager,
        convex: narrowphase.SupportShape(Real),
        convex_position: Vec3r,
        convex_rotation: Quatr,
        data: *const MeshData,
        mesh_position: Vec3r,
        mesh_rotation: Quatr,
        mesh_is_a: bool,
        collector: anytype,
    ) void {
        _ = self;
        const inv_rot = mesh_rotation.conjugate();
        // The SAME hardened filter the shape-overlap arm uses, and for the same reason: contact
        // generation's own predicate is `collideOrdered` returning non-null, which it does for a
        // `shallow` pair, so a box that dropped a triangle inside the contact margin would lose a
        // contact the convex↔convex path would have made (finding F1).
        const box = meshCandidateBox(
            data,
            convex,
            inv_rot.rotateVec3(convex_position.sub(mesh_position)),
            inv_rot.mul(convex_rotation),
        );
        var per_triangle = MeshContactCollector(@TypeOf(collector)){
            .data = data,
            .convex = convex,
            .convex_position = convex_position,
            .convex_rotation = convex_rotation,
            .mesh_position = mesh_position,
            .mesh_rotation = mesh_rotation,
            .mesh_is_a = mesh_is_a,
            .sink = collector,
        };
        _ = data.traverseAabb(box, &per_triangle);
    }
};

/// Keeps the nearest ACCEPTED triangle of one mesh for `raycastBody`, and tightens the
/// traversal's bound to it.
///
/// **Where the back-face POLICY is applied.** The kernel reports which side was met and
/// never decides whether that side answers — it may not, `triangle.zig` being forbidden
/// from importing the query vocabulary. This is the one place that knows both the mode and
/// the geometry, so it is where `.ignore` drops a hit and `.collide` keeps it; the normal
/// flip that `.collide` owes the `normal · direction <= 0` invariant is `localHit`'s, since
/// that flip is an invariant and not a choice.
///
/// **The tie-break is the SMALLER triangle index**, not the traversal order. A ray through
/// a shared edge of a closed mesh hits both its triangles at the same distance — the
/// kernel's boundary is face-inclusive — and without a fixed tie-break the answer would
/// depend on the SAH cut, hence on the order the triangles were authored in.
const MeshRayCollector = struct {
    data: *const MeshData,
    /// Ray origin in the body's LOCAL frame — the frame the mesh's vertices are in.
    origin: Vec3r,
    /// Unit ray direction in that same frame.
    direction: Vec3r,
    back_face_mode: api.BackFaceMode,
    best: ?narrowphase.LocalHit(Real) = null,
    bound: Real = std.math.inf(Real),

    pub fn add(self: *MeshRayCollector, triangle_index: u32) void {
        const hit = narrowphase.triangle.rayTriangle(
            Real,
            self.data.triangle(triangle_index),
            self.origin,
            self.direction,
        ) orelse return;
        if (hit.back_face and self.back_face_mode == .ignore) return;
        if (hit.distance > self.bound) return;
        if (self.best) |best| {
            if (hit.distance > best.distance) return;
            // Equal distance: the smaller triangle index wins, so the answer is a function
            // of the mesh and the ray and not of the tree's shape.
            if (hit.distance == best.distance and triangle_index >= best.subshape_id) return;
        }
        self.best = narrowphase.triangle.localHit(Real, hit, triangle_index);
        // Tightened TO the distance, not below it, so a triangle at exactly the same
        // distance still reaches the index tie-break above.
        self.bound = hit.distance;
    }

    pub fn maxDistance(self: *const MeshRayCollector) Real {
        return self.bound;
    }

    /// Never stops early: the nearest triangle is only known once the walk is done.
    pub fn shouldStop(_: *const MeshRayCollector) bool {
        return false;
    }
};

/// The candidate box a mesh traversal must offer the exact kernel, inflated so the filter is
/// CONSERVATIVE with respect to GJK's own contact margin (M1.1.11.1 closure, finding F1).
///
/// **Why an unhardened box is a wrong answer and not merely a tight one.** The exact predicate of
/// §1.11.12 is "the GJK regime is not `separated`", and that regime's boundary sits at
/// `conv_k · floatEps(T) · coordScale` BEYOND touching — a triangle separated by less than that
/// is `shallow`, which counts. A box filter accepts only triangles whose own box meets the
/// probe's, so a triangle inside that band but outside the box is dropped BEFORE the kernel can
/// classify it, and the entry answers `false` where the same probe against a bounded convex —
/// which no box filters at all — answers `true`. The convex arm calls GJK unfiltered; the mesh arm
/// must not be stricter than the kernel it feeds.
///
/// The inflation is the NORMATIVE margin, reused: `narrowphase.contactMargin` is the very
/// expression the classification evaluates, and `coordScale` is its symmetric pair scale. No
/// second epsilon is introduced — inventing one is what the discipline forbids, and one already
/// exists for exactly this band.
///
/// The mesh side of the scale is an upper BOUND over all candidate triangles
/// (`MeshData.maxVertexMagnitude`), because the box has to be fixed before the traversal chooses
/// which triangles it will offer. Over-estimating widens the box, which costs candidates the
/// kernel then rejects — the direction §1.11.2 already assigns that cost to.
fn meshCandidateBox(
    data: *const MeshData,
    probe: narrowphase.SupportShape(Real),
    probe_local_position: Vec3r,
    probe_local_rotation: Quatr,
) Aabbr {
    const scale = narrowphase.coordScale(
        Real,
        probe_local_position.length(),
        probe,
        // The mesh side enters through the bound, so a synthetic support shape carrying it as a
        // core extent would be a second way of saying the same thing; the sum is written out.
        .{ .core = .point, .radius = 0 },
    ) + data.maxVertexMagnitude();
    const margin = narrowphase.contactMargin(Real, scale);
    return supportShapeAabb(probe, probe_local_position, probe_local_rotation)
        .inflate(Vec3r.splat(margin));
}

/// Negates the normal of every manifold on its way through — the `a > b` half of
/// `collidePairEach`'s canonicalisation.
///
/// The normal is the only field that needs mirroring: position and penetration are
/// order-independent, and `contact_constraint.prepare` reconstructs both surface points from
/// `position ± ½·penetration·normal`, so the flip carries through to the anchors for free.
fn NegatingManifoldCollector(comptime Inner: type) type {
    return struct {
        inner: Inner,

        pub fn add(self: *@This(), subshape_id: u32, manifold: ContactManifold) void {
            var mirrored = manifold;
            mirrored.normal = mirrored.normal.neg(); // the caller wants a→b = −(b→a)
            self.inner.add(subshape_id, mirrored);
        }
    };
}

/// Keeps the ONE manifold a sub-shape-free pair produces — what `collidePair` returns.
///
/// The second assert is what makes that function's precondition unable to fail quietly: a mesh
/// pair reaching here would offer a manifold per contacting triangle, and the first extra one
/// fires rather than being silently dropped.
const SingleManifoldCollector = struct {
    manifold: ?ContactManifold = null,

    pub fn add(self: *SingleManifoldCollector, subshape_id: u32, manifold: ContactManifold) void {
        std.debug.assert(subshape_id == 0);
        std.debug.assert(self.manifold == null);
        self.manifold = manifold;
    }
};

/// Slack, in ULPs of 1, on the test that a contact normal ALREADY IS the face normal — and on
/// the tie band that decides which edges a contact could have come from. Both compare
/// quantities of order 1 (a dot product of two unit vectors) or a length against the triangle's
/// own extent, so this is float noise and not a geometric tolerance: the MODELLING parameter of
/// this mechanism is `mesh.default_active_edge_cos_threshold`, and it lives on the descriptor.
const internal_edge_noise_k: comptime_int = 16;

/// The triangle's FACE normal when the contact came from an INACTIVE edge, or `null` when the
/// normal is to be left alone (`engine-physics-forge.md` §1.11.17).
///
/// **Why a contact normal can differ from the face normal at all.** Against a convex, a contact
/// in the triangle's INTERIOR has the face as its supporting feature, so its normal IS the face
/// normal. A normal that differs therefore comes from the triangle's BOUNDARY — an edge or a
/// vertex — and it is free to tilt anywhere in the fan between the two adjacent faces. On a seam
/// between two coplanar triangles that tilt is pure artefact: the surface is flat, and a slider
/// crossing the seam is decelerated by a normal that has no business having a lateral component.
/// Correcting it to the face normal is what removes the catch.
///
/// **Which edges the contact "could have come from", without inventing a classification.** The
/// evidence is the contact's own surface point ON THE MESH, which §3 makes exactly recoverable:
/// the manifold point is the MIDPOINT of the two surface points, so `position ± ½·penetration·n`
/// gives each of them. The distance from that point to each of the three edge SEGMENTS is then
/// computed, and the candidates are those within float noise of the minimum. Using the SEGMENT
/// rather than the line is what makes a VERTEX contact fall out for free: a point near `v₀` is
/// equidistant from edge `v₀v₁` and edge `v₂v₀`, so both enter the candidate set and both must be
/// inactive for the snap to happen — which errs toward KEEPING a catch at a sharp corner, the
/// safe direction.
///
/// **What is deliberately NOT changed: the penetration.** §1.11.17 prescribes correcting the
/// normal, and only that. Measured along the old normal, the depth slightly over-states the
/// separation along the new one, by the cosine of the angle between them; the position pass then
/// pushes marginally harder than needed, bounded by that angle. Recomputing it would mean
/// re-running the generator against the corrected axis, which is a different manifold and not a
/// correction of this one.
fn internalEdgeNormal(
    data: *const MeshData,
    triangle_index: u32,
    mesh_position: Vec3r,
    mesh_rotation: Quatr,
    manifold: ContactManifold,
    mesh_is_a: bool,
) ?Vec3r {
    const face_local = data.faceNormal(triangle_index);
    const face_world = mesh_rotation.rotateVec3(face_local);
    const mesh_to_convex = if (mesh_is_a) manifold.normal else manifold.normal.neg();

    // Already a FACE contact: nothing to correct, and no edge to consult. Compared against 1,
    // both vectors being unit, so the slack is pure float noise.
    const noise: Real = internal_edge_noise_k * std.math.floatEps(Real);
    if (mesh_to_convex.dot(face_world) >= 1 - noise) return null;

    const verts = data.triangle(triangle_index);
    // The tie band scales with the triangle's own extent — the only scale this geometry has.
    var extent: Real = 0;
    inline for (0..3) |i| {
        extent = @max(extent, verts[(i + 1) % 3].sub(verts[i]).length());
    }
    const band = noise * extent;

    const inv_rot = mesh_rotation.conjugate();
    // The mesh's own surface point, per manifold point: `surface_a = position + ½·p·n` and
    // `surface_b = position − ½·p·n` (§3), and the mesh is whichever of the two it is.
    const half: Real = if (mesh_is_a) 0.5 else -0.5;

    var any_candidate = false;
    for (manifold.points[0..manifold.count]) |point| {
        const surface_world = point.position.add(manifold.normal.scale(half * point.penetration));
        const surface_local = inv_rot.rotateVec3(surface_world.sub(mesh_position));

        var distances: [3]Real = undefined;
        var closest: Real = std.math.inf(Real);
        for (&distances, 0..) |*slot, edge| {
            slot.* = distanceToSegment(surface_local, verts[edge], verts[(edge + 1) % 3]);
            closest = @min(closest, slot.*);
        }
        for (distances, 0..) |distance, edge| {
            if (distance > closest + band) continue;
            any_candidate = true;
            // One ACTIVE candidate edge and the normal stands: the fold is sharp enough that a
            // slider is meant to catch on it.
            if (data.edgeIsActiveAt(triangle_index, @intCast(edge))) return null;
        }
    }
    if (!any_candidate) return null;
    return face_world;
}

/// Distance from `p` to the segment `[a, b]`. The `length_sq == 0` guard is at TRUE ZERO and is
/// unreachable on a stored mesh — `MeshData.init` refuses an exactly degenerate triangle, so no
/// edge of one has zero length — but a zero-length segment would divide, so the guard states
/// what the refusal guarantees rather than trusting it silently.
fn distanceToSegment(p: Vec3r, a: Vec3r, b: Vec3r) Real {
    const ab = b.sub(a);
    const length_sq = ab.dot(ab);
    if (length_sq == 0) return p.sub(a).length();
    const t = std.math.clamp(p.sub(a).dot(ab) / length_sq, 0, 1);
    return p.sub(a.add(ab.scale(t))).length();
}

/// Runs the ordinary convex narrowphase against each candidate triangle of a mesh and forwards
/// every accepted manifold, tagged with its TRIANGLE INDEX — which is the `subshape_id` of a
/// mesh, it being root (§1.11.16).
///
/// **The back-face mode is `ignore`, FIXED, and internal to the solver** (§1.11.17). Contact
/// generation takes no query as a parameter, and there is nothing for a caller to choose here:
/// a contact generated on the back of a wall pushes the body THROUGH it.
///
/// The cull compares the manifold normal, oriented from the MESH toward the CONVEX, against the
/// triangle's own outward normal in world. That orientation is the one the resolution acts
/// along: the convex is pushed out along `+n` exactly when the two agree, and a contact whose
/// axis disagrees is one whose resolution would drive it through the surface. Strict `>`, the
/// true-zero convention — a normal exactly perpendicular to the face is not a front contact and
/// is not treated as one.
///
/// Active-edge correction is NOT applied here: the flags are baked, and the pass that reads
/// them is a separate step. An edge-on contact whose raw normal is near-perpendicular therefore
/// sits close to this cull's boundary, which is the interaction the active-edge step is written
/// against.
fn MeshContactCollector(comptime Sink: type) type {
    return struct {
        data: *const MeshData,
        /// The convex, in its own frame.
        convex: narrowphase.SupportShape(Real),
        convex_position: Vec3r,
        convex_rotation: Quatr,
        mesh_position: Vec3r,
        mesh_rotation: Quatr,
        /// Whether the MESH is body A of the canonical pair.
        mesh_is_a: bool,
        sink: Sink,

        pub fn add(self: *@This(), triangle_index: u32) void {
            const tri = shape_mod.triangleSupportShape(self.data, triangle_index);
            // The canonical order is preserved through the call, so the manifold's normal comes
            // out A→B and needs no mirroring here.
            const manifold = if (self.mesh_is_a) narrowphase.collideOrdered(
                Real,
                tri,
                self.mesh_position,
                self.mesh_rotation,
                self.convex,
                self.convex_position,
                self.convex_rotation,
            ) else narrowphase.collideOrdered(
                Real,
                self.convex,
                self.convex_position,
                self.convex_rotation,
                tri,
                self.mesh_position,
                self.mesh_rotation,
            );
            const found = manifold orelse return;
            const outward = self.mesh_rotation.rotateVec3(self.data.faceNormal(triangle_index));
            const mesh_to_convex = if (self.mesh_is_a) found.normal else found.normal.neg();
            if (mesh_to_convex.dot(outward) <= 0) return; // a back-face contact, culled

            // INTERNAL-EDGE CORRECTION, the consumer of the flags baked at creation
            // (§1.11.17). Applied AFTER the cull, so the cull decides on the raw geometry and
            // the correction only ever moves an accepted contact's normal toward the face it
            // already faces — the two cannot fight.
            var corrected = found;
            if (internalEdgeNormal(
                self.data,
                triangle_index,
                self.mesh_position,
                self.mesh_rotation,
                found,
                self.mesh_is_a,
            )) |face_world| {
                corrected.normal = if (self.mesh_is_a) face_world else face_world.neg();
            }
            self.sink.add(triangle_index, corrected);
        }
    };
}

/// Keeps the nearest ACCEPTED triangle of one mesh for `castShapeBody`, and tightens the
/// swept traversal's bound to it — the mesh sibling of `MeshRayCollector`.
///
/// **The facing is decided in the BODY's local frame, on the triangle's own normal**, and
/// not on the normal the kernel returns. The cast kernel's normal is the separating axis
/// oriented TOWARD the probe, so for a back approach it is already `−n` and carries no
/// information about which side was met — asking it would answer "front" always. The
/// triangle's outward normal against the sweep direction, both in the body's frame, is what
/// answers.
///
/// That also settles what the `.collide` normal FLIP means here: the kernel's contract
/// already guarantees `normal · direction <= 0` on every hit, so on this family the flip is
/// STRUCTURAL rather than applied — a back-face hit's normal IS the negated triangle normal
/// because that is the axis facing the probe. Asserted rather than assumed, in the suite.
const MeshCastCollector = struct {
    data: *const MeshData,
    /// The probe, in its own frame — the caller owns it, it is not a body.
    cast_shape: narrowphase.SupportShape(Real),
    /// The body relative to the probe: the pose the kernel works in.
    relpose: narrowphase.RelativePose(Real),
    /// Sweep direction in the PROBE's frame — what the kernel takes.
    direction_in_a: Vec3r,
    /// Sweep direction in the BODY's local frame — what the facing test takes.
    sweep_direction_local: Vec3r,
    back_face_mode: api.BackFaceMode,
    bound: Real,
    /// The KERNEL's hit type, in the probe's frame — not `BodyCastHit`. The shared mapping
    /// at the end of `castShapeBody` carries every class's answer to world in one place, so
    /// this arm must hand it the same frame the other two do.
    best: ?narrowphase.CastHit(Real) = null,
    best_triangle: u32 = 0,

    pub fn add(self: *MeshCastCollector, triangle_index: u32) void {
        if (self.back_face_mode == .ignore and narrowphase.triangle.isBackFace(
            Real,
            self.data.faceNormal(triangle_index),
            self.sweep_direction_local,
        )) return;
        const hit = narrowphase.castShape(
            Real,
            self.cast_shape,
            self.relpose,
            shape_mod.triangleSupportShape(self.data, triangle_index),
            self.direction_in_a,
            self.bound,
        ) orelse return;
        if (self.best) |best| {
            if (hit.distance > best.distance) return;
            // Equal time of impact: the smaller triangle index wins, so the answer is a
            // function of the mesh and the sweep and not of the tree's shape.
            if (hit.distance == best.distance and triangle_index >= self.best_triangle) return;
        }
        self.best = hit;
        self.best_triangle = triangle_index;
        self.bound = hit.distance;
    }

    pub fn maxDistance(self: *const MeshCastCollector) Real {
        return self.bound;
    }

    /// Never stops early: the nearest time of impact is only known once the walk is done.
    pub fn shouldStop(_: *const MeshCastCollector) bool {
        return false;
    }
};

/// Latches whether ANY triangle of one mesh overlaps the probe, for `overlapShapeBody`.
///
/// **The back-face predicate for an overlap is not the ray's.** A sweep or a ray has a
/// direction to compare against; an overlap has none, so the question becomes whether the
/// probe lies ENTIRELY in the rear half-space of the triangle's plane — one support call,
/// §1.11.15's construction applied to that plane (§1.11.17). A probe STRADDLING the plane
/// touches from the front and counts in both modes, which is the case that fails if the
/// predicate is written as a sign test on the closest point instead of on the support.
const MeshOverlapCollector = struct {
    data: *const MeshData,
    probe: narrowphase.SupportShape(Real),
    probe_position: Vec3r,
    probe_rotation: Quatr,
    /// The probe expressed in the BODY's frame — the frame the triangle's normal and its
    /// `v₀` are in, so the back-face predicate's three operands share one frame.
    probe_in_body: narrowphase.RelativePose(Real),
    body_position: Vec3r,
    body_rotation: Quatr,
    back_face_mode: api.BackFaceMode,
    found: bool = false,

    pub fn add(self: *MeshOverlapCollector, triangle_index: u32) void {
        if (self.found) return;
        if (self.back_face_mode == .ignore) {
            const normal = self.data.faceNormal(triangle_index);
            if (narrowphase.triangle.probeIsBehind(
                Real,
                normal,
                self.data.triangle(triangle_index)[0],
                // The probe's CORE support along the triangle's normal, in the body's frame.
                // The radius is carried separately and ADDED by the predicate, which is what
                // makes the test right for a sphere and a capsule and not only for a box.
                self.probe_in_body.supportB(self.probe, normal),
                self.probe.radius,
            )) return;
        }
        const result = narrowphase.gjk(
            Real,
            self.probe,
            self.probe_position,
            self.probe_rotation,
            shape_mod.triangleSupportShape(self.data, triangle_index),
            self.body_position,
            self.body_rotation,
        );
        if (result.status != .separated) self.found = true;
    }
};

/// Keeps the nearest point on any triangle of one mesh, for `closestPointBody`, and tightens
/// the bounded-distance traversal to it.
///
/// No membership test anywhere on this path: a mesh has no interior, so a distance of zero
/// means the queried point is ON a triangle — a SURFACE answer, never an interior one
/// (§1.11.17).
const MeshClosestPointCollector = struct {
    data: *const MeshData,
    /// The queried point in WORLD space — the frame the kernel works in.
    point: Vec3r,
    body_position: Vec3r,
    body_rotation: Quatr,
    best: ?BodyClosestPoint = null,
    best_triangle: u32 = 0,

    pub fn add(self: *MeshClosestPointCollector, triangle_index: u32) void {
        const candidate = closestPointOnCore(
            self.point,
            shape_mod.triangleSupportShape(self.data, triangle_index),
            self.body_position,
            self.body_rotation,
        );
        if (self.best) |best| {
            if (candidate.distance > best.distance) return;
            // Equal distance: the smaller triangle index wins — a shared edge of a closed
            // mesh is equidistant from both its triangles, so without a fixed tie-break the
            // answer would follow the SAH cut.
            if (candidate.distance == best.distance and triangle_index >= self.best_triangle) return;
        }
        self.best = .{
            .distance = candidate.distance,
            .position = candidate.position,
            .subshape_id = triangle_index,
        };
        self.best_triangle = triangle_index;
    }

    /// The bound the traversal prunes on, tightened to the best surface distance so far.
    pub fn maxDistance(self: *const MeshClosestPointCollector) Real {
        if (self.best) |best| return best.distance;
        return std.math.inf(Real);
    }
};

/// Closest point on ONE convex core's surface to `point`, with the distance to that
/// surface — the kernel `closestPointBody` runs on a whole convex and, since M1.1.11.1, on
/// each candidate triangle of a mesh.
///
/// **PRECONDITION: `point` is OUTSIDE the solid**, which the CALLER establishes — by the
/// membership test for a convex, and by the categorical surface rule for a triangle, which
/// has no interior to be inside of. Factored out so the mesh arm reuses the regime handling
/// and the radius projection verbatim instead of restating them; two copies of this
/// `.deep`-witness reconstruction is exactly how the two grains would come to disagree.
pub fn closestPointOnCore(
    point: Vec3r,
    shape_b: narrowphase.SupportShape(Real),
    pos_b: Vec3r,
    rot_b: Quatr,
) BodyClosestPoint {
    const probe: narrowphase.SupportShape(Real) = .{ .core = .point, .radius = 0 };
    const result = narrowphase.gjk(
        Real,
        probe,
        point,
        Quatr.identity,
        shape_b,
        pos_b,
        rot_b,
    );

    // The closest point on B's CORE, and the core distance to it — one pair per
    // regime, because `gjk.zig` specifies different fields in each. `closest_a`
    // never needs a lookup: A's core is a single point, so it IS `point`.
    const CoreWitness = struct { b: Vec3r, distance: Real };
    const core: CoreWitness = switch (result.status) {
        // Both specified.
        .separated, .shallow => .{ .b = result.closest_b, .distance = result.distance },
        // NEITHER specified: `closest_b` is the zero vector and `distance` is 0.
        // The terminal simplex is what `.deep` does carry, and its vertices hold
        // `support_b` — points on B's core, in the PROBE's frame, which for a
        // point core at `point` with identity rotation is world translated by
        // `point`. So the witness comes from there, and the distance is measured
        // against it rather than read from a field that does not hold one.
        .deep => blk: {
            const b = deepCoreWitness(result.simplex[0..result.simplex_count]).add(point);
            break :blk .{ .b = b, .distance = point.sub(b).length() };
        },
    };

    const radius_b = shape_b.radius;
    const surface_distance = @max(0, core.distance - radius_b);
    if (radius_b == 0) {
        // A hard core IS its own surface: no projection, and in particular no
        // normalisation to guard.
        return .{ .distance = surface_distance, .position = core.b };
    }
    const away = point.sub(core.b);
    const scale = @reduce(.Max, @abs(away.data));
    if (scale == 0) {
        // The queried point coincides with the core witness. Reachable only in the
        // deep band, where the two are within float noise of each other; the
        // witness is still a point of the core, hence of the surface for a hard
        // core, so answering it keeps the exterior contract. Guarded at TRUE ZERO
        // because `foundation`'s `normalize` is unguarded and would answer NaN.
        return .{ .distance = surface_distance, .position = core.b };
    }
    const reduced: Vec3r = .{ .data = away.data / @as(@Vector(3, Real), @splat(scale)) };
    const unit = reduced.scale(1 / reduced.length());
    return .{ .distance = surface_distance, .position = core.b.add(unit.scale(radius_b)) };
}

/// Closest point on B's CORE reconstructed from a `.deep` terminal simplex, in the
/// PROBE's frame.
///
/// `.deep` specifies the simplex and nothing else — no distance, no closest points
/// (`gjk.zig`). Its vertices are `support.Vertex(T)` triplets carrying `support_a` /
/// `support_b` alongside the Minkowski point `w`, so re-solving the closest-origin
/// problem over the `w`s recovers the barycentric weights and the same weights
/// combine the `support_b`s into a point of B's core. This is the reconstruction
/// `shapecast.zig` performs at its own terminal, for the same reason and from the same
/// data.
///
/// The result is in the frame GJK ran in, which is A's; the caller maps it out.
fn deepCoreWitness(simplex: []const narrowphase.Simplex(Real).Vertex) Vec3r {
    const S = narrowphase.Simplex(Real);
    std.debug.assert(simplex.len >= 1 and simplex.len <= 4);
    const res = switch (simplex.len) {
        1 => S.closestOriginPoint(simplex[0].w),
        2 => S.closestOriginSegment(simplex[0].w, simplex[1].w),
        3 => S.closestOriginTriangle(simplex[0].w, simplex[1].w, simplex[2].w),
        4 => S.closestOriginTetra(simplex[0].w, simplex[1].w, simplex[2].w, simplex[3].w),
        else => unreachable,
    };
    var acc = Vec3r.zero;
    for (res.indices[0..res.count], res.bary[0..res.count]) |i, weight| {
        acc = acc.add(simplex[i].support_b.scale(weight));
    }
    return acc;
}

/// Exact AABB of a SUPPORT SHAPE — core plus inflation radius — at pose (`pos`, `rot`), in
/// the frame that pose is expressed in.
///
/// The sibling of `worldAabb` at the CORE grain, and it exists because the two entries that
/// take a caller-supplied probe receive a `SupportShape` and not a `Shape`: a mesh's
/// internal traversal needs that probe's box in the BODY's local frame, which no world box
/// can supply once the body is rotated.
///
/// **Deliberately NOT merged with `worldAabb`.** Its convex arms compute the same
/// quantities, but not by the same operation order — the capsule arm merges two transported
/// end-cap boxes where this one adds the radius to a transported half-extent — and M1.1.9 /
/// M1.1.10 pin exact world AABBs for those shapes. Unifying them would be a behaviour
/// change measured in ULPs on inherited envelopes, for no gain; the two grains are also
/// genuinely different, `worldAabb`'s mesh arm bounding a WHOLE mesh where this one bounds
/// ONE triangle.
pub fn supportShapeAabb(shape: narrowphase.SupportShape(Real), pos: Vec3r, rot: Quatr) Aabbr {
    const r = Vec3r.splat(shape.radius);
    switch (shape.core) {
        .point => return Aabbr.fromCenterHalfExtents(pos, r),
        .segment => |half_height| {
            // The axis is transported, then the box spans both endpoints and grows by the
            // radius on every side.
            const axis = Mat3r.fromQuat(rot).cols[1].scale(half_height);
            const p0 = pos.add(axis);
            const p1 = pos.sub(axis);
            return Aabbr.fromMinMax(p0.min(p1), p0.max(p1)).inflate(r);
        },
        .box => |half_extents| {
            // `extent_i = Σ_j |R_ij| · he_j`, the absolute rotation matrix times the
            // half-extents — the exact box of a rotated box.
            const m = Mat3r.fromQuat(rot);
            const c0 = m.cols[0].toArray();
            const c1 = m.cols[1].toArray();
            const c2 = m.cols[2].toArray();
            const he = half_extents.toArray();
            var ext: [3]Real = undefined;
            inline for (0..3) |i| {
                ext[i] = @abs(c0[i]) * he[0] + @abs(c1[i]) * he[1] + @abs(c2[i]) * he[2];
            }
            return Aabbr.fromCenterHalfExtents(pos, Vec3r.fromArray(ext).add(r));
        },
        .triangle => |verts| {
            const first = pos.add(rot.rotateVec3(verts[0]));
            var box = Aabbr.fromMinMax(first, first);
            inline for (1..3) |i| box = box.expand(pos.add(rot.rotateVec3(verts[i])));
            return box.inflate(r);
        },
    }
}

/// Exact world-space AABB of a shape at pose (`pos`, `rot`).
///
/// `pub` since M1.1.10 / E5: a shape CAST needs the initial world AABB of a shape
/// that is not a body — the query's own — to size the swept traversal
/// (`engine-physics-forge.md` §1.11.10). `bodyAabb` is the body-level wrapper.
///
/// **PRECONDITION: the shape is BOUNDED**, which is a DISPATCH on the class and not an
/// assert on one variant of it (M1.1.11.1) — a mesh has an answer here and it is not
/// the half-space's. A half-space has no world AABB at all, and an infinite box does
/// not degrade the BVH, it destroys it: its centre is `(−inf + inf)·0.5`, i.e. NaN,
/// which is the ray origin a shape cast derives from a box; its surface area is
/// infinite, so the SAH cost is infinite at every candidate; and the union carries the
/// infinity to the root, after which every query visits every node (§1.11.15). The
/// plane is asked a PREDICATE instead. The class is dispatched on rather than left to
/// fall through to the `unreachable` below, because the class is the information the
/// failure should carry.
pub fn worldAabb(shape: Shape, pos: Vec3r, rot: Quatr) Aabbr {
    switch (shape.class()) {
        .convex, .triangle_soup => {},
        .half_space => unreachable,
    }
    switch (shape.shape_type) {
        .sphere => return Aabbr.fromCenterHalfExtents(pos, Vec3r.splat(shape.radius)),
        .box => {
            // extent_i = Σ_j |R_ij| · he_j (absolute rotation matrix × half-extents).
            const m = Mat3r.fromQuat(rot);
            const c0 = m.cols[0].toArray();
            const c1 = m.cols[1].toArray();
            const c2 = m.cols[2].toArray();
            const he = shape.half_extents.toArray();
            var ext: [3]Real = undefined;
            inline for (0..3) |i| {
                ext[i] = @abs(c0[i]) * he[0] + @abs(c1[i]) * he[1] + @abs(c2[i]) * he[2];
            }
            return Aabbr.fromCenterHalfExtents(pos, Vec3r.fromArray(ext));
        },
        .capsule => {
            // Endpoints = pos ± R·(0, h, 0) = pos ± h·col1; merge the end-cap spheres.
            const m = Mat3r.fromQuat(rot);
            const axis = m.cols[1].scale(shape.half_height);
            const p0 = pos.add(axis);
            const p1 = pos.sub(axis);
            const rr = Vec3r.splat(shape.radius);
            const cap0 = Aabbr.fromMinMax(p0.sub(rr), p0.add(rr));
            const cap1 = Aabbr.fromMinMax(p1.sub(rr), p1.add(rr));
            return cap0.merge(cap1);
        },
        .triangle_mesh => {
            // The TIGHT box over the TRANSPORTED VERTICES, like every other arm of this
            // function: the box arm applies the absolute rotation matrix to its own
            // half-extents, which for a box IS the tight box; the capsule arm merges the
            // two transported end-cap spheres, which for a capsule IS the tight box.
            // §1.11.12 words this entry's exact kernel as the body's TIGHT world AABB,
            // and the mesh is not the one shape in the family allowed to be loose.
            //
            // The enclosure of the transported LOCAL box is the construction this is
            // not, and the two differ strictly under a rotation that is not axis-aligned
            // — measured on a single triangle at 45° about `+Y`, the enclosure reaches
            // `√2` below the body on the Z axis where the tight box reaches `√2/2`.
            //
            // **O(V), and that costs nothing here**: a mesh forces a STATIC body
            // (`error.ShapeMustBeStatic` above), whose pose never changes and whose
            // broadphase proxy is therefore never updated — there is no per-tick path
            // through this arm at all. What remains is the per-candidate call from
            // `aabbOverlapsBody`; should that ever measure as hot, the answer is a
            // per-body box cached at `addBody`, with no invalidation logic precisely
            // because the shape is static-only, decided on figures rather than guessed.
            //
            // TIGHT OVER THE STORED VERTEX SET, which is the same rule `local_aabb`
            // follows: a vertex no index references still counts, because the engine does
            // not silently drop what the caller supplied — the same doctrine that refuses
            // to sanitise away a degenerate triangle. The two definitions coincide for
            // any mesh whose vertices are all referenced.
            const data = shape.mesh.?;
            const first = pos.add(rot.rotateVec3(data.vertices[0]));
            var box = Aabbr.fromMinMax(first, first);
            for (data.vertices[1..]) |v| box = box.expand(pos.add(rot.rotateVec3(v)));
            return box;
        },
        // The store admits sphere/box/capsule, the plane since M1.1.11 and the triangle
        // mesh since M1.1.11.1, and rejects every other variant with
        // `error.UnsupportedShape`. The plane is excluded by the class dispatch above,
        // so the four arms are exhaustive over what can reach here.
        else => unreachable,
    }
}

/// Widen the descriptor's f32 `Vec3` to solver precision.
fn convVec3(v: ApiVec3) Vec3r {
    const a = v.toArray();
    return Vec3r.fromArray(.{ a[0], a[1], a[2] });
}

/// Widen the descriptor's f32 `Quatf` to solver precision.
fn convQuat(q: ApiQuat) Quatr {
    const a = q.toArray();
    return Quatr.fromArray(.{ a[0], a[1], a[2], a[3] });
}

// --- tests -------------------------------------------------------------------
// The bulk of the `BodyManager` acceptance suite lives in
// `tests/body_manager_test.zig`; the pose mutators are covered inline here
// (M1.1.7) because their contract is exactly the handle validation of this file.

const testing = std.testing;

test "pose mutators write the pose and no-op on a stale handle" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    const shape = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });

    const kept = try bm.addBody(gpa, &store, .{
        .entity = .{ .index = 0, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    });
    const doomed = try bm.addBody(gpa, &store, .{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    });

    const p = Vec3r.fromArray(.{ 1, 2, 3 });
    const q = Quatr.fromAxisAngle(Vec3r.unit_z, 0.5);
    bm.setPosition(kept, p);
    bm.setRotation(kept, q);
    try testing.expect(bm.position(kept).?.approxEql(p, 0));
    try testing.expect(bm.rotation(kept).?.approxEql(q, 0));

    // A stale handle (freed slot, bumped generation) writes nothing — neither into
    // its own freed slot nor anywhere else.
    bm.removeBody(doomed);
    bm.setPosition(doomed, Vec3r.fromArray(.{ 9, 9, 9 }));
    bm.setRotation(doomed, Quatr.fromAxisAngle(Vec3r.unit_x, 1.0));
    try testing.expectEqual(@as(?Vec3r, null), bm.position(doomed));
    try testing.expectEqual(@as(?Quatr, null), bm.rotation(doomed));
    try testing.expect(bm.position(kept).?.approxEql(p, 0));
    try testing.expect(bm.rotation(kept).?.approxEql(q, 0));
}
