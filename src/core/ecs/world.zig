//! Tier 0 root `World` — owns the S1 `(Transform, Velocity)` archetype, the
//! S4 dynamic archetypes, the runtime `Registry`, and the `ResourceStore`,
//! and the M0.1 / E1 generational `EntityIdentityStore` that gives all of
//! the above a coherent, leak-detecting identity.
//!
//! Identity vs storage. The `identity` store owns the per-slot
//! `(generation, alive)` table plus the free-index stack shared by both
//! spawn paths. The two location maps (`entity_locations` for the S1
//! comptime archetype, `dynamic_locations` for the S4 dynamic archetypes)
//! remain `AutoHashMapUnmanaged(EntityId, Location)` keyed by the new
//! packed `EntityId` — generation now travels with the key, so the maps
//! reject stale handles for free.
//!
//! Despawn is the only structural mutation routed through the identity
//! store. It validates the handle's generation, removes the entity from
//! its archetype via swap-and-pop, updates the location of the entity that
//! moved into the freed chunk slot, then releases the identity slot (which
//! bumps the generation and pushes the index onto the free list). The S4
//! dynamic-side despawn is wired separately in E2 (generalised storage);
//! the E1 surface only handles the S1 path because the bench non-regression
//! workload (100 k entities × 1 archetype) and the new
//! `tests/ecs/generational_indices.zig` only exercise the static path.

const std = @import("std");
const components = @import("components.zig");
const entity_mod = @import("entity.zig");
const archetype_mod = @import("archetype.zig");
const query_mod = @import("query.zig");

const registry_mod = @import("registry.zig");
const arch_dyn_mod = @import("archetype_dynamic.zig");
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

// Comptime list of the static-side archetype's component types.
// Private because the comptime instantiation it drives (`Archetype`,
// `Query`) is the only surface anyone consumes.
const archetype_components: []const type = &.{ Transform, Velocity };
/// Public archetype handle for the S1 static path — consumers that
/// drive the comptime SoA storage (bench harness, smoke test) need
/// the instantiated type at their call sites, not the factory.
pub const Archetype = archetype_mod.Archetype(archetype_components);
const Query = query_mod.Query(archetype_components);
const Location = archetype_mod.Location;

const Registry = registry_mod.Registry;
const ComponentId = registry_mod.ComponentId;
const ComponentDesc = registry_mod.ComponentDesc;
const FieldDesc = registry_mod.FieldDesc;
const FieldKind = registry_mod.FieldKind;
const DynamicArchetype = arch_dyn_mod.DynamicArchetype;
const ResourceStore = resources_mod.ResourceStore;
const RuntimeQuery = query_runtime_mod.RuntimeQuery;
const EntityIdentityStore = entity_mod.EntityIdentityStore;

/// Location inside the dynamic side of the world: which dynamic archetype,
/// which chunk inside it, which slot inside the chunk. Distinct from the
/// S1 `Location` (which is chunk_idx + slot only, since S1 has one
/// hardcoded archetype).
pub const DynamicLocation = struct {
    archetype_idx: u32,
    chunk_idx: u32,
    slot: u32,
};

