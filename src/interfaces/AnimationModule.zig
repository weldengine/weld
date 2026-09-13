//! `src/interfaces/AnimationModule.zig` — the Tier 1 animation interface.
//!
//! **THIS FILE IS NOT FROZEN, and the attestation below is what says so
//! mechanically.** No `WELD_ANIMATION_PROTOCOL_VERSION` is declared and no
//! comptime surface guard exists; both land with the freeze, together. Until
//! then an entry may be added, removed or re-typed without bumping anything —
//! which is precisely why a reader must not mistake the presence of this file
//! for a settled signature. The test at the foot of this file fails the day a
//! protocol version appears, so the freeze cannot happen by accident: whoever
//! adds the constant is sent to the checklist that owes the guard beside it.
//!
//! **THIS PARAGRAPH AND THAT TEST MOVE TOGETHER.** They are two halves of one
//! claim. A header saying "not frozen" over a guard that freezes, or the
//! reverse, is a file that contradicts itself in the one place a reader trusts.
//!
//! **The types the signatures name are declared HERE**, which is where
//! `engine-tier-interfaces.md` §4 puts them, and the module implements against
//! them rather than the reverse. The physics interface takes its types from a
//! types-only module instead, because Forge's descriptors are ALSO ECS
//! components read by its synchronisation seam and its services — three
//! consumers that must not each pull in a solver. Kinesis has one consumer
//! today. If a second appears that cannot import the implementation, the split
//! Forge made is the shape to copy, and the freeze is when it would cost
//! nothing.
//!
//! **What is real and what is a stub is stated per entry below**, not left to
//! be discovered by calling one. A stub returns `error.NotImplemented`; it
//! never returns a plausible zero, because a caller cannot tell a zero that
//! means "no rotation" from a zero that means "nobody wrote this yet".
//!
//! **The assert block covers what an implementation OWES TODAY, and it grows
//! with the implementation rather than standing complete in advance.** An
//! entry asserted before anything can satisfy it forces a body that returns a
//! plausible answer — which is worse than its absence, because the absence is
//! visible and the plausible answer is not. The block is complete at the
//! freeze and not before; §4 of the owner document lists what it will hold.

const std = @import("std");
const core = @import("weld_core");
const foundation = @import("foundation");

const math = foundation.math;

/// Position, rotation and scale of an entity in world space — the Tier 0
/// component, named here because `getSocketTransform` answers in it.
pub const Transform = core.ecs.components.Transform;
/// Opaque asset handle, ABI-equivalent to `u64`.
pub const AssetHandle = core.rtti.AssetHandle;
/// Entity identifier.
pub const EntityId = core.ecs.EntityId;
/// 3-vector at the pose scalar.
pub const Vec3 = math.Vec3;
/// Unit quaternion at the pose scalar.
pub const Quat = math.Quatf;
/// 4×4 column-major matrix — what `getSkinMatrices` hands the GPU.
pub const Mat4 = math.Mat4f;

/// A skeleton instance created by the module and referenced by the `Skeleton`
/// component.
pub const SkeletonId = u32;

/// No skeleton instance.
///
/// All-ones and NOT zero, because zero is a live id: a field defaulting to `0`
/// would mean "instance 0" everywhere nobody set it, and no bit pattern would
/// be left to mean absence.
pub const no_skeleton: SkeletonId = std.math.maxInt(SkeletonId);

/// Index of a bone within its skeleton. Bones are numbered in the asset's
/// topological order, so a parent's index is always lower than its children's.
pub const BoneIndex = u16;

/// One bone's transform inside a packed pose.
///
/// **The members are `@Vector`-backed and that is the measured half of the
/// layout ruling, not a detail.** The same interleaving over the Tier 0
/// `Transform`, whose members are `[3]f32` / `[4]f32` because it is an
/// `extern struct` POD, measures about 10 % slower on BOTH a pose blend and a
/// forward-kinematics pass — the conversion between a three-element array and
/// a vector sits on every bone of every frame. The entity-facing surface keeps
/// the Tier 0 `Transform`; the packed pose does not.
///
/// It is NOT named `BonePose` and NOT named `SoaTransform`: both are retired
/// names of the BUFFER below, and reusing either rebuilds the three-names-for-
/// one-object confusion the corpus resolved by picking `PoseBuffer`.
pub const BoneTransform = struct {
    /// Translation, in the space the buffer holds.
    position: Vec3 = Vec3.zero,
    /// Rotation, assumed unit.
    rotation: Quat = Quat.identity,
    /// Non-uniform scale.
    scale: Vec3 = Vec3.one,
};

