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

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const shape_mod = @import("shape.zig");
const body_mod = @import("body.zig");
const narrowphase = @import("pipeline/narrowphase/root.zig");
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

const ApiVec3 = @import("foundation").math.Vec3;
const ApiQuat = @import("foundation").math.Quatf;

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
        // Material domain guards (debug-only; the M1.1.0 `mass > 0` precedent).
        // Friction is a non-negative Coulomb coefficient; restitution is a [0, 1]
        // ratio. Both must be finite. Typed-error descriptor validation is a later
        // milestone; this guards the otherwise-unchecked material path.
        std.debug.assert(std.math.isFinite(desc.friction) and desc.friction >= 0);
        std.debug.assert(std.math.isFinite(desc.restitution) and desc.restitution >= 0 and desc.restitution <= 1);
        const body = Body{
            .position = convVec3(desc.position),
            .rotation = convQuat(desc.rotation),
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
            .flags = .{ .continuous = desc.continuous },
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
    pub fn setLinearVelocity(self: *BodyManager, id: BodyId, velocity: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.linear_velocity)[idx] = velocity;
    }

    /// Set the world-space angular velocity. No-op on a stale/invalid handle.
    /// Internal to `BodyManager`: the public `PhysicsModule` 3D interface has no
    /// angular-velocity mutator (frozen decision at M1.1.15).
    pub fn setAngularVelocity(self: *BodyManager, id: BodyId, velocity: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.angular_velocity)[idx] = velocity;
    }

    /// Set the world-space position. No-op on a stale/invalid handle. INTERNAL to
    /// `forge_3d` (like `addTorque`/`setAngularVelocity`): the day-1
    /// `PhysicsModule` 3D surface carries no pose mutator — flagged for the M1.1.15
    /// freeze review. The NGS position solver (M1.1.7) writes its corrected poses
    /// through it.
    pub fn setPosition(self: *BodyManager, id: BodyId, new_position: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.position)[idx] = new_position;
    }

    /// Set the world-space orientation (mirror of `setPosition`; the caller owns
    /// normalization). No-op on a stale/invalid handle. INTERNAL — see
    /// `setPosition`.
    pub fn setRotation(self: *BodyManager, id: BodyId, new_rotation: Quatr) void {
        const idx = self.alloc.validate(id) orelse return;
        self.bodies.items(.rotation)[idx] = new_rotation;
    }

    /// Accumulate a world-space force (N) into the body's per-tick force
    /// accumulator. No-op on a stale/invalid handle. Any live body accumulates
    /// (the per-tick clear in `integrate` is uniform); a force must be
    /// re-applied every tick it should act.
    pub fn addForce(self: *BodyManager, id: BodyId, force: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        const forces = self.bodies.items(.force);
        forces[idx] = forces[idx].add(force);
    }

    /// Accumulate a world-space torque (N·m) into the body's per-tick torque
    /// accumulator. No-op on a stale/invalid handle. Internal to `BodyManager`
    /// (the interface has no torque mutator — see `setAngularVelocity`).
    pub fn addTorque(self: *BodyManager, id: BodyId, torque: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        const torques = self.bodies.items(.torque);
        torques[idx] = torques[idx].add(torque);
    }

    /// Apply an instantaneous linear impulse (N·s) as an IMMEDIATE velocity
    /// change `Δv = impulse · inv_mass`. No-op on a stale/invalid handle, and
    /// naturally a no-op on a static/kinematic body (`inv_mass == 0`) — no
    /// `body_type` branch needed.
    pub fn addImpulse(self: *BodyManager, id: BodyId, impulse: Vec3r) void {
        const idx = self.alloc.validate(id) orelse return;
        const inv_mass = self.bodies.items(.motion)[idx].inv_mass;
        const vel = self.bodies.items(.linear_velocity);
        vel[idx] = vel[idx].add(impulse.scale(inv_mass));
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
