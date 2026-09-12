//! Counter-proof 1 — an access the declaration does not name.
//!
//! MUST NOT COMPILE. The declared set names `Transform` only; the body reaches
//! `Velocity`, which no entry grants in either direction.

const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.writes(ecs.Transform)};

fn body(ctx: ecs.SystemContextOf(&spec)) anyerror!void {
    const e = ecs.EntityId.dead;
    _ = ctx.view.get(ecs.Velocity, e);
}

const descriptor = ecs.SystemDescriptor.of(.update, "undeclared", &spec, body);

comptime {
    _ = descriptor;
}
