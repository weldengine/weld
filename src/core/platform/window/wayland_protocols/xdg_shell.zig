//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-wayland`.
//!
//! Wayland protocol `xdg_shell` bindings emitted from upstream XML.
//! Throwaway: S3 unifier replaces this generator.

const std = @import("std");
const core = @import("core.zig");
const WlInterface = core.WlInterface;
const WlMessage = core.WlMessage;

// ---- xdg_wm_base (v7) ----

pub const xdg_wm_base_error = enum(u32) {
    role = 0,
    defunct_surfaces = 1,
    not_the_topmost_popup = 2,
    invalid_popup_parent = 3,
    invalid_surface_state = 4,
    invalid_positioner = 5,
    unresponsive = 6,
    _,
};

pub const xdg_wm_base_request = struct {
    pub const destroy: u32 = 0;
    pub const create_positioner: u32 = 1;
    pub const get_xdg_surface: u32 = 2;
    pub const pong: u32 = 3;
};

pub const xdg_wm_base_event = struct {
    pub const ping: u32 = 0;
};

pub const xdg_wm_base_listener = extern struct {
    ping: *const fn (data: ?*anyopaque, proxy: *xdg_wm_base, serial: u32) callconv(.c) void,
};

const xdg_wm_base_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = null },
    .{ .name = "get_xdg_surface", .signature = "no", .types = null },
    .{ .name = "pong", .signature = "u", .types = null },
};

const xdg_wm_base_events = [_]WlMessage{
    .{ .name = "ping", .signature = "u", .types = null },
};

pub const xdg_wm_base_interface = WlInterface{
    .name = "xdg_wm_base",
    .version = 7,
    .method_count = 4,
    .methods = &xdg_wm_base_requests,
    .event_count = 1,
    .events = &xdg_wm_base_events,
};

