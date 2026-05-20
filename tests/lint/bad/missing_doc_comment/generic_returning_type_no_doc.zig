const std = @import("std");

// Generic function returning `type` — previously exempted by
// `isGenericReturningType`, now rejected: the type generator IS the
// API surface and the only place the docs can live.
pub fn Box(comptime T: type) type {
    return struct {
        value: T,
    };
}
