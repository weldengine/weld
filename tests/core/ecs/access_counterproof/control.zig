//! The POSITIVE control of the counter-proof corpus: this one MUST compile.
//!
//! Without it the three refusals beside it are vacuous — a view that refused
//! every access would satisfy all three and prove nothing. It is built in the
//! same execution as the refusals, so "the guard fires" and "the guard does not
//! fire on legitimate code" are established together or not at all.
//!
//! It exercises the three grants the model distinguishes: a declared read, a
//! declared write, and a read reaching through a write declaration.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{
    ecs.Access.reads(ecs.Velocity),
    ecs.Access.writes(ecs.Transform),
};

fn body(ctx: ecs.SystemContextOf(&spec)) anyerror!void {
    const e = ecs.EntityId.dead;
    _ = ctx.view.get(ecs.Velocity, e);
    _ = ctx.view.get(ecs.Transform, e);
    _ = ctx.view.getMut(ecs.Transform, e);
    _ = ctx.view.changedTick(ecs.Velocity, e);
}

/// Registration is what forces the body to be analysed, and it is written as a
/// function that is never called: `SystemDescriptor.of` is private now — the
/// scheduler refuses to accept a `run` and an `accesses` supplied separately —
/// so the only way in is the generic entry, which needs a live world this
/// fixture has no reason to build. Without a reference Zig analyses neither the
/// trampoline nor the body, and the file would compile by not looking.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "control", &spec, body);
}

comptime {
    _ = &wire;
}
