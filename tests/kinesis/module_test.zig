//! Acceptance for the Kinesis module's opening: what `init` touches, what the
//! instance store guarantees, and that the interface wrapper DELEGATES rather
//! than merely validating.
//!
//! Every oracle here is written to tell its entry apart from a plausible
//! NEIGHBOUR, not merely to observe that something happened. `getBoneCount`
//! against a constant, a recycled slot against a fresh one, the wrapper against
//! a wrapper that only holds its field — each of those is a form that passes a
//! weaker test.

const std = @import("std");

const core = @import("weld_core");
const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

const asset = kinesis.skeleton_asset;
const BoneIndex = anim.BoneIndex;
const BoneTransform = anim.BoneTransform;
const Mat4 = anim.Mat4;

const World = core.ecs.World;
const ModuleContext = core.ModuleContext;
const KinesisModule = kinesis.KinesisModule;
const Skeleton = kinesis.Skeleton;

const testing = std.testing;

/// A context whose four fields are real Tier 0 objects where a real one is
/// cheap.
///
/// `job_scheduler` is the exception: starting a worker pool for a test that
/// submits no job buys nothing, so it points at an UNMAPPED address — the
/// alignment of the type and nothing else. It is not a zeroed object and it is
/// not readable: anything that dereferenced it would fault rather than read a
/// plausible zero. What it buys is bounded — a field merely copied into the
/// context is invisible either way — so it witnesses a DEREFERENCE that does
/// not happen, not an absence of interest in the field.
const Fixture = struct {
    world: World,
    scheduler: core.ecs.SystemScheduler,
    ctx: ModuleContext,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .world = World.init(),
            .scheduler = core.ecs.SystemScheduler.init(),
            .ctx = undefined,
        };
        self.ctx = .{
            .world = &self.world,
            .persistent_allocator = gpa,
            .system_scheduler = &self.scheduler,
            .job_scheduler = @ptrFromInt(@alignOf(core.jobs.scheduler.Scheduler)),
        };
        return self;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.scheduler.deinit(gpa);
        self.world.deinit(gpa);
        gpa.destroy(self);
    }
};

/// Encode a flat rig of `n` bones — bone 0 the root, every other a child of
/// bone 0 — so a test that needs an instance can get one without caring about
/// the hierarchy.
fn encodeFlatRig(gpa: std.mem.Allocator, n: u16) ![]u8 {
    const parents = try gpa.alloc(BoneIndex, n);
    defer gpa.free(parents);
    const names = try gpa.alloc([]const u8, n);
    defer {
        for (names) |nm| gpa.free(nm);
        gpa.free(names);
    }
    const bind = try gpa.alloc(BoneTransform, n);
    defer gpa.free(bind);
    const inv = try gpa.alloc(Mat4, n);
    defer gpa.free(inv);
    for (0..n) |i| {
        parents[i] = if (i == 0) asset.no_parent else 0;
        // Distinct: the loader refuses two bones of one name, because a name
        // that addresses two bones addresses neither.
        names[i] = try std.fmt.allocPrint(gpa, "bone{d}", .{i});
        bind[i] = .{};
        inv[i] = Mat4.identity;
    }
    return asset.encode(gpa, .{
        .parents = parents,
        .names = names,
        .bind_local = bind,
        .inverse_bind = inv,
    });
}

fn loadFlatRig(module: *KinesisModule, gpa: std.mem.Allocator, n: u16) !kinesis.RigId {
    const bytes = try encodeFlatRig(gpa, n);
    defer gpa.free(bytes);
    return module.loadRig(bytes);
}

fn instantiateFlat(module: *KinesisModule, gpa: std.mem.Allocator, n: u16) !anim.SkeletonId {
    return module.instantiate(try loadFlatRig(module, gpa, n));
}

test "init registers the Skeleton component through the world" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    // Before: the type is unknown to the world. Without this half the
    // assertion after `init` would pass against a world that had been born
    // knowing it.
    try testing.expect(fx.world.componentId(@typeName(Skeleton)) == null);

    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    try testing.expect(fx.world.componentId(@typeName(Skeleton)) != null);
}

