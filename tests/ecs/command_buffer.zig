//! Command buffer acceptance tests: a structural mutation recorded in a system
//! body becomes visible only at the phase flush, and several of them apply in
//! system submission order.

const std = @import("std");
const weld_core = @import("weld_core");
const watchdog = @import("test_watchdog");

const World = weld_core.ecs.world.World;
const SystemContextOf = weld_core.ecs.SystemContextOf;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.world.EntityId;

const jobs_sched_mod = weld_core.jobs.scheduler;
const Scheduler = jobs_sched_mod.Scheduler;

const sys_sched_mod = weld_core.ecs.scheduler;
const SystemScheduler = sys_sched_mod.SystemScheduler;
const SystemContext = sys_sched_mod.SystemContext;
const SystemDescriptor = sys_sched_mod.SystemDescriptor;
const Access = weld_core.ecs.Access;

const command_buffer_mod = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer_mod.CommandBuffer;

// One declared access set per registered system, named after it.
// `registerSystem` derives BOTH the DAG's descriptors and the body's context
// type from the set named here, so a body cannot be paired with a declaration
// that does not describe it.
const spec_adds_tag1: []const Access = &.{};
const spec_removes_tag2: []const Access = &.{};

const DeferredSpawnState = struct {
    /// Snapshot of `world.entityCount()` taken inside the system
    /// body — the system records the spawn but should observe the
    /// pre-spawn count because the flush has not run yet.
    seen_count_in_body: usize = 0,
};

/// Empty, and the body is why: it records a spawn and counts entities. The
/// spawn is structural, so it goes through the command buffer; a cardinality is
/// neither a component nor a resource, so no declaration covers it. A system
/// that touches no entity data still receives a view — one that can do nothing
/// but count.
const deferred_spawn_spec = [_]Access{};

fn deferredSpawnSystem(ctx: sys_sched_mod.SystemContextOf(&deferred_spawn_spec)) anyerror!void {
    const state: *DeferredSpawnState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.spawn(.{
        Transform{},
        Velocity{},
    });
    state.seen_count_in_body = ctx.view.entityCount();
}

test "deferred spawn is visible only after the phase flush" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "deferred spawn is visible only after the phase flush");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    try sys.registerSystem(gpa, &world, .update, "deferred_spawn", &deferred_spawn_spec, deferredSpawnSystem);

    var state = DeferredSpawnState{};
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    try std.testing.expectEqual(@as(usize, 0), state.seen_count_in_body);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
}

// A and B sit on the SAME phase and touch the same entity, so intra-phase
// reordering is free to run them in either order. What must not vary is the
// FLUSH: the scheduler walks `phase.systems` in submission order.

const Tag1 = extern struct { v: u32 = 1 };
const Tag2 = extern struct { v: u32 = 2 };

const OrderTestState = struct {
    entity: EntityId,
};

fn systemAddsTag1(ctx: SystemContextOf(spec_adds_tag1)) anyerror!void {
    const state: *OrderTestState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.addComponent(state.entity, Tag1, .{ .v = 10 });
}

fn systemRemovesTag2(ctx: SystemContextOf(spec_removes_tag2)) anyerror!void {
    const state: *OrderTestState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.removeComponent(state.entity, Tag2);
}

test "add_component and remove_component are applied in system submission order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "add_component and remove_component are applied in system submission order");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    const entity = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, entity, Tag2, .{ .v = 99 });

    // Register A first, then B — submission order is (A, B).
    // Structural only: every mutation goes through the command buffer, which
    // the access model deliberately has no category for. An empty set is
    // therefore the true declaration, and it is written rather than defaulted.
    try sys.registerSystem(gpa, &world, .update, "adds_tag1", spec_adds_tag1, systemAddsTag1);
    // Empty declaration, as above: structural only.
    try sys.registerSystem(gpa, &world, .update, "removes_tag2", spec_removes_tag2, systemRemovesTag2);

    var state = OrderTestState{ .entity = entity };

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    //   (T, V, Tag2) → (T, V, Tag1, Tag2) [A] → (T, V, Tag1) [B]
    const tag1_value = world.get(Tag1, entity);
    try std.testing.expect(tag1_value != null);
    try std.testing.expectEqual(@as(u32, 10), tag1_value.?.v);

    const tag2_value = world.get(Tag2, entity);
    try std.testing.expect(tag2_value == null);
}
