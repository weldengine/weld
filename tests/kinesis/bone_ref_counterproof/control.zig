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

comptime {
    _ = &byRole;
    _ = &byName;
}
