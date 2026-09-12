//! Counter-proof 2 — a mutable access to a component declared read-only.
//!
//! MUST NOT COMPILE. `Velocity` is declared `reads`, and the body calls
//! `getMut` on it. The read side of the same declaration compiles, which is
//! what makes this case about the read/write distinction and not about
//! membership.

const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.reads(ecs.Velocity)};

fn body(ctx: ecs.SystemContextOf(&spec)) anyerror!void {
    const e = ecs.EntityId.dead;
    _ = ctx.view.get(ecs.Velocity, e);
    _ = ctx.view.getMut(ecs.Velocity, e);
}

const descriptor = ecs.SystemDescriptor.of(.update, "mutable_on_read", &spec, body);

comptime {
    _ = descriptor;
}
