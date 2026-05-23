//! Public surface of the M0.2 / E6 plugin loader skeleton.
//!
//! Tier 0 component that loads Tier 3 plugin shared libraries
//! (.so / .dll / .dylib), reads their `WeldPluginDesc`, and
//! exposes the `WeldAPI` table. All 7 sub-APIs are present with
//! final signatures but every callback returns
//! `WELD_ERR_NOT_IMPLEMENTED` — the runtime wiring is Phase 3
//! (cf. brief § Out-of-scope).
//!
//! Module convention follows `src/core/ecs/root.zig`,
//! `src/core/rtti/root.zig`, `src/core/resources/root.zig`,
//! `src/core/events/root.zig` — single canonical entry point.

const desc_mod = @import("desc.zig");
const api_mod = @import("api.zig");
const loader_mod = @import("loader.zig");

// -- Sub-module aliases ------------------------------------------------

/// C ABI types + constants + plugin descriptor.
pub const desc = desc_mod;
/// WeldAPI table + 7 sub-APIs with stub implementations.
pub const api = api_mod;
/// Loader implementation wrapping `std.DynLib`.
pub const loader = loader_mod;

// -- Flat type surface (most-frequently used) -------------------------

/// Loader registry.
pub const Loader = loader_mod.Loader;
/// Plugin handle returned by `loadPlugin`.
pub const PluginHandle = loader_mod.PluginHandle;
/// Loader error set.
pub const LoaderError = loader_mod.LoaderError;
/// Plugin descriptor returned by `weld_plugin_entry`.
pub const WeldPluginDesc = desc_mod.WeldPluginDesc;
/// Plugin lifecycle callbacks.
pub const WeldPluginCallbacks = desc_mod.WeldPluginCallbacks;
/// Plugin capability declarations.
pub const WeldPluginCaps = desc_mod.WeldPluginCaps;
/// Public Tier 3 API table.
pub const WeldAPI = api_mod.WeldAPI;
/// Result code surfaced by every `WeldResult`-returning callback.
pub const WeldResult = desc_mod.WeldResult;
/// `WELD_API_VERSION_MAJOR` constant.
pub const WELD_API_VERSION_MAJOR = desc_mod.WELD_API_VERSION_MAJOR;
/// `WELD_API_VERSION_MINOR` constant.
pub const WELD_API_VERSION_MINOR = desc_mod.WELD_API_VERSION_MINOR;
/// Stub API singleton — what the loader passes to every plugin
/// in M0.2. The 7 sub-APIs all return `WELD_ERR_NOT_IMPLEMENTED`.
pub const stub_api = api_mod.stub_api;

comptime {
    // Lazy-analysis guard — force eager analysis of every plugin
    // loader sub-file so inline tests are picked up by
    // `zig build test`.
    _ = desc_mod;
    _ = api_mod;
    _ = loader_mod;
}
