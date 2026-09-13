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
//! **THE PASS PRODUCES MATRICES, AND THAT IS A CORRECTNESS DECISION.** It used
//! to compose translation-rotation-scale into translation-rotation-scale, which
//! accumulates the scales componentwise — right only when no rotation between
//! two bones reorients the scale axes. Under a rotated child the accumulated
//! scale has no frame, and the position derived from it is wrong BY THE SCALE
//! FACTOR: measured, a root scaled `(3, 1, 1)` with a quarter-turned child put
//! its grandchild at `(0, 3, 0)` where the matrix product puts it at
//! `(0, 1, 0)`. A comment on that composition documented an approximation about
//! SHEAR — which is genuinely inexpressible in TRS — and a documented
//! approximation on one quantity does not cover an error on another. The
//! position is exact in every case, shear included.
//!
//! **The pass is ONE ascending loop, and the asset invariant is what buys
//! that.** A parent's index is strictly lower than its children's — refused at
//! load otherwise — so by the time bone `i` is reached its parent is already
//! final. No sort, no recursion, no visited set.

const std = @import("std");

const anim = @import("weld_interfaces_animation");
const asset_mod = @import("asset.zig");

const BoneIndex = anim.BoneIndex;
const BoneTransform = anim.BoneTransform;
const PoseBuffer = anim.PoseBuffer;
const ModelPose = anim.ModelPose;
const Mat4 = anim.Mat4;
const Vec3 = anim.Vec3;
const Quat = anim.Quat;

