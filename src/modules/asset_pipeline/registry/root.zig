//! Asset Pipeline `registry/` namespace — the `AssetHandle` and the slot
//! `Registry` that tracks handle allocation, refcount, and generation
//! invalidation on unload.

const asset_handle = @import("asset_handle.zig");

/// 64-bit typed, generation-checked asset reference.
pub const AssetHandle = asset_handle.AssetHandle;

/// Slot registry (refcount + generation invalidation). File-as-type.
pub const Registry = @import("Registry.zig");

// Pins so the inline tests of every sub-file are analysed
// (engine-zig-conventions.md §13 module-rooting guard).
comptime {
    _ = asset_handle;
    _ = Registry;
}
