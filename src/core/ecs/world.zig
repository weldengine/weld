//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Tier 0 root `World` — owns the unified archetype list, the M0.1 / E1
//! generational identity store, the runtime registry, and the resource
//! store. M0.1 / E2 collapsed the S1 (single hardcoded archetype) and S4
//! (list of dynamic archetypes) storage paths into a single byte-level
//! archetype layer (`archetype.zig`); both spawn paths and every query
//! now resolve to one entry in `archetypes`.
//!
//! Identity, archetype storage, and location maps are now consolidated:
//!
//! - `identity` (per E1) gives every spawned entity a generational
//!   handle and a free-list-recyclable slot index.
//! - `archetypes` holds every materialised archetype as a stable
//!   `*Archetype`. `archetype_by_signature` keys on the sorted byte
//!   view of the component-id list so add/remove transitions can find
//!   their target without rescanning the list.
//! - `entity_locations` is the single map from `EntityId → Location`
//!   covering both spawn paths. (`dynamic_locations` was retired with
//!   the E2 consolidation.)
//!
//! Transitions (`addComponent` / `removeComponent`) route through each
//! archetype's `TransitionCache`: the first add or remove of a given
//! component performs a global signature lookup and caches the resulting
//! `ArchetypeId`; subsequent transitions hit the cache.

const std = @import("std");
const components = @import("components.zig");
const entity_mod = @import("entity.zig");
const archetype_mod = @import("archetype.zig");
const query_mod = @import("query.zig");
const chunk_mod = @import("chunk.zig");
const tick_mod = @import("tick.zig");

const registry_mod = @import("registry.zig");
const resources_mod = @import("resources.zig");
const observers_mod = @import("observers.zig");
// M0.2 / E3 — singleton-entity resource registry, distinct from the
// M0.1 / S4 byte-keyed `ResourceStore` above (which the Etch
// interpreter still consumes).
const singleton_resources_mod = @import("../resources/registry.zig");
// M0.2 / E4 — heterogeneous event bus. Direct field on World per
// the technical decision E4 in the brief § Notes (alternative was
// scheduler-injected via ModuleContext; field-on-World aligns with
// E3's singleton_resources and with `engine-tier-interfaces.md`
// §0 which lists `event_bus` among Tier 0 services).
const events_bus_mod = @import("../events/bus.zig");
// M1.1.1-HF2 C4 — Tier-0 persistent heap (moved to core in M1.0.5). `World`
// owns the uniform decref walk over resource-owned payload slots; see
// `releaseResourcePayloads`.
const persistent = @import("../memory/persistent.zig");
// M1.B — the second storage backend. `World` owns the per-component sparse
// sets exactly as it owns `archetypes`; nothing below `world.zig` knows there
// are two backends (cf. `briefs/artifacts/m1.B-g0-site-list-and-contract.md`
// §2.1, one producer).
const sparse_mod = @import("sparse_storage.zig");

/// Public surface for consumers that spawn `(Transform, Velocity)`
/// entities without depending on `components.zig` directly — the
/// canonical write path for the S1 archetype.
pub const Transform = components.Transform;
/// Public surface mirror of `Transform`, same rationale.
pub const Velocity = components.Velocity;
/// Public alias so consumers can declare `EntityId` parameters
/// without taking a dependency on `components.zig`. Same packed
/// `(index, generation)` shape as the canonical type in `entity.zig`.
pub const EntityId = components.EntityId;
/// Errors surfaced by `World.despawn` and friends. Re-exported here so
/// consumers do not need to reach into `entity.zig` directly.
pub const WorldError = entity_mod.WorldError;
/// Canonical S1 query type — `Query(.{Transform, Velocity}, .{})` with
/// no E3 filters. Exposed so `bench/ecs_benchmark.zig` and the
/// scheduler tests can declare typed `*Chunk` bodies without spelling
/// out the comptime filter tuple.
pub const Query = query_mod.Query(&.{ Transform, Velocity }, .{});
/// Runtime, `ComponentId`-keyed query type (M1.0.0). Re-exported so the Etch
/// interpreter (which holds resolved ids, not Zig types) can name the return
/// type of `World.queryDynamic` without reaching into `query.zig`.
pub const DynamicQuery = query_mod.DynamicQuery;
/// Public alias for the byte-level archetype so the bench / tests do
/// not need to know about the deprecated `archetype_dynamic` shim.
pub const Archetype = archetype_mod.Archetype;
/// Public alias for the byte-level chunk.
pub const Chunk = chunk_mod.Chunk;
/// Canonical entity location — `(archetype_idx, chunk_idx, slot)`.
pub const Location = archetype_mod.Location;
/// Stable archetype handle (index into `World.archetypes`).
pub const ArchetypeId = archetype_mod.ArchetypeId;
/// Deprecated alias kept for Etch bridge / demo binaries that still
/// import `world.DynamicLocation`.
pub const DynamicLocation = Location;
/// World tick counter type, re-exported for callers driving the
/// E4 change-detection sidecars.
pub const Tick = tick_mod.Tick;

const Registry = registry_mod.Registry;
const ComponentId = registry_mod.ComponentId;
const ComponentDesc = registry_mod.ComponentDesc;
const FieldDesc = registry_mod.FieldDesc;
const FieldKind = registry_mod.FieldKind;
const ResourceStore = resources_mod.ResourceStore;
const EntityIdentityStore = entity_mod.EntityIdentityStore;

/// M1.0.6 E6 — the `on_attach` extension dispatch seam (D-E). A Tier-0 function
/// pointer the Etch bridge registers; the scene loader fires it after adding an
/// extension's components, passing the entity, the extension name, and the cooked
/// `on_attach` Etch source text (`null` if absent). M1.0.6 wired + fired the
/// seam; M1.0.9 registers the Etch bridge's callback, which re-parses + runs the
/// text — the seam itself still only fires whatever callback is registered.
pub const ExtensionAttachFn = *const fn (
    ctx: ?*anyopaque,
    world: *World,
    entity: EntityId,
    extension_name: []const u8,
    on_attach_text: ?[]const u8,
) anyerror!void;

/// A registered `on_attach` callback + its opaque context.
const AttachHook = struct { ctx: ?*anyopaque, func: ExtensionAttachFn };

/// M1.0.9 — the `on_detach` extension dispatch seam, mirror of
/// `ExtensionAttachFn`. Fired by the runtime `deactivate_extension` path BEFORE
/// removing the extension's components (so the hook still sees them), passing
/// the cooked `on_detach` Etch source text (`null` if absent). Never fired at
/// load — load only activates.
pub const ExtensionDetachFn = *const fn (
    ctx: ?*anyopaque,
    world: *World,
    entity: EntityId,
    extension_name: []const u8,
    on_detach_text: ?[]const u8,
) anyerror!void;

/// A registered `on_detach` callback + its opaque context.
const DetachHook = struct { ctx: ?*anyopaque, func: ExtensionDetachFn };

