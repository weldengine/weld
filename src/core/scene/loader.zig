//! `.scene.bin` runtime loader — reads a cooked image back into a live `World`
//! (`engine-scene-serialization.md` §4).
//!
//! Reuses `accessor.zig` VERBATIM — the zero-copy read half of the codec — and adds
//! only the runtime steps: identity remap, per-entity instantiation, the UUID map and
//! the `on_spawned` lifecycle. No new storage primitive.
//!
//! Tier discipline: `weld_core` internals only, never `weld_etch` (`ARCH-013`).

const std = @import("std");

const format = @import("format.zig");
const accessor_mod = @import("accessor.zig");
const validate = @import("validate.zig");
const registry_mod = @import("../ecs/registry.zig");
const world_mod = @import("../ecs/world.zig");
const observers_mod = @import("../ecs/observers.zig");
const command_buffer_mod = @import("../ecs/command_buffer.zig");
const fs = @import("../platform/fs.zig");
const persistent = @import("../memory/persistent.zig");

const Accessor = accessor_mod.Accessor;
const ComponentId = registry_mod.ComponentId;
const World = world_mod.World;
const EntityId = world_mod.EntityId;

/// Errors from opening + integrity-checking a `.scene.bin` byte image.
/// `format.ReadError` covers a truncated / wrong-magic / wrong-version file;
/// `CorruptScene` is a content-hash mismatch (the bytes were altered after the
/// cook recorded their `XxHash64`); `MalformedScene` is a structural
/// inconsistency caught by `validate.structure` (`StructureError`).
pub const OpenError = format.ReadError || error{CorruptScene} || StructureError;

/// Errors from mapping on-disk schema identity to the runtime registry.
/// `UnknownComponent`: a scene type the running program never registered
/// (Phase 1 has no auto-registration from the on-disk `SchemaEntry` —
/// `engine-scene-serialization.md` §4). `SchemaMismatch`: the type is
/// registered but its size/alignment diverge from the cooked layout, so
/// byte-copying its columns into storage would corrupt it.
pub const RemapError = error{ UnknownComponent, SchemaMismatch } || std.mem.Allocator.Error;

/// Raised for a scene that opens and hashes valid but is structurally invalid —
/// e.g. an entity whose parent ordinal points past the UUID table. **Distinct
/// from `error.CorruptScene`** (a content-hash mismatch): the bytes are intact
/// (the cook's `XxHash64` matches), the scene structure is not. A well-formed
/// cook never produces this — it is a defensive guard on external input.
pub const StructureError = error{MalformedScene};

/// Resolves an extension prefab name (from the scene's Prefab ID Table) to its
/// cooked `.prefab.bin` bytes at load — the runtime twin of the
/// cook's `BaseResolver`. The bytes must outlive the load. Null = unknown name
/// (the loader errors `UnknownExtension`). Wired to a project/asset registry at
/// runtime; tests wire it to an in-process buffer.
pub const ExtensionResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    pub fn resolve(self: ExtensionResolver, name: []const u8) ?[]const u8 {
        return self.resolveFn(self.ctx, name);
    }
};

/// Open a `.scene.bin` byte image and return a zero-copy `Accessor` borrowing it.
///
/// THE ORDER IS LOAD-BEARING — header, then hash, then structure. `verifyHash` is no
/// defence against a crafted image, the hash being recomputable, so
/// `validate.structure` runs REGARDLESS of it and walks the raw bytes with checked
/// arithmetic. That validator is the single gate that lets every later `Accessor`
/// getter trust the file-controlled offsets it dereferences, so no caller may build
/// an accessor any other way on externally-supplied bytes.
///
/// Errors: `TooShort` / `BadMagic` / `BadVersion` on the header, `CorruptScene` on the
/// content hash, `MalformedScene` on an inconsistent structure.
pub fn openVerified(bytes: []const u8) OpenError!Accessor {
    const acc = try Accessor.open(bytes);
    if (!acc.verifyHash()) return error.CorruptScene;
    try validate.structure(bytes, acc.header);
    return acc;
}

/// Build the schema-remap table: on-disk schema index -> runtime `ComponentId`.
///
/// Identity is the component NAME (`engine-ecs-internals.md` §10), and each entry's
/// cooked size and alignment are checked against the runtime layout — that check is
/// what stops a scene cooked against a different layout from feeding mismatched bytes
/// into storage. The caller owns the returned slice.
///
/// Errors: `UnknownComponent`, `SchemaMismatch` on diverging size or alignment,
/// `MalformedScene` when two schema entries resolve to one runtime id, `OutOfMemory`.
pub fn buildSchemaRemap(gpa: std.mem.Allocator, world: *const World, acc: Accessor) (RemapError || StructureError)![]ComponentId {
    const count = acc.schemaCount();
    const remap = try gpa.alloc(ComponentId, count);
    errdefer gpa.free(remap);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const s = acc.schema(i);
        const id = world.componentId(s.name) orelse return error.UnknownComponent;
        if (s.size != world.registry.componentSize(id) or
            s.alignment != world.registry.componentAlignment(id))
        {
            return error.SchemaMismatch;
        }
        remap[i] = id;
    }
    // Two schema entries resolving to one runtime id would make the remap ambiguous.
    for (remap, 0..) |a, ai| {
        for (remap[ai + 1 ..]) |b| {
            if (a == b) return error.MalformedScene;
        }
    }
    return remap;
}

/// 16-byte UUID to runtime `EntityId`, built as the scene loads.
pub const UuidMap = std.AutoHashMapUnmanaged([16]u8, EntityId);

/// What a load produces: every instantiated entity in load order, the UUID map, and
/// the backing mapping for the `loadScene(path)` entry.
///
/// Component data is COPIED into ECS storage during the load, so the entities outlive
/// the mapping — `mmap` is held only so its lifetime is the caller's to end. Loaded
/// resource `string` blocks are refcounted and owned by their `StringSlot`s, NOT by
/// this result: the resource owner reclaims them.
pub const LoadResult = struct {
    spawned: []EntityId,
    uuid_to_entity: UuidMap,
    mmap: ?fs.Mmap,

    /// Free the loader-owned allocations and close the backing mapping.
    pub fn deinit(self: *LoadResult, gpa: std.mem.Allocator) void {
        gpa.free(self.spawned);
        self.uuid_to_entity.deinit(gpa);
        if (self.mmap) |*m| m.close();
        self.* = undefined;
    }
};

/// Count of entries in the on-disk UUID table, derived from the header offsets.
fn uuidCount(acc: Accessor) u32 {
    return (acc.header.schema_table_offset - acc.header.uuid_table_offset) / 16;
}

/// One resource the loader wrote, recorded for commit or rollback.
const ResourceEdit = struct {
    cid: ComponentId,
    snapshot: ?[]u8,
    /// The resource's dirty bit BEFORE the loader touched it, so a rejected load
    /// leaves no spurious change signal.
    dirty_before: bool,
};

const ResourceJournal = std.ArrayListUnmanaged(ResourceEdit);

/// Decref every `string_` field block referenced by `bytes`.
fn decrefResourceStrings(world: *const World, gpa: std.mem.Allocator, cid: ComponentId, bytes: []const u8) void {
    for (world.registry.componentFields(cid)) |fd| {
        if (fd.kind != .string_) continue;
        var ss: persistent.StringSlot = undefined;
        @memcpy(std.mem.asBytes(&ss), bytes[fd.offset..][0..@sizeOf(persistent.StringSlot)]);
        if (ss.ptr != 0) persistent.decref(gpa, @ptrFromInt(ss.ptr));
    }
}