/// The pose of a skeleton at an instant — one `BoneTransform` per bone,
/// interleaved.
///
/// **Interleaved rather than split into per-component arrays, and the number
/// decided it.** The two consumers pull in opposite directions — a blend is
/// bone-independent and a forward-kinematics pass is serialised by the parent
/// chain — so the question was settled by measuring both: interleaving wins the
/// blend at every bone count tried and ties the kinematics. The split form the
/// corpus proposed was argued for on vectorisation, and the only variant that
/// actually vectorises, one scalar array per channel, is the one that loses the
/// blend by a factor of 1.8.
///
/// The buffer is variable-length, so it cannot be a component
/// (`engine-zig-conventions.md` §16): it lives in module-owned storage and the
/// `Skeleton` component carries a `SkeletonId` into it.
pub const PoseBuffer = struct {
    /// How many bones `bones` addresses.
    bone_count: u32 = 0,
    /// The bones, or undefined when `bone_count` is zero. A many-pointer and
    /// not a slice because this type crosses the module boundary and the
    /// storage behind it is owned by the implementation, never by the caller.
    bones: [*]BoneTransform = undefined,

    /// The bones as a slice.
    pub fn slice(self: PoseBuffer) []BoneTransform {
        return self.bones[0..self.bone_count];
    }

    /// The bones as a read-only slice.
    pub fn constSlice(self: PoseBuffer) []const BoneTransform {
        return self.bones[0..self.bone_count];
    }
};

/// The canonical role vocabulary a `SkeletonProfile` maps onto bone indices.
///
/// **APPEND-ONLY: an ordinal is never reassigned, and a retired role keeps
/// its own.** The mapping is written into skeleton assets, so renumbering
/// silently re-points every stored role at a different bone — a save-format
/// break that no compilation notices.
pub const BoneRole = enum(u16) {
    root,
    pelvis,
    spine_01,
    spine_02,
    spine_03,
    neck,
    head,
    clavicle_l,
    upper_arm_l,
    forearm_l,
    hand_l,
    clavicle_r,
    upper_arm_r,
    forearm_r,
    hand_r,
    thigh_l,
    calf_l,
    foot_l,
    toe_l,
    thigh_r,
    calf_r,
    foot_r,
    toe_r,
};

/// How a bone is named across a module interface, a component schema or a rule
/// (`ARCH-033`).
///
/// The literal name stays a legitimate variant — a tentacle or a mech has no
/// role, and demanding one would be absurd. What is imposed is the UNIFORMITY
/// of the addressing type, never the obligation of a role.
pub const BoneRef = union(enum) {
    /// The bone's own name, as the asset spells it.
    name: []const u8,
    /// A role, resolved through the skeleton's optional profile.
    role: BoneRole,
};

/// Which solver `solveIK` runs.
///
/// Declared ahead of its implementations so a typed stub has a parameter type,
/// the same reason the joint types exist on the physics side before the joints
/// do. Nothing here is exercised yet, and the surface is not settled: the
/// freeze owes this enum a decision it has not taken.
pub const IKType = enum {
    two_bone,
    leg_plant,
    fabrik,
    ccd,
    full_body,
    look_at,
    aim_chain,
};

/// One inverse-kinematics request, in ALREADY-RESOLVED addressing.
///
/// It takes `BoneIndex` and not `BoneRef`: symbolic addressing enters the
/// module at `resolveBone` and `getSocketTransform`, never at a solver.
pub const IKRequest = struct {
    ik_type: IKType,
    chain_root: BoneIndex,
    chain_tip: BoneIndex,
    target_position: Vec3,
    target_rotation: ?Quat = null,
    weight: f32 = 1.0,
    /// Bone or socket whose forward axis must reach the target.
    pointer: ?BoneIndex = null,
    /// Hinge axis in the middle bone's local space; `null` infers it from the
    /// bind pose when the chain is assembled.
    bend_axis: ?Vec3 = null,
    /// Distance over which the approach to maximum extension becomes
    /// exponential instead of hard-clamped.
    extension_softening: f32 = 0.005,
};

/// What an implementation refuses when an entry exists on this surface and its
/// body does not.
///
/// A distinct error rather than a plausible answer: a caller cannot tell a zero
/// meaning "no rotation" from a zero meaning "nobody wrote this yet".
pub const NotImplemented = error{NotImplemented};

