//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! Public API surface of the ECS — canonical entry point for
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
//! Every type of the stable public surface is re-exported here verbatim. The flat
//! layout (`ecs.World`, `ecs.Query`, `ecs.CommandBuffer`, …) lets consumers reach the
//! whole stable surface through a single import, while the per-implementation
//! sub-modules (`ecs.world`, `ecs.query`, `ecs.command_buffer`, …) stay reachable for
//! tests, the bench, and the rare consumer that needs an internal symbol not promoted
//! to the stable list.
//!
//! Modules NOT re-exported in this root (`ecs.chunk`, `ecs.archetype`, `ecs.registry`,
//! `ecs.resources`, `ecs.entity` internals, …) are considered internals — they back the
//! public API but are not part of the stable contract. Consumers reading from them
//! outside of tests should expect breakage on later milestones.

/// FROZEN — see `engine-phase-0-criteria.md` C0.5.
/// Version of the frozen ECS Tier-0 public surface (World verbs,
/// EntityId/ComponentId layout, Query/CommandBuffer/SystemScheduler
/// signatures, and the byte-keyed `resources` store). Bumped on any
/// breaking change — a tracked migration, not a freeze failure (the
/// `*_PROTOCOL_VERSION` rule, generalized from `WELD_IPC_PROTOCOL_VERSION`).
///
/// At 2 since declared-access enforcement (`ARCH-030`). FOUR of the shapes this
/// version covers changed, and all four are breaking for a Tier-1 caller:
/// `SystemDescriptor.accesses` lost its empty default, `SystemContext` lost its
/// `*World`, `CommandBuffer` lost its `world` — so `flush` and `init` moved with
/// it — and `RegistrationError` gained `DependencyCycle`, which breaks an
/// exhaustive `switch` even though `registerSystem`'s inferred `!void` reads
/// unchanged. That last one RIDES this bump rather than asking for a second:
/// one version covers one milestone's breaking set, and a number incremented
/// per change would stop meaning "the surface a caller compiled against".
/// The additions beside them (`view`, `View`, `Access`, `SystemContextOf`)
/// would not on their own have moved this number.
pub const WELD_ECS_PROTOCOL_VERSION: u32 = 2;

// ─── Sub-module re-exports — keeps `weld_core.ecs.<file>.<symbol>` reachable ──

/// Generational identity store (`EntityIdentityStore`, `EntityId`).
pub const entity = @import("entity.zig");
/// Canonical POD components (`Transform`, `Velocity`).
pub const components = @import("components.zig");
/// World tick counter type.
pub const tick = @import("tick.zig");
/// Change-detection sidecars (dirty bitset, added/changed tick columns).
pub const change_detection = @import("change_detection.zig");
/// 16 KiB byte-level chunk + layout.
pub const chunk = @import("chunk.zig");
/// Byte-level archetype + transition cache.
pub const archetype = @import("archetype.zig");
/// Comptime-typed query (With / Without / Predicate / Changed filters).
pub const query = @import("query.zig");
/// World root: archetype list, identity, registry, observer registry, tick.
pub const world = @import("world.zig");
/// System scheduler: phase pipeline, implicit DAG, cmd buffer wiring.
pub const scheduler = @import("scheduler.zig");
/// Runtime component registry (id assignment + per-type descriptor cache).
pub const registry = @import("registry.zig");

