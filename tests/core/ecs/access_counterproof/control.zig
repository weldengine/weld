//! The POSITIVE control of the counter-proof corpus: this one MUST compile.
//!
//! Without it the three refusals beside it are vacuous — a view that refused
//! every access would satisfy all three and prove nothing. It is built in the
//! same execution as the refusals, so "the guard fires" and "the guard does not
//! fire on legitimate code" are established together or not at all.
//!
//! It exercises the three grants the model distinguishes: a declared read, a
//! declared write, and a read reaching through a write declaration.

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

const descriptor = ecs.SystemDescriptor.of(.update, "control", &spec, body);

comptime {
    // Forces the trampoline — and through it `body` — to be analysed. Without a
    // reference Zig analyses neither, and the file would compile by not looking.
    _ = descriptor;
}
