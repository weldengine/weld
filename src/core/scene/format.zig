//! `.scene.bin` format — Tier 0, single source of truth shared verbatim with
//! the M1.0.5 runtime loader (`engine-scene-serialization.md` §4).
//!
//! This file owns two things:
//!   1. The **on-disk format contract** — magic / version constants and the SoA
//!      column-layout rules (the M1.0.5 loader SLICES each column at an entity's
//!      rank and hands the slices to the World's spawn surface, so the cook and
//!      the loader must agree on column order, stride and alignment — the
//!      agreement is what makes the slice land on the right bytes, and it is
//!      required whether or not the destination is an archetype chunk). The `SceneHeader` extern struct + the byte-level
//!      writer/accessor land in E2.
//!   2. The **neutral cook model** (`CookModel`) — the in-memory representation
//!      the M1.0.4 Etch cook driver (`src/etch/scene_cook.zig`) produces and the
//!      E2 writer serializes. It is raw bytes + index tables + Tier-0 `FieldKind`
//!      only — **no `weld_etch` types** (tier discipline: `src/core/scene/` never
//!      imports `weld_etch`).
//!
//! SoA layout contract (correctness contract with the M1.0.5 loader):
//!   * Component columns are flat N-element SoA arrays (chunk-agnostic); the
//!     loader slices them across 16 KB chunks.
//!   * Column order = ascending component order (`archetype.sortComponentIds`).
//!   * Column stride = `Registry.componentSize(component)`.
//!   * Each column start is aligned to the component alignment
//!     (`Registry.componentAlignment(component)`).
//! Components are POD-strict (validator-gated), so archetype columns are pure
//! byte-copyable scalars/enums — never the resource-only `string_` slot.
//!
//! Component identity (on-disk, `engine-ecs-internals.md` §10 — Schema Registry):
//! the `.scene.bin` carries a **Schema Registry** section; an archetype's
//! component mask and a resource's schema reference are encoded as **file-local
//! indices** into that table — never as runtime `ComponentId`s (which are not
//! stable across runs/processes). Phase-1 schema identity is the component
//! **name** (the runtime registry for Etch-declared components exposes only
//! `componentName`/`idOf` — there is no comptime `schema_hash` for them); the
//! M1.0.5 loader maps each schema name back to a runtime id via `idOf(name)`.
//! The in-memory `CookModel` below keeps its `ComponentId`s — the in-process
//! round-trip resolves them through the cook's own registry; only the E2
//! on-disk encoding is schema-indexed.

const std = @import("std");

const registry_mod = @import("../ecs/registry.zig");

/// Re-exported so the cook model and the loader name component ids / field
/// kinds through `weld_core.scene.format` without reaching into `ecs.registry`.
pub const ComponentId = registry_mod.ComponentId;
/// Re-exported (see `ComponentId`). The writer/accessor dispatch on this to
/// handle the resource-only `string_` slot (a string-table reference on disk).
pub const FieldKind = registry_mod.FieldKind;

// ── On-disk format constants ────────────────────────────────────────────────

/// File magic at offset 0. `[4]u8` (not a `u32`) so the on-disk byte order is
/// unambiguous regardless of host endianness (the `RuntimeHeader` precedent,
/// `src/modules/asset_pipeline/format/runtime_bin.zig`).
pub const magic = [4]u8{ 'W', 'S', 'C', 'N' };

/// `.scene.bin` binary format version (the codec/layout version — bumped on any
/// breaking layout change). Distinct from `content_version` (the authored
/// scene's `version:` field, opaque to the codec).
///
/// **2** (M1.0.6): the reserved sections became real — the cross-references table
/// and the `extensions_offset` region (Entity Extensions Table + Prefab ID Table
/// + hooks) went from bare count-placeholders (`[0]`) to full structures. A break
/// vs v1 (M1.0.4/M1.0.5): a v1 file fails `BadVersion` and must be re-cooked
/// (`.scene.bin`/`.prefab.bin` are deterministic build artifacts, no prod files
/// in Phase 1).
pub const format_version: u16 = 2;

/// `SceneHeader` size — the fixed 64-byte (cache-line) prefix every file opens
/// with. All section offsets in the header are relative to the file start.
pub const header_size: usize = 64;

/// Errors from `SceneHeader.read` / accessor open.
pub const ReadError = error{
    /// The byte slice is smaller than a `SceneHeader`.
    TooShort,
    /// The first four bytes are not `WSCN`.
    BadMagic,
    /// `version` is not a format version this build understands.
    BadVersion,
};