/// Commit the loader's resource writes, decreffing each replaced old block.
fn commitResources(world: *const World, gpa: std.mem.Allocator, journal: *ResourceJournal) void {
    for (journal.items) |edit| {
        if (edit.snapshot) |snap| {
            decrefResourceStrings(world, gpa, edit.cid, snap);
            gpa.free(snap);
        }
    }
    journal.deinit(gpa);
}

/// Roll the loader's resource writes back, best-effort under OOM.
fn rollbackResources(world: *World, gpa: std.mem.Allocator, journal: *ResourceJournal) void {
    // LIFO: an undo log replays in the opposite order to the one it recorded, or a
    // duplicate same-resource entry corrupts the refcount.
    var k: usize = journal.items.len;
    while (k > 0) {
        k -= 1;
        const edit = journal.items[k];
        if (world.resources.getMutResource(edit.cid)) |live| {
            decrefResourceStrings(world, gpa, edit.cid, live);
        }
        if (edit.snapshot) |snap| {
            if (world.resources.getMutResource(edit.cid)) |live| @memcpy(live, snap);
            gpa.free(snap);
            // Restore the pre-load dirty bit, so a rejected load leaves no `changed` signal.
            world.resources.setDirty(edit.cid, edit.dirty_before);
        } else {
            world.resources.removeResource(gpa, edit.cid) catch {};
        }
    }
    journal.deinit(gpa);
}

/// Load a cooked byte image into `world`; the caller owns `bytes`.
///
/// TWO-PHASE, and that is the ordering guarantee: EVERY loaded entity exists before
/// any `on_spawned` fires — phase 1 spawns through a path that dispatches no
/// observers, phase 2 fires them per entity.
///
/// Errors: the open and remap sets, `MalformedScene`, allocation failure, plus
/// anything an `on_spawned` observer propagates.
pub fn loadFromBytes(world: *World, gpa: std.mem.Allocator, bytes: []const u8, ext_resolver: ?ExtensionResolver) anyerror!LoadResult {
    const acc = try openVerified(bytes);

    const remap = try buildSchemaRemap(gpa, world, acc);
    defer gpa.free(remap);

    var spawned: std.ArrayListUnmanaged(EntityId) = .empty;
    defer spawned.deinit(gpa);
    var uuid_to_entity: UuidMap = .empty;
    errdefer uuid_to_entity.deinit(gpa);
    var journal: ResourceJournal = .empty;

    // The load is transactional: on any error after the first spawn, the errdefer
    // despawns in reverse order and rolls the resource writes back.
    var committed = false;
    errdefer if (!committed) {
        rollbackResources(world, gpa, &journal);
        var k: usize = spawned.items.len;
        while (k > 0) {
            k -= 1;
            world.despawn(gpa, spawned.items[k]) catch |e|
                std.log.warn("scene load rollback: despawn failed: {t}", .{e});
        }
    };

    try instantiate(world, gpa, acc, remap, &spawned, &uuid_to_entity);
    // Cross-references after every entity exists (a reference can point forward),
    // before resources + on_spawned so a rule sees fully-linked entities.
    try resolveCrossRefs(world, acc, remap, uuid_to_entity);
    // Resources before extensions/on_spawned so a hook/rule can read them.
    try loadResources(world, gpa, acc, remap, &journal);
    // Extension activation: add each active extension's components +
    // fire the `on_attach` seam. After resources, before `on_spawned`.
    try applyExtensions(world, gpa, acc, uuid_to_entity, ext_resolver);
    // Drain the structural commands the `on_attach` hooks queued.
    {
        var hook_drain = command_buffer_mod.CommandBuffer.init(gpa, world);
        defer hook_drain.deinit();
        try observers_mod.flushWithObservers(&hook_drain, &world.observer_registry);
    }
    try dispatchSpawnLifecycle(world, gpa, spawned.items);

    // Built BEFORE the commit, so a dupe OOM still rolls back.
    const spawned_slice = try gpa.dupe(EntityId, spawned.items);

    // Commit the resource writes: decref each replaced old block; the new blocks
    // stay live, owned by the resource slots. Infallible; frees the journal.
    commitResources(world, gpa, &journal);
    committed = true;

    return .{
        .spawned = spawned_slice,
        .uuid_to_entity = uuid_to_entity,
        .mmap = null,
    };
}

/// Load a cooked `.scene.bin` from `path`; the result owns the mapping.
pub fn loadScene(world: *World, gpa: std.mem.Allocator, path: []const u8, ext_resolver: ?ExtensionResolver) anyerror!LoadResult {
    var mmap = try fs.mmapFile(gpa, path);
    errdefer mmap.close();
    var result = try loadFromBytes(world, gpa, mmap.bytes, ext_resolver);
    result.mmap = mmap;
    return result;
}

/// Phase 1 — instantiate every entity of every archetype block.
///
/// The gathered bytes are in on-disk COLUMN order; the spawn surface reorders by id
/// AND PARTITIONS BY STORAGE MODE, so an id named by the block may never reach an
/// archetype at all. Each parent ordinal is validated but NO parent link is applied —
/// no runtime hierarchy component exists yet.
fn instantiate(
    world: *World,
    gpa: std.mem.Allocator,
    acc: Accessor,
    remap: []const ComponentId,
    spawned: *std.ArrayListUnmanaged(EntityId),
    uuid_to_entity: *UuidMap,
) !void {
    const ucount = uuidCount(acc);
    const arch_count = acc.archetypeCount();

    // Both maps are pre-reserved to the load's totals, which makes every per-entity
    // insert infallible. That matters for the rollback: a post-spawn OOM must never
    // strand a spawned entity outside `spawned`, which is the slice the errdefer
    // despawns — such an entity would be a live orphan nothing reclaims. The
    // reservations are the only fallible step here and they run BEFORE any spawn.
    var total_entities: usize = 0;
    {
        var bi: u32 = 0;
        while (bi < arch_count) : (bi += 1) total_entities += acc.archetype(bi).entity_count;
    }
    // A hash-valid malformed scene can still declare counts that overflow the sum.
    if (total_entities > std.math.maxInt(u32)) return error.MalformedScene;
    try spawned.ensureTotalCapacity(gpa, total_entities);
    // The hash map's capacity is a `u32` (`Size`); the guard above GUARANTEES
    // `total_entities` fits, so the `@intCast` cannot truncate or panic.
    try uuid_to_entity.ensureTotalCapacity(gpa, @intCast(total_entities));

    var ai: u32 = 0;
    while (ai < arch_count) : (ai += 1) {
        const block = acc.archetype(ai);
        const cc = block.component_count;

        // Per-block component ids (constant across the block's entities).
        const ids = try gpa.alloc(ComponentId, cc);
        defer gpa.free(ids);
        for (0..cc) |c| ids[c] = remap[block.schemaIndex(c)];

        // Per-slot payload views, reused each slot.
        const payloads = try gpa.alloc([]const u8, cc);
        defer gpa.free(payloads);

        var slot: usize = 0;
        while (slot < block.entity_count) : (slot += 1) {
            // Validate the UUID ordinal BEFORE dereferencing the table with it.
            const uuid_ord = block.entityUuidOrdinal(slot);
            if (uuid_ord >= ucount) return error.MalformedScene;

            for (0..cc) |c| payloads[c] = block.componentSlot(c, slot);
            const eid = try world.spawnDynamicWithValues(gpa, ids, payloads);
            // Recorded FIRST, so the rollback covers `eid` even if the next step fails.
            spawned.appendAssumeCapacity(eid);
            const gop = uuid_to_entity.getOrPutAssumeCapacity(acc.uuidAt(uuid_ord).*);
            // A UUID ordinal shared by two entities is malformed (the cooker
            // never emits one); reject rather than silently overwrite the map.
            if (gop.found_existing) return error.MalformedScene;
            gop.value_ptr.* = eid;

            // Structural (not hash) validity: a parent ordinal must index the
            // UUID table or be `no_parent`. The link itself is not applied (no
            // runtime hierarchy component yet).
            const parent = block.entityParent(slot);
            if (parent != format.no_parent and parent >= ucount) return error.MalformedScene;
        }
    }
}

