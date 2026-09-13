//! Counter-proof 6 — the erased world handed to a dispatched body, WRAPPED.
//!
//! MUST NOT COMPILE, and it is a separate fixture from the bare form on
//! purpose. `carriesMarkedIn` enters every composite and follows pointers, so
//! declaring the marker on the type is supposed to cover a pointer buried in a
//! struct as well as a bare one — supposed to, until a fixture exercises it.
//! Measured before the fix: this form returned false exactly like the bare one.
//!
//! **Its diagnostic is WEAKER than the bare form's, and that is recorded rather
//! than repaired here.** `reasonOf` walks only `.pointer` and `.optional` where
//! `carriesMarkedIn` enters everything, so a marker reached through a FIELD
//! refuses correctly and explains nothing — `M1.D.24`, which this milestone
//! named and left to the bound's owner. The refusal is what this fixture
//! asserts; the missing reason is that debt's, not this one's.

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
