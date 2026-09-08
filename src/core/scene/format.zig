//! `.scene.bin` format — the contract shared VERBATIM with the runtime loader, plus
//! the neutral cook model.
//!
//! THE SoA LAYOUT IS AN AGREEMENT WITH THE LOADER, which slices each column at an
//! entity's rank: column order is ascending component order, stride is
//! `componentSize`, each column start is aligned to `componentAlignment`. Break any
//! of the three and the slice lands on the wrong bytes.
//!
//! ON-DISK COMPONENT IDENTITY IS A FILE-LOCAL SCHEMA INDEX, never a runtime
//! `ComponentId`, which is stable across neither runs nor processes.

const std = @import("std");

const registry_mod = @import("../ecs/registry.zig");

/// Re-exported so the cook model and the loader name components identically.
pub const ComponentId = registry_mod.ComponentId;
/// Re-exported; the writer and accessor dispatch on it.
pub const FieldKind = registry_mod.FieldKind;

/// File magic at offset 0. A `[4]u8` and not a `u32`, so the on-disk bytes are
/// endianness-independent.
pub const magic = [4]u8{ 'W', 'S', 'C', 'N' };

/// The CODEC version, distinct from `content_version` (the authored scene's own).
///
/// A file of an older version fails `BadVersion` and must be re-cooked — these are
/// deterministic build artifacts, so there is nothing to migrate.
pub const format_version: u16 = 2;

/// Fixed 64-byte prefix, one cache line.
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

/// `.scene.bin` header — 64 bytes, the prefix of every file.
///
/// Read and written FIELD BY FIELD little-endian, never `@ptrCast` off an arbitrary
/// buffer: that is what makes it unaligned-safe as well as endianness-defined.
/// `hash` covers the content AFTER the header.
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
    extensions_offset: u32 = 0, // @44
    crossrefs_offset: u32 = 0, // @48
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

    /// Parse and validate a header from the front of `bytes`.
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

/// On-disk Schema Registry entry (`engine-ecs-internals.md` §10).
pub const SchemaEntry = extern struct {
    /// String-table byte offset of the component's name.
    name_ref: u32,
    /// `Registry.componentSize` — the SoA column stride.
    size: u16,
    /// `Registry.componentAlignment` — the SoA column start alignment.
    alignment: u16,
};

/// On-disk Cross-references Table entry — one per bearing entity field.
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

    /// Read a `CrossRefEntry` little-endian at `off`.
    pub fn readAt(bytes: []const u8, off: usize) CrossRefEntry {
        return .{
            .source_uuid_ordinal = std.mem.readInt(u32, bytes[off..][0..4], .little),
            .schema_index = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little),
            .field_offset = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little),
            .target_uuid_ordinal = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .little),
        };
    }
};

/// Byte offset of column `i` relative to the column region start, alignment included.
pub fn columnOffset(region_start: usize, sizes: []const u16, aligns: []const u16, entity_count: u32, i: usize) usize {
    var off = region_start;
    var c: usize = 0;
    while (c < i) : (c += 1) {
        off = std.mem.alignForward(usize, off, aligns[c]);
        off += @as(usize, sizes[c]) * entity_count;
    }
    return std.mem.alignForward(usize, off, aligns[i]);
}

/// End offset of the whole column region.
pub fn columnsRegionEnd(region_start: usize, sizes: []const u16, aligns: []const u16, entity_count: u32) usize {
    var off = region_start;
    for (sizes, aligns) |sz, al| {
        off = std.mem.alignForward(usize, off, al);
        off += @as(usize, sz) * entity_count;
    }
    return off;
}

/// `parent_uuid` sentinel: the entity has no parent (root entity).
pub const no_parent: u32 = std.math.maxInt(u32);

/// One resource `string_` field: its slot offset and the string to intern.
pub const StringFieldRef = struct {
    /// Byte offset of the `string_` slot within `ResourceEntry.data`.
    offset: u16,
    /// Index into `CookModel.strings` — the field's resolved UTF-8 value.
    str: u32,
};

/// One serialized resource — its POD image plus its string fields.
pub const ResourceEntry = struct {
    schema_id: ComponentId,
    data: []u8,
    string_fields: []StringFieldRef,
};

/// Per-entity identity carried alongside its archetype's columns.
pub const EntityEntry = struct {
    /// Index into `CookModel.strings` — the entity's name.
    name: u32,
    /// Index into `CookModel.uuids` — the entity's 16-byte UUID.
    uuid: u32,
    /// Index into `CookModel.uuids` — the parent entity's UUID, or `no_parent`.
    parent_uuid: u32,
};

/// One archetype block: every entity sharing the same sorted component set.
pub const ArchetypeBlock = struct {
    /// Component ids, SORTED ASCENDING — the column order depends on it.
    component_ids: []ComponentId,
    entity_count: u32,
    /// One column per `component_ids` entry, in the same order.
    columns: [][]u8,
    /// Per-entity identity, `len == entity_count`, slot order matches `columns`.
    entities: []EntityEntry,
};

/// One entity-to-entity cross-reference in the neutral cook model.
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

/// One entity's active extensions in the neutral model.
pub const ExtModelEntry = struct {
    uuid: u32,
    prefab_ids: []const u32,
};

/// An `extends` prefab's hooks in the neutral model.
pub const HookSet = struct {
    on_attach: ?u32,
    on_detach: ?u32,
};

/// The neutral, World-free model the cook produces; owns every slice below.
pub const CookModel = struct {
    /// Deduplicated UTF-8 strings: entity names + resource `string_` values.
    strings: [][]const u8,
    /// 16-byte UUIDs: entity UUIDs (indexed by `EntityEntry.uuid`/`parent_uuid`).
    uuids: [][16]u8,
    resources: []ResourceEntry,
    archetypes: []ArchetypeBlock,
    /// Entity-to-entity cross-references; empty when the scene has none.
    cross_refs: []const CrossRef = &.{},
    /// Active-extension entries, one per entity carrying any.
    ext_entries: []const ExtModelEntry = &.{},
    /// Deduplicated extension-prefab names, as string refs.
    prefab_id_table: []const u32 = &.{},
    /// `extends` prefab hooks.
    hooks: []const HookSet = &.{},
    /// The authored scene's own `version:` field, opaque to the codec.
    content_version: u16 = 0,

    /// Backing arena for every slice above.
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
