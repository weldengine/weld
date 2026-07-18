//! `forge_3d/shape.zig` — the `ShapeStore` and its analytic shape data.
//!
//! `createShape` builds a `Shape` (geometry at solver precision + precomputed
//! local AABB + unit-mass local inertia diagonal) and stores it in a
//! generational slot pool. M1.1.0 constructs sphere/box/capsule; every other
//! `ShapeType` is rejected with `error.UnsupportedShape`. Inertia is the
//! unit-mass diagonal; `BodyManager` scales it by the body's mass at `addBody`.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const narrowphase = @import("pipeline/narrowphase.zig");
const IdAllocator = @import("slot_alloc.zig").IdAllocator;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Aabbr = config.Aabbr;
const ShapeId = api.ShapeId;
const ShapeType = api.ShapeType;
const ShapeDescriptor = api.ShapeDescriptor;

/// Immutable per-shape data: geometry (solver precision), the local-space AABB,
/// and the unit-mass local inertia diagonal (principal axes). Only the geometry
/// fields relevant to `shape_type` are meaningful.
pub const Shape = struct {
    shape_type: ShapeType,
    /// Sphere / capsule radius (metres).
    radius: Real = 0,
    /// Box half-extents (metres).
    half_extents: Vec3r = Vec3r.zero,
    /// Capsule cylinder half-height (metres), along +Y.
    half_height: Real = 0,
    /// Local-space (untransformed) bounding box.
    local_aabb: Aabbr,
    /// Unit-mass local inertia diagonal (principal axes).
    unit_inertia: Vec3r,
};

/// A generational store of collision shapes with LIFO slot reuse.
pub const ShapeStore = struct {
    alloc: IdAllocator = .{},
    shapes: std.ArrayListUnmanaged(Shape) = .empty,

    /// Release all storage.
    pub fn deinit(self: *ShapeStore, gpa: std.mem.Allocator) void {
        self.alloc.deinit(gpa);
        self.shapes.deinit(gpa);
        self.* = undefined;
    }

    /// Number of live shapes.
    pub fn count(self: *const ShapeStore) u32 {
        return self.alloc.live_count;
    }

    /// Build and store a shape, returning its handle. Sphere/box/capsule only;
    /// any other variant returns `error.UnsupportedShape` (no slot allocated).
    pub fn createShape(self: *ShapeStore, gpa: std.mem.Allocator, desc: ShapeDescriptor) !ShapeId {
        const shape = try buildShape(desc);
        try self.alloc.ensureUnusedCapacity(gpa, 1);
        try self.shapes.ensureUnusedCapacity(gpa, 1);
        const a = self.alloc.allocateAssumeCapacity();
        if (a.is_new) {
            self.shapes.appendAssumeCapacity(shape);
        } else {
            self.shapes.items[a.index] = shape;
        }
        return a.id;
    }

    /// Free a shape. No-op on a stale/invalid handle.
    pub fn destroyShape(self: *ShapeStore, id: ShapeId) void {
        _ = self.alloc.free(id);
    }

    /// Safe getter — returns the shape, or null if `id` is stale/invalid.
    pub fn get(self: *const ShapeStore, id: ShapeId) ?Shape {
        const idx = self.alloc.validate(id) orelse return null;
        return self.shapes.items[idx];
    }
};

/// Convert an immutable `Shape` to the narrowphase `SupportShape` at solver
/// precision: sphere → point core + radius, capsule → Y-segment(`half_height`)
/// core + radius, box → box(`half_extents`) core + radius 0 (a box has no convex
/// radius in M1.1.2). `ShapeStore` only ever holds these three (`createShape`
/// rejects the rest with `error.UnsupportedShape`), so no other tag can reach
/// here — the same invariant as `body_manager.worldAabb`.
pub fn supportShape(shape: Shape) narrowphase.SupportShape(Real) {
    return switch (shape.shape_type) {
        .sphere => .{ .core = .point, .radius = shape.radius },
        .capsule => .{ .core = .{ .segment = shape.half_height }, .radius = shape.radius },
        .box => .{ .core = .{ .box = shape.half_extents }, .radius = 0 },
        else => unreachable,
    };
}

/// Build the `Shape` for a descriptor (sphere/box/capsule), computing its local
/// AABB and unit-mass inertia. Other shapes → `error.UnsupportedShape`.
fn buildShape(desc: ShapeDescriptor) error{UnsupportedShape}!Shape {
    switch (desc) {
        .sphere => |s| {
            const r: Real = s.radius;
            return .{
                .shape_type = .sphere,
                .radius = r,
                .local_aabb = Aabbr.fromCenterHalfExtents(Vec3r.zero, Vec3r.splat(r)),
                // I = 2/5 m r² (all axes), unit mass.
                .unit_inertia = Vec3r.splat(0.4 * r * r),
            };
        },
        .box => |b| {
            const he_arr = b.half_extents.toArray(); // [3]f32
            const hx: Real = he_arr[0];
            const hy: Real = he_arr[1];
            const hz: Real = he_arr[2];
            const he = Vec3r.fromArray(.{ hx, hy, hz });
            return .{
                .shape_type = .box,
                .half_extents = he,
                .local_aabb = Aabbr.fromCenterHalfExtents(Vec3r.zero, he),
                // Ix = m/3 (hy² + hz²), cyclic; unit mass.
                .unit_inertia = Vec3r.fromArray(.{
                    (hy * hy + hz * hz) / 3.0,
                    (hx * hx + hz * hz) / 3.0,
                    (hx * hx + hy * hy) / 3.0,
                }),
            };
        },
        .capsule => |c| {
            const r: Real = c.radius;
            const h: Real = c.half_height;
            return .{
                .shape_type = .capsule,
                .radius = r,
                .half_height = h,
                // Extends ±r in X/Z, ±(h+r) in Y.
                .local_aabb = Aabbr.fromCenterHalfExtents(Vec3r.zero, Vec3r.fromArray(.{ r, h + r, r })),
                .unit_inertia = capsuleUnitInertia(r, h),
            };
        },
        else => return error.UnsupportedShape,
    }
}

