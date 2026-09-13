//! Counter-proof 5 — the erased world handed to a dispatched body, bare.
//!
//! MUST NOT COMPILE. `View` has always been refused in a worker's arguments,
//! because it reaches any entity of the world by handle while a worker owns one
//! range. `*ErasedFor(spec)` is what a view rebuilds itself from with NO cast —
//! `fromErased` takes precisely this type — so passing one hands over the same
//! reach under a different name.
//!
//! **It was NOT refused until the marker was put on the type.** `ErasedFor` was
//! created to close a promotion between views and was born without the
//! guarantee its twin carried, because that guarantee is implemented in another
//! file. Measured before the fix: `carriesMarked(*ErasedFor)` returned false
//! bare AND wrapped, while `carriesMarked(View)` returned true.
//!
//! The subject here is the TYPE's marker, not an entry's wiring: that the four
//! dispatching entries call this guard is asserted by the derived census in
//! `tests/ecs/hybrid_query_test.zig`. What this fixture answers is whether the
//! guard has anything to find.

const std = @import("std");
const ecs = @import("weld_core").ecs;

const spec = [_]ecs.Access{ecs.Access.writes(ecs.Transform)};

fn wire(p: *ecs.view.ErasedFor(&spec)) void {
    ecs.command_buffer.refuseCommandBufferInArgs(@TypeOf(.{p}));
}

comptime {
    _ = &wire;
}
