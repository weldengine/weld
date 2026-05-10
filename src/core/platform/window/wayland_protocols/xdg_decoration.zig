//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-wayland`.
//!
//! Wayland protocol `xdg_decoration_unstable_v1` bindings emitted from upstream XML.
//! Throwaway: S3 unifier replaces this generator.

const core = @import("core.zig");
const WlInterface = core.WlInterface;
const WlMessage = core.WlMessage;
const xdg_shell = @import("xdg_shell.zig");

// ---- zxdg_decoration_manager_v1 (v2) ----

pub const zxdg_decoration_manager_v1 = opaque {};

pub const zxdg_decoration_manager_v1_request = struct {
    pub const destroy: u32 = 0;
    pub const get_toplevel_decoration: u32 = 1;
};

const zxdg_decoration_manager_v1_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel_decoration", .signature = "no", .types = null },
};

pub const zxdg_decoration_manager_v1_interface = WlInterface{
    .name = "zxdg_decoration_manager_v1",
    .version = 2,
    .method_count = 2,
    .methods = &zxdg_decoration_manager_v1_requests,
    .event_count = 0,
    .events = null,
};

// ---- zxdg_toplevel_decoration_v1 (v2) ----

pub const zxdg_toplevel_decoration_v1 = opaque {};

pub const zxdg_toplevel_decoration_v1_error = enum(u32) {
    unconfigured_buffer = 0,
    already_constructed = 1,
    orphaned = 2,
    invalid_mode = 3,
    _,
};

pub const zxdg_toplevel_decoration_v1_mode = enum(u32) {
    client_side = 1,
    server_side = 2,
    _,
};

pub const zxdg_toplevel_decoration_v1_request = struct {
    pub const destroy: u32 = 0;
    pub const set_mode: u32 = 1;
    pub const unset_mode: u32 = 2;
};

pub const zxdg_toplevel_decoration_v1_event = struct {
    pub const configure: u32 = 0;
};

pub const zxdg_toplevel_decoration_v1_listener = extern struct {
    configure: *const fn (data: ?*anyopaque, proxy: *zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void,
};

const zxdg_toplevel_decoration_v1_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_mode", .signature = "u", .types = null },
    .{ .name = "unset_mode", .signature = "", .types = null },
};

const zxdg_toplevel_decoration_v1_events = [_]WlMessage{
    .{ .name = "configure", .signature = "u", .types = null },
};

pub const zxdg_toplevel_decoration_v1_interface = WlInterface{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 2,
    .method_count = 3,
    .methods = &zxdg_toplevel_decoration_v1_requests,
    .event_count = 1,
    .events = &zxdg_toplevel_decoration_v1_events,
};
