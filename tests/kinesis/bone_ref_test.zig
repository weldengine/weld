//! Bone addressing end to end: from a loaded asset, through the module and
//! through the interface wrapper, to a bone index or to absence.
//!
//! The resolver's own unit tests live beside it, on a rig built in memory. What
//! lives HERE is the path a caller actually takes — a byte buffer, a load, an
//! instance — because that path is what a socket, a solver and a rule will use,
//! and because a resolver that is right in isolation can still be wired to the
//! wrong rig.

const std = @import("std");

const core = @import("weld_core");
const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

const asset = kinesis.skeleton_asset;
const BoneIndex = anim.BoneIndex;
const BoneRef = anim.BoneRef;
const BoneRole = anim.BoneRole;
const BoneTransform = anim.BoneTransform;
const Mat4 = anim.Mat4;

const testing = std.testing;

const Fixture = struct {
    world: core.ecs.World,
    scheduler: core.ecs.SystemScheduler,
    ctx: core.ModuleContext,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .world = core.ecs.World.init(),
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

const leg_names = [_][]const u8{ "root", "thigh_l", "calf_l", "foot_l", "toe_l" };
const leg_parents = [_]BoneIndex{ asset.no_parent, 0, 1, 2, 3 };

/// A five-bone leg whose profile maps every role it has EXCEPT `calf_l`.
///
/// The gap is in the MIDDLE, which is what makes the absence test adversarial:
/// with the gap at the end, a resolver that walked off the array would answer
/// null for the right reason by accident.
fn encodeLeg(gpa: std.mem.Allocator, with_profile: bool) ![]u8 {
    const bind = [_]BoneTransform{ .{}, .{}, .{}, .{}, .{} };
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity, Mat4.identity, Mat4.identity, Mat4.identity };
    const mappings = [_]asset.RoleMapping{
        .{ .role = .root, .bone = 0 },
        .{ .role = .thigh_l, .bone = 1 },
        .{ .role = .foot_l, .bone = 3 },
        .{ .role = .toe_l, .bone = 4 },
    };
    return asset.encode(gpa, .{
        .parents = &leg_parents,
        .names = &leg_names,
        .bind_local = &bind,
        .inverse_bind = &inv,
        .profile = if (with_profile)
            .{ .kind = .humanoid, .provenance = .authored, .mappings = &mappings }
        else
            null,
    });
}

fn openLeg(gpa: std.mem.Allocator, module: *kinesis.KinesisModule, with_profile: bool) !anim.SkeletonId {
    const bytes = try encodeLeg(gpa, with_profile);
    defer gpa.free(bytes);
    return module.instantiate(try module.loadRig(bytes));
}

test "a mapped role resolves to its bone index" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const id = try openLeg(gpa, &module, true);
    try testing.expectEqual(@as(?BoneIndex, 0), module.resolveBone(id, .{ .role = .root }));
    try testing.expectEqual(@as(?BoneIndex, 1), module.resolveBone(id, .{ .role = .thigh_l }));
    try testing.expectEqual(@as(?BoneIndex, 4), module.resolveBone(id, .{ .role = .toe_l }));
}

test "an unmapped role resolves to absence, not to a neighbouring bone" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const id = try openLeg(gpa, &module, true);

    // `calf_l` is the gap. A resolver indexing the mapping array by ordinal
    // answers `foot_l`'s bone here — a NEIGHBOUR, plausible, animated, wrong.
    try testing.expectEqual(@as(?BoneIndex, null), module.resolveBone(id, .{ .role = .calf_l }));

    // Its two neighbours still resolve to their own bones, which is what rules
    // out a resolver that simply stopped working at the gap.
    try testing.expectEqual(@as(?BoneIndex, 1), module.resolveBone(id, .{ .role = .thigh_l }));
    try testing.expectEqual(@as(?BoneIndex, 3), module.resolveBone(id, .{ .role = .foot_l }));

    // And a role the rig does not have at all is absent, not an error.
    try testing.expectEqual(@as(?BoneIndex, null), module.resolveBone(id, .{ .role = .hand_r }));
}

test "a skeleton with no profile resolves by literal name" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const id = try openLeg(gpa, &module, false);

    // The tentacle-and-mech case: no profile at all, and fully usable.
    try testing.expectEqual(@as(?BoneIndex, 2), module.resolveBone(id, .{ .name = "calf_l" }));
    try testing.expectEqual(@as(?BoneIndex, 0), module.resolveBone(id, .{ .name = "root" }));
    // Every role is absent, and that absence is not a defect.
    try testing.expectEqual(@as(?BoneIndex, null), module.resolveBone(id, .{ .role = .root }));

    // The SAME rig with a profile resolves both ways, so the two variants are
    // not exclusive — which is what `ARCH-033` means by imposing the type and
    // not the role.
    const profiled = try openLeg(gpa, &module, true);
    try testing.expectEqual(@as(?BoneIndex, 2), module.resolveBone(profiled, .{ .name = "calf_l" }));
    try testing.expectEqual(@as(?BoneIndex, 3), module.resolveBone(profiled, .{ .role = .foot_l }));
}

test "a stale instance resolves to absence rather than to another rig's bone" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const id = try openLeg(gpa, &module, true);
    module.destroySkeleton(id);
    try testing.expectEqual(@as(?BoneIndex, null), module.resolveBone(id, .{ .role = .foot_l }));
    try testing.expectEqual(@as(?BoneIndex, null), module.resolveBone(anim.no_skeleton, .{ .name = "root" }));
}

test "two bones of one name are refused, so a name never addresses two bones" {
    const gpa = testing.allocator;
    const bind = [_]BoneTransform{ .{}, .{} };
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity };
    const bytes = try asset.encode(gpa, .{
        .parents = &[_]BoneIndex{ asset.no_parent, 0 },
        .names = &[_][]const u8{ "hand", "hand" },
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
    defer gpa.free(bytes);
    // Refused at LOAD rather than arbitrated at resolution: picking the first
    // of two same-named bones is acting on possibly the wrong one, which is the
    // failure the addressing contract exists to forbid.
    try testing.expectError(error.DuplicateBoneName, asset.parse(gpa, bytes));

    // And the well-formed neighbour still loads, so the refusal is about the
    // duplicate and not about the shape of the fixture.
    const ok = try asset.encode(gpa, .{
        .parents = &[_]BoneIndex{ asset.no_parent, 0 },
        .names = &[_][]const u8{ "hand_l", "hand_r" },
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
    defer gpa.free(ok);
    var parsed = try asset.parse(gpa, ok);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), parsed.boneCount());
}

test "the interface wrapper delegates resolution" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    const Wrapped = anim.AnimationModule(kinesis.KinesisModule);
    var wrapped = try Wrapped.init(&fx.ctx);
    defer wrapped.deinit();

    const id = try openLeg(gpa, &wrapped.impl, true);
    try testing.expectEqual(@as(?BoneIndex, 3), wrapped.resolveBone(id, .{ .role = .foot_l }));
    try testing.expectEqual(@as(?BoneIndex, null), wrapped.resolveBone(id, .{ .role = .calf_l }));
    try testing.expectEqual(@as(?BoneIndex, 2), wrapped.resolveBone(id, .{ .name = "calf_l" }));
}
