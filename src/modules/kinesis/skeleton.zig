//! The runtime skeleton: the hierarchy an asset describes, and the forward
//! kinematics that turns local poses into model-space ones.
//!
//! **THREE SPACES, and confusing them is the classic defect of this module.**
//! LOCAL is a bone relative to its parent — what a clip samples into.
//! MODEL is a bone relative to the skeleton root — what the pass below
//! produces. WORLD is model composed with the entity's own `Transform`, and it
//! is produced by the CONSUMERS: the skin-matrix build and the socket read each
//! compose it themselves. Baking the entity transform into this pass would make
//! both of them wrong in a way that looks right on an entity sitting at the
//! origin.
//!
//! **The pass is ONE ascending loop, and the asset invariant is what buys
//! that.** A parent's index is strictly lower than its children's — refused at
//! load otherwise — so by the time bone `i` is reached its parent is already
//! final. No sort, no recursion, no visited set, and no second pass: running the
//! loop twice is a fixed point, which is the mechanical form of the claim and
//! what the acceptance suite asserts.

const std = @import("std");

const anim = @import("weld_interfaces_animation");
const asset_mod = @import("asset.zig");

const BoneIndex = anim.BoneIndex;
const BoneTransform = anim.BoneTransform;
const PoseBuffer = anim.PoseBuffer;
const Mat4 = anim.Mat4;
const Vec3 = anim.Vec3;
const Quat = anim.Quat;

/// The immutable half of a skeleton — everything that comes from the asset and
/// is the same for every entity posed against it.
///
/// Separate from the per-entity poses because it IS shared: a hundred
/// characters on one rig carry one hierarchy and a hundred poses. Owning a copy
/// per entity would not be wrong, only wasteful — but it would also make the
/// sharing a refactor later rather than a store lookup, which is why the split
/// is here rather than promised.
pub const Rig = struct {
    /// Parent of each bone, `asset.no_parent` for the root. Strictly lower than
    /// the bone's own index everywhere else.
    parents: []BoneIndex,
    /// Where each bone's name sits in `name_bytes`.
    name_spans: []asset_mod.SkeletonAsset.NameSpan,
    /// Every bone name, concatenated.
    name_bytes: []u8,
    /// The bind pose, each bone relative to its parent.
    bind_local: []BoneTransform,
    /// The inverse of each bone's bind transform in model space — the second
    /// operand a skin matrix needs.
    inverse_bind: []Mat4,
    /// The role mapping, when the asset carried one.
    profile: ?asset_mod.SkeletonProfile,
    /// Backing storage for `profile.mappings`.
    profile_mappings: []asset_mod.RoleMapping,

    /// How many bones.
    pub fn boneCount(self: Rig) u32 {
        return @intCast(self.parents.len);
    }

    /// The name of bone `i`.
    pub fn boneName(self: Rig, i: BoneIndex) []const u8 {
        const span = self.name_spans[i];
        return self.name_bytes[span.start..][0..span.len];
    }

    /// Take ownership of a parsed asset.
    ///
    /// The asset is consumed by value and its allocations are adopted rather
    /// than copied: a `Rig` is what a parsed asset becomes, not a second copy
    /// of it, and two owners of one set of slices is a double free waiting for
    /// a reader to introduce it.
    pub fn fromAsset(a: asset_mod.SkeletonAsset) Rig {
        return .{
            .parents = a.parents,
            .name_spans = a.name_spans,
            .name_bytes = a.name_bytes,
            .bind_local = a.bind_local,
            .inverse_bind = a.inverse_bind,
            .profile = a.profile,
            .profile_mappings = a.profile_mappings,
        };
    }

    /// Release everything the rig owns.
    pub fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
        gpa.free(self.parents);
        gpa.free(self.name_spans);
        gpa.free(self.name_bytes);
        gpa.free(self.bind_local);
        gpa.free(self.inverse_bind);
        gpa.free(self.profile_mappings);
        self.* = undefined;
    }
};

