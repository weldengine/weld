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

/// Never called, and referenced so Zig analyses it at all: without a reference
/// neither the trampoline nor the body is analysed and the file compiles by not
/// looking. The generic entry is the only way in — `SystemDescriptor.of` is
/// private — and it takes a live world this fixture has no reason to build.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "control", &spec, body);
}

comptime {
    _ = &wire;
}
