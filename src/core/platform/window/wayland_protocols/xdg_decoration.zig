//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-wayland`.
//!
//! Wayland protocol `xdg_decoration_unstable_v1` bindings emitted from upstream XML.
//! Throwaway: S3 unifier replaces this generator.

const std = @import("std");
const core = @import("core.zig");
const WlInterface = core.WlInterface;
const WlMessage = core.WlMessage;
const xdg_shell = @import("xdg_shell.zig");

// ---- zxdg_decoration_manager_v1 (v2) ----

pub const zxdg_decoration_manager_v1_request = struct {
    pub const destroy: u32 = 0;
    pub const get_toplevel_decoration: u32 = 1;
};

const zxdg_decoration_manager_v1_get_toplevel_decoration_types: [2]?*const WlInterface = .{
    &zxdg_toplevel_decoration_v1_interface,
    &xdg_shell.xdg_toplevel_interface,
};

const zxdg_decoration_manager_v1_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel_decoration", .signature = "no", .types = &zxdg_decoration_manager_v1_get_toplevel_decoration_types },
};

pub const zxdg_decoration_manager_v1_interface = WlInterface{
    .name = "zxdg_decoration_manager_v1",
    .version = 2,
    .method_count = 2,
    .methods = &zxdg_decoration_manager_v1_requests,
    .event_count = 0,
    .events = null,
};

pub const zxdg_decoration_manager_v1 = opaque {
    pub fn destroy(self: *zxdg_decoration_manager_v1) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), zxdg_decoration_manager_v1_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn getToplevelDecoration(self: *zxdg_decoration_manager_v1, toplevel: *xdg_shell.xdg_toplevel) core.Error!*zxdg_toplevel_decoration_v1 {
        var args: [2]core.WlArgument = undefined;
        args[0].n = 0;
        args[1].o = @ptrCast(toplevel);
        const _proxy = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), zxdg_decoration_manager_v1_request.get_toplevel_decoration, &zxdg_toplevel_decoration_v1_interface, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }
};

// ---- zxdg_toplevel_decoration_v1 (v2) ----

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

pub const zxdg_toplevel_decoration_v1 = opaque {
    pub fn destroy(self: *zxdg_toplevel_decoration_v1) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), zxdg_toplevel_decoration_v1_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn setMode(self: *zxdg_toplevel_decoration_v1, mode: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = mode;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), zxdg_toplevel_decoration_v1_request.set_mode, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn unsetMode(self: *zxdg_toplevel_decoration_v1) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), zxdg_toplevel_decoration_v1_request.unset_mode, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn addListener(self: *zxdg_toplevel_decoration_v1, listener: *const zxdg_toplevel_decoration_v1_listener, data: ?*anyopaque) core.Error!void {
        if (core.lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};