/// `.scene.bin` header — 64 bytes, cache-line aligned, the prefix of every file.
/// Read/written field-by-field little-endian (the `RuntimeHeader` discipline,
/// `src/modules/asset_pipeline/format/runtime_bin.zig`) so the on-disk layout is
/// endianness-defined and unaligned-safe — never `@ptrCast`'d off an arbitrary
/// buffer. All Weld targets are little-endian, so this is also the native order.
///
/// `hash` covers the content AFTER the header (all sections); a reader can
/// recompute `std.hash.XxHash64.hash(0, bytes[header_size..])` and compare.
/// Section offsets are file-relative. `schema_table_offset` / `schema_count`
/// locate the Schema Registry (`engine-ecs-internals.md` §10); `extensions` and
/// `crossrefs` are reserved (written empty in M1.0.4, populated by M1.0.6).
pub const SceneHeader = extern struct {
    magic: [4]u8 = magic, // @0
    version: u16 = format_version, // @4
    content_version: u16 = 0, // @6 — authored scene `version:` (opaque to codec)
    platform: u16 = 0, // @8 — reserved (0 = platform-agnostic)
    flags: u16 = 0, // @10 — reserved
    entity_count: u32 = 0, // @12
    resource_count: u32 = 0, // @16
    schema_count: u32 = 0, // @20
    string_table_offset: u32 = 0, // @24
    uuid_table_offset: u32 = 0, // @28
    schema_table_offset: u32 = 0, // @32
    resources_offset: u32 = 0, // @36
    archetypes_offset: u32 = 0, // @40
    extensions_offset: u32 = 0, // @44 — reserved (empty in M1.0.4)
    crossrefs_offset: u32 = 0, // @48 — reserved (empty in M1.0.4)
    _reserved: u32 = 0, // @52 — pads `hash` to the 8-aligned @56
    hash: u64 = 0, // @56

    comptime {
        std.debug.assert(@sizeOf(SceneHeader) == header_size);
        std.debug.assert(@alignOf(SceneHeader) == 8);
        std.debug.assert(@offsetOf(SceneHeader, "hash") == 56);
        std.debug.assert(@offsetOf(SceneHeader, "entity_count") == 12);
    }

    /// Serialize the header into `buf` little-endian, field by field.
    pub fn writeTo(self: SceneHeader, buf: *[header_size]u8) void {
        @memset(buf, 0);
        @memcpy(buf[0..4], &self.magic);
        std.mem.writeInt(u16, buf[4..6], self.version, .little);
        std.mem.writeInt(u16, buf[6..8], self.content_version, .little);
        std.mem.writeInt(u16, buf[8..10], self.platform, .little);
        std.mem.writeInt(u16, buf[10..12], self.flags, .little);
        std.mem.writeInt(u32, buf[12..16], self.entity_count, .little);
        std.mem.writeInt(u32, buf[16..20], self.resource_count, .little);
        std.mem.writeInt(u32, buf[20..24], self.schema_count, .little);
        std.mem.writeInt(u32, buf[24..28], self.string_table_offset, .little);
        std.mem.writeInt(u32, buf[28..32], self.uuid_table_offset, .little);
        std.mem.writeInt(u32, buf[32..36], self.schema_table_offset, .little);
        std.mem.writeInt(u32, buf[36..40], self.resources_offset, .little);
        std.mem.writeInt(u32, buf[40..44], self.archetypes_offset, .little);
        std.mem.writeInt(u32, buf[44..48], self.extensions_offset, .little);
        std.mem.writeInt(u32, buf[48..52], self.crossrefs_offset, .little);
        std.mem.writeInt(u64, buf[56..64], self.hash, .little);
    }

    /// Parse + validate a header from the front of `bytes`. Checks length,
    /// magic, and version; does NOT verify `hash` (the caller may).
    pub fn read(bytes: []const u8) ReadError!SceneHeader {
        if (bytes.len < header_size) return error.TooShort;
        var h: SceneHeader = .{};
        @memcpy(&h.magic, bytes[0..4]);
        if (!std.mem.eql(u8, &h.magic, &magic)) return error.BadMagic;
        h.version = std.mem.readInt(u16, bytes[4..6], .little);
        if (h.version != format_version) return error.BadVersion;
        h.content_version = std.mem.readInt(u16, bytes[6..8], .little);
        h.platform = std.mem.readInt(u16, bytes[8..10], .little);
        h.flags = std.mem.readInt(u16, bytes[10..12], .little);
        h.entity_count = std.mem.readInt(u32, bytes[12..16], .little);
        h.resource_count = std.mem.readInt(u32, bytes[16..20], .little);
        h.schema_count = std.mem.readInt(u32, bytes[20..24], .little);
        h.string_table_offset = std.mem.readInt(u32, bytes[24..28], .little);
        h.uuid_table_offset = std.mem.readInt(u32, bytes[28..32], .little);
        h.schema_table_offset = std.mem.readInt(u32, bytes[32..36], .little);
        h.resources_offset = std.mem.readInt(u32, bytes[36..40], .little);
        h.archetypes_offset = std.mem.readInt(u32, bytes[40..44], .little);
        h.extensions_offset = std.mem.readInt(u32, bytes[44..48], .little);
        h.crossrefs_offset = std.mem.readInt(u32, bytes[48..52], .little);
        h.hash = std.mem.readInt(u64, bytes[56..64], .little);
        return h;
    }
};

