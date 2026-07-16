//! `.scene.bin` accessor — Tier 0, zero-copy read view over the bytes the
//! `writer.zig` produced. **Reused verbatim by the M1.0.5 runtime loader**,
//! which layers mmap + memcpy-into-chunks + UUID→handle remap + `on_spawned` on
//! top — none of that lives here.
//!
//! No allocation: every getter returns a slice/pointer into the borrowed bytes
//! (or a small value). `open` validates `magic` + `version`. Scalars are read
//! little-endian via `std.mem.readInt` (unaligned-safe — the byte buffer need
//! not be aligned); component column DATA is returned as raw byte slices for the
//! loader to memcpy. Self-describing: column strides/alignments come from the
//! Schema Registry, so no `Registry` is needed to slice archetype columns.
//!
//! Column placement is computed with `format.columnOffset` — the SAME routine
//! the writer used — so reader/writer offsets agree by construction.

const std = @import("std");

const format = @import("format.zig");

const SceneHeader = format.SceneHeader;

/// Max components per archetype the accessor will slice without heap (stack
/// scratch for the shared column-offset computation). Scene archetypes are
/// small; a malformed file exceeding this trips an assert, not silent corruption.
pub const max_components_per_archetype = 256;

/// Zero-copy read view over a `.scene.bin` byte image. Construct with `open`
/// (validates the header); every getter borrows from `bytes` without allocating.
pub const Accessor = struct {
    bytes: []const u8,
    header: SceneHeader,

    /// Validate `magic` + `version` and parse the header. Does not verify the
    /// content `hash` (call `verifyHash` if you want that).
    pub fn open(bytes: []const u8) format.ReadError!Accessor {
        const header = try SceneHeader.read(bytes);
        return .{ .bytes = bytes, .header = header };
    }

    /// Recompute the content hash and compare it to the header's.
    pub fn verifyHash(self: Accessor) bool {
        if (self.bytes.len < format.header_size) return false;
        return std.hash.XxHash64.hash(0, self.bytes[format.header_size..]) == self.header.hash;
    }

    fn readU16(self: Accessor, off: usize) u16 {
        return std.mem.readInt(u16, self.bytes[off..][0..2], .little);
    }
    fn readU32(self: Accessor, off: usize) u32 {
        return std.mem.readInt(u32, self.bytes[off..][0..4], .little);
    }

    // ── String / UUID tables ──

    /// The interned string at `ref` (a string-table-relative byte offset, as
    /// stored in entity/schema/resource references).
    pub fn stringAt(self: Accessor, ref: u32) []const u8 {
        const base = self.header.string_table_offset + ref;
        const len = self.readU32(base);
        return self.bytes[base + 4 ..][0..len];
    }

    /// The 16-byte UUID at ordinal `idx`.
    pub fn uuidAt(self: Accessor, idx: u32) *const [16]u8 {
        const off = self.header.uuid_table_offset + @as(usize, idx) * 16;
        return self.bytes[off..][0..16];
    }

    // ── Schema Registry (§10) ──

    pub const Schema = struct { name: []const u8, size: u16, alignment: u16 };

    pub fn schemaCount(self: Accessor) u32 {
        return self.header.schema_count;
    }

    /// The schema at file-local index `idx` (name + column stride + alignment).
    pub fn schema(self: Accessor, idx: u32) Schema {
        const off = self.header.schema_table_offset + @as(usize, idx) * 8; // 8 = @sizeOf SchemaEntry
        return .{
            .name = self.stringAt(self.readU32(off)),
            .size = self.readU16(off + 4),
            .alignment = self.readU16(off + 6),
        };
    }

    // ── Resources ──

    pub fn resourceCount(self: Accessor) u32 {
        return self.header.resource_count;
    }

    /// A view over resource `idx` (walks the block sequentially — resource
    /// counts are small). Fields: `schema_index`, the POD `data` blob, and the
    /// string-field references.
    pub fn resource(self: Accessor, idx: u32) Resource {
        var off: usize = self.header.resources_offset;
        var i: u32 = 0;
        while (i < idx) : (i += 1) off = self.resourceEnd(off);
        return self.resourceAt(off);
    }

    fn resourceAt(self: Accessor, off: usize) Resource {
        const schema_index = self.readU32(off);
        const data_size = self.readU32(off + 4);
        const data = self.bytes[off + 8 ..][0..data_size];
        const sf_off = off + 8 + data_size;
        const sf_count = self.readU32(sf_off);
        return .{ .acc = self, .schema_index = schema_index, .data = data, .sf_off = sf_off + 4, .sf_count = sf_count };
    }

    fn resourceEnd(self: Accessor, off: usize) usize {
        const r = self.resourceAt(off);
        return r.sf_off + @as(usize, r.sf_count) * 8;
    }

    pub const Resource = struct {
        acc: Accessor,
        schema_index: u32,
        data: []const u8,
        sf_off: usize, // file offset of the first string-field pair
        sf_count: u32,

        /// The materialized string value of the `string_` field at byte `offset`
        /// within `data`, or null if no such field. `data`'s slot itself is zero
        /// (the value lives in the string table — see the writer).
        pub fn stringField(self: Resource, offset: u16) ?[]const u8 {
            var i: u32 = 0;
            while (i < self.sf_count) : (i += 1) {
                const p = self.sf_off + @as(usize, i) * 8;
                if (self.acc.readU32(p) == offset) return self.acc.stringAt(self.acc.readU32(p + 4));
            }
            return null;
        }
    };

    // ── Entity Extensions region (M1.0.6 E5, SHAPE A) ──
    //
    // `@ extensions_offset`, three self-delimiting sub-tables in order:
    //   Entity Extensions Table — `ext_count:u32` then per entity
    //     `{ uuid_ordinal:u32, extension_count:u32, extension_ids:[…]u32 }`
    //   Prefab ID Table — `prefab_id_count:u32` then `[…]u32` string-table offsets
    //   Hooks — `hook_count:u32` then `[…]{ on_attach_ref:u32, on_detach_ref:u32 }`
    //     (string-table offsets; 0 = absent). `hook_count ∈ {0,1}` in M1.0.6.

    /// A view over one Entity Extensions Table entry.
    pub const ExtEntry = struct {
        acc: Accessor,
        uuid_ordinal: u32,
        extension_count: u32,
        ids_off: usize, // file offset of the first `extension_id` u32

        /// The `j`-th active-extension id (an index into the Prefab ID Table).
        pub fn extensionId(self: ExtEntry, j: u32) u32 {
            return self.acc.readU32(self.ids_off + @as(usize, j) * 4);
        }
    };

    pub fn extensionsCount(self: Accessor) u32 {
        return self.readU32(self.header.extensions_offset);
    }

    /// The `i`-th Entity Extensions Table entry (walks variable-length entries).
    pub fn extension(self: Accessor, i: u32) ExtEntry {
        var off: usize = self.header.extensions_offset + 4; // skip ext_count
        var k: u32 = 0;
        while (k < i) : (k += 1) {
            const ecount = self.readU32(off + 4);
            off += 8 + @as(usize, ecount) * 4;
        }
        return .{
            .acc = self,
            .uuid_ordinal = self.readU32(off),
            .extension_count = self.readU32(off + 4),
            .ids_off = off + 8,
        };
    }

    /// File offset of the Prefab ID Table's `prefab_id_count` (past the ext table).
    fn prefabIdTableStart(self: Accessor) usize {
        var off: usize = self.header.extensions_offset + 4;
        const count = self.extensionsCount();
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const ecount = self.readU32(off + 4);
            off += 8 + @as(usize, ecount) * 4;
        }
        return off;
    }

    pub fn prefabIdCount(self: Accessor) u32 {
        return self.readU32(self.prefabIdTableStart());
    }

    /// The `i`-th deduplicated extension-prefab name (Prefab ID Table).
    pub fn prefabName(self: Accessor, i: u32) []const u8 {
        const base = self.prefabIdTableStart() + 4;
        return self.stringAt(self.readU32(base + @as(usize, i) * 4));
    }

    /// File offset of the hooks sub-section's `hook_count` (past the Prefab ID Table).
    fn hooksStart(self: Accessor) usize {
        const pcount = self.prefabIdCount();
        return self.prefabIdTableStart() + 4 + @as(usize, pcount) * 4;
    }

    pub fn hookCount(self: Accessor) u32 {
        return self.readU32(self.hooksStart());
    }

    /// One hooks entry: `on_attach`/`on_detach` rendered Etch text, or null if the
    /// hook is absent (its on-disk string-table ref is 0).
    pub const Hook = struct { on_attach: ?[]const u8, on_detach: ?[]const u8 };

    pub fn hook(self: Accessor, i: u32) Hook {
        const base = self.hooksStart() + 4 + @as(usize, i) * 8;
        const a_ref = self.readU32(base);
        const d_ref = self.readU32(base + 4);
        return .{
            .on_attach = if (a_ref == 0) null else self.stringAt(a_ref),
            .on_detach = if (d_ref == 0) null else self.stringAt(d_ref),
        };
    }

    // ── Cross-references Table (M1.0.6 E4) ──

    /// Number of entity→entity cross-reference entries (`0` for a scene with no
    /// `Entity` field references, and for every M1.0.4/M1.0.5 file).
    pub fn crossrefsCount(self: Accessor) u32 {
        return self.readU32(self.header.crossrefs_offset);
    }

    /// The `i`-th `CrossRefEntry` (16 B each, after the `u32` count prefix).
    pub fn crossref(self: Accessor, i: u32) format.CrossRefEntry {
        const off = self.header.crossrefs_offset + 4 + @as(usize, i) * 16;
        return format.CrossRefEntry.readAt(self.bytes, off);
    }

    // ── Archetypes ──

    pub fn archetypeCount(self: Accessor) u32 {
        return self.readU32(self.header.archetypes_offset);
    }

    /// A view over archetype `idx` (walks blocks sequentially).
    pub fn archetype(self: Accessor, idx: u32) Archetype {
        var off: usize = self.header.archetypes_offset + 4; // skip the count
        var i: u32 = 0;
        while (i < idx) : (i += 1) off = self.archetypeEnd(off);
        return self.archetypeAt(off);
    }

    fn archetypeAt(self: Accessor, block_off: usize) Archetype {
        const component_count = self.readU32(block_off);
        std.debug.assert(component_count <= max_components_per_archetype);
        const schema_indices_off = block_off + 4;
        const entity_count_off = schema_indices_off + @as(usize, component_count) * 4;
        const entity_count = self.readU32(entity_count_off);
        const names_off = entity_count_off + 4;
        const uuids_off = names_off + @as(usize, entity_count) * 4;
        const parents_off = uuids_off + @as(usize, entity_count) * 4;
        const columns_base = parents_off + @as(usize, entity_count) * 4;
        return .{
            .acc = self,
            .component_count = component_count,
            .entity_count = entity_count,
            .schema_indices_off = schema_indices_off,
            .names_off = names_off,
            .uuids_off = uuids_off,
            .parents_off = parents_off,
            .columns_base = columns_base,
        };
    }

    fn archetypeEnd(self: Accessor, block_off: usize) usize {
        const a = self.archetypeAt(block_off);
        return a.columnsEnd();
    }

    pub const Archetype = struct {
        acc: Accessor,
        component_count: u32,
        entity_count: u32,
        schema_indices_off: usize,
        names_off: usize,
        uuids_off: usize,
        parents_off: usize,
        columns_base: usize,

        /// Schema Registry index of the `c`-th component (column order = the
        /// on-disk component mask, sorted ascending by the cook).
        pub fn schemaIndex(self: Archetype, c: usize) u32 {
            return self.acc.readU32(self.schema_indices_off + c * 4);
        }
        /// Entity `slot`'s name.
        pub fn entityName(self: Archetype, slot: usize) []const u8 {
            return self.acc.stringAt(self.acc.readU32(self.names_off + slot * 4));
        }
        /// Entity `slot`'s UUID.
        pub fn entityUuid(self: Archetype, slot: usize) *const [16]u8 {
            return self.acc.uuidAt(self.acc.readU32(self.uuids_off + slot * 4));
        }
        /// Entity `slot`'s own UUID ordinal (unvalidated — callers bound-check
        /// against `uuidCount` before dereferencing via `uuidAt`).
        pub fn entityUuidOrdinal(self: Archetype, slot: usize) u32 {
            return self.acc.readU32(self.uuids_off + slot * 4);
        }
        /// Entity `slot`'s parent UUID ordinal, or `format.no_parent`.
        pub fn entityParent(self: Archetype, slot: usize) u32 {
            return self.acc.readU32(self.parents_off + slot * 4);
        }

        fn columnByteOffset(self: Archetype, c: usize) usize {
            var sizes: [max_components_per_archetype]u16 = undefined;
            var aligns: [max_components_per_archetype]u16 = undefined;
            var i: usize = 0;
            while (i <= c) : (i += 1) {
                const s = self.acc.schema(self.schemaIndex(i));
                sizes[i] = s.size;
                aligns[i] = s.alignment;
            }
            return format.columnOffset(self.columns_base, sizes[0 .. c + 1], aligns[0 .. c + 1], self.entity_count, c);
        }

        /// The full flat SoA column for the `c`-th component (`entity_count *
        /// stride` bytes).
        pub fn column(self: Archetype, c: usize) []const u8 {
            const stride = self.acc.schema(self.schemaIndex(c)).size;
            const start = self.columnByteOffset(c);
            return self.acc.bytes[start..][0 .. @as(usize, stride) * self.entity_count];
        }

        /// Entity `slot`'s bytes for the `c`-th component.
        pub fn componentSlot(self: Archetype, c: usize, slot: usize) []const u8 {
            const stride = self.acc.schema(self.schemaIndex(c)).size;
            return self.column(c)[slot * stride ..][0..stride];
        }

        fn columnsEnd(self: Archetype) usize {
            var sizes: [max_components_per_archetype]u16 = undefined;
            var aligns: [max_components_per_archetype]u16 = undefined;
            var i: usize = 0;
            while (i < self.component_count) : (i += 1) {
                const s = self.acc.schema(self.schemaIndex(i));
                sizes[i] = s.size;
                aligns[i] = s.alignment;
            }
            return format.columnsRegionEnd(self.columns_base, sizes[0..self.component_count], aligns[0..self.component_count], self.entity_count);
        }
    };
};

