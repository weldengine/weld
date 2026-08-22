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

test "step executes the nine coded steps of the eleven-anchor cycle in order" {
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

    // COUNTER-FACTUALS, RUN — five, each naming the PAIR it moved, because a
    // counter-factual that does not name its object does not bound its conclusion.
    //
    // Two pairs are used, and they differ in one property that decides everything
    // below: whether inverting the two stages has a PHYSICAL consequence.
    //   - `(proxy_update, sensor_pass)` — stages 10 and 10 bis. Inverting them is
    //     physically harmless: the sensor pass takes a `*const BodyManager`, so it
    //     cannot alter one bit of body state, and reading proxies from before the
    //     update instead of after changes only what the sensor state reports.
    //   - `(build_constraints, island_partition)` — stages 4 and 5. Inverting them
    //     partitions LAST tick's constraint array and then rebuilds it, so the island
    //     ranges the solver consumes no longer describe the constraints it solves.
    //
    // (A) CALLS of 10 / 10 bis swapped: `1 failed` of 561, and it is this test.
    // (D) CALLS of 4 / 5 swapped: `4 failed, 35 crashed`.
    // (C) BODIES of 10 / 10 bis swapped, each `enter()` left in place: the whole suite
    //     GREEN, 560/561, this test included.
    // (C') BODIES of 4 / 5 swapped, each `enter()` left in place: `3 failed, 35
    //     crashed`, and this test PASSES — which is exactly (D) MINUS this test.
    // (B) the warm start hoisted out of the substep loop: see the cadence test below.
    //
    // WHAT THAT MEASURES, in its bounded form. A record separated from its work is
    // undetectable ONLY where inverting the two stages is physically harmless: (C') is
    // the measurement that says so, since moving the work without its record produced
    // the same 35 crashes as moving the calls. Everywhere the order has a physical
    // consequence the physics guards fire on their own, loudly, and this test is not
    // load-bearing there.
    //
    // WHICH IS WHY THIS TEST EXISTS, and it is the claim that was buried under the
    // residual: the one adjacency where nothing else fires is precisely the harmless
    // one — 10 / 10 bis, where (A) reports `1 failed` of 561 and every other guard in
    // the suite stays green. Without this assertion that adjacency could be inverted
    // in silence. The structural convention — each `enter()` the first statement of
    // the stage method carrying its name — is what keeps the recorded order the
    // executed one on the harmless pairs, and it is the only place it has to.
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
    try testing.expectEqual(points * 4, world.solver_stats.not_reported.warm_start_injections);

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
    try testing.expectEqual(single_points, single.solver_stats.not_reported.warm_start_injections);

    // COUNTER-FACTUAL, RUN: hoisting the `applyWarmStartRange` loop out of the substep
    // loop in `rigid/solver.zig` makes this test report `expected 16, found 4` — the
    // four-substep reading collapsing to `points` — while the one-substep reading
    // above is untouched. Six physics tests fall with it, including the determinism
    // witness; this is the only one of the seven whose message names the cause.
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

// --- proxies and body lifetime (Gate B) ---------------------------------------

const BroadphaseLayer = @import("../pipeline/broadphase.zig").BroadphaseLayer;

/// The four per-class proxy counts, in enum order — the only shape a count of proxies
/// is allowed to take here. A TOTAL is satisfied by a body inserted into the wrong
/// class, which is the whole defect these tests exist to catch.
fn classCounts(world: *const PhysicsWorld) [4]u32 {
    return .{
        world.proxyCountIn(.static),
        world.proxyCountIn(.dynamic),
        world.proxyCountIn(.debris),
        world.proxyCountIn(.trigger),
    };
}

fn addBoxBody(
    gpa: std.mem.Allocator,
    world: *PhysicsWorld,
    body_type: api.BodyType,
    is_trigger: bool,
    entity_index: u32,
    centre: [3]f32,
) !BodyId {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var desc = api.BodyDescriptor{
        .entity = .{ .index = entity_index, .generation = 0 },
        .body_type = body_type,
        .shape = shape,
    };
    desc.position = av3(centre[0], centre[1], centre[2]);
    desc.is_trigger = is_trigger;
    if (body_type == .dynamic) desc.mass = 1;
    return world.addBody(gpa, desc);
}

test "a proxy exists for every live body and for every character presence, and none outlives its owner" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer world.deinit(gpa);

    // Five bodies spread over three classes, plus a HALF-SPACE, which is the case a
    // tree-only count would miss: it has no AABB at all and lives in the layer's
    // unbounded list (`engine-physics-shapes.md` §1.11.15). `proxyCountIn` walks both.
    const ground = try addBoxBody(gpa, &world, .static, false, 1, .{ 0, 0, 0 });
    const dyn = try addBoxBody(gpa, &world, .dynamic, false, 2, .{ 0, 5, 0 });
    const platform = try addBoxBody(gpa, &world, .kinematic, false, 3, .{ 10, 0, 0 });
    const trigger = try addBoxBody(gpa, &world, .static, true, 4, .{ 20, 0, 0 });

    const plane_shape = try world.store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = -10 } });
    const plane = api.BodyDescriptor{
        .entity = .{ .index = 5, .generation = 0 },
        .body_type = .static,
        .shape = plane_shape,
    };
    _ = try world.addBody(gpa, plane);

    // AND A CHARACTER — trap named in the gate: the presence is inserted by the
    // orchestrator and by nothing else, so a counting scene without one is green on the
    // empty set of exactly what this test exists to guard.
    const hero = try world.createCharacter(gpa, .{ .entity = .{ .index = 6, .generation = 0 } });
    try testing.expect((try world.chars.getCharacterInnerBody(hero)) != null);

    // static  = ground box + half-space              -> 2
    // dynamic = dynamic box + kinematic platform + presence -> 3
    // debris  = nothing declares it                  -> 0
    // trigger = the sensor                           -> 1
    try testing.expectEqual([4]u32{ 2, 3, 0, 1 }, classCounts(&world));

    // NOTHING OUTLIVES ITS OWNER, measured AFTER destruction and in a scene where an
    // orphan WOULD be visible: five other proxies remain, so a leaked one shows up as an
    // excess in its class rather than being hidden by an empty world.
    world.destroyCharacter(gpa, hero);
    try testing.expectEqual([4]u32{ 2, 2, 0, 1 }, classCounts(&world));

    world.removeBody(dyn);
    try testing.expectEqual([4]u32{ 2, 1, 0, 1 }, classCounts(&world));

    world.removeBody(trigger);
    try testing.expectEqual([4]u32{ 2, 1, 0, 0 }, classCounts(&world));

    world.removeBody(platform);
    world.removeBody(ground);
    try testing.expectEqual([4]u32{ 1, 0, 0, 0 }, classCounts(&world));
}

