//! Tier 0 resource registry: indexes singleton-entity resources by `rtti.TypeId`.
//!
//! Imports stay narrow: `world.zig` embeds this as a field, so more is a cycle.

const std = @import("std");
const rtti = @import("../rtti/root.zig");
const entity_mod = @import("../ecs/entity.zig");

/// Stable `rtti.TypeId` keying the resource lookup map.
pub const TypeId = rtti.TypeId;
/// Re-export of the ECS `EntityId`, so consumers need not reach into ECS internals.
pub const EntityId = entity_mod.EntityId;

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Per-world index of singleton-entity resources; the components live in archetypes.
pub const ResourceRegistry = struct {
    singleton_entities: std.AutoHashMapUnmanaged(TypeId, EntityId) = .empty,

    /// Initial empty registry; allocates on the first `register`.
    pub fn init() ResourceRegistry {
        return .{};
    }

    /// Free the index ONLY — despawning the resource entities is `World.deinit`'s.
    pub fn deinit(self: *ResourceRegistry, gpa: std.mem.Allocator) void {
        self.singleton_entities.deinit(gpa);
        self.* = undefined;
    }

    /// The entity hosting resource `tid`, or null when none is set.
    pub fn lookup(self: *const ResourceRegistry, tid: TypeId) ?EntityId {
        return self.singleton_entities.get(tid);
    }

    /// Bind `tid` to `entity`, overwriting any prior binding SILENTLY.
    pub fn register(
        self: *ResourceRegistry,
        gpa: std.mem.Allocator,
        tid: TypeId,
        entity: EntityId,
    ) !void {
        try self.singleton_entities.put(gpa, tid, entity);
    }

    /// Drop the binding; the caller despawns the entity. No-op when unregistered.
    pub fn unregister(self: *ResourceRegistry, tid: TypeId) void {
        _ = self.singleton_entities.remove(tid);
    }

    /// Number of distinct resource types currently registered.
    pub fn count(self: *const ResourceRegistry) u32 {
        return @intCast(self.singleton_entities.count());
    }
};

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// 1-byte marker on every singleton-resource entity: the signature
/// `[T, ResourceMarker]` cannot collide with a user-spawned `[T]`.
pub const ResourceMarker = extern struct {
    /// Zero-meaning padding, so the `extern struct` is not empty.
    _: u8 = 0,
};
