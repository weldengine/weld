//! A body paired with a declaration that does not describe it.
//!
//! MUST NOT COMPILE. The body is typed against `writes(Transform)` and the
//! registration declares `reads(Velocity)`. Neither half is wrong on its own;
//! it is their PAIRING that is a lie, and the lie is the one `ARCH-030` exists
//! to make impossible — the DAG orders the system on a set that has nothing to
//! do with what the body touches.
//!
//! **DO NOT WRITE THIS AS AN OMITTED `accesses` FIELD.** That asserts only
//! that Zig refuses a struct literal missing a field without a default, which
//! it does with or without any of this work: a counter-proof testing what the
//! compiler does anyway is green for a reason unrelated to the invariant, and
//! that is how the general form can go unclosed with a fixture standing guard
//! over it.
//!
//! What closes it is not a check: `registerSystem` no longer ACCEPTS a `run`
//! and an `accesses` supplied separately. It takes the declared set and the
//! body, derives both halves on the spot, and a body whose context type was
//! built from another set cannot be passed.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const declared = [_]ecs.Access{ecs.Access.reads(ecs.Velocity)};
const other = [_]ecs.Access{ecs.Access.writes(ecs.Transform)};

/// Typed against `other`, and legitimate against it: it writes what that set
/// declares. Nothing here is wrong until it meets the registration below.
fn body(ctx: ecs.SystemContextOf(&other)) anyerror!void {
    _ = ctx.view.getMut(ecs.Transform, ecs.EntityId.dead);
}

fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "mismatched_pair", &declared, body);
}

comptime {
    _ = &wire;
}
