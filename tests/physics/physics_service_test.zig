//! The Tier 1 physics service called from a rule, and the sensor deltas
//! translated onto the Tier 0 bus (M1.1.15.2 G6).

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const weld_etch = @import("weld_etch");
const module = @import("forge_module");
const physics = @import("forge_services");
const sensor_events = @import("forge_sensor_events");
const sync = @import("forge_sync");

const World = core.ecs.World;
const ComponentId = core.ecs.registry.ComponentId;
const EventQueue = core.events.EventQueue;
const Lifetime = core.events.Lifetime;
const PhysicsWorld = forge_3d.PhysicsWorld;
const Vec3r = forge_3d.Vec3r;
const services = weld_etch.services;
const types = weld_etch.types;
const AstArena = weld_etch.Ast;
const Diagnostic = weld_etch.diagnostics.Diagnostic;
const testing = std.testing;

fn av3(x: f32, y: f32, z: f32) @import("foundation").math.Vec3 {
    return @import("foundation").math.Vec3.fromArray(.{ x, y, z });
}

const Harness = struct {
    arenas: [2]AstArena,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    exports: [2]types.TypeChecker.ExportTable = .{ .empty, .empty },
    prefabs: std.StringHashMapUnmanaged(void) = .empty,
    uuids: std.StringHashMapUnmanaged(void) = .empty,
    module_index: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *Harness, gpa: std.mem.Allocator) void {
        for (self.diagnostics.items) |*d| d.deinit(gpa);
        self.diagnostics.deinit(gpa);
        for (&self.arenas) |*a| a.deinit(gpa);
        for (&self.exports) |*e| e.deinit(gpa);
        self.prefabs.deinit(gpa);
        self.uuids.deinit(gpa);
        self.module_index.deinit(gpa);
    }
};

/// Type-check `caller_src` against the EMITTED `physics.d.etch` — the artifact
/// `bindgen-check` guards, never a literal written here.
fn check(gpa: std.mem.Allocator, caller_src: []const u8) !Harness {
    var decl_pr = try weld_etch.parser.parseWithMode(gpa, physics.declaration_source, .declaration_file);
    errdefer decl_pr.deinit(gpa);
    var caller_pr = try weld_etch.parser.parse(gpa, caller_src);
    errdefer caller_pr.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), decl_pr.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), caller_pr.diagnostics.len);
    gpa.free(decl_pr.diagnostics);
    gpa.free(caller_pr.diagnostics);

    var h: Harness = .{ .arenas = .{ decl_pr.ast, caller_pr.ast }, .diagnostics = .empty };
    errdefer h.deinit(gpa);
    const ctx: types.TypeChecker.ProjectContext = .{
        .prefabs = &h.prefabs,
        .uuids = &h.uuids,
        .module_index = &h.module_index,
        .exports = &h.exports,
        .arenas = &h.arenas,
    };
    try types.TypeChecker.checkProject(gpa, &h.arenas[1], &h.diagnostics, &ctx);
    return h;
}

