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

/// The model transform of bone `i`, resolved by walking UP to the root.
///
/// An oracle that owes the pass nothing: it is defined by the hierarchy alone
/// and evaluates in whatever order recursion reaches, so it cannot agree with a
/// pass that composes the wrong things or visits in the wrong order. The
/// ascending loop's OWN idempotence proves nothing — it is a pure function of
/// its inputs when the two buffers are distinct, so running it twice is
/// bit-identical whatever its body does, including a body that copies.
fn modelByWalkingUp(
    parents: []const BoneIndex,
    local: []const BoneTransform,
    i: usize,
) BoneTransform {
    if (parents[i] == asset_mod.no_parent) return local[i];
    return compose(modelByWalkingUp(parents, local, parents[i]), local[i]);
}

fn expectSameTransform(want: BoneTransform, got: BoneTransform) !void {
    // All TEN scalars. Comparing a subset is how a rotation-order defect hides:
    // `rotation.x/y/z` are exactly the components a wrong composition moves
    // while `w` and the position can stay plausible.
    try testing.expect(got.position.approxEql(want.position, 1e-5));
    try testing.expect(got.scale.approxEql(want.scale, 1e-5));
    try testing.expect(got.rotation.approxEql(want.rotation, 1e-5));
}

test "forward kinematics agrees with resolving each bone up to the root" {
    // **This replaces a test that could not fail.** Its predecessor ran the
    // pass twice and asserted bit equality, on the stated ground that a wrong
    // visiting order would move something on the second run. It would not: the
    // pass is a pure function of `(parents, local)`, so idempotence holds for
    // any body at all — a body reduced to `dst[i] = src[i]` passed it.
    const gpa = testing.allocator;
    const pose = @import("pose.zig");

    const parents = [_]BoneIndex{ asset_mod.no_parent, 0, 1, 1, 3, 0 };
    const local = try pose.alloc(gpa, parents.len);
    defer pose.free(gpa, local);
    const model = try pose.alloc(gpa, parents.len);
    defer pose.free(gpa, model);

    // Rotations about DIFFERENT axes down the chain, and non-uniform scales:
    // a chain turning about one axis cannot see a composition order, and a
    // uniform scale cannot see which side the scale is applied on.
    const axes = [_]Vec3{ Vec3.unit_x, Vec3.unit_y, Vec3.unit_z, v3(1, 1, 0), v3(0, 1, 1), v3(1, 0, 1) };
    for (local.slice(), 0..) |*b, i| {
        const f: f32 = @floatFromInt(i + 1);
        b.* = .{
            .position = v3(f * 0.25, f, -f * 0.5),
            .rotation = Quat.fromAxisAngle(axes[i].normalize(), f * 0.4),
            .scale = v3(1.0 + f * 0.1, 1.0 - f * 0.05, 1.0 + f * 0.07),
        };
    }

    forwardKinematics(&parents, local, model);
    for (model.constSlice(), 0..) |got, i| {
        errdefer std.debug.print("bone {d} diverged from the walk-up oracle\n", .{i});
        try expectSameTransform(modelByWalkingUp(&parents, local.constSlice(), i), got);
    }

    // Non-vacuity: the oracle must not agree with everything. A pass reduced to
    // a copy — the mutant that defeated the predecessor — differs from it on at
    // least one bone of this fixture.
    var disagrees = false;
    for (local.constSlice(), 0..) |copied, i| {
        const walked = modelByWalkingUp(&parents, local.constSlice(), i);
        if (!walked.position.approxEql(copied.position, 1e-5)) disagrees = true;
    }
    try testing.expect(disagrees);
}
