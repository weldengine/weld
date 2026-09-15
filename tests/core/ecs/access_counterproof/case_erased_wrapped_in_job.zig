//! Counter-proof 6 — the erased world handed to a dispatched body, WRAPPED.
//!
//! MUST NOT COMPILE, and a separate fixture from the bare form on purpose:
//! `carriesMarkedIn` enters every composite, so declaring the marker on the type
//! covers a pointer buried in a struct as well as a bare one — which only a
//! fixture exercising the wrapped form establishes.
//!
//! This asserts the REFUSAL alone, the harness comparing compilation and not
//! message text. The reason's own witness lives beside the walk, in
//! `foundation/job_bound.zig`, where it can be read at runtime.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.writes(ecs.Transform)};

const Carrier = struct {
    world: *ecs.view.ErasedFor(&spec),
    stride: usize,
};

fn wire(c: Carrier) void {
    ecs.command_buffer.refuseCommandBufferInArgs(@TypeOf(.{c}));
}

comptime {
    _ = &wire;
}