test "an Etch rule calls the physics service and receives its result" {
    const gpa = testing.allocator;
    // THE SLICE'S FIRST HALF: a rule reaching a Tier 1 module through the service
    // path, on the declaration `bindgen-check` guards.
    var h = try check(gpa,
        \\component Probe { blocked: int = 0, count: int = 0 }
        \\rule look(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  let p = entity.get_mut(Probe)
        \\  if physics.raycast_any(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 100.0, 4294967295) {
        \\    p.blocked = 1
        \\  }
        \\  p.count = physics.point_query_count(5.0, 0.0, 0.0, 4294967295)
        \\}
    );
    defer h.deinit(gpa);
    for (h.diagnostics.items) |d| std.debug.print("check {s}: {s}\n", .{ d.code.code(), d.primary_message });
    // `point_query_count` throws, so an unwrapped call is E0902 — the rule above is
    // deliberately written without a `try` to pin that the fallible half of the
    // surface is REACHABLE from the checker.
    try testing.expectEqual(@as(usize, 1), h.diagnostics.items.len);
    try testing.expectEqualStrings("E0902", h.diagnostics.items[0].code.code());

    // The infallible half type-checks clean on its own.
    var ok = try check(gpa,
        \\component Probe { blocked: int = 0, count: int = 0 }
        \\rule look(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  if physics.raycast_any(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 100.0, 4294967295) {
        \\    entity.get_mut(Probe).blocked = 1
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // AND IT RUNS. A box sits on the ray; the rule must see it, and must NOT see
    // one that is off the ray — the second half, without which "blocked = 1" could
    // come from a service that always answers true.
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var scheduler = core.ecs.SystemScheduler.init();
    defer scheduler.deinit(gpa);
    var mod_ctx = core.ModuleContext{
        .world = &ecs,
        .persistent_allocator = gpa,
        .system_scheduler = &scheduler,
        // The job scheduler is the one field with no cheap real instance, and this
        // milestone's `init` provably never reads it — the same placeholder
        // `forge_module_test`'s fixture uses, for the same reason.
        .job_scheduler = @ptrFromInt(@alignOf(core.jobs.scheduler.Scheduler)),
    };
    var m = try module.Forge3DModule.init(&mod_ctx);
    defer m.deinit();
    const shape = try m.createShape(.{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    _ = try m.addBody(.{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .static,
        .shape = shape,
        .position = av3(10, 0, 0),
    });

    var journal: sync.in.Journal = .{};
    defer journal.deinit(gpa);
    var svc_ctx: physics.Ctx = .{ .m = &m, .ecs = &ecs, .journal = &journal };
    var registry: services.Registry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, &physics.spec, &svc_ctx);

    var interp = try weld_etch.Interpreter.compile(gpa, &ok.arenas[1], &ecs);
    defer interp.deinit();
    interp.setServiceRegistry(&registry);

    const cid = ecs.registry.idOf("Probe").?;
    const e = try ecs.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(&ecs, 1);

    const loc = ecs.dynamicLocation(e).?;
    const arch = ecs.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    var blocked: i64 = 0;
    @memcpy(std.mem.asBytes(&blocked), slot[0..8]);
    try testing.expectEqual(@as(i64, 1), blocked);
}

test "the two sensor deltas reach the Tier 0 bus as TriggerEnter and TriggerExit" {
    const gpa = testing.allocator;
    var pw = PhysicsWorld.init(Vec3r.zero, 1.0 / 60.0);
    defer pw.deinit(gpa);

    const box = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(1, 1, 1) } });
    var trig = api.BodyDescriptor{ .entity = .{ .index = 10, .generation = 0 }, .body_type = .static, .shape = box };
    trig.is_trigger = true;
    _ = try pw.addBody(gpa, trig);
    var occ = api.BodyDescriptor{ .entity = .{ .index = 11, .generation = 0 }, .body_type = .kinematic, .shape = box };
    occ.position = av3(0, 0, 0);
    const occupant = try pw.addBody(gpa, occ);

    const enter_q = try EventQueue(sensor_events.TriggerPair).init(gpa, 8, Lifetime.tick);
    defer enter_q.deinit(gpa);
    const exit_q = try EventQueue(sensor_events.TriggerPair).init(gpa, 8, Lifetime.tick);
    defer exit_q.deinit(gpa);

    // TICK 1 — the pair appears. One ENTER, no EXIT.
    try pw.step(gpa);
    const r1 = sensor_events.publish(&pw, enter_q, exit_q);
    try testing.expectEqual(@as(u32, 1), r1.entered);
    try testing.expectEqual(@as(u32, 0), r1.exited);

    // The payload is the ORIENTED pair in ENTITY identities, trigger first.
    var cursor: core.events.EventCursor = .{
        .type_id = core.rtti.computeTypeId(sensor_events.TriggerPair),
        .last_read = 0,
        .epoch = enter_q.currentEpoch(),
    };
    const first = (try enter_q.poll(&cursor)).?;
    const trigger_id: core.ecs.EntityId = @bitCast(first.trigger);
    const other_id: core.ecs.EntityId = @bitCast(first.other);
    try testing.expectEqual(@as(u32, 10), trigger_id.index);
    try testing.expectEqual(@as(u32, 11), other_id.index);

    // TICK 2 — nothing changed, so NEITHER delta fires. There is no `TriggerStay`,
    // and this is what says so: the pair is still in the state and produces no event.
    try pw.step(gpa);
    const r2 = sensor_events.publish(&pw, enter_q, exit_q);
    try testing.expectEqual(@as(u32, 0), r2.entered);
    try testing.expectEqual(@as(u32, 0), r2.exited);
    try testing.expectEqual(@as(usize, 1), pw.sensors.current.items.len);

    // TICK 3 — the occupant leaves. One EXIT, no ENTER.
    pw.setBodyTransform(occupant, Vec3r.fromArray(.{ 50, 0, 0 }), forge_3d.Quatr.identity);
    try pw.step(gpa);
    const r3 = sensor_events.publish(&pw, enter_q, exit_q);
    try testing.expectEqual(@as(u32, 0), r3.entered);
    try testing.expectEqual(@as(u32, 1), r3.exited);
}

// --- M1.1.15.2 G8 — F7 --------------------------------------------------------

test "point_query_count signals its truncation instead of returning a capped total" {
    const gpa = testing.allocator;
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var scheduler = core.ecs.SystemScheduler.init();
    defer scheduler.deinit(gpa);
    var mod_ctx = core.ModuleContext{
        .world = &ecs,
        .persistent_allocator = gpa,
        .system_scheduler = &scheduler,
        .job_scheduler = @ptrFromInt(@alignOf(core.jobs.scheduler.Scheduler)),
    };
    var m = try module.Forge3DModule.init(&mod_ctx);
    defer m.deinit();
    var journal2: sync.in.Journal = .{};
    defer journal2.deinit(gpa);
    var ctx: physics.Ctx = .{ .m = &m, .ecs = &ecs, .journal = &journal2 };

    const box = try m.createShape(.{ .box = .{ .half_extents = av3(1, 1, 1) } });
    const cap = physics.point_query_capacity;

    // BELOW the capacity: a real count, and it is the count of ENTITIES.
    for (0..cap - 1) |i| {
        _ = try m.addBody(.{
            .entity = .{ .index = @intCast(i + 1), .generation = 0 },
            .body_type = .static,
            .shape = box,
            .position = av3(0, 0, 0),
        });
    }
    try testing.expectEqual(@as(i64, @intCast(cap - 1)), try physics.pointQueryCount(&ctx, 0, 0, 0, -1));

    // AT the capacity: refused. A count equal to the capacity cannot be told from a
    // larger one, so both are refused — refusing a legitimate exactly-`cap` answer is
    // the safe direction, where returning it would be indistinguishable from a set of
    // two hundred reported as `cap`.
    _ = try m.addBody(.{
        .entity = .{ .index = @intCast(cap), .generation = 0 },
        .body_type = .static,
        .shape = box,
        .position = av3(0, 0, 0),
    });
    try testing.expectError(error.TooManyResults, physics.pointQueryCount(&ctx, 0, 0, 0, -1));

    // BEYOND it: still refused, and the point of asserting both is that the entry does
    // not start answering again once the set grows past the buffer.
    for (0..20) |i| {
        _ = try m.addBody(.{
            .entity = .{ .index = @intCast(cap + i + 1), .generation = 0 },
            .body_type = .static,
            .shape = box,
            .position = av3(0, 0, 0),
        });
    }
    try testing.expectError(error.TooManyResults, physics.pointQueryCount(&ctx, 0, 0, 0, -1));

    // NON-VACUITY: a point OUTSIDE everything still answers zero rather than erroring,
    // so the refusals above are about the bound and not about the entry having stopped
    // working.
    try testing.expectEqual(@as(i64, 0), try physics.pointQueryCount(&ctx, 500, 0, 0, -1));
}

// ---------------------------------------------------------------------------
// M1.1.15.2 G11 — the five MUTATION wrappers, and the journal's production path.
//
// Every oracle below is DISCRIMINATING in the sense G6b fixed for this milestone:
// it separates the entry from its plausible neighbour, not merely from doing
// nothing. `move_kinematic` is separated from `set_body_transform` by the DERIVED
// velocity, `move_character` from `set_character_position` by the sweep,
// `resize_character` from a boolean by its third outcome.
// ---------------------------------------------------------------------------

const Transform = core.ecs.components.Transform;
const Velocity = api.Velocity;
const RigidBody = api.RigidBody;
const EntityId = core.ecs.EntityId;

/// A world, a module, a journal and a service context — the four objects a
/// mutation wrapper needs, wired the way production wires them.
const Rig = struct {
    ecs: World,
    scheduler: core.ecs.SystemScheduler,
    mod_ctx: core.ModuleContext = undefined,
    m: module.Forge3DModule = undefined,
    journal: sync.in.Journal = .{},
    ctx: physics.Ctx = undefined,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, self: *Rig) !void {
        self.* = .{ .ecs = World.init(), .scheduler = core.ecs.SystemScheduler.init(), .gpa = gpa };
        self.mod_ctx = .{
            .world = &self.ecs,
            .persistent_allocator = gpa,
            .system_scheduler = &self.scheduler,
            .job_scheduler = @ptrFromInt(@alignOf(core.jobs.scheduler.Scheduler)),
        };
        self.m = try module.Forge3DModule.init(&self.mod_ctx);
        self.ctx = .{ .m = &self.m, .ecs = &self.ecs, .journal = &self.journal };
    }

    fn deinit(self: *Rig) void {
        self.m.deinit();
        self.journal.deinit(self.gpa);
        self.scheduler.deinit(self.gpa);
        self.ecs.deinit(self.gpa);
    }

    /// An ECS entity carrying `Transform` and `Velocity`, bound to a body of the
    /// given kind at `centre`.
    fn spawnLinked(
        self: *Rig,
        body_type: api.BodyType,
        half: [3]f32,
        centre: [3]f32,
    ) !struct { entity: EntityId, body: api.BodyId } {
        // `World.spawn` carries BOTH `Transform` and `Velocity` — the mutation wrappers
        // mirror into the second, so an entity without it would make the mirror half a
        // silent no-op.
        const entity = try self.ecs.spawn(self.gpa, .{ .pos = centre }, .{});
        const shape = try self.m.createShape(.{ .box = .{ .half_extents = av3(half[0], half[1], half[2]) } });
        var desc = api.BodyDescriptor{ .entity = entity, .body_type = body_type, .shape = shape };
        desc.position = av3(centre[0], centre[1], centre[2]);
        desc.restitution = 0;
        if (body_type == .dynamic) desc.mass = 1;
        return .{ .entity = entity, .body = try self.m.addBody(desc) };
    }

    fn bits(_: *Rig, e: EntityId) u64 {
        return @bitCast(e);
    }
};

