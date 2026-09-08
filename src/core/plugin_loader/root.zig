//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Public surface of the Tier 0 plugin loader: the C ABI types, the descriptor, the
//! stub API table and the loader itself.

const desc_mod = @import("desc.zig");
const api_mod = @import("api.zig");
const loader_mod = @import("loader.zig");

/// C ABI types + constants + plugin descriptor.
pub const desc = desc_mod;
/// WeldAPI table + 7 sub-APIs with stub implementations.
pub const api = api_mod;
/// Loader implementation wrapping `std.DynLib`.
pub const loader = loader_mod;

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
/// Stub API table the loader hands every plugin.
pub const stub_api = api_mod.stub_api;

comptime {
    // NOT dead code: these references are what make Zig analyse the sub-files, so
    // their inline `test` blocks are collected at all.
    _ = desc_mod;
    _ = api_mod;
    _ = loader_mod;
}
