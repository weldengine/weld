const std = @import("std");

/// Identifier `usingnamespace` appears inside a function body — also
/// rejected.
pub fn doStuff() void {
    const usingnamespace: u32 = 1;
    _ = usingnamespace;
}
