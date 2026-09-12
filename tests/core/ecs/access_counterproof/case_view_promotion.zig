//! Counter-proof 4 — promoting a read declaration to a write one by rebuilding
//! a view over the pointer the restricted one carries.
//!
//! MUST NOT COMPILE. The body is declared `reads(Velocity)` and never calls
//! `getMut` on its own view — it builds a SECOND view, declared
//! `writes(Velocity)`, over the world pointer the first one transports, and
//! writes through that.
//!
//! **On `main` this compiled.** `world_erased` was `*anyopaque`, the same type
//! for every declared set, so `fromErased` accepted any view's pointer: no
//! cast, no builtin, no diagnostic. The file header claimed the escape cost an
//! explicit `@ptrCast` "a deliberate and greppable act", which was true of
//! recovering a `*World` and false of the bypass that is actually useful. The
//! refusal now lives in `fromErased`'s signature rather than in a check.
//!
//! The diagnostic is the COMPILER's and not the view's marker: nothing here
//! reaches an access test, because the type error fires first — which is the
//! point. A refusal that needed `weld-access-refused` would mean the promotion
//! had already succeeded and the view was arguing about it afterwards.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const read_spec = [_]ecs.Access{ecs.Access.reads(ecs.Velocity)};
const write_spec = [_]ecs.Access{ecs.Access.writes(ecs.Velocity)};

fn body(ctx: ecs.SystemContextOf(&read_spec)) anyerror!void {
    const e = ecs.EntityId.dead;

    // Legitimate, and left in so the case is not refused for the wrong reason:
    // the declared read compiles.
    _ = ctx.view.get(ecs.Velocity, e);

    // THE PROMOTION. `ctx.view.world_erased` is a `*ErasedFor(&read_spec)` and
    // `View(&write_spec).fromErased` takes a `*ErasedFor(&write_spec)`.
    const promoted = ecs.View(&write_spec).fromErased(ctx.view.world_erased);
    _ = promoted.getMut(ecs.Velocity, e);
}

/// Registration is what forces the body to be analysed, and it is written as a
/// function that is never called: `SystemDescriptor.of` is private now — the
/// scheduler refuses to accept a `run` and an `accesses` supplied separately —
/// so the only way in is the generic entry, which needs a live world this
/// fixture has no reason to build. Without a reference Zig analyses neither the
/// trampoline nor the body, and the file would compile by not looking.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "view_promotion", &read_spec, body);
}

comptime {
    _ = &wire;
}
