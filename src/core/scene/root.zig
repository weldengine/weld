//! Public surface of the Tier 0 `scene` submodule: the on-disk format, the writer,
//! the zero-copy accessor, the structural validator and the runtime loader.

/// `.scene.bin` format contract + the neutral cook model (`CookModel`).
pub const format = @import("format.zig");
/// `.scene.bin` byte writer: `format.CookModel` → on-disk bytes.
pub const writer = @import("writer.zig");
/// `.scene.bin` zero-copy accessor (read half; reused verbatim by ).
pub const accessor = @import("accessor.zig");
/// Structural validator, run before any accessor getter is trusted.
pub const validate = @import("validate.zig");
/// Runtime loader: a cooked byte image into a `World`.
pub const loader = @import("loader.zig");

comptime {
    // NOT dead code: these references are what make Zig analyse the sub-files, so
    // their inline `test` blocks are collected at all.
    _ = format;
    _ = writer;
    _ = accessor;
    _ = validate;
    _ = loader;
}
