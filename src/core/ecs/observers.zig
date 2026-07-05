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
/// Arguments (M1.0.2 E3 — uniform signature carrying a context pointer
/// and old/new value pointers):
/// - `ctx` — opaque per-listener context (e.g. the Etch interpreter's
///    `{ interp, rule_desc_idx }`), threaded back to the callback. `null`
///    for context-free (native) observers.
/// - `world` — the world being mutated (read access only is safe;
///    direct write access is allowed but discouraged — prefer the
///    `deferred` buffer for cmds that should land at the next flush).
/// - `entity` — the entity that triggered the event.
/// - `component_id` — the component involved. Populated for
///    `on_add` / `on_remove` / `on_replaced`; `null` for
///    `on_spawned` / `on_despawned`.
/// - `old_value` — pointer to the pre-mutation component bytes
///    (`componentSize(component_id)` long). Set for `on_remove` and
///    `on_replaced`; `null` otherwise.
/// - `new_value` — pointer to the post-mutation component bytes. Set for
///    `on_add` and `on_replaced`; `null` otherwise.
/// - `deferred` — shared command buffer where observer-issued
///    mutations are queued for the next flush.
///
/// Conventions: `on_added` → `new_value` set, `old_value` null;
/// `on_removed` → `old_value` set, `new_value` null; `on_replaced` →
/// both set; `on_spawned` / `on_despawned` → both null, `component_id` null.
pub const ObserverFn = *const fn (
    ctx: ?*anyopaque,
    world: *World,
    entity: EntityId,
    component_id: ?ComponentId,
    old_value: ?*const anyopaque,
    new_value: ?*const anyopaque,
    deferred: *CommandBuffer,
) anyerror!void;

/// One registered observer: a callback plus its opaque context (M1.0.2 E3).
pub const Listener = struct {
    ctx: ?*anyopaque,
    callback: ObserverFn,
};

/// Per-event listener list — a flat `ArrayListUnmanaged` keeps
/// dispatch as `for items |l| try l.callback(...)`.
const Listeners = std.ArrayListUnmanaged(Listener);

