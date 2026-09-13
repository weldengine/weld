//! Allocation and lifetime of a `PoseBuffer`.
//!
//! The type itself is declared on the interface, because the interface's own
//! signatures name it. What lives here is everything that OWNS one: a pose
//! buffer is variable-length, so it cannot be an ECS component
//! (`engine-zig-conventions.md` §16) and it is not the caller's to free. The
//! module allocates it from the allocator it stored at `init` and hands out a
//! `SkeletonId`; the precedent is the physics world, which lives outside the
//! ECS with a resource carrying the pointer.

const std = @import("std");

const anim = @import("weld_interfaces_animation");

/// One bone's transform inside a packed pose.
pub const BoneTransform = anim.BoneTransform;
/// The pose of a skeleton at an instant.
pub const PoseBuffer = anim.PoseBuffer;

/// Allocate a pose of `bone_count` bones, every bone at the identity.
///
/// The identity fill is not a convenience: an uninitialised rotation is not a
/// unit quaternion, and every composition downstream assumes unit. A buffer
/// handed out with `undefined` rotations produces finite, plausible, wrong
/// world transforms rather than a crash.
pub fn alloc(gpa: std.mem.Allocator, bone_count: u32) !PoseBuffer {
    const bones = try gpa.alloc(BoneTransform, bone_count);
    for (bones) |*b| b.* = .{};
    return .{ .bone_count = bone_count, .bones = bones.ptr };
}

/// Release a pose allocated by `alloc`.
///
/// Takes the buffer by value: it carries its own length, so there is no second
/// place for that length to be wrong.
pub fn free(gpa: std.mem.Allocator, pose: PoseBuffer) void {
    gpa.free(pose.bones[0..pose.bone_count]);
}

/// Copy `src` over `dst`, bone for bone.
///
/// The two must agree on `bone_count`; a partial copy would leave the tail of
/// `dst` holding the previous skeleton's bones, which reads as a pose rather
/// than as an error.
pub fn copy(dst: PoseBuffer, src: PoseBuffer) void {
    std.debug.assert(dst.bone_count == src.bone_count);
    @memcpy(dst.slice(), src.constSlice());
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "an allocated pose is the identity everywhere" {
    const gpa = testing.allocator;
    const p = try alloc(gpa, 5);
    defer free(gpa, p);

    try testing.expectEqual(@as(u32, 5), p.bone_count);
    try testing.expectEqual(@as(usize, 5), p.slice().len);
    for (p.constSlice()) |b| {
        // The rotation is the half that matters: `undefined` here is not a
        // unit quaternion and every composition downstream assumes one.
        try testing.expectEqual(@as(f32, 1), b.rotation.w);
        try testing.expectEqual(@as(f32, 0), b.rotation.x);
        try testing.expect(b.position.approxEql(anim.Vec3.zero, 0));
        try testing.expect(b.scale.approxEql(anim.Vec3.one, 0));
    }
}

test "a zero-bone pose allocates and frees" {
    // The degenerate size is legal — a skeleton asset with no bones is refused
    // at load, but the buffer type has no such rule and must not trap on it.
    const gpa = testing.allocator;
    const p = try alloc(gpa, 0);
    defer free(gpa, p);
    try testing.expectEqual(@as(usize, 0), p.constSlice().len);
}

test "copy transfers every bone" {
    const gpa = testing.allocator;
    const src = try alloc(gpa, 3);
    defer free(gpa, src);
    const dst = try alloc(gpa, 3);
    defer free(gpa, dst);

    for (src.slice(), 0..) |*b, i| {
        b.position = anim.Vec3.fromArray(.{ @floatFromInt(i), 0, 0 });
    }
    copy(dst, src);
    for (dst.constSlice(), 0..) |b, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), b.position.data[0]);
    }
    // The copy must not have aliased: writing the source afterwards must not
    // move the destination.
    src.slice()[0].position = anim.Vec3.fromArray(.{ 99, 0, 0 });
    try testing.expectEqual(@as(f32, 0), dst.constSlice()[0].position.data[0]);
}
