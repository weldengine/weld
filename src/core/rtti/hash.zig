//! Deterministic identity + schema hashes for RTTI.
//!
//! - `computeTypeId(T)` returns the 32-bit identity of a type by
//!   hashing `@typeName(T)` with `XxHash32(seed=0)`.
//! - `computeSchemaHash(T)` returns the 64-bit schema digest of a
//!   type by hashing `(@typeName(T), [(field.name, kind, count,
//!   offset) for each field])` with `XxHash64(seed=0)`.
//!
//! Both functions are pure comptime — they fold to constants at
//! compile time and produce the same bytes across builds (XxHash is
//! deterministic, the inputs are build-independent: type name +
//! comptime-resolved field layout).
//!
//! Decision taken — `schema_hash` is **sensitive to `@typeName`**:
//! two structs with the same layout but different names
//! produce distinct `schema_hash` values. The hash_test.zig
//! "schema_hash is sensitive to the type name" test documents the decision.
//! The algorithm follows `briefs/M0.2-rtti-resources-events-bindgen.md`
//! E1 §Deliverable.

const std = @import("std");
const type_info = @import("type_info.zig");

const TypeId = type_info.TypeId;
const SchemaHash = type_info.SchemaHash;
const FieldDesc = type_info.FieldDesc;
const FieldKind = type_info.FieldKind;
const builder = @import("comptime_builder.zig");

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Comptime-deterministic 32-bit identity for `T`. Wraps
/// `computeTypeIdFromName(@typeName(T))`.
pub fn computeTypeId(comptime T: type) TypeId {
    return computeTypeIdFromName(@typeName(T));
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Comptime-deterministic 32-bit identity for an arbitrary name.
/// Exposed for tests and for use cases (cross-language tools, IPC
/// debugging) that need to compute a `TypeId` without holding the Zig
/// type itself.
pub fn computeTypeIdFromName(name: []const u8) TypeId {
    return std.hash.XxHash32.hash(0, name);
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Comptime-deterministic 64-bit schema digest for `T`. The fields are
/// derived from `builder.buildFields(T)`; the hash mixes the type
/// name with the `(name, kind, count, offset)` tuple of each field in
/// declaration order. Sensitive to field reordering and to
/// `@typeName(T)`.
pub fn computeSchemaHash(comptime T: type) SchemaHash {
    const fields = comptime builder.buildFields(T);
    return computeSchemaHashFromParts(@typeName(T), fields);
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Direct hash entry point used by `computeSchemaHash` and the
/// E1 registry tests. Hashes the tuple `(type_name,
/// [(field.name, kind, count, offset) for each field])` with
/// `XxHash64(seed=0)`. Exposed so callers can verify field-order
/// sensitivity without going through the comptime builder.
///
/// Comptime branch quota is raised because the hash loop iterates
/// over an arbitrary field count and XxHash's `update` itself loops
/// over chunked input — both consume branches when the call is
/// evaluated at compile time.
pub fn computeSchemaHashFromParts(type_name: []const u8, fields: []const FieldDesc) SchemaHash {
    @setEvalBranchQuota(100_000);
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(type_name);
    for (fields) |f| {
        hasher.update(f.name);
        const kind_byte: u8 = @intFromEnum(f.kind);
        hasher.update(std.mem.asBytes(&kind_byte));
        const count: u32 = f.count;
        hasher.update(std.mem.asBytes(&count));
        const offset: u32 = f.offset;
        hasher.update(std.mem.asBytes(&offset));
    }
    return hasher.final();
}

// ---------------------------------------------------------------- tests --

test "computeTypeIdFromName matches XxHash32 reference" {
    // XxHash32 seed=0 on "hello" — sanity check that we are wiring the
    // canonical algorithm and not, say, an internal variant.
    const got = computeTypeIdFromName("hello");
    const ref = std.hash.XxHash32.hash(0, "hello");
    try std.testing.expectEqual(ref, got);
}

test "computeTypeId is comptime-foldable" {
    const Foo = struct { x: f32 };
    const id_a = comptime computeTypeId(Foo);
    const id_b = comptime computeTypeId(Foo);
    try std.testing.expectEqual(id_a, id_b);
}

test "computeSchemaHashFromParts is field-order sensitive" {
    // Two field lists that differ only in the iteration order should
    // produce distinct hashes when fed to the parts-level helper.
    const a = [_]FieldDesc{
        .{ .name = "x", .offset = 0, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
        .{ .name = "y", .offset = 4, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
    };
    const b = [_]FieldDesc{
        .{ .name = "y", .offset = 0, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
        .{ .name = "x", .offset = 4, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
    };
    const ha = computeSchemaHashFromParts("Same", &a);
    const hb = computeSchemaHashFromParts("Same", &b);
    try std.testing.expect(ha != hb);
}