/// Compose a parent's transform with a child's local one.
///
/// **This is the TRS composition, and it is an APPROXIMATION whenever a
/// non-uniform scale meets a rotation that does not permute its axes.** The
/// exact product of two transforms carrying non-uniform scale contains shear,
/// and shear is not expressible as translation-rotation-scale — so an exact
/// pipeline would have to carry matrices, which a pose cannot: a matrix does
/// not blend, and blending is the operation the pose type exists for. Every
/// skeletal animation system makes this trade; what is unusual is writing it
/// down. The acceptance suite pins the choice with a case where the two forms
/// visibly differ, so switching to matrices is a decision someone takes rather
/// than a diff that slips through.
pub fn compose(parent: BoneTransform, local: BoneTransform) BoneTransform {
    return .{
        .position = parent.position.add(parent.rotation.rotateVec3(local.position.mul(parent.scale))),
        .rotation = parent.rotation.mul(local.rotation),
        .scale = parent.scale.mul(local.scale),
    };
}

/// Fill `model` with each bone relative to the skeleton ROOT, from `local`.
///
/// One ascending pass. The caller's three arrays must agree on length, and the
/// hierarchy must satisfy the asset invariant — both are the loader's
/// guarantees and both are asserted rather than re-derived here, because
/// re-deriving them per frame is what the load-time refusal exists to avoid.
pub fn forwardKinematics(parents: []const BoneIndex, local: PoseBuffer, model: PoseBuffer) void {
    std.debug.assert(local.bone_count == model.bone_count);
    std.debug.assert(parents.len == local.bone_count);

    const src = local.constSlice();
    const dst = model.slice();
    if (dst.len == 0) return;

    // The root takes its local transform unchanged: model space IS the root's
    // space, so composing anything onto it would place the skeleton somewhere
    // the entity transform is then asked to place it a second time.
    dst[0] = src[0];
    for (1..dst.len) |i| {
        const p = parents[i];
        std.debug.assert(p < i);
        dst[i] = compose(dst[p], src[i]);
    }
}

/// The model-space transform each bone holds in the bind pose.
///
/// Derived by running the pass over the bind pose, which is what makes the
/// stored inverse-bind matrices checkable: their product with these is the
/// identity for any asset whose bind pose and rest pose coincide.
pub fn bindModelPose(rig: Rig, out: PoseBuffer) void {
    std.debug.assert(out.bone_count == rig.boneCount());
    @memcpy(out.slice(), rig.bind_local);
    forwardKinematics(rig.parents, out, out);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3.fromArray(.{ x, y, z });
}

test "compose places a child through its parent's rotation and scale" {
    // Parent: two metres up, a quarter turn about +Z, scale (2, 3, 1).
    // Child: one metre along its own +Y.
    //
    // The parent's scale acts on the child's offset FIRST, in the parent's own
    // frame: (0,1,0) becomes (0,3,0), and the quarter turn about +Z sends +Y to
    // -X, so the child lands three metres along -X of the parent.
    const parent = BoneTransform{
        .position = v3(0, 2, 0),
        .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0),
        .scale = v3(2, 3, 1),
    };
    const child = BoneTransform{ .position = v3(0, 1, 0) };
    const out = compose(parent, child);

    try testing.expect(out.position.approxEql(v3(-3, 2, 0), 1e-5));
    try testing.expect(out.scale.approxEql(v3(2, 3, 1), 1e-6));
    try testing.expect(out.rotation.approxEql(parent.rotation, 1e-6));
}

