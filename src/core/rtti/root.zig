//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Public surface of the RTTI subsystem: comptime builder, type metadata,
//! deterministic hashes, runtime registry. Flat surface plus sub-module aliases for
//! consumers that must address private symbols.

const type_info_mod = @import("type_info.zig");
const hash_mod = @import("hash.zig");
const builder_mod = @import("comptime_builder.zig");
const registry_mod = @import("registry.zig");

/// Type metadata declarations.
pub const type_info = type_info_mod;
/// Deterministic identity + schema hashes for RTTI metadata.
pub const hash = hash_mod;
/// Comptime builder that turns a Zig type into a `TypeInfo` record.
pub const comptime_builder = builder_mod;
/// Runtime registry that indexes `TypeInfo` by `TypeId` / `type_name`.
pub const registry = registry_mod;

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Bumped on any breaking change to the frozen surface — a tracked migration.
pub const WELD_RTTI_PROTOCOL_VERSION: u32 = 1;

/// Stable 32-bit identity of a registered type (cf. `type_info.zig`).
pub const TypeId = type_info_mod.TypeId;
/// 64-bit schema digest of a registered type (cf. `type_info.zig`).
pub const SchemaHash = type_info_mod.SchemaHash;
/// Category of a registered type (component / resource / event / message).
pub const Category = type_info_mod.Category;
/// Lifecycle hint for resource-category types.
pub const Lifecycle = type_info_mod.Lifecycle;
/// Concrete element kind of a field (`f32`, `vec3`, `optional`, …).
pub const FieldKind = type_info_mod.FieldKind;
/// Per-field metadata record.
pub const FieldDesc = type_info_mod.FieldDesc;
/// Complete metadata record for a registered type.
pub const TypeInfo = type_info_mod.TypeInfo;

/// 2-component float vector (engine composite, `FieldKind.vec2`).
pub const Vec2 = type_info_mod.Vec2;
/// 3-component float vector (engine composite, `FieldKind.vec3`).
pub const Vec3 = type_info_mod.Vec3;
/// 4-component float vector (engine composite, `FieldKind.vec4`).
pub const Vec4 = type_info_mod.Vec4;
/// Unit quaternion (engine composite, `FieldKind.quat`).
pub const Quat = type_info_mod.Quat;
/// 3×3 column-major float matrix (engine composite, `FieldKind.mat3`).
pub const Mat3 = type_info_mod.Mat3;
/// 4×4 column-major float matrix (engine composite, `FieldKind.mat4`).
pub const Mat4 = type_info_mod.Mat4;
/// RGBA float color in linear space (engine composite, `FieldKind.color`).
pub const Color = type_info_mod.Color;
/// Opaque entity handle, ABI-equivalent to `u64` (`FieldKind.entity`).
pub const Entity = type_info_mod.Entity;
/// Opaque asset handle, ABI-equivalent to `u64` (`FieldKind.asset_handle`).
pub const AssetHandle = type_info_mod.AssetHandle;

/// Builds the full `TypeInfo` record for `T` at comptime.
pub const buildTypeInfo = builder_mod.buildTypeInfo;
/// Builds the per-field metadata slice for `T` at comptime.
pub const buildFields = builder_mod.buildFields;
/// Maps a Zig type to its concrete `FieldKind`.
pub const classifyField = builder_mod.classifyField;
/// POD predicate gating `buildTypeInfo`'s `@compileError`.
pub const isPOD = builder_mod.isPOD;
/// Reads the resource lifecycle from a struct's `pub const lifecycle`, if any.
pub const inferLifecycle = builder_mod.inferLifecycle;

/// Comptime-deterministic 32-bit identity for `T`.
pub const computeTypeId = hash_mod.computeTypeId;
/// Comptime-deterministic 32-bit identity for an arbitrary name.
pub const computeTypeIdFromName = hash_mod.computeTypeIdFromName;
/// Comptime-deterministic 64-bit schema digest for `T`.
pub const computeSchemaHash = hash_mod.computeSchemaHash;
/// Direct schema hash entry point — hashes `(name, fields)`.
pub const computeSchemaHashFromParts = hash_mod.computeSchemaHashFromParts;

/// Runtime registry indexing `TypeInfo` records.
pub const Registry = registry_mod.Registry;
/// Error set returned by `Registry.register`.
pub const RegisterError = registry_mod.RegisterError;

comptime {
    // NOT dead code: these references are what make Zig analyse the sub-files, so
    // their inline `test` blocks are collected at all.
    _ = type_info_mod;
    _ = hash_mod;
    _ = builder_mod;
    _ = registry_mod;
}
