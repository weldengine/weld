//! `.scene.bin` runtime loader — Tier 0 (`engine-scene-serialization.md` §4,
//! "Chargement (loader runtime — M1.0.5)").
//!
//! Reads a cooked `.scene.bin` back into a live ECS `World`. It **reuses
//! `accessor.zig` verbatim** (the zero-copy read half of the M1.0.4 codec) and
//! layers the runtime-only steps on top: on-disk-identity → runtime remap,
//! per-entity instantiation, the UUID→handle map, and the `on_spawned`
//! lifecycle. No new ECS storage primitive — the loader assembles existing
//! bricks (`world.spawnDynamicWithValues`, `Registry.idOf`, `ObserverRegistry`,
//! `world.addResource`).
//!
//! Tier discipline: imports `weld_core` internals only — never `weld_etch`
//! (`engine-spec.md` §3.5). The cook driver's Etch coupling lives in
//! `src/etch/scene_cook.zig`; the loader consumes only the neutral byte image.
//!
//! ## Stages (gate-split, see `briefs/M1.0.5-scene-load.md`)
//! * **E1 (here)** — open + integrity check + schema-identity remap. The two
//!   units below (`openVerified`, `buildSchemaRemap`) are the front of the load
//!   pipeline; both operate on a borrowed byte image so they are unit-testable
//!   without touching the filesystem. They form the clean internal boundary the
//!   E2 instantiation step builds on (and a future bulk path would swap behind).
//! * **E2** — `loadScene(world, gpa, path)`: the `fs.mmapFile` wrapper, the
//!   per-entity instantiation loop, the UUID map, two-phase `on_spawned`, and
//!   the `LoadResult` that owns the mmap.
//! * **E3** — resource loading (POD bytes + interned `string` fields).

const std = @import("std");

const format = @import("format.zig");
const accessor_mod = @import("accessor.zig");
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
/// cook recorded their `XxHash64`).
pub const OpenError = format.ReadError || error{CorruptScene};

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
/// M1.0.4 cook never produces this — it is a defensive guard on external input.
pub const StructureError = error{MalformedScene};

/// Resolves an extension prefab name (from the scene's Prefab ID Table) to its
/// cooked `.prefab.bin` bytes at load (M1.0.6 E6) — the runtime twin of the
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

/// Open a `.scene.bin` byte image: validate magic + version (via the accessor,
/// read little-endian field-by-field — never a raw `@ptrCast` off an unaligned
/// buffer), then verify the content hash. Returns a zero-copy `Accessor`
/// borrowing `bytes` for its whole lifetime.
///
/// Errors:
///   - `error.TooShort` / `error.BadMagic` / `error.BadVersion` — invalid header
///   - `error.CorruptScene` — content hash does not match the header's
pub fn openVerified(bytes: []const u8) OpenError!Accessor {
    const acc = try Accessor.open(bytes);
    if (!acc.verifyHash()) return error.CorruptScene;
    return acc;
}

/// Build the schema-remap table: on-disk Schema-Registry index → runtime
/// `ComponentId`. Phase-1 schema identity is the component **name**
/// (`engine-ecs-internals.md` §10): each on-disk schema's name is resolved
/// through the world's registry (`Registry.idOf`), and its cooked
/// `size`/`alignment` are validated against the runtime layout so a scene
/// cooked against a different component layout can never feed mismatched bytes
/// into storage.
///
/// The returned slice is `acc.schemaCount()` long, indexed by on-disk schema
/// index; the caller owns it (`gpa.free`).
///
/// Errors:
///   - `error.UnknownComponent` — a schema name the world never registered
///   - `error.SchemaMismatch` — registered, but size/alignment diverge
///   - `error.OutOfMemory`
pub fn buildSchemaRemap(gpa: std.mem.Allocator, world: *const World, acc: Accessor) RemapError![]ComponentId {
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
    return remap;
}

// ─── E2 — instantiation + UUID map + two-phase on_spawned ────────────────────

/// 16-byte UUID → runtime `EntityId`, built as the scene loads. Keyed on the
/// raw UUID bytes (`Archetype.entityUuid`) so the accessor stays untouched; a
/// dense ordinal-keyed map is a later optimization.
pub const UuidMap = std.AutoHashMapUnmanaged([16]u8, EntityId);

