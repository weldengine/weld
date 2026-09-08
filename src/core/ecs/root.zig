//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! The flat names below are the CONTRACT. The sub-module re-exports stay reachable
//! for tests and the bench, and reading from one is reading an internal.

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Bumped on any breaking change of the surface — a tracked migration, not a fault.
pub const WELD_ECS_PROTOCOL_VERSION: u32 = 1;

/// Generational identity store.
pub const entity = @import("entity.zig");
/// Canonical POD components.
pub const components = @import("components.zig");
/// World tick counter type.
pub const tick = @import("tick.zig");
/// Change-detection sidecars.
pub const change_detection = @import("change_detection.zig");
/// 16 KiB byte-level chunk + layout.
pub const chunk = @import("chunk.zig");
/// Byte-level archetype + transition cache.
pub const archetype = @import("archetype.zig");
/// Comptime-typed query and its filter specs.
pub const query = @import("query.zig");
/// World root: archetypes, identity, registry, observers, tick.
pub const world = @import("world.zig");
/// System scheduler: phase pipeline, implicit DAG, command-buffer wiring.
pub const scheduler = @import("scheduler.zig");
/// Runtime component registry.
pub const registry = @import("registry.zig");

/// Sparse-set storage, opt-in per component; `table` stays the default.
pub const sparse_storage = @import("sparse_storage.zig");
/// The mixed-query planner and its DISTINCT iteration type.
pub const hybrid_query = @import("hybrid_query.zig");
/// Deprecated re-export under the legacy `DynamicArchetype` name.
pub const archetype_dynamic = @import("archetype_dynamic.zig");
/// The Etch resource backend; `src/core/resources/` is a DIFFERENT model, not a heir.
pub const resources = @import("resources.zig");
/// Comptime-typed query consumed by the Etch → Zig codegen.
pub const comptime_query = @import("comptime_query.zig");
/// Per-system command buffer for deferred structural mutations.
pub const command_buffer = @import("command_buffer.zig");
/// Observer registry, hooked into the per-phase flush.
pub const observers = @import("observers.zig");

/// Top-level ECS world.
pub const World = world.World;

/// Generational entity handle: `packed struct(u64) { index: u32, generation: u32 }`.
pub const EntityId = world.EntityId;

/// Runtime component / resource id assigned by the registry.
pub const ComponentId = registry.ComponentId;

/// `table | sparse`; re-exported so the Etch front-end validates `@storage` here.
pub const StorageKind = registry.StorageKind;

/// Stable archetype handle (index into `World.archetypes`).
pub const ArchetypeId = world.ArchetypeId;

/// Monotonic frame tick — `u32` incremented by `World.beginFrame()`.
pub const Tick = tick.Tick;

/// Canonical `Transform` component (`pos`, `rot`, `scale`).
pub const Transform = world.Transform;

/// Canonical `Velocity` component (`linear`, `angular`).
pub const Velocity = world.Velocity;

/// Byte-level archetype storage, for a caller walking archetypes directly.
pub const Archetype = world.Archetype;

/// 16 KiB byte-level chunk, surfaced by `Query.chunkAt(i)`.
pub const Chunk = world.Chunk;

/// `(archetype_idx, chunk_idx, slot)` location of an entity.
pub const Location = world.Location;

/// Errors returned by `World.despawn` and friends.
pub const WorldError = world.WorldError;

/// Comptime query FACTORY — `ecs.Query(components, filters)` returns the type.
pub const Query = query.Query;

/// Filter spec: matching archetype must contain `T`.
pub const With = query.With;

/// Filter spec: matching archetype must NOT contain `T`.
pub const Without = query.Without;

/// Filter spec: per-slot predicate evaluated by `query.slotPasses`.
pub const Predicate = query.Predicate;

/// Filter spec: `T`'s `changed_tick` strictly after the query's `last_run_tick`.
pub const Changed = query.Changed;

/// Per-system command buffer, reached through `SystemContext.cmd`.
pub const CommandBuffer = command_buffer.CommandBuffer;

/// Tagged-union command kind hosted by `CommandBuffer`.
pub const Command = command_buffer.Command;

/// Callback signature for observer hooks.
pub const ObserverFn = observers.ObserverFn;

/// Phase-based system registry with implicit DAG and intra-phase dispatch.
pub const SystemScheduler = scheduler.SystemScheduler;

/// System descriptor: phase, name, run function, access list.
pub const SystemDescriptor = scheduler.SystemDescriptor;

/// The canonical phase pipeline, in order.
pub const Phase = scheduler.Phase;

/// Per-frame state surfaced to every system.
pub const FrameContext = scheduler.FrameContext;

/// Per-call argument bundle passed to every `SystemFn` body.
pub const SystemContext = scheduler.SystemContext;

/// Type-erased system entry point.
pub const SystemFn = scheduler.SystemFn;

/// Adds a READ edge on `T` to the system's access list.
pub const Reads = scheduler.Reads;

/// Adds a WRITE edge on `T` to the system's access list.
pub const Writes = scheduler.Writes;

/// Placeholder — the resource access API does not exist yet.
pub const ReadsResource = scheduler.ReadsResource;

/// Placeholder — the resource access API does not exist yet.
pub const WritesResource = scheduler.WritesResource;

/// One access entry on a `SystemDescriptor`.
pub const AccessDescriptor = scheduler.AccessDescriptor;

/// Discriminator for `AccessDescriptor.kind`.
pub const AccessKind = scheduler.AccessKind;

/// Job batch accumulator, surfaced via `SystemContext.builder`.
pub const JobBuilder = scheduler.JobBuilder;

/// Error set returned by `SystemScheduler.registerSystem`.
pub const RegistrationError = scheduler.RegistrationError;
