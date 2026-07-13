//! `foundation/math/aabb.zig` — generic axis-aligned bounding box `Aabb(T)`.
//!
//! Stored as its minimum and maximum corners over 3-vectors. Face contact
//! counts as overlap / containment (inclusive `<=`), the convention broadphase
//! wants.

const std = @import("std");
const vec = @import("vec.zig");

/// Axis-aligned bounding box over 3-vectors of scalar `T`, stored as its
/// minimum and maximum corners.
pub fn Aabb(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = vec.Vec(3, T);

        /// Minimum corner (componentwise smallest).
        min: Vec3T,
        /// Maximum corner (componentwise largest).
        max: Vec3T,

        /// Box from explicit min/max corners.
        pub fn fromMinMax(min_corner: Vec3T, max_corner: Vec3T) Self {
            return .{ .min = min_corner, .max = max_corner };
        }

        /// Box from a center and (non-negative) half-extents.
        pub fn fromCenterHalfExtents(center_point: Vec3T, half_extents: Vec3T) Self {
            return .{ .min = center_point.sub(half_extents), .max = center_point.add(half_extents) };
        }

        /// Smallest box containing both `self` and `other`.
        pub fn merge(self: Self, other: Self) Self {
            return .{ .min = self.min.min(other.min), .max = self.max.max(other.max) };
        }

        /// Box grown to include `point`.
        pub fn expand(self: Self, point: Vec3T) Self {
            return .{ .min = self.min.min(point), .max = self.max.max(point) };
        }

        /// Whether `point` lies inside (inclusive of the faces).
        pub fn contains(self: Self, point: Vec3T) bool {
            return @reduce(.And, self.min.data <= point.data) and
                @reduce(.And, point.data <= self.max.data);
        }

        /// Whether `self` and `other` intersect (touching faces count).
        pub fn overlaps(self: Self, other: Self) bool {
            return @reduce(.And, self.min.data <= other.max.data) and
                @reduce(.And, other.min.data <= self.max.data);
        }

        /// Geometric center.
        pub fn center(self: Self) Vec3T {
            return self.min.add(self.max).scale(0.5);
        }

        /// Half the size along each axis.
        pub fn halfExtents(self: Self) Vec3T {
            return self.max.sub(self.min).scale(0.5);
        }

        /// Surface area `2·(dx·dy + dy·dz + dz·dx)` where `d = max - min`.
        /// The SAH cost metric the broadphase BVH descends on. A degenerate
        /// (zero-extent) box returns 0.
        pub fn surfaceArea(self: Self) T {
            const d = self.max.sub(self.min).toArray();
            return 2 * (d[0] * d[1] + d[1] * d[2] + d[2] * d[0]);
        }
    };
}

/// f32 axis-aligned bounding box.
pub const Aabbf = Aabb(f32);

const testing = std.testing;
const Vec3 = vec.Vec3;

test "merge contains overlaps truth table" {
    const a = Aabbf.fromMinMax(Vec3.zero, Vec3.one);
    const disjoint = Aabbf.fromMinMax(Vec3.splat(2), Vec3.splat(3));
    const touching = Aabbf.fromMinMax(Vec3.one, Vec3.splat(2)); // shares corner (1,1,1)
    const nested = Aabbf.fromMinMax(Vec3.splat(0.25), Vec3.splat(0.75));

    try testing.expect(!a.overlaps(disjoint));
    try testing.expect(a.overlaps(touching)); // inclusive faces
    try testing.expect(a.overlaps(nested));
    try testing.expect(nested.overlaps(a));

    try testing.expect(a.contains(Vec3.splat(0.5)));
    try testing.expect(a.contains(Vec3.zero)); // face-inclusive
    try testing.expect(!a.contains(Vec3.splat(1.5)));

    const m = a.merge(disjoint);
    try testing.expect(m.min.approxEql(Vec3.zero, 1e-6));
    try testing.expect(m.max.approxEql(Vec3.splat(3), 1e-6));
}

test "center halfExtents and fromCenterHalfExtents" {
    const box = Aabbf.fromCenterHalfExtents(Vec3.fromArray(.{ 1, 2, 3 }), Vec3.splat(0.5));
    try testing.expect(box.center().approxEql(Vec3.fromArray(.{ 1, 2, 3 }), 1e-6));
    try testing.expect(box.halfExtents().approxEql(Vec3.splat(0.5), 1e-6));
    try testing.expect(box.min.approxEql(Vec3.fromArray(.{ 0.5, 1.5, 2.5 }), 1e-6));
    try testing.expect(box.max.approxEql(Vec3.fromArray(.{ 1.5, 2.5, 3.5 }), 1e-6));
}

test "expand grows the box to include a point" {
    var box = Aabbf.fromMinMax(Vec3.zero, Vec3.one);
    box = box.expand(Vec3.fromArray(.{ -1, 2, 0.5 }));
    try testing.expect(box.min.approxEql(Vec3.fromArray(.{ -1, 0, 0 }), 1e-6));
    try testing.expect(box.max.approxEql(Vec3.fromArray(.{ 1, 2, 1 }), 1e-6));
}

test "generic Aabb f64 instantiation compiles" {
    const A = Aabb(f64);
    const V = vec.Vec(3, f64);
    const box = A.fromCenterHalfExtents(V.zero, V.splat(2));
    try testing.expect(box.contains(V.fromArray(.{ 1, -1, 2 })));
    try testing.expect(!box.contains(V.fromArray(.{ 3, 0, 0 })));
}

test "surfaceArea" {
    // 2 × 3 × 4 box → 2·(2·3 + 3·4 + 4·2) = 2·(6 + 12 + 8) = 52.
    const box = Aabbf.fromMinMax(Vec3.zero, Vec3.fromArray(.{ 2, 3, 4 }));
    try testing.expectApproxEqAbs(@as(f32, 52), box.surfaceArea(), 1e-4);
    // Offset from the origin must not change the extents.
    const shifted = Aabbf.fromMinMax(Vec3.fromArray(.{ 5, 5, 5 }), Vec3.fromArray(.{ 7, 8, 9 }));
    try testing.expectApproxEqAbs(@as(f32, 52), shifted.surfaceArea(), 1e-4);
    // Degenerate (zero-extent) box → 0.
    const point = Aabbf.fromMinMax(Vec3.one, Vec3.one);
    try testing.expectEqual(@as(f32, 0), point.surfaceArea());
    // A flat (zero-thickness) box has two faces of area dx·dz: 2·(2·0 + 0·4 + 4·2) = 16.
    const flat = Aabbf.fromMinMax(Vec3.zero, Vec3.fromArray(.{ 2, 0, 4 }));
    try testing.expectApproxEqAbs(@as(f32, 16), flat.surfaceArea(), 1e-4);
}
