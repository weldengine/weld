//! Structural-mutation observers, fired during the per-system command-buffer flush.
//!
//! THE DISPATCH POSITION IS THE CONTRACT. `remove_component` and `despawn` fire
//! PRE-apply, which is what lets a callback read the entity's components one last
//! time before the swap-and-pop invalidates the slot; `spawn` and `add_component`
//! fire POST-apply, so `on_add` sees the attached values.
//!
//! An observer MAY record structural mutations into the shared `deferred` buffer,
//! and they are NOT applied re-entrantly: they run at the NEXT flush, before that
//! phase's own buffers. That one flush-point of latency is what guarantees forward
//! progress — no recursive observer loop can stall the engine.

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
///
/// WHICH POINTERS ARE SET IS PER EVENT and a callback must not assume: `on_added`
/// has `new_value` only, `on_removed` `old_value` only, `on_replaced` both,
/// `on_spawned` / `on_despawned` neither and no `component_id`. Each value pointer
/// is `componentSize(component_id)` bytes.
///
/// `world` is safe to READ; a direct write is allowed and discouraged — the
/// `deferred` buffer is where a mutation belongs.
pub const ObserverFn = *const fn (
    ctx: ?*anyopaque,
    world: *World,
    entity: EntityId,
    component_id: ?ComponentId,
    old_value: ?*const anyopaque,
    new_value: ?*const anyopaque,
    deferred: *CommandBuffer,
) anyerror!void;

/// One registered observer: a callback plus its opaque context (E3).
pub const Listener = struct {
    ctx: ?*anyopaque,
    callback: ObserverFn,
};

/// Per-event listener list — a flat `ArrayListUnmanaged` keeps
/// dispatch as `for items |l| try l.callback(...)`.
const Listeners = std.ArrayListUnmanaged(Listener);

/// Ascending-`ComponentId` walk over the UNION of an entity's table and sparse
/// components.
///
/// ONE walk for both directions, never a copy per direction — its whole job is an
/// ORDER, which is exactly what two copies would drift on. Ascending id and NOT the
/// caller's slice order, or the observer order would depend on how someone wrote a
/// spawn literal.
pub const ComponentUnionIter = struct {
    world: *World,
    entity: EntityId,
    table_ids: []const ComponentId,
    ti: usize = 0,
    s_next: ?ComponentId = null,

    pub fn init(world: *World, entity: EntityId) ComponentUnionIter {
        const ids: []const ComponentId = blk: {
            const loc = world.entity_locations.get(entity) orelse break :blk &.{};
            break :blk world.archetypes.items[loc.archetype_idx].component_ids;
        };
        return .{
            .world = world,
            .entity = entity,
            .table_ids = ids,
            .s_next = world.sparse_stores.nextContaining(0, entity),
        };
    }

    /// Both heads are ascending by construction, so taking the smaller yields the
    /// union in ascending id with no allocation and no sort.
    pub fn next(it: *ComponentUnionIter) ?ComponentId {
        const t_cid: ?ComponentId = if (it.ti < it.table_ids.len) it.table_ids[it.ti] else null;
        if (t_cid == null and it.s_next == null) return null;
        const take_table = if (t_cid) |t| (it.s_next == null or t < it.s_next.?) else false;
        if (take_table) {
            it.ti += 1;
            return t_cid.?;
        }
        const sc = it.s_next.?;
        it.s_next = it.world.sparse_stores.nextContaining(sc + 1, it.entity);
        return sc;
    }
};