/// What a load produces. `spawned` is every instantiated entity in load order;
/// `uuid_to_entity` resolves a scene UUID to its runtime handle (the seam the
/// hierarchy / cross-reference milestones build on); `mmap` is the backing file
/// mapping for the `loadScene(path)` entry (null for `loadFromBytes`, whose
/// bytes the caller owns). Component data is copied into ECS storage during the
/// load, so the entities outlive the mapping — `mmap` is held only so its
/// lifetime is the caller's to end (`engine-scene-serialization.md` §4).
///
/// Ownership: the caller ends the load's life with `deinit` (frees `spawned`,
/// the map, the interned resource strings, and closes `mmap` if present).
pub const LoadResult = struct {
    spawned: []EntityId,
    uuid_to_entity: UuidMap,
    /// Tier-0 persistent-heap blocks interned for loaded resource `string`
    /// fields (E3), allocated **immortal**. Owned here (not by the interp), so
    /// `deinit` `destroy`s them — the resources' `StringSlot`s point into these.
    resource_strings: [][*]u8,
    mmap: ?fs.Mmap,

    /// Free the loader-owned allocations, reclaim the interned resource strings,
    /// and close the backing mmap (if any). Does **not** despawn the loaded
    /// entities — they belong to the `World`.
    pub fn deinit(self: *LoadResult, gpa: std.mem.Allocator) void {
        gpa.free(self.spawned);
        self.uuid_to_entity.deinit(gpa);
        for (self.resource_strings) |p| persistent.destroy(gpa, p);
        gpa.free(self.resource_strings);
        if (self.mmap) |*m| m.close();
        self.* = undefined;
    }
};

/// Count of entries in the on-disk UUID table, derived from the header section
/// offsets (`uuid_table` ends where `schema_table` begins; 16 B per UUID). Lets
/// the loader bounds-check parent ordinals without a new accessor getter.
fn uuidCount(acc: Accessor) u32 {
    return (acc.header.schema_table_offset - acc.header.uuid_table_offset) / 16;
}

/// Load a cooked `.scene.bin` byte image into `world`. The byte-level core
/// (no filesystem): validate + remap (E1), instantiate every entity, then fire
/// the `on_spawned` lifecycle in a second pass. The returned `LoadResult` has a
/// null `mmap` — the caller owns `bytes`.
///
/// Two-phase, so the ordering guarantee holds: **every loaded entity exists
/// before any `on_spawned` fires** (phase 1 spawns via `spawnDynamicWithValues`,
/// which dispatches no observers; phase 2 fires `on_spawned` per entity).
///
/// Errors: the E1 set (`OpenError`/`RemapError`), `error.MalformedScene`
/// (`StructureError`) for a structurally-invalid scene (e.g. an out-of-range
/// parent ordinal), allocation failure, plus anything an `on_spawned` observer
/// propagates (hence the open error set).
pub fn loadFromBytes(world: *World, gpa: std.mem.Allocator, bytes: []const u8, ext_resolver: ?ExtensionResolver) anyerror!LoadResult {
    const acc = try openVerified(bytes);

    const remap = try buildSchemaRemap(gpa, world, acc);
    defer gpa.free(remap);

    var spawned: std.ArrayListUnmanaged(EntityId) = .empty;
    errdefer spawned.deinit(gpa);
    var uuid_to_entity: UuidMap = .empty;
    errdefer uuid_to_entity.deinit(gpa);
    var res_strings: std.ArrayListUnmanaged([*]u8) = .empty;
    errdefer {
        for (res_strings.items) |p| persistent.destroy(gpa, p);
        res_strings.deinit(gpa);
    }

    try instantiate(world, gpa, acc, remap, &spawned, &uuid_to_entity);
    // Cross-references after every entity exists (a reference can point forward),
    // before resources + on_spawned so a rule sees fully-linked entities.
    try resolveCrossRefs(world, acc, remap, uuid_to_entity);
    // Resources before extensions/on_spawned so a hook/rule can read them.
    try loadResources(world, gpa, acc, remap, &res_strings);
    // Extension activation (M1.0.6 E6): add each active extension's components +
    // fire the `on_attach` seam. After resources, before `on_spawned`.
    try applyExtensions(world, gpa, acc, uuid_to_entity, ext_resolver);
    // M1.0.9 — drain the structural commands the `on_attach` hooks queued, AFTER
    // the whole activation pass and BEFORE `on_spawned`, so a spawn observer sees
    // a fully-materialised entity. `dispatchSpawnLifecycle` also opens with a
    // drain; this explicit one keeps the ordering contract local to the load
    // sequence (it does not depend on a downstream function's internal drain).
    {
        var hook_drain = command_buffer_mod.CommandBuffer.init(gpa, world);
        defer hook_drain.deinit();
        try observers_mod.flushWithObservers(&hook_drain, &world.observer_registry);
    }
    try dispatchSpawnLifecycle(world, gpa, spawned.items);

    return .{
        .spawned = try spawned.toOwnedSlice(gpa),
        .uuid_to_entity = uuid_to_entity,
        .resource_strings = try res_strings.toOwnedSlice(gpa),
        .mmap = null,
    };
}

