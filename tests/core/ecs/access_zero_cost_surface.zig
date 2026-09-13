//! The witness pair whose emitted assembly `zig build ecs-access-zero-cost`
//! compares, instruction for instruction.
//!
//! Two functions that differ in exactly one thing: one reaches a component
//! through a declared-access `View`, the other through a `*World` directly.
//! Everything else — the component, the entity parameter, the return type — is
//! identical, so a difference in the listing can only come from the view.
//!
//! `export` rather than `pub`: the scanner needs a stable, unmangled label to
//! anchor each body on, and an unexported function may not reach the object at
//! all under Zig's lazy analysis.
//!
//! **Both take `*anyopaque`, and that is what makes the pair a witness rather
//! than a comparison of two calling conventions.** A `View` is a struct with
//! automatic layout, which an exported function cannot take at all; giving one
//! side a `*World` and the other a view would have measured the ABI and not the
//! wrapper. With the same parameter on both, the only difference left is the
//! path from that pointer to the component — a narrowing `@ptrCast`,
//! `fromErased` and the membership test on one side, a bare cast on the other.
//!
//! The view side gained that `@ptrCast` when the erased world stopped being
//! `*anyopaque` and became an opaque generated per declared set. It is the same
//! cast the generated trampoline performs, it is a no-op at runtime, and the
//! comparison below is what says so rather than this sentence.

const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.writes(ecs.Transform)};

/// Through the view. Its declared set grants the write, so the membership test
/// passes and must leave nothing behind.
export fn weld_zero_cost_via_view(p: *anyopaque, e: ecs.EntityId) ?*ecs.Transform {
    return ecs.View(&spec).fromErased(@ptrCast(p)).getMut(ecs.Transform, e);
}

/// Through the world, unrestricted. The reference listing.
export fn weld_zero_cost_via_world(p: *anyopaque, e: ecs.EntityId) ?*ecs.Transform {
    const w: *ecs.World = @ptrCast(@alignCast(p));
    return w.getMut(ecs.Transform, e);
}
