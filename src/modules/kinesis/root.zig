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
const bone_ref_mod = @import("bone_ref.zig");
const sync_mod = @import("sync.zig");

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
/// Bone addressing — the one path from a `BoneRef` to an index.
pub const bone_ref = bone_ref_mod;
/// The ECS seam: publishing the module and registering its per-frame pass.
pub const sync = sync_mod;

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
    ///
    /// **BY VALUE, not by pointer, and that is a lifetime decision rather than
    /// a style one.** `rigs` grows by reallocation, so a `*const Rig` handed
    /// out here is dangling the moment another rig is loaded — and holding one
    /// across a load is exactly what the shipped scenario does. The record is
    /// seven slices whose own pointers are stable across that move, so a copy
    /// is complete and costs one struct copy.
    pub fn rig(self: *Self, id: RigId) ?Rig {
        if (id >= self.rigs.items.len) return null;
        return self.rigs.items[id];
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

    /// The module's per-frame pass: recompute every live instance's
    /// model-space pose from its local one.
    ///
    /// **This is what the registered system drives**, and it is why the pass is
    /// a mechanism rather than an entry point. It walks the module's OWN
    /// instance store and not the entities that carry a `Skeleton`: reaching
    /// those needs a query, and the declared-access view exposes none until its
    /// first consumer — so the pass poses every instance that exists, which is
    /// every instance somebody asked for.
    ///
    /// Allocation-free, hence `void`: the poses were sized when the instance
    /// was created and the pass only writes into them.
    pub fn update(self: *Self) void {
        for (self.instances.items) |*inst| {
            if (!inst.live) continue;
            const r = &self.rigs.items[inst.rig];
            skeleton_mod.forwardKinematics(r.parents, inst.local, inst.model);
        }
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

    /// Resolve a bone reference against an instance's rig — the ONE resolution
    /// path.
    ///
    /// A role the profile does not map resolves to ABSENCE, never to a
    /// neighbouring bone: a solver that cannot find its chain deactivates
    /// instead of moving the wrong one.
    pub fn resolveBone(self: *Self, id: SkeletonId, ref: anim.BoneRef) ?BoneIndex {
        const inst = self.instance(id) orelse return null;
        return bone_ref_mod.resolveBone(self.rigs.items[inst.rig], ref);
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

    // --- Declared, not implemented -------------------------------------------
    //
    // Each REFUSES rather than answering a plausible value. The error channel
    // exists for that refusal and for nothing else: the owner document shows
    // several of these infallible, and the interface file carries why the
    // freeze — not this shape — decides that entry by entry.

    /// Sample `clip` at `time` into `pose`.
    pub fn sampleClip(self: *Self, clip: anim.AssetHandle, time: f32, pose: *anim.PoseBuffer) anyerror!void {
        _ = .{ self, clip, time, pose };
        return error.NotImplemented;
    }

    /// How long `clip` runs, in seconds.
    pub fn getClipDuration(self: *Self, clip: anim.AssetHandle) anyerror!f32 {
        _ = .{ self, clip };
        return error.NotImplemented;
    }

    /// Interpolate `a` towards `b` by `alpha` into `out`.
    pub fn blendPoses(
        self: *Self,
        a: *const anim.PoseBuffer,
        b: *const anim.PoseBuffer,
        alpha: f32,
        out: *anim.PoseBuffer,
    ) anyerror!void {
        _ = .{ self, a, b, alpha, out };
        return error.NotImplemented;
    }

    /// Add `additive` onto `base` by `alpha` into `out`.
    pub fn additivePose(
        self: *Self,
        base: *const anim.PoseBuffer,
        additive: *const anim.PoseBuffer,
        alpha: f32,
        out: *anim.PoseBuffer,
    ) anyerror!void {
        _ = .{ self, base, additive, alpha, out };
        return error.NotImplemented;
    }

    /// The bone matrices the GPU skins with.
    pub fn getSkinMatrices(self: *Self, entity: anim.EntityId) anyerror![]const anim.Mat4 {
        _ = .{ self, entity };
        return error.NotImplemented;
    }

    /// Run one inverse-kinematics request; answers whether it converged.
    pub fn solveIK(self: *Self, entity: anim.EntityId, request: anim.IKRequest) anyerror!bool {
        _ = .{ self, entity, request };
        return error.NotImplemented;
    }

    /// The world transform of a socket.
    pub fn getSocketTransform(self: *Self, entity: anim.EntityId, socket: anim.BoneRef) anyerror!?anim.Transform {
        _ = .{ self, entity, socket };
        return error.NotImplemented;
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
    _ = bone_ref_mod;
    _ = sync_mod;
}
