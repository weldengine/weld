const std = @import("std");

// Generic function returning `type` — exempt per the brief's *Notes*.
pub fn Box(comptime T: type) type {
    return struct {
        value: T,
    };
}
