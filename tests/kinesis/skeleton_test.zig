//! Acceptance for the skeleton asset: what loads, and what is refused.
//!
//! **EVERY REFUSAL IS PAIRED, IN THE SAME TEST, WITH A SKELETON THAT MUST
//! LOAD.** A loader that refused everything satisfies four rejection tests and
//! nothing else; the pairing is what makes each of them mean "this shape and
//! not that one" instead of "something was refused".
//!
//! The fixtures are built through the format's own encoder rather than as hand
//! assembled bytes, so the layout has one declarant: a second description of it
//! living here would drift from the reader it is meant to exercise.

const std = @import("std");

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

const asset = kinesis.skeleton_asset;
const BoneIndex = anim.BoneIndex;
const BoneTransform = anim.BoneTransform;
const Mat4 = anim.Mat4;
const Vec3 = anim.Vec3;
const Quat = anim.Quat;

const testing = std.testing;
const no_parent = asset.no_parent;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3.fromArray(.{ x, y, z });
}

/// A three-level chain: root → spine → head.
///
/// The spine carries a NON-UNIFORM scale and a quarter turn, which is what
/// separates a correct composition from one that happens to work: under uniform
/// scale `R·S` and `S·R` agree, and under identity rotation the scale axes never
/// move.
const chain_parents = [_]BoneIndex{ no_parent, 0, 1 };
const chain_names = [_][]const u8{ "root", "spine", "head" };

fn chainBind() [3]BoneTransform {
    return .{
        .{ .position = v3(0, 0, 0), .rotation = Quat.identity, .scale = Vec3.one },
        .{
            .position = v3(0, 2, 0),
            .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0),
            .scale = v3(2, 3, 1),
        },
        .{ .position = v3(0, 1, 0), .rotation = Quat.identity, .scale = Vec3.one },
    };
}

fn encodeChain(gpa: std.mem.Allocator, parents: []const BoneIndex) ![]u8 {
    const bind = chainBind();
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity, Mat4.identity };
    return asset.encode(gpa, .{
        .parents = parents,
        .names = &chain_names,
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
}

/// Load the well-formed chain and assert it really loaded.
///
/// Called by every rejection test below. Its own assertions are what make those
/// tests discriminating rather than merely negative.
fn expectWellFormedLoads(gpa: std.mem.Allocator) !void {
    const bytes = try encodeChain(gpa, &chain_parents);
    defer gpa.free(bytes);
    var a = try asset.parse(gpa, bytes);
    defer a.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), a.boneCount());
    try testing.expectEqual(no_parent, a.parents[0]);
    try testing.expectEqualStrings("spine", a.boneName(1));
}

fn expectRefused(gpa: std.mem.Allocator, parents: []const BoneIndex, want: anyerror) !void {
    const bytes = try encodeChain(gpa, parents);
    defer gpa.free(bytes);
    try testing.expectError(want, asset.parse(gpa, bytes));
}

test "a well-formed skeleton loads" {
    try expectWellFormedLoads(testing.allocator);
}

test "an out-of-range parent index is refused" {
    const gpa = testing.allocator;
    try expectRefused(gpa, &.{ no_parent, 0, 9 }, error.ParentIndexOutOfRange);
    try expectWellFormedLoads(gpa);
}

test "a parent appearing after its child is refused" {
    const gpa = testing.allocator;
    // Bone 1 names bone 2, which is below it in the file and above it in index.
    try expectRefused(gpa, &.{ no_parent, 2, 0 }, error.ParentAfterChild);
    try expectWellFormedLoads(gpa);
}

test "a cycle is refused" {
    const gpa = testing.allocator;
    // Bone 1 → 2 → 1. It is caught as a forward reference, which is what any
    // cycle must contain: the topological order makes a cycle unrepresentable
    // rather than merely detected, so there is no separate walk and no separate
    // code.
    try expectRefused(gpa, &.{ no_parent, 2, 1 }, error.ParentAfterChild);
    // And the degenerate one, a bone that is its own parent.
    try expectRefused(gpa, &.{ no_parent, 1, 1 }, error.ParentAfterChild);
    try expectWellFormedLoads(gpa);
}

test "more than one root is refused" {
    const gpa = testing.allocator;
    try expectRefused(gpa, &.{ no_parent, no_parent, 1 }, error.MultipleRoots);
    try expectWellFormedLoads(gpa);
}

test "a foreign or mis-versioned buffer is refused before its contents are judged" {
    const gpa = testing.allocator;
    const bytes = try encodeChain(gpa, &chain_parents);
    defer gpa.free(bytes);

    const wrong_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong_magic);
    wrong_magic[0] = 'X';
    try testing.expectError(error.BadMagic, asset.parse(gpa, wrong_magic));

    const wrong_version = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong_version);
    wrong_version[4] = 0xFF;
    wrong_version[5] = 0xFF;
    try testing.expectError(error.BadVersion, asset.parse(gpa, wrong_version));

    try expectWellFormedLoads(gpa);
}

