//! Observer registry contract: an observer fires at the flush, an
//! `on_despawned` observer can still read the entity one last time, and a
//! structural mutation an observer issues waits for the NEXT flush.

const std = @import("std");
const weld_core = @import("weld_core");
const watchdog = @import("test_watchdog");

const World = weld_core.ecs.world.World;
const Access = weld_core.ecs.Access;
const SystemContextOf = weld_core.ecs.SystemContextOf;
const Transform = weld_core.ecs.world.Transform;
const Velocity = weld_core.ecs.world.Velocity;
const EntityId = weld_core.ecs.world.EntityId;

const jobs_sched_mod = weld_core.jobs.scheduler;
const Scheduler = jobs_sched_mod.Scheduler;

const sys_sched_mod = weld_core.ecs.scheduler;
const SystemScheduler = sys_sched_mod.SystemScheduler;
const SystemContext = sys_sched_mod.SystemContext;

const observers_mod = weld_core.ecs.observers;
const command_buffer_mod = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer_mod.CommandBuffer;

const registry_mod = weld_core.ecs.registry;
const ComponentId = registry_mod.ComponentId;

const Tag = extern struct { v: u32 = 0 };
const Marker = extern struct { id: u32 = 0 };

// One declared access set per registered system, named after it.
// `registerSystem` derives BOTH the DAG's descriptors and the body's context
// type from the set named here, so a body cannot be paired with a declaration
// that does not describe it.
const spec_add_tag: []const Access = &.{};
const spec_despawn: []const Access = &.{};
const spec_spawn_one: []const Access = &.{};
const spec_noop: []const Access = &.{};

const AddObserverState = struct {
    fire_count: u32 = 0,
    last_entity: EntityId = .{ .index = 0, .generation = 0 },
    last_cid: ComponentId = 0,
    expected_cid: ComponentId,
    target_entity: EntityId,
};

var ADD_STATE: ?*AddObserverState = null;

fn onAddTagObserver(
    _: ?*anyopaque,
    world: *World,
    entity: EntityId,
    component_id: ?ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    deferred: *CommandBuffer,
) anyerror!void {
    _ = world;
    _ = deferred;
    const s = ADD_STATE.?;
    s.fire_count += 1;
    s.last_entity = entity;
    s.last_cid = component_id.?;
}

fn addTagSystem(ctx: SystemContextOf(spec_add_tag)) anyerror!void {
    const s: *AddObserverState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.addComponent(s.target_entity, Tag, .{ .v = 7 });
}

test "on_add observer is called during flush after add_component" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "on_add observer is called during flush after add_component");
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
    const expected_cid = try world.ensureComponentRegistered(gpa, Tag);

    var state = AddObserverState{
        .expected_cid = expected_cid,
        .target_entity = entity,
    };
    ADD_STATE = &state;
    defer ADD_STATE = null;

    try world.registerOnAdd(gpa, Tag, null, &onAddTagObserver);
    // Structural only: every mutation goes through the command buffer, which
    // the access model deliberately has no category for. An empty set is
    // therefore the true declaration, and it is written rather than defaulted.
    try sys.registerSystem(gpa, &world, .update, "add_tag", spec_add_tag, addTagSystem);

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    try std.testing.expectEqual(@as(u32, 1), state.fire_count);
    try std.testing.expectEqual(entity.index, state.last_entity.index);
    try std.testing.expectEqual(expected_cid, state.last_cid);
}

const DespawnObserverState = struct {
    entity_was_live: bool = false,
    tag_value_seen: u32 = 0,
    target_entity: EntityId,
};

var DESPAWN_STATE: ?*DespawnObserverState = null;

fn onDespawnedObserver(
    _: ?*anyopaque,
    world: *World,
    entity: EntityId,
    component_id: ?ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    deferred: *CommandBuffer,
) anyerror!void {
    _ = deferred;
    _ = component_id; // on_despawned passes null
    const s = DESPAWN_STATE.?;
    // The despawn application has NOT happened yet — the entity
    // must still be live in the identity store and its components
    // must still be readable via `world.get`.
    s.entity_was_live = world.isLive(entity);
    if (world.get(Tag, entity)) |tag| {
        s.tag_value_seen = tag.v;
    }
}

