//! M0.2 / E1 — hash determinism + sensitivity tests.
//!
//! Coverage per `briefs/M0.2-rtti-resources-events-bindgen.md` E1
//! § Local acceptance criteria:
//!
//! - `type_id` is comptime-deterministic (two invocations on the same
//!   type produce the same value).
//! - `schema_hash` is sensitive to the order of fields.
//! - `schema_hash` is **sensitive** to the type name (acted decision:
//!   the algorithm mixes `@typeName(T)` into the hash, so two layout-
//!   equivalent types with different names yield distinct hashes; cf.
//!   `hash.zig` top-level comment).

const std = @import("std");
const weld_core = @import("weld_core");

const rtti = weld_core.rtti;
const FieldKind = rtti.FieldKind;

test "type_id is deterministic across invocations" {
    const Foo = struct {
        a: f32,
        b: u32,
    };
    const id_first = comptime rtti.computeTypeId(Foo);
    const id_second = comptime rtti.computeTypeId(Foo);
    try std.testing.expectEqual(id_first, id_second);
}

test "type_id derived from name matches the canonical XxHash32 reference" {
    // Sanity: the published algorithm is `XxHash32(seed=0, @typeName)`.
    // We can compute it directly and expect equality with the helper.
    const name = "weld_engine.test.ManualName";
    const expected: rtti.TypeId = std.hash.XxHash32.hash(0, name);
    try std.testing.expectEqual(expected, rtti.computeTypeIdFromName(name));
}

test "schema_hash is sensitive to field order" {
    // Two field arrays with the same names + kinds but swapped order
    // must produce distinct hashes. We hash directly through the
    // parts-level helper so the `@typeName` component is held
    // constant — isolates the field-order sensitivity.
    const FieldDesc = rtti.FieldDesc;
    const a = [_]FieldDesc{
        .{ .name = "x", .offset = 0, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
        .{ .name = "y", .offset = 4, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
    };
    const b = [_]FieldDesc{
        .{ .name = "y", .offset = 0, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
        .{ .name = "x", .offset = 4, .size = 4, .alignment = 4, .kind = .f32, .count = 1, .nested_type_id = null, .unit = "" },
    };
    const ha = rtti.computeSchemaHashFromParts("Pair", &a);
    const hb = rtti.computeSchemaHashFromParts("Pair", &b);
    try std.testing.expect(ha != hb);
}

test "schema_hash is sensitive to the type name (layout-equivalent types differ)" {
    // Decision recorded in `hash.zig`: the algorithm includes the
    // `@typeName(T)` in the digest. Two structs whose layout is
    // identical but whose name differs therefore produce distinct
    // `schema_hash` values.
    const Alpha = struct { x: f32, y: f32 };
    const Beta = struct { x: f32, y: f32 };
    const ha = comptime rtti.computeSchemaHash(Alpha);
    const hb = comptime rtti.computeSchemaHash(Beta);
    try std.testing.expect(ha != hb);
}

test "schema_hash is stable for a single type across builds" {
    // Determinism: the value depends only on `@typeName` and the
    // declared field layout — both build-independent.
    const Stable = extern struct {
        a: u32,
        b: u32,
    };
    const first = comptime rtti.computeSchemaHash(Stable);
    const second = comptime rtti.computeSchemaHash(Stable);
    try std.testing.expectEqual(first, second);
}

test "schema_hash differs when a field is renamed" {
    // Field renaming changes the hash even when the kind / offset /
    // count are unchanged — the name is mixed into the digest.
    const Original = extern struct { count: u32 };
    const Renamed = extern struct { tally: u32 };
    const h0 = comptime rtti.computeSchemaHash(Original);
    const h1 = comptime rtti.computeSchemaHash(Renamed);
    try std.testing.expect(h0 != h1);
}