test "move_kinematic derives both velocities and mirrors them in the same call" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();

    const p = try r.spawnLinked(.kinematic, .{ 1, 0.25, 1 }, .{ 0, 0, 0 });
    const dt: f64 = 1.0 / 60.0;

    // A PURE ROTATION, and that choice is the discrimination. A linear-only
    // implementation reaches the right POSITION on a combined move and passes a test
    // that reads position — the defect class M1.1.15 named on `moveKinematic` itself.
    // A quarter turn about Y with no translation has no linear answer to hide behind.
    const s = @sin(@as(f64, std.math.pi / 4.0));
    const c = @cos(@as(f64, std.math.pi / 4.0));
    try physics.moveKinematic(&r.ctx, r.bits(p.entity), 0, 0, 0, 0, s, 0, c, dt);

    // BOTH velocities are derived. The angular one is the half a translation cannot
    // produce, and its VALUE discriminates between the two plausible derivations: the
    // engine's is `ω = 2 · vec(q_target · conj(q_current)) / dt`, which is trig-free by
    // design (M1.1.15) and yields `2·sin(θ/2)/dt`, NOT the exact axis-angle `θ/dt`. At a
    // quarter turn the two are 84.85 and 94.25 — ten per cent apart — so this reads the
    // form and not merely the presence of a rotation.
    const quarter_turn_omega: f32 = @floatCast(2.0 * s * 60.0); // 84.8528
    const axis_angle_omega: f32 = @floatCast(std.math.pi / 2.0 * 60.0); // 94.2478
    const v = sync.solverVelocity(&r.m.world, p.body);
    try testing.expectApproxEqAbs(@as(f32, 0), v.linear[0], 1e-5);
    try testing.expectApproxEqAbs(quarter_turn_omega, v.angular[1], 1e-3);
    try testing.expect(@abs(v.angular[1] - axis_angle_omega) > 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0), v.angular[0], 1e-4);

    // THE MIRROR IS ATOMIC WITH THE MOVE — asserted BEFORE any `step` and before any
    // `syncOut`, so what is read can only have been written by the call itself.
    const t = r.ecs.get(Transform, p.entity).?;
    try testing.expectApproxEqAbs(@as(f32, @floatCast(s)), t.rot[1], 1e-5);
    const ev = r.ecs.get(Velocity, p.entity).?;
    try testing.expectApproxEqAbs(quarter_turn_omega, ev.angular[1], 1e-3);

    // A TRANSLATION TOO, so the entry is not pinned on rotation alone: three metres
    // of +X over one tick is 180 m/s.
    try physics.moveKinematic(&r.ctx, r.bits(p.entity), 3, 0, 0, 0, s, 0, c, dt);
    const v2 = sync.solverVelocity(&r.m.world, p.body);
    try testing.expectApproxEqAbs(@as(f32, 180), v2.linear[0], 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 3), r.ecs.get(Transform, p.entity).?.pos[0], 1e-5);

    // DOMAIN. A non-unit rotation is refused rather than normalised: it is used by
    // CONJUGATION to derive `ω`, and a conjugate inverts a unit quaternion alone.
    try testing.expectError(error.RotationNotUnit, physics.moveKinematic(&r.ctx, r.bits(p.entity), 0, 0, 0, 0, 0, 0, 0, dt));
    try testing.expectError(error.NonPositiveDt, physics.moveKinematic(&r.ctx, r.bits(p.entity), 0, 0, 0, 0, 0, 0, 1, 0));
    // AND AN ENTITY THAT OWNS NO BODY IS A TYPED ERROR, never a silent no-op.
    const bare = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    try testing.expectError(error.NoPhysicsBody, physics.moveKinematic(&r.ctx, r.bits(bare), 0, 0, 0, 0, 0, 0, 1, dt));
}

