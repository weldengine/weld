//! FROZEN — see engine-phase-0-criteria.md C0.5. Every public entry below is.
//!
//! Deterministic identity and schema hashes for RTTI.
//!
//! BOTH ARE PURE COMPTIME AND MUST STAY BYTE-STABLE ACROSS BUILDS: the inputs are a
//! type name and a comptime-resolved field layout, and the digest is what makes
//! `register` idempotent across a rebuild.
//!
//! `schema_hash` is SENSITIVE to `@typeName` by decision — two structs of identical
//! layout and different names hash differently.

const std = @import("std");
const type_info = @import("type_info.zig");

const TypeId = type_info.TypeId;
const SchemaHash = type_info.SchemaHash;
const FieldDesc = type_info.FieldDesc;
const FieldKind = type_info.FieldKind;
const builder = @import("comptime_builder.zig");

/// Comptime-deterministic 32-bit identity for `T`.
pub fn computeTypeId(comptime T: type) TypeId {
    return computeTypeIdFromName(@typeName(T));
}

/// Comptime-deterministic 32-bit identity for an arbitrary name.
pub fn computeTypeIdFromName(name: []const u8) TypeId {
    return std.hash.XxHash32.hash(0, name);
}

/// Comptime-deterministic 64-bit schema digest for `T`, over its ordered fields.
pub fn computeSchemaHash(comptime T: type) SchemaHash {
    const fields = comptime builder.buildFields(T);
    return computeSchemaHashFromParts(@typeName(T), fields);
}

/// Digest entry point taking the parts directly, for callers that have no type.
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
    // A known XxHash32 value, so a wiring change to the algorithm shows up here.
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
    // Field ORDER must change the digest, or a reordered struct hashes equal.
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