/// Top-level ECS world — single archetype list, shared identity, shared
/// registry, shared resources.
pub const World = struct {
    // ── Shared identity (M0.1 / E1) ──
    /// Generational identity store driving every spawn / despawn. A
    /// single store guarantees that the `(index, generation)` halves of
    /// an `EntityId` stay unique world-wide.
    identity: EntityIdentityStore,

    // ── Change detection (M0.1 / E4) ──
    /// Monotonic frame counter. Incremented by `beginFrame()` at the
    /// start of each tick; written into every spawn / migration's
    /// `added_tick` + `changed_tick` sidecars and into every
    /// `getMut(T)` auto-mark. Reads happen from `Query.last_run_tick`
    /// comparisons.
    current_tick: Tick,

    // ── Component metadata + storage (M0.1 / E2) ──
    /// Runtime component / resource type registry. Assigns
    /// `ComponentId`s on first registration and caches size +
    /// alignment + default bytes + field descriptors.
    registry: Registry,
    /// Every archetype the world has materialised, stored as
    /// stable `*Archetype` so the transition cache and the location
    /// map can hold raw archetype ids without worrying about
    /// reallocation invalidating pointers.
    archetypes: std.ArrayListUnmanaged(*Archetype),
    /// `signature bytes → archetype id` lookup. The bytes are a view
    /// over the archetype's owned `component_ids` slice, so the key
    /// lifetime is tied to the archetype.
    archetype_by_signature: std.StringHashMapUnmanaged(ArchetypeId),
    /// Single `EntityId → Location` map covering every spawn path.
    entity_locations: std.AutoHashMapUnmanaged(EntityId, Location),

    /// **Runtime, `ComponentId`-keyed** resource store (M0.1 / S4) —
    /// the resource backend the **Etch** subsystem requires: the
    /// tree-walking interpreter and the Zig codegen resolve resource
    /// names → `ComponentId` and access raw bytes at runtime (neither
    /// has a comptime type to hand to a typed API). Also driven by the
    /// Etch differential corpus + bench. Canonical for all
    /// runtime/dynamic resource access.
    resources: ResourceStore,

    /// M0.2 / E3 — **comptime-`TypeId`-keyed** singleton-entity resource
    /// registry (`rtti.TypeId → EntityId`) for resources set via
    /// `src/core/resources/` (`setResource(T)` / `getResourceMut(T)`).
    /// Canonical for the comptime-typed host / slice / test API, and the
    /// only path with query-exclusion (resources are real entities).
    ///
    /// This and `resources` above are **NOT duplication**: they are two
    /// models for two disjoint consumers — a runtime/byte path (Etch)
    /// and a comptime/typed path (host). Phase 0 freezes **both** (C0.5).
    /// The true unification (a typed path for the interpreter, or a
    /// runtime-id path for this registry) needs Etch capabilities absent
    /// in Phase 0 and is deferred to a Phase-1 milestone.
    singleton_resources: singleton_resources_mod.ResourceRegistry = .{},

    /// M0.2 / E4 — heterogeneous event bus. Owns the per-event-type
    /// MPMC queues registered via `events.register(world, gpa, T,
    /// cap, lifetime)`. Drained by the scheduler at phase / tick
    /// / frame boundaries.
    event_bus: events_bus_mod.EventBus = .{},

    /// M0.1 / E6 — observer registry. Carries per-event callback
    /// lists + a shared deferred command buffer for observer-issued
    /// mutations. Lazy-init'd by the first `registerOn*` call; tests
    /// that don't exercise observers never pay the alloc cost.
    observer_registry: observers_mod.ObserverRegistry = .{},

    /// M1.0.6 E6 — the `on_attach` extension dispatch seam (D-E). A Tier-0
    /// callback the Etch bridge registers; the scene loader fires it after adding
    /// an extension's components. `loader.zig` never calls the Etch VM directly —
    /// it goes through this hook. **M1.0.6 wires + fires the seam only**; the
    /// actual execution of `on_attach_text` (Etch code) is **M1.0.9** (wired in
    /// the Etch bridge's registered callback, not here — the seam still just
    /// fires).
    attach_hook: ?AttachHook = null,

    /// M1.0.9 — the `on_detach` extension dispatch seam, mirror of `attach_hook`.
    /// Registered by the Etch bridge; fired by the runtime deactivate path before
    /// removing an extension's components. `null` until registered (last wins).
    detach_hook: ?DetachHook = null,

    /// M1.0.9 — per-entity active-extension set: an entity → the OWNED copies of
    /// the names of the extensions currently active on it, in activation order.
    /// Populated by `addEntityExtension` inside the shared activate path (so load
    /// AND runtime activation both track for free), pruned by
    /// `removeEntityExtension` on deactivate, freed in `deinit`. Not serialized —
    /// rebuilt at load from the Entity Extensions Table via the same path. Backs
    /// the interpreter's `has_extension` / `active_extensions`.
    entity_extensions: std.AutoHashMapUnmanaged(EntityId, std.ArrayListUnmanaged([]const u8)) = .empty,

    /// M1.B — per-component sparse sets, one slot per `ComponentId` whose
    /// registry descriptor carries `.sparse`. Defaulted and NOT listed in
    /// `init()`, so a world registering no sparse component allocates no slot.
    ///
    /// The mode is a property of the RUNTIME REGISTRY and never of an entity's
    /// on-disk identity, which is what makes a pre-M1.B scene load unchanged.
    sparse_stores: sparse_mod.SparseStores = .{},

    /// M1.B/G9 — how many `@requires` removals were SKIPPED this tick.
    ///
    /// The refusal channel: a counted field plus a `std.log.warn` bounded to one
    /// line per tick, the `syncIn` shape.
    ///
    /// **On `World` and NOT on `RuntimeReport`** — a Zig system can refuse a
    /// removal as readily as a rule, and a counter on the Etch report would make
    /// the first invisible.
    ///
    /// **Per TICK, and cleared at BOTH boundaries** — see
    /// `resetTickObservations`. Resetting in `beginFrame` alone makes the field
    /// mean "per tick" or "per run" depending on whether the program uses a
    /// `changed` filter somewhere else entirely.
    requires_removals_skipped: u32 = 0,
    /// The first component id whose removal was skipped this tick, so the log
    /// line names one rather than only counting.
    first_requires_skip: ?ComponentId = null,

    pub fn init() World {
        return .{
            .identity = EntityIdentityStore.init(),
            .current_tick = tick_mod.initial_tick,
            .registry = Registry.init(),
            .archetypes = .empty,
            .archetype_by_signature = .empty,
            .entity_locations = .empty,
            .resources = ResourceStore.init(),
            .singleton_resources = singleton_resources_mod.ResourceRegistry.init(),
            .event_bus = events_bus_mod.EventBus.init(),
            .observer_registry = observers_mod.ObserverRegistry.init(),
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        for (self.archetypes.items) |a| {
            a.deinit(gpa);
            gpa.destroy(a);
        }
        self.archetypes.deinit(gpa);
        self.archetype_by_signature.deinit(gpa);
        self.sparse_stores.deinit(gpa);
        self.entity_locations.deinit(gpa);
        // Reclaim resource-owned persistent payloads (strings, collections)
        // BEFORE freeing the byte buffers (M1.1.1-HF2 C4). Idempotent — a no-op
        // when an interpreter already ran this in its own deinit.
        self.releaseResourcePayloads(gpa);
        self.resources.deinit(gpa);
        self.singleton_resources.deinit(gpa);
        self.event_bus.deinit(gpa);
        self.registry.deinit(gpa);
        self.identity.deinit(gpa);
        self.observer_registry.deinit(gpa);
        {
            // Free each entity's owned extension-name copies + its list (M1.0.9).
            var it = self.entity_extensions.valueIterator();
            while (it.next()) |list| {
                for (list.items) |name| gpa.free(name);
                list.deinit(gpa);
            }
            self.entity_extensions.deinit(gpa);
        }
        self.* = undefined;
    }

    // ─── Observer registration (M0.1 / E6) ───────────────────────────────

    /// Register an `on_spawned` observer (M1.0.2 E3: `ctx` threaded back to the
    /// callback; native callers pass `null`).
    pub fn registerOnSpawned(
        self: *World,
        gpa: std.mem.Allocator,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        try self.observer_registry.registerOnSpawned(gpa, self, ctx, callback);
    }

    /// Register an `on_despawned` observer.
    pub fn registerOnDespawned(
        self: *World,
        gpa: std.mem.Allocator,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        try self.observer_registry.registerOnDespawned(gpa, self, ctx, callback);
    }

    /// Register an `on_add` observer for component `T`.
    pub fn registerOnAdd(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnAdd(gpa, self, cid, ctx, callback);
    }

    /// Register an `on_remove` observer for component `T`.
    pub fn registerOnRemove(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnRemove(gpa, self, cid, ctx, callback);
    }

    /// Register an `on_replaced` observer for component `T` (M1.0.2 E3 — fires
    /// when `T` is added to an entity that already has it).
    pub fn registerOnReplaced(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnReplaced(gpa, self, cid, ctx, callback);
    }

    /// M1.0.5 E2 — fire `on_spawned` for one already-spawned entity. The scene
    /// loader's two-phase lifecycle pass calls this directly: entities are
    /// instantiated by `spawnDynamicWithValues` (which fires no observers), then
    /// `on_spawned` is dispatched per entity in a second pass, guaranteeing
    /// every loaded entity exists before any `on_spawned` rule runs. An
    /// `on_spawned` rule may queue structural commands into the shared deferred
    /// buffer; the caller drains it via the usual flush path.
    pub fn dispatchOnSpawned(self: *World, gpa: std.mem.Allocator, eid: EntityId) !void {
        try self.observer_registry.dispatchOnSpawned(gpa, self, eid);
    }

    /// M1.0.15 — immediate spawn with initial values that fires the same
    /// observers a deferred `.spawn` flush would (on_spawned + on_add), returning
    /// the new handle. Backs the Etch `world.spawn_with` test-runner surface;
    /// wraps `ObserverRegistry.spawnWithObservers`.
    pub fn spawnWithObservers(
        self: *World,
        gpa: std.mem.Allocator,
        component_ids: []const ComponentId,
        payloads: []const []const u8,
    ) !EntityId {
        return self.observer_registry.spawnWithObservers(gpa, self, component_ids, payloads);
    }

    /// M1.0.6 E6 — register the `on_attach` extension dispatch callback (the Etch
    /// bridge supplies the real one; M1.0.6 tests supply a Tier-0 stand-in). One
    /// hook per world (last registration wins).
    pub fn registerOnAttach(self: *World, ctx: ?*anyopaque, callback: ExtensionAttachFn) void {
        self.attach_hook = .{ .ctx = ctx, .func = callback };
    }

    /// M1.0.6 E6 — fire the `on_attach` seam for `entity`'s newly-activated
    /// extension `extension_name`, passing the cooked `on_attach_text` (the Etch
    /// hook source; `null` if the extension has no `on_attach`). No-op if no hook
    /// is registered. The loader calls this after adding the extension's
    /// components. The registered callback (the Etch bridge, M1.0.9) re-parses +
    /// executes the text; here the seam just fires it.
    pub fn dispatchOnAttach(self: *World, entity: EntityId, extension_name: []const u8, on_attach_text: ?[]const u8) anyerror!void {
        if (self.attach_hook) |h| try h.func(h.ctx, self, entity, extension_name, on_attach_text);
    }

    /// M1.0.9 — register the `on_detach` extension dispatch callback (mirror of
    /// `registerOnAttach`). One hook per world (last registration wins).
    pub fn registerOnDetach(self: *World, ctx: ?*anyopaque, callback: ExtensionDetachFn) void {
        self.detach_hook = .{ .ctx = ctx, .func = callback };
    }

    /// M1.0.9 — fire the `on_detach` seam for `entity`'s extension being
    /// deactivated, passing the cooked `on_detach_text` (`null` if absent). The
    /// runtime deactivate path calls this BEFORE removing the extension's
    /// components, so the hook still sees them. No-op if no hook is registered.
    pub fn dispatchOnDetach(self: *World, entity: EntityId, extension_name: []const u8, on_detach_text: ?[]const u8) anyerror!void {
        if (self.detach_hook) |h| try h.func(h.ctx, self, entity, extension_name, on_detach_text);
    }

    /// M1.0.9 — record `name` as an active extension on `entity` (storing an
    /// OWNED copy). Called inside the shared activate path after the extension's
    /// components are added. A name already present is not duplicated (the
    /// activate path rejects a re-activation via component conflict first, so
    /// this is belt-and-braces).
    pub fn addEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8) !void {
        const gop = try self.entity_extensions.getOrPut(gpa, entity);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try gop.value_ptr.append(gpa, owned);
    }

    /// R6 (M1.1.1-HF3) — reserve everything a following `commitEntityExtension`
    /// needs so that commit is infallible: dupe `name` (returned to the caller),
    /// reserve one map slot, and reserve one slot in the entity's inner list.
    /// This is the fallible half of the reserve-then-mutate split
    /// `activateExtension` uses. It performs **no observable extension mutation**:
    /// it may materialize a fresh EMPTY list entry for `entity`, but an empty set
    /// reads as "no extensions" through `hasEntityExtension` / `entityExtensions`,
    /// so a caller that aborts before `commitEntityExtension` (e.g. the grouped add
    /// fails) leaves observable state unchanged and the call retryable. The stray
    /// empty entry is inert and reclaimed at `despawn` / `deinit`.
    pub fn reserveEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8) ![]u8 {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.entity_extensions.ensureUnusedCapacity(gpa, 1);
        const gop = self.entity_extensions.getOrPutAssumeCapacity(entity);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.ensureUnusedCapacity(gpa, 1);
        return owned;
    }

    /// R6 (M1.1.1-HF3) — infallibly record an extension reserved by
    /// `reserveEntityExtension`, taking ownership of `owned`. Appends via
    /// `appendAssumeCapacity` (capacity reserved). Belt-and-braces dedup: if the
    /// name is already active it frees `owned` instead (the activate path's
    /// component-conflict check already precludes re-activation). Either way the
    /// caller must not touch `owned` afterwards.
    pub fn commitEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, owned: []u8) void {
        const list = self.entity_extensions.getPtr(entity).?; // reserved above
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, owned)) {
                gpa.free(owned);
                return;
            }
        }
        list.appendAssumeCapacity(owned);
    }

    /// M1.0.9 — drop `name` from `entity`'s active-extension set, freeing the
    /// owned copy. No-op if absent. Removes the map entry once the set empties.
    pub fn removeEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8) void {
        const list = self.entity_extensions.getPtr(entity) orelse return;
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (std.mem.eql(u8, list.items[i], name)) {
                gpa.free(list.items[i]);
                _ = list.orderedRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            list.deinit(gpa);
            _ = self.entity_extensions.remove(entity);
        }
    }

    /// M1.0.9 — whether `name` is currently active on `entity`.
    pub fn hasEntityExtension(self: *const World, entity: EntityId, name: []const u8) bool {
        const list = self.entity_extensions.getPtr(entity) orelse return false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }

    /// M1.0.9 — the OWNED names of the extensions active on `entity`, in
    /// activation order (empty slice if none). Borrowed view — valid until the
    /// entity's set is next mutated.
    pub fn entityExtensions(self: *const World, entity: EntityId) []const []const u8 {
        const list = self.entity_extensions.getPtr(entity) orelse return &.{};
        return list.items;
    }

    /// M1.1.1-HF1 (D7) — drop `entity`'s entire active-extension set, freeing
    /// every owned name copy and the backing list, and dropping the map entry.
    /// No-op when the entity has no active extensions. Called from `despawn` so
    /// a despawned entity never leaves its extension-name copies stranded in
    /// `entity_extensions` until `deinit`.
    fn purgeEntityExtensions(self: *World, gpa: std.mem.Allocator, entity: EntityId) void {
        if (self.entity_extensions.fetchRemove(entity)) |kv| {
            var list = kv.value;
            for (list.items) |name| gpa.free(name);
            list.deinit(gpa);
        }
    }

    // ─── Component registration helpers ──────────────────────────────────

    /// Register a component whose layout is described at runtime.
    /// Returns the assigned `ComponentId`. Forwarded straight to the
    /// underlying `Registry` — see `registry.zig`.
    pub fn registerComponentRaw(self: *World, gpa: std.mem.Allocator, desc: ComponentDesc) !ComponentId {
        return try self.registry.registerComponentRaw(gpa, desc);
    }

    /// Convenience wrapper for the comptime path. The descriptor is
    /// derived from `@typeInfo(T)`.
    pub fn registerComponent(self: *World, gpa: std.mem.Allocator, comptime T: type) !ComponentId {
        return try self.registry.registerComponent(gpa, T);
    }

    pub fn componentId(self: *const World, name: []const u8) ?ComponentId {
        return self.registry.idOf(name);
    }

    /// Public alias of the internal `ensureRegistered` path so the
    /// E5b `SystemScheduler` can resolve `Reads(T)` / `Writes(T)`
    /// access descriptors against the world's registry without
    /// reaching into a private symbol. Idempotent.
    pub fn ensureComponentRegistered(self: *World, gpa: std.mem.Allocator, comptime T: type) !ComponentId {
        return try self.ensureRegistered(gpa, T);
    }

    /// Ensure `T` is registered with the world's `Registry` and return
    /// its `ComponentId`. Idempotent — the second call returns the
    /// cached id without re-registering.
    ///
    /// Bypasses `Registry.registerComponent`'s `FieldKind`-driven path
    /// because the E2 typed spawn surface only needs size + alignment +
    /// default bytes — not the per-field descriptors that Etch consumes
    /// for byte-oriented field access. Components like `Transform` and
    /// `Velocity` carry array fields (`[3]f32`, `[4]f32`) which the
    /// `FieldKind` enum deliberately rejects until RTTI lands in M0.2.
    fn ensureRegistered(self: *World, gpa: std.mem.Allocator, comptime T: type) !ComponentId {
        if (self.registry.idOf(@typeName(T))) |id| return id;
        var default: T = .{};
        return try self.registry.registerComponentRaw(gpa, .{
            .name = @typeName(T),
            .size = @intCast(@sizeOf(T)),
            .alignment = @intCast(@alignOf(T)),
            .default_bytes = std.mem.asBytes(&default),
            .fields = &.{},
        });
    }

    // ─── Archetype lookup ────────────────────────────────────────────────

    /// A component-id set every member of which is `.table`-stored, sorted
    /// into an archetype signature.
    ///
    /// `splitByStorage` is its ONLY constructor, so an archetype signature
    /// cannot be built from a set nobody partitioned — the obligation is
    /// carried by the TYPE and not by a `std.debug.assert`, which ReleaseFast
    /// compiles to nothing. That distinction is not stylistic here: a sparse id
    /// reaching a signature would not crash, it would silently give the
    /// component a table column the sparse store also owns, after which the
    /// answer depends on which of the two a given caller consulted. A wrong
    /// answer with no diagnostic is the H1 class (cf. M1.1.15.1), and a guard
    /// live only in the two matrix cells where a breach costs nothing is not a
    /// guard on the path a game ships.
    ///
    /// Deliberately NOT an induction over `Archetype.component_ids`: it would
    /// hold today, and it would be a proof a future reader can break by adding
    /// one archetype constructor. Every site re-splits instead, which on the
    /// remove paths re-checks a set already known table-only — one registry
    /// lookup per id, against a migration that memcpys every column of every
    /// entity slot. Measured against the wrong quantity, that cost is invisible.
    const TableIds = struct {
        sorted: []const ComponentId,
    };

    /// The two halves of a caller-supplied component-id set.
    const StorageSplit = struct {
        /// Table ids, compacted to the front of the caller's buffer and sorted
        /// into signature order.
        table: TableIds,
        /// Sparse ids, in the buffer's tail. Order is the input's, minus the
        /// table ids removed from it — deterministic, not contractual.
        sparse: []const ComponentId,
    };

    /// Partition `buf` IN PLACE by storage mode: table ids first — then sorted,
    /// so the prefix is a signature — sparse ids after. One pass, no
    /// allocation, because every call site already owns a mutable id buffer.
    ///
    /// The partition is what ROUTES. It is not a validation step a path could
    /// skip on the grounds that its ids came from somewhere trustworthy: it is
    /// the only way to obtain the `TableIds` the archetype funnel demands, and
    /// the only place the sparse half is named.
    fn splitByStorage(self: *const World, buf: []ComponentId) StorageSplit {
        var n_table: usize = 0;
        for (0..buf.len) |i| {
            // `storageOf` and not `registry.componentStorage`: this is the
            // FIRST thing to touch a caller-supplied id, so an unregistered one
            // would index the registry out of range here rather than downstream
            // in `Archetype.init` as it always did. `storageOf` answers
            // `.table` past the registry's end, which sends the id into the
            // signature and lets `Archetype.init` fail exactly as before —
            // the precondition is pre-existing and this keeps it unmoved
            // instead of relocating its breach into the partition.
            if (self.storageOf(buf[i]) == .table) {
                std.mem.swap(ComponentId, &buf[n_table], &buf[i]);
                n_table += 1;
            }
        }
        archetype_mod.sortComponentIds(buf[0..n_table]);
        return .{
            .table = .{ .sorted = buf[0..n_table] },
            .sparse = buf[n_table..],
        };
    }

    /// Refuse a caller-supplied id slice that names the same component twice.
    ///
    /// **ACTIVE, not an assert**, because the breach is silent in the mode
    /// ReleaseFast compiles the assert out of: a repeated id makes
    /// `Archetype.init` build a duplicate column, after which `componentIndex`
    /// answers the FIRST and the second is written once and never read; on the
    /// sparse side it appends a second dense row.
    ///
    /// O(n²) deliberately — these slices hold a handful of ids and a set would
    /// allocate on a path whose whole point is not to.
    fn refuseDuplicateIds(ids: []const ComponentId) !void {
        for (ids, 0..) |c, i| {
            for (ids[i + 1 ..]) |other| {
                if (other == c) return error.DuplicateComponent;
            }
        }
    }

    /// Add `cid_new` together with its `@requires` closure, in one transaction.
    ///
    /// Members already carried are skipped — the closure is a floor and not a
    /// reset, so an entity that already has `Transform` keeps ITS `Transform`
    /// with its current values rather than having it overwritten by a default.
    /// Missing members get their REGISTRY DEFAULTS, which is what
    /// `etch-reference-part3.md` §6 specifies ("et l'ajoute avec ses defaults").
    /// Expand a caller-supplied component set with the transitive closure its
    /// members declare, into a NEW pair of lists. Returns whether anything was
    /// added.
    ///
    /// **ONE expansion semantics for all six add and spawn paths**, none of
    /// which delegates to a sibling — a second expansion written per site is how
    /// they would come to disagree.
    ///
    /// - **Idempotent**, because a caller legitimately passes `{Mesh, Transform}`
    ///   when `Mesh` requires `Transform`: appending unconditionally would make
    ///   `refuseDuplicateIds` reject a correct call, turning the duplicate rule
    ///   into a regression of this one.
    /// - **Payloads come from the registry**, the only source that asks the
    ///   caller for nothing.
    /// - **A NEW pair of arrays, never an expansion in place.** The positional
    ///   ids-to-payloads pairing is a coincidence the scene loader relies on —
    ///   it reuses one id array per block — so the `dupe` protects a
    ///   PERMUTATION, not a change of length.
    ///
    /// `entity` is null for a spawn, where nothing is present yet.
    fn expandRequires(
        self: *World,
        gpa: std.mem.Allocator,
        ids_in: []const ComponentId,
        vals_in: ?[]const []const u8,
        entity: ?EntityId,
        ids_out: *std.ArrayListUnmanaged(ComponentId),
        vals_out: *std.ArrayListUnmanaged([]const u8),
    ) !bool {
        for (ids_in, 0..) |cid, i| {
            try ids_out.append(gpa, cid);
            try vals_out.append(gpa, if (vals_in) |v| v[i] else self.registry.componentDefaultBytes(cid));
        }
        var expanded = false;
        for (ids_in) |cid| {
            for (self.registry.requiresClosure(cid)) |c| {
                if (std.mem.indexOfScalar(ComponentId, ids_out.items, c) != null) continue;
                if (entity) |e| if (self.hasComponentDyn(e, c)) continue;
                try ids_out.append(gpa, c);
                try vals_out.append(gpa, self.registry.componentDefaultBytes(c));
                expanded = true;
            }
        }
        return expanded;
    }

    fn addWithClosure(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cid_new: ComponentId,
        value_bytes: []const u8,
        closure: []const ComponentId,
    ) !void {
        var ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ids.deinit(gpa);
        var vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer vals.deinit(gpa);
        try ids.append(gpa, cid_new);
        try vals.append(gpa, value_bytes);
        for (closure) |c| {
            if (self.hasComponentDyn(entity, c)) continue;
            try ids.append(gpa, c);
            try vals.append(gpa, self.registry.componentDefaultBytes(c));
        }
        // One entry point whatever the closure contributed: when every requisite
        // is already present `ids` holds one id and the batched entry handles
        // that correctly. A branch on `ids.items.len == 1` was written here and
        // REMOVED — both arms called the same thing, so it was a branch that
        // could not change behaviour carrying a comment that implied it could.
        return self.addComponentsDynamic(gpa, entity, ids.items, vals.items);
    }

    /// Clear the per-tick observation counters.
    ///
    /// Called from BOTH frame boundaries — `beginFrame` and `tickBoundary` —
    /// because each is reached by a population the other is not: the scheduler
    /// and the codegen reach `beginFrame`, and a `changed`-free tree-walker
    /// program reaches only `tickBoundary`. Extracted rather than written twice,
    /// so the two sites cannot drift into resetting different sets.
    ///
    /// Both boundaries CAN fire in one tick, and that is harmless NOT because
    /// the second clear finds a zero — it erases whatever the tick counted. What
    /// makes it harmless is the READ WINDOW: the count means "since the last
    /// boundary" and is read during the tick, so by the time a boundary closes
    /// it the observation has been available for its whole window.
    fn resetTickObservations(self: *World) void {
        self.requires_removals_skipped = 0;
        self.first_requires_skip = null;
    }

    /// Whether removing `cid` from `entity` is refused because something the
    /// entity CARRIES still requires it, and record the refusal if so.
    ///
    /// `exempt` names the ids being dropped in the SAME command: a grouped
    /// removal of a requisite together with all its dependents is ALLOWED
    /// (`engine-ecs-internals.md` §3), so a requirer that is itself leaving
    /// does not hold its requisite back. Without that exception a legitimate
    /// teardown would be refused forever, which is the guard's other way of
    /// being wrong.
    /// Public since the M1.B reprise: the observer-dispatching apply must know
    /// whether a removal will be REFUSED before it fires `on_remove`, because
    /// an observer describes a state that has taken place. Reading it there and
    /// then NOT reaching `removeComponentDynamic` keeps the skip counted
    /// exactly once — the count lives in this function, so a pre-validation
    /// that also fell through would count twice.
    pub fn requiresRefusesRemoval(
        self: *World,
        entity: EntityId,
        cid: ComponentId,
        exempt: []const ComponentId,
    ) bool {
        var i: ComponentId = 0;
        const n: ComponentId = @intCast(self.registry.componentCount());
        while (i < n) : (i += 1) {
            if (i == cid) continue;
            var is_exempt = false;
            for (exempt) |x| if (x == i) {
                is_exempt = true;
                break;
            };
            if (is_exempt) continue;
            if (!self.registry.isRequiredBy(cid, i)) continue;
            if (!self.hasComponentDyn(entity, i)) continue;
            // ONE LINE PER TICK AT MOST — the first skip logs and names itself,
            // the counter carries the rest. Bounded on purpose: a scene with a
            // hundred offenders logs once, exactly as the `syncIn` precedent
            // logs per pass and never per body.
            if (self.requires_removals_skipped == 0) {
                std.log.warn(
                    "ecs/@requires: removal SKIPPED — component {d} is still required by {d} on this entity; " ++
                        "drop them in one command to remove both",
                    .{ cid, i },
                );
                self.first_requires_skip = cid;
            }
            self.requires_removals_skipped += 1;
            return true;
        }
        return false;
    }

    /// Which backend owns `cid`.
    ///
    /// **The REGISTRY is the authority, never the existence of a sparse store**:
    /// a component declared `.sparse` that nobody has spawned yet has no slot,
    /// and routing on slot existence would answer "absent" correctly by
    /// accident.
    ///
    /// **An out-of-range id is NOT a programmer error here.** `componentBytes`
    /// and its siblings take a caller-supplied `ComponentId` and answer `null`
    /// for an unknown one; indexing the registry unguarded would turn that call
    /// into an out-of-bounds read, and `.table` is what reproduces the old
    /// answer — the archetype lookup then returns `null` as it always did.
    ///
    /// Public so the Etch bridge picks its `ComponentRef` arm from the SAME
    /// authority the routing uses.
    pub fn storageOf(self: *const World, cid: ComponentId) registry_mod.StorageKind {
        if (cid >= self.registry.componentCount()) return .table;
        return self.registry.componentStorage(cid);
    }

    /// Declare a storage for every id in `ids`, which the caller has already
    /// established sparse (they come from `StorageSplit.sparse`). Idempotent
    /// per id.
    ///
    /// The loop lives on `World` and not on `SparseStores` because it needs the
    /// registry for each id's size and alignment, and giving the backend a
    /// registry dependency would undo G2's decoupling for the sake of one loop.
    fn ensureSparseStores(self: *World, gpa: std.mem.Allocator, ids: []const ComponentId) !void {
        for (ids) |cid| {
            _ = try self.sparse_stores.ensure(
                gpa,
                cid,
                self.registry.componentSize(cid),
                self.registry.componentAlignment(cid),
            );
        }
    }

    /// Write `entity`'s payload into each sparse store of `ids`.
    ///
    /// `SparseSetStorage.add` is itself reserve-then-mutate, so ONE failing add
    /// leaves ITS store untouched — but a failure on the third id would leave
    /// the first two committed, and a half-populated entity is exactly the
    /// observable mutation the invariant forbids. So the unwind is World-level:
    /// `errdefer` removes from every store already written, in reverse, which
    /// is the LIFO order M1.1.1-HF1/D2 established after a forward undo was
    /// measured to corrupt a refcount on duplicate entries.
    ///
    /// `payloads` + `id_order` carry the caller's ORIGINAL pairing, which the
    /// resolution below scans by id: `splitByStorage` permuted the buffer, so
    /// positional pairing is gone by the time control reaches here.
    /// `spawnDynamic` passes null/null and gets registry defaults.
    fn addSparsePayloads(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        ids: []const ComponentId,
        payloads: ?[]const []const u8,
        id_order: ?[]const ComponentId,
    ) !void {
        var written: usize = 0;
        errdefer self.removeSparsePayloads(entity, ids[0..written]);
        for (ids) |cid| {
            const store = self.sparse_stores.get(cid).?;
            // A DUPLICATE id in the caller's set would land here twice, and
            // `SparseSetStorage.add`'s `assert(!contains)` is compiled to nothing
            // in ReleaseFast — so the second call would append a SECOND dense
            // row for this entity, after which `positionOf` answers the first,
            // `remove` swaps one away and the other is unreachable for the
            // world's lifetime (a leak that survives `despawn`, since
            // `removeEntity` drops one row per store). Loud instead.
            //
            // The TABLE side has the same precondition and the same hole — a
            // duplicate id makes `Archetype.init` build a signature with a
            // repeated column — but that PREDATES M1.B, so it is reported
            // rather than silently changed here.
            if (store.contains(entity)) return error.DuplicateComponent;
            const bytes = blk: {
                if (payloads) |ps| {
                    // Resolve this id to its payload through the caller's
                    // ORIGINAL id order: `splitByStorage` permuted the scratch
                    // buffer, so positional pairing is gone by here.
                    const order = id_order.?;
                    for (order, 0..) |req, k| {
                        if (req == cid) break :blk ps[k];
                    }
                    // Proven, not assumed. `ids` is `split.sparse`, whose every
                    // member `splitByStorage` CHECKED against the registry, and
                    // on the batched-add path the buffer it split is
                    // `src.component_ids ++ cids` — so a member could come from
                    // the archetype rather than from `order` only if a
                    // component's mode changed after its archetype was built.
                    // It cannot: `registerComponentRaw` refuses an existing
                    // name with `DuplicateComponent`, and every one of the six
                    // accesses to `entries.items[id].desc` in `registry.zig` is
                    // a READ — there is no write path to an existing
                    // descriptor anywhere in the tree. One grep re-checks that.
                    unreachable;
                }
                break :blk self.registry.componentDefaultBytes(cid);
            };
            try store.add(gpa, entity, bytes, self.current_tick);
            written += 1;
        }
    }

    /// Remove `entity` from each sparse store of `ids`, in reverse.
    ///
    /// Infallible by construction: `SparseSetStorage.remove` is a swap-remove
    /// over already-allocated arrays. That is what makes it usable as an
    /// `errdefer`, and it is why the spawn paths write the SPARSE side FIRST
    /// and the table slot LAST — undoing a table slot means `removeSwap` plus
    /// repairing the swapped-in entity's location, and the step whose undo is
    /// messier is the step that should have nothing after it to undo.
    fn removeSparsePayloads(self: *World, entity: EntityId, ids: []const ComponentId) void {
        var k = ids.len;
        while (k > 0) {
            k -= 1;
            // The store exists (`ensureSparseStores` ran first) and the entity
            // was added to it, so `remove` finds it.
            _ = self.sparse_stores.get(ids[k]).?.remove(entity);
        }
    }

    /// Find an archetype by its sorted `ComponentId` signature. Returns
    /// `null` when no archetype with that exact signature exists yet.
    fn findArchetype(self: *World, sorted_ids: []const ComponentId) ?*Archetype {
        const key = archetype_mod.signatureBytes(sorted_ids);
        if (self.archetype_by_signature.get(key)) |idx| {
            return self.archetypes.items[idx];
        }
        return null;
    }

    /// Find or create the archetype for the given sorted `ComponentId`
    /// signature. Stable pointer for the world's lifetime.
    fn getOrCreateArchetype(self: *World, gpa: std.mem.Allocator, key_ids: TableIds) !*Archetype {
        const sorted_ids = key_ids.sorted;
        if (self.findArchetype(sorted_ids)) |existing| return existing;

        const arch_id: ArchetypeId = @intCast(self.archetypes.items.len);
        const a = try gpa.create(Archetype);
        errdefer gpa.destroy(a);
        a.* = try Archetype.init(gpa, &self.registry, arch_id, sorted_ids);
        errdefer a.deinit(gpa);
        try self.archetypes.append(gpa, a);
        errdefer _ = self.archetypes.pop();

        // Key bytes alias the archetype's owned `component_ids` slice —
        // valid for the archetype's lifetime, which equals the world's.
        const key = archetype_mod.signatureBytes(a.component_ids);
        try self.archetype_by_signature.put(gpa, key, arch_id);

        return a;
    }

    pub fn archetypeCount(self: *const World) usize {
        return self.archetypes.items.len;
    }

    /// The archetype at `idx`. TABLE BACKEND ONLY, by nature and not by
    /// omission: an archetype is the table storage, so there is no bimodal
    /// version of this entry to write.
    ///
    /// Since M1.B it is therefore a BOUNDED primitive. Paired with
    /// `dynamicLocation` it is the two-call idiom through which a caller
    /// reaches a component's bytes itself — `componentIndex` then
    /// `componentSlot` — and for a sparse component `componentIndex` answers
    /// null, after which the caller's own `orelse` decides what happens and
    /// each caller may decide differently. `World.componentBytes` is the entry
    /// that answers for both backends; reach for this one only when the
    /// archetype itself is the subject (its signature, its chunks, its
    /// `is_singleton` flag), never as a way to read a component.
    pub fn dynamicArchetype(self: *World, idx: ArchetypeId) *Archetype {
        return self.archetypes.items[idx];
    }

    /// Where `entity` lives in the TABLE storage — archetype, chunk, slot — or
    /// null for a stale handle.
    ///
    /// Total and correct for every live entity, sparse-only ones included:
    /// since M1.B an entity carrying no table component lives in the EMPTY
    /// archetype rather than nowhere, so this never returns null for a live
    /// handle. What it does not carry is any sparse-side information — see
    /// `dynamicArchetype` for the bound the pair shares.
    pub fn dynamicLocation(self: *const World, id: EntityId) ?Location {
        return self.entity_locations.get(id);
    }

    // ─── Spawn / despawn ─────────────────────────────────────────────────

    /// Spawn an entity with the S1 `(Transform, Velocity)` archetype.
    /// Generational id drawn from the identity store; archetype found
    /// or created on first call.
    pub fn spawn(
        self: *World,
        gpa: std.mem.Allocator,
        transform: Transform,
        velocity: Velocity,
    ) !EntityId {
        const id_t = try self.ensureRegistered(gpa, Transform);
        const id_v = try self.ensureRegistered(gpa, Velocity);
        var ids = [_]ComponentId{ id_t, id_v };

        // M1.B reprise / P1-1 — this entry writes ONLY the two columns it names
        // and takes `allocateSlot`, which does not default-initialise, so a
        // component the closure contributed would land here with undefined
        // bytes. Rather than rewrite a hot path that is otherwise correct, an
        // expanded set DELEGATES to the general entry, which writes every
        // column it was given. The branch is measured, not stylistic: a typed
        // component registers with no `requires` of its own, so the closure is
        // empty unless an Etch declaration claimed the same name through
        // `registerAlias` — rare, and exactly the case that must not silently
        // skip the rule.
        if (self.registry.requiresClosure(id_t).len != 0 or
            self.registry.requiresClosure(id_v).len != 0)
        {
            const vals = [_][]const u8{ std.mem.asBytes(&transform), std.mem.asBytes(&velocity) };
            return self.spawnDynamicWithValues(gpa, ids[0..], vals[0..]);
        }
        // `Transform` and `Velocity` are core components and table-stored, but
        // the split runs anyway: the funnel takes no other input, and a path
        // exempted because its ids look trustworthy is the path that breaks
        // the day one of them is registered differently.
        const split = self.splitByStorage(ids[0..]);
        // Without this, `addSparsePayloads` below unwraps `sparse_stores.get(cid).?`
        // on a store that was never declared and PANICS. The comment above says
        // the split exists for "the day one of them is registered differently";
        // that day it panicked, which is what makes this line the point rather
        // than the comment.
        try self.ensureSparseStores(gpa, split.sparse);
        const arch = try self.getOrCreateArchetype(gpa, split.table);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(eid);

        try self.addSparsePayloads(gpa, eid, split.sparse, null, null);
        errdefer self.removeSparsePayloads(eid, split.sparse);

        const r = try arch.allocateSlot(gpa, self.current_tick);
        const chunk = arch.chunks.items[r.chunk_idx];

        // Write the components in the archetype's sorted-id order. We
        // match against the comptime ids resolved above so the choice
        // does not depend on which type registered first.
        for (arch.component_ids, 0..) |cid, i| {
            const dst = arch.componentSlot(chunk, i, r.slot);
            if (cid == id_t) {
                @memcpy(dst, std.mem.asBytes(&transform));
            } else if (cid == id_v) {
                @memcpy(dst, std.mem.asBytes(&velocity));
            } else unreachable; // archetype was created from {id_t, id_v}
        }
        arch.entityIds(chunk)[r.slot] = eid;

        self.entity_locations.putAssumeCapacity(eid, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return eid;
    }

    /// Spawn an entity in the dynamic side of the world. The slot is
    /// initialised from the registry's default bytes for every
    /// component of the archetype. Identity and location go through the
    /// same shared paths as the typed `spawn` above.
    pub fn spawnDynamic(self: *World, gpa: std.mem.Allocator, component_ids: []const ComponentId) !EntityId {
        try refuseDuplicateIds(component_ids);
        // M1.B reprise / P1-1 — the closure is expanded HERE, on the caller's
        // set, before anything is resolved from it.
        var ex_ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ex_ids.deinit(gpa);
        var ex_vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ex_vals.deinit(gpa);
        _ = try self.expandRequires(gpa, component_ids, null, null, &ex_ids, &ex_vals);
        const ids_all = ex_ids.items;
        // Caller's ids may be unsorted, and may mix the two storage modes.
        // `splitByStorage` sorts the table half into signature order and names
        // the sparse half in one pass over the dup.
        const scratch = try gpa.dupe(ComponentId, ids_all);
        defer gpa.free(scratch);
        const split = self.splitByStorage(scratch);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        try self.ensureSparseStores(gpa, split.sparse);
        const arch = try self.getOrCreateArchetype(gpa, split.table);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(eid);

        try self.addSparsePayloads(gpa, eid, split.sparse, null, null);
        errdefer self.removeSparsePayloads(eid, split.sparse);

        const r = try arch.spawnDefault(gpa, eid, self.current_tick);
        self.entity_locations.putAssumeCapacity(eid, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return eid;
    }

    /// M0.1 / E6 — dynamic spawn with payload bytes per component.
    /// Variant of `spawnDynamic` used by the command-buffer flush path
    /// so deferred spawn commands can carry the caller-provided values
    /// instead of falling back to the registry's default bytes.
    /// `payloads[i]` must match the size of the component whose id is
    /// `component_ids[i]`; the caller is responsible for that pairing.
    pub fn spawnDynamicWithValues(
        self: *World,
        gpa: std.mem.Allocator,
        component_ids: []const ComponentId,
        payloads: []const []const u8,
    ) !EntityId {
        std.debug.assert(component_ids.len == payloads.len);
        try refuseDuplicateIds(component_ids);

        // M1.B reprise / P1-1 — the closure is expanded on the caller's set,
        // into a NEW pair of lists, before anything is resolved from either.
        var ex_ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ex_ids.deinit(gpa);
        var ex_vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ex_vals.deinit(gpa);
        _ = try self.expandRequires(gpa, component_ids, payloads, null, &ex_ids, &ex_vals);
        const ids_all = ex_ids.items;
        const vals_all = ex_vals.items;

        // `splitByStorage` permutes the scratch buffer, so the original
        // (id, payload) pairing survives only in the caller's `component_ids` —
        // which both the column loop below and `addSparsePayloads` resolve
        // against by ComponentId rather than by position.
        const scratch = try gpa.dupe(ComponentId, ids_all);
        defer gpa.free(scratch);
        const split = self.splitByStorage(scratch);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        try self.ensureSparseStores(gpa, split.sparse);
        const arch = try self.getOrCreateArchetype(gpa, split.table);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(eid);

        try self.addSparsePayloads(gpa, eid, split.sparse, vals_all, ids_all);
        errdefer self.removeSparsePayloads(eid, split.sparse);

        const r = try arch.allocateSlot(gpa, self.current_tick);
        const chunk = arch.chunks.items[r.chunk_idx];

        // For each archetype column, find the matching payload by
        // ComponentId (linear scan — `component_ids.len` is small).
        for (arch.component_ids, 0..) |arch_cid, col| {
            var found: ?usize = null;
            for (ids_all, 0..) |req_cid, k| {
                if (req_cid == arch_cid) {
                    found = k;
                    break;
                }
            }
            const dst = arch.componentSlot(chunk, col, r.slot);
            if (found) |k| {
                @memcpy(dst, vals_all[k]);
            } else {
                // Unreachable: `split.table` is a subset of `component_ids`,
                // so every archetype column has a payload. The ids that are
                // NOT columns are the sparse half, written above.
                unreachable;
            }
        }
        arch.entityIds(chunk)[r.slot] = eid;

        self.entity_locations.putAssumeCapacity(eid, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return eid;
    }

    /// Despawn an entity by handle. Returns `error.StaleEntityHandle`
    /// when the handle's index is unknown, the slot is already freed,
    /// or the generation does not match. Updates the swapped-in
    /// entity's location atomically with the chunk-level swap. Purges the
    /// entity's active-extension set (M1.1.1-HF1 D7) so its owned name copies
    /// are freed here rather than stranded until `World.deinit`.
    pub fn despawn(self: *World, gpa: std.mem.Allocator, id: EntityId) WorldError!void {
        try self.identity.validate(id);
        const location = self.entity_locations.get(id) orelse return error.StaleEntityHandle;

        const arch = self.archetypes.items[location.archetype_idx];
        if (arch.removeSwap(location.chunk_idx, location.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = location;
        }
        _ = self.entity_locations.remove(id);
        // Sweep every sparse store. Placed before `identity.release` for
        // reading order and NOT as a correctness condition — a first version of
        // this comment claimed otherwise and was refuted by its own
        // counter-factual: moving the sweep after the release leaves the whole
        // suite green. The reason is that `positionOf` compares the generation
        // against the STORE's own copy of the handle (`dense.items[pos]`) and
        // never consults the identity store, so releasing the index cannot
        // change what `removeEntity(id)` finds. An order dependency would need
        // a sweep keyed on something the identity store owns, and there is
        // none.
        _ = self.sparse_stores.removeEntity(id);
        self.purgeEntityExtensions(gpa, id);
        self.identity.release(id);
    }

    /// Whether `entity` carries `cid`, whichever backend stores it.
    ///
    /// Total and infallible — `false` for a stale handle, an unknown id or an
    /// absent component, indistinguishably, which is the shape
    /// `WeldEcsAPI.component_has` is frozen at (`ARCH-018`).
    ///
    /// **Not a convenience over `componentBytes() != null`.** The batched paths
    /// ask presence to raise `DuplicateComponent`/`UnknownComponent`, and they
    /// asked it of the ARCHETYPE — which answers `false` for a sparse component
    /// the entity carries, so a batched add of an already-present sparse
    /// component passed the check and reached `SparseSetStorage.add`'s own
    /// assert: live in Debug, compiled to nothing in ReleaseFast, a silent
    /// double insert in the mode a game ships.
    /// `entity`'s `changed_tick` for `cid`, whichever backend holds it, or null
    /// when the entity is stale or does not carry the component.
    ///
    /// **Use this and not the `dynamicLocation` + `dynamicArchetype` +
    /// `changedTick` idiom**, which answers for the TABLE half only: a sparse
    /// component reads as "never changed", a wrong answer with no diagnostic.
    ///
    /// No `addedTickOf` twin — nothing consumes one outside the query paths,
    /// which reach the archetype directly. An accessor with no caller is an
    /// unexercised entry, not symmetry.
    pub fn changedTickOf(self: *const World, entity: EntityId, cid: ComponentId) ?tick_mod.Tick {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.getConst(cid) orelse return null;
            return store.changedTick(entity);
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        return arch.changedTick(chunk, col, loc.slot);
    }

    pub fn hasComponentDyn(self: *const World, entity: EntityId, cid: ComponentId) bool {
        if (!self.identity.isLive(entity)) return false;
        const loc = self.entity_locations.get(entity) orelse return false;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.getConst(cid) orelse return false;
            return store.contains(entity);
        }
        return self.archetypes.items[loc.archetype_idx].hasComponent(cid);
    }

    pub fn entityCount(self: *const World) usize {
        return self.entity_locations.count();
    }

    /// `true` if `id` refers to a live entity in this world. Returns
    /// `false` for stale handles instead of erroring.
    pub fn isLive(self: *const World, id: EntityId) bool {
        return self.identity.isLive(id);
    }

    // ─── M0.1 / E4 — frame tick + typed component access ────────────────

    /// Open a new frame. Bumps `current_tick` (wrapping arithmetic — a
    /// follow-up milestone handles the u32 wraparound per the brief)
    /// and clears every chunk's dirty bitset so `Changed<T>` queries
    /// only see this frame's modifications.
    pub fn beginFrame(self: *World) void {
        self.current_tick +%= 1;
        for (self.archetypes.items) |arch| arch.clearAllDirtyBitsets();
        self.resetTickObservations();
        // No sparse arm, and the absence is an INVARIANT rather than an
        // omission: a sparse store carries per-row `added`/`changed` ticks and
        // NO dirty bitset (M1.B/G2 invariant 2), because the bitset exists to
        // let a chunk-granular query skip a whole chunk — a granularity a
        // sparse set does not have. An arm here would have nothing to clear.
        // The guard for it is `SparseSetStorage.field_set_pin`, which lives
        // where a field gets added rather than here where one is read: adding a
        // bitset to the backend breaks that pin, and its message names this
        // function.
    }

    /// Read-only typed access to component `T` on `entity`. Returns
    /// `null` when the entity is stale or its archetype does not
    /// hold `T`. Does **not** mark the slot as changed.
    pub fn get(self: *const World, comptime T: type, entity: EntityId) ?*const T {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        const cid = self.registry.idOf(@typeName(T)) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.getConst(cid) orelse return null;
            const bytes = store.get(entity) orelse return null;
            return @ptrCast(@alignCast(bytes.ptr));
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col_idx = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        const bytes = arch.componentSlot(chunk, col_idx, loc.slot);
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Mutable typed access to component `T` on `entity`. **Auto-marks**
    /// `changed_tick[T][slot] = current_tick` and sets the slot's dirty
    /// bit before returning the pointer — every write through this
    /// pointer is observable by a `Changed<T>` query whose
    /// `last_run_tick < current_tick`. Returns `null` for stale handles
    /// or missing components.
    pub fn getMut(self: *World, comptime T: type, entity: EntityId) ?*T {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        const cid = self.registry.idOf(@typeName(T)) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.get(cid) orelse return null;
            // `getMut` stamps `changed_tick` in the sparse store exactly as the
            // table arm stamps it in the chunk sidecar — the auto-mark is the
            // entry's contract, not a table implementation detail.
            const bytes = store.getMut(entity, self.current_tick) orelse return null;
            return @ptrCast(@alignCast(bytes.ptr));
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col_idx = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        arch.markChanged(chunk, col_idx, loc.slot, self.current_tick);
        const bytes = arch.componentSlot(chunk, col_idx, loc.slot);
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Dynamic (by `ComponentId`) read of `entity`'s component bytes — the
    /// runtime analogue of `get`, used by the observer dispatch (M1.0.2 E3).
    /// Returns the live storage slice (`componentSize(cid)` long), or `null`
    /// when the entity is stale or its archetype lacks `cid`. Does not mark
    /// the slot changed.
    pub fn componentBytes(self: *World, entity: EntityId, cid: ComponentId) ?[]u8 {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.get(cid) orelse return null;
            // Deliberately NOT `getMut`: this entry is the byte-level READ
            // surface — `observers.zig` reads through it to build its
            // `old_ptr`/`new_ptr` payloads — and stamping a change here would
            // make an observer dispatch look like a mutation. The table arm
            // does not stamp either; `markComponentChangedDyn` is the entry
            // whose job that is.
            return store.bytesMut(entity) orelse return null;
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        return arch.componentSlot(chunk, col, loc.slot);
    }

    /// Stamp `entity`'s `cid` slot as changed at `current_tick` (M1.0.2 E3) —
    /// used after an in-place replace overwrite so a `Changed<T>` query sees it,
    /// mirroring `getMut`'s auto-mark. No-op when the entity/component is absent.
    pub fn markComponentChangedDyn(self: *World, entity: EntityId, cid: ComponentId) void {
        const loc = self.entity_locations.get(entity) orelse return;
        if (self.storageOf(cid) == .sparse) {
            // Without this arm the mark would be SILENTLY LOST: the entry
            // returns `void`, and `componentIndex` on a sparse id answers null,
            // so the pre-M1.B body's `orelse return` would swallow it. A change
            // that never propagates has no diagnostic anywhere — the same class
            // of defect as answering the wrong entity, and the reason this entry
            // is routed rather than left to fail loud (it cannot fail at all).
            if (self.sparse_stores.get(cid)) |store| {
                store.markChanged(entity, self.current_tick);
            }
            return;
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col = arch.componentIndex(cid) orelse return;
        const chunk = arch.chunks.items[loc.chunk_idx];
        arch.markChanged(chunk, col, loc.slot, self.current_tick);
    }

    // ─── Add / remove component (M0.1 / E2 — transition cache) ──────────

    /// Insert component `T` on `entity`. Routes through the current
    /// archetype's `TransitionCache`: the first add of `T` from this
    /// archetype performs the signature lookup and caches the target
    /// archetype id; subsequent adds hit the cache. Existing
    /// components are byte-copied into the target archetype's slot;
    /// the source slot is freed via swap-and-pop and the trailing
    /// entity's location is updated atomically.
    ///
    /// `error.StaleEntityHandle` is returned when the handle does not
    /// match the identity store. Adding a component the entity already
    /// has is a programmer error and panics in debug.
    pub fn addComponent(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        comptime T: type,
        value: T,
    ) !void {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        const cid_new = try self.ensureRegistered(gpa, T);

        // M1.B reprise / P1-1 — the fifth and last add path. It handles ONE
        // component and branches on its storage; an expanded set needs the
        // grouped machinery, which `addComponentDynamic` already reaches
        // through the single expansion point. Same shape as `spawn`: the guard
        // stays even though a typed component registers with no `requires` of
        // its own, because what is kept is the PROPERTY and not today's
        // instance — an Etch declaration can claim the same name through
        // `registerAlias`, and that is exactly the case that must not skip the
        // rule in silence.
        if (self.registry.requiresClosure(cid_new).len != 0) {
            return self.addComponentDynamic(gpa, entity, cid_new, std.mem.asBytes(&value));
        }

        if (self.storageOf(cid_new) == .sparse) {
            // NO archetype transition at all: a sparse component's presence is
            // a row in its own store, so the entity's signature — and with it
            // its location, its chunk, and every other component's address —
            // is untouched. That ABSENCE of migration is the mode's whole
            // reason to exist, not an optimisation on top of it.
            const store = try self.sparse_stores.ensure(
                gpa,
                cid_new,
                self.registry.componentSize(cid_new),
                self.registry.componentAlignment(cid_new),
            );
            // ACTIVE check, not an assert. `SparseSetStorage.add` asserts
            // `!contains(entity)`, and `std.debug.assert` is compiled to NOTHING
            // in ReleaseFast — so in the mode a game ships, a double add would
            // append a SECOND dense row for the same entity, after which
            // `positionOf` answers the first and `remove` swaps one of the two
            // away, leaving the other permanently unreachable. A wrong answer
            // with no diagnostic (the H1 class, M1.1.15.1). `DuplicateComponent`
            // is the error `addComponentsDynamic` already returns for exactly
            // this condition, so nothing new is invented.
            //
            // Deliberately in the SPARSE arm only: the table arm's own
            // `assert(!src_arch.hasComponent(cid_new))` is stripped identically
            // and has the same hole, but that hole PREDATES M1.B and changing it
            // would change an existing contract. Reported, not silently fixed.
            if (store.contains(entity)) return error.DuplicateComponent;
            try store.add(gpa, entity, std.mem.asBytes(&value), self.current_tick);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        // ACTIVE, mirroring the sparse arm above and for the same reason: the
        // `std.debug.assert` this replaces was compiled to nothing in
        // ReleaseFast, so the migration proceeded and built a signature with
        // `cid_new` TWICE. Restores a precondition already written rather than
        // inventing one, and `DuplicateComponent` is the error the batched path
        // already returns for this condition.
        //
        // `applyWithObservers` is unaffected: it tests presence FIRST and only
        // reaches here on the absent branch, where add-on-present is a
        // replacement rather than an error.
        if (src_arch.hasComponent(cid_new)) return error.DuplicateComponent;

        // Resolve the target archetype — cache hit first, full lookup +
        // create if cold.
        const dst_arch = blk: {
            if (src_arch.transitions.add.get(cid_new)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            // Build the target signature: src.component_ids ∪ {cid_new}.
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len + 1);
            defer gpa.free(target_ids);
            @memcpy(target_ids[0..src_arch.component_ids.len], src_arch.component_ids);
            target_ids[src_arch.component_ids.len] = cid_new;
            const split = self.splitByStorage(target_ids);

            const target = try self.getOrCreateArchetype(gpa, split.table);
            // Cache the transition on the source archetype. Re-resolve
            // the source pointer in case `getOrCreateArchetype` grew
            // the archetypes ArrayList — the existing `src_arch`
            // pointer is stable because archetypes hold `*Archetype`
            // (not `Archetype` by value), but be explicit.
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.add.put(gpa, cid_new, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        // Allocate a slot in the destination archetype — the
        // `allocateSlot` call stamps `added_tick` + `changed_tick`
        // sidecars for **every** destination column at
        // `self.current_tick`. We then overwrite the surviving columns'
        // `added_tick` to preserve the original attachment tick so the
        // semantic "added_tick = when this component was first attached
        // to this entity" survives migration.
        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        // Copy each destination component column from either the source
        // archetype (if the component exists there) or the caller's
        // freshly-provided value. Surviving columns also carry their
        // pre-migration `added_tick` / `changed_tick`; the new column
        // keeps the `current_tick` value `allocateSlot` already stamped.
        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            if (dst_cid == cid_new) {
                @memcpy(dst, std.mem.asBytes(&value));
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);

                // Preserve the source's `added_tick` and
                // `changed_tick` for this column.
                const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
                const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
                dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
                dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
            }
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        // Swap-and-pop from the source archetype, then patch the
        // location maps.
        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// M0.1 / E6 — dynamic addComponent used by the command-buffer
    /// flush path. Same migration logic as `addComponent` but the
    /// component's identity is given directly (already resolved at
    /// record time) and the new column's bytes come from the caller's
    /// payload slice.
    pub fn addComponentDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cid_new: ComponentId,
        value_bytes: []const u8,
    ) !void {
        // M1.B/G9 — `@requires`: the closure is added with the component, in ONE
        // transaction. Delegated to `addComponentsDynamic` rather than
        // reimplemented, because that entry ALREADY is the transaction — all
        // fallible work before the first observable mutation — and a second
        // implementation of the same atomicity is a second thing to keep true.
        //
        // The closure is read, never walked: `requiresClosure` returns the
        // flattened array `finalizeRequires` computed once, which is what
        // `engine-ecs-internals.md` §3 means by "jamais reparcouru à chaque
        // ajout".
        const closure = self.registry.requiresClosure(cid_new);
        if (closure.len != 0) return self.addWithClosure(gpa, entity, cid_new, value_bytes, closure);
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        if (self.storageOf(cid_new) == .sparse) {
            // NO archetype transition at all: a sparse component's presence is
            // a row in its own store, so the entity's signature — and with it
            // its location, its chunk, and every other component's address —
            // is untouched. That ABSENCE of migration is the mode's whole
            // reason to exist, not an optimisation on top of it.
            const store = try self.sparse_stores.ensure(
                gpa,
                cid_new,
                self.registry.componentSize(cid_new),
                self.registry.componentAlignment(cid_new),
            );
            // ACTIVE check — see the twin in `addComponent` for why an assert
            // will not do here and why the table arm is deliberately left alone.
            if (store.contains(entity)) return error.DuplicateComponent;
            try store.add(gpa, entity, value_bytes, self.current_tick);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        // ACTIVE, mirroring the sparse arm above and for the same reason: the
        // `std.debug.assert` this replaces was compiled to nothing in
        // ReleaseFast, so the migration proceeded and built a signature with
        // `cid_new` TWICE. Restores a precondition already written rather than
        // inventing one, and `DuplicateComponent` is the error the batched path
        // already returns for this condition.
        //
        // `applyWithObservers` is unaffected: it tests presence FIRST and only
        // reaches here on the absent branch, where add-on-present is a
        // replacement rather than an error.
        if (src_arch.hasComponent(cid_new)) return error.DuplicateComponent;

        const dst_arch = blk: {
            if (src_arch.transitions.add.get(cid_new)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len + 1);
            defer gpa.free(target_ids);
            @memcpy(target_ids[0..src_arch.component_ids.len], src_arch.component_ids);
            target_ids[src_arch.component_ids.len] = cid_new;
            const split = self.splitByStorage(target_ids);

            const target = try self.getOrCreateArchetype(gpa, split.table);
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.add.put(gpa, cid_new, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            if (dst_cid == cid_new) {
                @memcpy(dst, value_bytes);
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);

                const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
                const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
                dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
                dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
            }
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// M0.1 / E6 — dynamic removeComponent used by the command-buffer
    /// flush path. Same migration logic as `removeComponent` but the
    /// component identity is given as a `ComponentId` (already resolved
    /// at record time).
    pub fn removeComponentDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cid_drop: ComponentId,
    ) !void {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        // M1.B/G9 — a removal refused by `@requires` is SKIPPED, not an error:
        // the invariant "if A is present, its closure is present" holds, the
        // deviation is counted on `World` and logged once per tick, and the
        // tick survives. An error here would be the channel
        // `engine-ecs-internals.md` §3 and this milestone's brief both refuse —
        // a deferred command turned into an unobservable tick failure.
        if (self.requiresRefusesRemoval(entity, cid_drop, &.{})) return;

        if (self.storageOf(cid_drop) == .sparse) {
            // Mirrors the table arm's `assert(hasComponent)` below: removing an
            // absent component is a programmer error on this entry. UNLIKE that
            // arm, the release path is a no-op rather than undefined — the
            // assert is compiled to nothing in ReleaseFast, and a `.?` sitting
            // behind it would then be UB on the exact misuse the assert exists
            // to name. Matching the table arm bit for bit would be matching a
            // defect, so the absence is handled rather than assumed.
            std.debug.assert(self.hasComponentDyn(entity, cid_drop));
            const store = self.sparse_stores.get(cid_drop) orelse return;
            _ = store.remove(entity);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(src_arch.hasComponent(cid_drop));

        const dst_arch = blk: {
            if (src_arch.transitions.remove.get(cid_drop)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            // `>= 1` and not `>= 2`: since M1.B the EMPTY archetype is legal, so
            // dropping an entity's last component is a transition to it rather
            // than a programmer error. The `>= 2` this replaces was a leftover
            // of the illegality G2 lifted — legal at the layout, still forbidden
            // at the transition. Guaranteed by the `hasComponent(cid_drop)`
            // check above, which is what makes the bound `1` and not `0`.
            std.debug.assert(src_arch.component_ids.len >= 1);
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len - 1);
            defer gpa.free(target_ids);
            var di: usize = 0;
            for (src_arch.component_ids) |cid| {
                if (cid == cid_drop) continue;
                target_ids[di] = cid;
                di += 1;
            }

            const split = self.splitByStorage(target_ids);
            const target = try self.getOrCreateArchetype(gpa, split.table);
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.remove.put(gpa, cid_drop, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);

            const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
            const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
            dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
            dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// R6 (M1.1.1-HF3) — add SEVERAL components to `entity` in a SINGLE archetype
    /// migration. Either the whole set lands (the entity moves once to the target
    /// archetype with every new column written) or nothing changes: the only
    /// fallible steps — target-archetype creation, `entity_locations` reservation,
    /// and the destination slot allocation — all run BEFORE the first observable
    /// mutation (the source `removeSwap` + location update), and the value writes
    /// are infallible `memcpy`. This replaces N sequential `addComponentDynamic`
    /// calls, whose mid-loop failure left the entity partially extended — the
    /// extension-activation atomicity defect.
    ///
    /// `cids[i]` pairs with `values[i]` (`values[i].len == componentSize(cids[i])`,
    /// a programmer contract — asserted). `cids` length 0 is a no-op. R11(c)
    /// (M1.1.1-HF3): every `cids[i]` must be ABSENT from `entity`'s current
    /// archetype AND DISTINCT within `cids` — a real check (`error.DuplicateComponent`),
    /// not an assert; a duplicate would put the id twice in the target archetype
    /// (corruption) and mis-map values.
    /// Add a set of components, expanding every `@requires` closure first.
    ///
    /// The expansion happens ONCE, here, and `addComponentsExact` below is the
    /// terminal that assumes an already-closed set — which is what keeps the
    /// recursion finite and gives the rule a single semantics for all six add
    /// and spawn paths.
    pub fn addComponentsDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cids: []const ComponentId,
        values: []const []const u8,
    ) !void {
        std.debug.assert(cids.len == values.len); // programmer contract, not file-reachable
        if (cids.len == 0) return;
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        // M1.B reprise / P1-1 — THE grouped expansion point. Every other add
        // path routes here rather than expanding for itself, so there is one
        // semantics and not six. The helper is entity-aware, so a requisite the
        // entity already carries is skipped and the present-check below never
        // sees one.
        var ex_ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ex_ids.deinit(gpa);
        var ex_vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ex_vals.deinit(gpa);
        //
        // Allocation-free when nothing requires anything, which is the common
        // case and the one the hot path must keep: the closure lookup is a
        // slice length per id, and only a non-empty one reaches the copy.
        var needs = false;
        for (cids) |c| {
            if (self.registry.requiresClosure(c).len != 0) {
                needs = true;
                break;
            }
        }
        if (needs) _ = try self.expandRequires(gpa, cids, values, entity, &ex_ids, &ex_vals);
        const ids_all = if (needs) ex_ids.items else cids;
        const vals_all = if (needs) ex_vals.items else values;
        {
            // R11(c): real duplicate/present checks BEFORE any allocation.
            //
            // Routed through `hasComponentDyn` and NOT `src_arch.hasComponent`:
            // the archetype answers `false` for a sparse component the entity
            // actually carries, so the pre-M1.B form let a batched add of an
            // already-present sparse component through, straight to
            // `SparseSetStorage.add`'s own assert — live in Debug and compiled
            // to nothing in ReleaseFast, i.e. a silent double insert in the
            // mode a game ships. This is the check `hasComponentDyn` exists
            // for, and the reason it is not a convenience wrapper.
            for (ids_all, 0..) |c, ci| {
                if (self.hasComponentDyn(entity, c)) return error.DuplicateComponent;
                for (ids_all[ci + 1 ..]) |other| if (other == c) return error.DuplicateComponent;
            }
        }

        // Target archetype = source components ∪ `cids`, sorted. Built once — the
        // per-transition cache is single-component-keyed, so the grouped path
        // resolves the target directly via `getOrCreateArchetype` (dedup by set).
        const src_len = self.archetypes.items[src_loc.archetype_idx].component_ids.len;
        const target_ids = try gpa.alloc(ComponentId, src_len + ids_all.len);
        defer gpa.free(target_ids);
        @memcpy(target_ids[0..src_len], self.archetypes.items[src_loc.archetype_idx].component_ids);
        @memcpy(target_ids[src_len..], ids_all);
        // The funnel's own split does the filtering: `split.table` is
        // src ∪ (table half of `cids`), sorted, and `split.sparse` is exactly
        // the sparse half of `cids` — `src.component_ids` cannot contribute to
        // it, every archetype signature being table-only by construction. So
        // the signature needs no separate pre-pass; `target_ids` is merely
        // over-allocated by the sparse count, which is harmless.
        const split = self.splitByStorage(target_ids);
        try self.ensureSparseStores(gpa, split.sparse);

        const dst_arch = try self.getOrCreateArchetype(gpa, split.table);
        // `getOrCreateArchetype` may have grown `self.archetypes` — re-fetch the
        // source archetype pointer through the (possibly-moved) list.
        const src_arch = self.archetypes.items[src_loc.archetype_idx];

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        // Sparse rows BEFORE the reserved table slot, per the rule stated at
        // `removeSparsePayloads`: the sparse undo is infallible, the table
        // undo is not, so the step with the messier undo goes last and has
        // nothing after it to unwind. `split.sparse` aliases `target_ids`,
        // whose `defer` was declared earlier and therefore runs AFTER this
        // `errdefer`.
        try self.addSparsePayloads(gpa, entity, split.sparse, vals_all, ids_all);
        errdefer self.removeSparsePayloads(entity, split.sparse);

        // SELF-MIGRATION GUARD, and it sits HERE — after the sparse rows — for a
        // reason its first version got wrong: placed above `addSparsePayloads`
        // it returned before writing them, so the entity ended up carrying
        // nothing while the comment claimed "the sparse rows are already
        // written above". The test caught it; the comment had asserted an order
        // the code did not have.
        //
        // What it guards: when every added id is sparse, the target signature
        // EQUALS the source's, so the funnel hands back the SOURCE archetype.
        // The migration below would then reserve a SECOND slot in it, copy the
        // row into it, and swap-pop the original — and that swap brings the
        // fresh copy back down from the tail and reports THIS entity as the
        // relocated one, so the `getPtr(swapped_id)` line records the correct
        // slot and the `putAssumeCapacity` two lines later overwrites it with
        // the slot the swap just freed. The entity's location then designates a
        // dead slot outside `[0, entity_count)`, and the next spawn into this
        // archetype ALIASES it: reads answer the other entity's bytes and writes
        // corrupt them, with no diagnostic anywhere.
        //
        // Unreachable before M1.B — a grouped add always added at least one
        // signature member — and reachable from production at
        // `loader.activateExtension` for an extension declaring only sparse
        // components.
        if (dst_arch == src_arch) return;

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        // ── from here down: infallible (reserve-then-mutate boundary) ──
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            var new_k: ?usize = null;
            for (ids_all, 0..) |c, k| {
                if (c == dst_cid) {
                    new_k = k;
                    break;
                }
            }
            if (new_k) |k| {
                @memcpy(dst, vals_all[k]); // a newly-added component: caller's bytes
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);
                dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
                dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
            }
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// R12(a) (M1.1.1-HF3) — a validated, slot-reserved grouped remove awaiting
    /// `commitRemoveComponentsDynamic` (infallible) or `abortRemoveComponentsDynamic`
    /// (infallible). Produced by `prepareRemoveComponentsDynamic`, which does ALL
    /// the fallible work. Lets a caller run a fallible-but-non-structural step
    /// (e.g. the `on_detach` hook) BETWEEN validation and the mutation, then
    /// commit or roll back with no way to strand the entity.
    pub const PreparedRemove = struct {
        entity: EntityId,
        src_arch: *Archetype,
        src_loc: Location,
        dst_arch: *Archetype,
        /// The reserved destination slot, or null when the drop set is
        /// ENTIRELY sparse — in which case the target signature equals the
        /// source's, the funnel returns the source archetype, and there is no
        /// migration to perform. Null rather than a self-migration: see the
        /// guard in `prepareRemoveComponentsDynamic` for what the self-migrating
        /// form corrupts.
        dst_r: ?archetype_mod.SpawnResult,
        /// `prepare`'s OWNED copy of `cids`, partitioned in place: the first
        /// `n_table` entries drop from the archetype signature, the rest are
        /// sparse rows for `commit` to remove. Freed by `commit` or `abort`,
        /// which is why both now take an allocator.
        ///
        /// Owned rather than a slice into the caller's `cids`: that would work
        /// today — `loader.deactivateExtension` keeps its stack buffer alive
        /// across the window — and it would make the trio's correctness depend
        /// on a lifetime precondition no signature states. One allocation, on a
        /// path that already makes one for `target_ids`.
        cids_owned: []ComponentId,
        n_table: usize,

        /// The sparse ids this remove must drop.
        pub fn sparseDrops(self: PreparedRemove) []const ComponentId {
            return self.cids_owned[self.n_table..];
        }
    };

    /// R12(a) — the fallible half of a grouped remove: validate, resolve the
    /// target archetype, reserve `entity_locations` capacity, and allocate the
    /// destination slot. No observable mutation yet (the entity stays in its
    /// source archetype). R11(c): every `cids[i]` must be PRESENT and DISTINCT —
    /// real checks (`error.UnknownComponent` / `error.DuplicateComponent`) BEFORE
    /// any allocation, so exactly `cids.len` components drop and no out-of-bounds
    /// write is possible. `cids` length 0 → `error.UnknownComponent` is not
    /// reachable (the caller passes ≥1; the wrapper short-circuits 0).
    pub fn prepareRemoveComponentsDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cids: []const ComponentId,
    ) !PreparedRemove {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;
        const src_arch0 = self.archetypes.items[src_loc.archetype_idx];
        const src_len = src_arch0.component_ids.len;

        // R11(c): present + distinct, checked before any allocation. Routed
        // through `hasComponentDyn` for the same reason as the batched add: the
        // archetype answers `false` for a sparse component the entity carries,
        // so `src_arch0.hasComponent` would reject a legitimate sparse drop
        // with `UnknownComponent` — a refusal of the right shape for the wrong
        // reason, and the harder kind to diagnose.
        for (cids, 0..) |c, ci| {
            if (!self.hasComponentDyn(entity, c)) return error.UnknownComponent;
            for (cids[ci + 1 ..]) |other| if (other == c) return error.DuplicateComponent;
        }
        // M1.B/G9 — `exempt = cids`: a grouped removal of a requisite TOGETHER
        // with its dependents is ALLOWED, so a requirer that is itself leaving
        // does not hold its requisite back. Without that exception a legitimate
        // teardown would be refused forever, which is the guard's other way of
        // being wrong.
        //
        // **This path ERRORS where the single paths SKIP, and the asymmetry is
        // the channel each path can afford — measured, not chosen.** All three
        // flush paths (`CommandBuffer.applyOne`, `applyWithObservers`,
        // `applyRawCommand`) call the SINGLE `removeComponentDynamic`, so an
        // error there would abort the tick — the channel §3 and the brief both
        // refuse. This grouped entry has exactly ONE caller in the repository,
        // `loader.deactivateExtension`, a scene-load path that already returns
        // typed errors and no tick depends on. And a grouped remove is ONE
        // migration: dropping the subset the guard admits would be a silent
        // partial answer, so the whole command is refused rather than trimmed.
        for (cids) |c| {
            if (self.requiresRefusesRemoval(entity, c, cids)) return error.RequiredComponent;
        }

        // Partition the drops: only the table half leaves the signature, and
        // `src_len - cids.len` would UNDERFLOW the moment a sparse id is among
        // them — `cids` is not a subset of the signature any more.
        const cids_owned = try gpa.dupe(ComponentId, cids);
        errdefer gpa.free(cids_owned);
        const drop_split = self.splitByStorage(cids_owned);
        const n_table = drop_split.table.sorted.len;
        std.debug.assert(src_len >= n_table);

        // Target archetype = source components \ the TABLE half of `cids`.
        const target_ids = try gpa.alloc(ComponentId, src_len - n_table);
        defer gpa.free(target_ids);
        var di: usize = 0;
        for (src_arch0.component_ids) |cid| {
            var drop = false;
            for (drop_split.table.sorted) |c| {
                if (c == cid) {
                    drop = true;
                    break;
                }
            }
            if (drop) continue;
            target_ids[di] = cid;
            di += 1;
        }
        std.debug.assert(di == target_ids.len); // guaranteed by the present+distinct checks

        const split = self.splitByStorage(target_ids);
        const dst_arch = try self.getOrCreateArchetype(gpa, split.table);
        // `getOrCreateArchetype` may have grown `self.archetypes` — re-fetch src.
        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        // SELF-MIGRATION GUARD, the twin of `addComponentsDynamic`'s: when every
        // dropped id is sparse the funnel returns the SOURCE archetype, and
        // reserving a slot in it would set up the copy-then-swap sequence that
        // strands the entity's location on a freed slot. No slot is reserved, so
        // `abort` has none to release and `commit` has none to fill.
        const dst_r: ?archetype_mod.SpawnResult = if (dst_arch == src_arch)
            null
        else blk: {
            try self.entity_locations.ensureUnusedCapacity(gpa, 1);
            break :blk try dst_arch.allocateSlot(gpa, self.current_tick);
        };
        return .{
            .entity = entity,
            .src_arch = src_arch,
            .src_loc = src_loc,
            .dst_arch = dst_arch,
            .dst_r = dst_r,
            .cids_owned = cids_owned,
            .n_table = n_table,
        };
    }

    /// R12(a) — the infallible half: copy the surviving columns into the reserved
    /// dst slot, swap-pop the source, and update `entity_locations` (capacity was
    /// reserved in `prepare`). After this the remove is observable.
    pub fn commitRemoveComponentsDynamic(self: *World, gpa: std.mem.Allocator, prepared: PreparedRemove) void {
        defer gpa.free(prepared.cids_owned);
        // The sparse rows go here and NOT in `prepare`, and the reason is
        // semantic rather than structural: `loader.deactivateExtension` fires
        // `on_detach` BETWEEN the two halves, and that hook may read the
        // component being removed. The table columns are still in the source
        // archetype at hook time, so the sparse row must still be in its store
        // — dropping it in `prepare` would show the hook a half-removed
        // component. Infallible either way, so atomicity does not decide it.
        self.removeSparsePayloads(prepared.entity, prepared.sparseDrops());
        // Null `dst_r` means the drop set was entirely sparse: the rows above are
        // the whole removal and the entity does not move. Returning here is what
        // keeps the self-migration guard's decision from being undone.
        const dst_r = prepared.dst_r orelse return;
        const dst_arch = prepared.dst_arch;
        const src_arch = prepared.src_arch;
        const src_loc = prepared.src_loc;
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);
            dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
            dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = prepared.entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(prepared.entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// R12(a) — roll back a `PreparedRemove` without committing: pop the reserved
    /// dst slot. INVARIANT: the reserved slot is the LAST of its chunk
    /// (`allocateSlot` appended it) and nothing allocates into `dst_arch` between
    /// prepare and abort — hook structural changes are deferred (M1.0.10) and the
    /// path is single-threaded — so `removeSwap` on it is a pure pop (no swap,
    /// returns null). The entity was never recorded in `entity_locations` for the
    /// dst slot, so no map fix-up is needed.
    pub fn abortRemoveComponentsDynamic(self: *World, gpa: std.mem.Allocator, prepared: PreparedRemove) void {
        _ = self;
        defer gpa.free(prepared.cids_owned);
        // Nothing to undo on the sparse side: `commit` is what removes those
        // rows, so an aborted prepare never touched them.
        //
        // And nothing to release when `dst_r` is null — an entirely sparse drop
        // set reserved no slot, so a `removeSwap` here would pop a LIVE row
        // belonging to some other entity.
        const dst_r = prepared.dst_r orelse return;
        const swapped = prepared.dst_arch.removeSwap(dst_r.chunk_idx, dst_r.slot);
        std.debug.assert(swapped == null); // the reserved slot must be the chunk's last
    }

    /// Remove SEVERAL components in one migration (prepare → commit). The mirror of
    /// `addComponentsDynamic`; `cids` length 0 is a no-op. Callers that must run a
    /// step between validation and the mutation use `prepare`/`commit`/`abort`
    /// directly (e.g. `loader.deactivateExtension`, which fires `on_detach` in
    /// between).
    pub fn removeComponentsDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cids: []const ComponentId,
    ) !void {
        if (cids.len == 0) return;
        const prepared = try self.prepareRemoveComponentsDynamic(gpa, entity, cids);
        self.commitRemoveComponentsDynamic(gpa, prepared);
    }

    /// M0.8 E3 — apply a single tag-bit mutation (`etch-grammar.md` §4.4): the
    /// deferred-structural-change primitive shared by the Etch interpreter's
    /// tag queue and the codegen command buffer's `set_tag`/`clear_tag`.
    /// `tagset_id` is the registered `TagSet` component — a `[words]u64`
    /// bitfield, one slot per tagged entity. If the entity already has
    /// `TagSet`, the bit is flipped in place (no structural change); if it
    /// lacks one and `set` is true, `TagSet` is added (an archetype transition)
    /// with the bit set; clearing a bit on an entity without `TagSet` is a
    /// no-op. A stale handle is dropped silently (the entity despawned before
    /// the deferred flush). Call only at a flush point, never mid-iteration.
    pub fn applyTagMutation(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        tagset_id: ComponentId,
        bit_index: u32,
        set: bool,
    ) !void {
        // Routed through `componentBytes`, never the archetype: this entry
        // mutates IN PLACE, so it does not appear in an enumeration of the
        // archetype funnel's callers, and on a sparse `TagSet` reaching the
        // archetype answers null. `componentBytes` hands out mutable bytes
        // WITHOUT stamping a change, which is the behaviour here.
        //
        // A STALE HANDLE MUST BE SILENTLY IGNORED, which is what this line
        // restores. The command-buffer flush depends on it — a tag recorded for
        // an entity despawned later in the same tick is ordinary — and without
        // it the null falls into the `else if (set)` arm below, where
        // `addComponentDynamic` returns `StaleEntityHandle`, propagated, which
        // aborts every remaining command of the flush.
        if (self.entity_locations.get(entity) == null) return;
        if (self.componentBytes(entity, tagset_id)) |bytes| {
            setTagBit(bytes, bit_index, set);
        } else if (set) {
            const size = self.registry.componentSize(tagset_id);
            const buf = try gpa.alloc(u8, size);
            defer gpa.free(buf);
            @memset(buf, 0);
            setTagBit(buf, bit_index, true);
            try self.addComponentDynamic(gpa, entity, tagset_id, buf);
        }
    }

    /// Remove component `T` from `entity`. Routes through the source
    /// archetype's `TransitionCache.remove`. The destination archetype
    /// is the source's signature minus `cid`. Component data for the
    /// removed type is dropped; remaining components are byte-copied.
    pub fn removeComponent(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        comptime T: type,
    ) !void {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        const cid_drop = self.registry.idOf(@typeName(T)) orelse return error.StaleEntityHandle;
        // M1.B/G9 — a removal refused by `@requires` is SKIPPED, not an error:
        // the invariant "if A is present, its closure is present" holds, the
        // deviation is counted on `World` and logged once per tick, and the
        // tick survives. An error here would be the channel
        // `engine-ecs-internals.md` §3 and this milestone's brief both refuse —
        // a deferred command turned into an unobservable tick failure.
        if (self.requiresRefusesRemoval(entity, cid_drop, &.{})) return;

        if (self.storageOf(cid_drop) == .sparse) {
            // Mirrors the table arm's `assert(hasComponent)` below: removing an
            // absent component is a programmer error on this entry. UNLIKE that
            // arm, the release path is a no-op rather than undefined — the
            // assert is compiled to nothing in ReleaseFast, and a `.?` sitting
            // behind it would then be UB on the exact misuse the assert exists
            // to name. Matching the table arm bit for bit would be matching a
            // defect, so the absence is handled rather than assumed.
            std.debug.assert(self.hasComponentDyn(entity, cid_drop));
            const store = self.sparse_stores.get(cid_drop) orelse return;
            _ = store.remove(entity);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(src_arch.hasComponent(cid_drop));

        const dst_arch = blk: {
            if (src_arch.transitions.remove.get(cid_drop)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            // `>= 1` and not `>= 2`: since M1.B the EMPTY archetype is legal, so
            // dropping an entity's last component is a transition to it rather
            // than a programmer error. The `>= 2` this replaces was a leftover
            // of the illegality G2 lifted — legal at the layout, still forbidden
            // at the transition. Guaranteed by the `hasComponent(cid_drop)`
            // check above, which is what makes the bound `1` and not `0`.
            std.debug.assert(src_arch.component_ids.len >= 1);
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len - 1);
            defer gpa.free(target_ids);
            var di: usize = 0;
            for (src_arch.component_ids) |cid| {
                if (cid == cid_drop) continue;
                target_ids[di] = cid;
                di += 1;
            }

            const split = self.splitByStorage(target_ids);
            const target = try self.getOrCreateArchetype(gpa, split.table);
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.remove.put(gpa, cid_drop, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);

            // Surviving columns keep their pre-migration ticks.
            const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
            const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
            dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
            dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    // ─── Queries ─────────────────────────────────────────────────────────

    /// S1 sugar — `world.query(gpa)` returns the no-filter
    /// `Query(.{Transform, Velocity}, .{})` over every materialised
    /// (Transform, Velocity)-containing archetype. The bench, the
    /// no-alloc test, and the scheduler tests use this entry point;
    /// callers exercising the E3 filters (`With` / `Without` /
    /// `Predicate`) go through `queryFiltered` directly.
    pub fn query(self: *World, gpa: std.mem.Allocator) !Query {
        return try self.queryFiltered(gpa, &.{ Transform, Velocity }, .{});
    }

    /// Build a comptime-typed multi-archetype query against the
    /// world. `Components` is the read/write set; `filters` is a
    /// tuple of `With(T)`, `Without(T)`, `Predicate(fn)` filter
    /// specs. Auto-registers every type appearing in either set so
    /// callers never have to call `registerComponent` by hand. The
    /// returned query owns a heap-allocated matches list — callers
    /// `defer q.deinit(gpa)`.
    pub fn queryFiltered(
        self: *World,
        gpa: std.mem.Allocator,
        comptime Components: []const type,
        comptime filters: anytype,
    ) !query_mod.Query(Components, filters) {
        const QueryT = query_mod.Query(Components, filters);
        var q = QueryT.empty();
        errdefer q.deinit(gpa);

        // Resolve every type in the required + with + without sets to
        // a `ComponentId`. `ensureRegistered` is idempotent so calling
        // it on already-registered types just returns the cached id.
        // Store the resolved ids on the Query so the E6 lazy re-scan
        // path can reuse them without re-resolving on every iteration.
        inline for (Components, 0..) |T, i| {
            q.required_ids[i] = try self.ensureRegistered(gpa, T);
        }
        inline for (QueryT.with_types, 0..) |T, i| {
            q.with_ids[i] = try self.ensureRegistered(gpa, T);
        }
        inline for (QueryT.without_types, 0..) |T, i| {
            q.without_ids[i] = try self.ensureRegistered(gpa, T);
        }

        // Walk archetypes in creation order so the resulting matches
        // list (and therefore the iteration order surfaced through
        // `chunkAt`) is deterministic and reproducible.
        for (self.archetypes.items) |arch| {
            if (!query_mod.archetypeMatches(arch, &q.required_ids, &q.with_ids, &q.without_ids)) {
                continue;
            }
            var indices: [Components.len]u32 = undefined;
            for (q.required_ids, 0..) |cid, i| {
                indices[i] = @intCast(arch.componentIndex(cid).?);
            }
            try q.matches.append(gpa, .{ .archetype = arch, .column_indices = indices });
        }

        // E6 — wire the lazy re-scan view. After this point, every
        // iteration entry (`chunkCount` / `chunkAt` / `forEachChunk`)
        // first compares `archetypes.items.len` against
        // `last_seen_archetype_count` and re-scans the tail slice on
        // mismatch.
        q.archetype_view = .{
            .ctx = @ptrCast(self),
            .archetypes_slice = &worldArchetypesSlice,
        };
        q.rescan_gpa = gpa;
        q.last_seen_archetype_count = self.archetypes.items.len;

        return q;
    }

    /// Type-erased accessor used by Query's lazy re-scan path —
    /// recovers the `*World` pointer and returns the current
    /// archetype slice. The slice is recomputed on every call so the
    /// rescan loop always sees the up-to-date `items` pointer (which
    /// can move when the ArrayList reallocates).
    fn worldArchetypesSlice(ctx: *anyopaque) []const *Archetype {
        const w: *World = @ptrCast(@alignCast(ctx));
        return w.archetypes.items;
    }

    /// Build a runtime, `ComponentId`-keyed dynamic query (M1.0.0) — the
    /// selection primitive the Etch interpreter routes rule entity selection
    /// through. The interpreter resolves `when` components to `ComponentId`s
    /// (no Zig type to hand to the comptime `queryFiltered`), so it needs an
    /// id-keyed entry point. Matches a single conjunctive term: archetypes
    /// containing every id in `with_ids` and none in `without_ids`, reusing
    /// `archetypeMatches` + the shared option-β lazy re-scan
    /// (`query.rescanNewArchetypes`) — the same matcher and rescan body as the
    /// comptime `Query`. The query owns copies of the id sets; callers
    /// `defer q.deinit(gpa)`.
    ///
    /// `last_seen_archetype_count` starts at 0: the first `maybeRescan` (the
    /// interpreter calls it at the top of each rule run) does the initial full
    /// scan through the very same shared path as every later tail rescan — no
    /// separate initial-scan loop to keep in sync.
    ///
    /// Additive to the World API. The C0.5 freeze covers the Tier-0 ↔ Tier-1
    /// module interfaces, not internal `World` methods, so this does not
    /// breach it.
    pub fn queryDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        with_ids: []const ComponentId,
        without_ids: []const ComponentId,
    ) !query_mod.DynamicQuery {
        const with_copy = try gpa.dupe(ComponentId, with_ids);
        errdefer gpa.free(with_copy);
        const without_copy = try gpa.dupe(ComponentId, without_ids);
        errdefer gpa.free(without_copy);

        return .{
            .with_ids = with_copy,
            .without_ids = without_copy,
            .archetype_view = .{
                .ctx = @ptrCast(self),
                .archetypes_slice = &worldArchetypesSlice,
            },
            .rescan_gpa = gpa,
        };
    }

    // ─── Resources ───────────────────────────────────────────────────────

    /// Add a resource. `init_bytes` is duplicated by the store.
    pub fn addResource(self: *World, gpa: std.mem.Allocator, id: ComponentId, init_bytes: []const u8) !void {
        try self.resources.addResource(gpa, id, init_bytes);
    }

    /// Tick boundary — reset resource dirty bits. Called once per tick
    /// by the interpreter after every rule has run.
    pub fn tickBoundary(self: *World) void {
        self.resources.tickBoundary();
        // M1.B/G9 — the SECOND reset site, and both are required because neither
        // covers the other's population. Measured rather than assumed:
        // `beginFrame` is called unconditionally by the ECS scheduler's frame
        // dispatch (`scheduler.zig`) and by the emitted codegen tick, so it is
        // the boundary a Zig host reaches — but the TREE-WALKER gates it on
        // `if (self.has_changed)`, by design and with its own comment saying "a
        // `changed`-free program never advances the tick". With the reset in
        // `beginFrame` alone, an Etch program carrying no `changed` filter never
        // reset the counter at all: it accumulated over the whole run and the
        // once-per-tick log fired once per PROGRAM. The field's meaning would
        // have depended on whether the program used an unrelated feature.
        self.resetTickObservations();
    }

    /// Decref and zero every resource's persistent-heap payload slot
    /// (`.string_` / `.array_` / `.map_` / `.set_`) — the uniform teardown of
    /// resource-owned heap blocks (M1.1.1-HF2 C4). Tier-0 `World` owns this
    /// walk so a world with no interpreter (e.g. the scene loader over a bare
    /// world) and any resource outside the interpreter's `bridge.resources`
    /// still reclaim their blocks. `ResourceStore` stays string-agnostic in
    /// write — `resources.deinit` only frees the byte buffers — but `World`
    /// owns this decref pass over them.
    ///
    /// Idempotent: each slot is zeroed (`ptr = 0`) after its decref, so a
    /// second call no-ops. This is load-bearing for the interpreter teardown
    /// order — `Interpreter.deinit` calls this BEFORE destroying its immortal
    /// `persistent_literals`, and the subsequent `World.deinit` call then sees
    /// zeroed slots and never re-reads a slot pointing at a freed immortal
    /// block (which would be a use-after-free). `persistent.decref` no-ops on a
    /// sentinel-refcount immortal default and frees a refcounted user block.
    ///
    /// Allocation-free (decrefs + in-place slot zeroing only); never fails.
    /// Reaches into `resources.entries` directly rather than through a store
    /// method: the enumeration is a `World`-level teardown concern, and
    /// `ResourceStore` (FROZEN, M0.9) exposes no all-resources iterator.
    pub fn releaseResourcePayloads(self: *World, gpa: std.mem.Allocator) void {
        var it = self.resources.entries.iterator();
        while (it.next()) |kv| {
            const rid = kv.key_ptr.*;
            const buf = kv.value_ptr.bytes;
            for (self.registry.componentFields(rid)) |fd| {
                switch (fd.kind) {
                    .string_ => {
                        var ss: persistent.StringSlot = undefined;
                        @memcpy(std.mem.asBytes(&ss), buf[fd.offset .. fd.offset + @sizeOf(persistent.StringSlot)]);
                        if (ss.ptr != 0) {
                            persistent.decref(gpa, @ptrFromInt(ss.ptr));
                            ss.ptr = 0;
                            @memcpy(buf[fd.offset .. fd.offset + @sizeOf(persistent.StringSlot)], std.mem.asBytes(&ss));
                        }
                    },
                    // Collection field (M1.0.17): decref the container block; its
                    // registered drop releases string elements/keys/values before
                    // the block frees.
                    .array_, .map_, .set_ => {
                        var cs: persistent.CollectionSlot = undefined;
                        @memcpy(std.mem.asBytes(&cs), buf[fd.offset .. fd.offset + @sizeOf(persistent.CollectionSlot)]);
                        if (cs.ptr != 0) {
                            persistent.decref(gpa, @ptrFromInt(cs.ptr));
                            cs.ptr = 0;
                            @memcpy(buf[fd.offset .. fd.offset + @sizeOf(persistent.CollectionSlot)], std.mem.asBytes(&cs));
                        }
                    },
                    else => {},
                }
            }
        }
    }

    // ─── Inspection helpers ──────────────────────────────────────────────

    /// Total chunk count across every archetype. Used by the bench
    /// harness for the report.
    pub fn chunkCount(self: *const World) usize {
        var total: usize = 0;
        for (self.archetypes.items) |a| total += a.chunkCount();
        return total;
    }
};

/// Set or clear a single bit in a `TagSet`'s raw `[words]u64` bytes (M0.8 E3).
/// The bit index maps to word `bit / 64`, position `bit % 64`.
fn setTagBit(bytes: []u8, bit: u32, set: bool) void {
    const off: usize = @as(usize, bit / 64) * 8;
    var word: u64 = 0;
    @memcpy(std.mem.asBytes(&word), bytes[off .. off + 8]);
    const mask = @as(u64, 1) << @intCast(bit % 64);
    if (set) {
        word |= mask;
    } else {
        word &= ~mask;
    }
    @memcpy(bytes[off .. off + 8], std.mem.asBytes(&word));
}

test "registerOnDetach / dispatchOnDetach fires the on_detach seam (M1.0.9)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Spy = struct {
        var fired: u32 = 0;
        var saw_name: bool = false;
        var saw_text: bool = false;
        fn cb(_: ?*anyopaque, _: *World, _: EntityId, name: []const u8, text: ?[]const u8) anyerror!void {
            fired += 1;
            if (std.mem.eql(u8, name, "CombatModule")) saw_name = true;
            if (text != null and std.mem.indexOf(u8, text.?, "Health") != null) saw_text = true;
        }
    };
    Spy.fired = 0;
    Spy.saw_name = false;
    Spy.saw_text = false;

    const e = EntityId{ .index = 1, .generation = 1 };
    const detach_text = "entity.get_mut(Health).max -= 50";

    // No hook registered → dispatch is a no-op (mirror of the on_attach seam).
    try world.dispatchOnDetach(e, "CombatModule", detach_text);
    try std.testing.expectEqual(@as(u32, 0), Spy.fired);

    world.registerOnDetach(null, &Spy.cb);
    try world.dispatchOnDetach(e, "CombatModule", detach_text);
    try std.testing.expectEqual(@as(u32, 1), Spy.fired);
    try std.testing.expect(Spy.saw_name);
    try std.testing.expect(Spy.saw_text);
}

test "per-entity extension side-table tracks add / has / remove (M1.0.9)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const e1 = EntityId{ .index = 1, .generation = 1 };
    const e2 = EntityId{ .index = 2, .generation = 1 };

    try std.testing.expect(!world.hasEntityExtension(e1, "Combat"));
    try std.testing.expectEqual(@as(usize, 0), world.entityExtensions(e1).len);

    try world.addEntityExtension(gpa, e1, "Combat");
    try world.addEntityExtension(gpa, e1, "Merchant");
    try world.addEntityExtension(gpa, e2, "Combat");
    // Re-adding the same name is a no-op (belt-and-braces dedup).
    try world.addEntityExtension(gpa, e1, "Combat");

    try std.testing.expect(world.hasEntityExtension(e1, "Combat"));
    try std.testing.expect(world.hasEntityExtension(e1, "Merchant"));
    try std.testing.expect(world.hasEntityExtension(e2, "Combat"));

    const e1_exts = world.entityExtensions(e1);
    try std.testing.expectEqual(@as(usize, 2), e1_exts.len);
    try std.testing.expectEqualStrings("Combat", e1_exts[0]); // activation order
    try std.testing.expectEqualStrings("Merchant", e1_exts[1]);

    world.removeEntityExtension(gpa, e1, "Combat");
    try std.testing.expect(!world.hasEntityExtension(e1, "Combat"));
    try std.testing.expect(world.hasEntityExtension(e1, "Merchant"));
    try std.testing.expectEqual(@as(usize, 1), world.entityExtensions(e1).len);

    // e2 still has Combat — the set is per-entity.
    try std.testing.expect(world.hasEntityExtension(e2, "Combat"));

    // Draining the last extension drops the map entry; `deinit` frees the rest
    // (the testing allocator flags any leak of the owned name copies).
    world.removeEntityExtension(gpa, e1, "Merchant");
    try std.testing.expectEqual(@as(usize, 0), world.entityExtensions(e1).len);
}

test "despawn removes the entity's extension entry (M1.1.1-HF1 D7)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Marker = extern struct { v: u32 = 0 };
    const cid = try world.registerComponent(gpa, Marker);

    const e = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    try world.addEntityExtension(gpa, e, "CombatModule");
    try world.addEntityExtension(gpa, e, "MerchantModule");
    try std.testing.expect(world.hasEntityExtension(e, "CombatModule"));
    try std.testing.expectEqual(@as(usize, 2), world.entityExtensions(e).len);

    try world.despawn(gpa, e);

    // The extension entry is gone — its owned name copies were freed by
    // `despawn`, not stranded until `deinit` (the testing allocator would flag
    // any leak). No entry remains for this entity.
    try std.testing.expect(!world.hasEntityExtension(e, "CombatModule"));
    try std.testing.expect(!world.hasEntityExtension(e, "MerchantModule"));
    try std.testing.expectEqual(@as(usize, 0), world.entityExtensions(e).len);
    try std.testing.expect(!world.isLive(e));
}

test "despawn is allocation-free after spawn (M1.1.1-HF2 C1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Marker = extern struct { v: u32 = 0 };
    const cid = try world.registerComponent(gpa, Marker);

    const e = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    try std.testing.expect(world.isLive(e));
    const live_before = world.identity.liveCount();

    // Despawn allocates nothing: `identity.release` is a bare
    // `appendAssumeCapacity` (C1), `entity_locations.remove` frees a hash slot,
    // and this entity carries no extension entry to purge. Prove it by failing
    // every allocation for the whole despawn — it must still succeed and
    // reclaim the slot.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try world.despawn(failing.allocator(), e);

    try std.testing.expect(!world.isLive(e));
    try std.testing.expectEqual(live_before - 1, world.identity.liveCount());
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "spawn OOM on archetype storage leaves no orphan identity (M1.1.1-HF2 C1)" {
    const gpa = std.testing.allocator;
    const Marker = extern struct { v: u32 = 0 };

    // Pass 1 — count the allocations a fresh dynamic spawn performs. The final
    // one is the archetype chunk allocation in `spawnDefault`, which runs AFTER
    // `identity.allocate`.
    var alloc_count: usize = undefined;
    {
        var w = World.init();
        defer w.deinit(gpa);
        const cid = try w.registerComponent(gpa, Marker);
        var counting = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
        _ = try w.spawnDynamic(counting.allocator(), &[_]ComponentId{cid});
        alloc_count = counting.alloc_index;
    }
    try std.testing.expect(alloc_count > 0);

    // Pass 2 — identical fresh world; fail the final allocation
    // (`fail_index = alloc_count - 1`). Identity was already allocated by then,
    // so the spawn's `errdefer self.identity.release(eid)` must reclaim it.
    // `release` is now infallible (no swallowed OOM from a `catch {}`), so
    // `liveCount` returns to its pre-spawn value and no slot is stranded.
    var w = World.init();
    defer w.deinit(gpa);
    const cid = try w.registerComponent(gpa, Marker);
    const live_before = w.identity.liveCount();

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = alloc_count - 1 });
    try std.testing.expectError(error.OutOfMemory, w.spawnDynamic(failing.allocator(), &[_]ComponentId{cid}));

    try std.testing.expectEqual(live_before, w.identity.liveCount());
    try std.testing.expectEqual(@as(usize, 0), w.entityCount());
}

test "releaseResourcePayloads is idempotent and frees a string block once (M1.1.1-HF2 C4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Register a resource-shaped type with a single `.string_` field at offset
    // 0 (16 bytes, a `StringSlot`). Resources register through the same raw
    // path as components — the resource-only gating of `.string_` lives in the
    // Etch validator, not in the Tier-0 registry.
    const zero16 = [_]u8{0} ** 16;
    const fields = [_]registry_mod.FieldDesc{.{ .name = "s", .offset = 0, .kind = .string_ }};
    const rid = try world.registerComponentRaw(gpa, .{
        .name = "ResWithString",
        .size = 16,
        .alignment = 8,
        .default_bytes = &zero16,
        .fields = &fields,
    });
    try world.addResource(gpa, rid, &zero16);

    // Write a refcounted (refcount 1) persistent string block into the slot.
    const block = try persistent.alloc(gpa, persistent.type_string, 5);
    try std.testing.expectEqual(@as(u32, 1), persistent.refcount(block));
    var ss = persistent.StringSlot{ .ptr = @intFromPtr(block), .len = 5 };
    const buf = world.resources.getMutResource(rid).?;
    @memcpy(buf[0..@sizeOf(persistent.StringSlot)], std.mem.asBytes(&ss));

    // First call frees the block (refcount 1 → 0) and zeroes the slot.
    world.releaseResourcePayloads(gpa);
    // Slot is zeroed → the second call decrefs nothing (no double-free / UAF).
    world.releaseResourcePayloads(gpa);

    @memcpy(std.mem.asBytes(&ss), buf[0..@sizeOf(persistent.StringSlot)]);
    try std.testing.expectEqual(@as(u64, 0), ss.ptr);

    // Leak detection (std.testing.allocator, via the deferred `world.deinit`
    // whose own `releaseResourcePayloads` call is a third no-op) proves the
    // block was reclaimed exactly once.
}

test "addComponentsDynamic migrates once and is atomic under OOM" {
    const backing = std.testing.allocator;
    const va = [_]u8{ 0xAA, 0, 0, 0 };
    const vb = [_]u8{ 0xBB, 0, 0, 0 };
    const vc = [_]u8{ 0xCC, 0, 0, 0 };
    const vd = [_]u8{ 0xDD, 0, 0, 0 };
    const desc = struct {
        fn d(name: []const u8) ComponentDesc {
            return .{ .name = name, .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} };
        }
    }.d;

    // Success path: grouped add of B,C,D onto an entity that has A yields one
    // archetype move with all four values readable.
    {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("GA"));
        const b = try world.registerComponentRaw(backing, desc("GB"));
        const c = try world.registerComponentRaw(backing, desc("GC"));
        const d = try world.registerComponentRaw(backing, desc("GD"));
        const e = try world.spawnDynamicWithValues(backing, &.{a}, &.{&va});
        try world.addComponentsDynamic(backing, e, &.{ b, c, d }, &.{ &vb, &vc, &vd });
        try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
        try std.testing.expectEqualSlices(u8, &vb, world.componentBytes(e, b).?);
        try std.testing.expectEqualSlices(u8, &vc, world.componentBytes(e, c).?);
        try std.testing.expectEqualSlices(u8, &vd, world.componentBytes(e, d).?);
    }

    // Atomic under OOM: at every injected failure point the grouped add either
    // fully lands or leaves the entity in its source archetype with only A.
    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("GA"));
        const b = try world.registerComponentRaw(backing, desc("GB"));
        const c = try world.registerComponentRaw(backing, desc("GC"));
        const d = try world.registerComponentRaw(backing, desc("GD"));
        const e = try world.spawnDynamicWithValues(backing, &.{a}, &.{&va});
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (world.addComponentsDynamic(fa.allocator(), e, &.{ b, c, d }, &.{ &vb, &vc, &vd })) |_| {
            try std.testing.expectEqualSlices(u8, &vd, world.componentBytes(e, d).?);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
            try std.testing.expect(world.componentBytes(e, b) == null);
            try std.testing.expect(world.componentBytes(e, c) == null);
            try std.testing.expect(world.componentBytes(e, d) == null);
        }
    }
}

test "removeComponentsDynamic is atomic under OOM" {
    const backing = std.testing.allocator;
    const va = [_]u8{ 0xAA, 0, 0, 0 };
    const vb = [_]u8{ 0xBB, 0, 0, 0 };
    const vc = [_]u8{ 0xCC, 0, 0, 0 };
    const vd = [_]u8{ 0xDD, 0, 0, 0 };
    const desc = struct {
        fn d(name: []const u8) ComponentDesc {
            return .{ .name = name, .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} };
        }
    }.d;

    // Success path: grouped remove of B,C,D leaves only A.
    {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("RA"));
        const b = try world.registerComponentRaw(backing, desc("RB"));
        const c = try world.registerComponentRaw(backing, desc("RC"));
        const d = try world.registerComponentRaw(backing, desc("RD"));
        const e = try world.spawnDynamicWithValues(backing, &.{ a, b, c, d }, &.{ &va, &vb, &vc, &vd });
        try world.removeComponentsDynamic(backing, e, &.{ b, c, d });
        try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
        try std.testing.expect(world.componentBytes(e, b) == null);
        try std.testing.expect(world.componentBytes(e, c) == null);
        try std.testing.expect(world.componentBytes(e, d) == null);
    }

    // Atomic under OOM: on failure the entity keeps all four components.
    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("RA"));
        const b = try world.registerComponentRaw(backing, desc("RB"));
        const c = try world.registerComponentRaw(backing, desc("RC"));
        const d = try world.registerComponentRaw(backing, desc("RD"));
        const e = try world.spawnDynamicWithValues(backing, &.{ a, b, c, d }, &.{ &va, &vb, &vc, &vd });
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (world.removeComponentsDynamic(fa.allocator(), e, &.{ b, c, d })) |_| {
            try std.testing.expect(world.componentBytes(e, b) == null);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
            try std.testing.expectEqualSlices(u8, &vb, world.componentBytes(e, b).?);
            try std.testing.expectEqualSlices(u8, &vc, world.componentBytes(e, c).?);
            try std.testing.expectEqualSlices(u8, &vd, world.componentBytes(e, d).?);
        }
    }
}