test "trigger role wins over body type in class assignment" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer world.deinit(gpa);

    // THE PAIR IS THE TEST. A kinematic sensor alone would be satisfied by an
    // implementation that sends every KINEMATIC body to `trigger`; its twin without the
    // role pins that the discriminant is `is_trigger` and not the body type. The two
    // differ in exactly one field.
    const sensor_body = try addBoxBody(gpa, &world, .kinematic, true, 1, .{ 0, 0, 0 });
    const plain = try addBoxBody(gpa, &world, .kinematic, false, 2, .{ 10, 0, 0 });

    try testing.expectEqual([4]u32{ 0, 1, 0, 1 }, classCounts(&world));
    try testing.expectEqual(@as(?bool, true), world.bm.isTrigger(sensor_body));
    try testing.expectEqual(@as(?bool, false), world.bm.isTrigger(plain));
    try testing.expectEqual(@as(?api.BodyType, .kinematic), world.bm.bodyType(sensor_body));
    try testing.expectEqual(@as(?api.BodyType, .kinematic), world.bm.bodyType(plain));

    // And the rule read directly, in both orders, so the priority is asserted and not
    // merely exhibited by a scene that happens to agree with it.
    const BM = @TypeOf(world.bm);
    try testing.expectEqual(BroadphaseLayer.trigger, BM.broadLayerFor(true, .kinematic));
    try testing.expectEqual(BroadphaseLayer.trigger, BM.broadLayerFor(true, .static));
    try testing.expectEqual(BroadphaseLayer.trigger, BM.broadLayerFor(true, .dynamic));
    try testing.expectEqual(BroadphaseLayer.dynamic, BM.broadLayerFor(false, .kinematic));
    try testing.expectEqual(BroadphaseLayer.static, BM.broadLayerFor(false, .static));
    try testing.expectEqual(BroadphaseLayer.dynamic, BM.broadLayerFor(false, .dynamic));
}

