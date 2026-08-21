//! M1.1.15 acceptance suite for `PhysicsWorld` — the owner of the per-tick cycle.
//!
//! What this file measures is the ORCHESTRATION and never the physics: the order the
//! stages of `engine-physics-solver.md` §1.7 run in, the substep cadence, the proxy
//! lifetime, the class assignment and the wake composition. What each stage COMPUTES
//! is measured by the suite of the stage — `solver_test.zig`, `sleep_test.zig`,
//! `sensor_test.zig`, `island_test.zig` — and re-measuring it here would only put a
//! second copy of those claims where nobody maintains them.
//!
//! Every counter-factual named in a test below was RUN, and its effect is written
//! next to the assertion it justifies. A control whose green alone has been seen is
//! indistinguishable from a control that judges nothing
//! (`engine-development-workflow.md` §5.5).

const std = @import("std");
const config = @import("../config.zig");
const world_mod = @import("../world.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const PhysicsWorld = world_mod.PhysicsWorld;
const Step = world_mod.Step;
const StepTrace = world_mod.StepTrace;
const BodyId = api.BodyId;
const testing = std.testing;

const fixed_dt: Real = 1.0 / 60.0;
const gravity_y: Real = -9.81;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

/// A static ground box (half-extents 5 × 0.5 × 5) centred on the origin, so its top
/// face is at `y = 0.5`, plus a dynamic unit box resting FLUSH on it (centre at
/// `y = 1.0`, zero penetration). Contacts therefore exist from the first tick, which
/// is what every test below needs and none of them should have to arrange.
fn groundAndRestingBox(gpa: std.mem.Allocator, world: *PhysicsWorld) !BodyId {
    const ground_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

    var ground = api.BodyDescriptor{
        .entity = .{ .index = 0, .generation = 0 },
        .body_type = .static,
        .shape = ground_shape,
    };
    ground.restitution = 0;
    _ = try world.addBody(gpa, ground);

    var box = api.BodyDescriptor{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .dynamic,
        .shape = box_shape,
    };
    box.mass = 1;
    box.restitution = 0;
    box.position = av3(0, 1.0, 0);
    return world.addBody(gpa, box);
}

/// Constraint points the world currently holds, summed over its manifolds — the
/// quantity the warm start injects once per substep.
fn totalConstraintPoints(world: *const PhysicsWorld) u32 {
    var total: u32 = 0;
    for (world.constraints.items) |c| total += c.count;
    return total;
}

// --- step order ---------------------------------------------------------------

test "step executes the eleven cycle steps in the frozen order" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndRestingBox(gpa, &world);

    var trace: StepTrace = .{};
    world.trace = &trace;
    try world.step(gpa);

    // THE ORDER, read as an order. `expectEqualSlices` compares position by
    // position, so this fails on a permutation that a "did each stage run?" check
    // would pass — which is the whole difference between reading a sequence and
    // reading a set.
    //
    // The nine entries are the anchors of §1.7 that EXECUTE. Three do not, and their
    // absence is the contract: step 3 is read-only and owns no code, step 5 bis is
    // the empty composite seam of §1.7.3, and step 8 is retired at a frozen number.
    // Anchors 6 and 7 are one `rigid.solveTick` call, whose internal order (substep
    // loop, then restitution) `rigid/solver.zig` pins where it can be seen.
    const expected = [_]Step{
        .broadphase_pairs, //   (1)
        .pair_retention, //     (2)
        .build_constraints, //  (4)
        .island_partition, //   (5)
        .solve_tick, //         (6) + (7)
        .harvest_contacts, //   (9)
        .proxy_update, //       (10)
        .sensor_pass, //        (10 bis)
        .sleep_transition, //   (11)
    };
    try testing.expectEqualSlices(Step, &expected, trace.order());

    // NON-VACUITY, both halves. A trace that recorded nothing would compare equal to
    // an empty expectation, and a truncated one would compare equal to a short
    // expectation: the length is pinned against the module's own count, and the
    // recorder is required to have dropped nothing.
    try testing.expectEqual(world_mod.executed_step_count, trace.order().len);
    try testing.expectEqual(@as(u32, 0), trace.dropped);

    // COUNTER-FACTUAL, run: swapping the `proxy_update` and `sensor_pass` calls in
    // `world.zig` — a permutation with no effect on any body, since the sensor pass
    // takes a `*const BodyManager` — fails on THIS assertion and on nothing else in
    // the suite. That is the property being claimed: the order is asserted here, and
    // here only, so it cannot move in silence.
}

test "the step trace is reset per tick and its order is stable across ticks" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndRestingBox(gpa, &world);

    var trace: StepTrace = .{};
    world.trace = &trace;

    // The recorder saturates rather than wrapping, so a caller that forgets to reset
    // sees a SHORT second tick and never a plausible one. Both readings are asserted:
    // without the reset the second tick drops every stage it tried to record.
    try world.step(gpa);
    try world.step(gpa);
    try testing.expectEqual(world_mod.executed_step_count, trace.order().len);
    try testing.expectEqual(@as(u32, world_mod.executed_step_count), trace.dropped);

    trace.reset();
    try testing.expectEqual(@as(usize, 0), trace.order().len);
    try world.step(gpa);
    try testing.expectEqual(Step.broadphase_pairs, trace.order()[0]);
    try testing.expectEqual(Step.sleep_transition, trace.order()[trace.order().len - 1]);
    try testing.expectEqual(@as(u32, 0), trace.dropped);
}

