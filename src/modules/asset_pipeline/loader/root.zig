//! Asset Pipeline `loader/` namespace — async runtime loading + lifecycle.

/// Async runtime asset loader (file-as-type).
pub const Loader = @import("Loader.zig");

comptime {
    _ = Loader;
}