/// Registry holding the four kinds of observer lists. Lives next to
/// the `World` (typically as a field) and is consulted during every
/// command buffer flush.
pub const ObserverRegistry = struct {
    on_spawned: Listeners = .empty,
    on_despawned: Listeners = .empty,
    on_add: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,
    on_remove: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,
    /// `on_replaced[cid]` — fired when `add_component(entity, cid)` lands on an
    /// entity that already has `cid` (M1.0.2 E3). Carries old + new values.
    on_replaced: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,

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

        var rep_it = self.on_replaced.valueIterator();
        while (rep_it.next()) |list| list.deinit(gpa);
        self.on_replaced.deinit(gpa);

        if (self.deferred) |*d| d.deinit();
        self.* = undefined;
    }

    /// Ensure `self.deferred` is initialised. Called lazily by the
    /// observer registration helpers — keeps `init()` allocator-free.
    fn ensureDeferred(self: *ObserverRegistry, gpa: std.mem.Allocator, world: *World) void {
        if (self.deferred == null) self.deferred = CommandBuffer.init(gpa, world);
    }

    /// Register an `on_spawned` observer (M1.0.2 E3: `ctx` threaded back).
    pub fn registerOnSpawned(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        ctx: ?*anyopaque,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        try self.on_spawned.append(gpa, .{ .ctx = ctx, .callback = callback });
    }

    /// Register an `on_despawned` observer.
    pub fn registerOnDespawned(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        ctx: ?*anyopaque,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        try self.on_despawned.append(gpa, .{ .ctx = ctx, .callback = callback });
    }

    /// Register an `on_add` observer for `cid`.
    pub fn registerOnAdd(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        cid: ComponentId,
        ctx: ?*anyopaque,
        callback: ObserverFn,
    ) !void {
        try self.registerInMap(gpa, world, &self.on_add, cid, ctx, callback);
    }

    /// Register an `on_remove` observer for `cid`.
    pub fn registerOnRemove(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        cid: ComponentId,
        ctx: ?*anyopaque,
        callback: ObserverFn,
    ) !void {
        try self.registerInMap(gpa, world, &self.on_remove, cid, ctx, callback);
    }

    /// Register an `on_replaced` observer for `cid` (M1.0.2 E3).
    pub fn registerOnReplaced(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        cid: ComponentId,
        ctx: ?*anyopaque,
        callback: ObserverFn,
    ) !void {
        try self.registerInMap(gpa, world, &self.on_replaced, cid, ctx, callback);
    }

    fn registerInMap(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        map: *std.AutoHashMapUnmanaged(ComponentId, Listeners),
        cid: ComponentId,
        ctx: ?*anyopaque,
        callback: ObserverFn,
    ) !void {
        self.ensureDeferred(gpa, world);
        const entry = try map.getOrPut(gpa, cid);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(gpa, .{ .ctx = ctx, .callback = callback });
    }

    /// Fire `on_spawned` for one already-instantiated entity (M1.0.5 E2). The
    /// scene loader drives the spawn lifecycle in a dedicated second pass —
    /// after every loaded entity exists — rather than through the
    /// command-buffer flush, so the ordering guarantee "all entities present
    /// before any `on_spawned` fires" holds. Ensures the shared `deferred`
    /// buffer exists first (a `null` `deferred` makes `fireList` early-return),
    /// letting an `on_spawned` rule queue structural commands the caller drains
    /// afterwards. Only `on_spawned` is fired — never `on_add`/`on_replaced`.
    pub fn dispatchOnSpawned(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        eid: EntityId,
    ) !void {
        self.ensureDeferred(gpa, world);
        try self.fireList(self.on_spawned, world, eid, null, null, null);
    }

    /// Spawn an entity with initial component values AND fire the exact
    /// observers a deferred `.spawn` flush fires — `on_spawned`, then
    /// `on_add[cid]` per component — returning the new handle. Factored out of
    /// `applyWithObservers`'s `.spawn` arm so an IMMEDIATE spawn that must return
    /// a handle (the Etch `world.spawn_with` test-runner surface, M1.0.15) shares
    /// the one observer-firing spawn path instead of duplicating it. The handle
    /// is valid on return (same tick). Observer-issued structural changes queue
    /// into the shared `deferred` buffer (drained at the next flush / tick).
    pub fn spawnWithObservers(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        component_ids: []const ComponentId,
        payloads: []const []const u8,
    ) !EntityId {
        self.ensureDeferred(gpa, world);
        const eid = try world.spawnDynamicWithValues(gpa, component_ids, payloads);
        try self.fireList(self.on_spawned, world, eid, null, null, null);
        for (component_ids) |cid| {
            if (self.on_add.get(cid)) |list| {
                const new_ptr: ?*const anyopaque = if (world.componentBytes(eid, cid)) |b| @ptrCast(b.ptr) else null;
                try self.fireList(list, world, eid, cid, null, new_ptr);
            }
        }
        return eid;
    }

    fn fireList(
        self: *ObserverRegistry,
        list: Listeners,
        world: *World,
        entity: EntityId,
        component_id: ?ComponentId,
        old_value: ?*const anyopaque,
        new_value: ?*const anyopaque,
    ) !void {
        const deferred = if (self.deferred != null) &self.deferred.? else return;
        for (list.items) |l| {
            try l.callback(l.ctx, world, entity, component_id, old_value, new_value, deferred);
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
            // Shares the returning-eid primitive with the immediate
            // `world.spawn_with` surface (M1.0.15) — one observer-firing spawn
            // path (on_spawned + on_add per component).
            _ = try reg.spawnWithObservers(gpa, world, s.component_ids, s.payloads);
        },
        .despawn => |d| {
            // Pre-apply: fire on_remove[cid] for every component the
            // entity still has, then on_despawned. The observer is
            // free to read the entity's components — they live until
            // we drop into `world.despawn` below, so `old_value` points
            // at the live (pre-destruction) slot.
            if (world.entity_locations.get(d.entity)) |loc| {
                const arch = world.archetypes.items[loc.archetype_idx];
                for (arch.component_ids) |cid| {
                    if (reg.on_remove.get(cid)) |list| {
                        const old_ptr: ?*const anyopaque = if (world.componentBytes(d.entity, cid)) |b| @ptrCast(b.ptr) else null;
                        try reg.fireList(list, world, d.entity, cid, old_ptr, null);
                    }
                }
            }
            try reg.fireList(reg.on_despawned, world, d.entity, null, null, null);
            try world.despawn(gpa, d.entity);
        },
        .add_component => |a| {
            // Replace = add-on-present (M1.0.2 E3): if the entity already has
            // the component, this is an in-place overwrite, not a migration —
            // `addComponentDynamic` would panic on the already-present assert.
            // Capture the old bytes before the overwrite (storage is clobbered),
            // overwrite, then fire `on_replaced[cid]` with old + new. Otherwise
            // it is a genuine add: migrate, then fire `on_add[cid]` with new.
            if (world.componentBytes(a.entity, a.component_id)) |slot| {
                const list_opt = reg.on_replaced.get(a.component_id);
                // Capture the old bytes ONLY when an `on_replaced` listener will
                // consume them — otherwise the shared Tier-0 path stays alloc-free
                // (a listener-less add-on-present must not pay a `dupe`).
                const old_copy: ?[]u8 = if (list_opt != null) try gpa.dupe(u8, slot) else null;
                defer if (old_copy) |oc| gpa.free(oc);
                // The in-place overwrite + change-mark are UNCONDITIONAL — the
                // add-on-present semantics do not depend on a listener.
                @memcpy(slot, a.bytes);
                world.markComponentChangedDyn(a.entity, a.component_id);
                if (list_opt) |list| {
                    const old_ptr: *const anyopaque = @ptrCast(old_copy.?.ptr);
                    const new_ptr: *const anyopaque = @ptrCast(slot.ptr);
                    try reg.fireList(list, world, a.entity, a.component_id, old_ptr, new_ptr);
                }
            } else {
                try world.addComponentDynamic(gpa, a.entity, a.component_id, a.bytes);
                if (reg.on_add.get(a.component_id)) |list| {
                    const new_ptr: ?*const anyopaque = if (world.componentBytes(a.entity, a.component_id)) |b| @ptrCast(b.ptr) else null;
                    try reg.fireList(list, world, a.entity, a.component_id, null, new_ptr);
                }
            }
        },
        .remove_component => |r| {
            // Pre-apply: observer reads the component value (live slot), THEN
            // the migration drops it.
            if (reg.on_remove.get(r.component_id)) |list| {
                const old_ptr: ?*const anyopaque = if (world.componentBytes(r.entity, r.component_id)) |b| @ptrCast(b.ptr) else null;
                try reg.fireList(list, world, r.entity, r.component_id, old_ptr, null);
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

// ─── M1.0.2 E3 — replace detection + old-value capture ─────────────────────

/// Test-only capture of the old/new component bytes (single `i32`) seen by an
/// observer fire (M1.0.2 E3).
const E3Capture = struct {
    var fired: u32 = 0;
    var old: i32 = 0;
    var new: i32 = 0;
    var saw_old: bool = false;
    var saw_new: bool = false;
    fn reset() void {
        fired = 0;
        old = 0;
        new = 0;
        saw_old = false;
        saw_new = false;
    }
};

fn e3CaptureObserver(
    _: ?*anyopaque,
    _: *World,
    _: EntityId,
    _: ?ComponentId,
    old_value: ?*const anyopaque,
    new_value: ?*const anyopaque,
    _: *CommandBuffer,
) anyerror!void {
    E3Capture.fired += 1;
    if (old_value) |p| {
        E3Capture.saw_old = true;
        E3Capture.old = @as(*const i32, @ptrCast(@alignCast(p))).*;
    }
    if (new_value) |p| {
        E3Capture.saw_new = true;
        E3Capture.new = @as(*const i32, @ptrCast(@alignCast(p))).*;
    }
}

fn e3RegisterRawI32(gpa: std.mem.Allocator, world: *World, name: []const u8) !ComponentId {
    return try world.registry.registerComponentRaw(gpa, .{
        .name = name,
        .size = 4,
        .alignment = 4,
        .default_bytes = &[_]u8{ 0, 0, 0, 0 },
        .fields = &.{},
    });
}

test "add on entity already having the component fires on_replaced with old and new (M1.0.2 E3)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const cid = try e3RegisterRawI32(gpa, &world, "Mark");
    var v7: i32 = 7;
    const e = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{cid}, &[_][]const u8{std.mem.asBytes(&v7)});

    E3Capture.reset();
    try world.observer_registry.registerOnReplaced(gpa, &world, cid, null, &e3CaptureObserver);

    // `add_component` on an entity that ALREADY has the component = replace.
    var v42: i32 = 42;
    const c: Command = .{ .add_component = .{ .entity = e, .component_id = cid, .bytes = std.mem.asBytes(&v42) } };
    try applyWithObservers(c, &world.observer_registry, &world, gpa);

    try testing.expectEqual(@as(u32, 1), E3Capture.fired);
    try testing.expect(E3Capture.saw_old and E3Capture.saw_new);
    try testing.expectEqual(@as(i32, 7), E3Capture.old);
    try testing.expectEqual(@as(i32, 42), E3Capture.new);
    // The slot now holds the new value (in-place overwrite, no migration).
    var stored: i32 = 0;
    @memcpy(std.mem.asBytes(&stored), world.componentBytes(e, cid).?[0..4]);
    try testing.expectEqual(@as(i32, 42), stored);
}

test "on_removed receives the pre-removal value (M1.0.2 E3)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Two components so the entity survives the remove (the source archetype
    // must keep >= 1 component — `removeComponentDynamic` asserts len >= 2).
    const keep = try e3RegisterRawI32(gpa, &world, "Keep");
    const drop = try e3RegisterRawI32(gpa, &world, "Drop");
    var kv: i32 = 1;
    var dv: i32 = 99;
    const e = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{ keep, drop }, &[_][]const u8{ std.mem.asBytes(&kv), std.mem.asBytes(&dv) });

    E3Capture.reset();
    try world.observer_registry.registerOnRemove(gpa, &world, drop, null, &e3CaptureObserver);

    const c: Command = .{ .remove_component = .{ .entity = e, .component_id = drop } };
    try applyWithObservers(c, &world.observer_registry, &world, gpa);

    try testing.expectEqual(@as(u32, 1), E3Capture.fired);
    try testing.expect(E3Capture.saw_old and !E3Capture.saw_new); // on_removed: old only
    try testing.expectEqual(@as(i32, 99), E3Capture.old); // the pre-removal value
    try testing.expect(world.componentBytes(e, drop) == null); // component gone
}

