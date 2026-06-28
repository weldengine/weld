//! `.scene.bin` writer — Tier 0. Serializes the neutral `format.CookModel`
//! (produced by the M1.0.4 Etch cook) into the on-disk byte image. The M1.0.5
//! loader reads it back with `accessor.zig` (the read half of this codec).
//!
//! File layout (all section offsets are file-relative, recorded in the header):
//! ```
//!   [SceneHeader            64 B]
//!   [String Table]                 length-prefixed UTF-8, deduplicated
//!   [UUID Table]                   16 B each
//!   [Schema Registry]              §10 — one SchemaEntry per distinct type
//!   [Resources Block]              per resource: schema-index + data + string refs
//!   [Archetype Blocks]             per archetype: schema mask + entity meta + SoA columns
//!   [Entity Extensions Table]      reserved — empty (M1.0.6)
//!   [Cross-references Table]       reserved — empty (M1.0.6)
//! ```
//! `hash` covers everything after the header. Component identity on disk is the
//! Schema Registry index (never a runtime `ComponentId`); schema identity is the
//! component name (`engine-ecs-internals.md` §10, M1.0.4 brief deviation).
//!
//! Determinism (the E3 re-cook byte-identity guarantee): every ordering here is
//! deterministic — schemas sorted by ascending `ComponentId` (the cook assigns
//! ids in declaration order), tables emitted in model order, no hashing of
//! addresses. Same source → same registry ids → same bytes.

const std = @import("std");

const format = @import("format.zig");
const registry_mod = @import("../ecs/registry.zig");

const Registry = registry_mod.Registry;
const ComponentId = registry_mod.ComponentId;
const SceneHeader = format.SceneHeader;

/// Writer failures: allocation, or a table/section larger than a `u32` offset
/// can address (`Overflow` — a scene far beyond any realistic size).
pub const WriteError = error{ OutOfMemory, Overflow };

/// Serialize `model` to `.scene.bin` bytes (caller owns the returned slice).
/// `registry` supplies each schema's name/size/alignment (the cook's own
/// registry — the same one `scene_cook.cook` returns alongside the model).
pub fn write(gpa: std.mem.Allocator, model: format.CookModel, registry: *const Registry) WriteError![]u8 {
    var w: Writer = .{ .gpa = gpa, .model = model, .registry = registry };
    defer w.deinit();
    return try w.run();
}

