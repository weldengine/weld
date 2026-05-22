//! Comptime builder — turns a Zig type into a `TypeInfo` record.
//!
//! `buildTypeInfo(comptime T: type, category: Category) TypeInfo` is
//! the public entry point. It traverses `T`'s declared fields, maps
//! each one to a `FieldKind`, validates POD (every field is a value
//! type — no pointers, no runtime slices, no error unions, no frames),
//! computes the `type_id` / `schema_hash`, and produces the
//! `TypeInfo` record in static comptime memory.
//!
//! `isPOD(comptime T: type) bool` is the POD predicate exposed for
//! testing: callers that want to verify the negative path
//! (non-POD types are rejected) can probe it without triggering the
//! `@compileError` that `buildTypeInfo` emits.
//!
//! POD rules — only the following Zig type kinds are allowed:
//!   - `bool`, `int`, `float`
//!   - `enum` (exhaustive or non-exhaustive)
//!   - `array` (all variants — sentinel-terminated → `string_inline`
//!      when child is `u8`, plain → `fixed_array`)
//!   - `optional` (child must also be POD)
//!   - `struct` (every field must be POD)
//!
//! Anything else — pointer, runtime slice (`.pointer` with size
//! `.slice`), error set, error union, anyframe, frame, function, vector
//! that does not match an engine composite — is rejected with
//! `@compileError`.

const std = @import("std");
const type_info = @import("type_info.zig");
const hash = @import("hash.zig");

const TypeId = type_info.TypeId;
const SchemaHash = type_info.SchemaHash;
const Category = type_info.Category;
const Lifecycle = type_info.Lifecycle;
const FieldKind = type_info.FieldKind;
const FieldDesc = type_info.FieldDesc;
const TypeInfo = type_info.TypeInfo;

