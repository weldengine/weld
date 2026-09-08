//! FROZEN — see engine-phase-0-criteria.md C0.5. Every public entry below is.
//!
//! POD records, built at comptime by `comptime_builder.zig`, indexed by `registry.zig`.

const std = @import("std");

/// Stable identity, derived deterministically from `@typeName(T)` at comptime.
pub const TypeId = u32;

/// Schema digest over the per-field layout plus the parent `@typeName`. Identical
/// schemas MUST hash equal, which is what makes `register` idempotent.
pub const SchemaHash = u64;

/// Which Tier 0 subsystem consumes the metadata.
pub const Category = enum(u8) {
    component,
    resource,
    event,
    message,
};

/// Lifecycle hint for resources; meaningless unless `category == .resource`.
pub const Lifecycle = enum(u8) {
    /// Serialized in scene files, not in saves, not replicated.
    config,
    /// `@state` — serialized in saves, replicated.
    state,
    /// `@transient` — never serialized, never replicated.
    transient,
};

/// Concrete element shape, so a consumer never re-derives it from `@typeName`.
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

/// `kind`, `count`, `offset` and `size` suffice — no consumer reaches `@TypeOf`.
pub const FieldDesc = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    alignment: u32,
    kind: FieldKind,
    /// Element count: 1 for scalars and composites, `len` for arrays.
    count: u32,
    nested_type_id: ?TypeId,
    /// Optional unit tag; empty when unspecified.
    unit: []const u8,
};

/// Complete metadata record for a registered type.
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

// EXACTLY one of these maps to its dedicated `FieldKind`; a raw `[N]f32` gets
// `.fixed_array` instead.

/// 2-component float vector; matches `WeldVec2` (`engine-c-api.md` §2.2).
pub const Vec2 = extern struct { x: f32 = 0, y: f32 = 0 };
/// 3-component float vector; matches `WeldVec3` (`engine-c-api.md` §2.2).
pub const Vec3 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
/// 4-component float vector; matches `WeldVec4` (`engine-c-api.md` §2.2).
pub const Vec4 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 0 };
/// Unit quaternion (x, y, z, w); matches `WeldQuat` (`engine-c-api.md` §2.2).
pub const Quat = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 1 };
/// 3x3 column-major matrix; matches `WeldMat3` (`engine-c-api.md` §2.2).
pub const Mat3 = extern struct { m: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
/// 4x4 column-major matrix; matches `WeldMat4` (`engine-c-api.md` §2.2).
pub const Mat4 = extern struct { m: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
/// Linear-space RGBA color; matches `WeldColor` (`engine-c-api.md` §2.2).
pub const Color = extern struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };

/// Opaque entity handle. The NON-EXHAUSTIVE enum is what gives it an identity
/// distinct from a raw `u64`, so the builder can tell an `entity` field apart.
pub const Entity = enum(u64) { _ };

/// Opaque asset handle; same rationale as `Entity`.
pub const AssetHandle = enum(u64) { _ };

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