// ─── M1.0.5 E2 — two-phase on_spawned dispatch entry ───────────────────────

const SpawnCounter = struct {
    var count: u32 = 0;
    fn reset() void {
        count = 0;
    }
};

fn spawnCountObserver(
    _: ?*anyopaque,
    _: *World,
    _: EntityId,
    _: ?ComponentId,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: *CommandBuffer,
) anyerror!void {
    SpawnCounter.count += 1;
}

test "dispatchOnSpawned fires on_spawned once for an already-spawned entity (M1.0.5 E2)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const cid = try e3RegisterRawI32(gpa, &world, "Tag");
    SpawnCounter.reset();
    try world.registerOnSpawned(gpa, null, &spawnCountObserver);

    // Direct spawn does NOT fire observers (only a cmd-buffer flush or this
    // explicit dispatch does) — the counter is still 0 right after spawning.
    var v: i32 = 1;
    const e = try world.spawnDynamicWithValues(gpa, &[_]ComponentId{cid}, &[_][]const u8{std.mem.asBytes(&v)});
    try testing.expectEqual(@as(u32, 0), SpawnCounter.count);

    try world.dispatchOnSpawned(gpa, e);
    try testing.expectEqual(@as(u32, 1), SpawnCounter.count);
    // `dispatchOnSpawned` lazily created the shared deferred buffer.
    try testing.expect(world.observer_registry.deferred != null);
}