const Vec2 = type_info.Vec2;
const Vec3 = type_info.Vec3;
const Vec4 = type_info.Vec4;
const Quat = type_info.Quat;
const Mat3 = type_info.Mat3;
const Mat4 = type_info.Mat4;
const Color = type_info.Color;
const Entity = type_info.Entity;
const AssetHandle = type_info.AssetHandle;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Builds the full `TypeInfo` record for `T` at comptime. The returned
/// value's `fields` slice points to a static comptime-promoted array;
/// callers can store the `TypeInfo` by value and the slice remains
/// valid for the lifetime of the binary.
///
/// When `category == .resource`, the `lifecycle` field is populated by
/// `inferLifecycle(T)` — reads the `pub const lifecycle: Lifecycle`
/// declaration if present, otherwise defaults to `.transient` (M0.2 /
/// E3 decision, cf. brief § Notes). For other categories,
/// `lifecycle` is `null`.
pub fn buildTypeInfo(comptime T: type, comptime category: Category) TypeInfo {
    comptime {
        if (!isPOD(T)) {
            @compileError("buildTypeInfo: type " ++ @typeName(T) ++ " is not POD (contains pointers, slices, error unions, or other non-POD members)");
        }
        const fields = buildFields(T);
        return TypeInfo{
            .type_id = hash.computeTypeId(T),
            .type_name = @typeName(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .schema_hash = hash.computeSchemaHashFromParts(@typeName(T), fields),
            .fields = fields,
            .category = category,
            .lifecycle = inferLifecycle(T, category),
        };
    }
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Reads the resource lifecycle for `T` at comptime. Returns `null`
/// for categories other than `.resource`. For resources, returns the
/// `T.lifecycle` declaration when present, otherwise `.transient` as
/// the safe default (least-durable lifecycle).
pub fn inferLifecycle(comptime T: type, comptime category: Category) ?Lifecycle {
    comptime {
        if (category != .resource) return null;
        if (@hasDecl(T, "lifecycle")) {
            const declared = T.lifecycle;
            if (@TypeOf(declared) != Lifecycle) {
                @compileError(
                    "inferLifecycle: '" ++ @typeName(T) ++
                        ".lifecycle' must be of type Lifecycle, got " ++
                        @typeName(@TypeOf(declared)),
                );
            }
            return declared;
        }
        return .transient;
    }
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Builds the per-field metadata slice for `T`. Comptime-only — the
/// returned slice points to a comptime-promoted array.
pub fn buildFields(comptime T: type) []const FieldDesc {
    comptime {
        const info = @typeInfo(T);
        const struct_info = switch (info) {
            .@"struct" => |s| s,
            else => @compileError("buildFields: expected struct, got " ++ @typeName(T) ++ " (" ++ @tagName(info) ++ ")"),
        };
        var out: [struct_info.fields.len]FieldDesc = undefined;
        for (struct_info.fields, 0..) |f, i| {
            out[i] = describeField(T, f.name, f.type);
        }
        const final = out;
        return &final;
    }
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Maps a Zig type to its concrete `FieldKind`. Comptime-only.
pub fn classifyField(comptime T: type) FieldKind {
    comptime {
        // Engine-canonical composites first — type identity beats
        // structural shape so `Vec3` does not fall through to
        // `.nested_struct`.
        if (T == Vec2) return .vec2;
        if (T == Vec3) return .vec3;
        if (T == Vec4) return .vec4;
        if (T == Quat) return .quat;
        if (T == Mat3) return .mat3;
        if (T == Mat4) return .mat4;
        if (T == Color) return .color;
        if (T == Entity) return .entity;
        if (T == AssetHandle) return .asset_handle;

        return switch (@typeInfo(T)) {
            .bool => .bool,
            .int => |int| switch (int.signedness) {
                .unsigned => switch (int.bits) {
                    8 => .u8,
                    16 => .u16,
                    32 => .u32,
                    64 => .u64,
                    else => @compileError("classifyField: unsupported unsigned int width " ++ @typeName(T)),
                },
                .signed => switch (int.bits) {
                    8 => .i8,
                    16 => .i16,
                    32 => .i32,
                    64 => .i64,
                    else => @compileError("classifyField: unsupported signed int width " ++ @typeName(T)),
                },
            },
            .float => |fl| switch (fl.bits) {
                32 => .f32,
                64 => .f64,
                else => @compileError("classifyField: unsupported float width " ++ @typeName(T)),
            },
            .@"enum" => .enum_tag,
            .array => |a| if (a.child == u8 and a.sentinel_ptr != null)
                .string_inline
            else
                .fixed_array,
            .optional => .optional,
            .@"struct" => .nested_struct,
            else => @compileError("classifyField: unsupported type kind " ++ @typeName(T) ++ " (" ++ @tagName(@typeInfo(T)) ++ ")"),
        };
    }
}

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Returns `true` iff every transitive member of `T` is a value type
/// usable in `extern struct`-style POD layouts: `bool` / `int` /
/// `float` / `enum` / engine composite / `array` / `optional` / nested
/// `struct` whose fields are all POD. Used by `buildTypeInfo` to gate
/// the `@compileError` and by tests to probe the negative path.
///
/// `inline` so that runtime call sites (e.g. tests asserting the
/// negative path) fold the comptime-only operations on `T` at the
/// caller instead of trying to emit a runtime body for a function
/// whose internals only exist at comptime.
pub inline fn isPOD(comptime T: type) bool {
    // Engine composites are POD by construction — short-circuit
    // before we recurse into their layout.
    if (T == Vec2 or T == Vec3 or T == Vec4 or T == Quat) return true;
    if (T == Mat3 or T == Mat4 or T == Color) return true;
    if (T == Entity or T == AssetHandle) return true;

    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .void, .noreturn, .undefined, .null => false,
        .array => |a| isPOD(a.child),
        .optional => |o| isPOD(o.child),
        .@"struct" => |s| podStructFields(s.fields),
        // Explicit reject list — keep it noisy so future Zig type
        // kinds surface here rather than silently passing.
        .pointer, .error_union, .error_set => false,
        .@"fn", .@"opaque", .frame, .@"anyframe" => false,
        .vector => false,
        .comptime_int, .comptime_float, .type, .enum_literal => false,
        .@"union" => false, // raw unions reserved for future tagged-union path
    };
}

inline fn podStructFields(comptime fields: anytype) bool {
    return comptime blk: {
        for (fields) |f| {
            if (!isPOD(f.type)) break :blk false;
        }
        break :blk true;
    };
}

fn describeField(comptime Parent: type, comptime field_name: []const u8, comptime FieldType: type) FieldDesc {
    comptime {
        const kind = classifyField(FieldType);
        var count: u32 = 1;
        var nested: ?TypeId = null;
        switch (@typeInfo(FieldType)) {
            .array => |a| {
                count = @intCast(a.len);
                // For arrays whose element is a user-defined type
                // (struct or enum), record the element's TypeId so
                // consumers can chase the layout. Skip for primitives.
                const child_info = @typeInfo(a.child);
                if (child_info == .@"struct" or child_info == .@"enum") {
                    nested = hash.computeTypeId(a.child);
                }
            },
            .optional => |o| {
                const child_info = @typeInfo(o.child);
                if (child_info == .@"struct" or child_info == .@"enum") {
                    nested = hash.computeTypeId(o.child);
                }
            },
            .@"struct" => {
                // Composites (Vec3 etc.) are caught above and never
                // hit this branch because their kind is dedicated.
                // Plain nested structs record their TypeId so the
                // round-trip can recurse.
                nested = hash.computeTypeId(FieldType);
            },
            else => {},
        }

        return FieldDesc{
            .name = field_name,
            .offset = @intCast(@offsetOf(Parent, field_name)),
            .size = @sizeOf(FieldType),
            .alignment = @alignOf(FieldType),
            .kind = kind,
            .count = count,
            .nested_type_id = nested,
            .unit = "",
        };
    }
}

// ---------------------------------------------------------------- tests --

test "buildFields on a simple POD struct" {
    const Position = extern struct {
        x: f32 = 0,
        y: f32 = 0,
        z: f32 = 0,
    };
    const fields = comptime buildFields(Position);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqual(FieldKind.f32, fields[0].kind);
    try std.testing.expectEqual(@as(u32, 0), fields[0].offset);
    try std.testing.expectEqual(@as(u32, 4), fields[0].size);
    try std.testing.expectEqual(@as(u32, 1), fields[0].count);
    try std.testing.expect(fields[0].nested_type_id == null);
}

test "buildTypeInfo populates schema_hash and type_id" {
    const Health = extern struct {
        current: f32 = 100,
        max: f32 = 100,
    };
    const info = comptime buildTypeInfo(Health, .component);
    try std.testing.expectEqual(Category.component, info.category);
    try std.testing.expect(info.type_id != 0);
    try std.testing.expect(info.schema_hash != 0);
    try std.testing.expectEqual(@as(usize, 2), info.fields.len);
    try std.testing.expect(info.lifecycle == null);
}

test "isPOD accepts plain primitives and structs" {
    const Inner = extern struct { a: u32 = 0, b: f64 = 0 };
    const Outer = extern struct { inner: Inner = .{}, count: u16 = 0 };
    try std.testing.expect(isPOD(Inner));
    try std.testing.expect(isPOD(Outer));
}

test "isPOD rejects pointer fields" {
    const Bad = struct { ptr: *u32 };
    try std.testing.expect(!isPOD(Bad));
}

test "isPOD rejects runtime slice fields" {
    const Bad = struct { slice: []const u8 };
    try std.testing.expect(!isPOD(Bad));
}
