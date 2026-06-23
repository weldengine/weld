# `weld_core.ecs` — Tier 0 Entity-Component-System

Public API entry point: `src/core/ecs/root.zig`.
Internal design reference: `engine-ecs-internals.md` (claude.ai knowledge base).

## Surface

A consumer does:

```zig
const ecs = @import("weld_core").ecs;
var world = ecs.World.init();
defer world.deinit(gpa);

// Spawn (typed)
const eid = try world.spawn(gpa, ecs.Transform{}, ecs.Velocity{ .linear = .{ 0, 1, 0 } });
```

Every type in the M0.1 public contract is reachable as a flat
re-export from `ecs.*`:

| Group | Types |
|---|---|
| Identity | `World`, `EntityId`, `ComponentId`, `ArchetypeId`, `Tick`, `WorldError` |
| Storage | `Archetype`, `Chunk`, `Location`, `Transform`, `Velocity` |
| Queries | `Query`, `With`, `Without`, `Predicate`, `Changed` |
| Scheduler | `SystemScheduler`, `SystemDescriptor`, `SystemContext`, `SystemFn`, `FrameContext`, `Phase`, `JobBuilder`, `RegistrationError` |
| Access | `Reads`, `Writes`, `ReadsResource`, `WritesResource`, `AccessDescriptor`, `AccessKind` |
| Mutations | `CommandBuffer`, `Command` |
| Observers | `ObserverFn` (registered via `World.registerOn*` methods) |

Sub-module aliases (`ecs.world`, `ecs.scheduler`, `ecs.query`,
`ecs.command_buffer`, …) remain reachable for tests and the bench.
New consumer code should prefer the flat surface.

## Minimal usage example

```zig
const std = @import("std");
const ecs = @import("weld_core").ecs;
const jobs = @import("weld_core").jobs;

// 1. Components — extern struct POD with default values.
const Mass = extern struct { value: f32 = 1.0 };

// 2. Body — type-erased trampoline target. Reads byte offsets
//    resolved once at query construction.
fn applyGravityChunk(chunk: *ecs.Chunk, query: *ecs.Query(&.{ecs.Velocity, Mass}, .{}), dt: f32) void {
    const v_off = query.componentOffsetFor(chunk, 0);
    const m_off = query.componentOffsetFor(chunk, 1);
    const count = chunk.entityCount();
    const velocities: [*]ecs.Velocity = @ptrCast(@alignCast(&chunk.bytes[v_off]));
    const masses: [*]Mass = @ptrCast(@alignCast(&chunk.bytes[m_off]));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        velocities[i].linear[1] -= 9.81 * masses[i].value * dt;
    }
}

const SystemState = struct {
    query: *ecs.Query(&.{ecs.Velocity, Mass}, .{}),
};

// 3. System — single-threaded body that stages chunked work into
//    ctx.builder. The SystemScheduler dispatches the batch.
fn applyGravity(ctx: ecs.SystemContext) anyerror!void {
    const state: *SystemState = @ptrCast(@alignCast(ctx.frame.user.?));
    try ctx.builder.addJob(state.query, applyGravityChunk, .{ state.query, ctx.frame.dt });
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var world = ecs.World.init();
    defer world.deinit(gpa);

    // 4. Spawn entities.
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const eid = try world.spawn(gpa, ecs.Transform{}, ecs.Velocity{ .linear = .{ 0, 1, 0 } });
        try world.addComponent(gpa, eid, Mass, .{});
    }

    // 5. Build the work-stealing job system + the system scheduler.
    var jobs_sched = try jobs.scheduler.Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    var sys = ecs.SystemScheduler.init();
    defer sys.deinit(gpa);

    // 6. Build the query once and stash it in the system's state.
    var query = try world.queryFiltered(gpa, &.{ ecs.Velocity, Mass }, .{});
    defer query.deinit(gpa);
    var state = SystemState{ .query = &query };

    // 7. Register the system on a phase with explicit access.
    try sys.registerSystem(gpa, &world, .{
        .phase = .fixed_update,
        .name = "apply_gravity",
        .run = applyGravity,
        .accesses = &.{ ecs.Reads(Mass), ecs.Writes(ecs.Velocity) },
    });

    // 8. Drive the tick loop.
    var tick: u32 = 0;
    while (tick < 60) : (tick += 1) {
        try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &state);
    }
}
```

