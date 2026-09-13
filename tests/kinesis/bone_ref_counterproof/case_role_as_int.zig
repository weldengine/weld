//! A role built from a bare integer ordinal.
//!
//! The role vocabulary is append-only and its ordinals are written into assets,
//! so an integer in a role's place is a number that means whatever this build's
//! enum happens to put there. Flip the decision this pins, by declaring
//! `BoneRole` a `u16` alias instead of an enum, and this file compiles.

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

fn resolve(module: *kinesis.KinesisModule, id: anim.SkeletonId) ?anim.BoneIndex {
    return module.resolveBone(id, anim.BoneRef{ .role = 17 });
}

comptime {
    _ = &resolve;
}