/// Resolve the Cross-references Table, patching each bearing entity field to a handle.
fn resolveCrossRefs(world: *World, acc: Accessor, remap: []const ComponentId, uuid_to_entity: UuidMap) !void {
    const ucount = uuidCount(acc);
    const count = acc.crossrefsCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const e = acc.crossref(i);
        if (e.source_uuid_ordinal >= ucount or e.target_uuid_ordinal >= ucount) return error.MalformedScene;
        if (e.schema_index >= remap.len) return error.MalformedScene;

        const src = uuid_to_entity.get(acc.uuidAt(e.source_uuid_ordinal).*) orelse return error.MalformedScene;
        const tgt = uuid_to_entity.get(acc.uuidAt(e.target_uuid_ordinal).*) orelse return error.MalformedScene;
        const cid = remap[e.schema_index];

        const slot = world.componentBytes(src, cid) orelse return error.MalformedScene;
        const off = e.field_offset;
        if (@as(usize, off) + @sizeOf(EntityId) > slot.len) return error.MalformedScene;
        @memcpy(slot[off..][0..@sizeOf(EntityId)], std.mem.asBytes(&tgt));
        world.markComponentChangedDyn(src, cid);
    }
}

/// Extension activation at load: materialise each active extension's components.
fn applyExtensions(world: *World, gpa: std.mem.Allocator, acc: Accessor, uuid_to_entity: UuidMap, ext_resolver: ?ExtensionResolver) !void {
    const count = acc.extensionsCount();
    if (count == 0) return;
    const ucount = uuidCount(acc);
    const resolver = ext_resolver orelse return error.MissingExtensionResolver;
    const pid_count = acc.prefabIdCount();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const e = acc.extension(i);
        if (e.uuid_ordinal >= ucount) return error.MalformedScene;
        const entity = uuid_to_entity.get(acc.uuidAt(e.uuid_ordinal).*) orelse return error.MalformedScene;
        var j: u32 = 0;
        while (j < e.extension_count) : (j += 1) {
            const pid = e.extensionId(j);
            if (pid >= pid_count) return error.MalformedScene;
            const name = acc.prefabName(pid);
            const ext_bytes = resolver.resolve(name) orelse return error.UnknownExtension;
            try activateExtension(world, gpa, entity, name, ext_bytes);
        }
    }
}

/// The single archetype block of a mono-entity extension prefab; anything else is
/// malformed.
fn extEntityArchetype(ext: Accessor) !Accessor.Archetype {
    var found: ?Accessor.Archetype = null;
    var total: u64 = 0; // u64 so the sum cannot wrap (entity_counts are u32)
    var ai: u32 = 0;
    while (ai < ext.archetypeCount()) : (ai += 1) {
        const a = ext.archetype(ai);
        total += a.entity_count;
        if (found == null and a.entity_count >= 1) found = a;
    }
    if (total == 0) return error.EmptyExtension;
    if (total > 1) return error.MultiEntityExtensionUnsupported;
    return found.?; // total == 1 ⇒ exactly one archetype has entity_count == 1
}

/// Activate one extension on one entity — the shared path used by load, by the
/// runtime entry, and by the interpreter's deferred flush.
///
/// RESERVE-THEN-MUTATE, so it is all-or-nothing under OOM: reject re-activation and
/// resolve the mono-entity archetype, prevalidate with ZERO mutation, reserve the
/// record, then perform the SINGLE fallible mutation as one grouped add — one
/// archetype migration, not N. Through that step the entity is left untouched on any
/// failure. The activation commits BEFORE the hook, and a hook error propagates
/// without unwinding it.
///
/// A component the entity already carries is REJECTED rather than overwritten: the
/// `extends` model is strictly additive, and the fatal cook counterpart is what makes
/// `cooked => loadable` hold. Authority: `engine-scene-serialization.md`.
pub fn activateExtension(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, ext_bytes: []const u8) !void {
    // Refuses a hook-only re-activation too, which carries no component to conflict.
    if (world.hasEntityExtension(entity, name)) return error.ExtensionAlreadyActive;
    const ext = try openVerified(ext_bytes);
    const arch = try extEntityArchetype(ext); // strict mono-entity cardinality
    const comp_count = arch.component_count;

    // Step 1 — prevalidate + collect (ZERO mutation): ids, size, conflict.
    const cids = try gpa.alloc(ComponentId, comp_count);
    defer gpa.free(cids);
    const values = try gpa.alloc([]const u8, comp_count);
    defer gpa.free(values);
    var c: usize = 0;
    while (c < comp_count) : (c += 1) {
        const sch = ext.schema(arch.schemaIndex(c));
        const cid = world.componentId(sch.name) orelse return error.UnknownComponent;
        if (sch.size != world.registry.componentSize(cid)) return error.SchemaMismatch;
        if (world.componentBytes(entity, cid) != null) return error.ExtensionComponentConflict;
        cids[c] = cid;
        values[c] = arch.componentSlot(c, 0);
    }

    // Fallible, and still no observable mutation.
    const owned = try world.reserveEntityExtension(gpa, entity, name);
    var committed = false;
    errdefer if (!committed) gpa.free(owned);

    // Step 3 — grouped add: THE single fallible component mutation (atomic).
    try world.addComponentsDynamic(gpa, entity, cids, values);

    // Infallible from here; takes ownership of the name copy.
    world.commitEntityExtension(gpa, entity, owned);
    committed = true;
    const on_attach_text: ?[]const u8 = if (ext.hookCount() > 0) ext.hook(0).on_attach else null;
    try world.dispatchOnAttach(entity, name, on_attach_text);
}

/// Runtime activation entry, reached from Etch and from direct callers.
pub fn runtimeActivate(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, resolver: ExtensionResolver) !void {
    const bytes = resolver.resolve(name) orelse return error.UnknownExtension;
    try activateExtension(world, gpa, entity, name, bytes);
}

