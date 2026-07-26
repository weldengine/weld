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
/// Generational store of collision shapes. Re-exported so sibling packages (the
/// `rigid/` solver) can name the `collidePair` store parameter type without
/// importing `shape.zig` directly (import-discipline boundary).
pub const ShapeStore = shape_mod.ShapeStore;
const Shape = shape_mod.Shape;
const Body = body_mod.Body;
const MotionProperties = body_mod.MotionProperties;
const GjkResult = narrowphase.GjkResult(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const RayR = broadphase_mod.Ray(Real);

const ApiVec3 = @import("foundation").math.Vec3;
const ApiQuat = @import("foundation").math.Quatf;

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
    /// inertia. Returns the new handle. Velocity starts at zero. Fails with
    /// `error.InvalidShape` on a stale/invalid `desc.shape`.
    pub fn addBody(self: *BodyManager, gpa: std.mem.Allocator, store: *const ShapeStore, desc: BodyDescriptor) !BodyId {
        const shape = store.get(desc.shape) orelse return error.InvalidShape;
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
            .sleep_radius = body_mod.computeSleepRadius(shape),
            .entity = desc.entity,
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
    /// stale/invalid. Pose-invariant, computed once at creation.
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
    }

    /// Set the world-space orientation (mirror of `setPosition`; the caller owns
    /// normalization). No-op on a stale/invalid handle. INTERNAL — see
    /// `setPosition`.
    ///
    /// NON-ACTIVATING BY CONTRACT — see `setLinearVelocity`.
    pub fn setRotation(self: *BodyManager, id: BodyId, new_rotation: Quatr) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.rotation)[idx] = new_rotation;
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
        return worldAabb(shape, pos, rot);
    }

    /// Ray against one body's shape, resolving its world pose and support shape
    /// (via `store`). Returns null if the handle — or its shape — is
    /// stale/invalid, or if the ray misses; `error.UnsupportedShape` if the shape
    /// is outside the kernel's set (a rounded box). The `BodyId`-level ray
    /// adapter for the broadphase→kernel flow, mirroring `gjkPair` /
    /// `collidePair`: unpack a `queryRay` candidate's `user_data` as a `BodyId`
    /// and call this per candidate.
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
    ) error{UnsupportedShape}!?narrowphase.LocalHit(Real) {
        const idx = self.alloc.validate(id) orelse return null;
        const shape = store.get(self.bodies.items(.shape)[idx]) orelse return null;
        const inv_rot = self.bodies.items(.rotation)[idx].conjugate();
        const local_origin = inv_rot.rotateVec3(ray.origin.sub(self.bodies.items(.position)[idx]));
        const local_direction = inv_rot.rotateVec3(ray.direction);
        return narrowphase.rayShape(Real, shape_mod.supportShape(shape), local_origin, local_direction);
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

    /// Full narrowphase (GJK → shallow/deep contact manifold) for the pair
    /// `a`/`b`, resolving each body's world pose and support shape (via `store`).
    /// Returns null if the pair is separated, or if either handle — or its shape
    /// — is stale/invalid. The `BodyId`-level manifold adapter for the
    /// broadphase→narrowphase flow (mirror of `gjkPair`): unpack a `computePairs`
    /// candidate's `user_data` as a `BodyId` and call this per pair.
    ///
    /// The pipeline is driven in a canonical BODY-ID order (`min(a, b)` first),
    /// negating the normal for the `a > b` caller. This makes the whole
    /// narrowphase order-independent even for the measure-zero case `collide`'s
    /// pose key cannot break — two bodies with bit-identical shape AND pose — and
    /// gives a stable, body-id-keyed order for M1.1.6 warm-starting.
    pub fn collidePair(self: *const BodyManager, store: *const ShapeStore, a: BodyId, b: BodyId) ?ContactManifold {
        if (a > b) {
            var m = self.collidePairOrdered(store, b, a) orelse return null;
            m.normal = m.normal.neg(); // caller wants a→b = −(b→a)
            return m;
        }
        return self.collidePairOrdered(store, a, b);
    }

    /// `collidePair` for a fixed (already-canonical body-id) order — validates both
    /// handles/shapes then runs the manifold pipeline in THIS order. Calls
    /// `collideOrdered` (not `collide`): `collide` would re-canonicalize by pose,
    /// so the `feature_id` reference/incident ownership would follow the pose and
    /// flip across a lexicographic pose boundary (Codex P1b). Driving by the fixed
    /// body-id order instead keeps the feature_id frame-stable; `collidePair`'s
    /// normal negation still gives order-independence.
    fn collidePairOrdered(self: *const BodyManager, store: *const ShapeStore, a: BodyId, b: BodyId) ?ContactManifold {
        const ia = self.alloc.validate(a) orelse return null;
        const ib = self.alloc.validate(b) orelse return null;
        const shape_a = store.get(self.bodies.items(.shape)[ia]) orelse return null;
        const shape_b = store.get(self.bodies.items(.shape)[ib]) orelse return null;
        return narrowphase.collideOrdered(
            Real,
            shape_mod.supportShape(shape_a),
            self.bodies.items(.position)[ia],
            self.bodies.items(.rotation)[ia],
            shape_mod.supportShape(shape_b),
            self.bodies.items(.position)[ib],
            self.bodies.items(.rotation)[ib],
        );
    }
};

/// Exact world-space AABB of a shape at pose (`pos`, `rot`).
fn worldAabb(shape: Shape, pos: Vec3r, rot: Quatr) Aabbr {
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
        // ShapeStore only admits sphere/box/capsule (createShape rejects the
        // rest with error.UnsupportedShape), so no other tag can reach here.
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