// ── tests ─────────────────────────────────────────────────────────────────

const registry_mod = @import("../ecs/registry.zig");
const writer = @import("writer.zig");

test "accessor round-trips a hand-built model through the writer" {
    const gpa = std.testing.allocator;

    // A registry with one component: Pos { x: f32, y: f32 } (size 8, align 4).
    var reg = registry_mod.Registry.init();
    defer reg.deinit(gpa);
    const fields = [_]registry_mod.FieldDesc{
        .{ .name = "x", .offset = 0, .kind = .f32_ },
        .{ .name = "y", .offset = 4, .kind = .f32_ },
    };
    const pos = try reg.registerComponentRaw(gpa, .{ .name = "Pos", .size = 8, .alignment = 4, .default_bytes = &[_]u8{0} ** 8, .fields = &fields });

    // Build a tiny CookModel by hand: 1 archetype [Pos], 2 entities.
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{ try a.dupe(u8, "A"), try a.dupe(u8, "B") });
    const uuids = try a.dupe([16]u8, &.{ [_]u8{1} ** 16, [_]u8{2} ** 16 });
    var col = try a.alloc(u8, 8 * 2);
    std.mem.writeInt(u32, col[0..4], @bitCast(@as(f32, 1.5)), .little); // A.x
    std.mem.writeInt(u32, col[4..8], @bitCast(@as(f32, 2.5)), .little); // A.y
    std.mem.writeInt(u32, col[8..12], @bitCast(@as(f32, 9.0)), .little); // B.x
    std.mem.writeInt(u32, col[12..16], @bitCast(@as(f32, 0.0)), .little); // B.y
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent },
        .{ .name = 1, .uuid = 1, .parent_uuid = 0 }, // B's parent = A
    });
    const ids = try a.dupe(format.ComponentId, &.{pos});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{ .component_ids = ids, .entity_count = 2, .columns = cols, .entities = ents }});
    var model: format.CookModel = .{ .strings = names, .uuids = uuids, .resources = &.{}, .archetypes = blocks, .arena = arena };
    defer model.deinit();

    const bytes = try writer.write(gpa, model, &reg);
    defer gpa.free(bytes);

    var acc = try Accessor.open(bytes);
    try std.testing.expect(acc.verifyHash());
    try std.testing.expectEqual(@as(u32, 1), acc.archetypeCount());
    try std.testing.expectEqual(@as(u32, 1), acc.schemaCount());
    try std.testing.expectEqualStrings("Pos", acc.schema(0).name);

    const arch = acc.archetype(0);
    try std.testing.expectEqual(@as(u32, 2), arch.entity_count);
    try std.testing.expectEqualStrings("A", arch.entityName(0));
    try std.testing.expectEqualStrings("B", arch.entityName(1));
    try std.testing.expectEqual(format.no_parent, arch.entityParent(0));
    try std.testing.expectEqual(@as(u8, 1), arch.entityUuid(0)[0]);
    // B's parent ordinal resolves to A's uuid.
    try std.testing.expectEqual(@as(u8, 1), arch.acc.uuidAt(arch.entityParent(1))[0]);

    // Decode A.x and B.x from the column.
    const ax: f32 = @bitCast(std.mem.readInt(u32, arch.componentSlot(0, 0)[0..4], .little));
    const bx: f32 = @bitCast(std.mem.readInt(u32, arch.componentSlot(0, 1)[0..4], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), ax, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), bx, 1e-6);
}
