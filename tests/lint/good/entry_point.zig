const std = @import("std");

// Entry points (main, build) are exempt per the brief's *Notes*.
pub fn main() void {}
pub fn build(b: *std.Build) void {
    _ = b;
}
