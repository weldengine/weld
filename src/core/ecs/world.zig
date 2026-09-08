//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Tier 0 root `World`. `archetypes` holds each archetype as a STABLE `*Archetype`,
//! so an id survives a reallocation, and `archetype_by_signature` keys on the
//! SORTED byte view of the id list — which is what lets a transition find its
//! target without rescanning.

const std = @import("std");
const components = @import("components.zig");
const entity_mod = @import("entity.zig");
const archetype_mod = @import("archetype.zig");
const query_mod = @import("query.zig");
const chunk_mod = @import("chunk.zig");
const tick_mod = @import("tick.zig");

const registry_mod = @import("registry.zig");
const resources_mod = @import("resources.zig");
const observers_mod = @import("observers.zig");
const singleton_resources_mod = @import("../resources/registry.zig");
// A direct field on `World`, like `singleton_resources` below.
const events_bus_mod = @import("../events/bus.zig");
// `World` owns the uniform decref walk — see `releaseResourcePayloads`.
const persistent = @import("../memory/persistent.zig");
// The second storage backend. Nothing below `world.zig` knows there are two.
const sparse_mod = @import("sparse_storage.zig");

/// Re-export so a consumer need not import `components.zig`.
pub const Transform = components.Transform;
/// Public surface mirror of `Transform`, same rationale.
pub const Velocity = components.Velocity;
/// Re-export; the same packed `(index, generation)` shape as in `entity.zig`.
pub const EntityId = components.EntityId;
/// Re-export so a consumer need not reach into `entity.zig`.
pub const WorldError = entity_mod.WorldError;
/// The canonical unfiltered query, so a caller can declare typed `*Chunk` bodies
/// without spelling the comptime filter tuple.
pub const Query = query_mod.Query(&.{ Transform, Velocity }, .{});
/// Re-export so the Etch interpreter, holding ids and not types, can name it.
pub const DynamicQuery = query_mod.DynamicQuery;
/// Re-export, so nothing needs the deprecated `archetype_dynamic` shim.
pub const Archetype = archetype_mod.Archetype;
/// Public alias for the byte-level chunk.
pub const Chunk = chunk_mod.Chunk;
/// Canonical entity location — `(archetype_idx, chunk_idx, slot)`.
pub const Location = archetype_mod.Location;
/// Stable archetype handle (index into `World.archetypes`).
pub const ArchetypeId = archetype_mod.ArchetypeId;
/// Deprecated alias, still imported by the Etch bridge and the demos.
pub const DynamicLocation = Location;
/// Re-export for a caller driving the change-detection sidecars.
pub const Tick = tick_mod.Tick;

const Registry = registry_mod.Registry;
const ComponentId = registry_mod.ComponentId;
const ComponentDesc = registry_mod.ComponentDesc;
const FieldDesc = registry_mod.FieldDesc;
const FieldKind = registry_mod.FieldKind;
const ResourceStore = resources_mod.ResourceStore;
const EntityIdentityStore = entity_mod.EntityIdentityStore;

/// A Tier-0 function pointer the Etch bridge registers; the scene loader fires it
/// after adding an extension's components, with the cooked `on_attach` source text.
/// The seam FIRES and never executes — `loader.zig` reaches no VM.
pub const ExtensionAttachFn = *const fn (
    ctx: ?*anyopaque,
    world: *World,
    entity: EntityId,
    extension_name: []const u8,
    on_attach_text: ?[]const u8,
) anyerror!void;

/// A registered `on_attach` callback + its opaque context.
const AttachHook = struct { ctx: ?*anyopaque, func: ExtensionAttachFn };

/// Mirror of `ExtensionAttachFn`, fired by the runtime deactivate path BEFORE the
/// extension's components are removed, so the hook still sees them. Never at load.
pub const ExtensionDetachFn = *const fn (
    ctx: ?*anyopaque,
    world: *World,
    entity: EntityId,
    extension_name: []const u8,
    on_detach_text: ?[]const u8,
) anyerror!void;

/// A registered `on_detach` callback + its opaque context.
const DetachHook = struct { ctx: ?*anyopaque, func: ExtensionDetachFn };

