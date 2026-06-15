//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Public API surface of the M0.1 ECS — canonical entry point for
//! consumers (Tier 1 modules, the runtime executable, the editor IPC
//! layer, the Etch codegen, end-user code).
//!
//! Importing convention:
//!
//! ```zig
//! const ecs = @import("weld_core").ecs;
//! var world = ecs.World.init();
//! const eid = try world.spawn(gpa, ecs.Transform{}, ecs.Velocity{});
//! ```
//!
//! Every type listed in `briefs/M0.1-ecs-full.md` § Scope › Public API
//! surface is re-exported here verbatim. The flat layout (`ecs.World`,
//! `ecs.Query`, `ecs.CommandBuffer`, …) lets consumers reach the
//! whole stable surface through a single import, while the
//! per-implementation sub-modules (`ecs.world`, `ecs.query`,
//! `ecs.command_buffer`, …) stay reachable for tests, the bench, and
//! the rare consumer that needs an internal symbol the brief did not
//! promote to the stable list.
//!
//! Modules NOT re-exported in this root (`ecs.chunk`, `ecs.archetype`,
//! `ecs.registry`, `ecs.resources`, `ecs.entity` internals, …) are
//! considered internals — they back the public API but are not part
//! of the M0.1 contract. Consumers reading from them outside of
//! tests should expect breakage on later milestones.

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
/// Version of the frozen ECS Tier-0 public surface (World verbs,
/// EntityId/ComponentId layout, Query/CommandBuffer/SystemScheduler
/// signatures, and the byte-keyed `resources` store). Bumped on any
/// breaking change — a tracked migration, not a freeze failure (the
/// `*_PROTOCOL_VERSION` rule, generalized from `WELD_IPC_PROTOCOL_VERSION`).
pub const WELD_ECS_PROTOCOL_VERSION: u32 = 1;

// ─── Sub-module re-exports — keeps `weld_core.ecs.<file>.<symbol>` reachable ──

/// E1 — generational identity store (`EntityIdentityStore`, `EntityId`).
pub const entity = @import("entity.zig");
/// E1 — canonical POD components (`Transform`, `Velocity`).
pub const components = @import("components.zig");
/// E4 — world tick counter type.
pub const tick = @import("tick.zig");
/// E4 — change-detection sidecars (dirty bitset, added/changed tick columns).
pub const change_detection = @import("change_detection.zig");
/// E2 — 16 KiB byte-level chunk + layout.
pub const chunk = @import("chunk.zig");
/// E2 — byte-level archetype + transition cache.
pub const archetype = @import("archetype.zig");
/// E3 — comptime-typed query (With/Without/Predicate filters) + E4 Changed.
pub const query = @import("query.zig");
/// E2/E4 — World root: archetype list, identity, registry, observer registry, tick.
pub const world = @import("world.zig");
/// E5a/E5b/E6 — system scheduler: phase pipeline, implicit DAG, cmd buffer wiring.
pub const scheduler = @import("scheduler.zig");
/// S4 — runtime component registry (id assignment + per-type descriptor cache).
pub const registry = @import("registry.zig");
/// S4 — deprecated re-export of `Archetype` under the legacy `DynamicArchetype` name.
pub const archetype_dynamic = @import("archetype_dynamic.zig");
/// S4 — runtime, `ComponentId`-keyed byte resource store: the permanent Etch
/// resource backend (interpreter + codegen + bridge), NOT superseded by the
/// M0.2 singleton-entity system in `src/core/resources/`. The two coexist as
/// two models for two consumers (cf. the dual-resource doc on `World.resources`
/// / `World.singleton_resources` in world.zig).
pub const resources = @import("resources.zig");
/// S5 — comptime-typed query consumed by the Etch → Zig codegen.
pub const comptime_query = @import("comptime_query.zig");
/// E6 — per-system command buffer for deferred structural mutations.
pub const command_buffer = @import("command_buffer.zig");
/// E6 — observer registry hooked into the per-phase cmd buffer flush.
pub const observers = @import("observers.zig");

// ─── Flat public API ──────────────────────────────────────────────────────

/// Top-level ECS world. Owns archetypes, identities, registry,
/// resources, observer registry, current tick.
pub const World = world.World;

