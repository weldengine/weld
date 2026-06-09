//! M0.1 / E6 — structural mutation observers.
//!
//! Hooks that fire during the per-system command-buffer flush, in
//! lock-step with the four deferrable mutations:
//!
//! - `on_spawned` (global, one list)
//! - `on_despawned` (global, one list)
//! - `on_add[ComponentId]` (per-component, hash-keyed)
//! - `on_remove[ComponentId]` (per-component, hash-keyed)
//!
//! Dispatch timing relative to each command (per brief E6):
//!
//! | Command            | Pre-apply observers              | Post-apply observers       |
//! |--------------------|----------------------------------|----------------------------|
//! | `spawn`            | —                                | on_spawned + on_add[cid]*  |
//! | `add_component`    | —                                | on_add[cid]                |
//! | `remove_component` | on_remove[cid]                   | —                          |
//! | `despawn`          | on_remove[cid]* + on_despawned   | —                          |
//!
//! The pre-apply position for remove / despawn is critical: it lets
//! `on_despawned` callbacks read the entity's components one last
//! time before the swap-and-pop invalidates the slot. The post-apply
//! position for spawn / add lets `on_add` see the newly-attached
//! component values.
//!
//! Re-entrancy contract (brief E6): observers MAY record structural
//! mutations through the shared deferred command buffer
//! (`ObserverRegistry.deferred`), but those mutations are NOT
//! applied re-entrantly during the current flush. They run at the
//! NEXT phase boundary's flush, before that phase's own system cmd
//! buffers. This guarantees forward progress: no recursive observer
//! loop can stall the engine.

const std = @import("std");
const world_mod = @import("world.zig");
const registry_mod = @import("registry.zig");
const command_buffer_mod = @import("command_buffer.zig");

const World = world_mod.World;
const EntityId = world_mod.EntityId;
const ComponentId = registry_mod.ComponentId;
const CommandBuffer = command_buffer_mod.CommandBuffer;
const Command = command_buffer_mod.Command;

/// Callback fired when a structural mutation triggers an observer.
/// Arguments:
/// - `world` — the world being mutated (read access only is safe;
///    direct write access is allowed but discouraged — prefer the
///    `deferred` buffer for cmds that should land at the next flush).
/// - `entity` — the entity that triggered the event.
/// - `component_id` — the component involved. Populated for
///    `on_add` / `on_remove`; `null` for `on_spawned` / `on_despawned`.
/// - `deferred` — shared command buffer where observer-issued
///    mutations are queued for the next flush.
pub const ObserverFn = *const fn (
    world: *World,
    entity: EntityId,
    component_id: ?ComponentId,
    deferred: *CommandBuffer,
) anyerror!void;

/// Per-event callback list — a flat `ArrayListUnmanaged` keeps
/// dispatch as `for items |f| try f(...)`.
const Listeners = std.ArrayListUnmanaged(ObserverFn);

/// Registry holding the four kinds of observer lists. Lives next to
/// the `World` (typically as a field) and is consulted during every
/// command buffer flush.
pub const ObserverRegistry = struct {
    on_spawned: Listeners = .empty,
    on_despawned: Listeners = .empty,
    on_add: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,
    on_remove: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,

    /// Shared deferred buffer for observer-issued cmds. Created
    /// lazily on first observer registration so test paths that do
    /// not exercise observers stay alloc-free.
    deferred: ?CommandBuffer = null,

    pub fn init() ObserverRegistry {
        return .{};
    }

    pub fn deinit(self: *ObserverRegistry, gpa: std.mem.Allocator) void {
        self.on_spawned.deinit(gpa);
        self.on_despawned.deinit(gpa);

        var add_it = self.on_add.valueIterator();
        while (add_it.next()) |list| list.deinit(gpa);
        self.on_add.deinit(gpa);

        var rm_it = self.on_remove.valueIterator();
        while (rm_it.next()) |list| list.deinit(gpa);
        self.on_remove.deinit(gpa);

        if (self.deferred) |*d| d.deinit();
        self.* = undefined;
    }

    /// Ensure `self.deferred` is initialised. Called lazily by the
    /// observer registration helpers — keeps `init()` allocator-free.
    fn ensureDeferred(self: *ObserverRegistry, gpa: std.mem.Allocator, world: *World) void {
        if (self.deferred == null) self.deferred = CommandBuffer.init(gpa, world);
    }

    /// Register an `on_spawned` observer.
    pub fn registerOnSpawned(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        try self.on_spawned.append(gpa, callback);
    }

    /// Register an `on_despawned` observer.
    pub fn registerOnDespawned(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        try self.on_despawned.append(gpa, callback);
    }

    /// Register an `on_add` observer for `cid`.
    pub fn registerOnAdd(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        cid: ComponentId,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        const entry = try self.on_add.getOrPut(gpa, cid);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(gpa, callback);
    }

    /// Register an `on_remove` observer for `cid`.
    pub fn registerOnRemove(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        cid: ComponentId,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        const entry = try self.on_remove.getOrPut(gpa, cid);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(gpa, callback);
    }

    fn fireList(
        self: *ObserverRegistry,
        list: Listeners,
        world: *World,
        entity: EntityId,
        component_id: ?ComponentId,
    ) !void {
        const deferred = if (self.deferred != null) &self.deferred.? else return;
        for (list.items) |f| {
            try f(world, entity, component_id, deferred);
        }
    }
};

