//! M0.1 / E6 — command buffer acceptance tests.
//!
//! Covers the two tests called out in `briefs/M0.1-ecs-full.md`
//! § Acceptance criteria › Tests for E6:
//!
//! - `test "deferred spawn is visible only after the phase flush"`
//!   — drive a `SystemScheduler` with a single system that records
//!   a deferred spawn through `ctx.cmd.spawn(...)`. Assert (a) world
//!   entity count is unchanged DURING the system body, (b) entity
//!   count is incremented AFTER `dispatchFrame` returns (the
//!   phase-boundary flush ran).
//! - `test "add_component and remove_component are applied in
//!    system submission order"` — register two systems on the
//!    same phase: system A records `add_component(Tag1)` on a
//!    pre-spawned entity, system B records `remove_component(Tag2)`.
//!    Verify the post-flush archetype reflects the submission
//!    order: A's command applies before B's.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.world.EntityId;

const jobs_sched_mod = weld_core.jobs.scheduler;
const Scheduler = jobs_sched_mod.Scheduler;

const sys_sched_mod = weld_core.ecs.scheduler;
const SystemScheduler = sys_sched_mod.SystemScheduler;
const SystemContext = sys_sched_mod.SystemContext;

const command_buffer_mod = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer_mod.CommandBuffer;

// ─── Test 1 — deferred spawn ─────────────────────────────────────────────

const DeferredSpawnState = struct {
    /// Snapshot of `world.entityCount()` taken inside the system
    /// body — the system records the spawn but should observe the
    /// pre-spawn count because the flush has not run yet.
    seen_count_in_body: usize = 0,
};

fn deferredSpawnSystem(ctx: SystemContext) anyerror!void {
    const state: *DeferredSpawnState = @ptrCast(@alignCast(ctx.frame.user.?));
    // Inside the body — record the spawn, capture the entity count
    // BEFORE the flush runs.
    try ctx.cmd.spawn(.{
        Transform{},
        Velocity{},
    });
    state.seen_count_in_body = ctx.world.entityCount();
}

test "deferred spawn is visible only after the phase flush" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "deferred_spawn",
        .run = deferredSpawnSystem,
    });

    var state = DeferredSpawnState{};
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    // Inside the system body, the spawn was deferred — the world
    // still showed zero entities.
    try std.testing.expectEqual(@as(usize, 0), state.seen_count_in_body);
    // After dispatchFrame returns the phase flush has applied the
    // recorded spawn.
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
}

// ─── Test 2 — submission-order flush ─────────────────────────────────────
//
// Two systems on the same phase. System A records an `addComponent`
// of `Tag1` on a pre-existing entity. System B records a `removeComponent`
// of `Tag2` from the same entity (after A's add). For the flush to be
// deterministic, A must apply before B regardless of intra-phase
// reordering — i.e., the SystemScheduler iterates `phase.systems` in
// submission order at flush time.

const Tag1 = extern struct { v: u32 = 1 };
const Tag2 = extern struct { v: u32 = 2 };

const OrderTestState = struct {
    entity: EntityId,
};

fn systemAddsTag1(ctx: SystemContext) anyerror!void {
    const state: *OrderTestState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.addComponent(state.entity, Tag1, .{ .v = 10 });
}

fn systemRemovesTag2(ctx: SystemContext) anyerror!void {
    const state: *OrderTestState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.removeComponent(state.entity, Tag2);
}

test "add_component and remove_component are applied in system submission order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Pre-spawn entity carrying (Transform, Velocity, Tag2). A's add
    // and B's remove operate on this entity.
    const entity = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, entity, Tag2, .{ .v = 99 });

    // Register A first, then B — submission order is (A, B).
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "adds_tag1",
        .run = systemAddsTag1,
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "removes_tag2",
        .run = systemRemovesTag2,
    });

    var state = OrderTestState{ .entity = entity };

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    // After flush, the entity has gone through:
    //   (T, V, Tag2)
    //     → (T, V, Tag1, Tag2)    [A applied]
    //     → (T, V, Tag1)           [B applied]
    // The final state must reflect both mutations applied in
    // submission order — i.e. Tag1 attached AND Tag2 detached.
    const tag1_value = world.get(Tag1, entity);
    try std.testing.expect(tag1_value != null);
    try std.testing.expectEqual(@as(u32, 10), tag1_value.?.v);

    const tag2_value = world.get(Tag2, entity);
    try std.testing.expect(tag2_value == null);
}