fn assertFn(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("AnimationModule implementation must declare '" ++ name ++ "'");
    }
    const Actual = @TypeOf(@field(T, name));
    const a = @typeInfo(Actual).@"fn";
    const e = @typeInfo(Expected).@"fn";
    if (a.params.len != e.params.len) {
        @compileError("AnimationModule entry '" ++ name ++ "' has the wrong arity: expected " ++
            std.fmt.comptimePrint("{d}", .{e.params.len}) ++ ", found " ++
            std.fmt.comptimePrint("{d}", .{a.params.len}));
    }
    for (a.params, e.params, 0..) |ap, ep, i| {
        if (ap.type.? != ep.type.?) {
            @compileError("AnimationModule entry '" ++ name ++ "' parameter " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ": expected " ++ @typeName(ep.type.?) ++
                ", found " ++ @typeName(ap.type.?));
        }
    }
    if (a.return_type.? != e.return_type.?) {
        @compileError("AnimationModule entry '" ++ name ++ "' returns " ++
            @typeName(a.return_type.?) ++ ", expected " ++ @typeName(e.return_type.?));
    }
}

/// The Tier 1 animation interface, over an implementation `Impl`.
///
/// The wrapper DELEGATES. A `struct { impl: Impl }` carrying nothing else
/// validates an implementation and exposes none of it, and a test asserting
/// only that the field exists cannot see that.
pub fn AnimationModule(comptime Impl: type) type {
    comptime {
        // --- Lifecycle ---
        assertFn(Impl, "init", fn (*core.ModuleContext) anyerror!Impl);
        assertFn(Impl, "deinit", fn (*Impl) void);

        // --- Skeleton ---
        assertFn(Impl, "createSkeleton", fn (*Impl, AssetHandle) anyerror!SkeletonId);
        assertFn(Impl, "destroySkeleton", fn (*Impl, SkeletonId) void);
        assertFn(Impl, "getBoneCount", fn (*Impl, SkeletonId) u32);
        assertFn(Impl, "resolveBone", fn (*Impl, SkeletonId, BoneRef) ?BoneIndex);
    }

    return struct {
        const Self = @This();

        impl: Impl,

        /// Open the module against the Tier 0 context.
        pub fn init(ctx: *core.ModuleContext) anyerror!Self {
            return .{ .impl = try Impl.init(ctx) };
        }
        /// Release everything the module owns.
        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        /// Instantiate a skeleton from its asset.
        pub fn createSkeleton(self: *Self, asset: AssetHandle) anyerror!SkeletonId {
            return self.impl.createSkeleton(asset);
        }
        /// Release a skeleton instance and the poses it owns.
        pub fn destroySkeleton(self: *Self, id: SkeletonId) void {
            self.impl.destroySkeleton(id);
        }
        /// How many bones a skeleton instance holds.
        pub fn getBoneCount(self: *Self, id: SkeletonId) u32 {
            return self.impl.getBoneCount(id);
        }
        /// Resolve a bone reference — the ONE resolution path (`ARCH-033`). A
        /// role the profile does not map resolves to absence, never to a
        /// neighbouring bone.
        pub fn resolveBone(self: *Self, id: SkeletonId, ref: BoneRef) ?BoneIndex {
            return self.impl.resolveBone(id, ref);
        }
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "this interface is not frozen" {
    // The mechanical half of the header. What breaks if this test is removed:
    // a protocol version lands as an ordinary edit, and the comptime surface
    // guard that must accompany it is never written.
    try testing.expect(!@hasDecl(@This(), "WELD_ANIMATION_PROTOCOL_VERSION"));
}

test "a role ordinal is never reassigned" {
    // Pinned BY VALUE, not by count. A count catches an insertion at the end
    // and misses an insertion in the middle, which is the one that silently
    // re-points every stored mapping at a different bone.
    try testing.expectEqual(@as(u16, 0), @intFromEnum(BoneRole.root));
    try testing.expectEqual(@as(u16, 1), @intFromEnum(BoneRole.pelvis));
    try testing.expectEqual(@as(u16, 6), @intFromEnum(BoneRole.head));
    try testing.expectEqual(@as(u16, 10), @intFromEnum(BoneRole.hand_l));
    try testing.expectEqual(@as(u16, 14), @intFromEnum(BoneRole.hand_r));
    try testing.expectEqual(@as(u16, 18), @intFromEnum(BoneRole.toe_l));
    try testing.expectEqual(@as(u16, 22), @intFromEnum(BoneRole.toe_r));
    try testing.expectEqual(@as(usize, 23), @typeInfo(BoneRole).@"enum".fields.len);
}

test "the absent skeleton is not a live id" {
    // Zero is instance zero. A default of zero would make every unset field
    // point at a real skeleton, which is the shape of defect that a sentinel
    // chosen by habit produces.
    try testing.expect(no_skeleton != 0);
    try testing.expectEqual(std.math.maxInt(SkeletonId), no_skeleton);
}

test "an empty pose buffer yields an empty slice" {
    const empty = PoseBuffer{};
    try testing.expectEqual(@as(usize, 0), empty.constSlice().len);
}