/// Sparse-set component storage, the second backend of `ARCH-005`.
/// Opt-in per component through `@storage(.sparse)`; `table` remains the
/// default.
pub const sparse_storage = @import("sparse_storage.zig");
/// The mixed-query planner and its DISTINCT iteration type. Additive
/// to the ECS surface on the precedent written at `world.zig`'s `queryDynamic`:
/// the C0.5 freeze covers the Tier-0 ↔ Tier-1 module interfaces, not internal
/// `World` methods. `tests/ecs/hybrid_query_test.zig` guards the version by
/// ENUMERATING this surface and reporting its size rather than by declaring the
/// version unchanged.
pub const hybrid_query = @import("hybrid_query.zig");
/// Deprecated re-export of `Archetype` under the legacy `DynamicArchetype` name.
pub const archetype_dynamic = @import("archetype_dynamic.zig");
/// Runtime, `ComponentId`-keyed byte resource store: the permanent Etch
/// resource backend (interpreter + codegen + bridge), NOT superseded by the
/// singleton-entity system in `src/core/resources/`. The two coexist as
/// two models for two consumers (cf. the dual-resource doc on `World.resources`
/// / `World.singleton_resources` in world.zig).
pub const resources = @import("resources.zig");
/// Comptime-typed query consumed by the Etch → Zig codegen.
pub const comptime_query = @import("comptime_query.zig");
/// Per-system command buffer for deferred structural mutations.
pub const command_buffer = @import("command_buffer.zig");
/// Observer registry hooked into the per-phase cmd buffer flush.
pub const observers = @import("observers.zig");
/// Declared-access view: the restricted handle a system receives in place of
/// a `*World`, and the comptime membership test that makes an undeclared
/// access a compile error (`ARCH-030`).
pub const view = @import("view.zig");

// ─── Flat public API ──────────────────────────────────────────────────────

/// Top-level ECS world. Owns archetypes, identities, registry,
/// resources, observer registry, current tick.
pub const World = world.World;

/// Generational entity handle: `packed struct(u64) { index: u32, generation: u32 }`.
pub const EntityId = world.EntityId;

/// Runtime component / resource id assigned by the registry.
pub const ComponentId = registry.ComponentId;

/// Storage backend of a component — `table | sparse`, default `table`
/// (`engine-ecs-internals.md` §2). Re-exported so the Etch front-end can
/// validate `@storage`'s argument against the domain's single declaration
/// instead of re-listing its spellings (`etch-resolver-types.md` §13.3.1).
pub const StorageKind = registry.StorageKind;

/// Stable archetype handle (index into `World.archetypes`).
pub const ArchetypeId = world.ArchetypeId;

/// Monotonic frame tick — `u32` incremented by `World.beginFrame()`.
pub const Tick = tick.Tick;

/// The canonical archetype's Transform component (`pos`, `rot`, `scale`).
pub const Transform = world.Transform;

/// The canonical archetype's Velocity component (`linear`, `angular`).
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

/// Per-call argument bundle passed to every `SystemFn` body. Carries the
/// world ERASED — a system that wants entity data takes `SystemContextOf`.
pub const SystemContext = scheduler.SystemContext;

/// The context a system declared through `SystemDescriptor.of` receives:
/// `SystemContext` with its erased world replaced by the `View` its
/// declaration parameterises.
pub const SystemContextOf = scheduler.SystemContextOf;

/// One entry of a declared access set, carrying the component or resource
/// TYPE. Written by every system author: `Access.reads(T)`,
/// `Access.writes(T)`, `Access.readsResource(R)`, `Access.writesResource(R)`.
pub const Access = view.Access;

/// Restricted handle over a `World`, parameterised by a declared access set.
/// An undeclared access, or a mutable access to a read-declared component,
/// does not compile.
pub const View = view.View;

/// Type-erased system entry point.
pub const SystemFn = scheduler.SystemFn;

/// `Reads(T)` access descriptor — adds a read edge on `T` to the
/// system's access list.
pub const Reads = scheduler.Reads;

/// `Writes(T)` access descriptor — adds a write edge on `T` to the
/// system's access list.
pub const Writes = scheduler.Writes;

/// `ReadsResource(R)` access descriptor — placeholder for resource
/// reads (the resource API is unimplemented).
pub const ReadsResource = scheduler.ReadsResource;

/// `WritesResource(R)` access descriptor — placeholder for resource
/// writes (the resource API is unimplemented).
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
