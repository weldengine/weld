//! M1.1.7 acceptance suite for the NGS position solver
//! (`engine-physics-forge.md` §1.7.2), driven through the full per-tick pipeline.
//!
//! The harness is NOT duplicated here: `World` comes from `solver_test.zig`, which
//! owns the single definition of the normative per-tick cycle (its file header
//! documents the eight steps). Copying it would let the two suites drift apart on
//! the one thing that must not drift.

const std = @import("std");
const config = @import("../config.zig");
const harness = @import("solver_test.zig");
const api = @import("weld_forge");

const Real = config.Real;
const World = harness.World;
const vr = harness.vr;
const av3 = harness.av3;
const groundAndBox = harness.groundAndBox;
const testing = std.testing;

test "position_iterations = 0 reproduces the velocity-only resting behaviour" {
    const gpa = testing.allocator;
    var world = World.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    // The M1.1.6 configuration: velocity pass only, no position correction at all.
    world.cfg.position_iterations = 0;
    const box = try groundAndBox(gpa, &world, 2.0, 0);

    var y_impact: ?Real = null;
    var min_after_impact: Real = 1e30;
    var t: u32 = 0;
    while (t < 300) : (t += 1) {
        try world.step(gpa);
        const y = world.bm.position(box).?.toArray()[1];
        if (y_impact == null and world.constraints.items.len > 0) y_impact = y;
        if (y_impact != null and y < min_after_impact) min_after_impact = y;
    }
    const y_final = world.bm.position(box).?.toArray()[1];

    // The pass early-returns before evaluating a single point.
    try testing.expectEqual(@as(u32, 0), world.position_result.iterations_run);
    try testing.expectEqual(@as(?Real, null), world.position_result.min_separation);

    // The M1.1.6 statement, preserved verbatim: the penetration is bounded at its
    // at-impact value and never recovered.
    try testing.expect(y_impact != null);
    try testing.expect(min_after_impact >= y_impact.? - 1e-3);
    try testing.expectApproxEqAbs(y_impact.?, y_final, 1e-3);

    // Discrimination guard: this rest is measurably BELOW the envelope the same
    // scene satisfies with the position pass enabled (`solver_test.zig`'s tightened
    // resting test), so the pin really observes the absence of NGS, not a scene
    // that happens to land near the analytic rest anyway.
    try testing.expect(y_final < 1.0 - 2 * @as(Real, 0.005));
}
