//! Counter-proof 3 — a body paired with a declaration that does not describe it.
//!
//! MUST NOT COMPILE. The body is typed against `writes(Transform)` and the
//! registration declares `reads(Velocity)`. Neither half is wrong on its own;
//! it is their PAIRING that is a lie, and the lie is the one `ARCH-030` exists
//! to make impossible — the DAG orders the system on a set that has nothing to
//! do with what the body touches.
//!
//! **This replaces a case that measured the wrong thing.** Its predecessor
//! OMITTED the `accesses` field and asserted that Zig refuses a struct literal
//! missing a field without a default — which Zig did already, with or without
//! any of this milestone's work. A counter-proof that tests what the compiler
//! does anyway is green for a reason unrelated to the invariant, and that is
//! how the general form went unclosed while a fixture stood guard over it.
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