/// Top-level ECS world — holds the static S1 archetype, the dynamic
/// S4 archetypes, the runtime component registry, the resource store,
/// and the M0.1 / E1 generational identity store.
pub const World = struct {
    // ── Shared identity (M0.1 / E1) ──
    /// Generational identity store driving every spawn / despawn across
    /// both the S1 comptime path and the S4 dynamic path. A single store
    /// guarantees that the `(index, generation)` halves of an `EntityId`
    /// stay unique world-wide.
    identity: EntityIdentityStore,

    // ── S1 comptime path ──
    archetype: Archetype,
    entity_locations: std.AutoHashMapUnmanaged(EntityId, Location),

    // ── S4 dynamic path ──
    /// Runtime component / resource type registry. Initialised lazily on
    /// first use (`registerComponent`, `addResource`) so that S1 code
    /// paths that ignore S4 pay nothing.
    registry: Registry,
    /// Dynamic archetypes the world owns. The interpreter walks this slice
    /// when evaluating `RuntimeQuery`. Stored as `*DynamicArchetype` so
    /// stable pointers survive `archetypes.append`.
    archetypes: std.ArrayListUnmanaged(*DynamicArchetype),
    /// Per-entity location map for entities spawned via `spawnDynamic`.
    /// Kept separate from `entity_locations` so the two storage paths
    /// remain easy to distinguish; identity is shared via `identity`.
    dynamic_locations: std.AutoHashMapUnmanaged(EntityId, DynamicLocation),
    /// Resource store keyed by `ComponentId`.
    resources: ResourceStore,

    pub fn init() World {
        return .{
            .identity = EntityIdentityStore.init(),
            .archetype = Archetype.init(0),
            .entity_locations = .empty,
            .registry = Registry.init(),
            .archetypes = .empty,
            .dynamic_locations = .empty,
            .resources = ResourceStore.init(),
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.archetype.deinit(gpa);
        self.entity_locations.deinit(gpa);
        // Dynamic side.
        for (self.archetypes.items) |a| {
            a.deinit(gpa);
            gpa.destroy(a);
        }
        self.archetypes.deinit(gpa);
        self.dynamic_locations.deinit(gpa);
        self.resources.deinit(gpa);
        self.registry.deinit(gpa);
        self.identity.deinit(gpa);
        self.* = undefined;
    }

    // ─── S1 comptime API ─────────────────────────────────────────────────

    /// Spawn an entity with the given component values. The entity id is
    /// drawn from the generational identity store — recycled slots reuse a
    /// previously-freed index with an incremented generation.
    pub fn spawn(
        self: *World,
        gpa: std.mem.Allocator,
        transform: Transform,
        velocity: Velocity,
    ) !EntityId {
        // Ensure the location map can absorb one more entry before we
        // reserve identity, so a put failure can't leave a live slot
        // without a backing location entry.
        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        const id = try self.identity.allocate(gpa);
        errdefer self.identity.release(gpa, id) catch {};
        const location = try self.archetype.append(gpa, id, .{ transform, velocity });
        // `ensureUnusedCapacity` above guarantees this never allocates.
        self.entity_locations.putAssumeCapacity(id, location);
        return id;
    }

    /// Despawn an entity by handle. Returns `error.StaleEntityHandle`
    /// when the handle's index is unknown, the slot is already freed, or
    /// the generation does not match — the caller can distinguish a
    /// genuine bug from a benign late despawn that way. The corresponding
    /// chunk slot is swap-and-popped; if another entity moves into the
    /// freed slot, its location map entry is updated atomically. The
    /// identity slot is bumped and pushed onto the free list last so any
    /// outstanding handle to the despawned entity becomes stale.
    pub fn despawn(self: *World, gpa: std.mem.Allocator, id: EntityId) WorldError!void {
        try self.identity.validate(id);
        const location = self.entity_locations.get(id) orelse return error.StaleEntityHandle;
        if (self.archetype.removeSwap(location)) |swapped_id| {
            // The entity that was at the last slot has been moved to
            // `location.slot`; rewrite its mapping so future lookups
            // resolve to the new chunk slot.
            self.entity_locations.getPtr(swapped_id).?.* = location;
        }
        _ = self.entity_locations.remove(id);
        try self.identity.release(gpa, id);
    }

    pub fn entityCount(self: *const World) usize {
        return self.entity_locations.count();
    }

    /// `true` if `id` refers to a live entity in this world (either spawn
    /// path). Returns `false` for stale handles instead of erroring —
    /// the caller picks the policy.
    pub fn isLive(self: *const World, id: EntityId) bool {
        return self.identity.isLive(id);
    }

    pub fn chunkCount(self: *const World) usize {
        return self.archetype.chunkCount();
    }

    pub fn query(self: *World) Query {
        return Query.init(&self.archetype);
    }

    // ─── S4 dynamic API ──────────────────────────────────────────────────

    /// Register a component whose layout is described at runtime. Returns
    /// the assigned `ComponentId`.
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

    /// Find or create a dynamic archetype for the given component set.
    /// Component ids are matched as a set; the archetype list is searched
    /// linearly (S4 expects a handful of archetypes).
    pub fn getOrCreateDynamicArchetype(self: *World, gpa: std.mem.Allocator, component_ids: []const ComponentId) !*DynamicArchetype {
        outer: for (self.archetypes.items) |a| {
            if (a.component_ids.len != component_ids.len) continue;
            for (component_ids) |id| {
                if (!a.hasComponent(id)) continue :outer;
            }
            return a;
        }
        const arch_id: u32 = @intCast(self.archetypes.items.len);
        const a = try gpa.create(DynamicArchetype);
        errdefer gpa.destroy(a);
        a.* = try DynamicArchetype.init(gpa, &self.registry, arch_id, component_ids);
        errdefer a.deinit(gpa);
        try self.archetypes.append(gpa, a);
        return a;
    }

    /// Spawn an entity in the dynamic side of the world. The slot is
    /// initialised from the registry's default bytes for every component
    /// of the archetype. The entity id is drawn from the same generational
    /// identity store as the S1 path, so the two never collide and slot
    /// reuse on either side stays coherent.
    pub fn spawnDynamic(self: *World, gpa: std.mem.Allocator, component_ids: []const ComponentId) !EntityId {
        // Reserve the location-map slot first so a put failure can't strand
        // a live identity slot without a backing location entry.
        try self.dynamic_locations.ensureUnusedCapacity(gpa, 1);
        const id = try self.identity.allocate(gpa);
        errdefer self.identity.release(gpa, id) catch {};
        const arch = try self.getOrCreateDynamicArchetype(gpa, component_ids);
        const r = try arch.spawnDefault(gpa, id);
        // `ensureUnusedCapacity` above guarantees this never allocates.
        self.dynamic_locations.putAssumeCapacity(id, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return id;
    }

    /// Find the dynamic archetype the given entity lives in. Returns
    /// `null` for entities spawned via the S1 comptime path or unknown
    /// ids.
    pub fn dynamicLocation(self: *const World, id: EntityId) ?DynamicLocation {
        return self.dynamic_locations.get(id);
    }

    pub fn dynamicArchetype(self: *World, idx: u32) *DynamicArchetype {
        return self.archetypes.items[idx];
    }

    /// Add a resource. `init_bytes` is duplicated by the store.
    pub fn addResource(self: *World, gpa: std.mem.Allocator, id: ComponentId, init_bytes: []const u8) !void {
        try self.resources.addResource(gpa, id, init_bytes);
    }

    /// Build a runtime query against this world's dynamic archetypes.
    pub fn query_dynamic(self: *World, includes: []const ComponentId, excludes: []const ComponentId) RuntimeQuery {
        return .{
            .includes = includes,
            .excludes = excludes,
            .archetypes = self.archetypes.items,
        };
    }

    /// Tick boundary — reset resource dirty bits. Called once per tick by
    /// the interpreter after every rule has run.
    pub fn tickBoundary(self: *World) void {
        self.resources.tickBoundary();
    }
};
