const std = @import("std");

/// First occurrence of the identifier `usingnamespace` — must be
/// flagged by no_usingnamespace.
pub const usingnamespace = 1;

/// Second occurrence further down — must also be flagged.
pub const offset = blk: {
    const x: u32 = usingnamespace;
    break :blk x;
};
