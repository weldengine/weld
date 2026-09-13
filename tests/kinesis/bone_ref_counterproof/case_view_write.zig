//! A write through the rig a module entry handed out.
//!
//! **The defect this refuses is silent and total.** `parents` is the hierarchy
//! the loader validated: every parent strictly below its child, exactly one
//! root, no index out of range — the three properties the single ascending
//! forward-kinematics pass rests on. A caller that can write into it after the
//! fact bypasses every one of those checks with an ordinary assignment, and
//! nothing downstream re-validates: the pass asserts `p < i` in Debug and
//! composes whatever it finds in ReleaseFast.
//!
//! The store's own record still has mutable slices — it must, it owns them. What
//! must not exist is a route from a module entry to that mutability, and
//! `RigView`'s `[]const` is that route's absence.

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

fn reparent(module: *kinesis.KinesisModule) void {
    const borrowed = module.rig(0).?;
    borrowed.parents[1] = 127;
}

comptime {
    _ = &reparent;
    _ = anim.no_skeleton;
}
