//! M0.2 / E3 — public API of the resource subsystem.
//!
//! Resources are singleton instances of POD types — exactly one
//! value of each resource type lives in the world at any given
//! time (cf. `engine-spec.md` §2.9). The implementation routes
//! through the ECS dynamic archetype path: each `setResource(T)`
//! spawns a dedicated entity holding the component `T` plus a
//! `ResourceMarker` marker. The marker keeps the resource's
//! archetype signature distinct from any user-spawned `[T]`
//! archetype, and `Archetype.is_singleton` flips on the
//! resource archetype so user queries never see the entity.
//!
//! Change detection reuses the M0.1 tick-based mechanism:
//! `getResourceMut` returns `world.getMut(T, entity)` which
//! auto-marks `changed_tick = current_tick` on the resource's
//! slot. `resourceChanged(T, since)` reads back that tick.
//!
//! API signature note (vs brief): the brief lists `setResource(world,
//! value)` and `removeResource(world, T)` without an allocator. The
//! underlying ECS write paths (`ensureComponentRegistered`,
//! `spawnDynamicWithValues`, `despawn`) require a `gpa`. The
//! signatures below thread `gpa` through the write surface — read
//! paths stay allocator-free.

const std = @import("std");
const rtti = @import("../rtti/root.zig");
const registry_mod = @import("registry.zig");
const world_mod = @import("../ecs/world.zig");

const TypeId = rtti.TypeId;
const EntityId = registry_mod.EntityId;
const ResourceMarker = registry_mod.ResourceMarker;
const World = world_mod.World;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Errors surfaced by `setResource` / `removeResource`. Read paths
/// return `null` instead of failing through this set.
pub const ResourceError = error{
    /// `spawnDynamicWithValues` failed to allocate the singleton
    /// entity's slot, or an internal hashmap grow failed. Underlying
    /// allocator surfaced.
    OutOfMemory,
    /// Other ECS-internal allocation / identity error propagated from
    /// the world (e.g. a `getMut` / `dynamicLocation` miss on the
    /// freshly-spawned singleton entity).
    EcsError,
    /// `removeResource`'s despawn hit a stale entity handle — the
    /// singleton entity was already despawned out-of-band. Propagated
    /// from `World.despawn` (`WorldError`).
    StaleEntityHandle,
};

/// Collapse an ECS-internal error from the `World` write path into the
/// `ResourceError` contract: `OutOfMemory` passes through; every other
/// allocation / identity error (e.g. `DuplicateComponent` from the
/// component registry) becomes `EcsError`.
fn mapWorldErr(e: anyerror) ResourceError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EcsError,
    };
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Insert or update the singleton resource of type `T`. On the
/// first call for `T`, spawns a dedicated entity holding
/// `[T, ResourceMarker]` and marks its archetype singleton. On
/// subsequent calls, writes the new value through `getMut`
/// (auto-marks `changed_tick`).
pub fn setResource(
    world: *World,
    gpa: std.mem.Allocator,
    value: anytype,
) ResourceError!void {
    const T = @TypeOf(value);
    // Build the RTTI TypeInfo at comptime as a POD gate — fails
    // compilation if `T` is not POD.
    _ = comptime rtti.buildTypeInfo(T, .resource);
    const tid: TypeId = comptime rtti.computeTypeId(T);

    if (world.singleton_resources.lookup(tid)) |eid| {
        // Update path — the entity already exists, just write the
        // new value via the change-detection-aware mutator.
        const ptr = world.getMut(T, eid) orelse return error.EcsError;
        ptr.* = value;
        return;
    }

    // First-time set — register both the resource type and the
    // marker, then spawn the singleton entity.
    const cid_t = world.ensureComponentRegistered(gpa, T) catch |e| return mapWorldErr(e);
    const cid_marker = world.ensureComponentRegistered(gpa, ResourceMarker) catch |e| return mapWorldErr(e);

    var local_value: T = value;
    var marker: ResourceMarker = .{};
    const value_bytes = std.mem.asBytes(&local_value);
    const marker_bytes = std.mem.asBytes(&marker);

    const cids = [_]u32{ cid_t, cid_marker };
    const payloads = [_][]const u8{ value_bytes, marker_bytes };
    const eid = world.spawnDynamicWithValues(gpa, &cids, &payloads) catch |e| return mapWorldErr(e);

    // Mark the resource archetype singleton so user queries skip
    // it (cf. `Query.maybeRescan` + `ComptimeQuery.next` checks).
    const loc = world.dynamicLocation(eid) orelse return error.EcsError;
    world.dynamicArchetype(loc.archetype_idx).is_singleton = true;

    world.singleton_resources.register(gpa, tid, eid) catch |e| return mapWorldErr(e);
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Immutable view of resource `T`. Returns `null` if the resource
/// has not been set or has been removed.
pub fn getResource(world: *const World, comptime T: type) ?*const T {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return null;
    return world.get(T, eid);
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Mutable view of resource `T`. Auto-marks `changed_tick` on the
/// resource's component slot — the next call to
/// `resourceChanged(T, since)` will see the bump. Returns `null` if
/// the resource has not been set.
pub fn getResourceMut(world: *World, comptime T: type) ?*T {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return null;
    return world.getMut(T, eid);
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Returns `true` iff a resource of type `T` is currently set.
pub fn hasResource(world: *const World, comptime T: type) bool {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    return world.singleton_resources.lookup(tid) != null;
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Drop the resource of type `T`. Despawns the singleton entity
/// and clears the `(TypeId → EntityId)` binding. No-op when the
/// resource has not been set.
pub fn removeResource(world: *World, gpa: std.mem.Allocator, comptime T: type) ResourceError!void {
    const tid: TypeId = comptime rtti.computeTypeId(T);
    const eid = world.singleton_resources.lookup(tid) orelse return;
    try world.despawn(gpa, eid);
    world.singleton_resources.unregister(tid);
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Returns `true` iff resource `T`'s `changed_tick` is strictly
/// greater than `since_tick`. Combined with `World.current_tick`
/// progress, lets a consumer detect mutations across frame
/// boundaries (`if (resourceChanged(world, T, system.last_run))
/// { ... }`).
///
/// Returns `false` for absent resources rather than failing — the
/// usual call site is a guard around a read, and "not changed"
/// covers "not present" semantically.
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