const Writer = struct {
    gpa: std.mem.Allocator,
    model: format.CookModel,
    registry: *const Registry,

    body: std.ArrayListUnmanaged(u8) = .empty,
    // Distinct schema ids (sorted asc) and the inverse map id → file-local index.
    schema_ids: std.ArrayListUnmanaged(ComponentId) = .empty,
    id_to_index: std.AutoHashMapUnmanaged(ComponentId, u32) = .empty,
    // model string ordinal → string-table byte offset (section-relative).
    model_str_ref: []u32 = &.{},
    // file-local schema index → its name's string-table byte offset.
    schema_name_ref: []u32 = &.{},

    fn deinit(self: *Writer) void {
        self.body.deinit(self.gpa);
        self.schema_ids.deinit(self.gpa);
        self.id_to_index.deinit(self.gpa);
        if (self.model_str_ref.len != 0) self.gpa.free(self.model_str_ref);
        if (self.schema_name_ref.len != 0) self.gpa.free(self.schema_name_ref);
    }

    fn run(self: *Writer) WriteError![]u8 {
        try self.collectSchemas();

        var hdr: SceneHeader = .{
            .content_version = self.model.content_version,
            .entity_count = try u32From(self.totalEntities()),
            .resource_count = try u32From(self.model.resources.len),
            .schema_count = try u32From(self.schema_ids.items.len),
        };

        hdr.string_table_offset = try self.sectionOffset();
        try self.writeStringTable();
        hdr.uuid_table_offset = try self.sectionOffset();
        try self.writeUuidTable();
        hdr.schema_table_offset = try self.sectionOffset();
        try self.writeSchemaTable();
        hdr.resources_offset = try self.sectionOffset();
        try self.writeResources();
        hdr.archetypes_offset = try self.sectionOffset();
        try self.writeArchetypes();
        hdr.extensions_offset = try self.sectionOffset();
        try self.appendU32(0); // reserved — empty (M1.0.6 E5/E6)
        hdr.crossrefs_offset = try self.sectionOffset();
        try self.writeCrossRefs();

        hdr.hash = std.hash.XxHash64.hash(0, self.body.items);

        const out = try self.gpa.alloc(u8, format.header_size + self.body.items.len);
        var hbuf: [format.header_size]u8 = undefined;
        hdr.writeTo(&hbuf);
        @memcpy(out[0..format.header_size], &hbuf);
        @memcpy(out[format.header_size..], self.body.items);
        return out;
    }

    // ── byte appenders (little-endian) ──

    fn appendU16(self: *Writer, v: u16) WriteError!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.body.appendSlice(self.gpa, &b);
    }
    fn appendU32(self: *Writer, v: u32) WriteError!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.body.appendSlice(self.gpa, &b);
    }
    fn appendBytes(self: *Writer, bytes: []const u8) WriteError!void {
        try self.body.appendSlice(self.gpa, bytes);
    }
    /// Pad the body with zeros until `header_size + body.len` is `align`-aligned
    /// (column starts are aligned in file-absolute space, = mmap memory space).
    fn padToFileAlign(self: *Writer, alignment: usize) WriteError!void {
        const cur = format.header_size + self.body.items.len;
        const target = std.mem.alignForward(usize, cur, alignment);
        var pad = target - cur;
        while (pad > 0) : (pad -= 1) try self.body.append(self.gpa, 0);
    }
    /// Current section's file offset (where the next bytes will land).
    fn sectionOffset(self: *Writer) WriteError!u32 {
        return try u32From(format.header_size + self.body.items.len);
    }

    fn totalEntities(self: *Writer) usize {
        var n: usize = 0;
        for (self.model.archetypes) |arch| n += arch.entity_count;
        return n;
    }

    // ── schema collection ──

    fn collectSchemas(self: *Writer) WriteError!void {
        for (self.model.archetypes) |arch| {
            for (arch.component_ids) |id| try self.noteSchema(id);
        }
        for (self.model.resources) |res| try self.noteSchema(res.schema_id);
        // The bearing component of every cross-ref is already on an entity (hence
        // in an archetype), but note it explicitly so `id_to_index` is total.
        for (self.model.cross_refs) |cr| try self.noteSchema(cr.component_id);
        // Deterministic order: ascending ComponentId.
        std.mem.sort(ComponentId, self.schema_ids.items, {}, comptime std.sort.asc(ComponentId));
        for (self.schema_ids.items, 0..) |id, idx| try self.id_to_index.put(self.gpa, id, @intCast(idx));
    }

    fn noteSchema(self: *Writer, id: ComponentId) WriteError!void {
        for (self.schema_ids.items) |existing| if (existing == id) return;
        try self.schema_ids.append(self.gpa, id);
    }

    // ── sections ──

    fn writeStringTable(self: *Writer) WriteError!void {
        const section_start = self.body.items.len;
        var dedup: std.StringHashMapUnmanaged(u32) = .empty;
        defer dedup.deinit(self.gpa);

        self.model_str_ref = try self.gpa.alloc(u32, self.model.strings.len);
        for (self.model.strings, 0..) |s, i| {
            self.model_str_ref[i] = try self.internString(&dedup, section_start, s);
        }
        self.schema_name_ref = try self.gpa.alloc(u32, self.schema_ids.items.len);
        for (self.schema_ids.items, 0..) |id, i| {
            self.schema_name_ref[i] = try self.internString(&dedup, section_start, self.registry.componentName(id));
        }
    }

    /// Intern `s` into the string table (dedup); returns its section-relative
    /// byte offset. Each entry is `[u32 len][len bytes]`.
    fn internString(self: *Writer, dedup: *std.StringHashMapUnmanaged(u32), section_start: usize, s: []const u8) WriteError!u32 {
        if (dedup.get(s)) |off| return off;
        const off = try u32From(self.body.items.len - section_start);
        try self.appendU32(try u32From(s.len));
        try self.appendBytes(s);
        try dedup.put(self.gpa, s, off);
        return off;
    }

    fn writeUuidTable(self: *Writer) WriteError!void {
        for (self.model.uuids) |u| try self.appendBytes(&u);
    }

    fn writeSchemaTable(self: *Writer) WriteError!void {
        for (self.schema_ids.items, 0..) |id, i| {
            try self.appendU32(self.schema_name_ref[i]); // name_ref
            try self.appendU16(self.registry.componentSize(id)); // size
            try self.appendU16(self.registry.componentAlignment(id)); // alignment
        }
    }

    fn writeResources(self: *Writer) WriteError!void {
        for (self.model.resources) |res| {
            try self.appendU32(self.id_to_index.get(res.schema_id).?); // schema index
            try self.appendU32(try u32From(res.data.len)); // data_size
            try self.appendBytes(res.data); // POD blob (string slots zeroed)
            try self.appendU32(try u32From(res.string_fields.len)); // string_field_count
            for (res.string_fields) |sf| {
                try self.appendU32(sf.offset); // field byte offset in the blob
                try self.appendU32(self.model_str_ref[sf.str]); // string-table ref
            }
        }
    }

    fn writeArchetypes(self: *Writer) WriteError!void {
        try self.appendU32(try u32From(self.model.archetypes.len));
        for (self.model.archetypes) |arch| {
            const n = arch.entity_count;
            // Per-column sizes/aligns in column (sorted-id) order.
            try self.appendU32(try u32From(arch.component_ids.len)); // component_count
            for (arch.component_ids) |id| try self.appendU32(self.id_to_index.get(id).?); // schema indices
            try self.appendU32(n); // entity_count
            for (arch.entities) |e| try self.appendU32(self.model_str_ref[e.name]); // name refs
            for (arch.entities) |e| try self.appendU32(e.uuid); // uuid ordinals
            for (arch.entities) |e| try self.appendU32(e.parent_uuid); // parent uuid ordinals / no_parent

            // SoA columns, each aligned (file-absolute) to its component alignment.
            for (arch.component_ids, 0..) |id, c| {
                try self.padToFileAlign(self.registry.componentAlignment(id));
                std.debug.assert(arch.columns[c].len == @as(usize, self.registry.componentSize(id)) * n);
                try self.appendBytes(arch.columns[c]);
            }
        }
    }

    /// Cross-references Table @ `crossrefs_offset`: `count: u32` then `count`
    /// `CrossRefEntry` (16 B). The model carries `component_id`; here it is
    /// converted to the file-local Schema Registry index (`id_to_index`) — the
    /// on-disk entry never stores a runtime `ComponentId`.
    fn writeCrossRefs(self: *Writer) WriteError!void {
        try self.appendU32(try u32From(self.model.cross_refs.len));
        for (self.model.cross_refs) |cr| {
            try self.appendU32(cr.source_uuid);
            try self.appendU32(self.id_to_index.get(cr.component_id).?);
            try self.appendU32(cr.field_offset);
            try self.appendU32(cr.target_uuid);
        }
    }
};

fn u32From(v: usize) WriteError!u32 {
    return std.math.cast(u32, v) orelse error.Overflow;
}
