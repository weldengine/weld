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

/// A dynamic unit box at `(x, y, z)` — the descriptor the transactionality sweeps use.
fn dynamicAt(shape: api.ShapeId, x: f32, y: f32, z: f32) api.BodyDescriptor {
    var d = api.BodyDescriptor{
        .entity = .{ .index = 7, .generation = 0 },
        .body_type = .dynamic,
        .shape = shape,
    };
    d.mass = 1;
    d.restitution = 0;
    d.position = av3(x, y, z);
    return d;
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
    world.setBodyTransform(far_ground_id, vr(100, -0.2, 0), config.Quatr.identity);
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
    world.setBodyTransform(platform, vr(1, 0, 0), config.Quatr.identity);
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
    _ = try world.moveCharacter(hero, vr(0, 0, 0.01), fixed_dt);
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

    _ = try world.moveCharacter(hero, vr(0, 0, 0.01), fixed_dt);
    try testing.expect(world.bm.isSleeping(box).?);
}

test "moveKinematic derives both velocities from the target pose over dt" {
    const gpa = testing.allocator;
    var world = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer world.deinit(gpa);
    const platform = try addBoxBody(gpa, &world, .kinematic, false, 1, .{ 0, 0, 0 });

    // A ROTATION-ONLY MOVE, which is the case that discriminates: an implementation
    // deriving only the linear half still passes a combined move, because its linear
    // answer would be right and the angular error would hide behind it. Here the position
    // does not change at all, so the linear column must read exactly zero and everything
    // the test asserts is angular.
    //
    // The target is written as quaternion COMPONENTS rather than as an angle, so the
    // expectation comes from the contract — `ω = 2·vec(dq)/dt` — and not from re-running
    // the implementation's own path. `(0, 0.6, 0, 0.8)` is unit by construction.
    const s: Real = 0.6;
    const c: Real = 0.8;
    const target_rot = config.Quatr{ .x = 0, .y = s, .z = 0, .w = c };
    world.moveKinematic(platform, Vec3r.zero, target_rot, fixed_dt);

    const w1 = world.bm.angularVelocity(platform).?.toArray();
    const expected_wy = 2 * s / fixed_dt;
    try testing.expect(std.math.approxEqAbs(Real, expected_wy, w1[1], 1e-4));
    // THE AXIS, asserted too: a formula that got the magnitude from the wrong components
    // would still satisfy a magnitude-only check.
    try testing.expectEqual(@as(Real, 0), w1[0]);
    try testing.expectEqual(@as(Real, 0), w1[2]);
    // And the angular half is genuinely NON-ZERO, which is what a linear-only
    // implementation fails: it would report exactly zero here.
    try testing.expect(@abs(w1[1]) > 1);
    try testing.expectEqual(Vec3r.zero, world.bm.linearVelocity(platform).?);
    // The pose was WRITTEN — this entry moves the body, unlike a velocity-only one.
    try testing.expect(std.math.approxEqAbs(Real, s, world.bm.rotation(platform).?.y, 1e-6));

    // THE SHORT-PATH TWIN. `q` and `−q` are the same rotation, so the same move written
    // with the negated target must give the SAME angular velocity. Without the sign
    // normalisation this reads as a near-full turn the other way — opposite sign and a
    // much larger magnitude — so the pair is what makes the flip observable.
    var twin = PhysicsWorld.initNoSleep(Vec3r.zero, fixed_dt);
    defer twin.deinit(gpa);
    const p2 = try addBoxBody(gpa, &twin, .kinematic, false, 1, .{ 0, 0, 0 });
    const negated = config.Quatr{ .x = 0, .y = -s, .z = 0, .w = -c };
    twin.moveKinematic(p2, Vec3r.zero, negated, fixed_dt);
    const w2 = twin.bm.angularVelocity(p2).?.toArray();
    try testing.expect(std.math.approxEqAbs(Real, w1[1], w2[1], 1e-4));

    // THE LINEAR HALF, on a translation-only move of the same world.
    const before = world.bm.position(platform).?;
    world.moveKinematic(platform, vr(0.5, 0, 0), target_rot, fixed_dt);
    const lin = world.bm.linearVelocity(platform).?.toArray();
    try testing.expect(std.math.approxEqAbs(Real, 0.5 / fixed_dt, lin[0], 1e-3));
    try testing.expectEqual(@as(Real, 0), lin[1]);
    try testing.expectEqual(@as(Real, 0), lin[2]);
    // The rotation did not change this time, so the angular column falls back to zero —
    // the mirror of the rotation-only case above, and what stops a stale `ω` from
    // surviving a move that carried no rotation.
    const w3 = world.bm.angularVelocity(platform).?.toArray();
    try testing.expect(@abs(w3[1]) < 1e-4);
    try testing.expect(std.math.approxEqAbs(Real, 0.5, world.bm.position(platform).?.toArray()[0], 1e-6));
    try testing.expect(before.toArray()[0] == 0);
}

