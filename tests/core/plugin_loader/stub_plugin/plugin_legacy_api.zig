//! Stub plugin variant built against a superseded API major.
//!
//! Exports `weld_plugin_entry` exactly like the happy-path stub but with
//! `api_version_min = 0`, below the runtime's current
//! `WELD_API_VERSION_MAJOR`. Used by
//! `tests/core/plugin_loader/load_unload_test.zig` to assert
//! `Loader.loadPlugin` returns `error.ApiVersionTooOld`.
//!
//! It is the twin of the too-new stub, and it exists because the refusal it
//! exercises was UNREACHABLE while the major was 0: nothing can be older than
//! the first major, so the loader's one-sided check looked complete. The
//! increment is what gave the second direction a witness.

const std = @import("std");
const abi = @import("weld_plugin_abi");

const WeldPluginDesc = abi.WeldPluginDesc;

const stub_name_bytes: []const u8 = "stub_legacy_api";
const stub_version_bytes: []const u8 = "0.0.1";

const stub_desc: WeldPluginDesc = .{
    .name = .{ .ptr = stub_name_bytes.ptr, .len = stub_name_bytes.len },
    .display_name = .{ .ptr = stub_name_bytes.ptr, .len = stub_name_bytes.len },
    .version = .{ .ptr = stub_version_bytes.ptr, .len = stub_version_bytes.len },
    .api_version_min = 0, // intentionally superseded
    .caps = .{},
    .callbacks = .{},
};

export fn weld_plugin_entry(api: *const anyopaque) callconv(.c) *const WeldPluginDesc {
    _ = api;
    return &stub_desc;
}