test "composition applies the parent's rotation to the child's, in that order" {
    // **Found by counter-factual: reversing the two operands changed nothing
    // that any test observed.** A chain whose bones rotate about ONE axis, or
    // whose children carry the identity, cannot see the order — quaternion
    // multiplication commutes for parallel axes and trivially for the identity,
    // and the acceptance chain has both properties. This fixture has neither.
    const p = BoneTransform{ .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0) };
    const c = BoneTransform{ .rotation = Quat.fromAxisAngle(Vec3.unit_x, std.math.pi / 2.0) };
    const got = compose(p, c);

    // The oracle is SEQUENTIAL APPLICATION and not the same product written
    // twice: rotating a vector by the child and then by the parent is what
    // "the child's rotation expressed in the parent's frame" means, and it owes
    // nothing to how `compose` spells it.
    const v = v3(1, 2, 3);
    try testing.expect(got.rotation.rotateVec3(v).approxEql(p.rotation.rotateVec3(c.rotation.rotateVec3(v)), 1e-5));

    // The discrimination guard, without which the assertion above would also
    // hold for the reversed order: the two orders must really differ on this
    // fixture.
    const reversed = c.rotation.mul(p.rotation);
    try testing.expect(!reversed.rotateVec3(v).approxEql(got.rotation.rotateVec3(v), 1e-3));
}

test "the TRS composition is not the matrix product under sheared scale" {
    // The contract this file states, pinned. A non-uniform parent scale under a
    // rotation that does NOT permute its axes produces shear, and the TRS form
    // cannot carry shear — so the two answers differ. The assertion is on the
    // DIFFERENCE: what breaks if this test is removed is that a later change to
    // matrix composition reads as a refactor instead of as the decision it is.
    const parent = BoneTransform{
        .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 4.0),
        .scale = v3(3, 1, 1),
    };
    const child = BoneTransform{
        .position = v3(1, 0, 0),
        .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 4.0),
    };

    const trs = compose(parent, child);
    const exact = Mat4.fromTrs(parent.position, parent.rotation, parent.scale)
        .mul(Mat4.fromTrs(child.position, child.rotation, child.scale));

    // Positions still agree — the offset passes through the same operations
    // either way — which is what makes this test about the BASIS and not about
    // arithmetic noise.
    try testing.expect(trs.position.approxEql(exact.translation(), 1e-5));

    // The basis does not. Column 1 of the exact product is the sheared image of
    // +Y; the TRS form gives a rotated, axis-scaled one.
    const trs_mat = Mat4.fromTrs(trs.position, trs.rotation, trs.scale);
    try testing.expect(!trs_mat.axis(1).approxEql(exact.axis(1), 1e-3));
}

test "forward kinematics reaches its fixed point in one pass" {
    // The mechanical form of "a single linear pass". If the ordering were wrong
    // — a parent evaluated after its child — a second pass would move something,
    // because the child would finally see a final parent. Bit equality after a
    // second run is what says the first one was enough.
    const gpa = testing.allocator;
    const pose = @import("pose.zig");

    const parents = [_]BoneIndex{ asset_mod.no_parent, 0, 1, 1, 3 };
    const local = try pose.alloc(gpa, parents.len);
    defer pose.free(gpa, local);
    const model = try pose.alloc(gpa, parents.len);
    defer pose.free(gpa, model);

    for (local.slice(), 0..) |*b, i| {
        const f: f32 = @floatFromInt(i + 1);
        b.* = .{
            .position = v3(f * 0.25, f, -f * 0.5),
            .rotation = Quat.fromAxisAngle(v3(0.3, 1, 0.2).normalize(), f * 0.4),
            .scale = v3(1.0 + f * 0.1, 1.0, 1.0 + f * 0.05),
        };
    }

    forwardKinematics(&parents, local, model);
    var first: [5]BoneTransform = undefined;
    @memcpy(&first, model.constSlice());

    forwardKinematics(&parents, local, model);
    for (model.constSlice(), first) |after, before| {
        try testing.expectEqual(before.position.data[0], after.position.data[0]);
        try testing.expectEqual(before.position.data[1], after.position.data[1]);
        try testing.expectEqual(before.position.data[2], after.position.data[2]);
        try testing.expectEqual(before.rotation.w, after.rotation.w);
        try testing.expectEqual(before.scale.data[0], after.scale.data[0]);
    }
}