/// Unit-mass local inertia diagonal of a Y-axis capsule (radius `r`, cylinder
/// half-height `h`): a composite of the cylinder and two hemispheres with the
/// mass split proportional to their volumes, hemispheres carried to the capsule
/// centre by the parallel-axis theorem. Degenerates to a sphere (h→0) and a
/// rod (r→0).
fn capsuleUnitInertia(r: Real, h: Real) Vec3r {
    const pi: Real = std.math.pi;
    const v_cyl = 2.0 * pi * r * r * h; // π r² · 2h
    const v_sph = (4.0 / 3.0) * pi * r * r * r; // two hemispheres = one sphere
    const v_total = v_cyl + v_sph;
    const m_cyl = v_cyl / v_total; // unit total mass, split by volume
    const m_sph = v_sph / v_total;

    // Long axis (Y): cylinder ½mr² + hemispheres ⅖mr².
    const iyy = m_cyl * (0.5 * r * r) + m_sph * (0.4 * r * r);
    // Transverse (X = Z): cylinder m(h²/3 + r²/4) + hemispheres m(⅖r² + h² + ¾hr).
    const ixx = m_cyl * (h * h / 3.0 + r * r / 4.0) +
        m_sph * (0.4 * r * r + h * h + 0.75 * h * r);
    return Vec3r.fromArray(.{ ixx, iyy, ixx });
}

const testing = std.testing;

test "unsupported shape is rejected" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    try testing.expectError(error.UnsupportedShape, store.createShape(gpa, .{ .cylinder = {} }));
    try testing.expectError(error.UnsupportedShape, store.createShape(gpa, .{ .empty = {} }));
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "sphere shape: local aabb and unit inertia" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    const id = try store.createShape(gpa, .{ .sphere = .{ .radius = 2.0 } });
    const s = store.get(id).?;
    try testing.expect(s.local_aabb.min.approxEql(Vec3r.splat(-2.0), 1e-6));
    try testing.expect(s.local_aabb.max.approxEql(Vec3r.splat(2.0), 1e-6));
    // 2/5 · 2² = 1.6 on every axis.
    try testing.expect(s.unit_inertia.approxEql(Vec3r.splat(1.6), 1e-6));
}

test "box shape: local aabb and cyclic unit inertia" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    // half_extents is the f32 descriptor Vec3 (`math.Vec3`).
    const id = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.fromArray(.{ 1, 2, 3 }) } });
    const s = store.get(id).?;
    try testing.expect(s.local_aabb.max.approxEql(vec3(1, 2, 3), 1e-6));
    try testing.expect(s.local_aabb.min.approxEql(vec3(-1, -2, -3), 1e-6));
    // Ix = (2²+3²)/3 = 13/3, Iy = (1²+3²)/3 = 10/3, Iz = (1²+2²)/3 = 5/3.
    try testing.expect(s.unit_inertia.approxEql(vec3(13.0 / 3.0, 10.0 / 3.0, 5.0 / 3.0), 1e-5));
}

test "capsule unit inertia degenerates to a sphere at h=0" {
    // h→0 ⇒ capsule is a sphere of radius r ⇒ inertia 2/5 r² on every axis.
    const inertia = capsuleUnitInertia(1.5, 0.0);
    try testing.expect(inertia.approxEql(Vec3r.splat(0.4 * 1.5 * 1.5), 1e-6));
}

test "shape slot reuse is LIFO and generation-checked" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    const a = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const b = try store.createShape(gpa, .{ .box = .{} });
    store.destroyShape(b);
    try testing.expect(store.get(b) == null); // stale ⇒ safe getter returns null
    const c = try store.createShape(gpa, .{ .capsule = .{} }); // reuses b's slot
    try testing.expect(c != b);
    try testing.expectEqual(api.PackedId.unpack(b).index, api.PackedId.unpack(c).index);
    try testing.expectEqual(api.PackedId.unpack(b).generation +% 1, api.PackedId.unpack(c).generation);
    try testing.expect(store.get(b) == null);
    try testing.expect(store.get(a) != null);
    try testing.expect(store.get(c) != null);
    try testing.expectEqual(@as(u32, 2), store.count());
}

// Test helper: build a solver-precision Vec3r from literals.
fn vec3(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

const ApiVec3 = @import("foundation").math.Vec3;
