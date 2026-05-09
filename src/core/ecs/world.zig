//! S1 root `World` — owns the single `(Transform, Velocity)` archetype and
//! exposes `spawn` / `despawn` / `query`.
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

pub const Transform = components.Transform;
pub const Velocity = components.Velocity;
pub const EntityId = components.EntityId;

pub const archetype_components: []const type = &.{ Transform, Velocity };
pub const Archetype = archetype_mod.Archetype(archetype_components);
pub const Query = query_mod.Query(archetype_components);
pub const Location = archetype_mod.Location;

pub const World = struct {
    archetype: Archetype,
    entity_locations: std.AutoHashMapUnmanaged(EntityId, Location),
    next_entity_id: u64,

    pub fn init() World {
        return .{
            .archetype = Archetype.init(0),
            .entity_locations = .empty,
            .next_entity_id = 0,
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.archetype.deinit(gpa);
        self.entity_locations.deinit(gpa);
        self.* = undefined;
    }

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
    pub fn despawn(self: *World, id: EntityId) void {
        const location = self.entity_locations.get(id) orelse {
            std.debug.assert(false); // unknown entity id
            return;
        };
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
};
