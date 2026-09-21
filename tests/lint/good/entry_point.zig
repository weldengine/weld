const std = @import("std");

// Entry points (`main`, `build`) are exempt.
pub fn main() void {}
pub fn build(b: *std.Build) void {
    _ = b;
}