/// The OWNED half of a skeleton — everything that comes from the asset and is
/// the same for every entity posed against it.
///
/// Separate from the per-entity poses because it IS shared: a hundred
/// characters on one rig carry one hierarchy and a hundred poses. Owning a copy
/// per entity would not be wrong, only wasteful — but it would also make the
/// sharing a refactor later rather than a store lookup, which is why the split
/// is here rather than promised.
///
/// **THIS TYPE IS THE OWNER AND IT IS NOT WHAT A CALLER RECEIVES.** It carries
/// mutable slices and a `deinit`, which is exactly right for the store that
/// holds it and exactly wrong for anyone reading it: a handed-out copy is a
/// second holder of the same seven allocations, so writing through it bypasses
/// every check the loader ran and calling `deinit` on it frees memory the
/// module still believes it owns — both of them silent. `view()` is what
/// leaves; see `RigView`, whose `[]const` slices and absent destructor make
/// each of those two a COMPILE error rather than a rule someone must remember.
///
/// Zig has no module-private declaration, so `pub` here is a reachability fact
/// and not a permission — stated rather than claimed away, the same limit
/// `bone_ref.zig` records for itself. What the split gives is that the OWNING
/// type never leaves an entry's return type, which is checkable and is checked.
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

    /// A read-only view of this rig — what every consumer outside the store
    /// gets, and the only shape that crosses a module entry.
    ///
    /// `profile_mappings` is deliberately NOT carried across: it is the backing
    /// storage `deinit` frees and has no meaning to a reader, so its absence is
    /// part of the separation rather than an omission. The profile itself
    /// crosses whole — its `mappings` is already `[]const`.
    pub fn view(self: Rig) RigView {
        return .{
            .parents = self.parents,
            .name_spans = self.name_spans,
            .name_bytes = self.name_bytes,
            .bind_local = self.bind_local,
            .inverse_bind = self.inverse_bind,
            .profile = self.profile,
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

/// A rig as a READER sees it: the same seven-field record minus its ownership.
///
/// **TWO TYPES AND NOT ONE, and the difference is the whole point.** Every
/// slice is `[]const`, so `v.parents[1] = 127` does not compile — a write that
/// would bypass the load-time validation that established the hierarchy's
/// invariants in the first place. There is no `deinit`, so `v.deinit(gpa)` does
/// not compile either — a free that would take the module's own memory with it
/// and leave the store holding released slices. Neither is a convention: both
/// are refused by the compiler, and the counter-proof corpus pins each with its
/// own diagnostic beside a control that still compiles.
///
/// It is copied by value for the reason `Rig` cannot be handed out by pointer:
/// the store grows by reallocation, so a `*const Rig` is dangling the moment
/// another rig is loaded. The slices it carries are stable across that move —
/// what moves is the record, not what it points at — so the copy is complete
/// and costs one struct copy.
pub const RigView = struct {
    /// Parent of each bone, `asset.no_parent` for the root. Strictly lower than
    /// the bone's own index everywhere else.
    parents: []const BoneIndex,
    /// Where each bone's name sits in `name_bytes`.
    name_spans: []const asset_mod.SkeletonAsset.NameSpan,
    /// Every bone name, concatenated.
    name_bytes: []const u8,
    /// The bind pose, each bone relative to its parent.
    bind_local: []const BoneTransform,
    /// The inverse of each bone's bind transform in model space.
    inverse_bind: []const Mat4,
    /// The role mapping, when the asset carried one.
    profile: ?asset_mod.SkeletonProfile,

    /// How many bones.
    pub fn boneCount(self: RigView) u32 {
        return @intCast(self.parents.len);
    }

    /// The name of bone `i`.
    pub fn boneName(self: RigView, i: BoneIndex) []const u8 {
        const span = self.name_spans[i];
        return self.name_bytes[span.start..][0..span.len];
    }
};

/// The matrix of one bone's local transform.
///
/// The single place a `BoneTransform` becomes a `Mat4`; everything downstream of
/// the pass is matrices, so there is no second conversion to keep in step.
pub fn localMatrix(b: BoneTransform) Mat4 {
    return Mat4.fromTrs(b.position, b.rotation, b.scale);
}

/// Fill `model` with each bone's transform relative to the skeleton ROOT, from
/// the local pose `local`.
///
/// One ascending pass, composing MATRICES: `model[i] = model[parent] · local[i]`.
/// Matrix composition carries shear, which is what makes the result exact for
/// every hierarchy rather than for the ones whose rotations happen to permute
/// their parents' scale axes.
///
/// The caller's three arrays must agree on length and the hierarchy must satisfy
/// the asset invariant — both are the loader's guarantees, asserted here rather
/// than re-derived per frame.
pub fn forwardKinematics(parents: []const BoneIndex, local: PoseBuffer, model: ModelPose) void {
    std.debug.assert(local.bone_count == model.bone_count);
    std.debug.assert(parents.len == local.bone_count);

    const src = local.constSlice();
    const dst = model.slice();
    if (dst.len == 0) return;

    // The root takes its own local matrix: model space IS the root's space, so
    // composing anything onto it would place the skeleton somewhere the entity
    // transform is then asked to place it a second time.
    dst[0] = localMatrix(src[0]);
    for (1..dst.len) |i| {
        const p = parents[i];
        std.debug.assert(p < i);
        dst[i] = dst[p].mul(localMatrix(src[i]));
    }
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3.fromArray(.{ x, y, z });
}

/// The model matrix of bone `i`, resolved by walking UP to the root.
///
/// An oracle that owes the pass nothing: it is defined by the hierarchy alone and
/// evaluates in whatever order recursion reaches, so it cannot agree with a pass
/// that composes the wrong things or visits in the wrong order. The ascending
/// loop's OWN idempotence proves nothing — it is a pure function of its inputs, so
/// running it twice is bit-identical whatever its body does, including a body that
/// copies.
fn modelByWalkingUp(
    parents: []const BoneIndex,
    local: []const BoneTransform,
    i: usize,
) Mat4 {
    const own = localMatrix(local[i]);
    if (parents[i] == asset_mod.no_parent) return own;
    return modelByWalkingUp(parents, local, parents[i]).mul(own);
}

test "forward kinematics agrees with resolving each bone up to the root" {
    const gpa = testing.allocator;
    const pose = @import("pose.zig");

    const parents = [_]BoneIndex{ asset_mod.no_parent, 0, 1, 1, 3, 0 };
    const local = try pose.alloc(gpa, parents.len);
    defer pose.free(gpa, local);
    const model = try pose.allocModel(gpa, parents.len);
    defer pose.freeModel(gpa, model);

    // Rotations about DIFFERENT axes down the chain, and non-uniform scales: a
    // chain turning about one axis cannot see a composition order, and a uniform
    // scale cannot see which side the scale is applied on.
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
        try testing.expect(got.approxEql(modelByWalkingUp(&parents, local.constSlice(), i), 1e-4));
    }

    // Non-vacuity: the oracle must not agree with everything. A pass reduced to
    // converting each local transform on its own — the mutant a weaker test lets
    // through — differs from it on at least one bone of this fixture.
    var disagrees = false;
    for (local.constSlice(), 0..) |b, i| {
        if (!localMatrix(b).approxEql(modelByWalkingUp(&parents, local.constSlice(), i), 1e-4)) {
            disagrees = true;
        }
    }
    try testing.expect(disagrees);
}

test "an accumulated scale does not survive a rotated child" {
    // **THE DEFECT THAT SENT THIS PASS TO MATRICES, pinned.** The root is scaled
    // on +X alone and the child is turned a quarter turn about +Z, so the
    // grandchild's own +X offset arrives along the root's +Y — an axis the root's
    // scale does NOT stretch. A translation-rotation-scale composition multiplies
    // the scales componentwise and has no way to know that, so it stretched the
    // offset by three; the matrix product does not.
    const gpa = testing.allocator;
    const pose = @import("pose.zig");

    const parents = [_]BoneIndex{ asset_mod.no_parent, 0, 1 };
    const local = try pose.alloc(gpa, 3);
    defer pose.free(gpa, local);
    const model = try pose.allocModel(gpa, 3);
    defer pose.freeModel(gpa, model);

    local.slice()[0] = .{ .scale = v3(3, 1, 1) };
    local.slice()[1] = .{ .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0) };
    local.slice()[2] = .{ .position = v3(1, 0, 0) };

    forwardKinematics(&parents, local, model);
    const got = model.constSlice()[2].translation();
    try testing.expect(got.approxEql(v3(0, 1, 0), 1e-5));

    // The discrimination guard: the wrong answer and the right one differ by the
    // whole scale factor, so a fixture where they coincided would pin nothing.
    try testing.expect(!got.approxEql(v3(0, 3, 0), 1e-2));
}