test "addBody is transactional: no fail index leaves a body, a proxy or a registration" {
    // EXHAUSTIVE FAIL-INDEX SWEEP, the shape M1.1.1-HF2 used on the ECS spawn path: a single
    // chosen index proves one branch, and the branch that leaks is exactly the one nobody
    // chose. Every index up to the successful call's allocation count is driven, and after
    // each failure the world must be indistinguishable from one where nothing was attempted.
    const gpa = testing.allocator;

    // Baseline: how many allocations does a successful `addBody` take? Counted rather than
    // guessed, so the sweep covers the whole call and not a prefix of it.
    var counting = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
    var base = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer base.deinit(counting.allocator());
    const base_shape = try base.store.createShape(counting.allocator(), .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const before = counting.allocations;
    _ = try base.addBody(counting.allocator(), dynamicAt(base_shape, 0, 5, 0));
    const needed = counting.allocations - before;
    try testing.expect(needed > 0); // otherwise the sweep below is vacuous

    var idx: usize = 0;
    while (idx < needed) : (idx += 1) {
        var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
        var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
        defer pw.deinit(fa.allocator());
        const shape = try pw.store.createShape(fa.allocator(), .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

        // Arm the failure only now, so the shape creation above is not what fails.
        fa.fail_index = fa.allocations + idx;
        const result = pw.addBody(fa.allocator(), dynamicAt(shape, 0, 5, 0));

        if (result) |_| {
            // This index was not an allocation site of `addBody`; nothing to assert.
            continue;
        } else |_| {
            // THREE observables, because the three fallible steps fail differently: the body
            // store, the broadphase, and the registration list. A single one of them would
            // pass against two of the three leaks.
            try testing.expectEqual(@as(usize, 0), pw.bodies.items.len);
            try testing.expectEqual(@as(u32, 0), pw.proxyCountIn(.dynamic));
            try testing.expectEqual(@as(u32, 0), pw.bm.count());
        }
    }
}

test "proxyOf resolves through the index and rejects a stale generation" {
    const gpa = testing.allocator;
    var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer pw.deinit(gpa);
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

    const first = try pw.addBody(gpa, dynamicAt(shape, 0, 5, 0));
    const first_proxy = pw.proxyOf(first).?;

    // A REMOVED HANDLE ANSWERS `null` even though its index is still in range and still
    // carries the generation it was bound with. That is what `IndexSlot.live` is for: the
    // slot allocator bumps the generation on FREE, so this table keeps the OLD one, and a
    // comparison alone would match and answer with a node the broadphase has freed.
    pw.removeBody(first);
    try testing.expect(pw.proxyOf(first) == null);

    // RECYCLED: the same index comes back with a different generation.
    const second = try pw.addBody(gpa, dynamicAt(shape, 10, 5, 0));
    try testing.expectEqual(
        api.PackedId.unpack(first).index,
        api.PackedId.unpack(second).index,
    ); // the race this test exists for
    try testing.expect(api.PackedId.unpack(first).generation != api.PackedId.unpack(second).generation);

    // The STALE handle still answers `null` — never the new occupant's proxy, which is the
    // failure a bare index lookup would produce.
    try testing.expect(pw.proxyOf(first) == null);
    const second_proxy = pw.proxyOf(second).?;
    try testing.expect(second_proxy.id == pw.bodies.items[0].proxy.id);
    // NON-VACUITY: the lookup really does find something, so the two `null`s above are the
    // absence of a SECOND answer and not the absence of any.
    _ = first_proxy;
}

test "the index and the registration list agree on every live body" {
    // TWO SOURCES ANSWERING DIFFERENTLY ABOUT ONE FACT IS A DEFECT, NEVER AN ENVELOPE — and
    // this one is not hypothetical: the moment the index landed, a caller that re-pointed a
    // body's proxy by writing the registration record alone left `proxyOf` returning a freed
    // node, and step 2 asserted inside `Bvh.proxyAabb`. `rebindProxy` is the single writer
    // that closed it; this is the guard that would catch the next one.
    const gpa = testing.allocator;
    var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer pw.deinit(gpa);
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

    // A mixed population: rigid bodies, a removal that leaves a hole, and a character
    // presence — which is registered by a different entry and is exactly the body the
    // M1.1.15 gate C defect went missing on.
    var ids: [6]api.BodyId = undefined;
    for (&ids, 0..) |*slot, i| {
        // `f32` and NOT `Real`: `BodyDescriptor` is the PUBLIC surface, which follows the
        // world scalar and not the solver's (`engine-physics-queries.md` §1.11.8). The `f64`
        // leg is what caught this — at the default precision the two coincide and the type
        // system proves nothing.
        const x: f32 = @floatFromInt(i * 3);
        slot.* = try pw.addBody(gpa, dynamicAt(shape, x, 5, 0));
    }
    pw.removeBody(ids[2]);
    const hero = try pw.createCharacter(gpa, .{ .entity = .{ .index = 77, .generation = 0 }, .position = av3(-5, 0, 0) });

    // DIRECTION 1 — every registration resolves through the index, to the SAME proxy.
    var walked: usize = 0;
    for (pw.bodies.items) |entry| {
        const viaIndex = pw.proxyOf(entry.id) orelse return error.RegisteredBodyMissingFromIndex;
        try testing.expectEqual(entry.proxy.layer, viaIndex.layer);
        try testing.expectEqual(entry.proxy.kind, viaIndex.kind);
        try testing.expectEqual(entry.proxy.id, viaIndex.id);
        walked += 1;
    }
    // The SIZE of what was walked: five surviving rigid bodies plus one presence.
    try testing.expectEqual(@as(usize, 6), walked);
    try testing.expectEqual(pw.bodies.items.len, walked);

    // DIRECTION 2 — every LIVE index slot names a registration. Without this half, an index
    // that kept a slot alive after a removal would pass direction 1 unnoticed.
    var live_slots: usize = 0;
    for (pw.index.items, 0..) |slot, idx| {
        if (!slot.live) continue;
        live_slots += 1;
        var found = false;
        for (pw.bodies.items) |entry| {
            if (api.PackedId.unpack(entry.id).index == idx) found = true;
        }
        try testing.expect(found);
    }
    try testing.expectEqual(walked, live_slots);

    pw.destroyCharacter(gpa, hero);
    // And the presence leaves BOTH: a destroy that deregistered only the list would leave a
    // live slot here.
    var after: usize = 0;
    for (pw.index.items) |slot| {
        if (slot.live) after += 1;
    }
    try testing.expectEqual(pw.bodies.items.len, after);
    try testing.expectEqual(@as(usize, 5), after);
}

test "the three pose setters are allocation-free and infallible" {
    // REPLACES `test "a failed pose write leaves the store where the broadphase still says
    // it is"` and `test "a failed moveKinematic leaves a retry able to derive the same
    // velocity"`. Both drove a `FailingAllocator` until `Broadphase.update` had to grow its
    // moved log, then asserted the rollback. Neither object exists any more: the log carries
    // at most one entry per proxy per consumption epoch, its capacity is reserved at proxy
    // insertion, and these three entries take no allocator at all — so there is no failure
    // to inject and no rollback to observe.
    //
    // THE SIGNATURE IS THE PROPERTY, and it is a stronger claim than either removed test
    // made: they showed the rollback was correct when the allocation failed, this shows the
    // allocation cannot happen. It is also the exact shape `engine-tier-interfaces.md` §1
    // declares for the three, under the condition it writes on them.
    inline for (.{
        @TypeOf(PhysicsWorld.setBodyTransform),
        @TypeOf(PhysicsWorld.moveKinematic),
        @TypeOf(PhysicsWorld.setCharacterPosition),
    }) |Entry| {
        const info = @typeInfo(Entry).@"fn";
        try testing.expectEqual(void, info.return_type.?);
        inline for (info.params) |param| try testing.expect(param.type.? != std.mem.Allocator);
    }

    // NON-VACUITY, in both directions. `addBody` legitimately keeps an allocator AND an
    // error union, so the walk above is not a predicate that never finds anything; and
    // `resizeCharacter` keeps both too, which is the entry the brief names as unable to join
    // the three because it creates a shape.
    inline for (.{ @TypeOf(PhysicsWorld.addBody), @TypeOf(PhysicsWorld.resizeCharacter) }) |Entry| {
        const info = @typeInfo(Entry).@"fn";
        try testing.expect(@typeInfo(info.return_type.?) == .error_union);
        var takes_allocator = false;
        inline for (info.params) |param| {
            if (param.type.? == std.mem.Allocator) takes_allocator = true;
        }
        try testing.expect(takes_allocator);
    }
}

test "repeated pose writes never grow the moved log, and the store never diverges" {
    // The BEHAVIOURAL half of the property above, on the same scenario the two removed tests
    // drove: escalating teleports, each one leaving the fat box so the tree really re-inserts.
    // They looped until an allocation was needed; here the point is that no number of them
    // needs one, because the log holds ONE entry for the proxy however many times it moves.
    const gpa = testing.allocator;
    var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer pw.deinit(gpa);
    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const id = try pw.addBody(gpa, dynamicAt(shape, 0, 5, 0));

    const proxy = pw.proxyOf(id).?;
    // The layer is read FROM THE PROXY rather than assumed: the class assignment is the
    // orchestrator's (§1.13.3), and hard-coding `.dynamic` here would make this test agree
    // with a wiring change instead of measuring it.
    const layer: usize = @intFromEnum(proxy.layer);

    // 64 moves — the same count the removed loops used as their budget, so the range that
    // used to cross an allocation boundary is the range asserted to cross none.
    const moves: u32 = 64;
    var attempt: u32 = 0;
    while (attempt < moves) : (attempt += 1) {
        const rot = pw.bm.rotation(id).?;
        const target = vr(@as(Real, @floatFromInt(attempt)) * 100 + 100, 5, 0);
        pw.setBodyTransform(id, target, rot);
        // THE STORE NEVER DIVERGES: the pose written is the pose stored, on every single
        // move. The removed tests could only assert this on the failure they provoked.
        try testing.expectEqual(target.toArray(), pw.bm.position(id).?.toArray());
    }

    // ONE entry after 64 moves. Pre-invariant this reads 64.
    try testing.expectEqual(@as(usize, 1), pw.bp.moved[layer].items.len);
    try testing.expectEqual(proxy.id, pw.bp.moved[layer].items[0]);

    // And the broadphase agrees with the store — the fat box of the leaf contains the body's
    // tight box at its final pose. Without this the "one entry" could be bought by not
    // refitting at all.
    const fat = pw.bp.proxyAabb(proxy).?;
    const tight = pw.bm.bodyAabb(&pw.store, id).?;
    try testing.expect(fat.contains(tight.min));
    try testing.expect(fat.contains(tight.max));
}

test "W4: destroying a character wakes the sleepers retained in pair with its presence" {
    // `removeBody` applies W4 in its FIRST instruction and `destroyCharacter` applied it
    // nowhere — one property on one path and not on its twin. The cause does not care which
    // entry removes the body: a sleeper retained against the presence loses what it was
    // beside, and a sleeper emits nothing in broadphase that could notice.
    //
    // Same scene as the `moveCharacter` W4 test, and the same in-scene counter-factual: one
    // act must wake the near sleeper and NOT the distant one, which is the level the claim is
    // made at. A test with only the near body would pass against an implementation that woke
    // the entire world.
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
    _ = try world.addBody(gpa, far_ground);
    const far_box = try addBoxBody(gpa, &world, .dynamic, false, 11, .{ 100, 1.0, 0 });

    const hero = try world.createCharacter(gpa, .{
        .entity = .{ .index = 20, .generation = 0 },
        .position = av3(0.85, 0.5, 0),
    });
    const presence = (try world.chars.getCharacterInnerBody(hero)).?;

    _ = try stepUntilAsleep(gpa, &world, box, 300);
    _ = try stepUntilAsleep(gpa, &world, far_box, 300);

    try testing.expect(retainsPair(&world, presence, box));
    try testing.expect(!retainsPair(&world, presence, far_box));
    try testing.expect(world.bm.isSleeping(box).?);
    try testing.expect(world.bm.isSleeping(far_box).?);

    world.destroyCharacter(gpa, hero);
    try testing.expect(!world.bm.isSleeping(box).?);
    try testing.expect(world.bm.isSleeping(far_box).?);
}

test "removeBody refuses a character presence, and refuses it before any mutation" {
    // THE SEQUENCE, reachable through public entries alone: `getCharacterInnerBody` hands out
    // the presence's `BodyId`, `removeBody` used to release its proxy and its registration, and
    // `destroyCharacter` then released a proxy the broadphase had already freed — tripping
    // `Broadphase.remove`'s assertion.
    //
    // TWO HALVES, because the name claims both. A proxy count alone measures that nothing was
    // RELEASED; it says nothing about the wake, and a scene with no retained sleeper would stay
    // green with the filter moved after `wakeRetainedPartners` — exactly the side effect the
    // name promises is absent.
    const gpa = testing.allocator;
    var world = PhysicsWorld.init(vr(0, gravity_y, 0), fixed_dt);
    defer world.deinit(gpa);
    const box = try groundAndRestingBox(gpa, &world);

    // Beside the box, inside the fat margin and out of contact — the same band the W4 tests
    // use, so the pair is retained without a manifold that would wake the box every tick.
    const hero = try world.createCharacter(gpa, .{
        .entity = .{ .index = 20, .generation = 0 },
        .position = av3(0.85, 0.5, 0),
    });
    const presence = (try world.chars.getCharacterInnerBody(hero)).?;
    _ = try stepUntilAsleep(gpa, &world, box, 300);

    // PRECONDITIONS, so neither half can pass vacuously: the pair exists — without it "still
    // asleep" is true for free — and the box is asleep.
    try testing.expect(retainsPair(&world, presence, box));
    try testing.expect(world.bm.isSleeping(box).?);
    const before = world.proxyCountIn(.dynamic);

    world.removeBody(presence);

    // (a) NOTHING WAS RELEASED. Per class and not a total: a refusal that had still freed the
    // proxy would satisfy a total against another class's count and fail here.
    try testing.expectEqual(before, world.proxyCountIn(.dynamic));
    try testing.expect((try world.chars.getCharacterInnerBody(hero)) != null);
    // (b) AND NOTHING WOKE. This is the half a proxy count cannot reach.
    try testing.expect(world.bm.isSleeping(box).?);

    // DISCRIMINATION, in the same scene: a legitimate W4 producer on the same presence DOES
    // wake it, so (b) is measuring a refused act and not a scene where nothing ever wakes.
    _ = try world.moveCharacter(hero, vr(0, 0, 0.01), fixed_dt);
    try testing.expect(!world.bm.isSleeping(box).?);

    // And the real release path still works, which is what makes the refusal a no-op and not a
    // leak.
    world.destroyCharacter(gpa, hero);
    try testing.expectEqual(before - 1, world.proxyCountIn(.dynamic));
}