// ─── Flush orchestrator ───────────────────────────────────────────────────

/// Apply a single command buffer with observer dispatch interleaved
/// between each command's apply step. After the loop, also flush the
/// registry's `deferred` buffer (the cmds queued by observers during
/// THIS flush stay deferred — they apply at the NEXT call to
/// `flushWithObservers` on a subsequent phase, NOT now).
///
/// In other words: each call to `flushWithObservers` drains the
/// **previous** flush's deferred cmds + the system's own cmds, then
/// stashes new observer-issued cmds into `registry.deferred` for the
/// next call. This is the "1 flush-point latency" semantic from the
/// brief.
pub fn flushWithObservers(
    cmd: *CommandBuffer,
    registry: ?*ObserverRegistry,
) !void {
    if (registry == null) {
        try cmd.flush();
        return;
    }
    const reg = registry.?;
    const world = cmd.world;
    const gpa = cmd.gpa;

    // First — drain the previous flush's queued observer cmds (raw,
    // no observer dispatch on these, since they were observer-issued
    // and we do not want recursion).
    if (reg.deferred) |*deferred| {
        for (deferred.commands.items) |c| try applyRawCommand(world, gpa, c);
        deferred.reset();
    }

    // Then — apply this system's cmds with observers dispatched
    // around each one. Observers may queue more cmds into
    // `reg.deferred` for the next flush.
    for (cmd.commands.items) |c| {
        try applyWithObservers(c, reg, world, gpa);
    }
    cmd.reset();
}

/// Apply a single command + dispatch observers around it. Used by
/// `flushWithObservers`; exposed at module scope for the inline tests.
pub fn applyWithObservers(
    c: Command,
    reg: *ObserverRegistry,
    world: *World,
    gpa: std.mem.Allocator,
) !void {
    switch (c) {
        .spawn => |s| {
            const eid = try world.spawnDynamicWithValues(gpa, s.component_ids, s.payloads);
            try reg.fireList(reg.on_spawned, world, eid, null);
            for (s.component_ids) |cid| {
                if (reg.on_add.get(cid)) |list| {
                    try reg.fireList(list, world, eid, cid);
                }
            }
        },
        .despawn => |d| {
            // Pre-apply: fire on_remove[cid] for every component the
            // entity still has, then on_despawned. The observer is
            // free to read the entity's components — they live until
            // we drop into `world.despawn` below.
            if (world.entity_locations.get(d.entity)) |loc| {
                const arch = world.archetypes.items[loc.archetype_idx];
                for (arch.component_ids) |cid| {
                    if (reg.on_remove.get(cid)) |list| {
                        try reg.fireList(list, world, d.entity, cid);
                    }
                }
            }
            try reg.fireList(reg.on_despawned, world, d.entity, null);
            try world.despawn(gpa, d.entity);
        },
        .add_component => |a| {
            try world.addComponentDynamic(gpa, a.entity, a.component_id, a.bytes);
            if (reg.on_add.get(a.component_id)) |list| {
                try reg.fireList(list, world, a.entity, a.component_id);
            }
        },
        .remove_component => |r| {
            // Pre-apply: observer reads the component value, THEN
            // the migration drops it.
            if (reg.on_remove.get(r.component_id)) |list| {
                try reg.fireList(list, world, r.entity, r.component_id);
            }
            try world.removeComponentDynamic(gpa, r.entity, r.component_id);
        },
        // Tag bit set/clear (M0.8 E3) — a deferred structural change with no
        // observer hook (tags are not add/remove-component events).
        .set_tag => |t| try world.applyTagMutation(gpa, t.entity, t.tagset_id, t.bit_index, true),
        .clear_tag => |t| try world.applyTagMutation(gpa, t.entity, t.tagset_id, t.bit_index, false),
    }
}

/// Raw apply without observer dispatch — used to drain the previous
/// flush's deferred buffer (those cmds were already "observer-issued"
/// and re-firing on them would create recursion).
fn applyRawCommand(world: *World, gpa: std.mem.Allocator, c: Command) !void {
    switch (c) {
        .spawn => |s| {
            _ = try world.spawnDynamicWithValues(gpa, s.component_ids, s.payloads);
        },
        .despawn => |d| try world.despawn(gpa, d.entity),
        .add_component => |a| try world.addComponentDynamic(gpa, a.entity, a.component_id, a.bytes),
        .remove_component => |r| try world.removeComponentDynamic(gpa, r.entity, r.component_id),
        .set_tag => |t| try world.applyTagMutation(gpa, t.entity, t.tagset_id, t.bit_index, true),
        .clear_tag => |t| try world.applyTagMutation(gpa, t.entity, t.tagset_id, t.bit_index, false),
    }
}

// ─── inline tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "ObserverRegistry init/deinit round-trip is leak-free" {
    const gpa = testing.allocator;
    var reg = ObserverRegistry.init();
    defer reg.deinit(gpa);
    try testing.expect(reg.deferred == null);
    try testing.expectEqual(@as(usize, 0), reg.on_spawned.items.len);
}
