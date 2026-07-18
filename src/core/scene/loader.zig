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
/// buffer), verify the content hash, then run the standalone **structural
/// validator** (`validate.structure`) before returning. The validator is the
/// single gate that lets every subsequent `Accessor` getter trust the
/// file-controlled offsets/counts it dereferences — no caller should touch an
/// accessor built any other way on externally-supplied bytes. Returns a
/// zero-copy `Accessor` borrowing `bytes` for its whole lifetime.
///
/// Order is load-bearing: header → hash → structure. `verifyHash` is no defense
/// against a crafted image (the hash is recomputable), so `validate.structure`
/// runs regardless of the hash and walks the raw bytes with checked arithmetic.
///
/// Errors:
///   - `error.TooShort` / `error.BadMagic` / `error.BadVersion` — invalid header
///   - `error.CorruptScene` — content hash does not match the header's
///   - `error.MalformedScene` — the structure is inconsistent (offsets, counts,
///     or references a getter would trust)
pub fn openVerified(bytes: []const u8) OpenError!Accessor {
    const acc = try Accessor.open(bytes);
    if (!acc.verifyHash()) return error.CorruptScene;
    try validate.structure(bytes, acc.header);
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
///   - `error.MalformedScene` — two schema entries resolve to the same
///     runtime `ComponentId` (duplicate schema names on disk; R11(b), M1.1.1-HF3)
///   - `error.OutOfMemory`
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
    // R11(b): two schema entries resolving to the same runtime `ComponentId` means
    // duplicate schema names on disk — malformed (the cook emits exactly one entry
    // per distinct id). The strictly-increasing file-local index check (validate
    // block (e)) cannot see this, since it compares indices, not resolved ids.
    for (remap, 0..) |a, ai| {
        for (remap[ai + 1 ..]) |b| {
            if (a == b) return error.MalformedScene;
        }
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
/// the map, and closes `mmap` if present). Loaded resource `string` blocks are
/// refcounted and owned by their `StringSlot`s (M1.1.1-HF1 / D1), not by the
/// `LoadResult` — the resource owner reclaims them at teardown.
pub const LoadResult = struct {
    spawned: []EntityId,
    uuid_to_entity: UuidMap,
    mmap: ?fs.Mmap,

    /// Free the loader-owned allocations and close the backing mmap (if any).
    /// Does **not** despawn the loaded entities — they belong to the `World` —
    /// and does **not** free the loaded resource `string` blocks: those are
    /// refcounted, owned by the resources' `StringSlot`s (D1), and reclaimed by
    /// the resource owner's teardown exactly like interp-written resource
    /// strings (`interp.zig` deinit). Teardown parity — no new mechanism.
    pub fn deinit(self: *LoadResult, gpa: std.mem.Allocator) void {
        gpa.free(self.spawned);
        self.uuid_to_entity.deinit(gpa);
        if (self.mmap) |*m| m.close();
        self.* = undefined;
    }
};

/// Count of entries in the on-disk UUID table, derived from the header section
/// offsets (`uuid_table` ends where `schema_table` begins; 16 B per UUID). Lets
/// the loader bounds-check parent ordinals without a new accessor getter.
///
/// Relies on `validate.structure` (run in `openVerified` before any loader step
/// reaches here): it proves check (a) `uuid_table_offset ≤ schema_table_offset`
/// so the subtraction never underflows, and check (b) their difference is a
/// multiple of 16 so the division is exact. Callers must have opened via
/// `openVerified` — never on unvalidated bytes.
fn uuidCount(acc: Accessor) u32 {
    return (acc.header.schema_table_offset - acc.header.uuid_table_offset) / 16;
}

// ─── D2 — resource-write transaction (snapshot / commit / rollback) ──────────

/// One resource the loader wrote, recorded for commit or rollback (M1.1.1-HF1 /
/// D2). `snapshot` is the resource's full byte image captured immediately BEFORE
/// the loader overwrote its string fields — its slots point at the *old* blocks.
/// A `null` snapshot marks a resource the loader ADDED fresh (rollback removes it
/// rather than restoring). The load is transactional: on success `commitResources`
/// decrefs the replaced old blocks; on any post-first-spawn error `rollbackResources`
/// decrefs the new blocks and restores/removes each touched resource.
const ResourceEdit = struct {
    cid: ComponentId,
    snapshot: ?[]u8,
    /// The resource's dirty bit BEFORE the loader touched it, captured at
    /// snapshot time (before the first `getMutResource`, which sets it true).
    /// Restored on rollback so a rejected load leaves no spurious
    /// `when resource T changed` (M1.1.1-HF2 C6). Moot on commit (a committed
    /// write is genuinely dirty) and for a freshly-added resource (rollback
    /// removes it).
    dirty_before: bool,
};

const ResourceJournal = std.ArrayListUnmanaged(ResourceEdit);

/// Decref every `.string_` field block referenced by `bytes` (a snapshot image or
/// the live resource buffer) for resource type `cid`. Empty slots (`ptr == 0`) are
/// skipped; immortal blocks no-op. Shared by commit (old blocks, read from the
/// snapshot) and rollback (new blocks, read from the live buffer).
fn decrefResourceStrings(world: *const World, gpa: std.mem.Allocator, cid: ComponentId, bytes: []const u8) void {
    for (world.registry.componentFields(cid)) |fd| {
        if (fd.kind != .string_) continue;
        var ss: persistent.StringSlot = undefined;
        @memcpy(std.mem.asBytes(&ss), bytes[fd.offset..][0..@sizeOf(persistent.StringSlot)]);
        if (ss.ptr != 0) persistent.decref(gpa, @ptrFromInt(ss.ptr));
    }
}

/// Commit the loader's resource writes (M1.1.1-HF1 / D2). For each resource that
/// REPLACED a prior value, decref the old string blocks the snapshot captured —
/// they are no longer referenced (the live slot holds the new block). The new
/// blocks stay live, owned by the resource slots (freed by the resource owner's
/// teardown — parity with interp-written strings). Frees each snapshot and the
/// journal. Infallible.
fn commitResources(world: *const World, gpa: std.mem.Allocator, journal: *ResourceJournal) void {
    for (journal.items) |edit| {
        if (edit.snapshot) |snap| {
            decrefResourceStrings(world, gpa, edit.cid, snap);
            gpa.free(snap);
        }
    }
    journal.deinit(gpa);
}

/// Roll back the loader's resource writes (M1.1.1-HF1 / D2), best-effort under
/// OOM. For each touched resource, decref the NEW string blocks it installed (read
/// from the live buffer), then restore the snapshot (a replaced resource) or remove
/// it (a freshly-added one). Every touched resource is left holding its prior bytes
/// / prior presence; the old blocks were never decreffed, so no incref is needed
/// and no double-free is possible. Frees each snapshot and the journal.
fn rollbackResources(world: *World, gpa: std.mem.Allocator, journal: *ResourceJournal) void {
    // Reverse (LIFO) — an undo-log replays in the opposite order it recorded.
    // A `.bin` may carry two entries of the SAME cid; those edits alias one live
    // slot, so undoing them FORWARD would restore an old block and then decref
    // that just-restored block, corrupting its refcount into a teardown
    // double-free / use-after-free. Mirrors the reverse despawn in `loadFromBytes`.
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
            // C6: the `getMutResource` calls above (decref pass + restore) forced
            // `dirty = true`; restore the pre-load state so the rejected load
            // leaves no spurious `when resource T changed`.
            world.resources.setDirty(edit.cid, edit.dirty_before);
        } else {
            world.resources.removeResource(gpa, edit.cid) catch {};
        }
    }
    journal.deinit(gpa);
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
    defer spawned.deinit(gpa);
    var uuid_to_entity: UuidMap = .empty;
    errdefer uuid_to_entity.deinit(gpa);
    var journal: ResourceJournal = .empty;

    // D2 — the load is loader-transactional. On any error after the first spawn,
    // roll back the loader's OWN mutations: decref the string blocks it installed
    // and restore/remove the resources it touched, then despawn every spawned
    // entity in reverse order (which, post-D7, also purges each entity's extension
    // entry). The contract covers the loader's mutations only — side effects of
    // user `on_attach` / `on_spawned` hooks that ran before the failure are
    // outside it. Best-effort under OOM (despawn on the D3-atomic release path).
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

    // Build the owned spawned slice BEFORE committing so a dupe OOM still rolls
    // back cleanly (commit is irreversible — it decrefs the replaced old blocks).
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

    // C2 (M1.1.1-HF2): pre-reserve both maps to the load's totals up front so
    // every per-entity insert below is assume-capacity (infallible). A
    // post-spawn OOM must never strand a just-spawned entity outside `spawned`
    // (the slice the `loadFromBytes` rollback errdefer despawns) — such an
    // entity would be a live orphan the rollback never reclaims. The
    // reservations are the only fallible step added here, and they run BEFORE
    // any spawn, so on their OOM nothing has spawned and the errdefer's despawn
    // loop is a no-op. `spawnDynamicWithValues` stays fallible, but on its
    // failure it records nothing, so the already-recorded prior entities are
    // despawned and the failed one never existed. Both maps take exactly
    // `total_entities` inserts — one per entity; C2b rejects duplicate UUID
    // ordinals, so `uuid_to_entity`'s capacity no longer depends on ordinal
    // validity (defence in depth against a malformed hash-valid scene).
    var total_entities: usize = 0;
    {
        var bi: u32 = 0;
        while (bi < arch_count) : (bi += 1) total_entities += acc.archetype(bi).entity_count;
    }
    // A hash-valid malformed scene can declare block entity counts whose sum
    // exceeds the hash map's u32 capacity domain — reject it as malformed
    // rather than panic in the `@intCast` below (the loader's contract is
    // `MalformedScene`, not a panic — C2b).
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
            // C2b (M1.1.1-HF2): validate the entity's own UUID ordinal BEFORE the
            // spawn — mirroring the parent-ordinal / cross-ref / extension checks.
            // A malformed (hash-valid) scene could otherwise dereference out of
            // the UUID table via `uuidAt`, and inserting > `uuidCount` distinct
            // keys would overflow the pre-reserved map post-spawn. Pre-spawn
            // error: the current entity is not yet created and priors are in
            // `spawned`, so the standard rollback reclaims them.
            const uuid_ord = block.entityUuidOrdinal(slot);
            if (uuid_ord >= ucount) return error.MalformedScene;

            for (0..cc) |c| payloads[c] = block.componentSlot(c, slot);
            const eid = try world.spawnDynamicWithValues(gpa, ids, payloads);
            // Record in `spawned` FIRST so the rollback covers `eid` even if the
            // duplicate-ordinal check below rejects the scene. Both inserts are
            // assume-capacity (reserved to `total_entities`, the exact put count).
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

/// The single archetype block of a mono-entity extension prefab (R12(c),
/// M1.1.1-HF3): STRICT cardinality — `total == 0` → `error.EmptyExtension`,
/// `total > 1` → `error.MultiEntityExtensionUnsupported`, else the one archetype
/// whose `entity_count == 1`. The single source of the mono-entity contract,
/// shared by `activateExtension` and `deactivateExtension`.
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

/// Activate one extension on one entity (M1.0.6 E6; **R6 atomicity rewrite,
/// M1.1.1-HF3**) — the shared bytes-taking path reused by load
/// (`applyExtensions`), the runtime `activate_extension` entry, and the
/// interpreter's deferred B1 flush. Structured reserve-then-mutate so it is
/// all-or-nothing under OOM:
///   0. Reject re-activation of an already-active extension
///      (`error.ExtensionAlreadyActive`, R12(d) — closes the hook-only
///      re-activation gap); resolve the strict mono-entity archetype
///      (`extEntityArchetype`: `total == 0`/`> 1` rejected).
///   1. Prevalidate with ZERO mutation: resolve every `ComponentId`; size-check;
///      conflict-check each against the entity.
///   2. Reserve the extension-record capacity (fallible, no observable mutation).
///   3. Grouped add — the SINGLE fallible component mutation, itself atomic
///      (`world.addComponentsDynamic`): one archetype migration, not N.
///   4. Record the extension (infallible) then fire `on_attach`.
/// On any failure through step 3 the entity is left untouched (no partial
/// extension — the defect this rewrite closes). The activation is committed
/// BEFORE the hook; a hook error propagates but does not unwind it (same contract
/// as load-time hooks, M1.1.1-HF1 / D2).
///
/// Conflict policy: a component the entity already carries is rejected with
/// `error.ExtensionComponentConflict` — the normative runtime policy for additive
/// extension conflicts. The `extends` model is strictly additive: no two active
/// extensions may declare the same component on one entity. See
/// `engine-scene-serialization.md` (extension additive conflicts) as the
/// authority; the static cook counterpart is the fatal `E1797
/// ExtensionAdditiveConflict`, and together they guarantee `cooked ⇒ loadable`.
pub fn activateExtension(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, ext_bytes: []const u8) !void {
    // Step 0 — refuse re-activation (R12(d)); works for hook-only (0-component)
    // extensions too, where the component-conflict check below cannot fire.
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

    // Step 2 — reserve the extension-record capacity (fallible, no observable
    // mutation). `owned` is freed if we abort before committing it.
    const owned = try world.reserveEntityExtension(gpa, entity, name);
    var committed = false;
    errdefer if (!committed) gpa.free(owned);

    // Step 3 — grouped add: THE single fallible component mutation (atomic).
    try world.addComponentsDynamic(gpa, entity, cids, values);

    // Step 4 — record the extension (infallible; takes ownership of `owned`),
    // then fire `on_attach`. The record is BEFORE the hook so a hook querying
    // `has_extension` / `active_extensions` sees it (M1.0.9).
    world.commitEntityExtension(gpa, entity, owned);
    committed = true;
    const on_attach_text: ?[]const u8 = if (ext.hookCount() > 0) ext.hook(0).on_attach else null;
    try world.dispatchOnAttach(entity, name, on_attach_text);
}

/// M1.0.9 — runtime extension activation entry, reached from Etch
/// `entity.activate_extension("X")` (the interpreter resolves the name through
/// the bridge's `ExtensionResolver`). Reuses the shared `activateExtension`
/// path (atomic prevalidate → reserve → grouped add → record → `on_attach`).
/// Unknown name → `error.UnknownExtension`; a component the entity already
/// carries → `error.ExtensionComponentConflict` (the normative additive-conflict
/// reject policy — see `engine-scene-serialization.md`).
pub fn runtimeActivate(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, resolver: ExtensionResolver) !void {
    const bytes = resolver.resolve(name) orelse return error.UnknownExtension;
    try activateExtension(world, gpa, entity, name, bytes);
}

/// Deactivate one extension on one entity given its cooked bytes (M1.0.9; **R6
/// atomicity rewrite, M1.1.1-HF3**) — the shared bytes-taking core reused by the
/// runtime deactivate entry and the interpreter's deferred B1 flush.
///
/// R12(b) prepare/commit order — the hook-ordering guarantee is now REAL:
///   1. Prevalidate with ZERO mutation: extension active (`ExtensionNotActive`),
///      bytes valid, strict mono-entity archetype, declared components resolvable;
///      collect the ones currently present.
///   2. PREPARE the grouped remove — all the fallible work (target archetype,
///      capacity, reserved dst slot), no observable mutation yet.
///   3. Fire `on_detach` FIRST (it still reads the present components). If it
///      fails, ABORT the prepared remove — the entity stays fully active.
///   4. COMMIT the remove + drop the record — both infallible.
/// So after the hook succeeds, NOT ONE fallible step remains; a hook failure rolls
/// the reserved slot back. (A component-less hook-only extension skips 2/4 and
/// just fires `on_detach` then drops the record.)
///
/// Conflict policy: reject-on-conflict (see `activateExtension`) keeps the
/// component set unambiguous — no two active declarants (base or extension) share a
/// component — so removal needs no provenance tracking. Normative; see
/// `engine-scene-serialization.md` (extension additive conflicts).
pub fn deactivateExtension(world: *World, gpa: std.mem.Allocator, entity: EntityId, name: []const u8, ext_bytes: []const u8) !void {
    if (!world.hasEntityExtension(entity, name)) return error.ExtensionNotActive;
    const ext = try openVerified(ext_bytes);
    const arch = try extEntityArchetype(ext); // strict mono-entity cardinality
    const comp_count = arch.component_count;

    // Step 1 — prevalidate + collect the declared components currently present
    // (ZERO mutation). Under the reject policy all are present; the presence
    // filter is belt-and-braces.
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

    // Hook-only extension (no present components): no structural change to make —
    // fire `on_detach`, then drop the record.
    if (n == 0) {
        try world.dispatchOnDetach(entity, name, on_detach_text);
        world.removeEntityExtension(gpa, entity, name);
        return;
    }

    // Step 2 — PREPARE (all fallible work; no observable mutation yet).
    const prepared = try world.prepareRemoveComponentsDynamic(gpa, entity, cids_buf[0..n]);
    // Step 3 — `on_detach` FIRST; roll the prepared remove back if it fails. After
    // this `try`, only infallible steps remain, so the errdefer never fires past it.
    errdefer world.abortRemoveComponentsDynamic(prepared);
    try world.dispatchOnDetach(entity, name, on_detach_text);

    // Step 4 — commit (infallible) + drop the record (infallible).
    world.commitRemoveComponentsDynamic(prepared);
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
/// resource path, following the `ecs_bridge` write discipline (M1.1.1-HF1 / D1):
/// for each resource, snapshot its current bytes, install the POD `data`
/// (string-field slots are zeroed on disk), then for each `string` field intern
/// the cooked value into the **Tier-0 persistent heap** as a **refcounted** block
/// (`persistent.alloc`, not immortal) and write its `StringSlot`. The new blocks
/// are owned by the slot, reclaimed by the resource owner's teardown (parity with
/// interp-written strings); the old blocks the snapshot captured are decreffed at
/// commit. Each touched resource is recorded in `journal` so the load is
/// transactional (D2). An empty string keeps the zeroed slot (`ptr == 0`).
///
/// Scene resources are *injected into the resource map at load* (`engine-spec.md`
/// §19.1): the scene value is authoritative and overrides a value the running
/// program already installed (e.g. a declared resource's defaults) rather than
/// erroring; the overridden value's old string blocks are decreffed at commit.
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

        // M1.0.17 — the loader reconstructs POD + interned `string` resource fields
        // only. A collection field (`.array_`/`.map_`/`.set_`) on disk is a zeroed
        // `CollectionSlot` (ptr == 0); installing it would crash the interpreter on
        // first access AND overwrite (without decref) any container the running
        // program already built — a leak. Reject cleanly BEFORE touching the
        // resource; full persistent-block reconstruction at scene-load is a Tier-0
        // scene-serialization milestone (M1.6), not this one.
        for (world.registry.componentFields(cid)) |fd| switch (fd.kind) {
            .array_, .map_, .set_ => return error.CollectionResourceFieldUnsupported,
            else => {},
        };

        const size = world.registry.componentSize(cid);
        std.debug.assert(r.data.len == size);

        // Reserve the journal slot up front so recording the edit cannot fail
        // after the resource is mutated (reserve-then-mutate).
        try journal.ensureUnusedCapacity(gpa, 1);

        // Install the POD image (string slots zeroed on disk), capturing the
        // pre-write snapshot. For an existing resource the snapshot holds the old
        // string slots (decreffed at commit / restored at rollback); for a fresh
        // one the snapshot is null (rollback removes it).
        // C6 (M1.1.1-HF2): capture the pre-write dirty bit BEFORE `getMutResource`
        // (which unconditionally sets it true), so a rollback can restore it — a
        // rejected load must not leave a spurious `when resource T changed`.
        // Absent resource → false (added fresh below; rollback removes it, moot).
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

        // Journal the edit BEFORE the fallible string writes, so a mid-field OOM
        // rolls the whole resource back (decref partial new blocks + restore).
        journal.appendAssumeCapacity(.{ .cid = cid, .snapshot = snapshot, .dirty_before = dirty_before });

        // Per string field: alloc a REFCOUNTED block owned by the slot (D1), copy
        // the cooked value, write the new `StringSlot`.
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
/// and the Settings write, exercising the full transactional rollback (D2).
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
    // (the C2 orphan). Under the pre-fix code, an OOM on the post-spawn
    // `uuid_to_entity.put` / `spawned.append` left exactly that orphan; the
    // rollback (allocation-free after C1) never reclaimed it. `entityCount == 0`
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

    // C6: dirty is restored to its pre-load value (false), not left spuriously
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
/// (both size 4, align 4). Reused by the E3 activate-atomicity test.
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
    // guard cannot fire, so R12(d)'s `hasEntityExtension` check is what rejects
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
