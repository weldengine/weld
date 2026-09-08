//! Public surface of the Tier 0 `memory` submodule: the refcounted persistent heap
//! for non-POD resource fields, consumed by the scene loader and the Etch runtime.

/// Refcounted, system-allocator-backed persistent heap.
pub const persistent = @import("persistent.zig");

comptime {
    // NOT dead code: this reference is what makes Zig analyse the sub-file, so its
    // inline `test` blocks are collected at all.
    _ = persistent;
}