## Allocation patterns

The ECS is **alloc-free in steady state** (after init / warm-up).
Concretely:

| Object | Lifetime | Allocates |
|---|---|---|
| `World` | Game-long | On every new archetype (cached after) + entity spawn (slot growth) |
| `Query` | Built once at registration, reused every dispatch | At construction (matches list); zero in steady state. **Lazy re-scan** appends new matches if archetypes get materialised after the query was built (E6) |
| `SystemScheduler.builder` (JobBuilder) | Cross-frame field, lazy-init | Arena grows during warm-up to working set, retained inter-frame |
| `CommandBuffer` (per system) | Lifetime of the system | Arena grows during warm-up; reset with `retain_capacity` on every flush |
| `ObserverRegistry.deferred` | Lifetime of the world | Arena allocated on first observer registration; cmds queued by observers reuse arena |

The `tests/ecs/no_alloc_steady_state.zig` test pins this contract:
4 archetypes × 4 systems × 1000 entities × 100 ticks, zero
`alloc_count` / `free_count` after warm-up.

## System scheduler — DAG + concurrency

`SystemScheduler` exposes 6 canonical phases dispatched in order:

```
pre_update → fixed_update → update → post_update → late_update → pre_render
```

Within a phase, the scheduler builds an implicit DAG from
each system's `accesses` descriptor:

- `Writes(X)` → `Reads(X)` edge (forward dataflow — writer runs before reader regardless of registration order).
- Two `Writes(X)` in the same phase = `error.WriteWriteConflict` at registration. No silent serialisation.

Topological levels are computed via Kahn's algorithm (cached
per phase, invalidated on `registerSystem`). Inside a level,
all systems' chunked work is gathered into one `JobBuilder` and
dispatched in a single wave — workers interleave chunks from
heterogeneous bodies. The phase boundary is an implicit
end-of-level barrier (`dispatchBatch` blocks until
`pending_count` reaches zero).

## Command buffers + observers

Structural mutations (`spawn` / `despawn` / `addComponent` /
`removeComponent`) inside a system body MUST go through
`ctx.cmd` — direct `World.*` mutation during a dispatch breaks
the query/chunk-pointer stability contract.

Flush happens **at the end of each phase** in **system
submission order**. Observers fire interleaved with each cmd
application:

| Command | Pre-apply | Post-apply |
|---|---|---|
| `spawn` | — | `on_spawned` + `on_add[cid]` (new) for each component |
| `add_component` (cid absent) | — | `on_add[cid]` (new) |
| `add_component` (cid present) | — | `on_replaced[cid]` (old + new) — in-place overwrite, no migration |
| `remove_component` | `on_remove[cid]` (old) | — |
| `despawn` | `on_remove[cid]` (old) for each component + `on_despawned` | — |

`on_replaced` (M1.0.2 E3) is triggered solely by `add_component` on an entity
that already has the component: the old value is captured before the overwrite,
then `on_replaced[cid]` fires with old + new. There is no separate `replace`
command.

The `ObserverFn` signature (M1.0.2 E3) is uniform across all kinds:

```zig
*const fn (ctx: ?*anyopaque, world: *World, entity: EntityId,
           component_id: ?ComponentId, old_value: ?*const anyopaque,
           new_value: ?*const anyopaque, deferred: *CommandBuffer) anyerror!void
```

Conventions: `on_added` → `new_value` set, `old_value` null; `on_removed` →
`old_value` set, `new_value` null; `on_replaced` → both set; `on_spawned` /
`on_despawned` → both null, `component_id` null. `ctx` is threaded back from
registration (the Etch interpreter passes a per-rule `{ interp, rule_desc_idx }`).

Observer callbacks may queue further structural mutations
through `deferred.spawn(...)` etc. — those cmds apply at the
**next** phase boundary's flush, never re-entrantly. Explicit
no-recursion contract — see `observers.flushWithObservers`.

## Where to look in the spec

- `engine-ecs-internals.md` — full design reference (archetype
  storage, transitions, query compilation, change detection,
  command buffers, job system, observers, comparison vs
  Bevy/Flecs/DOTS/EnTT).
- `engine-phase-0-criteria.md` — C0.1 metrics and reference
  machine targets.
- `briefs/M0.1-ecs-full.md` — milestone brief with the
  delivery scope, acceptance criteria, and execution journal.
