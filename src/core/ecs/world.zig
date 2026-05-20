//! S1 root `World` — owns the single `(Transform, Velocity)` archetype and
//! exposes `spawn` / `despawn` / `query`. S4 extends the same struct with
//! a runtime `Registry`, a `ResourceStore`, and a list of dynamic
//! archetypes, plus the methods enumerated in
//! `briefs/S4-etch-tree-walking-interpreter.md` Tier 0 ECS extensions —
//! all additive; the S1 comptime path is untouched.
//!
//! The world keeps a flat `AutoHashMapUnmanaged(EntityId, Location)` so that
//! despawn can locate any entity in O(1) and update the mapping for the
//! entity that swap-and-pop moves into the freed slot. No generational
//! indices, no FreeList — both are explicitly out-of-scope for S1.
//! Phase 0.1 will generalise this to multi-archetype storage with proper
//! generational indices; the current shape is the minimum needed to spawn
//! 100 000 entities, iterate them once per frame, and despawn them without
//! leaks (cf. `briefs/S1-mini-ecs.md` Out-of-scope).

const std = @import("std");
const components = @import("components.zig");
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
/// without taking a dependency on `components.zig`.
pub const EntityId = components.EntityId;

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
/// S4 archetypes, the runtime component registry, and the resource
/// store. Owns all entity storage and resolves both comptime and
/// runtime queries.
pub const World = struct {
    // ── S1 comptime path (unchanged) ──
    archetype: Archetype,
    entity_locations: std.AutoHashMapUnmanaged(EntityId, Location),
    next_entity_id: u64,

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
    /// Kept separate from `entity_locations` so the two paths cannot
    /// accidentally collide; ids still share `next_entity_id`.
    dynamic_locations: std.AutoHashMapUnmanaged(EntityId, DynamicLocation),
    /// Resource store keyed by `ComponentId`.
    resources: ResourceStore,

    pub fn init() World {
        return .{
            .archetype = Archetype.init(0),
            .entity_locations = .empty,
            .next_entity_id = 0,
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
        self.* = undefined;
    }

    // ─── S1 comptime API (unchanged) ──────────────────────────────────────

    /// Spawn an entity with the given component values. Returns its id.
    pub fn spawn(
        self: *World,
        gpa: std.mem.Allocator,
        transform: Transform,
        velocity: Velocity,
    ) !EntityId {
        const id: EntityId = self.next_entity_id;
        self.next_entity_id += 1;
        const location = try self.archetype.append(gpa, id, .{ transform, velocity });
        try self.entity_locations.put(gpa, id, location);
        return id;
    }

    /// Despawn an entity. The entity must have been spawned and not yet
    /// despawned (S1 has no generational checks — the caller is responsible).
    /// Despawning an unknown id is a programmer error and panics in every
    /// build mode (Phase 0.1 will replace this with a generational-index
    /// check that returns a dedicated error).
    pub fn despawn(self: *World, id: EntityId) void {
        const location = self.entity_locations.get(id) orelse @panic("despawn of unknown entity id");
        if (self.archetype.removeSwap(location)) |swapped_id| {
            // The entity that was at the last slot has been moved to `location.slot`.
            self.entity_locations.getPtr(swapped_id).?.* = location;
        }
        _ = self.entity_locations.remove(id);
    }

    pub fn entityCount(self: *const World) usize {
        return self.entity_locations.count();
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
    /// of the archetype. Returns the assigned id.
    pub fn spawnDynamic(self: *World, gpa: std.mem.Allocator, component_ids: []const ComponentId) !EntityId {
        const id: EntityId = self.next_entity_id;
        self.next_entity_id += 1;
        const arch = try self.getOrCreateDynamicArchetype(gpa, component_ids);
        const r = try arch.spawnDefault(gpa, id);
        try self.dynamic_locations.put(gpa, id, .{
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