test "a character created without a presence inserts no proxy" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer world.deinit(gpa);

    // The paired negative of the counting test: `inner_body = false` is a legal choice,
    // and it must leave every class empty. Without it, "the presence is inserted" is
    // satisfied by an orchestrator that inserts a proxy for every character whatever the
    // descriptor asked for.
    const ghost = try world.createCharacter(gpa, .{
        .entity = .{ .index = 1, .generation = 0 },
        .inner_body = false,
    });
    try testing.expectEqual(@as(?BodyId, null), try world.chars.getCharacterInnerBody(ghost));
    try testing.expectEqual([4]u32{ 0, 0, 0, 0 }, classCounts(&world));

    const solid = try world.createCharacter(gpa, .{ .entity = .{ .index = 2, .generation = 0 } });
    try testing.expect((try world.chars.getCharacterInnerBody(solid)) != null);
    try testing.expectEqual([4]u32{ 0, 1, 0, 0 }, classCounts(&world));
}

// --- wake composition (Gate C) -------------------------------------------------

/// Step until `id` is asleep, or fail. Sleeping is ON here, deliberately: these tests
/// ask "does this wake?", which is the one question that needs a sleeper.
fn stepUntilAsleep(gpa: std.mem.Allocator, world: *PhysicsWorld, id: BodyId, budget: u32) !u32 {
    var t: u32 = 0;
    while (t < budget) : (t += 1) {
        try world.step(gpa);
        if (world.bm.isSleeping(id).?) return t + 1;
    }
    return error.NeverFellAsleep;
}

test "external mutation wakes and resets the window; a solver-internal write does neither" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndRestingBox(gpa, &world);

    _ = try stepUntilAsleep(gpa, &world, box, 200);
    try testing.expect(world.bm.isSleeping(box).?);

    // DIRECTION ONE — the solver's own write path does NOT wake. These are the setters
    // the substep loop and the restitution pass drive on every body in contact, every
    // tick; if they woke, nothing in contact could ever sleep, which is the whole reason
    // §1.8.4 splits the two intentions.
    //
    // THE WINDOW IS READ AS A VALUE AND NOT AS A FLAG, and the value corrected this
    // test: a sleeping body's `sleep_time` is the ACCUMULATED window that made it
    // eligible — measured 0.5 s, which is `time_before_sleep` — and zero is what a WAKE
    // writes. So the two directions read DIFFERENT values on the same field, which
    // discriminates more sharply than the pair of zeroes first asserted here.
    const window_asleep = world.bm.sleepTime(box).?;
    try testing.expect(window_asleep > 0);
    world.bm.setLinearVelocity(box, vr(3, 0, 0));
    world.bm.setPosition(box, vr(0, 1.5, 0));
    world.bm.setRotation(box, config.Quatr.identity);
    try testing.expect(world.bm.isSleeping(box).?);
    try testing.expectEqual(window_asleep, world.bm.sleepTime(box).?);

    // DIRECTION TWO — the same write through the gameplay-facing entry wakes AND rearms.
    // Without direction one above, this assertion is satisfied by a rule that wakes on
    // every write whatever its origin, which is not the rule.
    world.setLinearVelocity(box, vr(3, 0, 0));
    try testing.expect(!world.bm.isSleeping(box).?);
    try testing.expectEqual(@as(Real, 0), world.bm.sleepTime(box).?);

    // AND THE WINDOW IS REALLY REARMED, not merely zero-because-it-was-zero: let it
    // accumulate, then wake again and read the drop. A wake that only cleared the
    // sleeping flag would leave the window where it stood.
    _ = try stepUntilAsleep(gpa, &world, box, 200);
    var t: u32 = 0;
    while (t < 5) : (t += 1) try world.step(gpa);
    const accumulated = world.bm.sleepTime(box).?;
    try testing.expect(accumulated > 0);
    world.addImpulse(box, vr(0.5, 0, 0));
    try testing.expect(!world.bm.isSleeping(box).?);
    try testing.expect(world.bm.sleepTime(box).? < accumulated);
}

