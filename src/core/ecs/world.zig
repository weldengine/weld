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

const registry_mod = @import("registry.zig");
const resources_mod = @import("resources.zig");
const query_runtime_mod = @import("query_runtime.zig");

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
/// Canonical S1 query type — `Query(.{Transform, Velocity})`. Exposed
/// as `world.Archetype.ChunkT` etc. consumers reach via this alias.
pub const Query = query_mod.Query(&.{ Transform, Velocity });
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

    pub fn init() World {
        return .{
            .identity = EntityIdentityStore.init(),
            .registry = Registry.init(),
            .archetypes = .empty,
            .archetype_by_signature = .empty,
            .entity_locations = .empty,
            .resources = ResourceStore.init(),
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
        self.* = undefined;
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

        const r = try arch.allocateSlot(gpa);
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

        const r = try arch.spawnDefault(gpa, eid);
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

        // Allocate a slot in the destination archetype.
        const dst_r = try dst_arch.allocateSlot(gpa);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        // Copy each destination component column from either the source
        // archetype (if the component exists there) or the caller's
        // freshly-provided value.
        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            if (dst_cid == cid_new) {
                @memcpy(dst, std.mem.asBytes(&value));
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);
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

        const dst_r = try dst_arch.allocateSlot(gpa);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);
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

    /// Build the S1 single-archetype query — `Query(.{Transform,
    /// Velocity})` over the `(Transform, Velocity)` archetype. Returns
    /// an empty query when no entity has been spawned yet (the
    /// archetype has not been materialised).
    pub fn query(self: *World) Query {
        const id_t = self.registry.idOf(@typeName(Transform)) orelse return Query.empty();
        const id_v = self.registry.idOf(@typeName(Velocity)) orelse return Query.empty();
        var ids = [_]ComponentId{ id_t, id_v };
        archetype_mod.sortComponentIds(&ids);
        const arch = self.findArchetype(&ids) orelse return Query.empty();
        // Pass the component ids in the order matching `Components` in
        // `Query(.{Transform, Velocity})` so the comptime column map
        // resolves Transform → index 0, Velocity → index 1 inside the
        // archetype.
        return Query.fromArchetype(arch, .{ id_t, id_v });
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