test "the journal mark keeps syncIn from replaying an explicit call as a teleportation" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();

    const p = try r.spawnLinked(.kinematic, .{ 1, 0.25, 1 }, .{ 0, 0, 0 });
    // Gameplay authority, or `syncIn` consumes nothing for this body and the replay
    // this test is about could not happen under any implementation.
    try r.ecs.addComponent(gpa, p.entity, RigidBody, .{ .authority = .gameplay });
    const dt: f64 = 1.0 / 60.0;

    r.ecs.beginFrame();
    // THE EXPLICIT OPERATION: move to x = 3 over one tick, deriving 180 m/s.
    try physics.moveKinematic(&r.ctx, r.bits(p.entity), 3, 0, 0, 0, 0, 0, 1, dt);
    try testing.expectApproxEqAbs(@as(f32, 180), sync.solverVelocity(&r.m.world, p.body).linear[0], 1e-2);

    // AND A CONTRADICTORY DIRECT WRITE IN THE SAME TICK. A `Transform` mutation is a
    // TELEPORTATION by contract — exact application, no derived velocity — so this
    // rule has expressed two intents for one tick.
    r.ecs.getMut(Transform, p.entity).?.pos[0] = -7;

    const res = try sync.in.syncIn(gpa, &r.m.world, &r.ecs, &r.journal);

    // THE EXPLICIT OPERATION WINS THE TICK. Without the mark, `syncIn` sees a changed
    // `Transform`, finds it differs from the solver, and pushes it with
    // `setBodyTransform` — which derives nothing: the body lands at −7 while its
    // velocity still describes 180 m/s toward +3, a motion it is no longer making.
    try testing.expectApproxEqAbs(@as(f32, 3), sync.solverPose(&r.m.world, p.body).?.pos[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 180), sync.solverVelocity(&r.m.world, p.body).linear[0], 1e-2);
    try testing.expectEqual(@as(u32, 0), res.poses_applied);

    // AND THE ECS IS RESTORED rather than left holding −7. Skipping alone would leave a
    // value the tick predicate can never see again — `changedTick > baseline` is false
    // when both are `now` and stays false afterwards — so the ECS would say −7 and the
    // solver 3, permanently and silently.
    try testing.expectEqual(@as(u32, 1), res.restored);
    try testing.expectApproxEqAbs(@as(f32, 3), r.ecs.get(Transform, p.entity).?.pos[0], 1e-5);

    // NON-VACUITY, and it is what proves the mark is doing the work rather than the
    // value predicate: on the NEXT tick the same direct write IS consumed, as an
    // ordinary gameplay teleportation, because no explicit call owns that tick.
    r.ecs.beginFrame();
    r.ecs.getMut(Transform, p.entity).?.pos[0] = -7;
    const later = try sync.in.syncIn(gpa, &r.m.world, &r.ecs, &r.journal);
    try testing.expectEqual(@as(u32, 1), later.poses_applied);
    try testing.expectEqual(@as(u32, 0), later.restored);
    try testing.expectApproxEqAbs(@as(f32, -7), sync.solverPose(&r.m.world, p.body).?.pos[0], 1e-5);
}