test "W4: removing a body wakes the sleepers retained in pair with it" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndRestingBox(gpa, &world);

    // A SECOND, DISTANT sleeper that shares no pair with the ground. It is what makes
    // this a test of the wake GRAPH rather than of a wake-everything: after the removal
    // it must still be asleep, and a scene without it cannot tell the two apart.
    const far_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    var far_ground = api.BodyDescriptor{
        .entity = .{ .index = 10, .generation = 0 },
        .body_type = .static,
        .shape = far_shape,
    };
    far_ground.position = av3(100, 0, 0);
    _ = try world.addBody(gpa, far_ground);
    const far_box = try addBoxBody(gpa, &world, .dynamic, false, 11, .{ 100, 1.0, 0 });

    _ = try stepUntilAsleep(gpa, &world, box, 300);
    _ = try stepUntilAsleep(gpa, &world, far_box, 300);
    try testing.expect(world.bm.isSleeping(box).?);
    try testing.expect(world.bm.isSleeping(far_box).?);

    // The ground under `box` goes. `box` is retained in a pair with it, `far_box` is not.
    const ground = world.bodies.items[0].id;
    world.removeBody(ground);
    try testing.expect(!world.bm.isSleeping(box).?);
    try testing.expect(world.bm.isSleeping(far_box).?); // the counter-factual, in scene
}

test "W4: static teleportation wakes the sleepers retained in pair with it" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndRestingBox(gpa, &world);

    const far_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    var far_ground = api.BodyDescriptor{
        .entity = .{ .index = 10, .generation = 0 },
        .body_type = .static,
        .shape = far_shape,
    };
    far_ground.position = av3(100, 0, 0);
    const far_ground_id = try world.addBody(gpa, far_ground);
    const far_box = try addBoxBody(gpa, &world, .dynamic, false, 11, .{ 100, 1.0, 0 });

    _ = try stepUntilAsleep(gpa, &world, box, 300);
    _ = try stepUntilAsleep(gpa, &world, far_box, 300);

    // Teleporting the DISTANT ground wakes the body above IT and leaves the other
    // asleep — both halves in one scene, so "it wakes" and "it wakes only what it
    // should" are read from the same act.
    try world.setBodyTransform(gpa, far_ground_id, vr(100, -0.2, 0), config.Quatr.identity);
    try testing.expect(!world.bm.isSleeping(far_box).?);
    try testing.expect(world.bm.isSleeping(box).?);
}

test "setBodyTransform derives no velocity" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer world.deinit(gpa);

    const platform = try addBoxBody(gpa, &world, .kinematic, false, 1, .{ 0, 0, 0 });
    try testing.expectEqual(Vec3r.zero, world.bm.linearVelocity(platform).?);
    try testing.expectEqual(Vec3r.zero, world.bm.angularVelocity(platform).?);

    // A teleport of one metre over one tick. If this entry derived a velocity the way
    // `moveKinematic` is required to, the linear column would read 60 m/s; it reads
    // zero, and that is the contract — the split between the two entries is what makes
    // `ground_velocity` truthful for one and silent for the other (§1.12.5).
    try world.setBodyTransform(gpa, platform, vr(1, 0, 0), config.Quatr.identity);
    try testing.expectEqual(vr(1, 0, 0), world.bm.position(platform).?);
    try testing.expectEqual(Vec3r.zero, world.bm.linearVelocity(platform).?);
    try testing.expectEqual(Vec3r.zero, world.bm.angularVelocity(platform).?);
}

