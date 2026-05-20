const std = @import("std");

// Type-alias initialisers (struct / enum / union / opaque / error
// literals) are exempt per the brief's *Notes*.
pub const Point = struct { x: i32, y: i32 };
pub const Color = enum { red, green, blue };
pub const Maybe = union { tag: u8, payload: u32 };
pub const Opaque = opaque {};
pub const MyError = error{ Foo, Bar };