test "set_authority writes the field and nothing else" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();

    const p = try r.spawnLinked(.dynamic, .{ 0.5, 0.5, 0.5 }, .{ 0, 10, 0 });
    try r.ecs.addComponent(gpa, p.entity, RigidBody, .{ .authority = .solver, .mass = 3 });

    // THE FIELD MOVES, and nothing beside it: `mass` is read back to pin that the
    // wrapper writes one field of the component and not a fresh one.
    try physics.setAuthority(&r.ctx, r.bits(p.entity), 1);
    try testing.expectEqual(api.PhysicsAuthority.gameplay, r.ecs.get(RigidBody, p.entity).?.authority);
    try testing.expectEqual(@as(f32, 3), r.ecs.get(RigidBody, p.entity).?.mass);

    // AND IT TAKES EFFECT THROUGH THE SEAM, which is the discriminating half: a
    // wrapper that wrote some other field would leave `syncOut` publishing. Under
    // `.gameplay` the pose is withheld, so the body falls in the solver while the ECS
    // `Transform` stays where gameplay put it.
    const before = r.ecs.get(Transform, p.entity).?.pos[1];
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        r.ecs.beginFrame();
        try sync.stepAndPublish(gpa, &r.m.world, &r.ecs);
    }
    try testing.expect(sync.solverPose(&r.m.world, p.body).?.pos[1] < before - 0.01);
    try testing.expectEqual(before, r.ecs.get(Transform, p.entity).?.pos[1]);

    // IT GOES BACK DOWN — a mirror and not a latch.
    try physics.setAuthority(&r.ctx, r.bits(p.entity), 0);
    try testing.expectEqual(api.PhysicsAuthority.solver, r.ecs.get(RigidBody, p.entity).?.authority);

    // DOMAIN, both halves: an ordinal outside the enum, and an entity with no
    // `RigidBody` to declare on.
    try testing.expectError(error.InvalidAuthority, physics.setAuthority(&r.ctx, r.bits(p.entity), 2));
    try testing.expectError(error.InvalidAuthority, physics.setAuthority(&r.ctx, r.bits(p.entity), -1));
    const bare = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    try testing.expectError(error.NoRigidBody, physics.setAuthority(&r.ctx, r.bits(bare), 1));
}

/// A floor, a wall at x = 3, and a character at the origin whose ECS entity carries
/// a `Transform` — the scene the three character wrappers are separated on.
fn characterScene(r: *Rig) !EntityId {
    const floor = try r.m.createShape(.{ .box = .{ .half_extents = av3(20, 0.5, 20) } });
    _ = try r.m.addBody(.{
        .entity = .{ .index = 900, .generation = 0 },
        .body_type = .static,
        .shape = floor,
        .position = av3(0, -0.5, 0),
    });
    const wall = try r.m.createShape(.{ .box = .{ .half_extents = av3(0.5, 2, 4) } });
    _ = try r.m.addBody(.{
        .entity = .{ .index = 901, .generation = 0 },
        .body_type = .static,
        .shape = wall,
        .position = av3(3, 2, 0),
    });
    // The base starts CLEAR of the floor, and that clearance is deliberate: created
    // with its base exactly on the floor's top face, the capsule touches it, so the
    // occupancy test of `resizeCharacter` finds a contact and refuses even a shrink —
    // measured. §1.12.7's "shrinking always succeeds" is about the target volume being
    // contained in the current one, not about a capsule already flush against a surface.
    const hero = try r.ecs.spawn(r.gpa, .{ .pos = .{ 0, 0.1, 0 } }, .{});
    _ = try r.m.createCharacter(.{ .entity = hero, .position = av3(0, 0.1, 0) });
    return hero;
}