test "composition applies the parent's transform to the child's, in that order" {
    // Order, on two rotations about non-parallel axes — quaternion and matrix
    // products both commute for parallel axes and trivially for the identity,
    // so a chain with either property cannot see an inversion.
    const gpa = testing.allocator;
    const pose = @import("pose.zig");

    const parents = [_]BoneIndex{ asset_mod.no_parent, 0 };
    const local = try pose.alloc(gpa, 2);
    defer pose.free(gpa, local);
    const model = try pose.allocModel(gpa, 2);
    defer pose.freeModel(gpa, model);

    local.slice()[0] = .{ .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0) };
    local.slice()[1] = .{
        .position = v3(1, 2, 3),
        .rotation = Quat.fromAxisAngle(Vec3.unit_x, std.math.pi / 2.0),
    };
    forwardKinematics(&parents, local, model);

    // The oracle is SEQUENTIAL APPLICATION: the child's offset expressed in the
    // parent's frame is the parent rotating what the child produced, and it owes
    // nothing to how the pass spells its product.
    const parent_rot = local.constSlice()[0].rotation;
    const want = parent_rot.rotateVec3(local.constSlice()[1].position);
    try testing.expect(model.constSlice()[1].translation().approxEql(want, 1e-5));

    // Discrimination guard: the reversed order really differs on this fixture.
    const reversed = localMatrix(local.constSlice()[1]).mul(localMatrix(local.constSlice()[0]));
    try testing.expect(!reversed.translation().approxEql(want, 1e-3));
}