test "init registers no system" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    // A system with nothing to run is a mechanism nothing executes. What breaks
    // if this test is removed: a placeholder system lands in a phase, takes a
    // slot in the dependency graph, and declares accesses nobody reads.
    var total: usize = 0;
    for (&fx.scheduler.phases) |*phase| total += phase.systems.items.len;
    try testing.expectEqual(@as(usize, 0), total);
}

test "an instance carries its own bone count" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    // TWO instances of DIFFERENT sizes: one instance cannot tell a per-instance
    // count from a constant, nor from the count of whichever was created last.
    const a = try instantiateFlat(&module, gpa, 3);
    const b = try instantiateFlat(&module, gpa, 7);
    try testing.expectEqual(@as(u32, 3), module.getBoneCount(a));
    try testing.expectEqual(@as(u32, 7), module.getBoneCount(b));

    try testing.expectEqual(@as(usize, 3), module.localPose(a).?.constSlice().len);
    try testing.expectEqual(@as(usize, 7), module.modelPose(b).?.constSlice().len);
}

test "a destroyed instance stays dead and its slot is never reused" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const a = try instantiateFlat(&module, gpa, 4);
    module.destroySkeleton(a);

    // Dead, and answering as such.
    try testing.expectEqual(@as(u32, 0), module.getBoneCount(a));
    try testing.expect(module.localPose(a) == null);

    // And the next instance does NOT land on the freed slot. If it did, the
    // stale handle `a` would start addressing somebody else's skeleton — which
    // reads as a working handle and is the whole reason slots are not recycled.
    const b = try instantiateFlat(&module, gpa, 9);
    try testing.expect(b != a);
    try testing.expectEqual(@as(u32, 0), module.getBoneCount(a));
    try testing.expectEqual(@as(u32, 9), module.getBoneCount(b));

    // Idempotent: a second destroy is a no-op, not a double free.
    module.destroySkeleton(a);
}

test "instantiating an unknown rig is refused" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    // Rig zero does not exist until one is loaded, so the refusal is about the
    // id naming nothing and not about the id being out of some fixed range.
    try testing.expectError(error.UnknownRig, module.instantiate(0));
    _ = try loadFlatRig(&module, gpa, 2);
    _ = try module.instantiate(0);
    try testing.expectError(error.UnknownRig, module.instantiate(1));
}

test "one rig backs many instances" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    // The whole reason the rig and the instance are separate stores: a hundred
    // characters on one skeleton carry one hierarchy and a hundred poses. Two
    // instances of ONE rig must have distinct poses, or a pose written for one
    // entity moves every other.
    const r = try loadFlatRig(&module, gpa, 3);
    const a = try module.instantiate(r);
    const b = try module.instantiate(r);
    try testing.expect(a != b);
    try testing.expect(module.localPose(a).?.bones != module.localPose(b).?.bones);
    try testing.expectEqual(@as(u32, 3), module.getBoneCount(a));
    try testing.expectEqual(@as(u32, 3), module.getBoneCount(b));
}

test "an out-of-range id answers as absent rather than trapping" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    try testing.expectEqual(@as(u32, 0), module.getBoneCount(anim.no_skeleton));
    try testing.expect(module.localPose(1234) == null);
    module.destroySkeleton(anim.no_skeleton);

    // **THE BOUNDARY, and it is the only id the check can get wrong.** Every
    // other test probes an id far outside the range or one `instantiate`
    // returned, so `>` in place of `>=` passes them all — and then
    // `getBoneCount(len)` indexes one past the end: a panic in Debug and a read
    // out of bounds in ReleaseFast. The id ONE PAST the last live instance is
    // what discriminates, and it only exists once an instance does.
    const live = try instantiateFlat(&module, gpa, 2);
    const one_past: anim.SkeletonId = live + 1;
    try testing.expectEqual(@as(u32, 0), module.getBoneCount(one_past));
    try testing.expect(module.localPose(one_past) == null);
    try testing.expect(module.modelPose(one_past) == null);
    try testing.expect(!module.updateModelPose(one_past));
    try testing.expect(module.resolveBone(one_past, .{ .name = "bone0" }) == null);
    module.destroySkeleton(one_past);
    // …and the last LIVE one still answers, so the bound was not merely made
    // stricter.
    try testing.expectEqual(@as(u32, 2), module.getBoneCount(live));
}

