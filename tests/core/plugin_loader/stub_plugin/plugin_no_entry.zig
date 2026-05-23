//! M0.2 / E6 — stub plugin variant that does NOT export
//! `weld_plugin_entry`.
//!
//! Used by `tests/core/plugin_loader/load_unload_test.zig` to
//! assert `Loader.loadPlugin` returns `error.MissingEntryPoint`
//! when the symbol is absent.

/// Bogus exported symbol — present so the library is non-empty
/// and links cleanly. Not used by anything.
export fn weld_plugin_decoy() callconv(.c) u32 {
    return 0;
}