/// Whether the retained candidate set holds the pair `(a, b)`, in either order.
fn retainsPair(world: *const PhysicsWorld, a: BodyId, b: BodyId) bool {
    const lo = @min(a, b);
    const hi = @max(a, b);
    const key = (@as(u64, lo) << 32) | hi;
    for (world.active.items) |k| {
        if (k == key) return true;
    }
    return false;
}

test "W4: moveCharacter wakes the sleeping bodies retained in pair with the presence" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndRestingBox(gpa, &world);

    // A SECOND sleeper, far away and sharing no pair with the presence. It is the
    // counter-factual, and it is IN THE SCENE rather than in a second test: the same act
    // must wake one and not the other, which is the level the claim is made at.
    const far_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(5, 0.5, 5) } });
    var far_ground = api.BodyDescriptor{
        .entity = .{ .index = 10, .generation = 0 },
        .body_type = .static,
        .shape = far_shape,
    };
    far_ground.position = av3(100, 0, 0);
    _ = try world.addBody(gpa, far_ground);
    const far_box = try addBoxBody(gpa, &world, .dynamic, false, 11, .{ 100, 1.0, 0 });

    // The character stands BESIDE the box, inside the broadphase fat margin and out of
    // contact: close enough that the pair is retained, far enough that no manifold is
    // built. That band is the whole point — if the capsule touched, `build`'s wake
    // fixpoint (§1.8.5) would wake the box every tick and this test would be measuring
    // that instead of W4.
    const hero = try world.createCharacter(gpa, .{
        .entity = .{ .index = 20, .generation = 0 },
        .position = av3(0.85, 0.5, 0),
    });
    const presence = (try world.chars.getCharacterInnerBody(hero)).?;

    _ = try stepUntilAsleep(gpa, &world, box, 300);
    _ = try stepUntilAsleep(gpa, &world, far_box, 300);

    // PRECONDITIONS, asserted so the test cannot pass vacuously: the pair exists, the
    // distant one does not, both bodies are asleep, and nothing is in contact with the
    // presence — the last is what separates W4 from the build fixpoint.
    try testing.expect(retainsPair(&world, presence, box));
    try testing.expect(!retainsPair(&world, presence, far_box));
    try testing.expect(world.bm.isSleeping(box).?);
    try testing.expect(world.bm.isSleeping(far_box).?);
    for (world.constraints.items) |c| {
        try testing.expect(c.body_a != presence and c.body_b != presence);
    }

    // ONE ACT, TWO READINGS.
    _ = try world.moveCharacter(gpa, hero, vr(0, 0, 0.01), fixed_dt);
    try testing.expect(!world.bm.isSleeping(box).?);
    try testing.expect(world.bm.isSleeping(far_box).?);
}

test "W4: a character moving where it is retained with nobody wakes nobody" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndRestingBox(gpa, &world);

    // The same scene as above MINUS the adjacency: the character stands far from the
    // sleeper. The sleeper is present and asleep, so a wake WOULD be visible — which is
    // what makes this a counter-factual at the right instant rather than a world in
    // which nothing sleeps.
    const hero = try world.createCharacter(gpa, .{
        .entity = .{ .index = 20, .generation = 0 },
        .position = av3(40, 0.5, 0),
    });
    const presence = (try world.chars.getCharacterInnerBody(hero)).?;

    _ = try stepUntilAsleep(gpa, &world, box, 300);
    try testing.expect(world.bm.isSleeping(box).?);
    try testing.expect(!retainsPair(&world, presence, box));

    _ = try world.moveCharacter(gpa, hero, vr(0, 0, 0.01), fixed_dt);
    try testing.expect(world.bm.isSleeping(box).?);
}