/// Deactivate one extension on one entity from its cooked bytes.
///
/// THE HOOK ORDER IS THE GUARANTEE: prevalidate with zero mutation, PREPARE the
/// grouped remove (all the fallible work, nothing observable), fire `on_detach` FIRST
/// while it can still read the present components, and only then COMMIT — so once the
/// hook has succeeded NOT ONE fallible step remains, and a hook failure aborts the
/// prepared remove leaving the entity fully active.
///
/// Reject-on-conflict at activation is what makes removal need no provenance: no two
/// active declarants ever share a component.
pub fn deactivateExtension(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, ext_bytes: []const u8) !void {
    if (!world.hasEntityExtension(entity, name)) return error.ExtensionNotActive;
    const ext = try openVerified(ext_bytes);
    const arch = try extEntityArchetype(ext); // strict mono-entity cardinality
    const comp_count = arch.component_count;

    // Prevalidate and collect the declared components currently present.
    const cids_buf = try gpa.alloc(ComponentId, comp_count);
    defer gpa.free(cids_buf);
    var n: usize = 0;
    var c: usize = 0;
    while (c < comp_count) : (c += 1) {
        const sch = ext.schema(arch.schemaIndex(c));
        const cid = world.componentId(sch.name) orelse return error.UnknownComponent;
        if (world.componentBytes(entity, cid) != null) {
            cids_buf[n] = cid;
            n += 1;
        }
    }

    const on_detach_text: ?[]const u8 = if (ext.hookCount() > 0) ext.hook(0).on_detach else null;

    // A hook-only extension has no structural change to prepare.
    if (n == 0) {
        try world.dispatchOnDetach(entity, name, on_detach_text);
        world.removeEntityExtension(gpa, entity, name);
        return;
    }

    // Step 2 — PREPARE (all fallible work; no observable mutation yet).
    const prepared = try world.prepareRemoveComponentsDynamic(gpa, entity, cids_buf[0..n]);
    // `on_detach` FIRST; the errdefer aborts the prepared remove if it throws.
    errdefer world.abortRemoveComponentsDynamic(gpa, prepared);
    try world.dispatchOnDetach(entity, name, on_detach_text);

    // Step 4 — commit (infallible) + drop the record (infallible).
    world.commitRemoveComponentsDynamic(gpa, prepared);
    world.removeEntityExtension(gpa, entity, name);
}

/// Runtime deactivation entry, reached from Etch and from direct callers.
pub fn runtimeDeactivate(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, resolver: ExtensionResolver) !void {
    const bytes = resolver.resolve(name) orelse return error.UnknownExtension;
    try deactivateExtension(world, gpa, entity, name, bytes);
}

/// Load the resources block.
///
/// Per resource: snapshot the current bytes, install the POD image (string slots are
/// zeroed on disk), then intern each cooked string into the persistent heap as a
/// REFCOUNTED block — never immortal — and write its `StringSlot`. The new blocks are
/// owned by the slot; the old ones the snapshot captured are decreffed at commit, and
/// each touched resource is journalled so the load stays transactional. An empty
/// string keeps the zeroed slot.
///
/// A scene resource OVERRIDES a value the running program already set.
fn loadResources(
    world: *World,
    gpa: std.mem.Allocator,
    acc: Accessor,
    remap: []const ComponentId,
    journal: *ResourceJournal,
) !void {
    const count = acc.resourceCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const r = acc.resource(i);
        const cid = remap[r.schema_index];

        for (world.registry.componentFields(cid)) |fd| switch (fd.kind) {
            .array_, .map_, .set_ => return error.CollectionResourceFieldUnsupported,
            else => {},
        };

        const size = world.registry.componentSize(cid);
        std.debug.assert(r.data.len == size);

        // Reserved up front, so recording the edit cannot fail after the write.
        try journal.ensureUnusedCapacity(gpa, 1);

        // Capture the dirty bit before the write, for the rollback.
        const dirty_before = world.resources.isDirty(cid);

        var snapshot: ?[]u8 = null;
        const dst = if (world.resources.getMutResource(cid)) |existing| blk: {
            const snap = try gpa.dupe(u8, existing);
            snapshot = snap;
            @memcpy(existing, r.data);
            break :blk existing;
        } else blk: {
            try world.addResource(gpa, cid, r.data);
            break :blk world.resources.getMutResource(cid).?;
        };

        // Journalled BEFORE the fallible string writes, so a mid-write OOM still rolls back.
        journal.appendAssumeCapacity(.{ .cid = cid, .snapshot = snapshot, .dirty_before = dirty_before });

        for (world.registry.componentFields(cid)) |fd| {
            if (fd.kind != .string_) continue;
            const sval = r.stringField(fd.offset) orelse continue;
            if (sval.len == 0) continue; // empty string → leave the zeroed slot
            const block = try persistent.alloc(gpa, persistent.type_string, sval.len);
            @memcpy(block[0..sval.len], sval);
            const fslot: persistent.StringSlot = .{ .ptr = @intFromPtr(block), .len = @intCast(sval.len) };
            @memcpy(dst[fd.offset..][0..@sizeOf(persistent.StringSlot)], std.mem.asBytes(&fslot));
        }
    }
}

/// Phase 2 — fire the `on_spawned` lifecycle for every loaded entity.
fn dispatchSpawnLifecycle(world: *World, gpa: std.mem.Allocator, spawned: []const EntityId) !void {
    var drain = command_buffer_mod.CommandBuffer.init(gpa, world);
    defer drain.deinit();

    // Drain any commands left queued from prior observer activity.
    try observers_mod.flushWithObservers(&drain, &world.observer_registry);
    // Every entity already exists — now fire its spawn hook.
    for (spawned) |eid| try world.dispatchOnSpawned(gpa, eid);
    // Apply whatever the `on_spawned` rules queued.
    try observers_mod.flushWithObservers(&drain, &world.observer_registry);
}

/// Read a little-endian `u32` at file offset `off`.
fn readU32At(acc: Accessor, off: u32) u32 {
    return std.mem.readInt(u32, acc.bytes[off..][0..4], .little);
}

const testing = std.testing;
const writer = @import("writer.zig");
const Registry = registry_mod.Registry;

/// Test helper: serialize a 1-archetype, 1-entity `.scene.bin` over `reg` (the
/// cook registry) holding the single component `cid` with a zeroed column.
/// Returns the caller-owned byte image (`gpa.free`).
fn buildOneCompScene(gpa: std.mem.Allocator, reg: *const Registry, cid: ComponentId) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "E0")});
    const uuids = try a.dupe([16]u8, &.{[_]u8{0} ** 16});
    const col = try a.alloc(u8, reg.componentSize(cid)); // 1 entity
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent },
    });
    const ids = try a.dupe(ComponentId, &.{cid});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = 1,
        .columns = cols,
        .entities = ents,
    }});
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

fn registerRaw(gpa: std.mem.Allocator, reg: *Registry, name: []const u8, size: u16, alignment: u16) !ComponentId {
    const zeros = try gpa.alloc(u8, size);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    return try reg.registerComponentRaw(gpa, .{
        .name = name,
        .size = size,
        .alignment = alignment,
        .default_bytes = zeros,
        .fields = &.{},
    });
}

/// Test helper: register a resource `<name> { v: string }` — one 16-byte
/// `.string_` slot at offset 0.
fn registerStringResource(gpa: std.mem.Allocator, reg: *Registry, name: []const u8) !ComponentId {
    return try reg.registerComponentRaw(gpa, .{
        .name = name,
        .size = 16,
        .alignment = 8,
        .default_bytes = &[_]u8{0} ** 16,
        .fields = &[_]registry_mod.FieldDesc{
            .{ .name = "v", .offset = 0, .kind = .string_ },
        },
    });
}

/// Test helper: register a resource `<name> { xs: T[] }` — one 8-byte `.array_`
/// (collection) slot at offset 0, which the loader must reject.
fn registerArrayResource(gpa: std.mem.Allocator, reg: *Registry, name: []const u8) !ComponentId {
    return try reg.registerComponentRaw(gpa, .{
        .name = name,
        .size = 8,
        .alignment = 8,
        .default_bytes = &[_]u8{0} ** 8,
        .fields = &[_]registry_mod.FieldDesc{
            .{ .name = "xs", .offset = 0, .kind = .array_ },
        },
    });
}

