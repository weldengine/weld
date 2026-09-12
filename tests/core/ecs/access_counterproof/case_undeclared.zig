//! Counter-proof 1 — an access the declaration does not name.
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

/// Registration is what forces the body to be analysed, and it is written as a
/// function that is never called: `SystemDescriptor.of` is private now — the
/// scheduler refuses to accept a `run` and an `accesses` supplied separately —
/// so the only way in is the generic entry, which needs a live world this
/// fixture has no reason to build. Without a reference Zig analyses neither the
/// trampoline nor the body, and the file would compile by not looking.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "undeclared", &spec, body);
}

comptime {
    _ = &wire;
}