test "grouped ops reject duplicate / absent components (R11c) without panicking" {
    const backing = std.testing.allocator;
    const v = [_]u8{ 0x11, 0, 0, 0 };
    const desc = struct {
        fn d(name: []const u8) ComponentDesc {
            return .{ .name = name, .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} };
        }
    }.d;

    var world = World.init();
    defer world.deinit(backing);
    const a = try world.registerComponentRaw(backing, desc("DA"));
    const b = try world.registerComponentRaw(backing, desc("DB"));
    const c = try world.registerComponentRaw(backing, desc("DC"));
    const e = try world.spawnDynamicWithValues(backing, &.{a}, &.{&v});

    // addComponentsDynamic: a cid already on the entity → DuplicateComponent.
    try std.testing.expectError(error.DuplicateComponent, world.addComponentsDynamic(backing, e, &.{a}, &.{&v}));
    // addComponentsDynamic: a cid repeated within `cids` → DuplicateComponent.
    try std.testing.expectError(error.DuplicateComponent, world.addComponentsDynamic(backing, e, &.{ b, b }, &.{ &v, &v }));
    // The entity is untouched by the rejected adds (still just A).
    try std.testing.expect(world.componentBytes(e, a) != null);
    try std.testing.expect(world.componentBytes(e, b) == null);

    // Give it A,B,C for the remove checks.
    try world.addComponentsDynamic(backing, e, &.{ b, c }, &.{ &v, &v });
    // removeComponentsDynamic: an absent cid → UnknownComponent.
    const d = try world.registerComponentRaw(backing, desc("DD"));
    try std.testing.expectError(error.UnknownComponent, world.removeComponentsDynamic(backing, e, &.{d}));
    // removeComponentsDynamic: a repeated cid → DuplicateComponent.
    try std.testing.expectError(error.DuplicateComponent, world.removeComponentsDynamic(backing, e, &.{ b, b }));
    // Still intact — the rejects happen before any mutation.
    try std.testing.expect(world.componentBytes(e, a) != null);
    try std.testing.expect(world.componentBytes(e, b) != null);
    try std.testing.expect(world.componentBytes(e, c) != null);
}
