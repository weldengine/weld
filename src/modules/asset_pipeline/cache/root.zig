//! Asset Pipeline `cache/` namespace — local cooking cache.

const cache_mod = @import("cache.zig");

/// Directory-backed cooking cache.
pub const Cache = cache_mod.Cache;
/// Compute the cooking-cache key from the cook inputs.
pub const computeKey = cache_mod.computeKey;

comptime {
    _ = cache_mod;
}