/// Load a cooked `.scene.bin` from `path`: `mmap` the file, then run
/// `loadFromBytes` over the borrowed bytes. The returned `LoadResult` owns the
/// mapping (`LoadResult.deinit` closes it). Adds `fs.Error` (open/map failure)
/// to `loadFromBytes`'s error set.
pub fn loadScene(world: *World, gpa: std.mem.Allocator, path: []const u8, ext_resolver: ?ExtensionResolver) anyerror!LoadResult {
    var mmap = try fs.mmapFile(gpa, path);
    errdefer mmap.close();
    var result = try loadFromBytes(world, gpa, mmap.bytes, ext_resolver);
    result.mmap = mmap;
    return result;
}

/// Phase 1 — instantiate every entity of every archetype block. Maps each
/// block's on-disk schema-index columns to runtime `ComponentId`s (the E1
/// remap), gathers each slot's raw component bytes (borrowed, on-disk column
/// order — `spawnDynamicWithValues` reorders by id), spawns the entity, records
/// `uuid → eid`, and appends to `spawned`. Validates each parent ordinal is
/// `no_parent` or in `[0, uuidCount)` (else `error.MalformedScene`) but
/// **applies no parent link** (no runtime hierarchy component exists yet —
/// owned by the hierarchy milestone).
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
            for (0..cc) |c| payloads[c] = block.componentSlot(c, slot);
            const eid = try world.spawnDynamicWithValues(gpa, ids, payloads);
            try uuid_to_entity.put(gpa, block.entityUuid(slot).*, eid);
            try spawned.append(gpa, eid);

            // Structural (not hash) validity: a parent ordinal must index the
            // UUID table or be `no_parent`. The link itself is not applied (no
            // runtime hierarchy component yet).
            const parent = block.entityParent(slot);
            if (parent != format.no_parent and parent >= ucount) return error.MalformedScene;
        }
    }
}

/// Resolve the Cross-references Table (M1.0.6 E4): patch each cooked `Entity`
/// field slot (written `EntityId.dead` at cook) to the referenced entity's
/// runtime handle. Per entry: map source/target UUID ordinals → handles via
/// `uuid_to_entity`, map the file-local schema index → runtime `ComponentId` via
/// `remap`, then overwrite the 8-byte field at `field_offset` and flag the
/// component changed. Bounds/identity are validated (`MalformedScene`) — the
/// loader treats the byte image as untrusted input. Runs after `instantiate`
/// (every entity exists) and before `loadResources`.
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

/// Extension activation (M1.0.6 E6) — for each entity in the Entity Extensions
/// Table, in table order, activate each of its extensions: resolve the extension
/// `.prefab.bin` by name (Prefab ID Table → `ExtensionResolver`), add its
/// components, and fire the `on_attach` Tier-0 seam. **No-op when the scene has no
/// active extensions** (so an extension-free scene needs no resolver). The
/// `on_attach` hook EXECUTION (M1.0.9) runs inside the registered seam's callback
/// (the Etch bridge); here `dispatchOnAttach` fires it with the cooked hook text.
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

