//! `.scene.bin` structural validator — Tier 0 (M1.1.1-HF3 / R1).
//!
//! A standalone structural pre-flight that walks the raw `.scene.bin` bytes
//! **directly** and **never calls an `accessor.zig` getter**. It is the front
//! door for trusting an externally-supplied scene image: `loader.openVerified`
//! runs header → content hash → `validate.structure` → return `Accessor`. Every
//! accessor getter trusts file-controlled offsets and counts (`stringAt` does an
//! unbounded `ref + 4 + len`, `schema` an unchecked index, `archetypeAt` hides a
//! `debug.assert` stripped in ReleaseFast, `column` an unchecked
//! `stride × entity_count`); this validator proves those trusts hold *before*
//! any getter runs, so a hash-valid but malformed image can never drive a getter
//! out of bounds.
//!
//! `verifyHash` is **not** a substitute: `XxHash64` is trivially recomputed by an
//! attacker who rewrites the bytes, so a matching hash says nothing about
//! structural validity.
//!
//! **Checked arithmetic everywhere.** Every offset/size derived from a
//! file-controlled quantity goes through `std.math.add`/`std.math.mul` (mapped to
//! `error.MalformedScene`) — never a bare `+`/`*`, including quantities that
//! "cannot" overflow on 64-bit. Every read goes through the bounds-checked
//! `readU32`/`readU16` helpers, so even a gap in the structural bound checks
//! surfaces as `error.MalformedScene`, never an out-of-bounds panic.
//!
//! Section order validated (matches `writer.zig` / `engine-scene-serialization.md`
//! §4): `header ≤ string ≤ uuid ≤ schema ≤ resources ≤ archetypes ≤ extensions
//! ≤ crossrefs ≤ bytes.len`.

const std = @import("std");

const format = @import("format.zig");
const accessor_mod = @import("accessor.zig");

const SceneHeader = format.SceneHeader;

/// Size of an on-disk `Entity` field slot (a `packed struct(u64)` `EntityId`),
/// the width a cross-reference patches at load. Named to mirror the loader's
/// `@sizeOf(EntityId)` bound without importing `world.zig` into this leaf.
const entity_ref_size: usize = 8;

/// Raised when the byte image opens and hashes valid but its internal structure
/// is inconsistent — an offset, count, or reference an accessor getter would
/// trust that does not hold. Structurally identical to (and unifies with) the
/// loader's `StructureError`; both carry the single `error.MalformedScene`.
/// Distinct from `error.CorruptScene` (a content-hash mismatch).
pub const StructureError = error{MalformedScene};

/// Checked `a + b`; overflow → `error.MalformedScene`.
fn add(a: usize, b: usize) StructureError!usize {
    return std.math.add(usize, a, b) catch error.MalformedScene;
}

/// Checked `a * b`; overflow → `error.MalformedScene`.
fn mul(a: usize, b: usize) StructureError!usize {
    return std.math.mul(usize, a, b) catch error.MalformedScene;
}