test "createSkeleton refuses rather than answering a plausible id" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    // Zero would be instance zero. The refusal is what keeps a caller from
    // reading "nobody wired the asset path" as "you got the first skeleton".
    try testing.expectError(error.NotImplemented, module.createSkeleton(@enumFromInt(1)));
}

test "the interface wrapper delegates, it does not merely validate" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    const Wrapped = anim.AnimationModule(KinesisModule);
    var wrapped = try Wrapped.init(&fx.ctx);
    defer wrapped.deinit();

    // A `struct { impl: Impl }` carrying nothing else compiles, validates the
    // implementation, and exposes none of it — and a test asserting only that
    // the field exists cannot see that. So each entry below is called THROUGH
    // the wrapper and its answer asserted. `resolveBone` is the wrapper's sixth
    // entry and is exercised the same way in `bone_ref_test.zig`, beside the
    // fixtures that give it a profile; saying "every entry" HERE would be false
    // of this file, and a sentence like that is what stops a reader checking.
    const id = try instantiateFlat(&wrapped.impl, gpa, 5);
    try testing.expectEqual(@as(u32, 5), wrapped.getBoneCount(id));
    try testing.expectError(error.NotImplemented, wrapped.createSkeleton(@enumFromInt(1)));
    wrapped.destroySkeleton(id);
    try testing.expectEqual(@as(u32, 0), wrapped.getBoneCount(id));
}

// --- the ECS seam ------------------------------------------------------------

test "the module publishes, withdraws, and refuses to replace a live publication" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try KinesisModule.init(&fx.ctx);
    defer module.deinit();

    try testing.expect(kinesis.sync.publishedModule(&fx.world) == null);
    try kinesis.sync.publishModule(gpa, &fx.world, &module);
    // The IDENTITY and not a boolean: a boolean cannot tell "still published"
    // from "erased and something else answers".
    try testing.expectEqual(&module, kinesis.sync.publishedModule(&fx.world).?);

    // A second publication is refused rather than silently replacing the first,
    // which would make a live module disappear with nobody having withdrawn it.
    var other = try KinesisModule.init(&fx.ctx);
    defer other.deinit();
    try testing.expectError(
        error.ModuleAlreadyPublished,
        kinesis.sync.publishModule(gpa, &fx.world, &other),
    );
    try testing.expectEqual(&module, kinesis.sync.publishedModule(&fx.world).?);

    // A withdrawal that names someone ELSE is a no-op — otherwise a late
    // teardown erases a module published after it, and every frame afterwards
    // is a silent nothing.
    kinesis.sync.withdrawModule(&fx.world, &other);
    try testing.expectEqual(&module, kinesis.sync.publishedModule(&fx.world).?);

    kinesis.sync.withdrawModule(&fx.world, &module);
    try testing.expect(kinesis.sync.publishedModule(&fx.world) == null);
}

