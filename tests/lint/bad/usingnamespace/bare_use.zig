const std = @import("std");

/// In Zig 0.16 `usingnamespace` is no longer a keyword, so we use it
/// as a regular identifier to keep `zig fmt --check` happy while
/// still triggering the `no_usingnamespace` rule.
pub const usingnamespace = 1;
