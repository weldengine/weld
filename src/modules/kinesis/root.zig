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

/// The ECS components this module registers.
pub const components = components_mod;
/// Pose allocation and lifetime.
pub const pose = pose_mod;

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

/// One live skeleton instance: the poses, and how many bones they hold.
///
/// The two poses are two SPACES and not two copies. `local` holds each bone
/// relative to its parent — what a clip samples into. `model` holds each bone
/// relative to the skeleton root — what forward kinematics derives. The
/// entity's own world placement is a third space and enters neither: it is
/// composed by the consumers, so that a socket read and a skin matrix build do
/// not each have to undo it.
const Instance = struct {
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
        self.* = undefined;
    }

    /// Create an instance of `bone_count` bones, both poses at the identity.
    ///
    /// This is the entry the asset path builds on: parsing a skeleton produces
    /// a bone count and a hierarchy, and the hierarchy joins the record here
    /// rather than in a second store keyed by the same id.
    pub fn createSkeletonInstance(self: *Self, bone_count: u32) anyerror!SkeletonId {
        // Reserve BEFORE allocating the poses: on a failed append the two
        // buffers would already be live with nothing holding them, and the
        // `errdefer` that frees them is one edit away from being forgotten.
        try self.instances.ensureUnusedCapacity(self.gpa, 1);

        const local = try pose_mod.alloc(self.gpa, bone_count);
        errdefer pose_mod.free(self.gpa, local);
        const model = try pose_mod.alloc(self.gpa, bone_count);

        const id: SkeletonId = @intCast(self.instances.items.len);
        self.instances.appendAssumeCapacity(.{
            .bone_count = bone_count,
            .local = local,
            .model = model,
            .live = true,
        });
        return id;
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
}