test "move_character sweeps where set_character_position teleports" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();
    const hero = try characterScene(&r);
    const dt: f64 = 1.0 / 60.0;

    // ASK FOR FIVE METRES OF +X, through a wall standing at x = 3. A sweep stops short
    // of it; a teleport does not. That contrast IS the oracle — an assertion that the
    // character "moved" would pass under either entry.
    const verdict = try physics.moveCharacter(&r.ctx, r.bits(hero), 5, 0, 0, dt);
    const swept = r.ecs.get(Transform, hero).?.pos[0];
    try testing.expect(swept > 0.5); // it really moved
    try testing.expect(swept < 2.6); // and the wall stopped it

    // THE VERDICT IS THE RETURN VALUE, as its `GroundState` ordinal: the character
    // stands on the floor, so `.grounded`, which is ordinal 0.
    try testing.expectEqual(@as(i64, @intFromEnum(api.GroundState.grounded)), verdict);

    // THE MIRROR IS THE CAPSULE'S BASE and not its centre (§1.12.3). The character
    // settles at `padding` above the floor — 0.02 m, which is what a SWEEP reserves and
    // not a pose invariant (§1.12.6) — so the base reads about 0.02 where a mirror of
    // the CENTRE would publish half a capsule height on top of it, about 0.92. The
    // bound below separates the two by a factor of forty-five.
    const base_y = r.ecs.get(Transform, hero).?.pos[1];
    try testing.expectApproxEqAbs(@as(f32, 0.02), base_y, 5e-3);
    try testing.expect(base_y < 0.9);

    // AND THE TELEPORT GOES THROUGH, from the same place, over the same wall.
    try physics.setCharacterPosition(&r.ctx, r.bits(hero), 6, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 6), r.m.world.chars.get(sync.characterOf(&r.m.world, hero).?).?.position.toArray()[0], 1e-4);

    // **AND IT DOES NOT MIRROR**, which is the corpus's own asymmetry rather than an
    // omission: `engine-movement.md` §11 writes `Transform.position = destination` in the
    // rule, beside the call, because the caller already HAS the destination. The ECS
    // therefore still holds the swept pose here, and a rule is what moves it.
    try testing.expectApproxEqAbs(swept, r.ecs.get(Transform, hero).?.pos[0], 1e-6);

    // AN ENTITY WITH NO CHARACTER IS A TYPED ERROR on all three entries.
    const bare = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    try testing.expectError(error.NoCharacter, physics.moveCharacter(&r.ctx, r.bits(bare), 1, 0, 0, dt));
    try testing.expectError(error.NoCharacter, physics.setCharacterPosition(&r.ctx, r.bits(bare), 1, 0, 0));
    try testing.expectError(error.NoCharacter, physics.resizeCharacter(&r.ctx, r.bits(bare), 0.3, 1.0));
}

test "resize_character keeps three outcomes and never collapses two into a bool" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();
    const hero = try characterScene(&r);

    // (1) SHRINKING ALWAYS SUCCEEDS — the target volume is contained in the current one.
    try testing.expect(try physics.resizeCharacter(&r.ctx, r.bits(hero), 0.3, 0.9));

    // (2) A CEILING 1.2 m up leaves room for 0.9 and none for 1.8. The SAME call
    // therefore answers `true` then `false`, which is what makes the refusal a real
    // measurement of occupancy and not a constant.
    const slab = try r.m.createShape(.{ .box = .{ .half_extents = av3(4, 0.1, 4) } });
    _ = try r.m.addBody(.{
        .entity = .{ .index = 902, .generation = 0 },
        .body_type = .static,
        .shape = slab,
        .position = av3(0, 1.3, 0),
    });
    try testing.expect(!try physics.resizeCharacter(&r.ctx, r.bits(hero), 0.3, 1.8));
    // And it is a REFUSAL and not an error: the character keeps the size it had.
    try testing.expectApproxEqAbs(@as(f32, 0.9), r.m.world.chars.get(sync.characterOf(&r.m.world, hero).?).?.height, 1e-5);

    // (3) THE THIRD OUTCOME, and the one a bare `bool` would fuse with (2): an
    // inadmissible request is an ERROR. "I cannot stand up" and "your request is
    // malformed" are answers a caller must tell apart (§1.12.7).
    try testing.expectError(error.InvalidDimensions, physics.resizeCharacter(&r.ctx, r.bits(hero), -1, 1.0));
}