pub const xdg_wm_base = opaque {
    pub fn destroy(self: *xdg_wm_base) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_wm_base_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn createPositioner(self: *xdg_wm_base) core.Error!*xdg_positioner {
        var args: [1]core.WlArgument = undefined;
        args[0].n = 0;
        const _proxy = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_wm_base_request.create_positioner, &xdg_positioner_interface, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn getXdgSurface(self: *xdg_wm_base, surface: *core.wl_surface) core.Error!*xdg_surface {
        var args: [2]core.WlArgument = undefined;
        args[0].n = 0;
        args[1].o = @ptrCast(surface);
        const _proxy = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_wm_base_request.get_xdg_surface, &xdg_surface_interface, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn pong(self: *xdg_wm_base, serial: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = serial;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_wm_base_request.pong, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn addListener(self: *xdg_wm_base, listener: *const xdg_wm_base_listener, data: ?*anyopaque) core.Error!void {
        if (core.lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- xdg_positioner (v7) ----

pub const xdg_positioner_error = enum(u32) {
    invalid_input = 0,
    _,
};

pub const xdg_positioner_anchor = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
    _,
};

pub const xdg_positioner_gravity = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
    _,
};

pub const xdg_positioner_constraint_adjustment = enum(u32) {
    none = 0,
    slide_x = 1,
    slide_y = 2,
    flip_x = 4,
    flip_y = 8,
    resize_x = 16,
    resize_y = 32,
    _,
};

pub const xdg_positioner_request = struct {
    pub const destroy: u32 = 0;
    pub const set_size: u32 = 1;
    pub const set_anchor_rect: u32 = 2;
    pub const set_anchor: u32 = 3;
    pub const set_gravity: u32 = 4;
    pub const set_constraint_adjustment: u32 = 5;
    pub const set_offset: u32 = 6;
    pub const set_reactive: u32 = 7;
    pub const set_parent_size: u32 = 8;
    pub const set_parent_configure: u32 = 9;
};

const xdg_positioner_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_size", .signature = "ii", .types = null },
    .{ .name = "set_anchor_rect", .signature = "iiii", .types = null },
    .{ .name = "set_anchor", .signature = "u", .types = null },
    .{ .name = "set_gravity", .signature = "u", .types = null },
    .{ .name = "set_constraint_adjustment", .signature = "u", .types = null },
    .{ .name = "set_offset", .signature = "ii", .types = null },
    .{ .name = "set_reactive", .signature = "", .types = null },
    .{ .name = "set_parent_size", .signature = "ii", .types = null },
    .{ .name = "set_parent_configure", .signature = "u", .types = null },
};

pub const xdg_positioner_interface = WlInterface{
    .name = "xdg_positioner",
    .version = 7,
    .method_count = 10,
    .methods = &xdg_positioner_requests,
    .event_count = 0,
    .events = null,
};

pub const xdg_positioner = opaque {
    pub fn destroy(self: *xdg_positioner) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn setSize(self: *xdg_positioner, width: i32, height: i32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].i = width;
        args[1].i = height;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_size, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setAnchorRect(self: *xdg_positioner, x: i32, y: i32, width: i32, height: i32) void {
        var args: [4]core.WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        args[2].i = width;
        args[3].i = height;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_anchor_rect, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setAnchor(self: *xdg_positioner, anchor: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = anchor;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_anchor, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setGravity(self: *xdg_positioner, gravity: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = gravity;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_gravity, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setConstraintAdjustment(self: *xdg_positioner, constraint_adjustment: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = constraint_adjustment;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_constraint_adjustment, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setOffset(self: *xdg_positioner, x: i32, y: i32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_offset, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setReactive(self: *xdg_positioner) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_reactive, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setParentSize(self: *xdg_positioner, parent_width: i32, parent_height: i32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].i = parent_width;
        args[1].i = parent_height;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_parent_size, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setParentConfigure(self: *xdg_positioner, serial: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = serial;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_positioner_request.set_parent_configure, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }
};

// ---- xdg_surface (v7) ----

pub const xdg_surface_error = enum(u32) {
    not_constructed = 1,
    already_constructed = 2,
    unconfigured_buffer = 3,
    invalid_serial = 4,
    invalid_size = 5,
    defunct_role_object = 6,
    _,
};

pub const xdg_surface_request = struct {
    pub const destroy: u32 = 0;
    pub const get_toplevel: u32 = 1;
    pub const get_popup: u32 = 2;
    pub const set_window_geometry: u32 = 3;
    pub const ack_configure: u32 = 4;
};

pub const xdg_surface_event = struct {
    pub const configure: u32 = 0;
};

pub const xdg_surface_listener = extern struct {
    configure: *const fn (data: ?*anyopaque, proxy: *xdg_surface, serial: u32) callconv(.c) void,
};

const xdg_surface_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = null },
    .{ .name = "get_popup", .signature = "n?oo", .types = null },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};

const xdg_surface_events = [_]WlMessage{
    .{ .name = "configure", .signature = "u", .types = null },
};

pub const xdg_surface_interface = WlInterface{
    .name = "xdg_surface",
    .version = 7,
    .method_count = 5,
    .methods = &xdg_surface_requests,
    .event_count = 1,
    .events = &xdg_surface_events,
};

pub const xdg_surface = opaque {
    pub fn destroy(self: *xdg_surface) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_surface_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn getToplevel(self: *xdg_surface) core.Error!*xdg_toplevel {
        var args: [1]core.WlArgument = undefined;
        args[0].n = 0;
        const _proxy = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_surface_request.get_toplevel, &xdg_toplevel_interface, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn getPopup(self: *xdg_surface, parent: ?*xdg_surface, positioner: *xdg_positioner) core.Error!*xdg_popup {
        var args: [3]core.WlArgument = undefined;
        args[0].n = 0;
        args[1].o = if (parent) |__p| @ptrCast(__p) else null;
        args[2].o = @ptrCast(positioner);
        const _proxy = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_surface_request.get_popup, &xdg_popup_interface, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn setWindowGeometry(self: *xdg_surface, x: i32, y: i32, width: i32, height: i32) void {
        var args: [4]core.WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        args[2].i = width;
        args[3].i = height;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_surface_request.set_window_geometry, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn ackConfigure(self: *xdg_surface, serial: u32) void {
        var args: [1]core.WlArgument = undefined;
        args[0].u = serial;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_surface_request.ack_configure, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn addListener(self: *xdg_surface, listener: *const xdg_surface_listener, data: ?*anyopaque) core.Error!void {
        if (core.lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- xdg_toplevel (v7) ----

pub const xdg_toplevel_error = enum(u32) {
    invalid_resize_edge = 0,
    invalid_parent = 1,
    invalid_size = 2,
    _,
};

pub const xdg_toplevel_resize_edge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
    _,
};

pub const xdg_toplevel_state = enum(u32) {
    maximized = 1,
    fullscreen = 2,
    resizing = 3,
    activated = 4,
    tiled_left = 5,
    tiled_right = 6,
    tiled_top = 7,
    tiled_bottom = 8,
    suspended = 9,
    constrained_left = 10,
    constrained_right = 11,
    constrained_top = 12,
    constrained_bottom = 13,
    _,
};

pub const xdg_toplevel_wm_capabilities = enum(u32) {
    window_menu = 1,
    maximize = 2,
    fullscreen = 3,
    minimize = 4,
    _,
};

pub const xdg_toplevel_request = struct {
    pub const destroy: u32 = 0;
    pub const set_parent: u32 = 1;
    pub const set_title: u32 = 2;
    pub const set_app_id: u32 = 3;
    pub const show_window_menu: u32 = 4;
    pub const move: u32 = 5;
    pub const resize: u32 = 6;
    pub const set_max_size: u32 = 7;
    pub const set_min_size: u32 = 8;
    pub const set_maximized: u32 = 9;
    pub const unset_maximized: u32 = 10;
    pub const set_fullscreen: u32 = 11;
    pub const unset_fullscreen: u32 = 12;
    pub const set_minimized: u32 = 13;
};

pub const xdg_toplevel_event = struct {
    pub const configure: u32 = 0;
    pub const close: u32 = 1;
    pub const configure_bounds: u32 = 2;
    pub const wm_capabilities: u32 = 3;
};

pub const xdg_toplevel_listener = extern struct {
    configure: *const fn (data: ?*anyopaque, proxy: *xdg_toplevel, width: i32, height: i32, states: *core.WlArray) callconv(.c) void,
    close: *const fn (data: ?*anyopaque, proxy: *xdg_toplevel) callconv(.c) void,
    configure_bounds: *const fn (data: ?*anyopaque, proxy: *xdg_toplevel, width: i32, height: i32) callconv(.c) void,
    wm_capabilities: *const fn (data: ?*anyopaque, proxy: *xdg_toplevel, capabilities: *core.WlArray) callconv(.c) void,
};

const xdg_toplevel_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = null },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_app_id", .signature = "s", .types = null },
    .{ .name = "show_window_menu", .signature = "ouii", .types = null },
    .{ .name = "move", .signature = "ou", .types = null },
    .{ .name = "resize", .signature = "ouu", .types = null },
    .{ .name = "set_max_size", .signature = "ii", .types = null },
    .{ .name = "set_min_size", .signature = "ii", .types = null },
    .{ .name = "set_maximized", .signature = "", .types = null },
    .{ .name = "unset_maximized", .signature = "", .types = null },
    .{ .name = "set_fullscreen", .signature = "?o", .types = null },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};

const xdg_toplevel_events = [_]WlMessage{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "a", .types = null },
};

pub const xdg_toplevel_interface = WlInterface{
    .name = "xdg_toplevel",
    .version = 7,
    .method_count = 14,
    .methods = &xdg_toplevel_requests,
    .event_count = 4,
    .events = &xdg_toplevel_events,
};

pub const xdg_toplevel = opaque {
    pub fn destroy(self: *xdg_toplevel) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn setParent(self: *xdg_toplevel, parent: ?*xdg_toplevel) void {
        var args: [1]core.WlArgument = undefined;
        args[0].o = if (parent) |__p| @ptrCast(__p) else null;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_parent, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setTitle(self: *xdg_toplevel, title: [*:0]const u8) void {
        var args: [1]core.WlArgument = undefined;
        args[0].s = title;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_title, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setAppId(self: *xdg_toplevel, app_id: [*:0]const u8) void {
        var args: [1]core.WlArgument = undefined;
        args[0].s = app_id;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_app_id, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn showWindowMenu(self: *xdg_toplevel, seat: *core.wl_seat, serial: u32, x: i32, y: i32) void {
        var args: [4]core.WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        args[2].i = x;
        args[3].i = y;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.show_window_menu, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn move(self: *xdg_toplevel, seat: *core.wl_seat, serial: u32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.move, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn resize(self: *xdg_toplevel, seat: *core.wl_seat, serial: u32, edges: u32) void {
        var args: [3]core.WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        args[2].u = edges;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.resize, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setMaxSize(self: *xdg_toplevel, width: i32, height: i32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].i = width;
        args[1].i = height;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_max_size, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setMinSize(self: *xdg_toplevel, width: i32, height: i32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].i = width;
        args[1].i = height;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_min_size, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setMaximized(self: *xdg_toplevel) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_maximized, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn unsetMaximized(self: *xdg_toplevel) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.unset_maximized, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setFullscreen(self: *xdg_toplevel, output: ?*core.wl_output) void {
        var args: [1]core.WlArgument = undefined;
        args[0].o = if (output) |__p| @ptrCast(__p) else null;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_fullscreen, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn unsetFullscreen(self: *xdg_toplevel) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.unset_fullscreen, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setMinimized(self: *xdg_toplevel) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_toplevel_request.set_minimized, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn addListener(self: *xdg_toplevel, listener: *const xdg_toplevel_listener, data: ?*anyopaque) core.Error!void {
        if (core.lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- xdg_popup (v7) ----

pub const xdg_popup_error = enum(u32) {
    invalid_grab = 0,
    _,
};

pub const xdg_popup_request = struct {
    pub const destroy: u32 = 0;
    pub const grab: u32 = 1;
    pub const reposition: u32 = 2;
};

pub const xdg_popup_event = struct {
    pub const configure: u32 = 0;
    pub const popup_done: u32 = 1;
    pub const repositioned: u32 = 2;
};

pub const xdg_popup_listener = extern struct {
    configure: *const fn (data: ?*anyopaque, proxy: *xdg_popup, x: i32, y: i32, width: i32, height: i32) callconv(.c) void,
    popup_done: *const fn (data: ?*anyopaque, proxy: *xdg_popup) callconv(.c) void,
    repositioned: *const fn (data: ?*anyopaque, proxy: *xdg_popup, token: u32) callconv(.c) void,
};

const xdg_popup_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "grab", .signature = "ou", .types = null },
    .{ .name = "reposition", .signature = "ou", .types = null },
};

const xdg_popup_events = [_]WlMessage{
    .{ .name = "configure", .signature = "iiii", .types = null },
    .{ .name = "popup_done", .signature = "", .types = null },
    .{ .name = "repositioned", .signature = "u", .types = null },
};

pub const xdg_popup_interface = WlInterface{
    .name = "xdg_popup",
    .version = 7,
    .method_count = 3,
    .methods = &xdg_popup_requests,
    .event_count = 3,
    .events = &xdg_popup_events,
};

pub const xdg_popup = opaque {
    pub fn destroy(self: *xdg_popup) void {
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_popup_request.destroy, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), core.WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn grab(self: *xdg_popup, seat: *core.wl_seat, serial: u32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_popup_request.grab, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn reposition(self: *xdg_popup, positioner: *xdg_positioner, token: u32) void {
        var args: [2]core.WlArgument = undefined;
        args[0].o = @ptrCast(positioner);
        args[1].u = token;
        _ = core.lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), xdg_popup_request.reposition, null, core.lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn addListener(self: *xdg_popup, listener: *const xdg_popup_listener, data: ?*anyopaque) core.Error!void {
        if (core.lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};
