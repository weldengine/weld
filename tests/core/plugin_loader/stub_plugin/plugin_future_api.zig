//! M0.2 / E6 — stub plugin variant claiming a future API version.
//!
//! Exports `weld_plugin_entry` exactly like the happy-path stub
//! but with `api_version_min = 99`, well above the runtime's
//! current `WELD_API_VERSION_MAJOR = 0`. Used by
//! `tests/core/plugin_loader/load_unload_test.zig` to assert
//! `Loader.loadPlugin` returns `error.ApiVersionTooNew`.

const std = @import("std");
const abi = @import("weld_plugin_abi");

const WeldPluginDesc = abi.WeldPluginDesc;

const stub_name_bytes: []const u8 = "stub_future_api";
const stub_version_bytes: []const u8 = "0.0.1";

const stub_desc: WeldPluginDesc = .{
    .name = .{ .ptr = stub_name_bytes.ptr, .len = stub_name_bytes.len },
    .display_name = .{ .ptr = stub_name_bytes.ptr, .len = stub_name_bytes.len },
    .version = .{ .ptr = stub_version_bytes.ptr, .len = stub_version_bytes.len },
    .api_version_min = 99, // intentionally too new
    .caps = .{},
    .callbacks = .{},
};

export fn weld_plugin_entry(api: *const anyopaque) callconv(.c) *const WeldPluginDesc {
    _ = api;
    return &stub_desc;
}
