//! FROZEN — see engine-phase-0-criteria.md C0.5. Every public entry below is.
//!
//! Public API of the resource subsystem — one singleton value per type.
//!
//! Each `setResource(T)` spawns an entity holding `[T, ResourceMarker]`. The marker
//! keeps that signature distinct from a user-spawned `[T]`, and `is_singleton` on the
//! archetype is what hides the entity from user queries — remove either and resources
//! become visible to every query over `T`.

const std = @import("std");
const rtti = @import("../rtti/root.zig");
const registry_mod = @import("registry.zig");
const world_mod = @import("../ecs/world.zig");

const TypeId = rtti.TypeId;
const EntityId = registry_mod.EntityId;
const ResourceMarker = registry_mod.ResourceMarker;
const World = world_mod.World;

/// Errors surfaced by the write paths; read paths return null instead.
pub const ResourceError = error{
    /// The singleton entity's slot, or an internal map grow, failed to allocate.
    OutOfMemory,
    /// Any other ECS identity or allocation error from the world.
    EcsError,
    /// The despawn hit a stale handle — the singleton entity was already gone.
    StaleEntityHandle,
};

/// Collapse a `World` write-path error into the `ResourceError` contract:
/// `OutOfMemory` passes through, everything else becomes `EcsError`.
fn mapWorldErr(e: anyerror) ResourceError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EcsError,
    };
}

/// Insert or update the singleton resource of type `T`.
pub fn setResource(
    world: *World,
    gpa: std.mem.Allocator,
    value: anytype,
) ResourceError!void {
    const T = @TypeOf(value);
    // A POD gate, not dead code: this fails compilation when `T` is not POD.
    _ = comptime rtti.buildTypeInfo(T, .resource);
    const tid: TypeId = comptime rtti.computeTypeId(T);

    if (world.singleton_resources.lookup(tid)) |eid| {
        const ptr = world.getMut(T, eid) orelse return error.EcsError;
        ptr.* = value;
        return;
    }

    const cid_t = world.ensureComponentRegistered(gpa, T) catch |e| return mapWorldErr(e);
    const cid_marker = world.ensureComponentRegistered(gpa, ResourceMarker) catch |e| return mapWorldErr(e);

    var local_value: T = value;
    var marker: ResourceMarker = .{};
    const value_bytes = std.mem.asBytes(&local_value);
    const marker_bytes = std.mem.asBytes(&marker);

    const cids = [_]u32{ cid_t, cid_marker };
    const payloads = [_][]const u8{ value_bytes, marker_bytes };
    const eid = world.spawnDynamicWithValues(gpa, &cids, &payloads) catch |e| return mapWorldErr(e);

    // Without this flag user queries over `T` would see the resource entity.
    const loc = world.dynamicLocation(eid) orelse return error.EcsError;
    world.dynamicArchetype(loc.archetype_idx).is_singleton = true;

    world.singleton_resources.register(gpa, tid, eid) catch |e| return mapWorldErr(e);
}

/// Immutable view of resource `T`, or null when unset.
pub fn getResource(world: *const World, comptime T: type) ?*const T {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return null;
    return world.get(T, eid);
}

/// Mutable view of resource `T`; auto-marks `changed_tick`. Null when unset.
pub fn getResourceMut(world: *World, comptime T: type) ?*T {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return null;
    return world.getMut(T, eid);
}

/// Returns `true` iff a resource of type `T` is currently set.
pub fn hasResource(world: *const World, comptime T: type) bool {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    return world.singleton_resources.lookup(tid) != null;
}

/// Drop resource `T`, despawning its entity. No-op when unset.
pub fn removeResource(world: *World, gpa: std.mem.Allocator, comptime T: type) ResourceError!void {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return;
    try world.despawn(gpa, eid);
    world.singleton_resources.unregister(tid);
}

/// True iff resource `T`'s `changed_tick` exceeds `since_tick`.
///
/// False for an ABSENT resource rather than an error — the call site is a guard
/// around a read, where "not changed" covers "not present".
pub fn resourceChanged(world: *const World, comptime T: type, since_tick: u32) bool {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return false;
    const loc = world.entity_locations.get(eid) orelse return false;
    const cid = world.registry.idOf(@typeName(T)) orelse return false;
    const arch = world.archetypes.items[loc.archetype_idx];
    const col_idx = arch.componentIndex(cid) orelse return false;
    const chunk = arch.chunks.items[loc.chunk_idx];
    const ct = arch.changedTick(chunk, col_idx, loc.slot);
    return ct > since_tick;
}