/// Test helper: cook a 0-entity scene with one string resource `res_cid` whose
/// field holds `value`. Caller-owned bytes.
fn buildStringResourceScene(gpa: std.mem.Allocator, reg: *const Registry, res_cid: ComponentId, value: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const strings = try a.dupe([]const u8, &.{try a.dupe(u8, value)});
    const data = try a.alloc(u8, 16);
    @memset(data, 0);
    const string_fields = try a.dupe(format.StringFieldRef, &.{.{ .offset = 0, .str = 0 }});
    const resources = try a.dupe(format.ResourceEntry, &.{.{
        .schema_id = res_cid,
        .data = data,
        .string_fields = string_fields,
    }});
    var model: format.CookModel = .{
        .strings = strings,
        .uuids = &.{},
        .resources = resources,
        .archetypes = &.{},
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

/// Test helper: cook a scene that spawns one `ecid` entity, overrides string
/// resource `settings_cid` with `"new"`, then carries a collection resource
/// `bag_cid` (LAST) — so the loader's collection rejection fires AFTER the spawn
/// and the Settings write, exercising the full transactional rollback.
fn buildSpawnThenFailScene(
    gpa: std.mem.Allocator,
    reg: *const Registry,
    ecid: ComponentId,
    settings_cid: ComponentId,
    bag_cid: ComponentId,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    // strings[0] = entity name, strings[1] = the new Settings value.
    const names = try a.dupe([]const u8, &.{ try a.dupe(u8, "E0"), try a.dupe(u8, "new") });
    const uuids = try a.dupe([16]u8, &.{[_]u8{0} ** 16});
    const col = try a.alloc(u8, reg.componentSize(ecid));
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent },
    });
    const ids = try a.dupe(ComponentId, &.{ecid});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = 1,
        .columns = cols,
        .entities = ents,
    }});
    const s_data = try a.alloc(u8, reg.componentSize(settings_cid));
    @memset(s_data, 0);
    const s_fields = try a.dupe(format.StringFieldRef, &.{.{ .offset = 0, .str = 1 }});
    const b_data = try a.alloc(u8, reg.componentSize(bag_cid));
    @memset(b_data, 0);
    const resources = try a.dupe(format.ResourceEntry, &.{
        .{ .schema_id = settings_cid, .data = s_data, .string_fields = s_fields },
        .{ .schema_id = bag_cid, .data = b_data, .string_fields = &.{} },
    });
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = resources,
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

/// Test helper: cook a 0-entity scene with TWO string-resource entries of the
/// SAME `settings_cid` ("a" then "b"), then a collection resource `bag_cid`
/// (LAST) that trips the loader's rejection. The rollback must undo the two
/// same-cid edits in LIFO order; a forward undo would corrupt the refcount.
fn buildDupResourceFailScene(
    gpa: std.mem.Allocator,
    reg: *const Registry,
    settings_cid: ComponentId,
    bag_cid: ComponentId,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const strings = try a.dupe([]const u8, &.{ try a.dupe(u8, "a"), try a.dupe(u8, "b") });
    const d0 = try a.alloc(u8, reg.componentSize(settings_cid));
    @memset(d0, 0);
    const d1 = try a.alloc(u8, reg.componentSize(settings_cid));
    @memset(d1, 0);
    const b_data = try a.alloc(u8, reg.componentSize(bag_cid));
    @memset(b_data, 0);
    const sf0 = try a.dupe(format.StringFieldRef, &.{.{ .offset = 0, .str = 0 }});
    const sf1 = try a.dupe(format.StringFieldRef, &.{.{ .offset = 0, .str = 1 }});
    const resources = try a.dupe(format.ResourceEntry, &.{
        .{ .schema_id = settings_cid, .data = d0, .string_fields = sf0 },
        .{ .schema_id = settings_cid, .data = d1, .string_fields = sf1 },
        .{ .schema_id = bag_cid, .data = b_data, .string_fields = &.{} },
    });
    var model: format.CookModel = .{
        .strings = strings,
        .uuids = &.{},
        .resources = resources,
        .archetypes = &.{},
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

test "buildSchemaRemap resolves on-disk schema names to runtime ids" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);

    const bytes = try buildOneCompScene(gpa, &world.registry, pos);
    defer gpa.free(bytes);

    const acc = try openVerified(bytes);
    const remap = try buildSchemaRemap(gpa, &world, acc);
    defer gpa.free(remap);

    try testing.expectEqual(@as(usize, 1), remap.len);
    try testing.expectEqual(pos, remap[0]);
}

test "buildSchemaRemap errors UnknownComponent for an unregistered name" {
    const gpa = testing.allocator;

    // Cook a scene referencing "Ghost" through a standalone cook registry.
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const ghost = try registerRaw(gpa, &cook_reg, "Ghost", 4, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, ghost);
    defer gpa.free(bytes);

    // Load into a world that never registered "Ghost".
    var world = World.init();
    defer world.deinit(gpa);
    const acc = try openVerified(bytes);
    try testing.expectError(error.UnknownComponent, buildSchemaRemap(gpa, &world, acc));
}

test "buildSchemaRemap errors SchemaMismatch on a divergent layout" {
    const gpa = testing.allocator;

    // Cooked as size 8 …
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const pos_cook = try registerRaw(gpa, &cook_reg, "Pos", 8, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, pos_cook);
    defer gpa.free(bytes);

    // … but registered as size 12 at load time.
    var world = World.init();
    defer world.deinit(gpa);
    _ = try registerRaw(gpa, &world.registry, "Pos", 12, 4);
    const acc = try openVerified(bytes);
    try testing.expectError(error.SchemaMismatch, buildSchemaRemap(gpa, &world, acc));
}

test "openVerified rejects a tampered scene with CorruptScene" {
    const gpa = testing.allocator;
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const pos = try registerRaw(gpa, &cook_reg, "Pos", 8, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, pos);
    defer gpa.free(bytes);

    // Flip a byte in the content region (after the 64-byte header) so the
    // recorded XxHash64 no longer matches, while magic/version stay valid.
    bytes[format.header_size] ^= 0xFF;
    try testing.expectError(error.CorruptScene, openVerified(bytes));
}

test "openVerified surfaces header ReadError (short / bad magic / bad version)" {
    const gpa = testing.allocator;
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const pos = try registerRaw(gpa, &cook_reg, "Pos", 8, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, pos);
    defer gpa.free(bytes);

    try testing.expectError(error.TooShort, openVerified(bytes[0..10]));

    const saved = bytes[0];
    bytes[0] = 'X';
    try testing.expectError(error.BadMagic, openVerified(bytes));
    bytes[0] = saved;

    std.mem.writeInt(u16, bytes[4..6], 999, .little);
    try testing.expectError(error.BadVersion, openVerified(bytes));
}

test "loadFromBytes rejects an out-of-range parent ordinal with MalformedScene" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);

    // 1 entity, 1 UUID (ordinal 0), but its parent ordinal is 5 — past the UUID
    // table. The writer still computes a valid header hash over these bytes, so
    // the file opens + verifies; only the structural check rejects it. This is
    // why the error is `MalformedScene`, not `CorruptScene` (hash mismatch).
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "E0")});
    const uuids = try a.dupe([16]u8, &.{[_]u8{0} ** 16});
    const col = try a.alloc(u8, 8);
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = 0, .parent_uuid = 5 },
    });
    const ids = try a.dupe(ComponentId, &.{pos});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = 1,
        .columns = cols,
        .entities = ents,
    }});
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    const bytes = try writer.write(gpa, model, &world.registry);
    defer gpa.free(bytes);

    try testing.expectError(error.MalformedScene, loadFromBytes(&world, gpa, bytes, null));
}

