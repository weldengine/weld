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

test "an Etch rule commands a physical state and another rule observes it" {
    const gpa = testing.allocator;

    // ZERO TICKS is the counter-factual, and it is built in rather than staged: the
    // world is constructed exactly the same way and no rule ever runs. The lift is
    // fifty metres below the probe ray, nothing is driven, and nothing is seen.
    const untouched = try arena.run(gpa, 0);
    try testing.expectEqual(@as(i64, 0), untouched.lift_driven);
    try testing.expectEqual(@as(i64, 0), untouched.lift_seen);
    try testing.expectApproxEqAbs(@as(f32, -50), untouched.lift_solver_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -50), untouched.lift_ecs_y, 1e-4);

    // ONE TICK. The rule calls `physics.move_kinematic` and the wrapper returns —
    // `-1` would mean the rule's own `catch` ran, which is why the value is three-state
    // and not a boolean: a throw and a rule that never fired would otherwise be one.
    const one = try arena.run(gpa, 1);
    try testing.expectEqual(@as(i64, 1), one.lift_driven);

    // THE PHYSICAL STATE MOVED, and it moved because a rule asked. Fifty metres of +Y,
    // to the pose the rule named.
    try testing.expectApproxEqAbs(@as(f32, 0), one.lift_solver_y, 1e-4);

    // THE MIRROR IS ATOMIC WITH THE CALL and not a publication: this body is under
    // `.gameplay` authority, so `syncOut` publishes NOTHING for it — the ECS `Transform`
    // can only have been written by the wrapper itself.
    try testing.expectApproxEqAbs(@as(f32, 0), one.lift_ecs_y, 1e-4);

    // AND BOTH VELOCITIES WERE DERIVED, which is what separates `move_kinematic` from a
    // teleportation: fifty metres over one tick of 1/60 s is 3000 m/s, mirrored into
    // `Velocity` in the same call. A `set_body_transform` would have reached the same
    // pose with this reading at zero.
    try testing.expectApproxEqAbs(@as(f32, 3000), one.lift_ecs_vy, 1.0);

    // THE LOOP CLOSES INSIDE THE SAME TICK, and that is a stronger statement than the
    // one first written here. `probe_lift` is declared after `drive_lift`, so it runs
    // after it, and its ray — fired upward from twenty metres below — already meets the
    // lift. **Nothing was stepped between them**: the mutation reached the BROADPHASE at
    // the call, which is `moveKinematic` composing its proxy refresh, and not at the
    // next `step`. A wrapper that moved the body and left a stale proxy would answer
    // `false` here and `true` one tick later, so the two readings are not
    // interchangeable.
    try testing.expectEqual(@as(i64, 1), one.lift_seen);
}