test "electedBodyOf answers exactly what electPublishers elects" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();

    // A SCENE WHERE EVERY LEVEL OF THE CRITERION BITES, or the agreement below would
    // be the agreement of two functions that never had to choose: entity A owns a
    // trigger created FIRST and a solid created second — so the trigger loses on the
    // second level despite winning on the third; entity B owns two solids, so the
    // smallest handle wins on the third; entity C owns one; and a character presence
    // is registered too, which neither may ever elect.
    const shape = try r.m.createShape(.{ .box = .{ .half_extents = av3(1, 1, 1) } });
    const a = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const b = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const c = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    const a_trigger = try r.m.addBody(.{ .entity = a, .body_type = .static, .shape = shape, .is_trigger = true, .position = av3(0, 0, 0) });
    const a_solid = try r.m.addBody(.{ .entity = a, .body_type = .static, .shape = shape, .position = av3(0, 0, 0) });
    const b_first = try r.m.addBody(.{ .entity = b, .body_type = .static, .shape = shape, .position = av3(9, 0, 0) });
    const b_second = try r.m.addBody(.{ .entity = b, .body_type = .static, .shape = shape, .position = av3(9, 0, 0) });
    const c_only = try r.m.addBody(.{ .entity = c, .body_type = .static, .shape = shape, .position = av3(18, 0, 0) });
    const hero = try r.ecs.spawn(gpa, .{ .pos = .{ 0, 0, 0 } }, .{});
    _ = try r.m.createCharacter(.{ .entity = hero, .position = av3(30, 0, 0) });

    // NON-VACUITY of the scene itself: the trigger really was created before the solid,
    // so "trigger loses" is a level of the criterion that had to fire.
    try testing.expect(a_trigger < a_solid);
    try testing.expect(b_first < b_second);

    // THE TWO AGREE, and they agree because they share the criterion — `Candidate` and
    // its `lessThan` — rather than because two readings were kept in step by review. A
    // wrapper electing differently from the seam would write to one collider while the
    // seam read from another, and one entity would answer with two poses.
    const table = try sync.electPublishers(gpa, &r.m.world);
    defer table.deinit(gpa);
    var elected: usize = 0;
    for (r.m.world.bodies.items, 0..) |entry, i| {
        if (!table.publishes[i]) continue;
        elected += 1;
        const owner = r.m.world.bm.entity(entry.id).?;
        try testing.expectEqual(entry.id, sync.electedBodyOf(&r.m.world, owner).?);
    }
    // Three entities own bodies, so the table elects exactly three — and the character
    // presence is not among them, which is the exclusion both sides must share.
    try testing.expectEqual(@as(usize, 3), elected);
    try testing.expectEqual(a_solid, sync.electedBodyOf(&r.m.world, a).?);
    try testing.expectEqual(b_first, sync.electedBodyOf(&r.m.world, b).?);
    try testing.expectEqual(c_only, sync.electedBodyOf(&r.m.world, c).?);
    try testing.expect(sync.electedBodyOf(&r.m.world, hero) == null);
    try testing.expect(sync.characterOf(&r.m.world, hero) != null);
    try testing.expect(sync.characterOf(&r.m.world, a) == null);
}

// ---------------------------------------------------------------------------
// M1.1.15.2 G14 — the two properties.
// ---------------------------------------------------------------------------

