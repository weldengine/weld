//! Etch type → Zig type mapping for the codegen.
//!
//! The mapping is FIXED: `int` → `i64`, `float` → `f64`, `bool` → `bool`.
//! Values in generated code are native Zig types, never a `Value` tagged
//! union on the hot path.
//!
//! The integer-family names (`i32`, `u32`, `f32`, `f64`) map to themselves. The
//! type-checker registers only `int`/`float`/`bool` as builtin POD component
//! types, but the lexer accepts the wider names, so mapping them keeps a later
//! widening from reaching the codegen before the checker knows about it.

const std = @import("std");

/// Error variant returned when an Etch type identifier has no Zig
/// equivalent in the codegen's mapping table.
pub const MapError = error{UnsupportedEtchType};

/// Alias for "the string the codegen will print as a Zig type" —
/// emitted verbatim into the cooked `.zig` output, no quoting.
pub const ZigTypeName = []const u8;

/// The Zig type name to emit for an Etch type identifier — the string written
/// in the source. `null` for a user-declared name, which the caller passes
/// through unchanged: an Etch component maps 1:1 to an `extern struct` of the
/// same name, with no prefix.
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

/// Whether `name` denotes a float primitive. Read when emitting a field's
/// default so the literal is cast, avoiding `comptime cast not allowed`.
pub fn isFloatLikeZigType(name: []const u8) bool {
    return std.mem.eql(u8, name, "f32") or
        std.mem.eql(u8, name, "f64") or
        std.mem.eql(u8, name, "float");
}

/// Whether `name` denotes an integer primitive the codegen knows. Same use as
/// `isFloatLikeZigType`: picking the cast for a numeric literal default.
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
    try std.testing.expectEqualStrings("i32", mapBuiltin("i32").?);
    try std.testing.expectEqualStrings("u32", mapBuiltin("u32").?);
    try std.testing.expectEqualStrings("f32", mapBuiltin("f32").?);
    try std.testing.expectEqualStrings("f64", mapBuiltin("f64").?);
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
