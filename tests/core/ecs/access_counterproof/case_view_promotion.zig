//! Promoting a read declaration to a write one by rebuilding a view over the
//! pointer the restricted one carries.
//!
//! MUST NOT COMPILE. The body is declared `reads(Velocity)` and never calls
//! `getMut` on its own view — it builds a SECOND view, declared
//! `writes(Velocity)`, over the world pointer the first one transports, and
//! writes through that.
//!
//! **WITH `world_erased` TYPED `*anyopaque` THIS COMPILES.** That is the same
//! type for every declared set, so `fromErased` accepts any view's pointer — no
//! cast, no builtin, no diagnostic — while the header claims the escape costs
//! an explicit `@ptrCast`, "a deliberate and greppable act": true of recovering
//! a `*World` and false of the bypass that is actually useful. The refusal
//! lives in `fromErased`'s signature and not in a check.
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

/// Never called, and referenced so Zig analyses it at all: without a reference
/// neither the trampoline nor the body is analysed and the file compiles by not
/// looking. The generic entry is the only way in — `SystemDescriptor.of` is
/// private — and it takes a live world this fixture has no reason to build.
fn wire(sched: *ecs.SystemScheduler, gpa: std.mem.Allocator, world: *ecs.World) !void {
    try sched.registerSystem(gpa, world, .update, "view_promotion", &read_spec, body);
}

comptime {
    _ = &wire;
}
