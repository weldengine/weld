//! Counter-proof 2 — a mutable access to a component declared read-only.
//!
//! MUST NOT COMPILE. `Velocity` is declared `reads`, and the body calls
//! `getMut` on it. The read side of the same declaration compiles, which is
//! what makes this case about the read/write distinction and not about
//! membership.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.reads(ecs.Velocity)};

fn body(ctx: ecs.SystemContextOf(&spec)) anyerror!void {
    const e = ecs.EntityId.dead;
    _ = ctx.view.get(ecs.Velocity, e);
    _ = ctx.view.getMut(ecs.Velocity, e);
}

/// Registration is what forces the body to be analysed, and it is written as a
/// function that is never called: `SystemDescriptor.of` is private now — the
/// scheduler refuses to accept a `run` and an `accesses` supplied separately —
/// so the only way in is the generic entry, which needs a live world this
/// fixture has no reason to build. Without a reference Zig analyses neither the
/// trampoline nor the body, and the file would compile by not looking.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "mutable_on_read", &spec, body);
}

comptime {
    _ = &wire;
}