test "the registered system drives the pass through a dispatched frame" {
    // **DISPATCHED, not called.** A first version of this test called
    // `module.update()` by hand and asserted the pose moved — which it does,
    // and which says nothing about the system: emptying the system's body left
    // the whole suite green. What has to run is `dispatchFrame`, so the claim
    // in the title is the thing being measured.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var world = World.init();
    defer world.deinit(gpa);
    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);
    var scheduler = core.ecs.SystemScheduler.init();
    defer scheduler.deinit(gpa);

    var ctx = ModuleContext{
        .world = &world,
        .persistent_allocator = gpa,
        .system_scheduler = &scheduler,
        .job_scheduler = &jobs,
    };
    var module = try KinesisModule.init(&ctx);
    defer module.deinit();
    try kinesis.sync.publishModule(gpa, &world, &module);
    defer kinesis.sync.withdrawModule(&world, &module);
    try kinesis.sync.registerSystems(gpa, &scheduler, &world);

    // ONE system, in `fixed_update`: the pass is inside the compared-output
    // perimeter, and a driver in `update` would pose differently on two
    // machines that agree on everything else.
    try testing.expectEqual(@as(usize, 1), scheduler.systemsInPhase(.fixed_update).len);
    var elsewhere: usize = 0;
    for ([_]core.ecs.Phase{ .pre_update, .update, .post_update, .late_update, .pre_render }) |p| {
        elsewhere += scheduler.systemsInPhase(p).len;
    }
    try testing.expectEqual(@as(usize, 0), elsewhere);

    // Registering twice is refused rather than adding a twin: two drivers of
    // one store run the pass twice a tick, and the second is invisible.
    try testing.expectError(
        error.SystemAlreadyRegistered,
        kinesis.sync.registerSystems(gpa, &scheduler, &world),
    );

    // Displace the child's LOCAL transform behind the pass's back, and assert
    // the model pose has NOT followed. Without this half the assertion after
    // the frame is satisfied by a pose that was already right.
    const id = try instantiateFlat(&module, gpa, 2);
    module.localPose(id).?.slice()[1].position = anim.Vec3.fromArray(.{ 0, 5, 0 });
    try testing.expectApproxEqAbs(
        @as(f32, 0),
        module.modelPose(id).?.constSlice()[1].translation().data[1],
        1e-6,
    );

    try scheduler.dispatchFrame(&world, gpa, io, &jobs, 1.0 / 60.0, null);

    try testing.expectApproxEqAbs(
        @as(f32, 5),
        module.modelPose(id).?.constSlice()[1].translation().data[1],
        1e-6,
    );
}

test "a frame dispatched with no module published is a no-op, not a fault" {
    // The system resolves its resource and returns when it names nothing. What
    // breaks if this is removed: a withdrawal followed by a frame dereferences
    // a dead address, and the fault surfaces far from the withdrawal.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var world = World.init();
    defer world.deinit(gpa);
    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, io);
    try jobs.start();
    defer jobs.deinit(gpa);
    var scheduler = core.ecs.SystemScheduler.init();
    defer scheduler.deinit(gpa);

    var ctx = ModuleContext{
        .world = &world,
        .persistent_allocator = gpa,
        .system_scheduler = &scheduler,
        .job_scheduler = &jobs,
    };
    var module = try KinesisModule.init(&ctx);
    defer module.deinit();
    try kinesis.sync.publishModule(gpa, &world, &module);
    try kinesis.sync.registerSystems(gpa, &scheduler, &world);

    kinesis.sync.withdrawModule(&world, &module);
    try scheduler.dispatchFrame(&world, gpa, io, &jobs, 1.0 / 60.0, null);
}

test "the declared entries that are not implemented refuse" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    const Wrapped = anim.AnimationModule(KinesisModule);
    var wrapped = try Wrapped.init(&fx.ctx);
    defer wrapped.deinit();

    // Called THROUGH the wrapper, because that is the surface a consumer sees,
    // and asserted one by one: a refusal is the only answer that cannot be
    // mistaken for a result. An unchanged pose, a zero duration, an empty
    // palette and a false are all plausible.
    var pose = try kinesis.poses.alloc(gpa, 2);
    defer kinesis.poses.free(gpa, pose);
    const clip: anim.AssetHandle = @enumFromInt(1);
    const entity = core.ecs.EntityId.dead;

    try testing.expectError(error.NotImplemented, wrapped.sampleClip(clip, 0.0, &pose));
    try testing.expectError(error.NotImplemented, wrapped.getClipDuration(clip));
    try testing.expectError(error.NotImplemented, wrapped.blendPoses(&pose, &pose, 0.5, &pose));
    try testing.expectError(error.NotImplemented, wrapped.additivePose(&pose, &pose, 0.5, &pose));
    try testing.expectError(error.NotImplemented, wrapped.getSkinMatrices(entity));
    try testing.expectError(error.NotImplemented, wrapped.solveIK(entity, .{
        .ik_type = .two_bone,
        .chain_root = 0,
        .chain_tip = 1,
        .target_position = anim.Vec3.zero,
    }));
    try testing.expectError(error.NotImplemented, wrapped.getSocketTransform(entity, .{ .role = .hand_r }));

    // The control: `update` is on the same surface and is REAL, so the seven
    // refusals above are about those entries and not about a wrapper that
    // refuses everything.
    wrapped.update();
}