/// Activate one extension on one entity (M1.0.6 E6) — the shared bytes-taking
/// path reused by load (`applyExtensions`), the runtime `activate_extension`
/// entry, AND the interpreter's deferred B1 flush: open the extension's
/// `.prefab.bin`, add its single entity's components to `entity`, record the
/// active extension, then fire the `on_attach` seam with the cooked hook text.
/// The extension prefab is mono-entity (cooked as such); a component the entity
/// already carries is a conflict (§30.5) — surfaced as
/// `error.ExtensionComponentConflict` rather than the dynamic-add assert.
pub fn activateExtension(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, ext_bytes: []const u8) !void {
    const ext = try openVerified(ext_bytes);

    // Mono-entity: the extension's components live on its single entity.
    var total: u32 = 0;
    var ai: u32 = 0;
    while (ai < ext.archetypeCount()) : (ai += 1) total += ext.archetype(ai).entity_count;
    if (total > 1) return error.MultiEntityExtensionUnsupported;

    ai = 0;
    while (ai < ext.archetypeCount()) : (ai += 1) {
        const arch = ext.archetype(ai);
        if (arch.entity_count == 0) continue;
        var c: usize = 0;
        while (c < arch.component_count) : (c += 1) {
            const sch = ext.schema(arch.schemaIndex(c));
            const cid = world.componentId(sch.name) orelse return error.UnknownComponent;
            if (sch.size != world.registry.componentSize(cid)) return error.SchemaMismatch;
            if (world.componentBytes(entity, cid) != null) return error.ExtensionComponentConflict;
            try world.addComponentDynamic(gpa, entity, cid, arch.componentSlot(c, 0));
        }
    }

    // Record the extension as active on the entity BEFORE firing `on_attach`, so
    // a hook that queries `has_extension` / `active_extensions` sees it (M1.0.9).
    // Tracked here means load AND runtime activation both track for free.
    try world.addEntityExtension(gpa, entity, name);

    // Fire the `on_attach` dispatch seam (D-E). M1.0.9 — the Etch bridge's
    // registered callback re-parses + executes `on_attach_text` against the live
    // world; with no bridge registered (Tier-0 tests) the seam is a no-op.
    const on_attach_text: ?[]const u8 = if (ext.hookCount() > 0) ext.hook(0).on_attach else null;
    try world.dispatchOnAttach(entity, name, on_attach_text);
}

/// M1.0.9 — runtime extension activation entry, reached from Etch
/// `entity.activate_extension("X")` (the interpreter resolves the name through
/// the bridge's `ExtensionResolver`). Reuses the shared `activateExtension`
/// path: add components → record the active extension → fire `on_attach`.
/// Unknown name → `error.UnknownExtension`; a component the entity already
/// carries → `error.ExtensionComponentConflict` (§30.5 reject policy).
pub fn runtimeActivate(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, resolver: ExtensionResolver) !void {
    const bytes = resolver.resolve(name) orelse return error.UnknownExtension;
    try activateExtension(world, gpa, entity, name, bytes);
}

/// M1.0.9 — runtime extension deactivation entry, reached from Etch
/// `entity.deactivate_extension("X")`. Fires the `on_detach` seam FIRST (so the
/// hook still reads the extension's components), then removes the extension's
/// declared components and drops the entity's active-extension record. The
/// extension must be active (`error.ExtensionNotActive` otherwise). The §30.5
/// reject conflict policy makes the component set unambiguous — no two active
/// extensions share a component — so removal needs no provenance tracking.
/// M1.0.9 — deactivate one extension on one entity given its cooked bytes: the
/// shared bytes-taking core reused by the runtime deactivate entry AND the
/// interpreter's deferred B1 flush. Fires `on_detach` FIRST (the hook still reads
/// the extension's components), then removes them, then drops the active record.
/// The extension must be active (`error.ExtensionNotActive`). The §30.5 reject
/// conflict policy makes the component set unambiguous — no provenance tracking.
pub fn deactivateExtension(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, ext_bytes: []const u8) !void {
    if (!world.hasEntityExtension(entity, name)) return error.ExtensionNotActive;
    const ext = try openVerified(ext_bytes);

    // `on_detach` before the components go away (the hook can still read them).
    const on_detach_text: ?[]const u8 = if (ext.hookCount() > 0) ext.hook(0).on_detach else null;
    try world.dispatchOnDetach(entity, name, on_detach_text);

    // Remove the extension's declared components (mono-entity, like activate).
    var ai: u32 = 0;
    while (ai < ext.archetypeCount()) : (ai += 1) {
        const arch = ext.archetype(ai);
        if (arch.entity_count == 0) continue;
        var c: usize = 0;
        while (c < arch.component_count) : (c += 1) {
            const sch = ext.schema(arch.schemaIndex(c));
            const cid = world.componentId(sch.name) orelse return error.UnknownComponent;
            if (world.componentBytes(entity, cid) != null) {
                try world.removeComponentDynamic(gpa, entity, cid);
            }
        }
    }

    world.removeEntityExtension(gpa, entity, name);
}

