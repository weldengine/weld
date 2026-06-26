//! `.scene.bin` format — Tier 0, single source of truth shared verbatim with
//! the M1.0.5 runtime loader (`engine-scene-serialization.md` §4).
//!
//! This file owns two things:
//!   1. The **on-disk format contract** — magic / version constants and the SoA
//!      column-layout rules (the M1.0.5 loader memcpys archetype columns into
//!      16 KB ECS chunks, so the cook and the loader must agree on column order,
//!      stride and alignment). The `SceneHeader` extern struct + the byte-level
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
pub const format_version: u16 = 1;

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
    try std.testing.expectEqual(@as(u16, 1), format_version);
}