/// On-disk Schema Registry entry (`engine-ecs-internals.md` §10). One per
/// distinct component/resource type referenced by the scene. Phase-1 identity is
/// the component **name** (`name_ref` into the string table); `size`/`alignment`
/// (from `Registry.componentSize`/`componentAlignment`) make archetype columns
/// self-describing so the accessor slices them without a registry. The M1.0.5
/// loader maps `name` → its runtime `ComponentId` via `idOf`. Field-level schema
/// (`engine-ecs-internals.md` §10 "champs", for migration) is deferred — Etch
/// components have no comptime schema hash; the name is the identity.
pub const SchemaEntry = extern struct {
    /// String-table byte offset of the component's name.
    name_ref: u32,
    /// `Registry.componentSize` — the SoA column stride.
    size: u16,
    /// `Registry.componentAlignment` — the SoA column start alignment.
    alignment: u16,
};

/// On-disk Cross-references Table entry (M1.0.6 D-B) — one per entity→entity
/// `Entity` component field that references another entity of the same scene.
/// 16 bytes, 4-aligned. All four fields are file-local ordinals/indices (never
/// runtime ids): the loader resolves them against the UUID table + the schema
/// remap. The bearing field's 8-byte slot is written `EntityId.dead` in its SoA
/// column at cook; the loader patches it to the target's runtime handle.
pub const CrossRefEntry = extern struct {
    /// UUID-table ordinal of the entity bearing the field (the reference source).
    source_uuid_ordinal: u32,
    /// File-local Schema Registry index of the bearing component.
    schema_index: u32,
    /// Byte offset of the `Entity` field within the component slot.
    field_offset: u32,
    /// UUID-table ordinal of the referenced (target) entity.
    target_uuid_ordinal: u32,

    comptime {
        std.debug.assert(@sizeOf(CrossRefEntry) == 16);
        std.debug.assert(@alignOf(CrossRefEntry) == 4);
    }

    /// Read a `CrossRefEntry` little-endian from `bytes` at `off` (unaligned-safe,
    /// the codec discipline — never `@ptrCast`). The accessor's `crossref(i)`.
    pub fn readAt(bytes: []const u8, off: usize) CrossRefEntry {
        return .{
            .source_uuid_ordinal = std.mem.readInt(u32, bytes[off..][0..4], .little),
            .schema_index = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little),
            .field_offset = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little),
            .target_uuid_ordinal = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .little),
        };
    }
};

/// Byte offset (relative to the column region start `region_start`) of column
/// `i` within an archetype block, given each column's `sizes`/`aligns` in column
/// order and the block's `entity_count`. **Writer and accessor MUST call this**
/// so their offsets agree — it is the single source of truth for intra-block SoA
/// column placement (column start aligned to the component alignment).
pub fn columnOffset(region_start: usize, sizes: []const u16, aligns: []const u16, entity_count: u32, i: usize) usize {
    var off = region_start;
    var c: usize = 0;
    while (c < i) : (c += 1) {
        off = std.mem.alignForward(usize, off, aligns[c]);
        off += @as(usize, sizes[c]) * entity_count;
    }
    return std.mem.alignForward(usize, off, aligns[i]);
}

/// End offset of the whole column region (= start of whatever follows the
/// columns), given the same inputs as `columnOffset`.
pub fn columnsRegionEnd(region_start: usize, sizes: []const u16, aligns: []const u16, entity_count: u32) usize {
    var off = region_start;
    for (sizes, aligns) |sz, al| {
        off = std.mem.alignForward(usize, off, al);
        off += @as(usize, sz) * entity_count;
    }
    return off;
}

// ── Neutral cook model (E1 output → E2 writer input) ─────────────────────────
//
// All references below are indices into the `CookModel`'s own tables; the E2
// writer resolves them to on-disk offsets. No `weld_etch` types appear here.