/// Read a little-endian `u32` at `off`, bounds-checked against `bytes.len` —
/// the ONLY 4-byte read path in this file (no raw slice indexing).
fn readU32(bytes: []const u8, off: usize) StructureError!u32 {
    const end = try add(off, 4);
    if (end > bytes.len) return error.MalformedScene;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Read a little-endian `u16` at `off`, bounds-checked against `bytes.len`.
fn readU16(bytes: []const u8, off: usize) StructureError!u16 {
    const end = try add(off, 2);
    if (end > bytes.len) return error.MalformedScene;
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

/// `alignForward(off, alignment)` computed with checked arithmetic. `alignment`
/// MUST be a validated power of two ≥ 1 (see the schema-table check) — this backs
/// `format.columnOffset`'s `std.mem.alignForward`, which asserts the same.
fn alignForwardChecked(off: usize, alignment: u16) StructureError!usize {
    std.debug.assert(alignment != 0 and std.math.isPowerOfTwo(alignment));
    const a: usize = alignment;
    const bumped = try add(off, a - 1);
    return bumped & ~(a - 1);
}

/// Structural validation state for one byte image. Built by `structure`, walked
/// by `run`. All fields except `bytes`/`h` are derived by check (a)/(b)/(c).
const Validator = struct {
    bytes: []const u8,
    h: SceneHeader,
    /// End of the string table (= `uuid_table_offset`); set by check (a).
    string_table_end: usize = 0,
    /// `(schema_table_offset - uuid_table_offset) / 16`; set by check (b). The
    /// same formula `loader.uuidCount` uses — validated exact here.
    uuid_count: usize = 0,

    /// Validate that `ref` addresses a length-prefixed string wholly inside the
    /// string table `[string_table_offset, string_table_end)`.
    fn checkStringRef(self: *const Validator, ref: u32) StructureError!void {
        const base = try add(self.h.string_table_offset, ref);
        const len_field_end = try add(base, 4);
        if (len_field_end > self.string_table_end) return error.MalformedScene;
        // Safe: len_field_end ≤ string_table_end ≤ uuid_table_offset ≤ bytes.len.
        const slen = try readU32(self.bytes, base);
        const data_end = try add(len_field_end, slen);
        if (data_end > self.string_table_end) return error.MalformedScene;
    }

    /// The on-disk `size` of schema `idx` (caller guarantees `idx < schema_count`
    /// and that check (c) verified the table fits). Reads `SchemaEntry.size` @ +4.
    fn schemaSize(self: *const Validator, idx: u32) StructureError!u16 {
        const base = try add(self.h.schema_table_offset, try mul(idx, 8));
        return readU16(self.bytes, try add(base, 4));
    }

    /// The on-disk `alignment` of schema `idx` (validated power-of-two in check
    /// (c)). Reads `SchemaEntry.alignment` @ +6.
    fn schemaAlign(self: *const Validator, idx: u32) StructureError!u16 {
        const base = try add(self.h.schema_table_offset, try mul(idx, 8));
        return readU16(self.bytes, try add(base, 6));
    }

    fn run(self: *Validator) StructureError!void {
        const h = self.h;
        const total = self.bytes.len;

        // (a) Section offsets: monotonic and within bytes.len.
        const st: usize = h.string_table_offset;
        const ut: usize = h.uuid_table_offset;
        const sc: usize = h.schema_table_offset;
        const rs: usize = h.resources_offset;
        const ar: usize = h.archetypes_offset;
        const ex: usize = h.extensions_offset;
        const cr: usize = h.crossrefs_offset;
        if (st < format.header_size) return error.MalformedScene;
        if (ut < st) return error.MalformedScene;
        if (sc < ut) return error.MalformedScene;
        if (rs < sc) return error.MalformedScene;
        if (ar < rs) return error.MalformedScene;
        if (ex < ar) return error.MalformedScene;
        if (cr < ex) return error.MalformedScene;
        if (cr > total) return error.MalformedScene;

        // (b) UUID table span `[uuid, schema)` is 16-divisible → uuid_count.
        const uuid_span = sc - ut; // ≥ 0 from (a)
        if (uuid_span % 16 != 0) return error.MalformedScene;
        self.uuid_count = uuid_span / 16;
        self.string_table_end = ut;

        // (c) Schema table: `schema_count × 8` fits within `[schema, resources)`;
        //     each entry's name_ref is a valid string ref and its alignment is a
        //     power of two ≥ 1 (backs `format.columnOffset`'s `alignForward`).
        const schema_count: usize = h.schema_count;
        const schema_bytes = try mul(schema_count, 8);
        const schema_end = try add(sc, schema_bytes);
        if (schema_end > rs) return error.MalformedScene;
        {
            var i: usize = 0;
            while (i < schema_count) : (i += 1) {
                const base = try add(sc, try mul(i, 8));
                try self.checkStringRef(try readU32(self.bytes, base));
                const alignment = try readU16(self.bytes, try add(base, 6));
                if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.MalformedScene;
            }
        }

        // (d) Resources: exactly `resource_count` sequential blocks within
        //     `[resources, archetypes)`; schema_index < schema_count; every
        //     string-field ref valid.
        {
            var off = rs;
            var i: usize = 0;
            while (i < @as(usize, h.resource_count)) : (i += 1) {
                if (try add(off, 8) > ar) return error.MalformedScene;
                const schema_index = try readU32(self.bytes, off);
                if (schema_index >= h.schema_count) return error.MalformedScene;
                const data_size = try readU32(self.bytes, try add(off, 4));
                // R10(a): the resource blob must be EXACTLY the component size — the
                // loader memcpys `data_size` bytes into a `componentSize`-byte slot
                // behind a `debug.assert` stripped in ReleaseFast, so a mismatch is
                // an out-of-bounds write there.
                if (data_size != @as(u32, try self.schemaSize(schema_index))) return error.MalformedScene;
                const data_end = try add(try add(off, 8), data_size);
                const sf_count_end = try add(data_end, 4);
                if (sf_count_end > ar) return error.MalformedScene;
                const sf_count = try readU32(self.bytes, data_end);
                const sf_bytes = try mul(sf_count, 8);
                const block_end = try add(sf_count_end, sf_bytes);
                if (block_end > ar) return error.MalformedScene;
                var s: usize = 0;
                while (s < sf_count) : (s += 1) {
                    const pair = try add(sf_count_end, try mul(s, 8));
                    // R10(b): the string-field offset is only a loader lookup key,
                    // but bound it inside the blob anyway (defense in depth).
                    const field_off = try readU32(self.bytes, pair);
                    if (try add(field_off, 4) > data_size) return error.MalformedScene;
                    try self.checkStringRef(try readU32(self.bytes, try add(pair, 4)));
                }
                off = block_end;
            }
        }

        // (e) Archetypes: `[count u32]` then blocks within `[archetypes, extensions)`.
        {
            if (try add(ar, 4) > ex) return error.MalformedScene;
            const arch_count = try readU32(self.bytes, ar);
            var off = try add(ar, 4);
            var a_i: usize = 0;
            while (a_i < arch_count) : (a_i += 1) {
                if (try add(off, 4) > ex) return error.MalformedScene;
                const cc = try readU32(self.bytes, off);
                if (cc > accessor_mod.max_components_per_archetype) return error.MalformedScene;
                const sidx_off = try add(off, 4);
                const ec_off = try add(sidx_off, try mul(cc, 4));
                if (try add(ec_off, 4) > ex) return error.MalformedScene;
                // Schema indices in range AND strictly increasing (R11(a)): the
                // on-disk schema mask is normatively "sorted ascending"
                // (`engine-scene-serialization.md` §4), so strict monotonicity also
                // rules out a duplicate ComponentId hiding in one archetype.
                // Extension prefabs run the same `openVerified` → `structure`, so
                // this covers their archetype blocks too.
                {
                    var c: usize = 0;
                    var prev_si: ?u32 = null;
                    while (c < cc) : (c += 1) {
                        const si = try readU32(self.bytes, try add(sidx_off, try mul(c, 4)));
                        if (si >= h.schema_count) return error.MalformedScene;
                        if (prev_si) |p| {
                            if (si <= p) return error.MalformedScene;
                        }
                        prev_si = si;
                    }
                }
                const entity_count = try readU32(self.bytes, ec_off);
                const names_off = try add(ec_off, 4);
                const ec_bytes = try mul(entity_count, 4);
                const uuids_off = try add(names_off, ec_bytes);
                const parents_off = try add(uuids_off, ec_bytes);
                const columns_base = try add(parents_off, ec_bytes);
                if (columns_base > ex) return error.MalformedScene;
                // Per-entity name refs / uuid ordinals / parent ordinals.
                {
                    var s: usize = 0;
                    while (s < entity_count) : (s += 1) {
                        try self.checkStringRef(try readU32(self.bytes, try add(names_off, try mul(s, 4))));
                        const uuid_ord = try readU32(self.bytes, try add(uuids_off, try mul(s, 4)));
                        if (@as(usize, uuid_ord) >= self.uuid_count) return error.MalformedScene;
                        const parent = try readU32(self.bytes, try add(parents_off, try mul(s, 4)));
                        if (parent != format.no_parent and @as(usize, parent) >= self.uuid_count) return error.MalformedScene;
                    }
                }
                // SoA columns: each start aligned to the component alignment, the
                // region ending within `[.., extensions)`. Mirrors
                // `format.columnsRegionEnd` with checked arithmetic.
                var col_off = columns_base;
                {
                    var c: usize = 0;
                    while (c < cc) : (c += 1) {
                        const si = try readU32(self.bytes, try add(sidx_off, try mul(c, 4)));
                        col_off = try alignForwardChecked(col_off, try self.schemaAlign(si));
                        col_off = try add(col_off, try mul(try self.schemaSize(si), entity_count));
                    }
                }
                if (col_off > ex) return error.MalformedScene;
                off = col_off;
            }
        }

        // (f) Extensions region within `[extensions, crossrefs)` (SHAPE A): the
        //     Entity Extensions Table, the Prefab ID Table, the hooks. Two
        //     sub-passes — per-entity extension ids need the prefab-id count,
        //     which follows the entity table on the wire.
        const prefab_id_count = try self.validateExtensionsRegion(ex, cr);
        try self.validateExtensionIds(ex, prefab_id_count);

        // (g) Cross-references within `[crossrefs, bytes.len)`: `[count u32]` then
        //     `count × 16 B`. Ordinals < uuid_count; schema_index < schema_count;
        //     `field_offset + 8 ≤` that schema's size (an Entity slot is 8 B).
        {
            if (try add(cr, 4) > total) return error.MalformedScene;
            const count = try readU32(self.bytes, cr);
            const entries_off = try add(cr, 4);
            const entries_end = try add(entries_off, try mul(count, 16));
            if (entries_end > total) return error.MalformedScene;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const base = try add(entries_off, try mul(i, 16));
                const src = try readU32(self.bytes, base);
                const schema_index = try readU32(self.bytes, try add(base, 4));
                const field_offset = try readU32(self.bytes, try add(base, 8));
                const tgt = try readU32(self.bytes, try add(base, 12));
                if (@as(usize, src) >= self.uuid_count) return error.MalformedScene;
                if (@as(usize, tgt) >= self.uuid_count) return error.MalformedScene;
                if (schema_index >= h.schema_count) return error.MalformedScene;
                const size = try self.schemaSize(schema_index);
                if (try add(field_offset, entity_ref_size) > @as(usize, size)) return error.MalformedScene;
            }
        }
    }

    /// Walk the Entity Extensions Table + Prefab ID Table + hooks within
    /// `[ex, cr)`, validating every span and every string ref (prefab names,
    /// hook text). Returns `prefab_id_count` for the per-entity id check.
    fn validateExtensionsRegion(self: *const Validator, ex: usize, cr: usize) StructureError!u32 {
        // Entity Extensions Table.
        if (try add(ex, 4) > cr) return error.MalformedScene;
        const ext_count = try readU32(self.bytes, ex);
        var off = try add(ex, 4);
        var i: usize = 0;
        while (i < ext_count) : (i += 1) {
            if (try add(off, 8) > cr) return error.MalformedScene; // uuid_ordinal + extension_count
            const ecount = try readU32(self.bytes, try add(off, 4));
            off = try add(try add(off, 8), try mul(ecount, 4));
            if (off > cr) return error.MalformedScene;
        }
        // Prefab ID Table (dedup'd extension names as string-table refs).
        if (try add(off, 4) > cr) return error.MalformedScene;
        const pid_count = try readU32(self.bytes, off);
        const pids_off = try add(off, 4);
        const pids_end = try add(pids_off, try mul(pid_count, 4));
        if (pids_end > cr) return error.MalformedScene;
        {
            var p: usize = 0;
            while (p < pid_count) : (p += 1) {
                try self.checkStringRef(try readU32(self.bytes, try add(pids_off, try mul(p, 4))));
            }
        }
        // Hooks (`hook_count ∈ {0,1}` today; refs are string-table offsets, 0 = absent).
        if (try add(pids_end, 4) > cr) return error.MalformedScene;
        const hook_count = try readU32(self.bytes, pids_end);
        const hooks_off = try add(pids_end, 4);
        const hooks_end = try add(hooks_off, try mul(hook_count, 8));
        if (hooks_end > cr) return error.MalformedScene;
        {
            var hk: usize = 0;
            while (hk < hook_count) : (hk += 1) {
                const base = try add(hooks_off, try mul(hk, 8));
                const a_ref = try readU32(self.bytes, base);
                const d_ref = try readU32(self.bytes, try add(base, 4));
                if (a_ref != 0) try self.checkStringRef(a_ref);
                if (d_ref != 0) try self.checkStringRef(d_ref);
            }
        }
        return pid_count;
    }

    /// Second sub-pass over the Entity Extensions Table: every per-entity
    /// extension id indexes the Prefab ID Table (`id < prefab_id_count`). The
    /// table spans validated in `validateExtensionsRegion` are re-derived here
    /// (identical bytes) so this stays allocation-free.
    fn validateExtensionIds(self: *const Validator, ex: usize, prefab_id_count: u32) StructureError!void {
        const ext_count = try readU32(self.bytes, ex);
        var off = try add(ex, 4);
        var i: usize = 0;
        while (i < ext_count) : (i += 1) {
            const ecount = try readU32(self.bytes, try add(off, 4));
            const ids_start = try add(off, 8);
            var j: usize = 0;
            while (j < ecount) : (j += 1) {
                const id = try readU32(self.bytes, try add(ids_start, try mul(j, 4)));
                if (id >= prefab_id_count) return error.MalformedScene;
            }
            off = try add(ids_start, try mul(ecount, 4));
        }
    }
};

/// Structurally validate a `.scene.bin` byte image whose header has already been
/// parsed (`SceneHeader.read` — magic/version checked) and whose content hash has
/// been verified. Walks the raw bytes; returns `error.MalformedScene` on any
/// inconsistency, `void` on success. Never calls an accessor getter, never
/// panics on adversarial input (all reads bounds-checked, all arithmetic checked).
pub fn structure(bytes: []const u8, header: SceneHeader) StructureError!void {
    var v: Validator = .{ .bytes = bytes, .h = header };
    try v.run();
}

// ── tests ─────────────────────────────────────────────────────────────────

const registry_mod = @import("../ecs/registry.zig");
const writer = @import("writer.zig");
const Registry = registry_mod.Registry;
const testing = std.testing;

/// Register a bare POD component of `size`/`alignment` (no field descriptors —
/// the validator reads only the schema table's size/alignment). Mirror of the
/// loader test's `registerRaw`.
fn registerPod(gpa: std.mem.Allocator, reg: *Registry, name: []const u8, size: u16, alignment: u16) !registry_mod.ComponentId {
    const default_bytes = try gpa.alloc(u8, size);
    defer gpa.free(default_bytes);
    @memset(default_bytes, 0);
    return reg.registerComponentRaw(gpa, .{ .name = name, .size = size, .alignment = alignment, .default_bytes = default_bytes, .fields = &.{} });
}

/// Build a rich `.scene.bin` exercising every section: two archetypes
/// (`[Pos]` ×2 entities and `[Pos, Link]` ×1), a `string_` resource, one
/// entity→entity cross-reference (via `Link`), and one active extension with a
/// prefab-id table. Caller owns the returned bytes and the registry (`reg`).
fn buildRichScene(gpa: std.mem.Allocator, reg: *Registry) ![]u8 {
    const pos = try registerPod(gpa, reg, "Pos", 8, 4); // id 0
    _ = try registerPod(gpa, reg, "Tag", 4, 4); // id 1 (unreferenced)
    // Link: one `.entity_` field at offset 0 (size 8, align 8).
    const link = blk: {
        const default_bytes = [_]u8{0} ** 8;
        const fields = [_]registry_mod.FieldDesc{.{ .name = "target", .offset = 0, .kind = .entity_ }};
        break :blk try reg.registerComponentRaw(gpa, .{ .name = "Link", .size = 8, .alignment = 8, .default_bytes = &default_bytes, .fields = &fields });
    }; // id 2
    // Settings resource: one `.string_` field at offset 0 (size 16, align 8).
    const settings = blk: {
        const default_bytes = [_]u8{0} ** 16;
        const fields = [_]registry_mod.FieldDesc{.{ .name = "title", .offset = 0, .kind = .string_ }};
        break :blk try reg.registerComponentRaw(gpa, .{ .name = "Settings", .size = 16, .alignment = 8, .default_bytes = &default_bytes, .fields = &fields });
    }; // id 3

    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    const strings = try a.dupe([]const u8, &.{
        try a.dupe(u8, "E0"), // 0
        try a.dupe(u8, "E1"), // 1
        try a.dupe(u8, "E2"), // 2
        try a.dupe(u8, "hello"), // 3 — resource string value
        try a.dupe(u8, "CombatModule"), // 4 — extension prefab name
    });
    const uuids = try a.dupe([16]u8, &.{ [_]u8{1} ** 16, [_]u8{2} ** 16, [_]u8{3} ** 16 });

    // Block A: [Pos], 2 entities.
    const col_a = try a.alloc(u8, 8 * 2);
    @memset(col_a, 0);
    const ids_a = try a.dupe(format.ComponentId, &.{pos});
    const cols_a = try a.dupe([]u8, &.{col_a});
    const ents_a = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent },
        .{ .name = 1, .uuid = 1, .parent_uuid = format.no_parent },
    });
    // Block B: [Pos, Link], 1 entity. Link column = EntityId.dead (0xFF×8).
    const col_b_pos = try a.alloc(u8, 8);
    @memset(col_b_pos, 0);
    const col_b_link = try a.alloc(u8, 8);
    @memset(col_b_link, 0xFF);
    const ids_b = try a.dupe(format.ComponentId, &.{ pos, link });
    const cols_b = try a.dupe([]u8, &.{ col_b_pos, col_b_link });
    const ents_b = try a.dupe(format.EntityEntry, &.{
        .{ .name = 2, .uuid = 2, .parent_uuid = format.no_parent },
    });
    const blocks = try a.dupe(format.ArchetypeBlock, &.{
        .{ .component_ids = ids_a, .entity_count = 2, .columns = cols_a, .entities = ents_a },
        .{ .component_ids = ids_b, .entity_count = 1, .columns = cols_b, .entities = ents_b },
    });

    const res_data = try a.alloc(u8, 16);
    @memset(res_data, 0);
    const res_sf = try a.dupe(format.StringFieldRef, &.{.{ .offset = 0, .str = 3 }});
    const resources = try a.dupe(format.ResourceEntry, &.{
        .{ .schema_id = settings, .data = res_data, .string_fields = res_sf },
    });

    const cross_refs = try a.dupe(format.CrossRef, &.{
        .{ .source_uuid = 2, .component_id = link, .field_offset = 0, .target_uuid = 0 },
    });
    const ext_prefab_ids = try a.dupe(u32, &.{0});
    const ext_entries = try a.dupe(format.ExtModelEntry, &.{
        .{ .uuid = 0, .prefab_ids = ext_prefab_ids },
    });
    const prefab_id_table = try a.dupe(u32, &.{4}); // strings[4] = "CombatModule"

    var model: format.CookModel = .{
        .strings = strings,
        .uuids = uuids,
        .resources = resources,
        .archetypes = blocks,
        .cross_refs = cross_refs,
        .ext_entries = ext_entries,
        .prefab_id_table = prefab_id_table,
        .content_version = 1,
        .arena = arena,
    };
    defer model.deinit();
    return writer.write(gpa, model, reg);
}

