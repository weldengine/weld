//! The bidirectional slice, run (M1.1.15.2 G7).
//!
//! C1.0's gate is that an Etch rule reaches a Tier 1 module AND that a Tier 1
//! module reaches an Etch rule. A slice that called without receiving would close
//! neither half, so both are asserted and each carries what makes it non-vacuous.

const std = @import("std");
const arena = @import("arena_slice");
const testing = std.testing;

test "the arena slice drives forge_3d in both directions" {
    const gpa = testing.allocator;
    // Two ticks, because the Zig → Etch half has ONE TICK of latency by
    // construction: the sensor deltas exist only after step 10 bis and the
    // interpreter's sources drain at the head of a tick.
    const observed = try arena.run(gpa, 2);

    // The slice COMPILES — a rule calling a service it cannot resolve, or observing
    // an event type nothing declares, would be diagnostics here rather than zero.
    try testing.expectEqual(@as(usize, 0), observed.diagnostics);

    // ETCH → ZIG. The rule asked the service and the answer came back from the real
    // broadphase: a wall stands on the ray at x = 10.
    try testing.expectEqual(@as(i64, 1), observed.wall_seen);

    // ZIG → ETCH. Forge's own sensor pass produced a crossing, it reached the Tier 0
    // bus, the bridge put it in front of the rules, and an `@on_event` rule counted
    // it. EXACTLY ONE: the pair enters once and persists, and a `TriggerStay` that
    // does not exist is what keeps the count from growing with the ticks.
    try testing.expectEqual(@as(i64, 1), observed.entered);

    // NON-VACUITY on that one: run it for more ticks and the count does NOT grow,
    // which is what tells an ENTER apart from a per-tick republication.
    const longer = try arena.run(gpa, 8);
    try testing.expectEqual(@as(i64, 1), longer.entered);
    try testing.expectEqual(@as(i64, 1), longer.wall_seen);
}
