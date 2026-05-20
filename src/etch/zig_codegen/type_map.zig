//! Etch type → Zig type mapping for the S5 codegen.
//!
//! Type mapping is **fixed for S5 and Phase 0.2** per
//! `briefs/S5-etch-codegen-zig.md` Scope — "`int` → `i64`, `float` → `f64`,
//! `bool` → `bool`". Values in generated code are native Zig types, never
//! a `Value` tagged union on the hot path.
//!
//! The integer-family variants (`i32`, `u32`, `f32`, `f64`) are mapped to
//! themselves — the S3 type-checker only registers `int`/`float`/`bool` as
//! recognised builtin POD types for components (cf. `etch/types.zig`
//! `BuiltinType`), but the lexer accepts the wider names so we map them to
//! avoid surprises if a future Phase 0.2 widening reaches the codegen
//! before the type-checker is updated.

const std = @import("std");

pub const MapError = error{UnsupportedEtchType};

/// Alias for "the string the codegen will print as a Zig type" —
/// emitted verbatim into the cooked `.zig` output, no quoting.
pub const ZigTypeName = []const u8;

/// Return the Zig type name to emit for an Etch type identifier. The Etch
/// type identifier is the string written in the source (`int`, `float`,
/// `bool`, `i32`, `u32`, `f32`, `f64`, or a user-declared component name).
///
/// For user types (`Health`, `Position`, ...) the caller passes through the
/// original name — Etch component names map 1:1 to Zig struct names per the
/// brief's "Component / resource Etch declarations mapped 1:1 to `extern
/// struct` Zig declarations under matching names (no prefix)".
pub fn mapBuiltin(name: []const u8) ?ZigTypeName {
    if (std.mem.eql(u8, name, "int")) return "i64";
    if (std.mem.eql(u8, name, "float")) return "f64";
    if (std.mem.eql(u8, name, "bool")) return "bool";
    if (std.mem.eql(u8, name, "i32")) return "i32";
    if (std.mem.eql(u8, name, "u32")) return "u32";
    if (std.mem.eql(u8, name, "f32")) return "f32";
    if (std.mem.eql(u8, name, "f64")) return "f64";
    return null;
}

/// Zig literal suffix for a numeric default expression. Used when emitting
/// field defaults to avoid `error: comptime cast not allowed` between e.g.
/// `i64` and the literal type of `0`.
pub fn isFloatLikeZigType(name: []const u8) bool {
    return std.mem.eql(u8, name, "f32") or
        std.mem.eql(u8, name, "f64") or
        std.mem.eql(u8, name, "float");
}

/// Return `true` when the canonical Zig type name in `name` denotes
/// one of the integer primitives the codegen knows about — used when
/// emitting numeric literal defaults to pick the right cast / suffix.
pub fn isIntLikeZigType(name: []const u8) bool {
    return std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "int");
}

test "type mapping int=>i64 float=>f64 bool=>bool" {
    try std.testing.expectEqualStrings("i64", mapBuiltin("int").?);
    try std.testing.expectEqualStrings("f64", mapBuiltin("float").?);
    try std.testing.expectEqualStrings("bool", mapBuiltin("bool").?);
    // Wider-named primitives map to themselves.
    try std.testing.expectEqualStrings("i32", mapBuiltin("i32").?);
    try std.testing.expectEqualStrings("u32", mapBuiltin("u32").?);
    try std.testing.expectEqualStrings("f32", mapBuiltin("f32").?);
    try std.testing.expectEqualStrings("f64", mapBuiltin("f64").?);
    // User types are nullable through this helper.
    try std.testing.expect(mapBuiltin("Health") == null);
}

test "isFloatLikeZigType / isIntLikeZigType categorise numeric kinds" {
    try std.testing.expect(isFloatLikeZigType("f64"));
    try std.testing.expect(isFloatLikeZigType("float"));
    try std.testing.expect(!isFloatLikeZigType("i64"));
    try std.testing.expect(isIntLikeZigType("i64"));
    try std.testing.expect(isIntLikeZigType("int"));
    try std.testing.expect(!isIntLikeZigType("f64"));
}
