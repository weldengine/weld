//! Counter-proof 6 — the erased world handed to a dispatched body, WRAPPED.
//!
//! MUST NOT COMPILE, and it is a separate fixture from the bare form on
//! purpose. `carriesMarkedIn` enters every composite and follows pointers, so
//! declaring the marker on the type is supposed to cover a pointer buried in a
//! struct as well as a bare one — supposed to, until a fixture exercises it.
//! Measured before the fix: this form returned false exactly like the bare one.
//!
//! **Its diagnostic used to be WEAKER than the bare form's, and is no longer.**
//! `reasonOf` walked only `.pointer` and `.optional` where `carriesMarkedIn`
//! entered everything, so a marker reached through a FIELD refused correctly and
//! explained nothing. The two walks are now the same walk. What this fixture
//! still asserts is only the REFUSAL — the harness compares compilation and not
//! message text — so the reason's own witness lives beside the walk, in
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
