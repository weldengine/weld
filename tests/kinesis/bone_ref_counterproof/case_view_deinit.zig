//! A destructor called on the rig a module entry handed out.
//!
//! **The defect this refuses is a use-after-free with no visible cause.** The
//! owning record's `deinit` frees seven allocations and poisons itself; called
//! on a COPY, it frees the module's memory while the store keeps holding the
//! same slices — so the module's own `deinit` frees them a second time, and
//! every pass between the two reads released memory. The caller wrote one line
//! that looks like tidy resource handling.
//!
//! A view has no destructor at all, which is why this does not compile: there
//! is nothing to free because there is nothing owned. The store is the one
//! owner, and being the one owner is a property of the TYPE rather than a rule
//! a reader must have been told.

const std = @import("std");

const anim = @import("weld_interfaces_animation");
const kinesis = @import("weld_kinesis");

fn release(module: *kinesis.KinesisModule, gpa: std.mem.Allocator) void {
    var borrowed = module.rig(0).?;
    borrowed.deinit(gpa);
}

comptime {
    _ = &release;
    _ = anim.no_skeleton;
}