fn despawnSystem(ctx: SystemContextOf(spec_despawn)) anyerror!void {
    const s: *DespawnObserverState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.despawn(s.target_entity);
}

test "on_despawned observer fires before chunk slot is reused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "on_despawned observer fires before chunk slot is reused");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Spawn with a Tag carrying a sentinel value so the callback can
    // confirm component data is still readable.
    const entity = try world.spawn(gpa, Transform{}, Velocity{});
    try world.addComponent(gpa, entity, Tag, .{ .v = 1234 });

    var state = DespawnObserverState{ .target_entity = entity };
    DESPAWN_STATE = &state;
    defer DESPAWN_STATE = null;

    try world.registerOnDespawned(gpa, null, &onDespawnedObserver);
    // Empty declaration, as above: structural only.
    try sys.registerSystem(gpa, &world, .update, "despawn", spec_despawn, despawnSystem);

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    try std.testing.expect(state.entity_was_live);
    try std.testing.expectEqual(@as(u32, 1234), state.tag_value_seen);

    try std.testing.expect(!world.isLive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

const ChainState = struct {
    on_spawned_count: u32 = 0,
};

var CHAIN_STATE: ?*ChainState = null;

fn onSpawnedChain(
    _: ?*anyopaque,
    world: *World,
    entity: EntityId,
    component_id: ?ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    deferred: *CommandBuffer,
) anyerror!void {
    _ = world;
    _ = entity;
    _ = component_id;
    const s = CHAIN_STATE.?;
    s.on_spawned_count += 1;
    // On the first spawn (count just became 1), queue another spawn
    // into the deferred buffer. The contract says the deferred
    // entity must NOT appear during this flush — it should land on
    // the NEXT call to `dispatchFrame`.
    if (s.on_spawned_count == 1) {
        try deferred.spawn(.{
            Transform{},
            Velocity{},
            Marker{ .id = 999 },
        });
    }
}

fn spawnOneSystem(ctx: SystemContextOf(spec_spawn_one)) anyerror!void {
    _ = ctx.frame; // state shared via globals
    try ctx.cmd.spawn(.{ Transform{}, Velocity{} });
}

fn noopSystem(_: SystemContextOf(spec_noop)) anyerror!void {}

test "observer-issued structural mutations are queued for the next flush" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "observer-issued structural mutations are queued for the next flush");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    var chain_state = ChainState{};
    CHAIN_STATE = &chain_state;
    defer CHAIN_STATE = null;

    try world.registerOnSpawned(gpa, null, &onSpawnedChain);
    // Empty declaration, as above: structural only.
    try sys.registerSystem(gpa, &world, .update, "spawn_one", spec_spawn_one, spawnOneSystem);

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    // First frame: the system spawns through the cmd buffer, the flush applies
    // it, `on_spawned` fires, and the observer queues a second spawn into the
    // deferred buffer — which must NOT apply this round.
    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &chain_state);

    try std.testing.expectEqual(@as(u32, 1), chain_state.on_spawned_count);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());

    // Second frame, with the spawning system replaced by a no-op so what is
    // observed is the deferred drain ALONE: the queued spawn applies now, and
    // `on_spawned` does NOT fire for it — a deferred command goes through
    // `rawApplyCommand`, which skips observer dispatch (no recursion).
    var sys2 = SystemScheduler.init();
    defer sys2.deinit(gpa);
    // Empty declaration, as above: structural only.
    try sys2.registerSystem(gpa, &world, .update, "noop", spec_noop, noopSystem);
    try sys2.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &chain_state);

    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    try std.testing.expectEqual(@as(u32, 1), chain_state.on_spawned_count);
}
