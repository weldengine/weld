//! M0.1 / E6 — observer registry acceptance tests.
//!
//! Three tests cover the contract listed in
//! `briefs/M0.1-ecs-full.md` § Acceptance criteria › Tests for E6:
//!
//! - `test "on_add observer is called during flush after add_component"`
//!   — record an `addComponent(Tag)` through the cmd buffer, register
//!   an `on_add` observer for `Tag`, drive `dispatchFrame`, assert
//!   the observer fired exactly once with the correct entity + cid.
//! - `test "on_despawned observer fires before chunk slot is reused"`
//!   — the observer must be able to read the entity's components
//!   one last time. Asserts `world.isLive(entity)` returns true and
//!   `world.get(Tag, entity)` returns the right value INSIDE the
//!   callback.
//! - `test "observer-issued structural mutations are queued for the
//!    next flush"` — observer reacts to a spawn by spawning another
//!    entity. The second entity must NOT appear during the CURRENT
//!    flush (no re-entrancy); it must appear after the NEXT
//!    `dispatchFrame` (one flush-point latency).

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

const observers_mod = weld_core.ecs.observers;
const command_buffer_mod = weld_core.ecs.command_buffer;
const CommandBuffer = command_buffer_mod.CommandBuffer;

const registry_mod = weld_core.ecs.registry;
const ComponentId = registry_mod.ComponentId;

// ─── Components used by the tests ─────────────────────────────────────────

const Tag = extern struct { v: u32 = 0 };
const Marker = extern struct { id: u32 = 0 };

// ─── Test 1 — on_add fires after add_component ────────────────────────────

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

fn addTagSystem(ctx: SystemContext) anyerror!void {
    const s: *AddObserverState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.addComponent(s.target_entity, Tag, .{ .v = 7 });
}

test "on_add observer is called during flush after add_component" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

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
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "add_tag",
        .run = addTagSystem,
    });

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    try std.testing.expectEqual(@as(u32, 1), state.fire_count);
    try std.testing.expectEqual(entity.index, state.last_entity.index);
    try std.testing.expectEqual(expected_cid, state.last_cid);
}

// ─── Test 2 — on_despawned fires before slot reuse ────────────────────────

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

fn despawnSystem(ctx: SystemContext) anyerror!void {
    const s: *DespawnObserverState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.cmd.despawn(s.target_entity);
}

test "on_despawned observer fires before chunk slot is reused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

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
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "despawn",
        .run = despawnSystem,
    });

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);

    // Inside the callback the entity was still live and its Tag was
    // still readable with the sentinel value.
    try std.testing.expect(state.entity_was_live);
    try std.testing.expectEqual(@as(u32, 1234), state.tag_value_seen);

    // After the flush, the despawn has been applied.
    try std.testing.expect(!world.isLive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

// ─── Test 3 — observer-issued mutations queue for next flush ──────────────

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

fn spawnOneSystem(ctx: SystemContext) anyerror!void {
    _ = ctx.frame; // state shared via globals
    try ctx.cmd.spawn(.{ Transform{}, Velocity{} });
}

fn noopSystem(_: SystemContext) anyerror!void {}

test "observer-issued structural mutations are queued for the next flush" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    var chain_state = ChainState{};
    CHAIN_STATE = &chain_state;
    defer CHAIN_STATE = null;

    try world.registerOnSpawned(gpa, null, &onSpawnedChain);
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "spawn_one",
        .run = spawnOneSystem,
    });

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    // ── First dispatchFrame ──────────────────────────────────────
    // System spawns 1 entity via cmd buffer. On flush, the spawn
    // applies → on_spawned fires → observer queues a second spawn
    // into deferred. The deferred spawn must NOT apply this round.
    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &chain_state);

    try std.testing.expectEqual(@as(u32, 1), chain_state.on_spawned_count);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());

    // ── Second dispatchFrame ─────────────────────────────────────
    // Replace the spawning system with a no-op so we observe ONLY
    // the deferred buffer drain. The previous flush's deferred
    // spawn must apply now and on_spawned must fire a second time
    // (no — actually, the observer-issued spawn does NOT re-fire
    // observers per the no-recursion contract; the rawApplyCommand
    // path skips the dispatch). Verify the second entity exists
    // and on_spawned was NOT called for it.
    var sys2 = SystemScheduler.init();
    defer sys2.deinit(gpa);
    try sys2.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "noop",
        .run = noopSystem,
    });
    try sys2.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &chain_state);

    // The deferred spawn from the previous flush has applied —
    // entity count went from 1 to 2.
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    // The chain observer did NOT re-fire because deferred cmds
    // bypass observer dispatch (no-recursion contract).
    try std.testing.expectEqual(@as(u32, 1), chain_state.on_spawned_count);
}