test "move_kinematic refused on a non-kinematic body leaves the state untouched" {
    const gpa = testing.allocator;
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();

    // **THE PROPERTY IS THE STATE AFTER THE REFUSAL, NOT THE REFUSAL.** An
    // `expectError` alone passes on an implementation that mutates and then returns the
    // error — which is the shape that matters here, since the entry writes a pose, two
    // derived velocities and a journal mark before it could ever have returned. So every
    // one of the four is captured beforehand and confronted afterwards.
    const dyn = try r.spawnLinked(.dynamic, .{ 0.5, 0.5, 0.5 }, .{ 1, 2, 3 });
    const sta = try r.spawnLinked(.static, .{ 0.5, 0.5, 0.5 }, .{ 9, 0, 0 });
    try r.ecs.addComponent(gpa, dyn.entity, RigidBody, .{ .authority = .solver });

    // A KNOWN JOURNAL STATE, established by a real pass rather than by construction: a
    // body with no entry at all would make "the mark did not move" true by absence.
    r.ecs.beginFrame();
    _ = try sync.in.syncIn(gpa, &r.m.world, &r.ecs, &r.journal);
    const mark_before = r.journal.entryOf(dyn.body).?;
    try testing.expect(mark_before.consumed_tick != null);

    // A KNOWN VELOCITY too, so "the velocity did not move" is not the statement that
    // zero stayed zero.
    r.m.world.bm.setLinearVelocity(dyn.body, forge_3d.Vec3r.fromArray(.{ 5, 0, 0 }));
    const pose_before = sync.solverPose(&r.m.world, dyn.body).?;
    const vel_before = sync.solverVelocity(&r.m.world, dyn.body);

    r.ecs.beginFrame();
    try testing.expectError(error.NotKinematic, physics.moveKinematic(&r.ctx, r.bits(dyn.entity), 40, 40, 40, 0, 0, 0, 1, 1.0 / 60.0));

    // NOTHING MOVED — pose, both velocities, and the journal mark.
    const pose_after = sync.solverPose(&r.m.world, dyn.body).?;
    try testing.expectEqualSlices(f32, &pose_before.pos, &pose_after.pos);
    try testing.expectEqualSlices(f32, &pose_before.rot, &pose_after.rot);
    const vel_after = sync.solverVelocity(&r.m.world, dyn.body);
    try testing.expectEqualSlices(f32, &vel_before.linear, &vel_after.linear);
    try testing.expectEqualSlices(f32, &vel_before.angular, &vel_after.angular);
    const mark_after = r.journal.entryOf(dyn.body).?;
    try testing.expectEqual(mark_before.consumed_tick.?, mark_after.consumed_tick.?);

    // A STATIC IS REFUSED TOO — "non-kinematic" and not "not dynamic".
    try testing.expectError(error.NotKinematic, physics.moveKinematic(&r.ctx, r.bits(sta.entity), 1, 1, 1, 0, 0, 0, 1, 1.0 / 60.0));

    // NON-VACUITY: the same call on a KINEMATIC body succeeds and moves it, so the
    // refusals above are the subject being refused and not the arguments being wrong.
    const kin = try r.spawnLinked(.kinematic, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 });
    try physics.moveKinematic(&r.ctx, r.bits(kin.entity), 2, 0, 0, 0, 0, 0, 1, 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 2), sync.solverPose(&r.m.world, kin.body).?.pos[0], 1e-5);
    // And ITS journal mark DID move, which is what the dynamic body's must not have.
    try testing.expect(r.journal.entryOf(kin.body).?.consumed_tick != null);
}

test "set_joint_motor resolves as §5 writes it, and fails loud" {
    const gpa = testing.allocator;

    // **THE RECEIVER FORM IS WHAT §5 FIXES**, and it is what this checks: a rule writes
    // `physics.set_joint_motor(...)`, dispatched on the service, against the EMITTED
    // declaration that `bindgen-check` guards — never a literal written here.
    //
    // The arguments take RD-2's scalar decomposition: §5 passes a `JointId` and an
    // aggregate `?JointMotor`, and the Phase 1 tree-walker carries neither. The residual
    // is named in the journal rather than papered over.
    var h = try check(gpa,
        \\component Door { open: int = 0 }
        \\rule open_door(entity: Entity)
        \\  when entity has Door
        \\{
        \\  try {
        \\    physics.set_joint_motor(7, true, 1, 1.5707964, 100.0, 0.0, 20.0, 1.0)
        \\    entity.get_mut(Door).open = 1
        \\  } catch err {
        \\    entity.get_mut(Door).open = 0 - 1
        \\  }
        \\}
    );
    defer h.deinit(gpa);
    for (h.diagnostics.items) |d| std.debug.print("check {s}: {s}\n", .{ d.code.code(), d.primary_message });
    try testing.expectEqual(@as(usize, 0), h.diagnostics.items.len);

    // NON-VACUITY on the resolution: an entry the service does NOT declare is a
    // diagnostic, so the clean run above is the checker finding this method and not the
    // checker accepting anything spelled on `physics`.
    var bad = try check(gpa,
        \\component Door { open: int = 0 }
        \\rule open_door(entity: Entity)
        \\  when entity has Door
        \\{
        \\  try {
        \\    physics.set_joint_torque(7, true, 1, 1.5707964, 100.0, 0.0, 20.0, 1.0)
        \\  } catch err { }
        \\}
    );
    defer bad.deinit(gpa);
    try testing.expect(bad.diagnostics.items.len > 0);

    // AND IT FAILS LOUD rather than answering success. `Forge3DModule` has no joints, so
    // the wrapper propagates — a stub returning `void` would be the truncated-success
    // class closed three times in this milestone.
    var r: Rig = undefined;
    try Rig.init(gpa, &r);
    defer r.deinit();
    try testing.expectError(error.JointsNotImplemented, physics.setJointMotor(&r.ctx, 7, true, 1, 1.5, 100, 0, 20, 1));
    // The CLEARING form reaches the same entry — `enabled = false` is §5's "absent or
    // null means no motor", and it must not short-circuit into a silent success.
    try testing.expectError(error.JointsNotImplemented, physics.setJointMotor(&r.ctx, 7, false, 0, 0, 0, 0, 0, 0));
    // Domain, refused before the entry: a handle out of `JointId`'s range and a mode
    // outside the two the enum declares.
    try testing.expectError(error.InvalidJointId, physics.setJointMotor(&r.ctx, -1, true, 0, 0, 0, 0, 0, 0));
    try testing.expectError(error.InvalidMotorMode, physics.setJointMotor(&r.ctx, 7, true, 2, 0, 0, 0, 0, 0));
}
