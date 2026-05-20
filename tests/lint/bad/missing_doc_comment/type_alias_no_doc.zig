const std = @import("std");

// Type-alias literals — previously exempted by `isTypeAlias`, now
// rejected: ECS components live on this exact shape and the brief is
// explicit that they need docs (cf. `engine-zig-conventions.md §16`).
pub const Point = struct { x: i32, y: i32 };
pub const Color = enum { red, green, blue };
pub const Maybe = union { tag: u8, payload: u32 };
pub const Opaque = opaque {};
pub const MyError = error{ Foo, Bar };
