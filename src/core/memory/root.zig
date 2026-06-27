//! Public surface of the Tier-0 `memory` submodule (re-exported from `weld_core`
//! as `weld_core.memory`). Owns the refcounted persistent heap used for non-POD
//! resource fields (`persistent.zig`) — consumed by the scene loader and, via
//! `weld_core`, by the Etch runtime (interp / bridge / cook).

/// Refcounted, system-allocator-backed persistent heap: `StringSlot`, `TypeId`,
/// `alloc`/`allocImmortal`/`incref`/`decref`/`destroy`.
pub const persistent = @import("persistent.zig");

comptime {
    // §13 lazy-analysis guard: pin the sub-file so its inline `test` blocks run
    // under the `core_tests` target (`engine-zig-conventions.md` §13).
    _ = persistent;
}