/// Recompute the content hash over `bytes[64..]` and write it into the header so
/// `Accessor.verifyHash` passes — used after a body/header mutation.
fn refixHash(bytes: []u8) void {
    const h = std.hash.XxHash64.hash(0, bytes[format.header_size..]);
    std.mem.writeInt(u64, bytes[56..64], h, .little);
}

/// Test-only: read the first and last byte of `slice` (nothing if empty) through
/// `doNotOptimizeAway`, so a slice the accessor built out of bounds panics here
/// under Debug/ReleaseSafe instead of being optimized away.
fn touch(slice: []const u8) void {
    if (slice.len == 0) return;
    std.mem.doNotOptimizeAway(slice[0]);
    std.mem.doNotOptimizeAway(slice[slice.len - 1]);
}

/// Test-only: traverse EVERY accessor getter over a validated image, asserting
/// nothing but the absence of a panic. This is what proves the gate's real
/// property — an image that *survives* `structure` can never drive a getter out
/// of bounds. Called on the seeded-mutation survivors and on the nominal scenes
/// alike; under Debug/ReleaseSafe the safety checks are live, so any out-of-bounds
/// slice or index panics here.
fn walkAll(acc: accessor_mod.Accessor) void {
    // Schemas: name (via stringAt), size, alignment.
    var si: u32 = 0;
    while (si < acc.schemaCount()) : (si += 1) {
        const s = acc.schema(si);
        touch(s.name);
        std.mem.doNotOptimizeAway(s.size);
        std.mem.doNotOptimizeAway(s.alignment);
    }
    // Resources: block walk, `.data`, and a few `stringField` offsets.
    var ri: u32 = 0;
    while (ri < acc.resourceCount()) : (ri += 1) {
        const r = acc.resource(ri);
        std.mem.doNotOptimizeAway(r.schema_index);
        touch(r.data);
        for ([_]u16{ 0, 4, 0xFFFF }) |off| {
            if (r.stringField(off)) |v| touch(v);
        }
    }
    // Archetypes: schema indices, per-entity meta, and every column / slot.
    var ai: u32 = 0;
    while (ai < acc.archetypeCount()) : (ai += 1) {
        const block = acc.archetype(ai);
        var c: usize = 0;
        while (c < block.component_count) : (c += 1) {
            std.mem.doNotOptimizeAway(block.schemaIndex(c));
            touch(block.column(c));
        }
        var slot: usize = 0;
        while (slot < block.entity_count) : (slot += 1) {
            touch(block.entityName(slot));
            const u = block.entityUuid(slot);
            std.mem.doNotOptimizeAway(u[0]);
            std.mem.doNotOptimizeAway(u[15]);
            std.mem.doNotOptimizeAway(block.entityParent(slot));
            var cc: usize = 0;
            while (cc < block.component_count) : (cc += 1) {
                touch(block.componentSlot(cc, slot));
            }
        }
    }
    // Extensions: entries + ids, prefab names, hooks.
    var ei: u32 = 0;
    while (ei < acc.extensionsCount()) : (ei += 1) {
        const e = acc.extension(ei);
        std.mem.doNotOptimizeAway(e.uuid_ordinal);
        var j: u32 = 0;
        while (j < e.extension_count) : (j += 1) std.mem.doNotOptimizeAway(e.extensionId(j));
    }
    var pi: u32 = 0;
    while (pi < acc.prefabIdCount()) : (pi += 1) touch(acc.prefabName(pi));
    var hi: u32 = 0;
    while (hi < acc.hookCount()) : (hi += 1) {
        const h = acc.hook(hi);
        if (h.on_attach) |v| touch(v);
        if (h.on_detach) |v| touch(v);
    }
    // Cross-references.
    var xi: u32 = 0;
    while (xi < acc.crossrefsCount()) : (xi += 1) {
        const cr = acc.crossref(xi);
        std.mem.doNotOptimizeAway(cr.source_uuid_ordinal);
        std.mem.doNotOptimizeAway(cr.schema_index);
        std.mem.doNotOptimizeAway(cr.field_offset);
        std.mem.doNotOptimizeAway(cr.target_uuid_ordinal);
    }
}