/// `parent_uuid` sentinel: the entity has no parent (root entity).
pub const no_parent: u32 = std.math.maxInt(u32);

/// One resource `string_` field. The field's 16-byte slot in `ResourceEntry.data`
/// is left zeroed; the writer fills it from `str` (the field's UTF-8 value lives
/// in `CookModel.strings`). Splitting the string out keeps `data` POD and lets
/// the writer dispatch the on-disk string-table reference on `FieldKind.string_`.
pub const StringFieldRef = struct {
    /// Byte offset of the `string_` slot within `ResourceEntry.data`.
    offset: u16,
    /// Index into `CookModel.strings` — the field's resolved UTF-8 value.
    str: u32,
};

/// One serialized resource (the scene's `resources { … }` block, one per
/// resource instance). `schema_id` is the cook's in-memory registry
/// `ComponentId` of the resource type (the E2 writer re-encodes it as a
/// file-local Schema Registry index on disk — see the file header). `data` is
/// `Registry.componentSize(schema_id)` bytes: POD scalar/enum fields are encoded
/// in place; each `string_` field's slot is zeroed and listed in `string_fields`.
pub const ResourceEntry = struct {
    schema_id: ComponentId,
    data: []u8,
    string_fields: []StringFieldRef,
};

/// Per-entity identity carried alongside its archetype's SoA columns. The entity
/// occupies slot `i` (its index in `ArchetypeBlock.entities`) of every column.
pub const EntityEntry = struct {
    /// Index into `CookModel.strings` — the entity's name.
    name: u32,
    /// Index into `CookModel.uuids` — the entity's 16-byte UUID.
    uuid: u32,
    /// Index into `CookModel.uuids` — the parent entity's UUID, or `no_parent`.
    parent_uuid: u32,
};

/// One archetype block: every entity sharing the same sorted component set, with
/// its components laid out as flat N-element SoA columns.
pub const ArchetypeBlock = struct {
    /// Sorted-ascending component ids (`archetype.sortComponentIds`) — the
    /// in-memory archetype identity. These are the cook's runtime `ComponentId`s;
    /// the E2 writer re-encodes them as file-local Schema Registry indices on
    /// disk (the on-disk component mask is never raw `ComponentId`s — see the
    /// component-identity note in the file header).
    component_ids: []ComponentId,
    entity_count: u32,
    /// One column per `component_ids` entry, same order. `columns[i]` is a flat
    /// `entity_count * componentSize(component_ids[i])`-byte array; the entity at
    /// slot `s` occupies `columns[i][s*sz .. (s+1)*sz]`.
    columns: [][]u8,
    /// Per-entity identity, `len == entity_count`, slot order matches `columns`.
    entities: []EntityEntry,
};

/// One entity→entity cross-reference in the neutral cook model (M1.0.6 E4). The
/// model carries it in terms of the cook's in-memory `component_id`; the **writer**
/// converts `component_id` → file-local Schema Registry index when emitting the
/// on-disk `CrossRefEntry` (the model never knows file-local schema indices).
pub const CrossRef = struct {
    /// `CookModel.uuids` ordinal of the source entity (bears the `Entity` field).
    source_uuid: u32,
    /// The bearing component's in-memory `ComponentId` (writer maps → schema index).
    component_id: ComponentId,
    /// Byte offset of the `Entity` field within the component slot.
    field_offset: u32,
    /// `CookModel.uuids` ordinal of the referenced (target) entity.
    target_uuid: u32,
};

/// One entity's active extensions (M1.0.6 E5) in the neutral model — the
/// `extensions:` clause of a scene entity/instance. `uuid` is a `CookModel.uuids`
/// ordinal (the bearing entity); `prefab_ids` are indices into
/// `CookModel.prefab_id_table` (the dedup'd extension-name table). On-disk these
/// become the Entity Extensions Table entries @ `extensions_offset`.
pub const ExtModelEntry = struct {
    uuid: u32,
    prefab_ids: []const u32,
};

/// An `extends` prefab's hooks (M1.0.6 E5) in the neutral model — `on_attach` /
/// `on_detach` rendered as canonical Etch **text** (`CookModel.strings` indices,
/// `null` = the hook is absent). On-disk these become the hooks sub-section's
/// `{on_attach_ref, on_detach_ref}` (string-table offsets; `0` = absent). Only an
/// `extends` `.prefab.bin` carries one (`hook_count ∈ {0,1}` in M1.0.6).
pub const HookSet = struct {
    on_attach: ?u32,
    on_detach: ?u32,
};

