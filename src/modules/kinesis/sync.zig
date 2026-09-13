//! The ECS seam: publishing the module into a `World`, and the registered
//! system that drives its per-frame pass.
//!
//! **The module lives OUTSIDE the ECS and a resource carries the pointer.** A
//! pose is variable-length, so neither it nor the store that owns it can be a
//! component; what the ECS holds is a `Skeleton` component carrying a handle
//! and, here, a resource carrying the address of the store those handles index.
//! The precedent is the physics seam, which publishes its world the same way
//! and for the same reason.
//!
//! **The registered system is what makes the pass a MECHANISM rather than an
//! entry point.** Without it `update` is a public function with one caller and
//! that caller is a test — the shape this repository names as a mechanism
//! nothing executes. It is also what makes the declared-access view the module
//! is built on load-bearing here rather than merely available.
//!
//! **The system declares the RESOURCE and no component, and that is honest
//! rather than minimal.** A pass driven by the entities that carry a `Skeleton`
//! would declare a read of it — but reaching them needs a query, and the
//! declared-access view deliberately exposes none until its first consumer.
//! Adding one is a Tier 0 change and belongs to whoever needs it. Until then
//! the pass walks the module's own instance store, and its declaration says so.

const std = @import("std");

const core = @import("weld_core");

const root = @import("root.zig");

const World = core.ecs.World;
const SystemScheduler = core.ecs.SystemScheduler;
const Access = core.ecs.Access;
const KinesisModule = root.KinesisModule;

/// The published address of a live `KinesisModule`.
///
/// POD `extern struct` because it IS a resource, and raw integers because a
/// resource cannot own anything: the module's lifetime is its publisher's, and
/// this record only says where it is.
pub const KinesisModuleRef = extern struct {
    module: usize = 0,

    fn pack(m: *KinesisModule) KinesisModuleRef {
        return .{ .module = @intFromPtr(m) };
    }

    fn modulePtr(self: KinesisModuleRef) ?*KinesisModule {
        if (self.module == 0) return null;
        return @ptrFromInt(self.module);
    }
};

fn resolve(ecs: anytype) ?KinesisModuleRef {
    const bytes = ecs.resourceBytes(KinesisModuleRef) orelse return null;
    if (bytes.len != @sizeOf(KinesisModuleRef)) return null;
    var ref: KinesisModuleRef = undefined;
    // Copied out rather than pointer-cast: the resource store hands back a byte
    // slice whose alignment is the store's and not this type's.
    @memcpy(std.mem.asBytes(&ref), bytes);
    if (ref.module == 0) return null;
    return ref;
}

/// Publish `module` into `ecs` so the registered system can find it.
///
/// **REFUSES to replace a live publication.** A silent replacement makes the
/// first module disappear without anyone having withdrawn it, and the frames
/// that follow drive a module its owner believes is still wired. Withdraw
/// first, then publish — the two entries are a pair.
pub fn publishModule(gpa: std.mem.Allocator, ecs: *World, module: *KinesisModule) !void {
    const id = try ecs.ensureComponentRegistered(gpa, KinesisModuleRef);
    const ref = KinesisModuleRef.pack(module);
    if (ecs.resources.getMutResource(id)) |slot| {
        if (slot.len != @sizeOf(KinesisModuleRef)) return error.ModuleAlreadyPublished;
        var current: KinesisModuleRef = undefined;
        @memcpy(std.mem.asBytes(&current), slot);
        if (current.module != 0) return error.ModuleAlreadyPublished;
        @memcpy(slot, std.mem.asBytes(&ref));
        return;
    }
    try ecs.addResource(gpa, id, std.mem.asBytes(&ref));
}

/// Withdraw the published module — the symmetric half of `publishModule`, and
/// the caller that published is the one that withdraws.
///
/// **Without it the resource outlives the module it names.** Publishing writes a
/// raw address, `deinit` frees and poisons, and a resource nobody cleared keeps
/// answering with a dead one.
///
/// **`expected` is CHECKED, and that is the other half of the same defect.** A
/// withdrawal that cleared whatever it found would let a late teardown erase a
/// module published after it — publish A, publish B, then run A's cleanup, and
/// every frame afterwards is a silent no-op. Finding someone else's address is
/// a NO-OP rather than a refusal, matching the tree's treatment of an
/// unhandleable handle on a teardown path.
pub fn withdrawModule(ecs: *World, expected: *KinesisModule) void {
    const id = ecs.componentId(@typeName(KinesisModuleRef)) orelse return;
    const slot = ecs.resources.getMutResource(id) orelse return;
    if (slot.len != @sizeOf(KinesisModuleRef)) return;
    var current: KinesisModuleRef = undefined;
    @memcpy(std.mem.asBytes(&current), slot);
    if (current.module != @intFromPtr(expected)) return;
    const empty = KinesisModuleRef{};
    @memcpy(slot, std.mem.asBytes(&empty));
}

/// The module published into `ecs`, or null if none is.
///
/// Answers with the IDENTITY and not a boolean, because a boolean cannot tell
/// "B is still published" from "B was erased and something else answers".
pub fn publishedModule(ecs: *World) ?*KinesisModule {
    const ref = resolve(ecs) orelse return null;
    return ref.modulePtr();
}

/// The system's declared access set — the ONE declaration this file writes.
///
/// It parameterises the body's view AND produces the descriptors the dependency
/// graph orders on, so the two cannot disagree. `writesResource` and not
/// `readsResource`: the pass mutates module state reached through this address,
/// and declaring a read would tell the graph this system may run beside another
/// that writes the same thing.
const pose_spec = [_]Access{
    Access.writesResource(KinesisModuleRef),
};

const pose_system_name = "kinesis_model_pose";

fn modelPoseSystem(ctx: core.ecs.SystemContextOf(&pose_spec)) anyerror!void {
    const ref = resolve(ctx.view) orelse return;
    ref.modulePtr().?.update();
}

/// Whether a system of this name is already registered in `phase`.
fn isRegistered(sched: *SystemScheduler, comptime phase: core.ecs.Phase, name: []const u8) bool {
    for (sched.systemsInPhase(phase)) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

/// Register the module's per-frame pass.
///
/// **`fixed_update`, not `update`**, because the pass it drives is inside the
/// compared-output perimeter: forward kinematics feeds what later becomes root
/// motion, and a pass sampled at the render framerate poses differently on two
/// machines that agree on everything else.
///
/// Refuses a second registration by name rather than adding a twin: two
/// drivers of one store would run the same pass twice per tick, which is not
/// wrong but is not what anyone asked for, and the second one is invisible.
pub fn registerSystems(gpa: std.mem.Allocator, sched: *SystemScheduler, ecs: *World) !void {
    if (isRegistered(sched, .fixed_update, pose_system_name)) return error.SystemAlreadyRegistered;
    try sched.registerSystem(
        gpa,
        ecs,
        .fixed_update,
        pose_system_name,
        &pose_spec,
        modelPoseSystem,
    );
}