test "resource strings outlive LoadResult.deinit (M1.1.1-HF1 D1)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const settings = try registerStringResource(gpa, &world.registry, "Settings");

    const bytes = try buildStringResourceScene(gpa, &world.registry, settings, "Verdant Keep");
    defer gpa.free(bytes);

    var result = try loadFromBytes(&world, gpa, bytes, null);
    result.deinit(gpa); // D1: LoadResult no longer owns the resource string block

    // The interned block outlives LoadResult.deinit — it is owned by the slot.
    const buf = world.resources.getResource(settings).?;
    var ss: persistent.StringSlot = undefined;
    @memcpy(std.mem.asBytes(&ss), buf[0..@sizeOf(persistent.StringSlot)]);
    try testing.expect(ss.ptr != 0);
    const loaded: [*]const u8 = @ptrFromInt(ss.ptr);
    try testing.expectEqualStrings("Verdant Keep", loaded[0..ss.len]);

    // Owner teardown (parity with the interp's resource-string deinit): release
    // the slot's refcounted block so the testing allocator sees no leak.
    decrefResourceStrings(&world, gpa, settings, buf);
}

test "loading over an existing resource string releases the previous block (M1.1.1-HF1 D1)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const settings = try registerStringResource(gpa, &world.registry, "Settings");

    const bytes_a = try buildStringResourceScene(gpa, &world.registry, settings, "first");
    defer gpa.free(bytes_a);
    const bytes_b = try buildStringResourceScene(gpa, &world.registry, settings, "second");
    defer gpa.free(bytes_b);

    var ra = try loadFromBytes(&world, gpa, bytes_a, null);
    ra.deinit(gpa);
    // The second load reads the old slot ("first" block), installs "second", and
    // decrefs "first" at commit → "first" is freed. Under `std.testing.allocator`
    // a missed decref would surface as a leak.
    var rb = try loadFromBytes(&world, gpa, bytes_b, null);
    rb.deinit(gpa);

    const buf = world.resources.getResource(settings).?;
    var ss: persistent.StringSlot = undefined;
    @memcpy(std.mem.asBytes(&ss), buf[0..@sizeOf(persistent.StringSlot)]);
    const loaded: [*]const u8 = @ptrFromInt(ss.ptr);
    try testing.expectEqualStrings("second", loaded[0..ss.len]);

    decrefResourceStrings(&world, gpa, settings, buf); // release "second"
}

test "a failed load leaves the world unchanged (M1.1.1-HF1 D2)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);
    const settings = try registerStringResource(gpa, &world.registry, "Settings");
    const bag = try registerArrayResource(gpa, &world.registry, "Bag");

    // Prior state: Settings = "old", no entities.
    const seed = try buildStringResourceScene(gpa, &world.registry, settings, "old");
    defer gpa.free(seed);
    var r_seed = try loadFromBytes(&world, gpa, seed, null);
    r_seed.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), world.entityCount());

    // A scene that spawns an entity + overrides Settings = "new", then trips the
    // collection-resource rejection — a failure AFTER the spawn and the resource
    // write. (Injection chosen for buildability with the Tier-0 test scaffolding;
    // the brief's example injections are equivalent post-first-spawn failures.)
    const bytes = try buildSpawnThenFailScene(gpa, &world.registry, pos, settings, bag);
    defer gpa.free(bytes);

    try testing.expectError(error.CollectionResourceFieldUnsupported, loadFromBytes(&world, gpa, bytes, null));

    // World unchanged: the spawned entity is despawned and Settings holds "old".
    try testing.expectEqual(@as(usize, 0), world.entityCount());
    const buf = world.resources.getResource(settings).?;
    var ss: persistent.StringSlot = undefined;
    @memcpy(std.mem.asBytes(&ss), buf[0..@sizeOf(persistent.StringSlot)]);
    const held: [*]const u8 = @ptrFromInt(ss.ptr);
    try testing.expectEqualStrings("old", held[0..ss.len]);

    decrefResourceStrings(&world, gpa, settings, buf); // release "old"
}

test "rollback restores across duplicate resource entries (M1.1.1-HF1 D2)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const settings = try registerStringResource(gpa, &world.registry, "Settings");
    const bag = try registerArrayResource(gpa, &world.registry, "Bag");

    // Prior state: Settings = "pre".
    const seed = try buildStringResourceScene(gpa, &world.registry, settings, "pre");
    defer gpa.free(seed);
    var r_seed = try loadFromBytes(&world, gpa, seed, null);
    r_seed.deinit(gpa);

    // A scene with TWO Settings entries of the same cid ("a" then "b") + a
    // trailing collection resource that fails. Rolling the two same-cid edits
    // back forward would restore "a" then wrongly decref it; LIFO restores "pre"
    // and frees each block exactly once (the testing allocator flags either bug).
    const bytes = try buildDupResourceFailScene(gpa, &world.registry, settings, bag);
    defer gpa.free(bytes);

    try testing.expectError(error.CollectionResourceFieldUnsupported, loadFromBytes(&world, gpa, bytes, null));

    const buf = world.resources.getResource(settings).?;
    var ss: persistent.StringSlot = undefined;
    @memcpy(std.mem.asBytes(&ss), buf[0..@sizeOf(persistent.StringSlot)]);
    const held: [*]const u8 = @ptrFromInt(ss.ptr);
    try testing.expectEqualStrings("pre", held[0..ss.len]); // pre-load value restored

    decrefResourceStrings(&world, gpa, settings, buf); // release "pre"
}

/// Test helper: cook a 2-archetype (`A` then `B`), one-entity-each `.scene.bin`.
/// Two spawns across two blocks exercise the per-entity instantiate loop.
fn buildTwoBlockScene(gpa: std.mem.Allocator, reg: *const Registry, cid_a: ComponentId, cid_b: ComponentId) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{ try a.dupe(u8, "E0"), try a.dupe(u8, "E1") });
    var uuid1 = [_]u8{0} ** 16;
    uuid1[0] = 1;
    const uuids = try a.dupe([16]u8, &.{ [_]u8{0} ** 16, uuid1 });
    const col_a = try a.alloc(u8, reg.componentSize(cid_a));
    @memset(col_a, 0);
    const col_b = try a.alloc(u8, reg.componentSize(cid_b));
    @memset(col_b, 0);
    const blocks = try a.dupe(format.ArchetypeBlock, &.{
        .{
            .component_ids = try a.dupe(ComponentId, &.{cid_a}),
            .entity_count = 1,
            .columns = try a.dupe([]u8, &.{col_a}),
            .entities = try a.dupe(format.EntityEntry, &.{.{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent }}),
        },
        .{
            .component_ids = try a.dupe(ComponentId, &.{cid_b}),
            .entity_count = 1,
            .columns = try a.dupe([]u8, &.{col_b}),
            .entities = try a.dupe(format.EntityEntry, &.{.{ .name = 1, .uuid = 1, .parent_uuid = format.no_parent }}),
        },
    });
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

