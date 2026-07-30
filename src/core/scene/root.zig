//! Public surface of the Tier-0 `scene` submodule (re-exported from
//! `weld_core` as `weld_core.scene`). Owns the `.scene.bin` format: the neutral
//! cook model + on-disk format contract (`format.zig`), the byte writer
//! (`writer.zig`, E2) and the zero-copy accessor (`accessor.zig`, E2 — reused
//! verbatim by the M1.0.5 loader).
//!
//! **Imports `weld_core` internals only — never `weld_etch`** (tier discipline,
//! `ARCH-017` / the M1.0.4 brief Notes). The Etch coupling
//! (descriptors, const-eval, `writeValueAsBytes`) lives in
//! `src/etch/scene_cook.zig`, which consumes this surface.

/// `.scene.bin` format contract + the neutral cook model (`CookModel`).
pub const format = @import("format.zig");
/// `.scene.bin` byte writer: `format.CookModel` → on-disk bytes.
pub const writer = @import("writer.zig");
/// `.scene.bin` zero-copy accessor (read half; reused verbatim by M1.0.5).
pub const accessor = @import("accessor.zig");
/// `.scene.bin` structural validator (M1.1.1-HF3 / R1): a standalone pre-flight
/// that walks the raw bytes and backs every accessor getter's trusted invariant.
/// `loader.openVerified` runs it before returning an `Accessor`.
pub const validate = @import("validate.zig");
/// `.scene.bin` runtime loader (M1.0.5): reads a cooked scene back into a live
/// ECS `World`, reusing `accessor` verbatim. `weld_core` only — never `weld_etch`.
pub const loader = @import("loader.zig");

comptime {
    // §13 lazy-analysis guard: pin every sub-file carrying inline `test` blocks
    // so they run under the `core_tests` target (`engine-zig-conventions.md` §13).
    _ = format;
    _ = writer;
    _ = accessor;
    _ = validate;
    _ = loader;
}