/// Open + verify + validate, mirroring `loader.openVerified` without importing it
/// (avoids the loader→validate import cycle). On success, `walkAll` exercises
/// every accessor getter over the validated image — so a validator gap that let
/// an invalid geometry through would surface as an out-of-bounds panic in a getter,
/// not slip by unseen. Returns whatever error the pipeline raises; the point of
/// the callers is that neither the validation nor the subsequent walk ever panics.
fn openAndValidate(bytes: []const u8) !void {
    const acc = try accessor_mod.Accessor.open(bytes);
    if (!acc.verifyHash()) return error.CorruptScene;
    try structure(bytes, acc.header);
    walkAll(acc);
}

test "validator accepts every cooked scene the writer produces" {
    const gpa = testing.allocator;

    // Rich scene: multi-archetype + resource + crossref + extension.
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const bytes = try buildRichScene(gpa, &reg);
    defer gpa.free(bytes);
    const acc = try accessor_mod.Accessor.open(bytes);
    try testing.expect(acc.verifyHash());
    try structure(bytes, acc.header);
    walkAll(acc); // nominal-path getter coverage (parity with the seeded survivors)

    // Minimal scene: one component, one entity, no resources/crossrefs/exts.
    var reg2 = Registry.init();
    defer reg2.deinit(gpa);
    const min_bytes = try buildMinimalScene(gpa, &reg2);
    defer gpa.free(min_bytes);
    const acc2 = try accessor_mod.Accessor.open(min_bytes);
    try structure(min_bytes, acc2.header);
    walkAll(acc2);
}