// --- the optional profile ----------------------------------------------------

fn encodeWithProfile(
    gpa: std.mem.Allocator,
    mappings: []const asset.RoleMapping,
) ![]u8 {
    const bind = chainBind();
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity, Mat4.identity };
    return asset.encode(gpa, .{
        .parents = &chain_parents,
        .names = &chain_names,
        .bind_local = &bind,
        .inverse_bind = &inv,
        .profile = .{ .kind = .humanoid, .provenance = .authored, .mappings = mappings },
    });
}

test "a skeleton without a profile loads and reports none" {
    const gpa = testing.allocator;
    const bytes = try encodeChain(gpa, &chain_parents);
    defer gpa.free(bytes);
    var a = try asset.parse(gpa, bytes);
    defer a.deinit(gpa);
    // The absence is the point: a skeleton with no profile stays fully usable,
    // and nothing downstream may treat its absence as a defect.
    try testing.expect(a.profile == null);
}

test "a partial profile loads with exactly the roles it declares" {
    const gpa = testing.allocator;
    const bytes = try encodeWithProfile(gpa, &.{
        .{ .role = .root, .bone = 0 },
        .{ .role = .head, .bone = 2 },
    });
    defer gpa.free(bytes);
    var a = try asset.parse(gpa, bytes);
    defer a.deinit(gpa);

    const p = a.profile.?;
    try testing.expectEqual(asset.ProfileKind.humanoid, p.kind);
    try testing.expectEqual(asset.Provenance.authored, p.provenance);
    // TWO of twenty-three roles, and the count is asserted: a profile read as
    // complete would make every unmapped role resolve to whatever sits at its
    // ordinal.
    try testing.expectEqual(@as(usize, 2), p.mappings.len);
    try testing.expectEqual(anim.BoneRole.head, p.mappings[1].role);
    try testing.expectEqual(@as(BoneIndex, 2), p.mappings[1].bone);
}

test "an ambiguous or dangling profile is refused" {
    const gpa = testing.allocator;

    const dup = try encodeWithProfile(gpa, &.{
        .{ .role = .head, .bone = 1 },
        .{ .role = .head, .bone = 2 },
    });
    defer gpa.free(dup);
    // A role mapped twice has no answer, and picking the first would make the
    // resolution depend on the order the importer happened to write.
    try testing.expectError(error.DuplicateRole, asset.parse(gpa, dup));

    const dangling = try encodeWithProfile(gpa, &.{.{ .role = .head, .bone = 7 }});
    defer gpa.free(dangling);
    try testing.expectError(error.ProfileBoneOutOfRange, asset.parse(gpa, dangling));

    try expectWellFormedLoads(gpa);
}

test "a role ordinal this build does not carry is refused" {
    const gpa = testing.allocator;
    const bytes = try encodeWithProfile(gpa, &.{.{ .role = .root, .bone = 0 }});
    defer gpa.free(bytes);

    // The role ordinal is the last four bytes: role u16 then bone u16. Raise it
    // past the vocabulary. An asset written by a LATER build carrying a role
    // this one does not know must be refused rather than read as whatever the
    // ordinal happens to land on here.
    const tampered = try gpa.dupe(u8, bytes);
    defer gpa.free(tampered);
    std.mem.writeInt(u16, tampered[tampered.len - 4 ..][0..2], 9999, .little);
    try testing.expectError(error.UnknownRole, asset.parse(gpa, tampered));

    try expectWellFormedLoads(gpa);
}

// --- the hierarchy at runtime ------------------------------------------------

const core = @import("weld_core");

/// The model-space bind pose of `chain_parents` + `chainBind()`, computed BY
/// HAND so the assertions below have an oracle the engine did not produce.
///
///   bone 0 (root)  : the identity.
///   bone 1 (spine) : the root is the identity, so the spine's model transform
///                    IS its local one — two metres up, a quarter turn about
///                    +Z, scale (2, 3, 1).
///   bone 2 (head)  : the spine's scale acts on the head's offset first, in the
///                    spine's own frame, so (0, 1, 0) becomes (0, 3, 0); the
///                    quarter turn about +Z sends +Y to -X, so the head lands
///                    three metres along -X. Rotation and scale pass through
///                    unchanged because the head's own are the identity.
const chain_model = [3]BoneTransform{
    .{ .position = v3(0, 0, 0), .rotation = Quat.identity, .scale = Vec3.one },
    .{
        .position = v3(0, 2, 0),
        .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0),
        .scale = v3(2, 3, 1),
    },
    .{
        .position = v3(-3, 2, 0),
        .rotation = Quat.fromAxisAngle(Vec3.unit_z, std.math.pi / 2.0),
        .scale = v3(2, 3, 1),
    },
};

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

