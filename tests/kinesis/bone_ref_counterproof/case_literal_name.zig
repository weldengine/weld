//! A bone named by a bare string literal, with no `BoneRef` around it.
//!
//! **`ARCH-033`'s first conformance test, made mechanical**: no literal bone
//! string in a reference position across a module interface. The literal name
//! stays a legitimate VARIANT — `control.zig` uses it — but it travels inside
//! the addressing type, never instead of it. Flip the decision this pins, by
//! typing the parameter `[]const u8`, and this file compiles.

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

fn resolve(module: *kinesis.KinesisModule, id: anim.SkeletonId) ?anim.BoneIndex {
    return module.resolveBone(id, "foot_l");
}

comptime {
    _ = &resolve;
}
