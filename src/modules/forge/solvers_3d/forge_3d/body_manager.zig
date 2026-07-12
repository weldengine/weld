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

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const shape_mod = @import("shape.zig");
const body_mod = @import("body.zig");
const IdAllocator = @import("slot_alloc.zig").IdAllocator;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const Aabbr = config.Aabbr;
const BodyId = api.BodyId;
const BodyDescriptor = api.BodyDescriptor;
const ShapeStore = shape_mod.ShapeStore;
const Shape = shape_mod.Shape;
const Body = body_mod.Body;
const MotionProperties = body_mod.MotionProperties;

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
        const body = Body{
            .position = convVec3(desc.position),
            .rotation = convQuat(desc.rotation),
            .linear_velocity = Vec3r.zero,
            .angular_velocity = Vec3r.zero,
            .motion = body_mod.computeMotion(desc, shape),
            .shape = desc.shape,
            .body_type = desc.body_type,
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

    /// Safe getter: derived motion properties, or null if `id` is stale/invalid.
    pub fn motionProperties(self: *const BodyManager, id: BodyId) ?MotionProperties {
        const idx = self.alloc.validate(id) orelse return null;
        return self.bodies.items(.motion)[idx];
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
