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
/// `on_attach` Etch source text (`null` if absent). M1.0.6 wires + fires the seam;
/// running the text is M1.0.9.
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
        self.entity_locations.deinit(gpa);
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
    /// components. Executing the text is M1.0.9 — here the seam just fires.
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
    fn getOrCreateArchetype(self: *World, gpa: std.mem.Allocator, sorted_ids: []const ComponentId) !*Archetype {
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

    pub fn dynamicArchetype(self: *World, idx: ArchetypeId) *Archetype {
        return self.archetypes.items[idx];
    }

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
        archetype_mod.sortComponentIds(&ids);
        const arch = try self.getOrCreateArchetype(gpa, &ids);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(gpa, eid) catch {};

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
        // Caller's ids may be unsorted — dup and sort before lookup.
        const sorted = try gpa.dupe(ComponentId, component_ids);
        defer gpa.free(sorted);
        archetype_mod.sortComponentIds(sorted);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        const arch = try self.getOrCreateArchetype(gpa, sorted);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(gpa, eid) catch {};

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

        // Build the sorted-id arch key while preserving the original
        // (id, payload) pairing so we can resolve each payload to its
        // sorted column index at write time.
        const sorted = try gpa.dupe(ComponentId, component_ids);
        defer gpa.free(sorted);
        archetype_mod.sortComponentIds(sorted);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        const arch = try self.getOrCreateArchetype(gpa, sorted);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(gpa, eid) catch {};

        const r = try arch.allocateSlot(gpa, self.current_tick);
        const chunk = arch.chunks.items[r.chunk_idx];

        // For each archetype column, find the matching payload by
        // ComponentId (linear scan — `component_ids.len` is small).
        for (arch.component_ids, 0..) |arch_cid, col| {
            var found: ?usize = null;
            for (component_ids, 0..) |req_cid, k| {
                if (req_cid == arch_cid) {
                    found = k;
                    break;
                }
            }
            const dst = arch.componentSlot(chunk, col, r.slot);
            if (found) |k| {
                @memcpy(dst, payloads[k]);
            } else {
                // Should never happen — sorted is derived from
                // component_ids by `dupe`, so every column has a payload.
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
    /// entity's location atomically with the chunk-level swap.
    pub fn despawn(self: *World, gpa: std.mem.Allocator, id: EntityId) WorldError!void {
        try self.identity.validate(id);
        const location = self.entity_locations.get(id) orelse return error.StaleEntityHandle;

        const arch = self.archetypes.items[location.archetype_idx];
        if (arch.removeSwap(location.chunk_idx, location.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = location;
        }
        _ = self.entity_locations.remove(id);
        try self.identity.release(gpa, id);
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
    }

    /// Read-only typed access to component `T` on `entity`. Returns
    /// `null` when the entity is stale or its archetype does not
    /// hold `T`. Does **not** mark the slot as changed.
    pub fn get(self: *const World, comptime T: type, entity: EntityId) ?*const T {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        const cid = self.registry.idOf(@typeName(T)) orelse return null;
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
        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(!src_arch.hasComponent(cid_new));

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
            archetype_mod.sortComponentIds(target_ids);

            const target = try self.getOrCreateArchetype(gpa, target_ids);
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
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(!src_arch.hasComponent(cid_new));

        const dst_arch = blk: {
            if (src_arch.transitions.add.get(cid_new)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len + 1);
            defer gpa.free(target_ids);
            @memcpy(target_ids[0..src_arch.component_ids.len], src_arch.component_ids);
            target_ids[src_arch.component_ids.len] = cid_new;
            archetype_mod.sortComponentIds(target_ids);

            const target = try self.getOrCreateArchetype(gpa, target_ids);
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

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(src_arch.hasComponent(cid_drop));

        const dst_arch = blk: {
            if (src_arch.transitions.remove.get(cid_drop)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            std.debug.assert(src_arch.component_ids.len >= 2);
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len - 1);
            defer gpa.free(target_ids);
            var di: usize = 0;
            for (src_arch.component_ids) |cid| {
                if (cid == cid_drop) continue;
                target_ids[di] = cid;
                di += 1;
            }

            const target = try self.getOrCreateArchetype(gpa, target_ids);
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
        const loc = self.entity_locations.get(entity) orelse return;
        const arch = self.archetypes.items[loc.archetype_idx];
        if (arch.componentIndex(tagset_id)) |col| {
            const chunk = arch.chunks.items[loc.chunk_idx];
            const bytes = arch.componentSlot(chunk, col, loc.slot);
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
        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(src_arch.hasComponent(cid_drop));

        const dst_arch = blk: {
            if (src_arch.transitions.remove.get(cid_drop)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            std.debug.assert(src_arch.component_ids.len >= 2);
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len - 1);
            defer gpa.free(target_ids);
            var di: usize = 0;
            for (src_arch.component_ids) |cid| {
                if (cid == cid_drop) continue;
                target_ids[di] = cid;
                di += 1;
            }

            const target = try self.getOrCreateArchetype(gpa, target_ids);
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
