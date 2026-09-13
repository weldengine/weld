//! Load a three-level skeleton and print what forward kinematics makes of it.
//!
//! **It exists so the result is READABLE and not only asserted.** The
//! acceptance suite pins the same chain against a hand-computed pose, which
//! answers "is it right"; this answers "what does it look like", which is the
//! question someone has when the numbers are wrong and they need to see where.
//!
//! It is also the one place the load-to-pose path runs as a program rather than
//! as a test — a public entry exercised only by `zig build test` has never had
//! its bodies analysed in a release build.

const std = @import("std");

const anim = @import("weld_interfaces_animation");
const foundation = @import("foundation");
const core = @import("weld_core");
const kinesis = @import("weld_kinesis");

const asset = kinesis.skeleton_asset;
const BoneIndex = anim.BoneIndex;
const BoneTransform = anim.BoneTransform;
const Mat4 = anim.Mat4;
const Quat = anim.Quat;
const Vec3 = anim.Vec3;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3.fromArray(.{ x, y, z });
}

/// root → spine → head, the spine carrying a quarter turn and a non-uniform
/// scale so the printed head position is not something the identity could have
/// produced.
fn buildChain(gpa: std.mem.Allocator) ![]u8 {
    const parents = [_]BoneIndex{ asset.no_parent, 0, 1 };
    const names = [_][]const u8{ "root", "spine", "head" };
    const bind = [_]BoneTransform{
        .{},
        .{
            .position = v3(0, 2, 0),
            .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0),
            .scale = v3(2, 3, 1),
        },
        .{ .position = v3(0, 1, 0) },
    };
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity, Mat4.identity };
    return asset.encode(gpa, .{
        .parents = &parents,
        .names = &names,
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // `ARCH-031` rule 5: installation belongs to the ACT of entering a process.
    // This one composes transforms and prints them, so its output is a float
    // result read by a human against a hand-computed one.
    foundation.math.float_env.install();

    var world = core.ecs.World.init();
    defer world.deinit(gpa);
    var scheduler = core.ecs.SystemScheduler.init();
    defer scheduler.deinit(gpa);
    // A REAL job scheduler, though nothing here submits a job: the context a
    // module receives must be a context, and a placeholder would make any future
    // `init` that reads the field fail in a way this scenario could not tell from
    // a defect.
    var jobs = try core.jobs.scheduler.Scheduler.init(gpa, init.io);
    defer jobs.deinit(gpa);

    var ctx = core.ModuleContext{
        .world = &world,
        .persistent_allocator = gpa,
        .system_scheduler = &scheduler,
        .job_scheduler = &jobs,
    };

    var module = try kinesis.KinesisModule.init(&ctx);
    defer module.deinit();

    const bytes = try buildChain(gpa);
    defer gpa.free(bytes);
    const rig_id = try module.loadRig(bytes);
    const id = try module.instantiate(rig_id);

    const rig = module.rig(rig_id).?;
    const local = module.localPose(id).?;
    const model = module.modelPose(id).?;

    std.debug.print("skeleton: {d} bones\n", .{rig.boneCount()});
    std.debug.print("{s:<8} {s:>8}   {s:<26} {s:<26}\n", .{ "bone", "parent", "local position", "model position" });
    for (0..rig.boneCount()) |i| {
        const b: BoneIndex = @intCast(i);
        const p = rig.parents[i];
        const lp = local.constSlice()[i].position;
        const mp = model.constSlice()[i].position;
        var parent_text: [8]u8 = undefined;
        const parent_str = if (p == asset.no_parent)
            "-"
        else
            std.fmt.bufPrint(&parent_text, "{d}", .{p}) catch "?";
        std.debug.print("{s:<8} {s:>8}   ({d: >7.3},{d: >7.3},{d: >7.3})   ({d: >7.3},{d: >7.3},{d: >7.3})\n", .{
            rig.boneName(b), parent_str,
            lp.data[0],      lp.data[1],
            lp.data[2],      mp.data[0],
            mp.data[1],      mp.data[2],
        });
    }
}
