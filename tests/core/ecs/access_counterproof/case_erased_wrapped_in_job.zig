//! MUST NOT COMPILE: the erased world reaching a dispatched body through a
//! struct FIELD, the wrapped form of the bare fixture beside it.
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