/// Top-level ECS world — single archetype list, shared identity, shared
/// registry, shared resources.
pub const World = struct {
    // ── Shared identity ──
    /// ONE store, which is what keeps an `EntityId`'s two halves unique world-wide.
    identity: EntityIdentityStore,

    // ── Change detection ──
    /// Bumped by `beginFrame`, written into every spawn, migration and `getMut`
    /// auto-mark, and read by `Query.last_run_tick` comparisons.
    current_tick: Tick,

    // ── Component metadata + storage ──
    /// Assigns ids on first registration and caches size, alignment and defaults.
    registry: Registry,
    /// Stable `*Archetype` entries, so a raw archetype id survives a reallocation.
    archetypes: std.ArrayListUnmanaged(*Archetype),
    /// The key BYTES view the archetype's own `component_ids` slice, so the key's
    /// lifetime is the archetype's.
    archetype_by_signature: std.StringHashMapUnmanaged(ArchetypeId),
    /// Single `EntityId → Location` map covering every spawn path.
    entity_locations: std.AutoHashMapUnmanaged(EntityId, Location),

    /// The RUNTIME, `ComponentId`-keyed store — the backend Etch requires, neither
    /// the interpreter nor the codegen having a comptime type to hand a typed API.
    resources: ResourceStore,

    /// The comptime-`TypeId`-keyed singleton-entity registry, and the only path with
    /// query exclusion, resources being real entities. NOT duplication of
    /// `resources` above: two models for two disjoint consumers, and BOTH are frozen.
    singleton_resources: singleton_resources_mod.ResourceRegistry = .{},

    /// Owns the per-event-type queues; the scheduler drains them at the boundaries.
    event_bus: events_bus_mod.EventBus = .{},

    /// LAZY-init'd by the first `registerOn*`, so a world with no observer pays
    /// nothing.
    observer_registry: observers_mod.ObserverRegistry = .{},

    /// The seam `loader.zig` goes through instead of reaching the Etch VM. It only
    /// FIRES whatever callback is registered; execution lives in that callback.
    attach_hook: ?AttachHook = null,

    /// Mirror of `attach_hook`. `null` until registered, and last wins.
    detach_hook: ?DetachHook = null,

    /// Entity → the OWNED copies of its active extension names, in activation
    /// order. Freed in `deinit`, and NOT serialized: load rebuilds it through the
    /// same path that runtime activation uses.
    entity_extensions: std.AutoHashMapUnmanaged(EntityId, std.ArrayListUnmanaged([]const u8)) = .empty,

    /// One slot per `ComponentId` declared `.sparse`. Defaulted and NOT in `init()`,
    /// so a world registering no sparse component allocates no slot. The mode is a
    /// property of the RUNTIME REGISTRY and never of an entity's on-disk identity.
    sparse_stores: sparse_mod.SparseStores = .{},

    /// How many `@requires` removals were SKIPPED this tick.
    ///
    /// On `World` and not on the Etch report, a Zig system being able to refuse as
    /// readily as a rule. Per TICK, and cleared at BOTH boundaries — see
    /// `resetTickObservations`.
    requires_removals_skipped: u32 = 0,
    /// So the log line NAMES one rather than only counting.
    first_requires_skip: ?ComponentId = null,

    pub fn init() World {
        return .{
            .identity = EntityIdentityStore.init(),
            .current_tick = tick_mod.initial_tick,
            .registry = Registry.init(),
            .archetypes = .empty,
            .archetype_by_signature = .empty,
            .entity_locations = .empty,
            .resources = ResourceStore.init(),
            .singleton_resources = singleton_resources_mod.ResourceRegistry.init(),
            .event_bus = events_bus_mod.EventBus.init(),
            .observer_registry = observers_mod.ObserverRegistry.init(),
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        for (self.archetypes.items) |a| {
            a.deinit(gpa);
            gpa.destroy(a);
        }
        self.archetypes.deinit(gpa);
        self.archetype_by_signature.deinit(gpa);
        self.sparse_stores.deinit(gpa);
        self.entity_locations.deinit(gpa);
        // Reclaim resource-owned persistent payloads (strings, collections)
        // BEFORE freeing the byte buffers (C4). Idempotent — a no-op
        // when an interpreter already ran this in its own deinit.
        self.releaseResourcePayloads(gpa);
        self.resources.deinit(gpa);
        self.singleton_resources.deinit(gpa);
        self.event_bus.deinit(gpa);
        self.registry.deinit(gpa);
        self.identity.deinit(gpa);
        self.observer_registry.deinit(gpa);
        {
            // Free each entity's owned extension-name copies + its list.
            var it = self.entity_extensions.valueIterator();
            while (it.next()) |list| {
                for (list.items) |name| gpa.free(name);
                list.deinit(gpa);
            }
            self.entity_extensions.deinit(gpa);
        }
        self.* = undefined;
    }

    /// Register an `on_spawned` observer (E3: `ctx` threaded back to the
    /// callback; native callers pass `null`).
    pub fn registerOnSpawned(
        self: *World,
        gpa: std.mem.Allocator,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        try self.observer_registry.registerOnSpawned(gpa, self, ctx, callback);
    }

    /// Register an `on_despawned` observer.
    pub fn registerOnDespawned(
        self: *World,
        gpa: std.mem.Allocator,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        try self.observer_registry.registerOnDespawned(gpa, self, ctx, callback);
    }

    /// Register an `on_add` observer for component `T`.
    pub fn registerOnAdd(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnAdd(gpa, self, cid, ctx, callback);
    }

    /// Register an `on_remove` observer for component `T`.
    pub fn registerOnRemove(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnRemove(gpa, self, cid, ctx, callback);
    }

    /// Fires when `T` is added to an entity that ALREADY has it.
    pub fn registerOnReplaced(
        self: *World,
        gpa: std.mem.Allocator,
        comptime T: type,
        ctx: ?*anyopaque,
        callback: observers_mod.ObserverFn,
    ) !void {
        const cid = try self.ensureRegistered(gpa, T);
        try self.observer_registry.registerOnReplaced(gpa, self, cid, ctx, callback);
    }

    /// Fire `on_spawned` for an already-spawned entity. The loader instantiates
    /// with `spawnDynamicWithValues`, which fires NOTHING, then dispatches here in a
    /// second pass — so every loaded entity exists before any `on_spawned` runs.
    pub fn dispatchOnSpawned(self: *World, gpa: std.mem.Allocator, eid: EntityId) !void {
        try self.observer_registry.dispatchOnSpawned(gpa, self, eid);
    }

    /// Immediate spawn firing exactly what a deferred `.spawn` flush fires, and
    /// returning the handle. Backs the Etch `world.spawn_with` surface.
    pub fn spawnWithObservers(
        self: *World,
        gpa: std.mem.Allocator,
        component_ids: []const ComponentId,
        payloads: []const []const u8,
    ) !EntityId {
        return self.observer_registry.spawnWithObservers(gpa, self, component_ids, payloads);
    }

    /// ONE hook per world; the last registration wins.
    pub fn registerOnAttach(self: *World, ctx: ?*anyopaque, callback: ExtensionAttachFn) void {
        self.attach_hook = .{ .ctx = ctx, .func = callback };
    }

    /// Fire the seam after the extension's components are added, with the cooked
    /// text or `null`. A no-op with no hook registered; the callback does the work.
    pub fn dispatchOnAttach(self: *World, entity: EntityId, extension_name: []const u8, on_attach_text: ?[]const u8) anyerror!void {
        if (self.attach_hook) |h| try h.func(h.ctx, self, entity, extension_name, on_attach_text);
    }

    /// ONE hook per world; the last registration wins.
    pub fn registerOnDetach(self: *World, ctx: ?*anyopaque, callback: ExtensionDetachFn) void {
        self.detach_hook = .{ .ctx = ctx, .func = callback };
    }

    /// Called BEFORE the extension's components are removed, so the hook still sees
    /// them. A no-op with no hook registered.
    pub fn dispatchOnDetach(self: *World, entity: EntityId, extension_name: []const u8, on_detach_text: ?[]const u8) anyerror!void {
        if (self.detach_hook) |h| try h.func(h.ctx, self, entity, extension_name, on_detach_text);
    }

    /// Records an OWNED copy. A name already present is not duplicated — the
    /// activate path refuses a re-activation on component conflict first.
    pub fn addEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8) !void {
        const gop = try self.entity_extensions.getOrPut(gpa, entity);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try gop.value_ptr.append(gpa, owned);
    }

    /// Reserve what a following `commitEntityExtension` needs, so that commit is
    /// INFALLIBLE. No observable mutation: it may materialise an EMPTY entry, which
    /// reads as "no extensions", so an aborting caller changes nothing.
    pub fn reserveEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8) ![]u8 {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.entity_extensions.ensureUnusedCapacity(gpa, 1);
        const gop = self.entity_extensions.getOrPutAssumeCapacity(entity);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.ensureUnusedCapacity(gpa, 1);
        return owned;
    }

    /// Infallibly record what `reserveEntityExtension` reserved, TAKING OWNERSHIP of
    /// `owned` — which the caller must not touch afterwards, freed here on the
    /// belt-and-braces dedup path.
    pub fn commitEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, owned: []u8) void {
        const list = self.entity_extensions.getPtr(entity).?; // reserved above
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, owned)) {
                gpa.free(owned);
                return;
            }
        }
        list.appendAssumeCapacity(owned);
    }

    /// Frees the owned copy and drops the map entry once the set empties.
    pub fn removeEntityExtension(self: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8) void {
        const list = self.entity_extensions.getPtr(entity) orelse return;
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (std.mem.eql(u8, list.items[i], name)) {
                gpa.free(list.items[i]);
                _ = list.orderedRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            list.deinit(gpa);
            _ = self.entity_extensions.remove(entity);
        }
    }

    /// whether `name` is currently active on `entity`.
    pub fn hasEntityExtension(self: *const World, entity: EntityId, name: []const u8) bool {
        const list = self.entity_extensions.getPtr(entity) orelse return false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }

    /// BORROWED view in activation order — valid until the set is next mutated.
    pub fn entityExtensions(self: *const World, entity: EntityId) []const []const u8 {
        const list = self.entity_extensions.getPtr(entity) orelse return &.{};
        return list.items;
    }

    /// Called from `despawn`, so a despawned entity leaves no name copies stranded
    /// in `entity_extensions` until `deinit`.
    fn purgeEntityExtensions(self: *World, gpa: std.mem.Allocator, entity: EntityId) void {
        if (self.entity_extensions.fetchRemove(entity)) |kv| {
            var list = kv.value;
            for (list.items) |name| gpa.free(name);
            list.deinit(gpa);
        }
    }

    /// Forwarded straight to the `Registry`.
    pub fn registerComponentRaw(self: *World, gpa: std.mem.Allocator, desc: ComponentDesc) !ComponentId {
        return try self.registry.registerComponentRaw(gpa, desc);
    }

    /// The descriptor is derived from `@typeInfo(T)`.
    pub fn registerComponent(self: *World, gpa: std.mem.Allocator, comptime T: type) !ComponentId {
        return try self.registry.registerComponent(gpa, T);
    }

    pub fn componentId(self: *const World, name: []const u8) ?ComponentId {
        return self.registry.idOf(name);
    }

    /// Public alias of `ensureRegistered`, so the scheduler resolves access
    /// descriptors without a private symbol. Idempotent.
    pub fn ensureComponentRegistered(self: *World, gpa: std.mem.Allocator, comptime T: type) !ComponentId {
        return try self.ensureRegistered(gpa, T);
    }

    /// Idempotent. BYPASSES the `FieldKind`-driven path: the typed spawn surface
    /// needs only size, alignment and defaults, and `Transform`/`Velocity` carry
    /// array fields that `FieldKind` deliberately rejects.
    fn ensureRegistered(self: *World, gpa: std.mem.Allocator, comptime T: type) !ComponentId {
        if (self.registry.idOf(@typeName(T))) |id| return id;
        var default: T = .{};
        return try self.registry.registerComponentRaw(gpa, .{
            .name = @typeName(T),
            .size = @intCast(@sizeOf(T)),
            .alignment = @intCast(@alignOf(T)),
            .default_bytes = std.mem.asBytes(&default),
            .fields = &.{},
        });
    }

    /// A component-id set every member of which is `.table`-stored, sorted into an
    /// archetype signature.
    ///
    /// `splitByStorage` is its ONLY constructor, so a signature cannot be built from
    /// an unpartitioned set — carried by the TYPE, not by an assert ReleaseFast
    /// compiles away. A sparse id in a signature would not crash: it would give the
    /// component a table column the sparse store also owns, after which the answer
    /// depends on which one a caller consulted. Every site re-splits rather than
    /// induct over `Archetype.component_ids`, which one new constructor breaks.
    const TableIds = struct {
        sorted: []const ComponentId,
    };

    /// The two halves of a caller-supplied component-id set.
    const StorageSplit = struct {
        /// Compacted to the front of the caller's buffer and SORTED into signature order.
        table: TableIds,
        /// In the tail, in the input's order minus the table ids — deterministic, not contractual.
        sparse: []const ComponentId,
    };

    /// Partition `buf` IN PLACE: table ids first and sorted, so the prefix IS a
    /// signature; sparse ids after. THE PARTITION IS WHAT ROUTES — not a validation
    /// a trusted path could skip, being the only way to obtain `TableIds`.
    fn splitByStorage(self: *const World, buf: []ComponentId) StorageSplit {
        var n_table: usize = 0;
        for (0..buf.len) |i| {
            // `storageOf` and not `registry.componentStorage`: this is the FIRST
            // thing to touch a caller-supplied id, and `storageOf` answers `.table`
            // past the registry's end — so an unregistered id still fails in
            // `Archetype.init` exactly as before, its breach not relocated here.
            if (self.storageOf(buf[i]) == .table) {
                std.mem.swap(ComponentId, &buf[n_table], &buf[i]);
                n_table += 1;
            }
        }
        archetype_mod.sortComponentIds(buf[0..n_table]);
        return .{
            .table = .{ .sorted = buf[0..n_table] },
            .sparse = buf[n_table..],
        };
    }

    /// Refuse an id slice naming the same component twice. ACTIVE and not an assert:
    /// a repeated id makes `Archetype.init` build a duplicate column, after which
    /// `componentIndex` answers the FIRST and the sparse side appends a second row.
    fn refuseDuplicateIds(ids: []const ComponentId) !void {
        for (ids, 0..) |c, i| {
            for (ids[i + 1 ..]) |other| {
                if (other == c) return error.DuplicateComponent;
            }
        }
    }

    /// Add `cid_new` with its `@requires` closure, in ONE transaction. A member
    /// already carried is SKIPPED — the closure is a floor, not a reset.
    /// Expand a caller-supplied set with the transitive closure its members declare,
    /// into a NEW pair of lists. Returns whether anything was added.
    ///
    /// ONE expansion semantics for all six add and spawn paths. IDEMPOTENT, a caller
    /// legitimately passing `{Mesh, Transform}` when `Mesh` requires `Transform`.
    /// And a NEW pair of arrays, never in place: the positional ids-to-payloads
    /// pairing is a coincidence the scene loader relies on, so the `dupe` protects a
    /// PERMUTATION. `entity` is null for a spawn.
    fn expandRequires(
        self: *World,
        gpa: std.mem.Allocator,
        ids_in: []const ComponentId,
        vals_in: ?[]const []const u8,
        entity: ?EntityId,
        ids_out: *std.ArrayListUnmanaged(ComponentId),
        vals_out: *std.ArrayListUnmanaged([]const u8),
    ) !bool {
        for (ids_in, 0..) |cid, i| {
            try ids_out.append(gpa, cid);
            try vals_out.append(gpa, if (vals_in) |v| v[i] else self.registry.componentDefaultBytes(cid));
        }
        var expanded = false;
        for (ids_in) |cid| {
            for (self.registry.requiresClosure(cid)) |c| {
                if (std.mem.indexOfScalar(ComponentId, ids_out.items, c) != null) continue;
                if (entity) |e| if (self.hasComponentDyn(e, c)) continue;
                try ids_out.append(gpa, c);
                try vals_out.append(gpa, self.registry.componentDefaultBytes(c));
                expanded = true;
            }
        }
        return expanded;
    }

    fn addWithClosure(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cid_new: ComponentId,
        value_bytes: []const u8,
        closure: []const ComponentId,
    ) !void {
        var ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ids.deinit(gpa);
        var vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer vals.deinit(gpa);
        try ids.append(gpa, cid_new);
        try vals.append(gpa, value_bytes);
        for (closure) |c| {
            if (self.hasComponentDyn(entity, c)) continue;
            try ids.append(gpa, c);
            try vals.append(gpa, self.registry.componentDefaultBytes(c));
        }
        // One entry point whatever the closure contributed. A branch on
        // `ids.items.len == 1` was written here and REMOVED — both arms called the
        // same thing, so it could not change behaviour.
        return self.addComponentsDynamic(gpa, entity, ids.items, vals.items);
    }

    /// Clear the per-tick observation counters, from BOTH boundaries — each reached
    /// by a population the other is not. Both CAN fire in one tick, which is
    /// harmless: the count is read DURING the tick.
    fn resetTickObservations(self: *World) void {
        self.requires_removals_skipped = 0;
        self.first_requires_skip = null;
    }

    /// Whether removing `cid` is refused because something the entity CARRIES still
    /// requires it — and record the refusal if so. `exempt` names the ids leaving in
    /// the SAME command, or a legitimate teardown would be refused forever. Public
    /// because the apply must know BEFORE firing `on_remove`, and reading it there
    /// keeps the skip counted ONCE.
    pub fn requiresRefusesRemoval(
        self: *World,
        entity: EntityId,
        cid: ComponentId,
        exempt: []const ComponentId,
    ) bool {
        var i: ComponentId = 0;
        const n: ComponentId = @intCast(self.registry.componentCount());
        while (i < n) : (i += 1) {
            if (i == cid) continue;
            var is_exempt = false;
            for (exempt) |x| if (x == i) {
                is_exempt = true;
                break;
            };
            if (is_exempt) continue;
            if (!self.registry.isRequiredBy(cid, i)) continue;
            if (!self.hasComponentDyn(entity, i)) continue;
            // ONE LINE PER TICK AT MOST: the first skip names itself and the counter
            // carries the rest, so a scene with a hundred offenders logs once.
            if (self.requires_removals_skipped == 0) {
                std.log.warn(
                    "ecs/@requires: removal SKIPPED — component {d} is still required by {d} on this entity; " ++
                        "drop them in one command to remove both",
                    .{ cid, i },
                );
                self.first_requires_skip = cid;
            }
            self.requires_removals_skipped += 1;
            return true;
        }
        return false;
    }

    /// Which backend owns `cid`. THE REGISTRY IS THE AUTHORITY, never the existence
    /// of a sparse store. An out-of-range id is NOT programmer error — `.table` is
    /// what reproduces the `null` the byte-level entries owe an unknown id.
    pub fn storageOf(self: *const World, cid: ComponentId) registry_mod.StorageKind {
        if (cid >= self.registry.componentCount()) return .table;
        return self.registry.componentStorage(cid);
    }

    /// Idempotent per id; the caller has already established these sparse.
    ///
    /// The loop lives on `World` and not on `SparseStores` because it needs the
    /// registry per id, and that dependency would undo the backend's decoupling.
    /// registry dependency would undo G2's decoupling for the sake of one loop.
    fn ensureSparseStores(self: *World, gpa: std.mem.Allocator, ids: []const ComponentId) !void {
        for (ids) |cid| {
            _ = try self.sparse_stores.ensure(
                gpa,
                cid,
                self.registry.componentSize(cid),
                self.registry.componentAlignment(cid),
            );
        }
    }

    /// Write `entity`'s payload into each sparse store. A failure on the third id
    /// would leave the first two COMMITTED, so the unwind is World-level and LIFO.
    /// `id_order` carries the ORIGINAL pairing, the split having permuted the buffer.
    fn addSparsePayloads(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        ids: []const ComponentId,
        payloads: ?[]const []const u8,
        id_order: ?[]const ComponentId,
    ) !void {
        var written: usize = 0;
        errdefer self.removeSparsePayloads(entity, ids[0..written]);
        for (ids) |cid| {
            const store = self.sparse_stores.get(cid).?;
            // A DUPLICATE id would land here twice, and `add`'s assert is compiled to
            // nothing in ReleaseFast — the second call appends a SECOND dense row,
            // after which the other becomes permanently unreachable. Loud instead.
            if (store.contains(entity)) return error.DuplicateComponent;
            const bytes = blk: {
                if (payloads) |ps| {
                    const order = id_order.?;
                    for (order, 0..) |req, k| {
                        if (req == cid) break :blk ps[k];
                    }
                    // Proven, not assumed: every member of `split.sparse` was CHECKED
                    // against the registry, and a member could come from the
                    // archetype rather than from `order` only if a component's mode
                    // changed after its archetype was built. It cannot — every access
                    // to an existing descriptor in `registry.zig` is a READ.
                    unreachable;
                }
                break :blk self.registry.componentDefaultBytes(cid);
            };
            try store.add(gpa, entity, bytes, self.current_tick);
            written += 1;
        }
    }

    /// Remove `entity` from each sparse store, in reverse. INFALLIBLE, which is what
    /// makes it usable as an `errdefer` — and why the spawn paths write the SPARSE
    /// side first and the table slot LAST, the messier undo going last.
    fn removeSparsePayloads(self: *World, entity: EntityId, ids: []const ComponentId) void {
        var k = ids.len;
        while (k > 0) {
            k -= 1;
            // `ensureSparseStores` ran first and the entity was added, so this finds it.
            _ = self.sparse_stores.get(ids[k]).?.remove(entity);
        }
    }

    /// `null` when no archetype has that EXACT signature yet.
    fn findArchetype(self: *World, sorted_ids: []const ComponentId) ?*Archetype {
        const key = archetype_mod.signatureBytes(sorted_ids);
        if (self.archetype_by_signature.get(key)) |idx| {
            return self.archetypes.items[idx];
        }
        return null;
    }

    /// The pointer is stable for the world's lifetime.
    fn getOrCreateArchetype(self: *World, gpa: std.mem.Allocator, key_ids: TableIds) !*Archetype {
        const sorted_ids = key_ids.sorted;
        if (self.findArchetype(sorted_ids)) |existing| return existing;

        const arch_id: ArchetypeId = @intCast(self.archetypes.items.len);
        const a = try gpa.create(Archetype);
        errdefer gpa.destroy(a);
        a.* = try Archetype.init(gpa, &self.registry, arch_id, sorted_ids);
        errdefer a.deinit(gpa);
        try self.archetypes.append(gpa, a);
        errdefer _ = self.archetypes.pop();

        // The key bytes ALIAS the archetype's own slice, valid for the world's life.
        const key = archetype_mod.signatureBytes(a.component_ids);
        try self.archetype_by_signature.put(gpa, key, arch_id);

        return a;
    }

    pub fn archetypeCount(self: *const World) usize {
        return self.archetypes.items.len;
    }

    /// The archetype at `idx`. TABLE BACKEND ONLY by nature: an archetype IS the
    /// table storage, so this is a BOUNDED primitive. For a sparse component
    /// `componentIndex` answers null and each caller's `orelse` may decide
    /// differently — `World.componentBytes` is what answers for both backends.
    pub fn dynamicArchetype(self: *World, idx: ArchetypeId) *Archetype {
        return self.archetypes.items[idx];
    }

    /// Where `entity` lives in the TABLE storage, or null for a stale handle.
    ///
    /// Total for every live entity, sparse-only ones included: an entity carrying no
    /// table component lives in the EMPTY archetype rather than nowhere. It carries
    /// no sparse-side information — see `dynamicArchetype` for the shared bound.
    pub fn dynamicLocation(self: *const World, id: EntityId) ?Location {
        return self.entity_locations.get(id);
    }

    /// Spawn an entity with the S1 `(Transform, Velocity)` archetype.
    /// Generational id drawn from the identity store; archetype found
    /// or created on first call.
    pub fn spawn(
        self: *World,
        gpa: std.mem.Allocator,
        transform: Transform,
        velocity: Velocity,
    ) !EntityId {
        const id_t = try self.ensureRegistered(gpa, Transform);
        const id_v = try self.ensureRegistered(gpa, Velocity);
        var ids = [_]ComponentId{ id_t, id_v };

        // This entry writes ONLY the two columns it names and takes `allocateSlot`,
        // which does not default-initialise — so a component the closure contributed
        // would land here with UNDEFINED bytes. An expanded set therefore DELEGATES
        // to the general entry, which writes every column it was given.
        if (self.registry.requiresClosure(id_t).len != 0 or
            self.registry.requiresClosure(id_v).len != 0)
        {
            const vals = [_][]const u8{ std.mem.asBytes(&transform), std.mem.asBytes(&velocity) };
            return self.spawnDynamicWithValues(gpa, ids[0..], vals[0..]);
        }
        // Both are table-stored, and the split runs anyway: the funnel takes no
        // other input, and a path exempted because its ids look trustworthy breaks
        // the day one of them is registered differently.
        // CAPTURED BEFORE THE SPLIT, which permutes `ids` in place.
        const named_ids = [_]ComponentId{ id_t, id_v };
        const named_vals = [_][]const u8{ std.mem.asBytes(&transform), std.mem.asBytes(&velocity) };
        const split = self.splitByStorage(ids[0..]);
        // Without this, `addSparsePayloads` unwraps a store that was never declared
        // and PANICS — which is what it did.
        try self.ensureSparseStores(gpa, split.sparse);
        const arch = try self.getOrCreateArchetype(gpa, split.table);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(eid);

        // THE CALLER'S VALUES, never `null, null`: null writes the REGISTRY DEFAULT,
        // so a component registered `.sparse` silently lost the value handed here.
        // `spawnDynamic` passes null CORRECTLY, having no values at all.
        try self.addSparsePayloads(gpa, eid, split.sparse, named_vals[0..], named_ids[0..]);
        errdefer self.removeSparsePayloads(eid, split.sparse);

        const r = try arch.allocateSlot(gpa, self.current_tick);
        const chunk = arch.chunks.items[r.chunk_idx];

        // In the archetype's sorted-id order, matched against the ids resolved above
        // so the choice does not depend on which type registered first.
        for (arch.component_ids, 0..) |cid, i| {
            const dst = arch.componentSlot(chunk, i, r.slot);
            if (cid == id_t) {
                @memcpy(dst, std.mem.asBytes(&transform));
            } else if (cid == id_v) {
                @memcpy(dst, std.mem.asBytes(&velocity));
            } else unreachable; // archetype was created from {id_t, id_v}
        }
        arch.entityIds(chunk)[r.slot] = eid;

        self.entity_locations.putAssumeCapacity(eid, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return eid;
    }

    /// Every slot is initialised from the registry's DEFAULT bytes.
    pub fn spawnDynamic(self: *World, gpa: std.mem.Allocator, component_ids: []const ComponentId) !EntityId {
        try refuseDuplicateIds(component_ids);
        // The closure is expanded HERE, on the caller's set, before anything else.
        var ex_ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ex_ids.deinit(gpa);
        var ex_vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ex_vals.deinit(gpa);
        _ = try self.expandRequires(gpa, component_ids, null, null, &ex_ids, &ex_vals);
        const ids_all = ex_ids.items;
        // The caller's ids may be unsorted and may mix both modes.
        const scratch = try gpa.dupe(ComponentId, ids_all);
        defer gpa.free(scratch);
        const split = self.splitByStorage(scratch);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        try self.ensureSparseStores(gpa, split.sparse);
        const arch = try self.getOrCreateArchetype(gpa, split.table);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(eid);

        try self.addSparsePayloads(gpa, eid, split.sparse, null, null);
        errdefer self.removeSparsePayloads(eid, split.sparse);

        const r = try arch.spawnDefault(gpa, eid, self.current_tick);
        self.entity_locations.putAssumeCapacity(eid, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return eid;
    }

    /// `spawnDynamic` carrying caller values instead of registry defaults.
    /// `payloads[i]` must match the size of `component_ids[i]` — THE CALLER's
    /// responsibility.
    pub fn spawnDynamicWithValues(
        self: *World,
        gpa: std.mem.Allocator,
        component_ids: []const ComponentId,
        payloads: []const []const u8,
    ) !EntityId {
        std.debug.assert(component_ids.len == payloads.len);
        try refuseDuplicateIds(component_ids);

        // Expanded into a NEW pair of lists, before anything is resolved from either.
        var ex_ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ex_ids.deinit(gpa);
        var ex_vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ex_vals.deinit(gpa);
        _ = try self.expandRequires(gpa, component_ids, payloads, null, &ex_ids, &ex_vals);
        const ids_all = ex_ids.items;
        const vals_all = ex_vals.items;

        // The split permutes the scratch buffer, so the original (id, payload)
        // pairing survives only in the caller's `component_ids` — which both loops
        // below resolve against BY ID and never by position.
        const scratch = try gpa.dupe(ComponentId, ids_all);
        defer gpa.free(scratch);
        const split = self.splitByStorage(scratch);

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        try self.ensureSparseStores(gpa, split.sparse);
        const arch = try self.getOrCreateArchetype(gpa, split.table);
        const eid = try self.identity.allocate(gpa);
        errdefer self.identity.release(eid);

        try self.addSparsePayloads(gpa, eid, split.sparse, vals_all, ids_all);
        errdefer self.removeSparsePayloads(eid, split.sparse);

        const r = try arch.allocateSlot(gpa, self.current_tick);
        const chunk = arch.chunks.items[r.chunk_idx];

        // Linear scan; `component_ids.len` is small.
        for (arch.component_ids, 0..) |arch_cid, col| {
            var found: ?usize = null;
            for (ids_all, 0..) |req_cid, k| {
                if (req_cid == arch_cid) {
                    found = k;
                    break;
                }
            }
            const dst = arch.componentSlot(chunk, col, r.slot);
            if (found) |k| {
                @memcpy(dst, vals_all[k]);
            } else {
                // Unreachable: `split.table` is a subset of `component_ids`, and the
                // ids that are NOT columns are the sparse half, written above.
                unreachable;
            }
        }
        arch.entityIds(chunk)[r.slot] = eid;

        self.entity_locations.putAssumeCapacity(eid, .{
            .archetype_idx = arch.archetype_id,
            .chunk_idx = r.chunk_idx,
            .slot = r.slot,
        });
        return eid;
    }

    /// `StaleEntityHandle` for an unknown index, a freed slot or a generation
    /// mismatch. Updates the swapped-in entity's location with the chunk swap, and
    /// PURGES the extension set so its owned names are freed here.
    pub fn despawn(self: *World, gpa: std.mem.Allocator, id: EntityId) WorldError!void {
        try self.identity.validate(id);
        const location = self.entity_locations.get(id) orelse return error.StaleEntityHandle;

        const arch = self.archetypes.items[location.archetype_idx];
        if (arch.removeSwap(location.chunk_idx, location.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = location;
        }
        _ = self.entity_locations.remove(id);
        // Before `identity.release` for reading order and NOT as a correctness
        // condition — a first version of this comment claimed otherwise and its own
        // counter-factual refuted it: `positionOf` compares the generation against
        // the STORE's copy of the handle and never consults the identity store.
        _ = self.sparse_stores.removeEntity(id);
        self.purgeEntityExtensions(gpa, id);
        self.identity.release(id);
    }

    /// Whether `entity` carries `cid`, whichever backend stores it. TOTAL — `false`
    /// for a stale handle, an unknown id or an absent component, indistinguishably.
    ///
    /// NOT a convenience over `componentBytes() != null`: the batched paths asked
    /// presence of the ARCHETYPE, which answers `false` for a sparse component the
    /// entity carries, so an already-present sparse add reached a stripped assert.
    /// `entity`'s `changed_tick` for `cid`, whichever backend holds it. USE THIS and
    /// not `dynamicLocation` + `dynamicArchetype`, which answers for the TABLE half
    /// only: a sparse component reads as "never changed".
    pub fn changedTickOf(self: *const World, entity: EntityId, cid: ComponentId) ?tick_mod.Tick {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.getConst(cid) orelse return null;
            return store.changedTick(entity);
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        return arch.changedTick(chunk, col, loc.slot);
    }

    pub fn hasComponentDyn(self: *const World, entity: EntityId, cid: ComponentId) bool {
        if (!self.identity.isLive(entity)) return false;
        const loc = self.entity_locations.get(entity) orelse return false;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.getConst(cid) orelse return false;
            return store.contains(entity);
        }
        return self.archetypes.items[loc.archetype_idx].hasComponent(cid);
    }

    pub fn entityCount(self: *const World) usize {
        return self.entity_locations.count();
    }

    /// `false` for a stale handle rather than an error.
    pub fn isLive(self: *const World, id: EntityId) bool {
        return self.identity.isLive(id);
    }

    /// Bumps `current_tick` (WRAPPING) and clears every chunk's dirty bitset, which
    /// is what bounds `Changed<T>` to this frame's modifications.
    pub fn beginFrame(self: *World) void {
        self.current_tick +%= 1;
        for (self.archetypes.items) |arch| arch.clearAllDirtyBitsets();
        self.resetTickObservations();
        // NO sparse arm, and the absence is an INVARIANT: a sparse store has no
        // dirty bitset, the bitset existing for a chunk-granular skip that a sparse
        // set cannot offer. The guard is `SparseSetStorage.field_set_pin`, which
        // lives where a field gets ADDED and whose message names this function.
    }

    /// `null` for a stale entity or an archetype without `T`. Does NOT mark changed.
    pub fn get(self: *const World, comptime T: type, entity: EntityId) ?*const T {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        const cid = self.registry.idOf(@typeName(T)) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.getConst(cid) orelse return null;
            const bytes = store.get(entity) orelse return null;
            return @ptrCast(@alignCast(bytes.ptr));
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col_idx = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        const bytes = arch.componentSlot(chunk, col_idx, loc.slot);
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// AUTO-MARKS `changed_tick` and the dirty bit BEFORE returning, so every write
    /// through the pointer is observable by a `Changed<T>` query. `null` for a stale
    /// handle or a missing component.
    pub fn getMut(self: *World, comptime T: type, entity: EntityId) ?*T {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        const cid = self.registry.idOf(@typeName(T)) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.get(cid) orelse return null;
            // The auto-mark is the ENTRY's contract, not a table implementation detail.
            const bytes = store.getMut(entity, self.current_tick) orelse return null;
            return @ptrCast(@alignCast(bytes.ptr));
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col_idx = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        arch.markChanged(chunk, col_idx, loc.slot, self.current_tick);
        const bytes = arch.componentSlot(chunk, col_idx, loc.slot);
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Byte-level read by `ComponentId`, the runtime analogue of `get`. `null` for a
    /// stale entity or a missing component. Does NOT mark the slot changed.
    pub fn componentBytes(self: *World, entity: EntityId, cid: ComponentId) ?[]u8 {
        if (!self.identity.isLive(entity)) return null;
        const loc = self.entity_locations.get(entity) orelse return null;
        if (self.storageOf(cid) == .sparse) {
            const store = self.sparse_stores.get(cid) orelse return null;
            // Deliberately NOT `getMut`: `observers.zig` reads through this to build
            // its old/new payloads, and stamping here would make a dispatch look like
            // a mutation. `markComponentChangedDyn` is the entry whose job that is.
            return store.bytesMut(entity) orelse return null;
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col = arch.componentIndex(cid) orelse return null;
        const chunk = arch.chunks.items[loc.chunk_idx];
        return arch.componentSlot(chunk, col, loc.slot);
    }

    /// Stamp `entity`'s `cid` slot as changed at `current_tick` (E3) —
    /// used after an in-place replace overwrite so a `Changed<T>` query sees it,
    /// mirroring `getMut`'s auto-mark. No-op when the entity/component is absent.
    pub fn markComponentChangedDyn(self: *World, entity: EntityId, cid: ComponentId) void {
        const loc = self.entity_locations.get(entity) orelse return;
        if (self.storageOf(cid) == .sparse) {
            // Without this arm the mark would be SILENTLY LOST: the entry returns
            // `void` and `componentIndex` on a sparse id answers null, so the
            // pre-body's `orelse return` would swallow it. A change that never
            // propagates has no diagnostic anywhere.
            if (self.sparse_stores.get(cid)) |store| {
                store.markChanged(entity, self.current_tick);
            }
            return;
        }
        const arch = self.archetypes.items[loc.archetype_idx];
        const col = arch.componentIndex(cid) orelse return;
        const chunk = arch.chunks.items[loc.chunk_idx];
        arch.markChanged(chunk, col, loc.slot, self.current_tick);
    }

    /// Insert component `T`. The first add of `T` from this archetype does the
    /// signature lookup and CACHES the target; later adds hit the cache. Existing
    /// columns are byte-copied and the source slot freed by swap-and-pop, with the
    /// trailing entity's location updated with it. `StaleEntityHandle` on a handle
    /// the identity store does not match.
    pub fn addComponent(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        comptime T: type,
        value: T,
    ) !void {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        const cid_new = try self.ensureRegistered(gpa, T);

        // The last single-component add path: it handles ONE component and branches
        // on its storage, so an expanded set needs the grouped machinery. The guard
        // keeps the PROPERTY and not today's instance — an Etch declaration can
        // claim the same name through `registerAlias`.
        if (self.registry.requiresClosure(cid_new).len != 0) {
            return self.addComponentDynamic(gpa, entity, cid_new, std.mem.asBytes(&value));
        }

        if (self.storageOf(cid_new) == .sparse) {
            // NO archetype transition: a sparse component's presence is a row in its
            // own store, so the signature, the location, the chunk and every other
            // component's address are UNTOUCHED. That absence IS the mode.
            const store = try self.sparse_stores.ensure(
                gpa,
                cid_new,
                self.registry.componentSize(cid_new),
                self.registry.componentAlignment(cid_new),
            );
            // ACTIVE check, not an assert: `add`'s assert is compiled to NOTHING in
            // ReleaseFast, so a double add appends a SECOND dense row and leaves the
            // other permanently unreachable. The table arm's identical hole PREDATES
            // this and is reported, not fixed here.
            if (store.contains(entity)) return error.DuplicateComponent;
            try store.add(gpa, entity, std.mem.asBytes(&value), self.current_tick);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        // ACTIVE, for the sparse arm's reason: the assert this replaces was compiled
        // to nothing in ReleaseFast, so the migration built a signature carrying
        // `cid_new` TWICE. `applyWithObservers` is unaffected — it tests presence
        // FIRST and reaches here only on the absent branch.
        if (src_arch.hasComponent(cid_new)) return error.DuplicateComponent;

        const dst_arch = blk: {
            if (src_arch.transitions.add.get(cid_new)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            // Build the target signature: src.component_ids ∪ {cid_new}.
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len + 1);
            defer gpa.free(target_ids);
            @memcpy(target_ids[0..src_arch.component_ids.len], src_arch.component_ids);
            target_ids[src_arch.component_ids.len] = cid_new;
            const split = self.splitByStorage(target_ids);

            const target = try self.getOrCreateArchetype(gpa, split.table);
            // Re-resolve the source pointer after a possible growth of the archetype
            // list. It is stable, holding `*Archetype` and not values — but explicitly.
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.add.put(gpa, cid_new, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        // `allocateSlot` stamps BOTH sidecars for every destination column at the
        // current tick; the surviving columns' `added_tick` is then overwritten, or
        // "first attached to this entity" would not survive a migration.
        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        // From the source when the component exists there, else the caller's value.
        // A surviving column carries its pre-migration ticks; the new one keeps what
        // `allocateSlot` stamped.
        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            if (dst_cid == cid_new) {
                @memcpy(dst, std.mem.asBytes(&value));
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);

                // Preserve the source's `added_tick` and
                // `changed_tick` for this column.
                const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
                const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
                dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
                dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
            }
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// `addComponent`'s migration with the id already resolved and the new column's
    /// bytes from the caller's payload.
    pub fn addComponentDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cid_new: ComponentId,
        value_bytes: []const u8,
    ) !void {
        // The closure is added WITH the component, in one transaction — delegated to
        // `addComponentsDynamic` because that entry ALREADY is the transaction, and a
        // second implementation of the same atomicity is a second thing to keep true.
        // The closure is READ and never walked: `requiresClosure` returns what
        // `finalizeRequires` flattened once.
        const closure = self.registry.requiresClosure(cid_new);
        if (closure.len != 0) return self.addWithClosure(gpa, entity, cid_new, value_bytes, closure);
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        if (self.storageOf(cid_new) == .sparse) {
            // NO archetype transition — see the twin in `addComponent`.
            const store = try self.sparse_stores.ensure(
                gpa,
                cid_new,
                self.registry.componentSize(cid_new),
                self.registry.componentAlignment(cid_new),
            );
            // ACTIVE check — see the twin in `addComponent` for why an assert
            // will not do here and why the table arm is deliberately left alone.
            if (store.contains(entity)) return error.DuplicateComponent;
            try store.add(gpa, entity, value_bytes, self.current_tick);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        // ACTIVE, for the sparse arm's reason — see the twin in `addComponent`.
        if (src_arch.hasComponent(cid_new)) return error.DuplicateComponent;

        const dst_arch = blk: {
            if (src_arch.transitions.add.get(cid_new)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len + 1);
            defer gpa.free(target_ids);
            @memcpy(target_ids[0..src_arch.component_ids.len], src_arch.component_ids);
            target_ids[src_arch.component_ids.len] = cid_new;
            const split = self.splitByStorage(target_ids);

            const target = try self.getOrCreateArchetype(gpa, split.table);
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.add.put(gpa, cid_new, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            if (dst_cid == cid_new) {
                @memcpy(dst, value_bytes);
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);

                const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
                const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
                dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
                dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
            }
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// `removeComponent`'s migration with the id already resolved.
    pub fn removeComponentDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cid_drop: ComponentId,
    ) !void {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        // A removal refused by `@requires` is SKIPPED, not an error: the invariant
        // holds, the deviation is counted and logged once per tick, and the tick
        // survives. An error here would turn a deferred command into an unobservable
        // tick failure.
        if (self.requiresRefusesRemoval(entity, cid_drop, &.{})) return;

        if (self.storageOf(cid_drop) == .sparse) {
            // Removing an absent component is programmer error on this entry, but
            // UNLIKE the table arm the release path is a NO-OP rather than undefined:
            // a `.?` behind a stripped assert would be UB on the exact misuse the
            // assert exists to name.
            std.debug.assert(self.hasComponentDyn(entity, cid_drop));
            const store = self.sparse_stores.get(cid_drop) orelse return;
            _ = store.remove(entity);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(src_arch.hasComponent(cid_drop));

        const dst_arch = blk: {
            if (src_arch.transitions.remove.get(cid_drop)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            // `>= 1` and not `>= 2`: the EMPTY archetype is LEGAL, so dropping an
            // entity's last component is a transition to it. Guaranteed by the
            // `hasComponent(cid_drop)` check above, which is what makes it 1 and not 0.
            std.debug.assert(src_arch.component_ids.len >= 1);
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len - 1);
            defer gpa.free(target_ids);
            var di: usize = 0;
            for (src_arch.component_ids) |cid| {
                if (cid == cid_drop) continue;
                target_ids[di] = cid;
                di += 1;
            }

            const split = self.splitByStorage(target_ids);
            const target = try self.getOrCreateArchetype(gpa, split.table);
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.remove.put(gpa, cid_drop, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);

            const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
            const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
            dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
            dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// Add SEVERAL components in a SINGLE migration: either the whole set lands or
    /// nothing changes. Every fallible step runs BEFORE the first observable
    /// mutation, and the value writes are infallible `memcpy`.
    ///
    /// `cids[i]` pairs with `values[i]`. Every `cids[i]` must be ABSENT and DISTINCT,
    /// and that is a real check: a duplicate would put the id twice in the target
    /// archetype and mis-map the values.
    pub fn addComponentsDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cids: []const ComponentId,
        values: []const []const u8,
    ) !void {
        std.debug.assert(cids.len == values.len); // programmer contract, not file-reachable
        if (cids.len == 0) return;
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        // THE grouped expansion point: every other add path routes here rather than
        // expanding for itself. The helper is entity-aware, so the present-check
        // below never sees a requisite the entity already carries.
        var ex_ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ex_ids.deinit(gpa);
        var ex_vals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ex_vals.deinit(gpa);
        // Allocation-free when nothing requires anything — the closure lookup is a
        // slice length per id, and only a non-empty one reaches the copy.
        var needs = false;
        for (cids) |c| {
            if (self.registry.requiresClosure(c).len != 0) {
                needs = true;
                break;
            }
        }
        if (needs) _ = try self.expandRequires(gpa, cids, values, entity, &ex_ids, &ex_vals);
        const ids_all = if (needs) ex_ids.items else cids;
        const vals_all = if (needs) ex_vals.items else values;
        {
            // Real duplicate/present checks BEFORE any allocation, and routed through
            // `hasComponentDyn` and NOT `src_arch.hasComponent`: the archetype answers
            // `false` for a sparse component the entity carries, so the earlier form
            // let an already-present sparse add through to an assert compiled to
            // nothing in ReleaseFast.
            for (ids_all, 0..) |c, ci| {
                if (self.hasComponentDyn(entity, c)) return error.DuplicateComponent;
                for (ids_all[ci + 1 ..]) |other| if (other == c) return error.DuplicateComponent;
            }
        }

        // Built ONCE: the per-transition cache is single-component-keyed, so the
        // grouped path resolves its target directly and dedups by SET.
        const src_len = self.archetypes.items[src_loc.archetype_idx].component_ids.len;
        const target_ids = try gpa.alloc(ComponentId, src_len + ids_all.len);
        defer gpa.free(target_ids);
        @memcpy(target_ids[0..src_len], self.archetypes.items[src_loc.archetype_idx].component_ids);
        @memcpy(target_ids[src_len..], ids_all);
        // The funnel's own split filters: `split.sparse` is exactly the sparse half
        // of `cids`, `src.component_ids` being table-only by construction. So
        // `target_ids` is merely over-allocated by the sparse count.
        const split = self.splitByStorage(target_ids);
        try self.ensureSparseStores(gpa, split.sparse);

        const dst_arch = try self.getOrCreateArchetype(gpa, split.table);
        // Re-fetch: `getOrCreateArchetype` may have grown the list.
        const src_arch = self.archetypes.items[src_loc.archetype_idx];

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);
        // Sparse rows BEFORE the table slot, per the rule at `removeSparsePayloads`:
        // the sparse undo is infallible and the table undo is not. `split.sparse`
        // aliases `target_ids`, whose `defer` was declared earlier and so runs AFTER
        // this `errdefer`.
        try self.addSparsePayloads(gpa, entity, split.sparse, vals_all, ids_all);
        errdefer self.removeSparsePayloads(entity, split.sparse);

        // SELF-MIGRATION GUARD, and it sits HERE, after the sparse rows: placed above
        // them its first version returned before writing them.
        //
        // When every added id is sparse the target signature EQUALS the source's, so
        // the funnel hands back the SOURCE archetype. The migration would reserve a
        // second slot, copy the row, and swap-pop the original — and that swap brings
        // the copy down from the tail and reports THIS entity as relocated, after
        // which the location update overwrites the correct slot with the freed one.
        // The next spawn into this archetype then ALIASES a live entity's bytes.
        // Reachable from `loader.activateExtension`.
        if (dst_arch == src_arch) return;

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        // ── from here down: infallible (reserve-then-mutate boundary) ──
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            var new_k: ?usize = null;
            for (ids_all, 0..) |c, k| {
                if (c == dst_cid) {
                    new_k = k;
                    break;
                }
            }
            if (new_k) |k| {
                @memcpy(dst, vals_all[k]); // a newly-added component: caller's bytes
            } else {
                const src_i = src_arch.componentIndex(dst_cid).?;
                const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
                @memcpy(dst, src);
                dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
                dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
            }
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// A validated, slot-reserved grouped remove awaiting `commit` or `abort`, both
    /// infallible. Lets a caller run a fallible-but-non-structural step — the
    /// `on_detach` hook — BETWEEN validation and mutation with no way to strand the
    /// entity.
    pub const PreparedRemove = struct {
        entity: EntityId,
        src_arch: *Archetype,
        src_loc: Location,
        dst_arch: *Archetype,
        /// The reserved slot, or null when the drop set is ENTIRELY sparse: the target
        /// signature then equals the source's and there is no migration. Null rather
        /// than a self-migration — see the guard in `prepare` for what that corrupts.
        dst_r: ?archetype_mod.SpawnResult,
        /// `prepare`'s OWNED copy of `cids`, partitioned in place. Owned rather than
        /// a slice into the caller's, which works TODAY and would make the trio's
        /// correctness depend on a lifetime precondition no signature states.
        cids_owned: []ComponentId,
        n_table: usize,

        /// The sparse ids this remove must drop.
        pub fn sparseDrops(self: PreparedRemove) []const ComponentId {
            return self.cids_owned[self.n_table..];
        }
    };

    /// The FALLIBLE half of a grouped remove: validate, resolve the target, reserve
    /// capacity, allocate the slot. No observable mutation yet. Every `cids[i]` must
    /// be PRESENT and DISTINCT, checked BEFORE any allocation.
    pub fn prepareRemoveComponentsDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cids: []const ComponentId,
    ) !PreparedRemove {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;
        const src_arch0 = self.archetypes.items[src_loc.archetype_idx];
        const src_len = src_arch0.component_ids.len;

        // Routed through `hasComponentDyn` for the batched add's reason: the
        // archetype answers `false` for a sparse component the entity carries, so
        // `hasComponent` would reject a legitimate sparse drop with `UnknownComponent`
        // — a refusal of the right shape for the wrong reason.
        for (cids, 0..) |c, ci| {
            if (!self.hasComponentDyn(entity, c)) return error.UnknownComponent;
            for (cids[ci + 1 ..]) |other| if (other == c) return error.DuplicateComponent;
        }
        // THIS PATH ERRORS WHERE THE SINGLE PATHS SKIP, and the asymmetry is the
        // channel each can afford: the three flush paths call the SINGLE
        // `removeComponentDynamic`, where an error aborts the tick, while this entry
        // has ONE caller that already returns typed errors. And a grouped remove is
        // ONE migration, so trimming it to the admitted subset would answer partially.
        for (cids) |c| {
            if (self.requiresRefusesRemoval(entity, c, cids)) return error.RequiredComponent;
        }

        // Only the table half leaves the signature, and `src_len - cids.len` would
        // UNDERFLOW the moment a sparse id is among them.
        const cids_owned = try gpa.dupe(ComponentId, cids);
        errdefer gpa.free(cids_owned);
        const drop_split = self.splitByStorage(cids_owned);
        const n_table = drop_split.table.sorted.len;
        std.debug.assert(src_len >= n_table);

        // Target archetype = source components \ the TABLE half of `cids`.
        const target_ids = try gpa.alloc(ComponentId, src_len - n_table);
        defer gpa.free(target_ids);
        var di: usize = 0;
        for (src_arch0.component_ids) |cid| {
            var drop = false;
            for (drop_split.table.sorted) |c| {
                if (c == cid) {
                    drop = true;
                    break;
                }
            }
            if (drop) continue;
            target_ids[di] = cid;
            di += 1;
        }
        std.debug.assert(di == target_ids.len); // guaranteed by the present+distinct checks

        const split = self.splitByStorage(target_ids);
        const dst_arch = try self.getOrCreateArchetype(gpa, split.table);
        // Re-fetch: `getOrCreateArchetype` may have grown the list.
        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        // SELF-MIGRATION GUARD, the twin of `addComponentsDynamic`'s: an entirely
        // sparse drop set gets the SOURCE archetype back, and reserving a slot in it
        // sets up the copy-then-swap that strands the location on a freed slot.
        const dst_r: ?archetype_mod.SpawnResult = if (dst_arch == src_arch)
            null
        else blk: {
            try self.entity_locations.ensureUnusedCapacity(gpa, 1);
            break :blk try dst_arch.allocateSlot(gpa, self.current_tick);
        };
        return .{
            .entity = entity,
            .src_arch = src_arch,
            .src_loc = src_loc,
            .dst_arch = dst_arch,
            .dst_r = dst_r,
            .cids_owned = cids_owned,
            .n_table = n_table,
        };
    }

    /// The INFALLIBLE half: copy the surviving columns, swap-pop the source, update
    /// `entity_locations` — whose capacity `prepare` reserved. Observable after this.
    pub fn commitRemoveComponentsDynamic(self: *World, gpa: std.mem.Allocator, prepared: PreparedRemove) void {
        defer gpa.free(prepared.cids_owned);
        // The sparse rows go HERE and not in `prepare`, for a semantic reason:
        // `on_detach` fires between the halves and may read the component. Its table
        // columns are still in the source archetype then, so the sparse row must
        // still be in its store or the hook sees a half-removed component.
        self.removeSparsePayloads(prepared.entity, prepared.sparseDrops());
        // A null `dst_r` means the drop was entirely sparse and the entity does not
        // move; returning is what keeps the self-migration guard's decision standing.
        const dst_r = prepared.dst_r orelse return;
        const dst_arch = prepared.dst_arch;
        const src_arch = prepared.src_arch;
        const src_loc = prepared.src_loc;
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);
            dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
            dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = prepared.entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(prepared.entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// Roll a `PreparedRemove` back: pop the reserved slot.
    ///
    /// INVARIANT — the reserved slot is the LAST of its chunk and nothing allocates
    /// into `dst_arch` between prepare and abort, so `removeSwap` on it is a pure pop.
    /// The entity was never recorded there, so no map fix-up is needed.
    pub fn abortRemoveComponentsDynamic(self: *World, gpa: std.mem.Allocator, prepared: PreparedRemove) void {
        _ = self;
        defer gpa.free(prepared.cids_owned);
        // Nothing to undo on the sparse side: `commit` is what removes those rows.
        // And nothing to release when `dst_r` is null — a `removeSwap` there would
        // pop a LIVE row belonging to another entity.
        const dst_r = prepared.dst_r orelse return;
        const swapped = prepared.dst_arch.removeSwap(dst_r.chunk_idx, dst_r.slot);
        std.debug.assert(swapped == null); // the reserved slot must be the chunk's last
    }

    /// Remove SEVERAL components in one migration. A caller needing a step between
    /// validation and mutation uses `prepare`/`commit`/`abort` directly.
    pub fn removeComponentsDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        cids: []const ComponentId,
    ) !void {
        if (cids.len == 0) return;
        const prepared = try self.prepareRemoveComponentsDynamic(gpa, entity, cids);
        self.commitRemoveComponentsDynamic(gpa, prepared);
    }

    /// Apply one tag-bit mutation. An entity that already has `TagSet` gets the bit
    /// flipped IN PLACE; one that lacks it and is setting gets an archetype
    /// transition. A STALE HANDLE IS DROPPED SILENTLY. Flush points only.
    pub fn applyTagMutation(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        tagset_id: ComponentId,
        bit_index: u32,
        set: bool,
    ) !void {
        // A STALE HANDLE MUST BE SILENTLY IGNORED, which is what this line restores:
        // a tag recorded for an entity despawned later in the same tick is ordinary,
        // and without it the null reaches `addComponentDynamic`, whose
        // `StaleEntityHandle` aborts every remaining command of the flush.
        if (self.entity_locations.get(entity) == null) return;
        if (self.componentBytes(entity, tagset_id)) |bytes| {
            setTagBit(bytes, bit_index, set);
        } else if (set) {
            const size = self.registry.componentSize(tagset_id);
            const buf = try gpa.alloc(u8, size);
            defer gpa.free(buf);
            @memset(buf, 0);
            setTagBit(buf, bit_index, true);
            try self.addComponentDynamic(gpa, entity, tagset_id, buf);
        }
    }

    /// The destination archetype is the source's signature MINUS `cid`; the removed
    /// component's data is dropped and the rest byte-copied.
    pub fn removeComponent(
        self: *World,
        gpa: std.mem.Allocator,
        entity: EntityId,
        comptime T: type,
    ) !void {
        try self.identity.validate(entity);
        const src_loc = self.entity_locations.get(entity) orelse return error.StaleEntityHandle;

        const cid_drop = self.registry.idOf(@typeName(T)) orelse return error.StaleEntityHandle;
        // A removal refused by `@requires` is SKIPPED, not an error — see the twin in
        // `removeComponentDynamic`.
        if (self.requiresRefusesRemoval(entity, cid_drop, &.{})) return;

        if (self.storageOf(cid_drop) == .sparse) {
            // Removing an absent component is programmer error here, but the release
            // path is a NO-OP rather than undefined: a `.?` behind a stripped assert
            // would be UB on the exact misuse the assert exists to name.
            std.debug.assert(self.hasComponentDyn(entity, cid_drop));
            const store = self.sparse_stores.get(cid_drop) orelse return;
            _ = store.remove(entity);
            return;
        }

        const src_arch = self.archetypes.items[src_loc.archetype_idx];
        std.debug.assert(src_arch.hasComponent(cid_drop));

        const dst_arch = blk: {
            if (src_arch.transitions.remove.get(cid_drop)) |target_idx| {
                break :blk self.archetypes.items[target_idx];
            }
            // `>= 1` and not `>= 2`: the EMPTY archetype is LEGAL, so dropping the
            // last component is a transition to it. The `hasComponent` check above is
            // what makes the bound 1 and not 0.
            std.debug.assert(src_arch.component_ids.len >= 1);
            const target_ids = try gpa.alloc(ComponentId, src_arch.component_ids.len - 1);
            defer gpa.free(target_ids);
            var di: usize = 0;
            for (src_arch.component_ids) |cid| {
                if (cid == cid_drop) continue;
                target_ids[di] = cid;
                di += 1;
            }

            const split = self.splitByStorage(target_ids);
            const target = try self.getOrCreateArchetype(gpa, split.table);
            const src_arch_after = self.archetypes.items[src_loc.archetype_idx];
            try src_arch_after.transitions.remove.put(gpa, cid_drop, target.archetype_id);
            break :blk target;
        };

        try self.entity_locations.ensureUnusedCapacity(gpa, 1);

        const dst_r = try dst_arch.allocateSlot(gpa, self.current_tick);
        const dst_chunk = dst_arch.chunks.items[dst_r.chunk_idx];
        const src_chunk = src_arch.chunks.items[src_loc.chunk_idx];

        for (dst_arch.component_ids, 0..) |dst_cid, i| {
            const src_i = src_arch.componentIndex(dst_cid).?;
            const dst = dst_arch.componentSlot(dst_chunk, i, dst_r.slot);
            const src = src_arch.componentSlot(src_chunk, src_i, src_loc.slot);
            @memcpy(dst, src);

            // Surviving columns keep their pre-migration ticks.
            const src_added = src_arch.addedTick(src_chunk, src_i, src_loc.slot);
            const src_changed = src_arch.changedTick(src_chunk, src_i, src_loc.slot);
            dst_chunk.addedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_added;
            dst_chunk.changedTickColumn(&dst_arch.layout, i)[dst_r.slot] = src_changed;
        }
        dst_arch.entityIds(dst_chunk)[dst_r.slot] = entity;

        if (src_arch.removeSwap(src_loc.chunk_idx, src_loc.slot)) |swapped_id| {
            self.entity_locations.getPtr(swapped_id).?.* = src_loc;
        }
        self.entity_locations.putAssumeCapacity(entity, .{
            .archetype_idx = dst_arch.archetype_id,
            .chunk_idx = dst_r.chunk_idx,
            .slot = dst_r.slot,
        });
    }

    /// The no-filter canonical query. A caller exercising the filters goes through
    /// `queryFiltered` directly.
    pub fn query(self: *World, gpa: std.mem.Allocator) !Query {
        return try self.queryFiltered(gpa, &.{ Transform, Velocity }, .{});
    }

    /// Build a comptime-typed query, auto-registering every type in either set so no
    /// caller registers by hand. The query owns a heap matches list — `defer
    /// q.deinit(gpa)`.
    pub fn queryFiltered(
        self: *World,
        gpa: std.mem.Allocator,
        comptime Components: []const type,
        comptime filters: anytype,
    ) !query_mod.Query(Components, filters) {
        const QueryT = query_mod.Query(Components, filters);
        var q = QueryT.empty();
        errdefer q.deinit(gpa);

        // Resolved once and STORED ON THE QUERY, so the lazy re-scan reuses the ids
        // instead of re-resolving them on every iteration.
        inline for (Components, 0..) |T, i| {
            q.required_ids[i] = try self.ensureRegistered(gpa, T);
        }
        inline for (QueryT.with_types, 0..) |T, i| {
            q.with_ids[i] = try self.ensureRegistered(gpa, T);
        }
        inline for (QueryT.without_types, 0..) |T, i| {
            q.without_ids[i] = try self.ensureRegistered(gpa, T);
        }

        // Creation order, so the matches list — and the iteration order `chunkAt`
        // surfaces — is deterministic.
        for (self.archetypes.items) |arch| {
            if (!query_mod.archetypeMatches(arch, &q.required_ids, &q.with_ids, &q.without_ids)) {
                continue;
            }
            var indices: [Components.len]u32 = undefined;
            for (q.required_ids, 0..) |cid, i| {
                indices[i] = @intCast(arch.componentIndex(cid).?);
            }
            try q.matches.append(gpa, .{ .archetype = arch, .column_indices = indices });
        }

        // After this, every iteration entry compares the archetype count and
        // re-scans the tail on a mismatch.
        q.archetype_view = .{
            .ctx = @ptrCast(self),
            .archetypes_slice = &worldArchetypesSlice,
        };
        q.rescan_gpa = gpa;
        q.last_seen_archetype_count = self.archetypes.items.len;

        return q;
    }

    /// Recomputed on EVERY call, so the rescan loop always sees the current `items`
    /// pointer, which moves when the list reallocates.
    fn worldArchetypesSlice(ctx: *anyopaque) []const *Archetype {
        const w: *World = @ptrCast(@alignCast(ctx));
        return w.archetypes.items;
    }

    /// Build a runtime, `ComponentId`-keyed query — the primitive the Etch
    /// interpreter routes rule selection through, having ids and no Zig type. ONE
    /// conjunctive term, reusing the comptime `Query`'s matcher and rescan body.
    /// `last_seen_archetype_count` starts at 0, so the first `maybeRescan` does the
    /// initial full scan through that same path.
    pub fn queryDynamic(
        self: *World,
        gpa: std.mem.Allocator,
        with_ids: []const ComponentId,
        without_ids: []const ComponentId,
    ) !query_mod.DynamicQuery {
        const with_copy = try gpa.dupe(ComponentId, with_ids);
        errdefer gpa.free(with_copy);
        const without_copy = try gpa.dupe(ComponentId, without_ids);
        errdefer gpa.free(without_copy);

        return .{
            .with_ids = with_copy,
            .without_ids = without_copy,
            .archetype_view = .{
                .ctx = @ptrCast(self),
                .archetypes_slice = &worldArchetypesSlice,
            },
            .rescan_gpa = gpa,
        };
    }

    /// Add a resource. `init_bytes` is duplicated by the store.
    pub fn addResource(self: *World, gpa: std.mem.Allocator, id: ComponentId, init_bytes: []const u8) !void {
        try self.resources.addResource(gpa, id, init_bytes);
    }

    /// Called once per tick, after every rule has run.
    pub fn tickBoundary(self: *World) void {
        self.resources.tickBoundary();
        // The SECOND reset site, and both are required because neither covers the
        // other's population — measured, not assumed: `beginFrame` is unconditional
        // for a Zig host, but the TREE-WALKER gates it on `has_changed`, so an Etch
        // program with no `changed` filter never reset the counter at all and the
        // once-per-tick log fired once per PROGRAM.
        self.resetTickObservations();
    }

    /// Decref and ZERO every resource's persistent-heap payload slot. `World` owns
    /// this walk so a world with no interpreter still reclaims them.
    ///
    /// IDEMPOTENT by the zeroing, which is load-bearing for the teardown ORDER:
    /// `Interpreter.deinit` calls this BEFORE destroying its immortal literals, and
    /// the later `World.deinit` then sees zeroed slots instead of re-reading one
    /// that points at a freed block.
    pub fn releaseResourcePayloads(self: *World, gpa: std.mem.Allocator) void {
        var it = self.resources.entries.iterator();
        while (it.next()) |kv| {
            const rid = kv.key_ptr.*;
            const buf = kv.value_ptr.bytes;
            for (self.registry.componentFields(rid)) |fd| {
                switch (fd.kind) {
                    .string_ => {
                        var ss: persistent.StringSlot = undefined;
                        @memcpy(std.mem.asBytes(&ss), buf[fd.offset .. fd.offset + @sizeOf(persistent.StringSlot)]);
                        if (ss.ptr != 0) {
                            persistent.decref(gpa, @ptrFromInt(ss.ptr));
                            ss.ptr = 0;
                            @memcpy(buf[fd.offset .. fd.offset + @sizeOf(persistent.StringSlot)], std.mem.asBytes(&ss));
                        }
                    },
                    // Its registered drop releases the elements before the block frees.
                    .array_, .map_, .set_ => {
                        var cs: persistent.CollectionSlot = undefined;
                        @memcpy(std.mem.asBytes(&cs), buf[fd.offset .. fd.offset + @sizeOf(persistent.CollectionSlot)]);
                        if (cs.ptr != 0) {
                            persistent.decref(gpa, @ptrFromInt(cs.ptr));
                            cs.ptr = 0;
                            @memcpy(buf[fd.offset .. fd.offset + @sizeOf(persistent.CollectionSlot)], std.mem.asBytes(&cs));
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// For the bench harness's report.
    pub fn chunkCount(self: *const World) usize {
        var total: usize = 0;
        for (self.archetypes.items) |a| total += a.chunkCount();
        return total;
    }
};

/// Word `bit / 64`, position `bit % 64`.
fn setTagBit(bytes: []u8, bit: u32, set: bool) void {
    const off: usize = @as(usize, bit / 64) * 8;
    var word: u64 = 0;
    @memcpy(std.mem.asBytes(&word), bytes[off .. off + 8]);
    const mask = @as(u64, 1) << @intCast(bit % 64);
    if (set) {
        word |= mask;
    } else {
        word &= ~mask;
    }
    @memcpy(bytes[off .. off + 8], std.mem.asBytes(&word));
}

test "registerOnDetach / dispatchOnDetach fires the on_detach seam (M1.0.9)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Spy = struct {
        var fired: u32 = 0;
        var saw_name: bool = false;
        var saw_text: bool = false;
        fn cb(_: ?*anyopaque, _: *World, _: EntityId, name: []const u8, text: ?[]const u8) anyerror!void {
            fired += 1;
            if (std.mem.eql(u8, name, "CombatModule")) saw_name = true;
            if (text != null and std.mem.indexOf(u8, text.?, "Health") != null) saw_text = true;
        }
    };
    Spy.fired = 0;
    Spy.saw_name = false;
    Spy.saw_text = false;

    const e = EntityId{ .index = 1, .generation = 1 };
    const detach_text = "entity.get_mut(Health).max -= 50";

    // No hook registered → dispatch is a no-op (mirror of the on_attach seam).
    try world.dispatchOnDetach(e, "CombatModule", detach_text);
    try std.testing.expectEqual(@as(u32, 0), Spy.fired);

    world.registerOnDetach(null, &Spy.cb);
    try world.dispatchOnDetach(e, "CombatModule", detach_text);
    try std.testing.expectEqual(@as(u32, 1), Spy.fired);
    try std.testing.expect(Spy.saw_name);
    try std.testing.expect(Spy.saw_text);
}

test "per-entity extension side-table tracks add / has / remove (M1.0.9)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const e1 = EntityId{ .index = 1, .generation = 1 };
    const e2 = EntityId{ .index = 2, .generation = 1 };

    try std.testing.expect(!world.hasEntityExtension(e1, "Combat"));
    try std.testing.expectEqual(@as(usize, 0), world.entityExtensions(e1).len);

    try world.addEntityExtension(gpa, e1, "Combat");
    try world.addEntityExtension(gpa, e1, "Merchant");
    try world.addEntityExtension(gpa, e2, "Combat");
    // Re-adding the same name is a no-op (belt-and-braces dedup).
    try world.addEntityExtension(gpa, e1, "Combat");

    try std.testing.expect(world.hasEntityExtension(e1, "Combat"));
    try std.testing.expect(world.hasEntityExtension(e1, "Merchant"));
    try std.testing.expect(world.hasEntityExtension(e2, "Combat"));

    const e1_exts = world.entityExtensions(e1);
    try std.testing.expectEqual(@as(usize, 2), e1_exts.len);
    try std.testing.expectEqualStrings("Combat", e1_exts[0]); // activation order
    try std.testing.expectEqualStrings("Merchant", e1_exts[1]);

    world.removeEntityExtension(gpa, e1, "Combat");
    try std.testing.expect(!world.hasEntityExtension(e1, "Combat"));
    try std.testing.expect(world.hasEntityExtension(e1, "Merchant"));
    try std.testing.expectEqual(@as(usize, 1), world.entityExtensions(e1).len);

    // e2 still has Combat — the set is per-entity.
    try std.testing.expect(world.hasEntityExtension(e2, "Combat"));

    // Draining the last extension drops the map entry; the testing allocator flags
    // any leak of the owned name copies.
    world.removeEntityExtension(gpa, e1, "Merchant");
    try std.testing.expectEqual(@as(usize, 0), world.entityExtensions(e1).len);
}

test "despawn removes the entity's extension entry (M1.1.1-HF1 D7)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Marker = extern struct { v: u32 = 0 };
    const cid = try world.registerComponent(gpa, Marker);

    const e = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    try world.addEntityExtension(gpa, e, "CombatModule");
    try world.addEntityExtension(gpa, e, "MerchantModule");
    try std.testing.expect(world.hasEntityExtension(e, "CombatModule"));
    try std.testing.expectEqual(@as(usize, 2), world.entityExtensions(e).len);

    try world.despawn(gpa, e);

    // The owned name copies were freed by `despawn`, not stranded until `deinit`.
    try std.testing.expect(!world.hasEntityExtension(e, "CombatModule"));
    try std.testing.expect(!world.hasEntityExtension(e, "MerchantModule"));
    try std.testing.expectEqual(@as(usize, 0), world.entityExtensions(e).len);
    try std.testing.expect(!world.isLive(e));
}

test "despawn is allocation-free after spawn (M1.1.1-HF2 C1)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Marker = extern struct { v: u32 = 0 };
    const cid = try world.registerComponent(gpa, Marker);

    const e = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    try std.testing.expect(world.isLive(e));
    const live_before = world.identity.liveCount();

    // Despawn allocates NOTHING, proven by failing every allocation for its whole
    // duration: it must still succeed and reclaim the slot.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try world.despawn(failing.allocator(), e);

    try std.testing.expect(!world.isLive(e));
    try std.testing.expectEqual(live_before - 1, world.identity.liveCount());
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "spawn OOM on archetype storage leaves no orphan identity (M1.1.1-HF2 C1)" {
    const gpa = std.testing.allocator;
    const Marker = extern struct { v: u32 = 0 };

    // Pass 1 — count the allocations a fresh dynamic spawn performs. The last is the
    // chunk allocation, which runs AFTER `identity.allocate`.
    var alloc_count: usize = undefined;
    {
        var w = World.init();
        defer w.deinit(gpa);
        const cid = try w.registerComponent(gpa, Marker);
        var counting = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
        _ = try w.spawnDynamic(counting.allocator(), &[_]ComponentId{cid});
        alloc_count = counting.alloc_index;
    }
    try std.testing.expect(alloc_count > 0);

    // Pass 2 — fail that final allocation. Identity was already allocated, so the
    // spawn's `errdefer` must reclaim it and `liveCount` return to its prior value.
    var w = World.init();
    defer w.deinit(gpa);
    const cid = try w.registerComponent(gpa, Marker);
    const live_before = w.identity.liveCount();

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = alloc_count - 1 });
    try std.testing.expectError(error.OutOfMemory, w.spawnDynamic(failing.allocator(), &[_]ComponentId{cid}));

    try std.testing.expectEqual(live_before, w.identity.liveCount());
    try std.testing.expectEqual(@as(usize, 0), w.entityCount());
}

test "releaseResourcePayloads is idempotent and frees a string block once (M1.1.1-HF2 C4)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // Resources register through the same raw path as components — the resource-only
    // gating of `.string_` lives in the Etch validator, not in the Tier-0 registry.
    const zero16 = [_]u8{0} ** 16;
    const fields = [_]registry_mod.FieldDesc{.{ .name = "s", .offset = 0, .kind = .string_ }};
    const rid = try world.registerComponentRaw(gpa, .{
        .name = "ResWithString",
        .size = 16,
        .alignment = 8,
        .default_bytes = &zero16,
        .fields = &fields,
    });
    try world.addResource(gpa, rid, &zero16);

    // Write a refcounted (refcount 1) persistent string block into the slot.
    const block = try persistent.alloc(gpa, persistent.type_string, 5);
    try std.testing.expectEqual(@as(u32, 1), persistent.refcount(block));
    var ss = persistent.StringSlot{ .ptr = @intFromPtr(block), .len = 5 };
    const buf = world.resources.getMutResource(rid).?;
    @memcpy(buf[0..@sizeOf(persistent.StringSlot)], std.mem.asBytes(&ss));

    // First call frees the block (refcount 1 → 0) and zeroes the slot.
    world.releaseResourcePayloads(gpa);
    // Slot is zeroed → the second call decrefs nothing (no double-free / UAF).
    world.releaseResourcePayloads(gpa);

    @memcpy(std.mem.asBytes(&ss), buf[0..@sizeOf(persistent.StringSlot)]);
    try std.testing.expectEqual(@as(u64, 0), ss.ptr);

    // The deferred `world.deinit` makes a THIRD no-op call, and the testing
    // allocator's leak detection is what proves it.
    // block was reclaimed exactly once.
}

test "addComponentsDynamic migrates once and is atomic under OOM" {
    const backing = std.testing.allocator;
    const va = [_]u8{ 0xAA, 0, 0, 0 };
    const vb = [_]u8{ 0xBB, 0, 0, 0 };
    const vc = [_]u8{ 0xCC, 0, 0, 0 };
    const vd = [_]u8{ 0xDD, 0, 0, 0 };
    const desc = struct {
        fn d(name: []const u8) ComponentDesc {
            return .{ .name = name, .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} };
        }
    }.d;

    // Success path: grouped add of B,C,D onto an entity that has A yields one
    // archetype move with all four values readable.
    {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("GA"));
        const b = try world.registerComponentRaw(backing, desc("GB"));
        const c = try world.registerComponentRaw(backing, desc("GC"));
        const d = try world.registerComponentRaw(backing, desc("GD"));
        const e = try world.spawnDynamicWithValues(backing, &.{a}, &.{&va});
        try world.addComponentsDynamic(backing, e, &.{ b, c, d }, &.{ &vb, &vc, &vd });
        try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
        try std.testing.expectEqualSlices(u8, &vb, world.componentBytes(e, b).?);
        try std.testing.expectEqualSlices(u8, &vc, world.componentBytes(e, c).?);
        try std.testing.expectEqualSlices(u8, &vd, world.componentBytes(e, d).?);
    }

    // Atomic under OOM: at every injected failure point the grouped add either
    // fully lands or leaves the entity in its source archetype with only A.
    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("GA"));
        const b = try world.registerComponentRaw(backing, desc("GB"));
        const c = try world.registerComponentRaw(backing, desc("GC"));
        const d = try world.registerComponentRaw(backing, desc("GD"));
        const e = try world.spawnDynamicWithValues(backing, &.{a}, &.{&va});
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (world.addComponentsDynamic(fa.allocator(), e, &.{ b, c, d }, &.{ &vb, &vc, &vd })) |_| {
            try std.testing.expectEqualSlices(u8, &vd, world.componentBytes(e, d).?);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
            try std.testing.expect(world.componentBytes(e, b) == null);
            try std.testing.expect(world.componentBytes(e, c) == null);
            try std.testing.expect(world.componentBytes(e, d) == null);
        }
    }
}

test "removeComponentsDynamic is atomic under OOM" {
    const backing = std.testing.allocator;
    const va = [_]u8{ 0xAA, 0, 0, 0 };
    const vb = [_]u8{ 0xBB, 0, 0, 0 };
    const vc = [_]u8{ 0xCC, 0, 0, 0 };
    const vd = [_]u8{ 0xDD, 0, 0, 0 };
    const desc = struct {
        fn d(name: []const u8) ComponentDesc {
            return .{ .name = name, .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} };
        }
    }.d;

    // Success path: grouped remove of B,C,D leaves only A.
    {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("RA"));
        const b = try world.registerComponentRaw(backing, desc("RB"));
        const c = try world.registerComponentRaw(backing, desc("RC"));
        const d = try world.registerComponentRaw(backing, desc("RD"));
        const e = try world.spawnDynamicWithValues(backing, &.{ a, b, c, d }, &.{ &va, &vb, &vc, &vd });
        try world.removeComponentsDynamic(backing, e, &.{ b, c, d });
        try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
        try std.testing.expect(world.componentBytes(e, b) == null);
        try std.testing.expect(world.componentBytes(e, c) == null);
        try std.testing.expect(world.componentBytes(e, d) == null);
    }

    // Atomic under OOM: on failure the entity keeps all four components.
    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var world = World.init();
        defer world.deinit(backing);
        const a = try world.registerComponentRaw(backing, desc("RA"));
        const b = try world.registerComponentRaw(backing, desc("RB"));
        const c = try world.registerComponentRaw(backing, desc("RC"));
        const d = try world.registerComponentRaw(backing, desc("RD"));
        const e = try world.spawnDynamicWithValues(backing, &.{ a, b, c, d }, &.{ &va, &vb, &vc, &vd });
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (world.removeComponentsDynamic(fa.allocator(), e, &.{ b, c, d })) |_| {
            try std.testing.expect(world.componentBytes(e, b) == null);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualSlices(u8, &va, world.componentBytes(e, a).?);
            try std.testing.expectEqualSlices(u8, &vb, world.componentBytes(e, b).?);
            try std.testing.expectEqualSlices(u8, &vc, world.componentBytes(e, c).?);
            try std.testing.expectEqualSlices(u8, &vd, world.componentBytes(e, d).?);
        }
    }
}

test "grouped ops reject duplicate / absent components (R11c) without panicking" {
    const backing = std.testing.allocator;
    const v = [_]u8{ 0x11, 0, 0, 0 };
    const desc = struct {
        fn d(name: []const u8) ComponentDesc {
            return .{ .name = name, .size = 4, .alignment = 4, .default_bytes = &[_]u8{0} ** 4, .fields = &.{} };
        }
    }.d;

    var world = World.init();
    defer world.deinit(backing);
    const a = try world.registerComponentRaw(backing, desc("DA"));
    const b = try world.registerComponentRaw(backing, desc("DB"));
    const c = try world.registerComponentRaw(backing, desc("DC"));
    const e = try world.spawnDynamicWithValues(backing, &.{a}, &.{&v});

    // addComponentsDynamic: a cid already on the entity → DuplicateComponent.
    try std.testing.expectError(error.DuplicateComponent, world.addComponentsDynamic(backing, e, &.{a}, &.{&v}));
    // addComponentsDynamic: a cid repeated within `cids` → DuplicateComponent.
    try std.testing.expectError(error.DuplicateComponent, world.addComponentsDynamic(backing, e, &.{ b, b }, &.{ &v, &v }));
    // The entity is untouched by the rejected adds (still just A).
    try std.testing.expect(world.componentBytes(e, a) != null);
    try std.testing.expect(world.componentBytes(e, b) == null);

    // Give it A,B,C for the remove checks.
    try world.addComponentsDynamic(backing, e, &.{ b, c }, &.{ &v, &v });
    // removeComponentsDynamic: an absent cid → UnknownComponent.
    const d = try world.registerComponentRaw(backing, desc("DD"));
    try std.testing.expectError(error.UnknownComponent, world.removeComponentsDynamic(backing, e, &.{d}));
    // removeComponentsDynamic: a repeated cid → DuplicateComponent.
    try std.testing.expectError(error.DuplicateComponent, world.removeComponentsDynamic(backing, e, &.{ b, b }));
    // Still intact — the rejects happen before any mutation.
    try std.testing.expect(world.componentBytes(e, a) != null);
    try std.testing.expect(world.componentBytes(e, b) != null);
    try std.testing.expect(world.componentBytes(e, c) != null);
}
