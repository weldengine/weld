//! Kinesis — the Tier 1 animation module.
//!
//! **`init` reaches the Tier 0 through `ModuleContext` and through nothing
//! else**, and the context has four fields for named reasons: `world` is the
//! SINGLE path to components, resources, events and observers, so no second
//! registrar and no second bus is offered or wanted. What this module
//! registers, it registers there.
//!
//! **The module STORES the allocator**, which is the whole reason this type
//! exists in front of the stores below: no entry of a Tier 1 interface takes an
//! allocator as a parameter (`ARCH-013`), because those entries are exercised
//! from Etch through Tier 1 services and an Etch signature carries none. The
//! stores themselves stay unmanaged and take it per call, which is the default
//! this module does not leave (`engine-zig-conventions.md` §3 — Kinesis is not
//! on the allocator-storing whitelist, and only its root is the exception the
//! interface forces).
//!
//! **Poses live HERE, outside the ECS, and the component carries a handle.** A
//! pose is variable-length and a component is POD, so the two cannot be the
//! same object; the precedent is the physics world, which lives outside with a
//! resource carrying the pointer. Do not reach for an ECS change to store a
//! pose.

const std = @import("std");

const core = @import("weld_core");
const anim = @import("weld_interfaces_animation");

const pose_mod = @import("pose.zig");
const components_mod = @import("components.zig");
const asset_mod = @import("asset.zig");
const skeleton_mod = @import("skeleton.zig");

/// The ECS components this module registers.
pub const components = components_mod;
/// Pose allocation and lifetime.
///
/// Named in the plural, and `skeleton_asset` spelled out, because the singular
/// forms collide with the parameter names the interface's own entries carry —
/// `sampleClip(clip, time, pose)` and `createSkeleton(asset)`. A namespace that
/// shadows a parameter is a compile error at the call site that adds the
/// parameter, which is a rename this file would rather not owe later.
pub const poses = pose_mod;
/// The skeleton asset: byte format, reader, and refusals.
pub const skeleton_asset = asset_mod;
/// The runtime hierarchy and its forward kinematics.
pub const skeleton = skeleton_mod;

/// An entity posed against a skeleton.
pub const Skeleton = components_mod.Skeleton;
/// The pose of a skeleton at an instant.
pub const PoseBuffer = anim.PoseBuffer;
/// One bone's transform inside a packed pose.
pub const BoneTransform = anim.BoneTransform;
/// A skeleton instance handle.
pub const SkeletonId = anim.SkeletonId;
/// Index of a bone within its skeleton.
pub const BoneIndex = anim.BoneIndex;
/// The immutable half of a skeleton, shared by every entity posed against it.
pub const Rig = skeleton_mod.Rig;

/// A loaded rig.
///
/// Distinct from `SkeletonId`, which names a per-entity INSTANCE. One rig backs
/// many instances: a hundred characters on one skeleton carry one hierarchy and
/// a hundred poses.
pub const RigId = u32;

/// No rig.
pub const no_rig: RigId = std.math.maxInt(RigId);

/// One live skeleton instance: the poses, and how many bones they hold.
///
/// The two poses are two SPACES and not two copies. `local` holds each bone
/// relative to its parent — what a clip samples into. `model` holds each bone
/// relative to the skeleton root — what forward kinematics derives. The
/// entity's own world placement is a third space and enters neither: it is
/// composed by the consumers, so that a socket read and a skin matrix build do
/// not each have to undo it.
const Instance = struct {
    /// The rig this instance is posed against.
    rig: RigId,
    bone_count: u32,
    local: anim.PoseBuffer,
    model: anim.PoseBuffer,
    /// False once the slot has been destroyed; the slot itself is never
    /// reused, so a stale `SkeletonId` reads as dead rather than as somebody
    /// else's skeleton.
    live: bool,
};