/// The neutral, World-free model the cook produces. Owns every slice via an
/// internal arena; `deinit` frees the lot. The E2 writer reads it to emit
/// `.scene.bin`; the E1 cook test inspects it directly (no serialization).
pub const CookModel = struct {
    /// Deduplicated UTF-8 strings: entity names + resource `string_` values.
    strings: [][]const u8,
    /// 16-byte UUIDs: entity UUIDs (indexed by `EntityEntry.uuid`/`parent_uuid`).
    uuids: [][16]u8,
    resources: []ResourceEntry,
    archetypes: []ArchetypeBlock,
    /// Entity→entity cross-references (M1.0.6 E4); empty for a scene with no
    /// `Entity` field references and for every prefab. Serialized to the
    /// Cross-references Table @ `crossrefs_offset`.
    cross_refs: []const CrossRef = &.{},
    /// Active-extension entries (M1.0.6 E5) — one per scene entity/instance with a
    /// non-empty `extensions:` clause. Empty for a prefab and for an extension-free
    /// scene. Serialized to the Entity Extensions Table @ `extensions_offset`.
    ext_entries: []const ExtModelEntry = &.{},
    /// Deduplicated extension-prefab names (M1.0.6 E5), as `CookModel.strings`
    /// indices; `ExtModelEntry.prefab_ids` index this table. Serialized to the
    /// Prefab ID Table (string-table offsets).
    prefab_id_table: []const u32 = &.{},
    /// `extends` prefab hooks (M1.0.6 E5) — `hook_count ∈ {0,1}`. Empty for a
    /// scene and for `of`/standalone prefabs. Serialized to the hooks sub-section.
    hooks: []const HookSet = &.{},
    /// The authored scene's `version:` field (0 if absent). Propagated to
    /// `SceneHeader.content_version` — opaque to the codec, for the game's own
    /// scene-versioning/migration.
    content_version: u16 = 0,

    /// Backing arena for every slice above — the cook builds into it, the model
    /// owns it, `deinit` reclaims it in one shot.
    arena: std.heap.ArenaAllocator,

    /// Free all model memory (the backing arena). The model is invalid after.
    pub fn deinit(self: *CookModel) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "CookModel arena round-trips an empty model" {
    const gpa = std.testing.allocator;
    var model: CookModel = .{
        .strings = &.{},
        .uuids = &.{},
        .resources = &.{},
        .archetypes = &.{},
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 0), model.archetypes.len);
}

test "format magic + version constants are stable" {
    try std.testing.expectEqualSlices(u8, "WSCN", &magic);
    try std.testing.expectEqual(@as(u16, 2), format_version);
}

test "SceneHeader writeTo/read round-trips little-endian" {
    const h: SceneHeader = .{
        .entity_count = 7,
        .resource_count = 2,
        .schema_count = 3,
        .string_table_offset = 64,
        .archetypes_offset = 256,
        .hash = 0xDEADBEEFCAFEF00D,
    };
    var buf: [header_size]u8 = undefined;
    h.writeTo(&buf);
    try std.testing.expectEqualSlices(u8, "WSCN", buf[0..4]);
    const back = try SceneHeader.read(&buf);
    try std.testing.expectEqual(@as(u32, 7), back.entity_count);
    try std.testing.expectEqual(@as(u32, 3), back.schema_count);
    try std.testing.expectEqual(@as(u32, 256), back.archetypes_offset);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFEF00D), back.hash);
}

test "SceneHeader.read rejects bad magic, short input, bad version" {
    var buf: [header_size]u8 = undefined;
    (SceneHeader{}).writeTo(&buf);
    try std.testing.expectError(error.TooShort, SceneHeader.read(buf[0..10]));
    buf[0] = 'X';
    try std.testing.expectError(error.BadMagic, SceneHeader.read(&buf));
    (SceneHeader{}).writeTo(&buf);
    std.mem.writeInt(u16, buf[4..6], 999, .little);
    try std.testing.expectError(error.BadVersion, SceneHeader.read(&buf));
}

test "columnOffset aligns each column to its component alignment" {
    // Two columns: sz=8/al=8 then sz=1/al=1, 4 entities. region starts at 0.
    const sizes = [_]u16{ 8, 1 };
    const aligns = [_]u16{ 8, 1 };
    try std.testing.expectEqual(@as(usize, 0), columnOffset(0, &sizes, &aligns, 4, 0));
    try std.testing.expectEqual(@as(usize, 32), columnOffset(0, &sizes, &aligns, 4, 1)); // after 8*4
    try std.testing.expectEqual(@as(usize, 36), columnsRegionEnd(0, &sizes, &aligns, 4)); // 32 + 1*4
}
