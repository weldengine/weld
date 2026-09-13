//! The POSITIVE control of the bone-addressing corpus: this one MUST compile.
//!
//! Without it the three refusals beside it are vacuous — an entry that accepted
//! nothing would satisfy all three and prove nothing. It is built in the same
//! execution as the refusals, so "the addressing type is imposed" and "the
//! addressing type does not refuse legitimate code" are established together or
//! not at all.
//!
//! It exercises BOTH legitimate variants, because `ARCH-033` imposes the
//! uniformity of the type and never the obligation of a role: a tentacle has no
//! role and addresses its bones by name.
//!
//! **And it READS a rig through the view an entry hands out**, which is the
//! control for the ownership half of this corpus: without it, "a view refuses
//! writes and frees" is satisfied by a view that refuses everything, and the
//! two refusals beside it would prove that the type is useless rather than that
//! it is tight. Read and refusal are established in the same execution.

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

const BoneRef = anim.BoneRef;
const BoneIndex = anim.BoneIndex;

fn byRole(module: *kinesis.KinesisModule, id: anim.SkeletonId) ?BoneIndex {
    return module.resolveBone(id, BoneRef{ .role = .foot_l });
}

fn byName(module: *kinesis.KinesisModule, id: anim.SkeletonId) ?BoneIndex {
    return module.resolveBone(id, BoneRef{ .name = "tentacle_07" });
}

/// Every legitimate read the view exists to serve. All of these compile; the
/// two writes in `case_view_*.zig` do not, and neither does a `deinit`.
fn readThrough(module: *kinesis.KinesisModule) u32 {
    const r = module.rig(0) orelse return 0;
    var n: u32 = r.boneCount();
    n +%= @intCast(r.boneName(0).len);
    n +%= r.parents[0];
    n +%= @intFromFloat(r.bind_local[0].scale.data[0]);
    n +%= @intFromFloat(r.inverse_bind[0].m[0]);
    if (r.profile) |p| n +%= @intCast(p.mappings.len);
    return n;
}

comptime {
    _ = &byRole;
    _ = &byName;
    _ = &readThrough;
}
