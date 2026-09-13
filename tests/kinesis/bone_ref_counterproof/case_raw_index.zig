//! A bone named by a bare index, with no `BoneRef` around it.
//!
//! The other side of the same uniformity. An already-resolved index is what the
//! SOLVERS take — `IKRequest` carries `BoneIndex` and not `BoneRef` — but the
//! resolution entry is the frontier where symbolic addressing enters the
//! module, and feeding it an index bypasses the frontier rather than crossing
//! it.

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

fn resolve(module: *kinesis.KinesisModule, id: anim.SkeletonId) ?anim.BoneIndex {
    const already: anim.BoneIndex = 3;
    return module.resolveBone(id, already);
}

comptime {
    _ = &resolve;
}