// --- substep cadence ----------------------------------------------------------

test "substep cadence: warm start is applied inside the substep loop, every substep" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndRestingBox(gpa, &world);

    // FOUR substeps — the default, and the point of the test. At one substep a
    // per-substep application and a once-per-tick application inject exactly the
    // same number of points, so a single-substep run cannot tell them apart and
    // measuring there would be measuring nothing.
    try testing.expectEqual(@as(u32, 4), world.cfg.substep_count);
    try world.step(gpa);

    const points = totalConstraintPoints(&world);
    // NON-VACUITY: a box resting flush on a box gives a face-face manifold, so there
    // is something to inject. Without this the equality below holds at zero.
    try testing.expect(points > 0);
    try testing.expectEqual(@as(u32, 4), world.solver_stats.substeps_executed);
    try testing.expectEqual(points * 4, world.solver_stats.warm_start_injections);

    // THE PAIRED NEGATIVE, at one substep on the same scene: the injections collapse
    // to exactly one pass over the points. Together the two readings discriminate —
    // an implementation that seeded once per tick would report `points` in BOTH, and
    // one that applied per substep reports `4 · points` here and `points` there.
    var single = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer single.deinit(gpa);
    single.cfg.substep_count = 1;
    _ = try groundAndRestingBox(gpa, &single);
    try single.step(gpa);

    const single_points = totalConstraintPoints(&single);
    try testing.expect(single_points > 0);
    try testing.expectEqual(@as(u32, 1), single.solver_stats.substeps_executed);
    try testing.expectEqual(single_points, single.solver_stats.warm_start_injections);

    // COUNTER-FACTUAL, run: hoisting the `applyWarmStartRange` loop out of the
    // substep loop in `rigid/solver.zig` makes the four-substep reading fall to
    // `points` and leaves the one-substep reading untouched — the asymmetry is what
    // this test is for.
}

test "the solve/relax sweep counts are one per substep" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndRestingBox(gpa, &world);
    try world.step(gpa);

    // `3·substep_count + 1` constraint sweeps per tick is the structural cost §1.8.2
    // states: solve, relax and warm start per substep, restitution once. Two of the
    // three are counted here; the third is the injection count above.
    try testing.expectEqual(world.solver_stats.substeps_executed, world.solver_stats.solve_sweeps);
    try testing.expectEqual(world.solver_stats.substeps_executed, world.solver_stats.relax_sweeps);
}

// --- step 10 bis --------------------------------------------------------------

test "step 10 bis runs on a world that was never told about sensors" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer world.deinit(gpa);

    // A trigger and a body inside it. Nothing switches the sensor pass on, because
    // there is nothing to switch: step 10 bis is unconditional. Until M1.1.15 the
    // pass was gated on a `sensors_on` flag the harness carried and that defaulted to
    // FALSE, which for a production world would mean sensors silently do not work —
    // and the determinism scenario asserted that flag rather than this property. That
    // assertion is gone; this is what replaced it, and it is obtained by a different
    // mechanism: it reads the STATE the pass produces, not a switch feeding it.
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(1, 1, 1) } });
    const sphere_shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.25 } });

    var trigger = api.BodyDescriptor{
        .entity = .{ .index = 7, .generation = 0 },
        .body_type = .static,
        .shape = box_shape,
    };
    trigger.is_trigger = true;
    const trigger_id = try world.addBody(gpa, trigger);

    var visitor = api.BodyDescriptor{
        .entity = .{ .index = 9, .generation = 0 },
        .body_type = .dynamic,
        .shape = sphere_shape,
    };
    visitor.mass = 1;
    visitor.gravity_factor = 0;
    _ = try world.addBody(gpa, visitor);

    try world.step(gpa);

    try testing.expectEqual(@as(usize, 1), world.sensors.current.items.len);
    try testing.expectEqual(@as(usize, 1), world.sensors.entered.items.len);
    const pair = world.sensors.current.items[0];
    try testing.expectEqual(@as(u32, 7), pair.trigger.index);
    try testing.expectEqual(@as(u32, 9), pair.other.index);

    // And the trigger reached NO constraint: `is_trigger` removes the physical
    // response absolutely (§1.13.7), so the pass that saw it produced no contact.
    // The positive above without this would be satisfied by a world in which a
    // trigger both detects and collides.
    try testing.expectEqual(@as(usize, 0), world.constraints.items.len);
    try testing.expectEqual(@as(?bool, true), world.bm.isTrigger(trigger_id));
}

test "a world with no trigger produces an empty sensor state rather than skipping" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    _ = try groundAndRestingBox(gpa, &world);

    var trace: StepTrace = .{};
    world.trace = &trace;
    try world.step(gpa);

    // The pass RAN — the trace says so — and produced nothing, which is the correct
    // answer for a scene with no trigger. The distinction matters: "the state is
    // empty" is satisfied both by a pass that ran over nothing and by a pass that
    // never ran, and only the first is the contract.
    var saw_sensor_pass = false;
    for (trace.order()) |s| {
        if (s == .sensor_pass) saw_sensor_pass = true;
    }
    try testing.expect(saw_sensor_pass);
    try testing.expectEqual(@as(usize, 0), world.sensors.current.items.len);
    try testing.expectEqual(@as(usize, 0), world.sensors.entered.items.len);
    try testing.expectEqual(@as(usize, 0), world.sensors.exited.items.len);
}