/// M1.0.9 — runtime deactivation entry (direct-programmatic path): resolve the
/// extension by name, then `deactivateExtension`. The Etch method goes through
/// the interpreter's deferred queue instead (B1); this stays for direct callers.
pub fn runtimeDeactivate(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, resolver: ExtensionResolver) !void {
    const bytes = resolver.resolve(name) orelse return error.UnknownExtension;
    try deactivateExtension(world, gpa, entity, name, bytes);
}

/// Load the resources block (E3) — the load-side mirror of M1.0.3's non-POD
/// resource path. For each resource: resolve its schema index → runtime
/// `ComponentId` (the E1 remap, already size/alignment-validated), copy the POD
/// `data` (string-field slots are zeroed on disk), then for each `string` field
/// of that resource type (offsets from the runtime `FieldDesc`) intern the
/// cooked value into the **Tier-0 persistent heap** (`allocImmortal`,
/// `type_string`) and write the resulting `StringSlot` into the slot — the same
/// in-memory `StringSlot` byte layout `ecs_bridge` reads/writes. Each interned
/// block is recorded in `strings` (owned by `LoadResult`, reclaimed at
/// `deinit`); the install goes through `world.addResource`, which copies the
/// bytes. An empty string keeps the zeroed slot (`ptr == 0`, no block).
fn loadResources(
    world: *World,
    gpa: std.mem.Allocator,
    acc: Accessor,
    remap: []const ComponentId,
    strings: *std.ArrayListUnmanaged([*]u8),
) !void {
    const count = acc.resourceCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const r = acc.resource(i);
        const cid = remap[r.schema_index];
        const size = world.registry.componentSize(cid);
        std.debug.assert(r.data.len == size);

        const bytes = try gpa.alloc(u8, size);
        defer gpa.free(bytes); // `addResource` copies; this is scratch
        @memcpy(bytes, r.data);

        for (world.registry.componentFields(cid)) |fd| {
            if (fd.kind != .string_) continue;
            const sval = r.stringField(fd.offset) orelse continue;
            if (sval.len == 0) continue; // empty string → leave the zeroed slot

            try strings.ensureUnusedCapacity(gpa, 1);
            const p = try persistent.allocImmortal(gpa, persistent.type_string, sval.len);
            @memcpy(p[0..sval.len], sval);
            strings.appendAssumeCapacity(p); // capacity reserved → cannot fail

            const fslot: persistent.StringSlot = .{ .ptr = @intFromPtr(p), .len = @intCast(sval.len) };
            @memcpy(bytes[fd.offset..][0..@sizeOf(persistent.StringSlot)], std.mem.asBytes(&fslot));
        }

        // Scene resources are *injected into the resource map at load*
        // (`engine-spec.md` §19.1): the scene value is authoritative, so it
        // overrides a value the running program already installed at compile
        // (e.g. a declared resource's defaults) rather than erroring. The
        // overridden value's own string blocks are owned by whoever installed
        // them (the interp frees its compile-time defaults at teardown); the
        // newly-interned blocks here are owned by `LoadResult`.
        if (world.resources.getMutResource(cid)) |dst| {
            @memcpy(dst, bytes);
        } else {
            try world.addResource(gpa, cid, bytes);
        }
    }
}

/// Phase 2 — fire the `on_spawned` lifecycle for every loaded entity, in load
/// order, reusing the existing flush path (`observers.flushWithObservers` /
/// `applyRawCommand`). A pre-existing deferred queue is drained first; an
/// `on_spawned` rule may queue structural commands, drained after the pass.
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

/// Read a little-endian `u32` at file offset `off` (the accessor's `readU32` is
/// private; the loader reads reserved-section counts directly).
fn readU32At(acc: Accessor, off: u32) u32 {
    return std.mem.readInt(u32, acc.bytes[off..][0..4], .little);
}

// ─── inline tests ───────────────────────────────────────────────────────────

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
