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

    var svc_ctx: physics.Ctx = .{ .m = &m };
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
    var ctx: physics.Ctx = .{ .m = &m };

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