test "instantiate under post-spawn OOM leaves no orphan (M1.1.1-HF2 C2)" {
    const gpa = testing.allocator;

    // A 2-block scene (two spawns) built once with the real allocator.
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const a_cid = try registerRaw(gpa, &reg, "A", 8, 4);
    const b_cid = try registerRaw(gpa, &reg, "B", 8, 4);
    const bytes = try buildTwoBlockScene(gpa, &reg, a_cid, b_cid);
    defer gpa.free(bytes);

    // Exhaustively fail each allocation of the load in turn. Whatever fails, the
    // load must either fully succeed (both entities present) or leave the world
    // at its pre-load state — never a live entity stranded outside `spawned`
    // (the orphan). Under the pre-fix code, an OOM on the post-spawn
    // `uuid_to_entity.put` / `spawned.append` left exactly that orphan; the
    // rollback (allocation-free ) never reclaimed it. `entityCount == 0`
    // AND `liveCount == 0` on every failure prove the fix.
    var saw_success = false;
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();

        var world = World.init();
        defer world.deinit(fa);

        // Register under the failing allocator too; a failure here is pre-load
        // (the load never runs) — still no orphan, so skip that index.
        _ = registerRaw(fa, &world.registry, "A", 8, 4) catch continue;
        _ = registerRaw(fa, &world.registry, "B", 8, 4) catch continue;

        if (loadFromBytes(&world, fa, bytes, null)) |r| {
            var rr = r;
            rr.deinit(fa);
            try testing.expectEqual(@as(usize, 2), world.entityCount());
            saw_success = true;
        } else |_| {
            try testing.expectEqual(@as(usize, 0), world.entityCount());
            try testing.expectEqual(@as(usize, 0), world.identity.liveCount());
        }
    }
    // The bound reached the all-allocations-succeed case, so the sweep covered
    // every load allocation (including all post-spawn points).
    try testing.expect(saw_success);
}

test "rejected load restores the resource dirty bit (M1.1.1-HF2 C6)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const ecid = try registerRaw(gpa, &world.registry, "E", 8, 4);
    const settings = try registerStringResource(gpa, &world.registry, "Settings");
    const bag = try registerArrayResource(gpa, &world.registry, "Bag");

    // Seed Settings so the failing load OVERRIDES it (snapshot path). addResource
    // starts it clean — the pre-load dirty state the rollback must restore.
    try world.addResource(gpa, settings, &[_]u8{0} ** 16);
    try testing.expect(!world.resources.isDirty(settings));

    // Spawns E, writes Settings.v = "new" (getMutResource → dirty = true), then
    // trips the Bag collection rejection → the transactional rollback runs.
    const bytes = try buildSpawnThenFailScene(gpa, &world.registry, ecid, settings, bag);
    defer gpa.free(bytes);
    try testing.expectError(error.CollectionResourceFieldUnsupported, loadFromBytes(&world, gpa, bytes, null));

    // dirty is restored to its pre-load value (false), not left spuriously
    // true by the rollback's own `getMutResource` calls. And no entity survived.
    try testing.expect(!world.resources.isDirty(settings));
    try testing.expectEqual(@as(usize, 0), world.entityCount());
}

/// Test helper: cook a 1-archetype, 2-entity `.scene.bin` over `reg` (component
/// `cid`), with the two entities' own UUID ordinals set to `ord0` / `ord1`. The
/// UUID table always holds 2 entries (so `uuidCount == 2`); an out-of-range or
/// duplicate ordinal is what the C2b tests inject. The writer computes a valid
/// header hash over the bytes, so the file opens + verifies — only the loader's
/// structural checks reject it.
fn buildTwoEntityOneBlockScene(gpa: std.mem.Allocator, reg: *const Registry, cid: ComponentId, ord0: u32, ord1: u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{ try a.dupe(u8, "E0"), try a.dupe(u8, "E1") });
    var uuid1 = [_]u8{0} ** 16;
    uuid1[0] = 1;
    const uuids = try a.dupe([16]u8, &.{ [_]u8{0} ** 16, uuid1 });
    const col = try a.alloc(u8, reg.componentSize(cid) * 2); // 2 entities, one archetype
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = ord0, .parent_uuid = format.no_parent },
        .{ .name = 1, .uuid = ord1, .parent_uuid = format.no_parent },
    });
    const ids = try a.dupe(ComponentId, &.{cid});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = 2,
        .columns = cols,
        .entities = ents,
    }});
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

test "instantiate rejects an out-of-range entity uuid ordinal (M1.1.1-HF2 C2b)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);

    // 2 entities, 2 UUIDs (uuidCount == 2); entity 1's own UUID ordinal is 2 —
    // past the table. The C2b pre-spawn check rejects it (MalformedScene, not
    // CorruptScene — the writer's hash is valid). Entity 0 spawned first, so the
    // rollback must reclaim it: entityCount and liveCount return to 0.
    const bytes = try buildTwoEntityOneBlockScene(gpa, &world.registry, pos, 0, 2);
    defer gpa.free(bytes);

    try testing.expectError(error.MalformedScene, loadFromBytes(&world, gpa, bytes, null));
    try testing.expectEqual(@as(usize, 0), world.entityCount());
    try testing.expectEqual(@as(usize, 0), world.identity.liveCount());
}

test "instantiate rejects a duplicate entity uuid ordinal (M1.1.1-HF2 C2b)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);

    // 2 entities sharing UUID ordinal 0 — malformed (the cooker never emits it).
    // Entity 0 spawns + registers uuid[0]; entity 1 (also ordinal 0) is spawned,
    // recorded in `spawned` FIRST, then rejected by the duplicate check → both
    // entities roll back. entityCount and liveCount return to 0.
    const bytes = try buildTwoEntityOneBlockScene(gpa, &world.registry, pos, 0, 0);
    defer gpa.free(bytes);

    try testing.expectError(error.MalformedScene, loadFromBytes(&world, gpa, bytes, null));
    try testing.expectEqual(@as(usize, 0), world.entityCount());
    try testing.expectEqual(@as(usize, 0), world.identity.liveCount());
}

/// Build a mono-entity extension `.prefab.bin`: one entity carrying [ExtX, ExtY]
/// (both size 4, align 4). Reused by the activate-atomicity test.
fn buildExtPrefab(gpa: std.mem.Allocator) ![]u8 {
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const x = try registerRaw(gpa, &reg, "ExtX", 4, 4); // id 0
    const y = try registerRaw(gpa, &reg, "ExtY", 4, 4); // id 1
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "ext_entity")});
    const uuids = try a.dupe([16]u8, &.{[_]u8{9} ** 16});
    const col_x = try a.alloc(u8, 4);
    @memset(col_x, 0x11);
    const col_y = try a.alloc(u8, 4);
    @memset(col_y, 0x22);
    const ids = try a.dupe(ComponentId, &.{ x, y }); // sorted ascending (0,1)
    const cols = try a.dupe([]u8, &.{ col_x, col_y });
    const ents = try a.dupe(format.EntityEntry, &.{.{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent }});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{ .component_ids = ids, .entity_count = 1, .columns = cols, .entities = ents }});
    var model: format.CookModel = .{ .strings = names, .uuids = uuids, .resources = &.{}, .archetypes = blocks, .arena = arena };
    defer model.deinit();
    return writer.write(gpa, model, &reg);
}

test "activateExtension is all-or-nothing under injected OOM" {
    const backing = testing.allocator;
    const ext_bytes = try buildExtPrefab(backing);
    defer backing.free(ext_bytes);

    // Step the FailingAllocator across the whole activation. At every failure
    // point the entity's component set AND its extension record equal the
    // pre-call state (base component present, ExtX/ExtY absent, no record).
    var fail_index: usize = 0;
    while (fail_index < 60) : (fail_index += 1) {
        var world = World.init();
        defer world.deinit(backing);
        const base = try registerRaw(backing, &world.registry, "ExtBase", 4, 4);
        _ = try registerRaw(backing, &world.registry, "ExtX", 4, 4);
        _ = try registerRaw(backing, &world.registry, "ExtY", 4, 4);
        const e = try world.spawnDynamic(backing, &[_]ComponentId{base});

        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        const x = world.componentId("ExtX").?;
        const y = world.componentId("ExtY").?;
        if (activateExtension(&world, fa.allocator(), e, "TestExt", ext_bytes)) |_| {
            // Succeeded before the injected point — components + record present.
            try testing.expect(world.hasEntityExtension(e, "TestExt"));
            try testing.expect(world.componentBytes(e, x) != null);
            try testing.expect(world.componentBytes(e, y) != null);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(world.componentBytes(e, base) != null); // base intact
            try testing.expect(world.componentBytes(e, x) == null); // no partial add
            try testing.expect(world.componentBytes(e, y) == null);
            try testing.expect(!world.hasEntityExtension(e, "TestExt")); // no record
        }
    }
}