/// Lives beside the `World` and is consulted at every command-buffer flush.
pub const ObserverRegistry = struct {
    on_spawned: Listeners = .empty,
    on_despawned: Listeners = .empty,
    on_add: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,
    on_remove: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,
    /// `on_replaced[cid]` — fired when `add_component(entity, cid)` lands on an
    /// entity that already has `cid` (E3). Carries old + new values.
    on_replaced: std.AutoHashMapUnmanaged(ComponentId, Listeners) = .empty,

    /// Created LAZILY on first registration, so a path exercising no observer stays
    /// allocation-free.
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

    /// Register an `on_spawned` observer (E3: `ctx` threaded back).
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

    /// Register an `on_replaced` observer for `cid` (E3).
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

    /// Fire `on_spawned` for an already-instantiated entity. The scene loader drives
    /// this in a dedicated SECOND pass, after every loaded entity exists, so the
    /// guarantee "all entities present before any `on_spawned`" holds. Ensures
    /// `deferred` exists first — a null one makes `fireList` early-return. Fires
    /// `on_spawned` ONLY, never `on_add` or `on_replaced`.
    pub fn dispatchOnSpawned(
        self: *ObserverRegistry,
        gpa: std.mem.Allocator,
        world: *World,
        eid: EntityId,
    ) !void {
        self.ensureDeferred(gpa, world);
        try self.fireList(self.on_spawned, world, eid, null, null, null);
    }

    /// Spawn with initial values and fire EXACTLY what a deferred `.spawn` flush
    /// fires — `on_spawned`, then `on_add[cid]` per component — returning the handle,
    /// valid on return. Factored out of `applyWithObservers` so an immediate spawn
    /// that must return a handle shares the ONE observer-firing spawn path.
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
        // The ENTITY's real union, not the caller's slice: the `@requires` closure
        // expands inside the spawn, so an unnamed component still owes its `on_add`.
        var it = ComponentUnionIter.init(world, eid);
        while (it.next()) |cid| {
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

/// Apply one buffer with observers interleaved around each command.
///
/// Each call drains the PREVIOUS flush's observer-issued commands plus the system's
/// own, then stashes newly-issued ones for the next call — the one flush-point of
/// latency, never re-entrancy.
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

    // RAW: no observer dispatch on these, they were observer-issued and recursion is
    // exactly what the deferral exists to prevent.
    if (reg.deferred) |*deferred| {
        for (deferred.commands.items) |c| try applyRawCommand(world, gpa, c);
        deferred.reset();
    }

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
            // The one observer-firing spawn path, shared with `world.spawn_with`.
            _ = try reg.spawnWithObservers(gpa, world, s.component_ids, s.payloads);
        },
        .despawn => |d| {
            // The command's own precondition, checked BEFORE any observer fires:
            // `on_despawned` fires unconditionally, so a double despawn in one tick
            // handed consumers the death of an entity whose despawn then failed. The
            // `on_remove` loop below is naturally empty there, which is why
            // `on_despawned` is the whole of the exposure.
            if (!world.isLive(d.entity)) return error.StaleEntityHandle;
            // Pre-apply, so `old_value` points at the LIVE slot: the components
            // survive until `world.despawn` runs below.
            if (world.entity_locations.get(d.entity) != null) {
                // The SAME walk the spawn direction takes. The archetype signature
                // ALONE is the table half only, and a skipped observer is
                // undetectable by any caller.
                var it = ComponentUnionIter.init(world, d.entity);
                while (it.next()) |cid| {
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
            // Add-on-present is an in-place OVERWRITE, not a migration —
            // `addComponentDynamic` would panic on its already-present assert. The
            // old bytes are captured before the clobber, then `on_replaced` fires.
            if (world.componentBytes(a.entity, a.component_id)) |slot| {
                const list_opt = reg.on_replaced.get(a.component_id);
                // Only when a listener will consume them: a listener-less
                // add-on-present must not pay a `dupe`.
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
                // EVERY COMPONENT THE TRANSACTION ADDS IS NOTIFIED, and that set is
                // not the command's id: `addComponentDynamic` expands the `@requires`
                // closure, so firing for `a.component_id` alone left a requisite
                // added here with no `on_add` at all.
                //
                // The ABSENT set is snapshotted BEFORE the add, so a requisite the
                // entity already carried is not re-notified — an `on_add` for a
                // component that was already there is the same lie in reverse.
                const closure = world.registry.requiresClosure(a.component_id);

                // With an empty closure the notified set is a subset of
                // `{a.component_id}`, so with no listener for that id the loop below
                // fires nothing whatever the presence tests answer — the two paths
                // are fire-for-fire identical here, which is why the fast one may
                // skip straight to the add. Measured: ten sparse adds with neither
                // closure nor listener cost TEN allocator operations against zero.
                if (closure.len == 0 and reg.on_add.get(a.component_id) == null) {
                    return world.addComponentDynamic(gpa, a.entity, a.component_id, a.bytes);
                }

                var pending: std.ArrayListUnmanaged(ComponentId) = .empty;
                defer pending.deinit(gpa);
                try pending.ensureTotalCapacity(gpa, closure.len + 1);
                if (!world.hasComponentDyn(a.entity, a.component_id)) {
                    pending.appendAssumeCapacity(a.component_id);
                }
                for (closure) |cid| {
                    if (cid == a.component_id) continue;
                    if (!world.hasComponentDyn(a.entity, cid)) pending.appendAssumeCapacity(cid);
                }
                // ASCENDING id: the closure's own order is a registry internal, so an
                // observer order resting on it would depend on registration order.
                std.mem.sort(ComponentId, pending.items, {}, std.sort.asc(ComponentId));

                try world.addComponentDynamic(gpa, a.entity, a.component_id, a.bytes);

                for (pending.items) |cid| {
                    // Presence re-read AFTER the add: the command may have been
                    // refused, and an observer describes a state that took place.
                    const bytes = world.componentBytes(a.entity, cid) orelse continue;
                    if (reg.on_add.get(cid)) |list| {
                        try reg.fireList(list, world, a.entity, cid, null, @ptrCast(bytes.ptr));
                    }
                }
            }
        },
        .remove_component => |r| {
            // AN OBSERVER DESCRIBES A STATE THAT HAS TAKEN PLACE, so the command's
            // precondition is checked BEFORE the event. A `@requires` refusal is a
            // silent SKIP inside `removeComponentDynamic`, and firing first handed
            // consumers an `on_removed` for a component that is still there.
            //
            // Returning rather than falling through keeps the skip counted ONCE —
            // the count lives inside `requiresRefusesRemoval`.
            if (world.requiresRefusesRemoval(r.entity, r.component_id, &.{})) return;
            // Pre-apply: observer reads the component value (live slot), THEN
            // the migration drops it.
            if (reg.on_remove.get(r.component_id)) |list| {
                const old_ptr: ?*const anyopaque = if (world.componentBytes(r.entity, r.component_id)) |b| @ptrCast(b.ptr) else null;
                try reg.fireList(list, world, r.entity, r.component_id, old_ptr, null);
            }
            try world.removeComponentDynamic(gpa, r.entity, r.component_id);
        },
        // Tag bit set/clear (E3) — a deferred structural change with no
        // observer hook (tags are not add/remove-component events).
        .set_tag => |t| try world.applyTagMutation(gpa, t.entity, t.tagset_id, t.bit_index, true),
        .clear_tag => |t| try world.applyTagMutation(gpa, t.entity, t.tagset_id, t.bit_index, false),
    }
}

/// RAW, no dispatch: re-firing on observer-issued commands would recurse.
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

const testing = std.testing;

test "ObserverRegistry init/deinit round-trip is leak-free" {
    const gpa = testing.allocator;
    var reg = ObserverRegistry.init();
    defer reg.deinit(gpa);
    try testing.expect(reg.deferred == null);
    try testing.expectEqual(@as(usize, 0), reg.on_spawned.items.len);
}

/// Test-only capture of the old/new component bytes (single `i32`) seen by an
/// observer fire (E3).
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
