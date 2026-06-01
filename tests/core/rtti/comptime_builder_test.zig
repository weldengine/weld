//! M0.2 / E1 — comptime builder tests.
//!
//! Coverage per `briefs/M0.2-rtti-resources-events-bindgen.md` E1
//! § Local acceptance criteria:
//!
//! 1. primitives map to the correct `FieldKind`
//! 2. nested struct resolves to `.nested_struct` + `nested_type_id`
//! 3. fixed-size array carries `count > 1`
//! 4. optional is encoded as `kind = .optional`
//! 5. enum is encoded as `kind = .enum_tag`
//! 6. POD validator rejects pointer fields
//!
//! Each test feeds the comptime builder a synthetic POD struct (no
//! `Position` / `Velocity` from the live ECS — those are untouched in
//! E1) and inspects the produced `TypeInfo` / `isPOD` predicate.

const std = @import("std");
const weld_core = @import("weld_core");

const rtti = weld_core.rtti;
const FieldKind = rtti.FieldKind;
const Category = rtti.Category;

test "primitives map to the correct FieldKind" {
    const Primitives = extern struct {
        flag: bool = false,
        small_u: u8 = 0,
        medium_u: u16 = 0,
        wide_u: u32 = 0,
        large_u: u64 = 0,
        small_i: i8 = 0,
        medium_i: i16 = 0,
        wide_i: i32 = 0,
        large_i: i64 = 0,
        f_single: f32 = 0,
        f_double: f64 = 0,
    };
    const info = comptime rtti.buildTypeInfo(Primitives, .component);
    try std.testing.expectEqual(@as(usize, 11), info.fields.len);

    const expected = [_]FieldKind{
        .bool, .u8,  .u16, .u32, .u64,
        .i8,   .i16, .i32, .i64, .f32,
        .f64,
    };
    for (info.fields, expected) |f, kind| {
        try std.testing.expectEqual(kind, f.kind);
        try std.testing.expectEqual(@as(u32, 1), f.count);
        try std.testing.expect(f.nested_type_id == null);
    }
}

test "engine composites map to their dedicated kinds" {
    const Composites = extern struct {
        v2: rtti.Vec2 = .{},
        v3: rtti.Vec3 = .{},
        v4: rtti.Vec4 = .{},
        q: rtti.Quat = .{},
        m3: rtti.Mat3 = .{},
        m4: rtti.Mat4 = .{},
        c: rtti.Color = .{},
        e: rtti.Entity = @enumFromInt(0),
        a: rtti.AssetHandle = @enumFromInt(0),
    };
    const info = comptime rtti.buildTypeInfo(Composites, .component);
    const expected = [_]FieldKind{
        .vec2, .vec3, .vec4, .quat, .mat3, .mat4, .color, .entity, .asset_handle,
    };
    try std.testing.expectEqual(expected.len, info.fields.len);
    for (info.fields, expected) |f, kind| {
        try std.testing.expectEqual(kind, f.kind);
    }
}

test "nested struct resolves via nested_type_id" {
    const Inner = extern struct {
        a: u32 = 0,
        b: u32 = 0,
    };
    const Outer = extern struct {
        head: u32 = 0,
        inner: Inner = .{},
    };
    const info_outer = comptime rtti.buildTypeInfo(Outer, .component);
    try std.testing.expectEqual(@as(usize, 2), info_outer.fields.len);

    const f_inner = info_outer.fields[1];
    try std.testing.expectEqual(FieldKind.nested_struct, f_inner.kind);
    try std.testing.expect(f_inner.nested_type_id != null);

    // The nested_type_id is the same as the standalone TypeId for Inner.
    const inner_id = comptime rtti.computeTypeId(Inner);
    try std.testing.expectEqual(inner_id, f_inner.nested_type_id.?);
}

test "fixed_array carries count > 1" {
    const Arrays = extern struct {
        bytes: [16]u8 = [_]u8{0} ** 16,
        floats: [4]f32 = .{ 0, 0, 0, 0 },
    };
    const info = comptime rtti.buildTypeInfo(Arrays, .component);
    try std.testing.expectEqual(@as(usize, 2), info.fields.len);

    const f0 = info.fields[0];
    try std.testing.expectEqual(FieldKind.fixed_array, f0.kind);
    try std.testing.expectEqual(@as(u32, 16), f0.count);

    const f1 = info.fields[1];
    try std.testing.expectEqual(FieldKind.fixed_array, f1.kind);
    try std.testing.expectEqual(@as(u32, 4), f1.count);
}

test "string_inline kicks in for sentinel-terminated u8 arrays" {
    const Tagged = struct {
        label: [16:0]u8 = [_:0]u8{0} ** 16,
    };
    const info = comptime rtti.buildTypeInfo(Tagged, .message);
    try std.testing.expectEqual(@as(usize, 1), info.fields.len);
    try std.testing.expectEqual(FieldKind.string_inline, info.fields[0].kind);
    try std.testing.expectEqual(@as(u32, 16), info.fields[0].count);
}

test "optional is encoded as kind = .optional" {
    const Container = struct {
        maybe_id: ?u32 = null,
    };
    const info = comptime rtti.buildTypeInfo(Container, .component);
    try std.testing.expectEqual(@as(usize, 1), info.fields.len);
    try std.testing.expectEqual(FieldKind.optional, info.fields[0].kind);
}

test "enum is encoded as kind = .enum_tag" {
    const Mode = enum(u8) { idle, walking, running };
    const HasEnum = extern struct {
        state: Mode = .idle,
    };
    const info = comptime rtti.buildTypeInfo(HasEnum, .component);
    try std.testing.expectEqual(@as(usize, 1), info.fields.len);
    try std.testing.expectEqual(FieldKind.enum_tag, info.fields[0].kind);
}

test "isPOD rejects pointer-bearing structs (would @compileError via buildTypeInfo)" {
    // Brief E1 §criterion 6: "pointer field produces compileError
    // (verified via @compileError detected at test build)". We test
    // the underlying `isPOD` predicate that gates the compile error,
    // so the negative path can be exercised without breaking the test
    // target's own compilation. The compile-error path itself is
    // unconditional inside `buildTypeInfo` — see comptime_builder.zig
    // top of `buildTypeInfo`.
    const Bad = struct { ptr: *u32 };
    try std.testing.expect(!rtti.isPOD(Bad));

    const BadSlice = struct { data: []const u8 };
    try std.testing.expect(!rtti.isPOD(BadSlice));

    const BadErrUnion = struct { v: anyerror!u32 };
    try std.testing.expect(!rtti.isPOD(BadErrUnion));

    const Good = struct { x: f32, y: f32 };
    try std.testing.expect(rtti.isPOD(Good));
}

test "lifecycle defaults to .transient for resources, null otherwise" {
    // Contract updated by M0.2 / E3 (cf. brief § Notes — technical
    // decision E3 / lifecycle inference). `buildTypeInfo` reads
    // `T.lifecycle` if declared, otherwise defaults to `.transient`
    // for the `.resource` category and leaves the field null for
    // every other category.
    const Res = extern struct { tick: u64 = 0 };
    const info_res = comptime rtti.buildTypeInfo(Res, .resource);
    try std.testing.expectEqual(rtti.Category.resource, info_res.category);
    try std.testing.expect(info_res.lifecycle != null);
    try std.testing.expectEqual(rtti.Lifecycle.transient, info_res.lifecycle.?);

    const info_comp = comptime rtti.buildTypeInfo(Res, .component);
    try std.testing.expect(info_comp.lifecycle == null);
}
