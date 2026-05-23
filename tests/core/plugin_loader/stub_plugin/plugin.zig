//! M0.2 / E6 — stub plugin for the load/unload tests.
//!
//! Built as a dynamic library (`.so` / `.dll` / `.dylib`) that
//! exports a single C symbol `weld_plugin_entry`. The stub returns
//! a static `WeldPluginDesc` with `name = "stub"`,
//! `version = "0.0.1"`, `api_version_min = 0`, no callbacks, no
//! capabilities. Used by `tests/core/plugin_loader/load_unload_test.zig`
//! to exercise the loader's happy path.
//!
//! Types are imported from `src/core/plugin_loader/desc.zig` via
//! the `weld_plugin_abi` module declared in the main `build.zig`
//! (decision Cas 3 — import croisé, cf. brief § Notes).

const std = @import("std");
const abi = @import("weld_plugin_abi");

const WeldPluginDesc = abi.WeldPluginDesc;
const WeldStr = abi.WeldStr;

// Static storage for the descriptor's strings — must outlive the
// `WeldPluginDesc` returned to the loader.
const stub_name_bytes: []const u8 = "stub";
const stub_display_name_bytes: []const u8 = "Stub Plugin";
const stub_version_bytes: []const u8 = "0.0.1";

const stub_desc: WeldPluginDesc = .{
    .name = .{ .ptr = stub_name_bytes.ptr, .len = stub_name_bytes.len },
    .display_name = .{ .ptr = stub_display_name_bytes.ptr, .len = stub_display_name_bytes.len },
    .version = .{ .ptr = stub_version_bytes.ptr, .len = stub_version_bytes.len },
    .api_version_min = 0,
    .caps = .{},
    .callbacks = .{},
};

/// Unique exported symbol — resolved by `Loader.loadPlugin` via
/// `dlsym("weld_plugin_entry")`. Receives the runtime's API table
/// (cast to `*const anyopaque` at the ABI boundary, cf.
/// `desc.WeldPluginEntryFn`) and returns a pointer to a static
/// `WeldPluginDesc` describing the plugin.
export fn weld_plugin_entry(api: *const anyopaque) callconv(.c) *const WeldPluginDesc {
    _ = api;
    return &stub_desc;
}
