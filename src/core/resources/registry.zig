//! M0.2 / E3 — Tier 0 resource registry (singleton entities).
//!
//! Indexes the world's resource singleton entities by `rtti.TypeId`.
//! Each entry maps a resource type to the `EntityId` that hosts the
//! singleton component, allowing `O(1)` lookup from `setResource` /
//! `getResource` paths.
//!
//! The registry only owns the `(TypeId → EntityId)` map. The actual
//! component storage lives in the world's archetypes — the
//! `Archetype.is_singleton` flag flips on the singleton entity's
//! archetype to keep it out of user queries (cf. `Query.maybeRescan`
//! + `ComptimeQuery.next` filters).
//!
//! Imports are kept narrow on purpose: this file only needs
//! `EntityId` from `entity.zig` to avoid creating a circular import
//! with `world.zig` (which embeds `ResourceRegistry` as a field).

const std = @import("std");
const rtti = @import("../rtti/root.zig");
const entity_mod = @import("../ecs/entity.zig");

/// Stable `rtti.TypeId` keying the resource lookup map.
pub const TypeId = rtti.TypeId;
/// Re-export from the ECS identity store so consumers (the public
/// API in `api.zig`) can address the entity surface through the
/// resource module without reaching into ECS internals.
pub const EntityId = entity_mod.EntityId;

/// Per-world registry of singleton-entity resources. Owns the
/// `(TypeId → EntityId)` map; the underlying component storage lives
/// in the world's archetypes. Lazy — the map only allocates on the
/// first `register` call.
pub const ResourceRegistry = struct {
    singleton_entities: std.AutoHashMapUnmanaged(TypeId, EntityId) = .empty,

    /// Initial empty registry. No allocation until the first
    /// `register` call.
    pub fn init() ResourceRegistry {
        return .{};
    }

    /// Free the hashmap storage. The owning `World.deinit` is
    /// responsible for despawning the resource entities themselves —
    /// the registry only releases its own index.
    pub fn deinit(self: *ResourceRegistry, gpa: std.mem.Allocator) void {
        self.singleton_entities.deinit(gpa);
        self.* = undefined;
    }

    /// Return the entity hosting resource type `tid`, or `null` if
    /// no resource of that type has been set.
    pub fn lookup(self: *const ResourceRegistry, tid: TypeId) ?EntityId {
        return self.singleton_entities.get(tid);
    }

    /// Bind `tid → entity`. Overwrites any prior binding silently
    /// (the `setResource` caller is expected to update-in-place
    /// when an entry already exists rather than re-binding here).
    pub fn register(
        self: *ResourceRegistry,
        gpa: std.mem.Allocator,
        tid: TypeId,
        entity: EntityId,
    ) !void {
        try self.singleton_entities.put(gpa, tid, entity);
    }

    /// Drop the `tid → entity` binding. The caller is responsible
    /// for despawning the entity. No-op when the type is not
    /// registered.
    pub fn unregister(self: *ResourceRegistry, tid: TypeId) void {
        _ = self.singleton_entities.remove(tid);
    }

    /// Number of distinct resource types currently registered.
    pub fn count(self: *const ResourceRegistry) u32 {
        return @intCast(self.singleton_entities.count());
    }
};

/// 1-byte marker component added to every singleton-resource
/// entity. Keeps the resource archetype distinct from any user
/// archetype that happens to contain only the resource type `T` —
/// the archetype signature `[T, ResourceMarker]` cannot collide
/// with a user-spawned `[T]`. Combined with `Archetype.is_singleton`
/// for the query exclusion path.
pub const ResourceMarker = extern struct {
    /// Zero-meaning padding to keep `extern struct` non-empty.
    /// Always written and read as `0`.
    _: u8 = 0,
};