/// Generational entity handle: `packed struct(u64) { index: u32, generation: u32 }`.
pub const EntityId = world.EntityId;

/// Runtime component / resource id assigned by the registry.
pub const ComponentId = registry.ComponentId;

/// Stable archetype handle (index into `World.archetypes`).
pub const ArchetypeId = world.ArchetypeId;

/// Monotonic frame tick — `u32` incremented by `World.beginFrame()`.
pub const Tick = tick.Tick;

/// Canonical S1 archetype's Transform component (`pos`, `rot`, `scale`).
pub const Transform = world.Transform;

/// Canonical S1 archetype's Velocity component (`linear`, `angular`).
pub const Velocity = world.Velocity;

/// Byte-level archetype storage. Public for callers that walk
/// archetypes directly (the bench, the Etch interpreter); typical
/// consumers go through `World.queryFiltered` instead.
pub const Archetype = world.Archetype;

/// 16 KiB byte-level chunk. Surfaced by `Query.chunkAt(i)` and by
/// the system body trampolines.
pub const Chunk = world.Chunk;

/// `(archetype_idx, chunk_idx, slot)` location of an entity inside
/// the world.
pub const Location = world.Location;

/// Errors returned by `World.despawn` and friends.
pub const WorldError = world.WorldError;

/// Comptime-typed query factory. `ecs.Query(components, filters)`
/// returns the concrete query type; `World.query` / `World.queryFiltered`
/// instantiate one against a world.
pub const Query = query.Query;

/// Filter spec: matching archetype must contain `T`.
pub const With = query.With;

/// Filter spec: matching archetype must NOT contain `T`.
pub const Without = query.Without;

/// Filter spec: per-slot predicate evaluated by `query.slotPasses`.
pub const Predicate = query.Predicate;

/// Filter spec: matches slots where `T`'s `changed_tick` is strictly
/// greater than the query's runtime `last_run_tick`.
pub const Changed = query.Changed;

/// Per-system command buffer for deferred structural mutations.
/// Accessed by systems via `SystemContext.cmd`.
pub const CommandBuffer = command_buffer.CommandBuffer;

/// Tagged-union command kind hosted by `CommandBuffer`.
pub const Command = command_buffer.Command;

/// Callback signature for observer hooks.
pub const ObserverFn = observers.ObserverFn;

/// Phase-based system registry + implicit DAG + concurrent
/// intra-phase dispatch.
pub const SystemScheduler = scheduler.SystemScheduler;

/// System descriptor: phase, name, run function, access list.
pub const SystemDescriptor = scheduler.SystemDescriptor;

/// Canonical phase pipeline (`pre_update`, `fixed_update`, `update`,
/// `post_update`, `late_update`, `pre_render`).
pub const Phase = scheduler.Phase;

/// Per-frame state surfaced to every system.
pub const FrameContext = scheduler.FrameContext;

/// Per-call argument bundle passed to every `SystemFn` body.
pub const SystemContext = scheduler.SystemContext;

/// Type-erased system entry point.
pub const SystemFn = scheduler.SystemFn;

/// `Reads(T)` access descriptor — adds a read edge on `T` to the
/// system's access list.
pub const Reads = scheduler.Reads;

/// `Writes(T)` access descriptor — adds a write edge on `T` to the
/// system's access list.
pub const Writes = scheduler.Writes;

/// `ReadsResource(R)` access descriptor — placeholder for resource
/// reads (M0.2 lands the resource API).
pub const ReadsResource = scheduler.ReadsResource;

/// `WritesResource(R)` access descriptor — placeholder for resource
/// writes (M0.2 lands the resource API).
pub const WritesResource = scheduler.WritesResource;

/// One access entry on a `SystemDescriptor`.
pub const AccessDescriptor = scheduler.AccessDescriptor;

/// Discriminator for `AccessDescriptor.kind`
/// (`reads` / `writes` / `reads_resource` / `writes_resource`).
pub const AccessKind = scheduler.AccessKind;

/// Heterogeneous job batch accumulator used by `SystemScheduler`
/// during intra-phase dispatch. Surfaced via `SystemContext.builder`.
pub const JobBuilder = scheduler.JobBuilder;

/// Error set returned by `SystemScheduler.registerSystem`.
pub const RegistrationError = scheduler.RegistrationError;