/// One archetype `[Pos]`, one entity — the smallest non-empty scene.
fn buildMinimalScene(gpa: std.mem.Allocator, reg: *Registry) ![]u8 {
    const pos = try registerPod(gpa, reg, "Pos", 8, 4);
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const strings = try a.dupe([]const u8, &.{try a.dupe(u8, "E0")});
    const uuids = try a.dupe([16]u8, &.{[_]u8{7} ** 16});
    const col = try a.alloc(u8, 8);
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ids = try a.dupe(format.ComponentId, &.{pos});
    const ents = try a.dupe(format.EntityEntry, &.{.{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent }});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{ .component_ids = ids, .entity_count = 1, .columns = cols, .entities = ents }});
    var model: format.CookModel = .{ .strings = strings, .uuids = uuids, .resources = &.{}, .archetypes = blocks, .arena = arena };
    defer model.deinit();
    return writer.write(gpa, model, reg);
}

test "validator rejects out-of-order and out-of-bounds section offsets" {
    const gpa = testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const base = try buildRichScene(gpa, &reg);
    defer gpa.free(base);

    // Header offset fields (little-endian): string@24, uuid@28, schema@32,
    // resources@36, archetypes@40, extensions@44, crossrefs@48.
    const cases = [_]struct { off: usize, val: u32 }{
        .{ .off = 24, .val = 0 }, // string_table_offset < header_size
        .{ .off = 28, .val = 0xFFFFFFFF }, // uuid past everything / bytes.len
        .{ .off = 32, .val = 8 }, // schema before uuid (out of order)
        .{ .off = 40, .val = 0xFFFFFFF0 }, // archetypes past bytes.len
        .{ .off = 48, .val = 0xFFFFFFFF }, // crossrefs past bytes.len
    };
    for (cases) |c| {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[c.off..][0..4], c.val, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
}

test "validator rejects invalid string, schema, uuid and crossref references" {
    const gpa = testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const base = try buildRichScene(gpa, &reg);
    defer gpa.free(base);
    const acc = try accessor_mod.Accessor.open(base);

    // Corrupt the first schema entry's name_ref to point past the string table.
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[acc.header.schema_table_offset..][0..4], 0xFFFFFFF0, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
    // Corrupt the first schema entry's alignment to a non-power-of-two.
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u16, buf[acc.header.schema_table_offset + 6 ..][0..2], 3, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
    // Corrupt a crossref schema_index to be ≥ schema_count.
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[acc.header.crossrefs_offset + 4 + 4 ..][0..4], 999, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
    // Corrupt a crossref source ordinal to be ≥ uuid_count.
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[acc.header.crossrefs_offset + 4 ..][0..4], 999, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
}

test "validator rejects overflowing column geometry" {
    const gpa = testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const base = try buildMinimalScene(gpa, &reg);
    defer gpa.free(base);
    const acc = try accessor_mod.Accessor.open(base);

    // Block layout at archetypes_offset: [arch_count u32][component_count u32]
    // [schema_indices ×cc][entity_count u32]…. cc == 1 → entity_count @ +12.
    const ao = acc.header.archetypes_offset;
    // Oversized entity_count: stride(8) × entity_count blows past the section.
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[ao + 12 ..][0..4], 0x20000000, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
    // Oversized component_count (> max_components_per_archetype).
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[ao + 4 ..][0..4], 0xFFFFFFFF, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
}

test "seeded mutation robustness: hash-fixed corrupt scenes never panic" {
    const gpa = testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const pristine = try buildRichScene(gpa, &reg);
    defer gpa.free(pristine);

    const buf = try gpa.dupe(u8, pristine);
    defer gpa.free(buf);

    // Fixed-seed PRNG (deterministic in CI). Each iteration resets to pristine,
    // applies 1–4 random byte mutations, re-fixes the hash so `verifyHash`
    // passes, then runs the open→verify→validate pipeline. The only assertion is
    // implicit: no path may panic (safety checks are live under Debug/ReleaseSafe).
    var prng = std.Random.DefaultPrng.init(0x5CE7E5EED);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        @memcpy(buf, pristine);
        const mutations = 1 + rand.uintLessThan(usize, 4);
        var m: usize = 0;
        while (m < mutations) : (m += 1) {
            const idx = rand.uintLessThan(usize, buf.len);
            buf[idx] = rand.int(u8);
        }
        refixHash(buf);
        openAndValidate(buf) catch {};
    }
}

