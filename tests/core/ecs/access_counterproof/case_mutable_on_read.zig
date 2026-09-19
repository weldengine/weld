//! A mutable access to a component declared read-only.
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

/// Never called, and referenced so Zig analyses it at all: without a reference
/// neither the trampoline nor the body is analysed and the file compiles by not
/// looking. The generic entry is the only way in — `SystemDescriptor.of` is
/// private — and it takes a live world this fixture has no reason to build.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "mutable_on_read", &spec, body);
}

comptime {
    _ = &wire;
}
