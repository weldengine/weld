//! Public surface of the Tier-0 `scene` submodule (re-exported from
//! `weld_core` as `weld_core.scene`). Owns the `.scene.bin` format: the neutral
//! cook model + on-disk format contract (`format.zig`), the byte writer
//! (`writer.zig`, E2) and the zero-copy accessor (`accessor.zig`, E2 — reused
//! verbatim by the M1.0.5 loader).
//!
//! **Imports `weld_core` internals only — never `weld_etch`** (tier discipline,
//! `engine-spec.md` §3.5 / the M1.0.4 brief Notes). The Etch coupling
//! (descriptors, const-eval, `writeValueAsBytes`) lives in
//! `src/etch/scene_cook.zig`, which consumes this surface.

/// `.scene.bin` format contract + the neutral cook model (`CookModel`).
pub const format = @import("format.zig");

comptime {
    // §13 lazy-analysis guard: pin every sub-file carrying inline `test` blocks
    // so they run under the `core_tests` target (`engine-zig-conventions.md`
    // §13). `writer`/`accessor` join here in E2.
    _ = format;
}