/// One archetype `[Pos(8,4), Tag(4,4)]`, one entity — for the R11(a) monotonic
/// schema-index test. The block's `schema_indices` sit at a known offset.
fn buildTwoCompScene(gpa: std.mem.Allocator, reg: *Registry) ![]u8 {
    const pos = try registerPod(gpa, reg, "Pos", 8, 4); // id 0 → file schema index 0
    const tag = try registerPod(gpa, reg, "Tag", 4, 4); // id 1 → file schema index 1
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const strings = try a.dupe([]const u8, &.{try a.dupe(u8, "E0")});
    const uuids = try a.dupe([16]u8, &.{[_]u8{3} ** 16});
    const col_pos = try a.alloc(u8, 8);
    @memset(col_pos, 0);
    const col_tag = try a.alloc(u8, 4);
    @memset(col_tag, 0);
    const ids = try a.dupe(format.ComponentId, &.{ pos, tag });
    const cols = try a.dupe([]u8, &.{ col_pos, col_tag });
    const ents = try a.dupe(format.EntityEntry, &.{.{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent }});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{ .component_ids = ids, .entity_count = 1, .columns = cols, .entities = ents }});
    var model: format.CookModel = .{ .strings = strings, .uuids = uuids, .resources = &.{}, .archetypes = blocks, .arena = arena };
    defer model.deinit();
    return writer.write(gpa, model, reg);
}

