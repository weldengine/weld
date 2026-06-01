//! M0.2 / E1 — registry tests.
//!
//! Coverage per `briefs/M0.2-rtti-resources-events-bindgen.md` E1
//! § Local acceptance criteria:
//!
//! - `register` then `lookup` returns an identical `TypeInfo`.
//! - `lookupByName` indexes by `type_name`.
//! - Double-`register` of the same `(type_id, schema_hash)` is
//!   idempotent.
//! - Double-`register` with different schemas returns
//!   `error.SchemaMismatch`.
//! - Round-trip `component → bytes → component` reconstructs the
//!   original bit-for-bit, encoding and decoding via the `FieldDesc`
//!   metadata only — no `@typeName` / `@TypeOf` at runtime.

const std = @import("std");
const weld_core = @import("weld_core");

const rtti = weld_core.rtti;
const Registry = rtti.Registry;

// -- Synthetic POD components used by the round-trip path -------------
//
// Position / Velocity here are local to the test — they do NOT consume
// or shadow the live ECS types from `src/core/ecs/components.zig`. E1
// is standalone: no domain wiring (S6 IPC swap is E2, resources are
// E3, events are E4).

const Position = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

const Velocity = extern struct {
    linear: rtti.Vec3 = .{},
    angular: rtti.Vec3 = .{},
};

test "register then lookup returns the same TypeInfo" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const info = comptime rtti.buildTypeInfo(Position, .component);
    try reg.register(info);

    const got = reg.lookup(info.type_id);
    try std.testing.expect(got != null);
    const g = got.?.*;
    try std.testing.expectEqual(info.type_id, g.type_id);
    try std.testing.expectEqual(info.schema_hash, g.schema_hash);
    try std.testing.expectEqual(info.size, g.size);
    try std.testing.expectEqual(info.alignment, g.alignment);
    try std.testing.expectEqual(info.fields.len, g.fields.len);
    try std.testing.expectEqual(info.category, g.category);
}

test "lookupByName indexes by type_name" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const info = comptime rtti.buildTypeInfo(Position, .component);
    try reg.register(info);

    const by_name = reg.lookupByName(info.type_name);
    try std.testing.expect(by_name != null);
    try std.testing.expectEqual(info.type_id, by_name.?.type_id);

    try std.testing.expect(reg.lookupByName("nope") == null);
}

test "double register with the same schema is idempotent" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const info = comptime rtti.buildTypeInfo(Position, .component);
    try reg.register(info);
    try reg.register(info); // no-op
    try reg.register(info); // still no-op

    try std.testing.expectEqual(@as(u32, 1), reg.count());
}

test "double register with a different schema returns SchemaMismatch" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const info = comptime rtti.buildTypeInfo(Position, .component);
    try reg.register(info);

    // Synthesize a record that claims the same `type_id` but with a
    // different schema_hash. Mirrors the failure mode that would arise
    // if a plugin shipped a stale `TypeInfo` against a host that had
    // bumped the schema.
    var mutated = info;
    mutated.schema_hash = info.schema_hash ^ 0xDEADBEEF_DEADBEEF;

    try std.testing.expectError(error.SchemaMismatch, reg.register(mutated));
}

test "round-trip component -> bytes -> component via FieldDesc only" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const info = comptime rtti.buildTypeInfo(Position, .component);
    try reg.register(info);

    const original = Position{ .x = 1.5, .y = -2.25, .z = 3.75 };

    // Encode field-by-field using only the `FieldDesc` metadata. We
    // deliberately do not call `@TypeOf(original)` or `@typeName` at
    // runtime — the encoder works off `info` alone.
    const src_bytes = std.mem.asBytes(&original);
    var wire: [@sizeOf(Position)]u8 = undefined;
    @memset(&wire, 0);
    for (info.fields) |f| {
        const start: usize = f.offset;
        const end: usize = start + f.size;
        @memcpy(wire[start..end], src_bytes[start..end]);
    }

    // Decode field-by-field into a fresh buffer, same constraint.
    var decoded: Position = undefined;
    const dst_bytes: *[@sizeOf(Position)]u8 = std.mem.asBytes(&decoded);
    @memset(dst_bytes, 0);
    for (info.fields) |f| {
        const start: usize = f.offset;
        const end: usize = start + f.size;
        @memcpy(dst_bytes[start..end], wire[start..end]);
    }

    // Bit-for-bit equality across the full struct.
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&original), std.mem.asBytes(&decoded)));
    try std.testing.expectEqual(original.x, decoded.x);
    try std.testing.expectEqual(original.y, decoded.y);
    try std.testing.expectEqual(original.z, decoded.z);
}

test "round-trip with nested composite (Vec3) via FieldDesc only" {
    // Velocity contains two Vec3 fields. The encoder still works off
    // raw byte ranges keyed by FieldDesc — kind / count are not
    // needed for the memcpy path, but the size + offset are.
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const info = comptime rtti.buildTypeInfo(Velocity, .component);
    try reg.register(info);

    const original = Velocity{
        .linear = .{ .x = 10, .y = 20, .z = 30 },
        .angular = .{ .x = -1, .y = -2, .z = -3 },
    };

    const src_bytes = std.mem.asBytes(&original);
    var wire: [@sizeOf(Velocity)]u8 = undefined;
    @memset(&wire, 0);
    for (info.fields) |f| {
        const start: usize = f.offset;
        const end: usize = start + f.size;
        @memcpy(wire[start..end], src_bytes[start..end]);
    }

    var decoded: Velocity = undefined;
    const dst_bytes: *[@sizeOf(Velocity)]u8 = std.mem.asBytes(&decoded);
    @memset(dst_bytes, 0);
    for (info.fields) |f| {
        const start: usize = f.offset;
        const end: usize = start + f.size;
        @memcpy(dst_bytes[start..end], wire[start..end]);
    }

    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&original), std.mem.asBytes(&decoded)));
}

test "two distinct types coexist in the registry without collision" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const pos_info = comptime rtti.buildTypeInfo(Position, .component);
    const vel_info = comptime rtti.buildTypeInfo(Velocity, .component);
    try std.testing.expect(pos_info.type_id != vel_info.type_id);

    try reg.register(pos_info);
    try reg.register(vel_info);
    try std.testing.expectEqual(@as(u32, 2), reg.count());

    try std.testing.expectEqual(pos_info.type_id, reg.lookup(pos_info.type_id).?.type_id);
    try std.testing.expectEqual(vel_info.type_id, reg.lookup(vel_info.type_id).?.type_id);
}