/// The chain, with inverse-bind matrices built from the HAND-COMPUTED model
/// pose above rather than from the engine's own kinematics.
///
/// That is what makes the round-trip test bite: the inverses come from one
/// source and the model pose they are checked against comes from the other, so
/// an error in the pass cannot cancel itself.
fn encodeChainWithInverseBind(gpa: std.mem.Allocator) ![]u8 {
    const bind = chainBind();
    var inv: [3]Mat4 = undefined;
    for (&inv, chain_model) |*m, t| {
        m.* = Mat4.fromTrs(t.position, t.rotation, t.scale).affineInverse();
    }
    return asset.encode(gpa, .{
        .parents = &chain_parents,
        .names = &chain_names,
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
}

test "world transforms of a three-level chain are correct" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const bytes = try encodeChainWithInverseBind(gpa);
    defer gpa.free(bytes);
    const rig = try module.loadRig(bytes);
    const id = try module.instantiate(rig);

    const model = module.modelPose(id).?;
    for (model.constSlice(), chain_model, 0..) |got, want, i| {
        errdefer std.debug.print("bone {d} diverged\n", .{i});
        try testing.expect(got.position.approxEql(want.position, 1e-5));
        try testing.expect(got.scale.approxEql(want.scale, 1e-5));
        try testing.expect(got.rotation.approxEql(want.rotation, 1e-5));
    }

    // And the LOCAL pose is untouched by the pass — the two spaces are two
    // buffers, and a pass that wrote its result over its own input would look
    // correct on the first frame and wrong on every one after.
    const local = module.localPose(id).?;
    try testing.expect(local.constSlice()[2].position.approxEql(v3(0, 1, 0), 1e-6));
}

test "forward kinematics is a single linear pass" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const bytes = try encodeChainWithInverseBind(gpa);
    defer gpa.free(bytes);
    const id = try module.instantiate(try module.loadRig(bytes));

    // The invariant the single pass rests on, read off the loaded rig: a parent
    // precedes its child. This is what the loader refuses to admit otherwise,
    // and what makes the ascending loop sufficient.
    const r = module.rig(0).?;
    for (r.parents, 0..) |p, i| {
        if (i == 0) continue;
        try testing.expect(p < i);
    }

    // And the mechanical half: one pass reaches the fixed point. If a parent
    // were evaluated after its child, a second pass would move something.
    var first: [3]anim.BoneTransform = undefined;
    @memcpy(&first, module.modelPose(id).?.constSlice());
    try testing.expect(module.updateModelPose(id));
    for (module.modelPose(id).?.constSlice(), first) |after, before| {
        try testing.expectEqual(before.position.data[0], after.position.data[0]);
        try testing.expectEqual(before.position.data[1], after.position.data[1]);
        try testing.expectEqual(before.rotation.w, after.rotation.w);
        try testing.expectEqual(before.scale.data[1], after.scale.data[1]);
    }
}

test "inverse bind pose composed with the bind pose yields identity" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const bytes = try encodeChainWithInverseBind(gpa);
    defer gpa.free(bytes);
    const id = try module.instantiate(try module.loadRig(bytes));
    const r = module.rig(0).?;

    // The product a skin matrix is built from, at the bind pose: it must be the
    // identity, because a mesh in its bind pose is undeformed. The epsilon is
    // stated rather than left to a default — the chain composes three
    // transforms with a non-uniform scale, so a few ULP of drift per bone is
    // expected and anything beyond it is not.
    const epsilon: f32 = 1e-4;
    for (module.modelPose(id).?.constSlice(), r.inverse_bind, 0..) |m, inv, i| {
        errdefer std.debug.print("bone {d} does not round-trip\n", .{i});
        const skin = Mat4.fromTrs(m.position, m.rotation, m.scale).mul(inv);
        try testing.expect(skin.approxEql(Mat4.identity, epsilon));
    }
}

test "a fresh instance stands in its bind pose, not at the origin" {
    const gpa = testing.allocator;
    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);
    var module = try kinesis.KinesisModule.init(&fx.ctx);
    defer module.deinit();

    const bytes = try encodeChainWithInverseBind(gpa);
    defer gpa.free(bytes);
    const id = try module.instantiate(try module.loadRig(bytes));

    // A skeleton left at the identity is a heap of bones at the origin, and it
    // looks exactly like a sampling bug. The head being three metres off the
    // origin is what tells the two apart.
    const head = module.localPose(id).?.constSlice()[2];
    try testing.expect(head.position.approxEql(v3(0, 1, 0), 1e-6));
    try testing.expect(!module.modelPose(id).?.constSlice()[2].position.approxEql(Vec3.zero, 1e-3));
}