test "validator rejects bad resource data_size and string-field offset" {
    const gpa = testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const base = try buildRichScene(gpa, &reg); // Settings resource: size 16, 1 string field
    defer gpa.free(base);
    const acc = try accessor_mod.Accessor.open(base);
    const ro = acc.header.resources_offset;

    // R10(a): data_size (@ resources_offset + 4) must equal the schema size (16).
    inline for (.{ @as(u32, 15), @as(u32, 20) }) |bad_size| {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[ro + 4 ..][0..4], bad_size, .little);
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
    // R10(b): the string-field offset (first sf pair @ resources_offset + 8 +
    // data_size(16) + 4 = +28) must satisfy offset + 4 <= data_size(16).
    {
        const buf = try gpa.dupe(u8, base);
        defer gpa.free(buf);
        std.mem.writeInt(u32, buf[ro + 28 ..][0..4], 20, .little); // 20 + 4 > 16
        refixHash(buf);
        try testing.expectError(error.MalformedScene, openAndValidate(buf));
    }
}

test "validator rejects non-ascending / duplicate schema indices in an archetype" {
    const gpa = testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);
    const base = try buildTwoCompScene(gpa, &reg);
    defer gpa.free(base);
    const acc = try accessor_mod.Accessor.open(base);
    // Block @ archetypes_offset + 4: [cc=2 u32][sidx0 u32][sidx1 u32]…
    // sidx1 lives at archetypes_offset + 12. Force it to equal sidx0 (0) — the
    // mask is no longer strictly ascending.
    const s1 = acc.header.archetypes_offset + 12;
    const buf = try gpa.dupe(u8, base);
    defer gpa.free(buf);
    std.mem.writeInt(u32, buf[s1..][0..4], 0, .little);
    refixHash(buf);
    try testing.expectError(error.MalformedScene, openAndValidate(buf));
}
