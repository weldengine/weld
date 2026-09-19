//! An access the declaration does not name.
//!
//! MUST NOT COMPILE. The declared set names `Transform` only; the body reaches
//! `Velocity`, which no entry grants in either direction.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.writes(ecs.Transform)};

fn body(ctx: ecs.SystemContextOf(&spec)) anyerror!void {
    const e = ecs.EntityId.dead;
    _ = ctx.view.get(ecs.Velocity, e);
}

/// Never called, and referenced so Zig analyses it at all: without a reference
/// neither the trampoline nor the body is analysed and the file compiles by not
/// looking. The generic entry is the only way in — `SystemDescriptor.of` is
/// private — and it takes a live world this fixture has no reason to build.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "undeclared", &spec, body);
}

comptime {
    _ = &wire;
}