/// The Tier 1 animation module.
pub const KinesisModule = struct {
    const Self = @This();

    /// The allocator received once, at `init`. THE reason this type sits in
    /// front of the stores.
    gpa: std.mem.Allocator,
    /// Loaded rigs, indexed by `RigId`. Monotone for the same reason the
    /// instances are.
    ///
    /// There is no `destroyRig`. Rigs are released at `deinit` and nowhere
    /// else, because the only thing that would free one is unloading its asset
    /// and no asset lifetime reaches this module yet. Adding the entry later
    /// touches no call site — what would NOT be additive is handing out rig ids
    /// that can dangle, which is why the slot is kept rather than recycled.
    rigs: std.ArrayListUnmanaged(Rig) = .empty,
    /// Live skeleton instances, indexed by `SkeletonId`.
    ///
    /// Monotone and never compacted: an id is a position, so recycling a slot
    /// would make a stale handle address a different skeleton with no way for
    /// the holder to tell. A destroyed slot keeps its poses freed and its
    /// `live` flag false.
    instances: std.ArrayListUnmanaged(Instance) = .empty,

    /// Open the module against the Tier 0 context.
    ///
    /// Registers this module's components through `ctx.world` — the single
    /// declarant of that act — and stores the persistent allocator. It
    /// registers no system: a system with no body to run is a mechanism
    /// nothing executes, and the pass that computes model-space poses lands
    /// with the kinematics it drives.
    pub fn init(ctx: *core.ModuleContext) anyerror!Self {
        _ = try ctx.world.ensureComponentRegistered(ctx.persistent_allocator, Skeleton);
        return .{ .gpa = ctx.persistent_allocator };
    }

    /// Release every instance and the poses they own.
    pub fn deinit(self: *Self) void {
        for (self.instances.items) |*inst| {
            if (!inst.live) continue;
            pose_mod.free(self.gpa, inst.local);
            pose_mod.free(self.gpa, inst.model);
            inst.live = false;
        }
        self.instances.deinit(self.gpa);
        for (self.rigs.items) |*loaded| loaded.deinit(self.gpa);
        self.rigs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Read a skeleton asset and keep it as a rig.
    ///
    /// Takes BYTES and not an `AssetHandle`: resolving a handle is the asset
    /// pipeline's, reached through the module registry, and no such route is
    /// wired. This is the entry `createSkeleton` will call once one is.
    pub fn loadRig(self: *Self, bytes: []const u8) anyerror!RigId {
        try self.rigs.ensureUnusedCapacity(self.gpa, 1);
        var parsed = try asset_mod.parse(self.gpa, bytes);
        errdefer parsed.deinit(self.gpa);
        const id: RigId = @intCast(self.rigs.items.len);
        // `fromAsset` ADOPTS the parse's allocations rather than copying them,
        // so the `errdefer` above must not survive this line: two owners of one
        // set of slices is a double free.
        self.rigs.appendAssumeCapacity(Rig.fromAsset(parsed));
        return id;
    }

    /// The rig behind a `RigId`, or null when the id names none.
    pub fn rig(self: *Self, id: RigId) ?*const Rig {
        if (id >= self.rigs.items.len) return null;
        return &self.rigs.items[id];
    }

    /// Instantiate `rig_id`, both poses seeded with its BIND pose.
    ///
    /// Seeded and not left at the identity: an entity whose clip has not been
    /// sampled yet must stand in its bind pose, which is a pose an artist
    /// authored. A skeleton at the identity is a heap of bones at the origin,
    /// and it looks exactly like a sampling bug.
    pub fn instantiate(self: *Self, rig_id: RigId) anyerror!SkeletonId {
        if (rig_id >= self.rigs.items.len) return error.UnknownRig;
        const r = &self.rigs.items[rig_id];
        const bone_count = r.boneCount();

        // Reserve BEFORE allocating the poses: on a failed append the two
        // buffers would already be live with nothing holding them, and the
        // `errdefer` that frees them is one edit away from being forgotten.
        try self.instances.ensureUnusedCapacity(self.gpa, 1);

        const local = try pose_mod.alloc(self.gpa, bone_count);
        errdefer pose_mod.free(self.gpa, local);
        const model = try pose_mod.alloc(self.gpa, bone_count);

        @memcpy(local.slice(), r.bind_local);
        skeleton_mod.forwardKinematics(r.parents, local, model);

        const id: SkeletonId = @intCast(self.instances.items.len);
        self.instances.appendAssumeCapacity(.{
            .rig = rig_id,
            .bone_count = bone_count,
            .local = local,
            .model = model,
            .live = true,
        });
        return id;
    }

    /// Recompute an instance's model-space pose from its local one.
    ///
    /// Answers false when the id names nothing, so a caller that lost track of
    /// an instance learns it here rather than by reading a pose that silently
    /// never moved.
    pub fn updateModelPose(self: *Self, id: SkeletonId) bool {
        const inst = self.instanceMut(id) orelse return false;
        const r = &self.rigs.items[inst.rig];
        skeleton_mod.forwardKinematics(r.parents, inst.local, inst.model);
        return true;
    }

    /// Instantiate a skeleton from its asset.
    ///
    /// Refuses: resolving an `AssetHandle` to bytes is the asset pipeline's,
    /// reached through the module registry, and no such route is wired. The
    /// refusal is typed rather than a zero id — a caller cannot tell instance
    /// zero from "nobody wrote this yet".
    pub fn createSkeleton(self: *Self, asset: anim.AssetHandle) anyerror!SkeletonId {
        _ = self;
        _ = asset;
        return error.NotImplemented;
    }

    /// Release an instance and the poses it owns. Idempotent; a stale or
    /// out-of-range id is ignored.
    pub fn destroySkeleton(self: *Self, id: SkeletonId) void {
        const inst = self.instanceMut(id) orelse return;
        pose_mod.free(self.gpa, inst.local);
        pose_mod.free(self.gpa, inst.model);
        inst.live = false;
    }

    /// How many bones an instance holds; zero for a stale or unknown id.
    ///
    /// Zero is not ambiguous here and that is why it is admissible where it was
    /// not for `createSkeleton`: an instance of zero bones cannot be created —
    /// a skeleton asset with no bones is refused — so zero from this entry
    /// means the id names nothing.
    pub fn getBoneCount(self: *Self, id: SkeletonId) u32 {
        const inst = self.instance(id) orelse return 0;
        return inst.bone_count;
    }

    /// The LOCAL pose of an instance — each bone relative to its parent.
    pub fn localPose(self: *Self, id: SkeletonId) ?anim.PoseBuffer {
        const inst = self.instance(id) orelse return null;
        return inst.local;
    }

    /// The MODEL-space pose of an instance — each bone relative to the
    /// skeleton root, NOT to the world. The entity's `Transform` is composed by
    /// the consumer.
    pub fn modelPose(self: *Self, id: SkeletonId) ?anim.PoseBuffer {
        const inst = self.instance(id) orelse return null;
        return inst.model;
    }

    fn instance(self: *Self, id: SkeletonId) ?*const Instance {
        if (id >= self.instances.items.len) return null;
        const inst = &self.instances.items[id];
        return if (inst.live) inst else null;
    }

    fn instanceMut(self: *Self, id: SkeletonId) ?*Instance {
        if (id >= self.instances.items.len) return null;
        const inst = &self.instances.items[id];
        return if (inst.live) inst else null;
    }
};

comptime {
    // The sub-files carry inline tests and nothing else in the closure
    // references them by name, so the reference is forced here
    // (`engine-zig-conventions.md` §13).
    _ = pose_mod;
    _ = components_mod;
    _ = asset_mod;
    _ = skeleton_mod;
}
