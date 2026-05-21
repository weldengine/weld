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
const query_runtime_mod = @import("query_runtime.zig");
const observers_mod = @import("observers.zig");

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
const RuntimeQuery = query_runtime_mod.RuntimeQuery;
const EntityIdentityStore = entity_mod.EntityIdentityStore;

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
    /// `get_mut(T)` auto-mark. Reads happen from `Query.last_run_tick`
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

    /// Resource store keyed by `ComponentId`.
    resources: ResourceStore,

    /// M0.1 / E6 — observer registry. Carries per-event callback
    /// lists + a shared deferred command buffer for observer-issued
    /// mutations. Lazy-init'd by the first `registerOn*` call; tests
    /// that don't exercise observers never pay the alloc cost.
    observer_registry: observers_mod.ObserverRegistry = .{},

    pub fn init() World {
        return .{
            .identity = EntityIdentityStore.init(),
            .current_tick = tick_mod.initial_tick,
            .registry = Registry.init(),
            .archetypes = .empty,
            .archetype_by_signature = .empty,
            .entity_locations = .empty,
            .resources = ResourceStore.init(),
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
        self.registry.deinit(gpa);
        self.identity.deinit(gpa);
        self.observer_registry.deinit(gpa);
        self.* = undefined;
    }

    // ─── Observer registration (M0.1 / E6) ───────────────────────────────

    /// Register an `on_spawned` observer.
    pub fn registerOnSpawned(
        self: *World,
        gpa: std.mem.Allocator,
        callback: observers_mod.ObserverFn,
    ) !void {
        try self.observer_registry.registerOnSpawned(gpa, self, callback);
    }

    /// Register an `on_despawned` observer.
    pub fn registerOnDespawned(
        self: *World,
        gpa: std.mem.Allocator,
        callback: observers_mod.ObserverFn,
    ) !void {
        try self.observer_registry.registerOnDespawned(gpa, self, callback);
    }

    /// Register an `on_add` observer for component `T`.
    pub fn registerOnAdd(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnAdd(gpa, self, cid, callback);
    }

    /// Register an `on_remove` observer for component `T`.
    pub fn registerOnRemove(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnRemove(gpa, self, cid, callback);
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
    pub fn get_mut(self: *World, comptime T: type, entity: EntityId) ?*T {
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

    /// Build a runtime query against this world's archetypes. Mirrors
    /// the pre-E2 entry point — `archetypes` is now the unified list,
    /// so the runtime query iterates over every materialised
    /// archetype.
    pub fn query_dynamic(self: *World, includes: []const ComponentId, excludes: []const ComponentId) RuntimeQuery {
        return .{
            .includes = includes,
            .excludes = excludes,
            .archetypes = self.archetypes.items,
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