test "extension with zero entities is rejected" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const base = try registerRaw(gpa, &world.registry, "ZBase", 4, 4);
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{base});

    // A cooked prefab with no entities (no archetypes) → total == 0.
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const arena = std.heap.ArenaAllocator.init(gpa);
    var model: format.CookModel = .{ .strings = &.{}, .uuids = &.{}, .resources = &.{}, .archetypes = &.{}, .arena = arena };
    defer model.deinit();
    const ext_bytes = try writer.write(gpa, model, &reg);
    defer gpa.free(ext_bytes);

    try testing.expectError(error.EmptyExtension, activateExtension(&world, gpa, e, "Empty", ext_bytes));
    // Entity untouched: base still present, no extension recorded.
    try testing.expect(world.componentBytes(e, base) != null);
    try testing.expect(!world.hasEntityExtension(e, "Empty"));
}

test "buildSchemaRemap rejects duplicate schema names (R11b)" {
    const gpa = testing.allocator;
    const bytes = try buildExtPrefab(gpa); // 2 schemas: ExtX, ExtY (both 4/4)
    defer gpa.free(bytes);
    const acc0 = try Accessor.open(bytes);
    const st = acc0.header.schema_table_offset;

    // Overwrite schema entry 1 (8 B) with a copy of entry 0 → both entries name
    // the same component, so `buildSchemaRemap` resolves both to one ComponentId.
    const buf = try gpa.dupe(u8, bytes);
    defer gpa.free(buf);
    @memcpy(buf[st + 8 ..][0..8], buf[st .. st + 8]);
    const h = std.hash.XxHash64.hash(0, buf[format.header_size..]);
    std.mem.writeInt(u64, buf[56..64], h, .little);

    var world = World.init();
    defer world.deinit(gpa);
    _ = try registerRaw(gpa, &world.registry, "ExtX", 4, 4);
    const acc = try openVerified(buf); // validate passes (indices 0,1 still distinct)
    try testing.expectError(error.MalformedScene, buildSchemaRemap(gpa, &world, acc));
}

test "deactivateExtension is all-or-nothing under injected OOM; on_detach fires exactly once (R12e)" {
    const backing = testing.allocator;
    const ext_bytes = try buildExtPrefab(backing);
    defer backing.free(ext_bytes);

    // A Tier-0 on_detach hook that only counts — no allocation, so it can never
    // be the OOM point.
    const Hook = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque, _: *World, _: EntityId, _: []const u8, _: ?[]const u8) anyerror!void {
            fired += 1;
        }
    };

    var fail_index: usize = 0;
    while (fail_index < 60) : (fail_index += 1) {
        var world = World.init();
        defer world.deinit(backing);
        const base = try registerRaw(backing, &world.registry, "ExtBase", 4, 4);
        _ = try registerRaw(backing, &world.registry, "ExtX", 4, 4);
        _ = try registerRaw(backing, &world.registry, "ExtY", 4, 4);
        world.registerOnDetach(null, &Hook.cb);
        const e = try world.spawnDynamic(backing, &[_]ComponentId{base});
        try activateExtension(&world, backing, e, "TestExt", ext_bytes); // working allocator
        const x = world.componentId("ExtX").?;
        const y = world.componentId("ExtY").?;

        Hook.fired = 0;
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (deactivateExtension(&world, fa.allocator(), e, "TestExt", ext_bytes)) |_| {
            // Success: on_detach fired exactly once; components + record gone.
            try testing.expectEqual(@as(usize, 1), Hook.fired);
            try testing.expect(!world.hasEntityExtension(e, "TestExt"));
            try testing.expect(world.componentBytes(e, x) == null);
            try testing.expect(world.componentBytes(e, y) == null);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // Every OOM point is BEFORE on_detach → hook fired 0 times and the
            // extension is fully active (components + record intact).
            try testing.expectEqual(@as(usize, 0), Hook.fired);
            try testing.expect(world.hasEntityExtension(e, "TestExt"));
            try testing.expect(world.componentBytes(e, x) != null);
            try testing.expect(world.componentBytes(e, y) != null);
        }
    }
}

test "deactivateExtension rejects multi-entity extension bytes (R12c)" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);
    const e = try world.spawnDynamic(gpa, &[_]ComponentId{pos});
    try world.addEntityExtension(gpa, e, "Multi"); // mark active by name

    // A valid 2-entity cooked image → the strict cardinality guard rejects it.
    const multi_bytes = try buildTwoEntityOneBlockScene(gpa, &world.registry, pos, 0, 1);
    defer gpa.free(multi_bytes);
    try testing.expectError(error.MultiEntityExtensionUnsupported, deactivateExtension(&world, gpa, e, "Multi", multi_bytes));
    try testing.expect(world.hasEntityExtension(e, "Multi")); // untouched
}

test "activateExtension rejects re-activation, including a hook-only extension (R12d)" {
    const backing = testing.allocator;
    const ext_bytes = try buildExtPrefab(backing);
    defer backing.free(ext_bytes);

    var world = World.init();
    defer world.deinit(backing);
    const base = try registerRaw(backing, &world.registry, "ExtBase", 4, 4);
    _ = try registerRaw(backing, &world.registry, "ExtX", 4, 4);
    _ = try registerRaw(backing, &world.registry, "ExtY", 4, 4);
    const e = try world.spawnDynamic(backing, &[_]ComponentId{base});
    try activateExtension(&world, backing, e, "TestExt", ext_bytes);
    try testing.expectError(error.ExtensionAlreadyActive, activateExtension(&world, backing, e, "TestExt", ext_bytes));

    // Hook-only extension (one entity, zero components): the component-conflict
    // guard cannot fire, so the `hasEntityExtension` check is what rejects
    // re-activation.
    var arena = std.heap.ArenaAllocator.init(backing);
    const a = arena.allocator();
    const hnames = try a.dupe([]const u8, &.{try a.dupe(u8, "he")});
    const huuids = try a.dupe([16]u8, &.{[_]u8{5} ** 16});
    const hents = try a.dupe(format.EntityEntry, &.{.{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent }});
    const hblocks = try a.dupe(format.ArchetypeBlock, &.{.{ .component_ids = &.{}, .entity_count = 1, .columns = &.{}, .entities = hents }});
    var hmodel: format.CookModel = .{ .strings = hnames, .uuids = huuids, .resources = &.{}, .archetypes = hblocks, .arena = arena };
    defer hmodel.deinit();
    var hreg = Registry.init();
    defer hreg.deinit(backing);
    const hook_only = try writer.write(backing, hmodel, &hreg);
    defer backing.free(hook_only);

    const e2 = try world.spawnDynamic(backing, &[_]ComponentId{base});
    try activateExtension(&world, backing, e2, "HookOnly", hook_only);
    try testing.expect(world.hasEntityExtension(e2, "HookOnly"));
    try testing.expectError(error.ExtensionAlreadyActive, activateExtension(&world, backing, e2, "HookOnly", hook_only));
}
