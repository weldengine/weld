//! RTTI type metadata — public surface of the M0.2 reflection runtime.
//!
//! Defines the canonical metadata records that describe component,
//! resource, event, and message types in the Weld engine: identity
//! (`TypeId`), schema digest (`SchemaHash`), per-field layout
//! (`FieldDesc` / `FieldKind`), category (`Category`), and optional
//! lifecycle tag (`Lifecycle`). The records are POD and produced at
//! comptime by `comptime_builder.zig`; the registry in `registry.zig`
//! indexes them at runtime for serializers, the editor, and the plugin
//! loader.
//!
//! E1 scope (M0.2 brief): no metier consumer yet. The S6 IPC swap is
//! E2, resources are E3, events are E4 — those land on top of this
//! file without changing its public surface.
//!
//! See `engine-spec.md` §2.5 and `briefs/M0.2-rtti-resources-events-bindgen.md`.

const std = @import("std");

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Stable identity for a registered type, derived deterministically
/// from `@typeName(T)` at comptime via `hash.computeTypeId`. Two Zig
/// types with different fully-qualified names have distinct `TypeId`s.
/// 32 bits is sufficient for the foreseeable type population (well
/// under 65 K registered types).
pub const TypeId = u32;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Schema digest — captures the per-field layout (name + kind + count
/// + offset) plus the parent `@typeName`. Identical schemas produce
/// the same hash (idempotent register); a mismatch is reported as
/// `error.SchemaMismatch` by the registry.
pub const SchemaHash = u64;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Category of a registered type. Drives which Tier 0 subsystem
/// (storage layer, query engine, event bus, IPC framing) consumes the
/// metadata at runtime.
pub const Category = enum(u8) {
    component,
    resource,
    event,
    message,
};

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Lifecycle hint for resources. Drives the serialization /
/// replication policy (cf. `engine-spec.md` §2.9 table). Only carries
/// meaning when `TypeInfo.category == .resource`; `null` for the other
/// categories.
pub const Lifecycle = enum(u8) {
    /// `@config` — serialized in scene files, not in saves, not
    /// replicated.
    config,
    /// `@state` — serialized in saves, replicated.
    state,
    /// `@transient` — never serialized, never replicated.
    transient,
};

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Field kind — discriminates between primitive scalars, fixed-size
/// arrays, nested structs, optionals, and engine-canonical composite
/// types (`Vec*`, `Quat`, `Mat*`, `Color`, `Entity`, `AssetHandle`).
/// Tagged on each field by the comptime builder so downstream
/// consumers (serializers, editor inspector, IPC) can dispatch on
/// concrete element shape without re-deriving it from `@typeName`.
pub const FieldKind = enum(u8) {
    bool,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    vec2,
    vec3,
    vec4,
    quat,
    mat3,
    mat4,
    color,
    entity,
    asset_handle,
    enum_tag,
    fixed_array,
    nested_struct,
    optional,
    string_inline,
};

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Per-field metadata. The combination of `kind`, `count`, `offset`,
/// and `size` is sufficient for the round-trip encode/decode path
/// exercised by the E1 registry test — runtime consumers never reach
/// back to `@TypeOf` or `@typeName` to interpret a field.
pub const FieldDesc = struct {
    /// Field name as declared in the Zig source. Comptime-known
    /// string with static lifetime.
    name: []const u8,
    /// Byte offset of the field within the enclosing struct, per
    /// `@offsetOf(T, name)`.
    offset: u32,
    /// Byte size of the field, per `@sizeOf(FieldType)`.
    size: u32,
    /// Alignment of the field, per `@alignOf(FieldType)`.
    alignment: u32,
    /// Concrete element kind.
    kind: FieldKind,
    /// Element count. `1` for scalar primitives and engine-canonical
    /// composites; `len` for `.fixed_array` / `.string_inline`.
    count: u32,
    /// `TypeId` of the nested element when `kind` is `.nested_struct`,
    /// `.fixed_array`, or `.optional` and the element is itself a
    /// user-defined type. `null` for plain primitives and engine
    /// composites.
    nested_type_id: ?TypeId,
    /// Optional unit tag (e.g. `"meters"`, `"degrees"`). Empty string
    /// when unspecified — kept on the field for the editor inspector
    /// without re-introducing a separate annotation map.
    unit: []const u8,
};

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Complete metadata record for a registered type. Stored by value in
/// `Registry.types` once `register` accepts it.
pub const TypeInfo = struct {
    type_id: TypeId,
    type_name: []const u8,
    size: u32,
    alignment: u32,
    schema_hash: SchemaHash,
    fields: []const FieldDesc,
    category: Category,
    lifecycle: ?Lifecycle = null,
};

// -- Engine-canonical composite types ----------------------------------
//
// E1 ships these so the comptime builder can map a user-defined struct
// field whose type is exactly one of these to the dedicated `FieldKind`
// variant (`.vec3`, `.quat`, etc.). They are POD, ABI-stable, and may
// be substituted for raw `[N]f32` arrays in user code that wants the
// dedicated kind tag instead of `.fixed_array`.
//
// The existing ECS components (`src/core/ecs/components.zig`) keep
// using raw `[N]f32 align(16)` arrays per S1 — they are untouched by
// E1 (no consumer wiring per the milestone scope).

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// 2-component float vector. Matches `WeldVec2` in
/// `engine-c-api.md` §2.2.
pub const Vec2 = extern struct { x: f32 = 0, y: f32 = 0 };
/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// 3-component float vector. Matches `WeldVec3` in
/// `engine-c-api.md` §2.2.
pub const Vec3 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// 4-component float vector. Matches `WeldVec4` in
/// `engine-c-api.md` §2.2.
pub const Vec4 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 0 };
/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Unit quaternion (x, y, z, w). Identity defaults to (0, 0, 0, 1).
/// Matches `WeldQuat` in `engine-c-api.md` §2.2.
pub const Quat = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 1 };
/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// 3×3 column-major float matrix. Matches `WeldMat3` in
/// `engine-c-api.md` §2.2.
pub const Mat3 = extern struct { m: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// 4×4 column-major float matrix. Matches `WeldMat4` in
/// `engine-c-api.md` §2.2.
pub const Mat4 = extern struct { m: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// RGBA float color in linear space. Matches `WeldColor` in
/// `engine-c-api.md` §2.2.
pub const Color = extern struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Opaque entity handle, ABI-equivalent to `u64` (matches the
/// `WeldEntity` typedef of `engine-c-api.md` §2.1). Non-exhaustive
/// enum gives a distinct type identity vs raw `u64` so the comptime
/// builder can disambiguate `entity` fields from generic `u64`
/// scalars.
pub const Entity = enum(u64) { _ };

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Opaque asset handle, ABI-equivalent to `u64` (matches
/// `WeldAssetHandle` in `engine-c-api.md` §2.1). Distinct type
/// identity via non-exhaustive enum, same rationale as `Entity`.
pub const AssetHandle = enum(u64) { _ };

// ---------------------------------------------------------------- tests --

test "TypeId / SchemaHash widths are stable" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(TypeId));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SchemaHash));
}

test "engine composites are POD with stable sizes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vec2));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Vec3));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Vec4));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Quat));
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Mat3));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Mat4));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Entity));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(AssetHandle));
}
