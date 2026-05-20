const std = @import("std");

/// Documented re-export — passes under the strict doc_comments rule.
pub const ArrayList = std.ArrayList;
/// Documented module re-export via `@import`.
pub const mem = std.mem;

/// Documented type-alias literal — composed of three primitives.
pub const Point = struct { x: i32, y: i32 };
/// Documented enum type alias.
pub const Color = enum { red, green, blue };
/// Documented error-set type alias.
pub const MyError = error{ Foo, Bar };

/// Documented generic function returning `type` — the docs live here
/// because the returned anonymous struct has nowhere else to host them.
pub fn Box(comptime T: type) type {
    return struct {
        value: T,
    };
}
