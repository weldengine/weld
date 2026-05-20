const std = @import("std");

/// Calls @cImport inside a function body — must still be rejected.
pub fn loadHeader() void {
    const c = @cImport(@cInclude("math.h"));
    _ = c;
}
