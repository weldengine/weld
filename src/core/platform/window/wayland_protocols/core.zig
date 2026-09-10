//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-wayland`.
//!
//! Wayland protocol `wayland` bindings emitted from upstream XML.
//! Throwaway: S3 unifier replaces this generator.

const std = @import("std");
// ---- Wayland C ABI (libwayland-client) common types ----

pub const WlInterface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const WlMessage,
    event_count: c_int,
    events: ?[*]const WlMessage,
};

pub const WlMessage = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const WlInterface,
};

pub const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

/// Argument union passed to `wl_proxy_marshal_array_flags`. Field tags match
/// the wire-signature characters: i u f s o n a h.
pub const WlArgument = extern union {
    i: i32,
    u: u32,
    f: i32, // wl_fixed_t (24.8 fixed-point)
    s: ?[*:0]const u8,
    o: ?*anyopaque,
    n: u32,
    a: ?*WlArray,
    h: i32,
};

/// 24.8 fixed-point scalar used by Wayland for sub-pixel coordinates.
pub const Fixed = enum(i32) {
    _,
    pub fn fromDouble(d: f64) Fixed {
        return @enumFromInt(@as(i32, @intFromFloat(d * 256.0)));
    }
    pub fn toDouble(self: Fixed) f64 {
        return @as(f64, @floatFromInt(@intFromEnum(self))) / 256.0;
    }
    pub fn fromInt(i: i32) Fixed {
        return @enumFromInt(i << 8);
    }
    pub fn toInt(self: Fixed) i32 {
        return @intFromEnum(self) >> 8;
    }
};

/// `flags` argument passed to `wl_proxy_marshal_array_flags`. Set on
/// destructor requests to free the proxy after the call returns.
pub const WL_MARSHAL_FLAG_DESTROY: u32 = 1;

pub const Error = error{
    LibraryNotFound,
    SymbolNotFound,
    ListenerAlreadySet,
    ProxyMarshalFailed,
    ConnectFailed,
};

// ---- libwayland-client dispatch ----
//
// dlopen the wayland client library and resolve the function pointers
// the spike binary needs. Variadic marshal entry points are kept in the
// dispatch table as `*const anyopaque` for completeness — the actual
// generated wrappers below all call `wl_proxy_marshal_array_flags`,
// the non-variadic equivalent.

pub const LibWaylandDispatch = struct {
    // Display lifecycle and event pumping.
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*wl_display = undefined,
    wl_display_disconnect: *const fn (*wl_display) callconv(.c) void = undefined,
    wl_display_dispatch: *const fn (*wl_display) callconv(.c) c_int = undefined,
    wl_display_dispatch_pending: *const fn (*wl_display) callconv(.c) c_int = undefined,
    wl_display_prepare_read: *const fn (*wl_display) callconv(.c) c_int = undefined,
    wl_display_read_events: *const fn (*wl_display) callconv(.c) c_int = undefined,
    wl_display_cancel_read: *const fn (*wl_display) callconv(.c) void = undefined,
    wl_display_roundtrip: *const fn (*wl_display) callconv(.c) c_int = undefined,
    wl_display_flush: *const fn (*wl_display) callconv(.c) c_int = undefined,
    wl_display_get_fd: *const fn (*wl_display) callconv(.c) c_int = undefined,

    // Variadic marshalling — opaque pointers (variadic ABI is not exposed by
    // generated wrappers). Kept here for callers that need them.
    wl_proxy_marshal_constructor: *const anyopaque = undefined,
    wl_proxy_marshal_constructor_versioned: *const anyopaque = undefined,
    wl_proxy_marshal_flags: *const anyopaque = undefined,

    // Non-variadic marshalling — every generated method calls this.
    wl_proxy_marshal_array_flags: *const fn (
        proxy: *anyopaque,
        opcode: u32,
        interface: ?*const WlInterface,
        version: u32,
        flags: u32,
        args: ?[*]WlArgument,
    ) callconv(.c) ?*anyopaque = undefined,

    // Listener registration + lifecycle.
    wl_proxy_add_listener: *const fn (*anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int = undefined,
    wl_proxy_destroy: *const fn (*anyopaque) callconv(.c) void = undefined,
    wl_proxy_get_version: *const fn (*anyopaque) callconv(.c) u32 = undefined,
    wl_proxy_set_user_data: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void = undefined,
    wl_proxy_get_user_data: *const fn (*anyopaque) callconv(.c) ?*anyopaque = undefined,
};

pub var lib_wayland: LibWaylandDispatch = .{};
var lib_handle: ?*anyopaque = null;

// `std.DynLib` is `@compileError("unsupported platform")` on Windows
// in Zig 0.16's stdlib, so we hand-roll a tiny dlopen abstraction.
// In practice `loadLibWayland` is only called on Linux (the Wayland
// backend is wired only there) but the generated code must still
// compile on Windows / macOS targets.
const _dl = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {
    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
};

fn _dlOpen(path_z: [*:0]const u8) ?*anyopaque {
    return if (comptime @import("builtin").os.tag == .windows)
        _dl.LoadLibraryA(path_z)
    else
        _dl.dlopen(path_z, 2); // RTLD_NOW
}

fn _dlLookup(handle: *anyopaque, name_z: [*:0]const u8) ?*anyopaque {
    return if (comptime @import("builtin").os.tag == .windows)
        _dl.GetProcAddress(handle, name_z)
    else
        _dl.dlsym(handle, name_z);
}

pub fn loadLibWayland() Error!void {
    if (lib_handle != null) return; // idempotent
    const candidates = &[_][:0]const u8{ "libwayland-client.so.0", "libwayland-client.so" };
    for (candidates) |path| {
        if (_dlOpen(path.ptr)) |h| {
            lib_handle = h;
            break;
        }
    }
    if (lib_handle == null) return error.LibraryNotFound;

    inline for (@typeInfo(LibWaylandDispatch).@"struct".fields) |f| {
        const sym = _dlLookup(lib_handle.?, f.name.ptr) orelse return error.SymbolNotFound;
        @field(lib_wayland, f.name) = @ptrCast(@alignCast(sym));
    }
}

// ---- wl_display (v1) ----

pub const wl_display_error = enum(u32) {
    invalid_object = 0,
    invalid_method = 1,
    no_memory = 2,
    implementation = 3,
    _,
};

pub const wl_display_request = struct {
    pub const sync: u32 = 0;
    pub const get_registry: u32 = 1;
};

pub const wl_display_event = struct {
    pub const @"error": u32 = 0;
    pub const delete_id: u32 = 1;
};

pub const wl_display_listener = extern struct {
    @"error": *const fn (data: ?*anyopaque, proxy: *wl_display, object_id: ?*anyopaque, code: u32, message: [*:0]const u8) callconv(.c) void,
    delete_id: *const fn (data: ?*anyopaque, proxy: *wl_display, id: u32) callconv(.c) void,
};

const wl_display_sync_types: [1]?*const WlInterface = .{
    &wl_callback_interface,
};

const wl_display_get_registry_types: [1]?*const WlInterface = .{
    &wl_registry_interface,
};

const wl_display_requests = [_]WlMessage{
    .{ .name = "sync", .signature = "n", .types = &wl_display_sync_types },
    .{ .name = "get_registry", .signature = "n", .types = &wl_display_get_registry_types },
};

const wl_display_error_types: [3]?*const WlInterface = .{
    null,
    null,
    null,
};

const wl_display_events = [_]WlMessage{
    .{ .name = "error", .signature = "ous", .types = &wl_display_error_types },
    .{ .name = "delete_id", .signature = "u", .types = null },
};

pub const wl_display_interface = WlInterface{
    .name = "wl_display",
    .version = 1,
    .method_count = 2,
    .methods = &wl_display_requests,
    .event_count = 2,
    .events = &wl_display_events,
};

pub const wl_display = opaque {
    pub fn sync(self: *wl_display) Error!*wl_callback {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_display_request.sync, &wl_callback_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn getRegistry(self: *wl_display) Error!*wl_registry {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_display_request.get_registry, &wl_registry_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn addListener(self: *wl_display, listener: *const wl_display_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_registry (v1) ----

pub const wl_registry_request = struct {
    pub const bind: u32 = 0;
};

pub const wl_registry_event = struct {
    pub const global: u32 = 0;
    pub const global_remove: u32 = 1;
};

pub const wl_registry_listener = extern struct {
    global: *const fn (data: ?*anyopaque, proxy: *wl_registry, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void,
    global_remove: *const fn (data: ?*anyopaque, proxy: *wl_registry, name: u32) callconv(.c) void,
};

const wl_registry_bind_types: [4]?*const WlInterface = .{
    null,
    null,
    null,
    null,
};

const wl_registry_requests = [_]WlMessage{
    .{ .name = "bind", .signature = "usun", .types = &wl_registry_bind_types },
};

const wl_registry_events = [_]WlMessage{
    .{ .name = "global", .signature = "usu", .types = null },
    .{ .name = "global_remove", .signature = "u", .types = null },
};

pub const wl_registry_interface = WlInterface{
    .name = "wl_registry",
    .version = 1,
    .method_count = 1,
    .methods = &wl_registry_requests,
    .event_count = 2,
    .events = &wl_registry_events,
};

pub const wl_registry = opaque {
    pub fn bind(self: *wl_registry, name: u32, interface: *const WlInterface, version: u32) Error!*anyopaque {
        var args: [4]WlArgument = undefined;
        args[0].u = name;
        args[1].s = interface.name;
        args[2].u = version;
        args[3].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_registry_request.bind, interface, version, 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn addListener(self: *wl_registry, listener: *const wl_registry_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_callback (v1) ----

pub const wl_callback_event = struct {
    pub const done: u32 = 0;
};

pub const wl_callback_listener = extern struct {
    done: *const fn (data: ?*anyopaque, proxy: *wl_callback, callback_data: u32) callconv(.c) void,
};

const wl_callback_events = [_]WlMessage{
    .{ .name = "done", .signature = "u", .types = null },
};

pub const wl_callback_interface = WlInterface{
    .name = "wl_callback",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 1,
    .events = &wl_callback_events,
};

pub const wl_callback = opaque {
    pub fn addListener(self: *wl_callback, listener: *const wl_callback_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_compositor (v7) ----

pub const wl_compositor_request = struct {
    pub const create_surface: u32 = 0;
    pub const create_region: u32 = 1;
    pub const release: u32 = 2;
};

const wl_compositor_create_surface_types: [1]?*const WlInterface = .{
    &wl_surface_interface,
};

const wl_compositor_create_region_types: [1]?*const WlInterface = .{
    &wl_region_interface,
};

const wl_compositor_requests = [_]WlMessage{
    .{ .name = "create_surface", .signature = "n", .types = &wl_compositor_create_surface_types },
    .{ .name = "create_region", .signature = "n", .types = &wl_compositor_create_region_types },
    .{ .name = "release", .signature = "", .types = null },
};

pub const wl_compositor_interface = WlInterface{
    .name = "wl_compositor",
    .version = 7,
    .method_count = 3,
    .methods = &wl_compositor_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_compositor = opaque {
    pub fn createSurface(self: *wl_compositor) Error!*wl_surface {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_compositor_request.create_surface, &wl_surface_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn createRegion(self: *wl_compositor) Error!*wl_region {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_compositor_request.create_region, &wl_region_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn release(self: *wl_compositor) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_compositor_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }
};

// ---- wl_shm_pool (v2) ----

pub const wl_shm_pool_request = struct {
    pub const create_buffer: u32 = 0;
    pub const destroy: u32 = 1;
    pub const resize: u32 = 2;
};

const wl_shm_pool_create_buffer_types: [6]?*const WlInterface = .{
    &wl_buffer_interface,
    null,
    null,
    null,
    null,
    null,
};

const wl_shm_pool_requests = [_]WlMessage{
    .{ .name = "create_buffer", .signature = "niiiiu", .types = &wl_shm_pool_create_buffer_types },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "resize", .signature = "i", .types = null },
};

pub const wl_shm_pool_interface = WlInterface{
    .name = "wl_shm_pool",
    .version = 2,
    .method_count = 3,
    .methods = &wl_shm_pool_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_shm_pool = opaque {
    pub fn createBuffer(self: *wl_shm_pool, offset: i32, width: i32, height: i32, stride: i32, format: u32) Error!*wl_buffer {
        var args: [6]WlArgument = undefined;
        args[0].n = 0;
        args[1].i = offset;
        args[2].i = width;
        args[3].i = height;
        args[4].i = stride;
        args[5].u = format;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shm_pool_request.create_buffer, &wl_buffer_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn destroy(self: *wl_shm_pool) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shm_pool_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn resize(self: *wl_shm_pool, size: i32) void {
        var args: [1]WlArgument = undefined;
        args[0].i = size;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shm_pool_request.resize, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }
};

// ---- wl_shm (v2) ----

pub const wl_shm_error = enum(u32) {
    invalid_format = 0,
    invalid_stride = 1,
    invalid_fd = 2,
    _,
};

pub const wl_shm_format = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
    c8 = 538982467,
    rgb332 = 943867730,
    bgr233 = 944916290,
    xrgb4444 = 842093144,
    xbgr4444 = 842089048,
    rgbx4444 = 842094674,
    bgrx4444 = 842094658,
    argb4444 = 842093121,
    abgr4444 = 842089025,
    rgba4444 = 842088786,
    bgra4444 = 842088770,
    xrgb1555 = 892424792,
    xbgr1555 = 892420696,
    rgbx5551 = 892426322,
    bgrx5551 = 892426306,
    argb1555 = 892424769,
    abgr1555 = 892420673,
    rgba5551 = 892420434,
    bgra5551 = 892420418,
    rgb565 = 909199186,
    bgr565 = 909199170,
    rgb888 = 875710290,
    bgr888 = 875710274,
    xbgr8888 = 875709016,
    rgbx8888 = 875714642,
    bgrx8888 = 875714626,
    abgr8888 = 875708993,
    rgba8888 = 875708754,
    bgra8888 = 875708738,
    xrgb2101010 = 808669784,
    xbgr2101010 = 808665688,
    rgbx1010102 = 808671314,
    bgrx1010102 = 808671298,
    argb2101010 = 808669761,
    abgr2101010 = 808665665,
    rgba1010102 = 808665426,
    bgra1010102 = 808665410,
    yuyv = 1448695129,
    yvyu = 1431918169,
    uyvy = 1498831189,
    vyuy = 1498765654,
    ayuv = 1448433985,
    nv12 = 842094158,
    nv21 = 825382478,
    nv16 = 909203022,
    nv61 = 825644622,
    yuv410 = 961959257,
    yvu410 = 961893977,
    yuv411 = 825316697,
    yvu411 = 825316953,
    yuv420 = 842093913,
    yvu420 = 842094169,
    yuv422 = 909202777,
    yvu422 = 909203033,
    yuv444 = 875713881,
    yvu444 = 875714137,
    r8 = 538982482,
    r16 = 540422482,
    rg88 = 943212370,
    gr88 = 943215175,
    rg1616 = 842221394,
    gr1616 = 842224199,
    xrgb16161616f = 1211388504,
    xbgr16161616f = 1211384408,
    argb16161616f = 1211388481,
    abgr16161616f = 1211384385,
    xyuv8888 = 1448434008,
    vuy888 = 875713878,
    vuy101010 = 808670550,
    y210 = 808530521,
    y212 = 842084953,
    y216 = 909193817,
    y410 = 808531033,
    y412 = 842085465,
    y416 = 909194329,
    xvyu2101010 = 808670808,
    xvyu12_16161616 = 909334104,
    xvyu16161616 = 942954072,
    y0l0 = 810299481,
    x0l0 = 810299480,
    y0l2 = 843853913,
    x0l2 = 843853912,
    yuv420_8bit = 942691673,
    yuv420_10bit = 808539481,
    xrgb8888_a8 = 943805016,
    xbgr8888_a8 = 943800920,
    rgbx8888_a8 = 943806546,
    bgrx8888_a8 = 943806530,
    rgb888_a8 = 943798354,
    bgr888_a8 = 943798338,
    rgb565_a8 = 943797586,
    bgr565_a8 = 943797570,
    nv24 = 875714126,
    nv42 = 842290766,
    p210 = 808530512,
    p010 = 808530000,
    p012 = 842084432,
    p016 = 909193296,
    axbxgxrx106106106106 = 808534593,
    nv15 = 892425806,
    q410 = 808531025,
    q401 = 825242705,
    xrgb16161616 = 942953048,
    xbgr16161616 = 942948952,
    argb16161616 = 942953025,
    abgr16161616 = 942948929,
    c1 = 538980675,
    c2 = 538980931,
    c4 = 538981443,
    d1 = 538980676,
    d2 = 538980932,
    d4 = 538981444,
    d8 = 538982468,
    r1 = 538980690,
    r2 = 538980946,
    r4 = 538981458,
    r10 = 540029266,
    r12 = 540160338,
    avuy8888 = 1498764865,
    xvuy8888 = 1498764888,
    p030 = 808661072,
    rgb161616 = 942950226,
    bgr161616 = 942950210,
    r16f = 1210064978,
    gr1616f = 1210077767,
    bgr161616f = 1213351746,
    r32f = 1176510546,
    gr3232f = 1176523335,
    bgr323232f = 1179797314,
    abgr32323232f = 1178092097,
    nv20 = 808605262,
    nv30 = 808670798,
    s010 = 808530003,
    s210 = 808530515,
    s410 = 808531027,
    s012 = 842084435,
    s212 = 842084947,
    s412 = 842085459,
    s016 = 909193299,
    s216 = 909193811,
    s416 = 909194323,
    _,
};

pub const wl_shm_request = struct {
    pub const create_pool: u32 = 0;
    pub const release: u32 = 1;
};

pub const wl_shm_event = struct {
    pub const format: u32 = 0;
};

pub const wl_shm_listener = extern struct {
    format: *const fn (data: ?*anyopaque, proxy: *wl_shm, format: u32) callconv(.c) void,
};

const wl_shm_create_pool_types: [3]?*const WlInterface = .{
    &wl_shm_pool_interface,
    null,
    null,
};

const wl_shm_requests = [_]WlMessage{
    .{ .name = "create_pool", .signature = "nhi", .types = &wl_shm_create_pool_types },
    .{ .name = "release", .signature = "", .types = null },
};

const wl_shm_events = [_]WlMessage{
    .{ .name = "format", .signature = "u", .types = null },
};

pub const wl_shm_interface = WlInterface{
    .name = "wl_shm",
    .version = 2,
    .method_count = 2,
    .methods = &wl_shm_requests,
    .event_count = 1,
    .events = &wl_shm_events,
};

pub const wl_shm = opaque {
    pub fn createPool(self: *wl_shm, fd: std.posix.fd_t, size: i32) Error!*wl_shm_pool {
        var args: [3]WlArgument = undefined;
        args[0].n = 0;
        args[1].h = fd;
        args[2].i = size;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shm_request.create_pool, &wl_shm_pool_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn release(self: *wl_shm) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shm_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_shm, listener: *const wl_shm_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_buffer (v1) ----

pub const wl_buffer_request = struct {
    pub const destroy: u32 = 0;
};

pub const wl_buffer_event = struct {
    pub const release: u32 = 0;
};

pub const wl_buffer_listener = extern struct {
    release: *const fn (data: ?*anyopaque, proxy: *wl_buffer) callconv(.c) void,
};

const wl_buffer_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
};

const wl_buffer_events = [_]WlMessage{
    .{ .name = "release", .signature = "", .types = null },
};

pub const wl_buffer_interface = WlInterface{
    .name = "wl_buffer",
    .version = 1,
    .method_count = 1,
    .methods = &wl_buffer_requests,
    .event_count = 1,
    .events = &wl_buffer_events,
};

pub const wl_buffer = opaque {
    pub fn destroy(self: *wl_buffer) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_buffer_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_buffer, listener: *const wl_buffer_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_data_offer (v4) ----

pub const wl_data_offer_error = enum(u32) {
    invalid_finish = 0,
    invalid_action_mask = 1,
    invalid_action = 2,
    invalid_offer = 3,
    _,
};

pub const wl_data_offer_request = struct {
    pub const accept: u32 = 0;
    pub const receive: u32 = 1;
    pub const destroy: u32 = 2;
    pub const finish: u32 = 3;
    pub const set_actions: u32 = 4;
};

pub const wl_data_offer_event = struct {
    pub const offer: u32 = 0;
    pub const source_actions: u32 = 1;
    pub const action: u32 = 2;
};

pub const wl_data_offer_listener = extern struct {
    offer: *const fn (data: ?*anyopaque, proxy: *wl_data_offer, mime_type: [*:0]const u8) callconv(.c) void,
    source_actions: *const fn (data: ?*anyopaque, proxy: *wl_data_offer, source_actions: u32) callconv(.c) void,
    action: *const fn (data: ?*anyopaque, proxy: *wl_data_offer, dnd_action: u32) callconv(.c) void,
};

const wl_data_offer_requests = [_]WlMessage{
    .{ .name = "accept", .signature = "u?s", .types = null },
    .{ .name = "receive", .signature = "sh", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "finish", .signature = "", .types = null },
    .{ .name = "set_actions", .signature = "uu", .types = null },
};

const wl_data_offer_events = [_]WlMessage{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "source_actions", .signature = "u", .types = null },
    .{ .name = "action", .signature = "u", .types = null },
};

pub const wl_data_offer_interface = WlInterface{
    .name = "wl_data_offer",
    .version = 4,
    .method_count = 5,
    .methods = &wl_data_offer_requests,
    .event_count = 3,
    .events = &wl_data_offer_events,
};

pub const wl_data_offer = opaque {
    pub fn accept(self: *wl_data_offer, serial: u32, mime_type: ?[*:0]const u8) void {
        var args: [2]WlArgument = undefined;
        args[0].u = serial;
        args[1].s = mime_type;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_offer_request.accept, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn receive(self: *wl_data_offer, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        var args: [2]WlArgument = undefined;
        args[0].s = mime_type;
        args[1].h = fd;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_offer_request.receive, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn destroy(self: *wl_data_offer) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_offer_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn finish(self: *wl_data_offer) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_offer_request.finish, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setActions(self: *wl_data_offer, dnd_actions: u32, preferred_action: u32) void {
        var args: [2]WlArgument = undefined;
        args[0].u = dnd_actions;
        args[1].u = preferred_action;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_offer_request.set_actions, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn addListener(self: *wl_data_offer, listener: *const wl_data_offer_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_data_source (v4) ----

pub const wl_data_source_error = enum(u32) {
    invalid_action_mask = 0,
    invalid_source = 1,
    _,
};

pub const wl_data_source_request = struct {
    pub const offer: u32 = 0;
    pub const destroy: u32 = 1;
    pub const set_actions: u32 = 2;
};

pub const wl_data_source_event = struct {
    pub const target: u32 = 0;
    pub const send: u32 = 1;
    pub const cancelled: u32 = 2;
    pub const dnd_drop_performed: u32 = 3;
    pub const dnd_finished: u32 = 4;
    pub const action: u32 = 5;
};

pub const wl_data_source_listener = extern struct {
    target: *const fn (data: ?*anyopaque, proxy: *wl_data_source, mime_type: ?[*:0]const u8) callconv(.c) void,
    send: *const fn (data: ?*anyopaque, proxy: *wl_data_source, mime_type: [*:0]const u8, fd: std.posix.fd_t) callconv(.c) void,
    cancelled: *const fn (data: ?*anyopaque, proxy: *wl_data_source) callconv(.c) void,
    dnd_drop_performed: *const fn (data: ?*anyopaque, proxy: *wl_data_source) callconv(.c) void,
    dnd_finished: *const fn (data: ?*anyopaque, proxy: *wl_data_source) callconv(.c) void,
    action: *const fn (data: ?*anyopaque, proxy: *wl_data_source, dnd_action: u32) callconv(.c) void,
};

const wl_data_source_requests = [_]WlMessage{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_actions", .signature = "u", .types = null },
};

const wl_data_source_events = [_]WlMessage{
    .{ .name = "target", .signature = "?s", .types = null },
    .{ .name = "send", .signature = "sh", .types = null },
    .{ .name = "cancelled", .signature = "", .types = null },
    .{ .name = "dnd_drop_performed", .signature = "", .types = null },
    .{ .name = "dnd_finished", .signature = "", .types = null },
    .{ .name = "action", .signature = "u", .types = null },
};

pub const wl_data_source_interface = WlInterface{
    .name = "wl_data_source",
    .version = 4,
    .method_count = 3,
    .methods = &wl_data_source_requests,
    .event_count = 6,
    .events = &wl_data_source_events,
};

pub const wl_data_source = opaque {
    pub fn offer(self: *wl_data_source, mime_type: [*:0]const u8) void {
        var args: [1]WlArgument = undefined;
        args[0].s = mime_type;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_source_request.offer, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn destroy(self: *wl_data_source) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_source_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn setActions(self: *wl_data_source, dnd_actions: u32) void {
        var args: [1]WlArgument = undefined;
        args[0].u = dnd_actions;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_source_request.set_actions, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn addListener(self: *wl_data_source, listener: *const wl_data_source_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_data_device (v4) ----

pub const wl_data_device_error = enum(u32) {
    role = 0,
    used_source = 1,
    _,
};

pub const wl_data_device_request = struct {
    pub const start_drag: u32 = 0;
    pub const set_selection: u32 = 1;
    pub const release: u32 = 2;
};

pub const wl_data_device_event = struct {
    pub const data_offer: u32 = 0;
    pub const enter: u32 = 1;
    pub const leave: u32 = 2;
    pub const motion: u32 = 3;
    pub const drop: u32 = 4;
    pub const selection: u32 = 5;
};

pub const wl_data_device_listener = extern struct {
    data_offer: *const fn (data: ?*anyopaque, proxy: *wl_data_device, id: *wl_data_offer) callconv(.c) void,
    enter: *const fn (data: ?*anyopaque, proxy: *wl_data_device, serial: u32, surface: *wl_surface, x: Fixed, y: Fixed, id: ?*wl_data_offer) callconv(.c) void,
    leave: *const fn (data: ?*anyopaque, proxy: *wl_data_device) callconv(.c) void,
    motion: *const fn (data: ?*anyopaque, proxy: *wl_data_device, time: u32, x: Fixed, y: Fixed) callconv(.c) void,
    drop: *const fn (data: ?*anyopaque, proxy: *wl_data_device) callconv(.c) void,
    selection: *const fn (data: ?*anyopaque, proxy: *wl_data_device, id: ?*wl_data_offer) callconv(.c) void,
};

const wl_data_device_start_drag_types: [4]?*const WlInterface = .{
    &wl_data_source_interface,
    &wl_surface_interface,
    &wl_surface_interface,
    null,
};

const wl_data_device_set_selection_types: [2]?*const WlInterface = .{
    &wl_data_source_interface,
    null,
};

const wl_data_device_requests = [_]WlMessage{
    .{ .name = "start_drag", .signature = "?oo?ou", .types = &wl_data_device_start_drag_types },
    .{ .name = "set_selection", .signature = "?ou", .types = &wl_data_device_set_selection_types },
    .{ .name = "release", .signature = "", .types = null },
};

const wl_data_device_data_offer_types: [1]?*const WlInterface = .{
    &wl_data_offer_interface,
};

const wl_data_device_enter_types: [5]?*const WlInterface = .{
    null,
    &wl_surface_interface,
    null,
    null,
    &wl_data_offer_interface,
};

const wl_data_device_selection_types: [1]?*const WlInterface = .{
    &wl_data_offer_interface,
};

const wl_data_device_events = [_]WlMessage{
    .{ .name = "data_offer", .signature = "n", .types = &wl_data_device_data_offer_types },
    .{ .name = "enter", .signature = "uoff?o", .types = &wl_data_device_enter_types },
    .{ .name = "leave", .signature = "", .types = null },
    .{ .name = "motion", .signature = "uff", .types = null },
    .{ .name = "drop", .signature = "", .types = null },
    .{ .name = "selection", .signature = "?o", .types = &wl_data_device_selection_types },
};

pub const wl_data_device_interface = WlInterface{
    .name = "wl_data_device",
    .version = 4,
    .method_count = 3,
    .methods = &wl_data_device_requests,
    .event_count = 6,
    .events = &wl_data_device_events,
};

pub const wl_data_device = opaque {
    pub fn startDrag(self: *wl_data_device, source: ?*wl_data_source, origin: *wl_surface, icon: ?*wl_surface, serial: u32) void {
        var args: [4]WlArgument = undefined;
        args[0].o = if (source) |__p| @ptrCast(__p) else null;
        args[1].o = @ptrCast(origin);
        args[2].o = if (icon) |__p| @ptrCast(__p) else null;
        args[3].u = serial;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_device_request.start_drag, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setSelection(self: *wl_data_device, source: ?*wl_data_source, serial: u32) void {
        var args: [2]WlArgument = undefined;
        args[0].o = if (source) |__p| @ptrCast(__p) else null;
        args[1].u = serial;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_device_request.set_selection, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn release(self: *wl_data_device) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_device_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_data_device, listener: *const wl_data_device_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_data_device_manager (v4) ----

pub const wl_data_device_manager_dnd_action = enum(u32) {
    none = 0,
    copy = 1,
    move = 2,
    ask = 4,
    _,
};

pub const wl_data_device_manager_request = struct {
    pub const create_data_source: u32 = 0;
    pub const get_data_device: u32 = 1;
    pub const release: u32 = 2;
};

const wl_data_device_manager_create_data_source_types: [1]?*const WlInterface = .{
    &wl_data_source_interface,
};

const wl_data_device_manager_get_data_device_types: [2]?*const WlInterface = .{
    &wl_data_device_interface,
    &wl_seat_interface,
};

const wl_data_device_manager_requests = [_]WlMessage{
    .{ .name = "create_data_source", .signature = "n", .types = &wl_data_device_manager_create_data_source_types },
    .{ .name = "get_data_device", .signature = "no", .types = &wl_data_device_manager_get_data_device_types },
    .{ .name = "release", .signature = "", .types = null },
};

pub const wl_data_device_manager_interface = WlInterface{
    .name = "wl_data_device_manager",
    .version = 4,
    .method_count = 3,
    .methods = &wl_data_device_manager_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_data_device_manager = opaque {
    pub fn createDataSource(self: *wl_data_device_manager) Error!*wl_data_source {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_device_manager_request.create_data_source, &wl_data_source_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn getDataDevice(self: *wl_data_device_manager, seat: *wl_seat) Error!*wl_data_device {
        var args: [2]WlArgument = undefined;
        args[0].n = 0;
        args[1].o = @ptrCast(seat);
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_device_manager_request.get_data_device, &wl_data_device_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn release(self: *wl_data_device_manager) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_data_device_manager_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }
};

// ---- wl_shell (v1) ----

pub const wl_shell_error = enum(u32) {
    role = 0,
    _,
};

pub const wl_shell_request = struct {
    pub const get_shell_surface: u32 = 0;
};

const wl_shell_get_shell_surface_types: [2]?*const WlInterface = .{
    &wl_shell_surface_interface,
    &wl_surface_interface,
};

const wl_shell_requests = [_]WlMessage{
    .{ .name = "get_shell_surface", .signature = "no", .types = &wl_shell_get_shell_surface_types },
};

pub const wl_shell_interface = WlInterface{
    .name = "wl_shell",
    .version = 1,
    .method_count = 1,
    .methods = &wl_shell_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_shell = opaque {
    pub fn getShellSurface(self: *wl_shell, surface: *wl_surface) Error!*wl_shell_surface {
        var args: [2]WlArgument = undefined;
        args[0].n = 0;
        args[1].o = @ptrCast(surface);
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_request.get_shell_surface, &wl_shell_surface_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }
};

// ---- wl_shell_surface (v1) ----

pub const wl_shell_surface_resize = enum(u32) {
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

pub const wl_shell_surface_transient = enum(u32) {
    inactive = 1,
    _,
};

pub const wl_shell_surface_fullscreen_method = enum(u32) {
    default = 0,
    scale = 1,
    driver = 2,
    fill = 3,
    _,
};

pub const wl_shell_surface_request = struct {
    pub const pong: u32 = 0;
    pub const move: u32 = 1;
    pub const resize: u32 = 2;
    pub const set_toplevel: u32 = 3;
    pub const set_transient: u32 = 4;
    pub const set_fullscreen: u32 = 5;
    pub const set_popup: u32 = 6;
    pub const set_maximized: u32 = 7;
    pub const set_title: u32 = 8;
    pub const set_class: u32 = 9;
};

pub const wl_shell_surface_event = struct {
    pub const ping: u32 = 0;
    pub const configure: u32 = 1;
    pub const popup_done: u32 = 2;
};

pub const wl_shell_surface_listener = extern struct {
    ping: *const fn (data: ?*anyopaque, proxy: *wl_shell_surface, serial: u32) callconv(.c) void,
    configure: *const fn (data: ?*anyopaque, proxy: *wl_shell_surface, edges: u32, width: i32, height: i32) callconv(.c) void,
    popup_done: *const fn (data: ?*anyopaque, proxy: *wl_shell_surface) callconv(.c) void,
};

const wl_shell_surface_move_types: [2]?*const WlInterface = .{
    &wl_seat_interface,
    null,
};

const wl_shell_surface_resize_types: [3]?*const WlInterface = .{
    &wl_seat_interface,
    null,
    null,
};

const wl_shell_surface_set_transient_types: [4]?*const WlInterface = .{
    &wl_surface_interface,
    null,
    null,
    null,
};

const wl_shell_surface_set_fullscreen_types: [3]?*const WlInterface = .{
    null,
    null,
    &wl_output_interface,
};

const wl_shell_surface_set_popup_types: [6]?*const WlInterface = .{
    &wl_seat_interface,
    null,
    &wl_surface_interface,
    null,
    null,
    null,
};

const wl_shell_surface_set_maximized_types: [1]?*const WlInterface = .{
    &wl_output_interface,
};

const wl_shell_surface_requests = [_]WlMessage{
    .{ .name = "pong", .signature = "u", .types = null },
    .{ .name = "move", .signature = "ou", .types = &wl_shell_surface_move_types },
    .{ .name = "resize", .signature = "ouu", .types = &wl_shell_surface_resize_types },
    .{ .name = "set_toplevel", .signature = "", .types = null },
    .{ .name = "set_transient", .signature = "oiiu", .types = &wl_shell_surface_set_transient_types },
    .{ .name = "set_fullscreen", .signature = "uu?o", .types = &wl_shell_surface_set_fullscreen_types },
    .{ .name = "set_popup", .signature = "ouoiiu", .types = &wl_shell_surface_set_popup_types },
    .{ .name = "set_maximized", .signature = "?o", .types = &wl_shell_surface_set_maximized_types },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_class", .signature = "s", .types = null },
};

const wl_shell_surface_events = [_]WlMessage{
    .{ .name = "ping", .signature = "u", .types = null },
    .{ .name = "configure", .signature = "uii", .types = null },
    .{ .name = "popup_done", .signature = "", .types = null },
};

pub const wl_shell_surface_interface = WlInterface{
    .name = "wl_shell_surface",
    .version = 1,
    .method_count = 10,
    .methods = &wl_shell_surface_requests,
    .event_count = 3,
    .events = &wl_shell_surface_events,
};

pub const wl_shell_surface = opaque {
    pub fn pong(self: *wl_shell_surface, serial: u32) void {
        var args: [1]WlArgument = undefined;
        args[0].u = serial;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.pong, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn move(self: *wl_shell_surface, seat: *wl_seat, serial: u32) void {
        var args: [2]WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.move, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn resize(self: *wl_shell_surface, seat: *wl_seat, serial: u32, edges: u32) void {
        var args: [3]WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        args[2].u = edges;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.resize, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setToplevel(self: *wl_shell_surface) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_toplevel, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setTransient(self: *wl_shell_surface, parent: *wl_surface, x: i32, y: i32, flags: u32) void {
        var args: [4]WlArgument = undefined;
        args[0].o = @ptrCast(parent);
        args[1].i = x;
        args[2].i = y;
        args[3].u = flags;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_transient, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setFullscreen(self: *wl_shell_surface, method: u32, framerate: u32, output: ?*wl_output) void {
        var args: [3]WlArgument = undefined;
        args[0].u = method;
        args[1].u = framerate;
        args[2].o = if (output) |__p| @ptrCast(__p) else null;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_fullscreen, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setPopup(self: *wl_shell_surface, seat: *wl_seat, serial: u32, parent: *wl_surface, x: i32, y: i32, flags: u32) void {
        var args: [6]WlArgument = undefined;
        args[0].o = @ptrCast(seat);
        args[1].u = serial;
        args[2].o = @ptrCast(parent);
        args[3].i = x;
        args[4].i = y;
        args[5].u = flags;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_popup, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setMaximized(self: *wl_shell_surface, output: ?*wl_output) void {
        var args: [1]WlArgument = undefined;
        args[0].o = if (output) |__p| @ptrCast(__p) else null;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_maximized, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setTitle(self: *wl_shell_surface, title: [*:0]const u8) void {
        var args: [1]WlArgument = undefined;
        args[0].s = title;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_title, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setClass(self: *wl_shell_surface, class_: [*:0]const u8) void {
        var args: [1]WlArgument = undefined;
        args[0].s = class_;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_shell_surface_request.set_class, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn addListener(self: *wl_shell_surface, listener: *const wl_shell_surface_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_surface (v7) ----

pub const wl_surface_error = enum(u32) {
    invalid_scale = 0,
    invalid_transform = 1,
    invalid_size = 2,
    invalid_offset = 3,
    defunct_role_object = 4,
    no_buffer = 5,
    _,
};

pub const wl_surface_request = struct {
    pub const destroy: u32 = 0;
    pub const attach: u32 = 1;
    pub const damage: u32 = 2;
    pub const frame: u32 = 3;
    pub const set_opaque_region: u32 = 4;
    pub const set_input_region: u32 = 5;
    pub const commit: u32 = 6;
    pub const set_buffer_transform: u32 = 7;
    pub const set_buffer_scale: u32 = 8;
    pub const damage_buffer: u32 = 9;
    pub const offset: u32 = 10;
    pub const get_release: u32 = 11;
};

pub const wl_surface_event = struct {
    pub const enter: u32 = 0;
    pub const leave: u32 = 1;
    pub const preferred_buffer_scale: u32 = 2;
    pub const preferred_buffer_transform: u32 = 3;
};

pub const wl_surface_listener = extern struct {
    enter: *const fn (data: ?*anyopaque, proxy: *wl_surface, output: *wl_output) callconv(.c) void,
    leave: *const fn (data: ?*anyopaque, proxy: *wl_surface, output: *wl_output) callconv(.c) void,
    preferred_buffer_scale: *const fn (data: ?*anyopaque, proxy: *wl_surface, factor: i32) callconv(.c) void,
    preferred_buffer_transform: *const fn (data: ?*anyopaque, proxy: *wl_surface, transform: u32) callconv(.c) void,
};

const wl_surface_attach_types: [3]?*const WlInterface = .{
    &wl_buffer_interface,
    null,
    null,
};

const wl_surface_frame_types: [1]?*const WlInterface = .{
    &wl_callback_interface,
};

const wl_surface_set_opaque_region_types: [1]?*const WlInterface = .{
    &wl_region_interface,
};

const wl_surface_set_input_region_types: [1]?*const WlInterface = .{
    &wl_region_interface,
};

const wl_surface_get_release_types: [1]?*const WlInterface = .{
    &wl_callback_interface,
};

const wl_surface_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "attach", .signature = "?oii", .types = &wl_surface_attach_types },
    .{ .name = "damage", .signature = "iiii", .types = null },
    .{ .name = "frame", .signature = "n", .types = &wl_surface_frame_types },
    .{ .name = "set_opaque_region", .signature = "?o", .types = &wl_surface_set_opaque_region_types },
    .{ .name = "set_input_region", .signature = "?o", .types = &wl_surface_set_input_region_types },
    .{ .name = "commit", .signature = "", .types = null },
    .{ .name = "set_buffer_transform", .signature = "i", .types = null },
    .{ .name = "set_buffer_scale", .signature = "i", .types = null },
    .{ .name = "damage_buffer", .signature = "iiii", .types = null },
    .{ .name = "offset", .signature = "ii", .types = null },
    .{ .name = "get_release", .signature = "n", .types = &wl_surface_get_release_types },
};

const wl_surface_enter_types: [1]?*const WlInterface = .{
    &wl_output_interface,
};

const wl_surface_leave_types: [1]?*const WlInterface = .{
    &wl_output_interface,
};

const wl_surface_events = [_]WlMessage{
    .{ .name = "enter", .signature = "o", .types = &wl_surface_enter_types },
    .{ .name = "leave", .signature = "o", .types = &wl_surface_leave_types },
    .{ .name = "preferred_buffer_scale", .signature = "i", .types = null },
    .{ .name = "preferred_buffer_transform", .signature = "u", .types = null },
};

pub const wl_surface_interface = WlInterface{
    .name = "wl_surface",
    .version = 7,
    .method_count = 12,
    .methods = &wl_surface_requests,
    .event_count = 4,
    .events = &wl_surface_events,
};

pub const wl_surface = opaque {
    pub fn destroy(self: *wl_surface) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn attach(self: *wl_surface, buffer: ?*wl_buffer, x: i32, y: i32) void {
        var args: [3]WlArgument = undefined;
        args[0].o = if (buffer) |__p| @ptrCast(__p) else null;
        args[1].i = x;
        args[2].i = y;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.attach, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn damage(self: *wl_surface, x: i32, y: i32, width: i32, height: i32) void {
        var args: [4]WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        args[2].i = width;
        args[3].i = height;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.damage, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn frame(self: *wl_surface) Error!*wl_callback {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.frame, &wl_callback_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn setOpaqueRegion(self: *wl_surface, region: ?*wl_region) void {
        var args: [1]WlArgument = undefined;
        args[0].o = if (region) |__p| @ptrCast(__p) else null;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.set_opaque_region, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setInputRegion(self: *wl_surface, region: ?*wl_region) void {
        var args: [1]WlArgument = undefined;
        args[0].o = if (region) |__p| @ptrCast(__p) else null;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.set_input_region, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn commit(self: *wl_surface) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.commit, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setBufferTransform(self: *wl_surface, transform: i32) void {
        var args: [1]WlArgument = undefined;
        args[0].i = transform;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.set_buffer_transform, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setBufferScale(self: *wl_surface, scale: i32) void {
        var args: [1]WlArgument = undefined;
        args[0].i = scale;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.set_buffer_scale, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn damageBuffer(self: *wl_surface, x: i32, y: i32, width: i32, height: i32) void {
        var args: [4]WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        args[2].i = width;
        args[3].i = height;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.damage_buffer, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn offset(self: *wl_surface, x: i32, y: i32) void {
        var args: [2]WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.offset, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn getRelease(self: *wl_surface) Error!*wl_callback {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_surface_request.get_release, &wl_callback_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn addListener(self: *wl_surface, listener: *const wl_surface_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_seat (v10) ----

pub const wl_seat_capability = enum(u32) {
    pointer = 1,
    keyboard = 2,
    touch = 4,
    _,
};

pub const wl_seat_error = enum(u32) {
    missing_capability = 0,
    _,
};

pub const wl_seat_request = struct {
    pub const get_pointer: u32 = 0;
    pub const get_keyboard: u32 = 1;
    pub const get_touch: u32 = 2;
    pub const release: u32 = 3;
};

pub const wl_seat_event = struct {
    pub const capabilities: u32 = 0;
    pub const name: u32 = 1;
};

pub const wl_seat_listener = extern struct {
    capabilities: *const fn (data: ?*anyopaque, proxy: *wl_seat, capabilities: u32) callconv(.c) void,
    name: *const fn (data: ?*anyopaque, proxy: *wl_seat, name: [*:0]const u8) callconv(.c) void,
};

const wl_seat_get_pointer_types: [1]?*const WlInterface = .{
    &wl_pointer_interface,
};

const wl_seat_get_keyboard_types: [1]?*const WlInterface = .{
    &wl_keyboard_interface,
};

const wl_seat_get_touch_types: [1]?*const WlInterface = .{
    &wl_touch_interface,
};

const wl_seat_requests = [_]WlMessage{
    .{ .name = "get_pointer", .signature = "n", .types = &wl_seat_get_pointer_types },
    .{ .name = "get_keyboard", .signature = "n", .types = &wl_seat_get_keyboard_types },
    .{ .name = "get_touch", .signature = "n", .types = &wl_seat_get_touch_types },
    .{ .name = "release", .signature = "", .types = null },
};

const wl_seat_events = [_]WlMessage{
    .{ .name = "capabilities", .signature = "u", .types = null },
    .{ .name = "name", .signature = "s", .types = null },
};

pub const wl_seat_interface = WlInterface{
    .name = "wl_seat",
    .version = 10,
    .method_count = 4,
    .methods = &wl_seat_requests,
    .event_count = 2,
    .events = &wl_seat_events,
};

pub const wl_seat = opaque {
    pub fn getPointer(self: *wl_seat) Error!*wl_pointer {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_seat_request.get_pointer, &wl_pointer_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn getKeyboard(self: *wl_seat) Error!*wl_keyboard {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_seat_request.get_keyboard, &wl_keyboard_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn getTouch(self: *wl_seat) Error!*wl_touch {
        var args: [1]WlArgument = undefined;
        args[0].n = 0;
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_seat_request.get_touch, &wl_touch_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }

    pub fn release(self: *wl_seat) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_seat_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_seat, listener: *const wl_seat_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_pointer (v10) ----

pub const wl_pointer_error = enum(u32) {
    role = 0,
    _,
};

pub const wl_pointer_button_state = enum(u32) {
    released = 0,
    pressed = 1,
    _,
};

pub const wl_pointer_axis = enum(u32) {
    vertical_scroll = 0,
    horizontal_scroll = 1,
    _,
};

pub const wl_pointer_axis_source = enum(u32) {
    wheel = 0,
    finger = 1,
    continuous = 2,
    wheel_tilt = 3,
    _,
};

pub const wl_pointer_axis_relative_direction = enum(u32) {
    identical = 0,
    inverted = 1,
    _,
};

pub const wl_pointer_request = struct {
    pub const set_cursor: u32 = 0;
    pub const release: u32 = 1;
};

pub const wl_pointer_event = struct {
    pub const enter: u32 = 0;
    pub const leave: u32 = 1;
    pub const motion: u32 = 2;
    pub const button: u32 = 3;
    pub const axis: u32 = 4;
    pub const frame: u32 = 5;
    pub const axis_source: u32 = 6;
    pub const axis_stop: u32 = 7;
    pub const axis_discrete: u32 = 8;
    pub const axis_value120: u32 = 9;
    pub const axis_relative_direction: u32 = 10;
};

pub const wl_pointer_listener = extern struct {
    enter: *const fn (data: ?*anyopaque, proxy: *wl_pointer, serial: u32, surface: *wl_surface, surface_x: Fixed, surface_y: Fixed) callconv(.c) void,
    leave: *const fn (data: ?*anyopaque, proxy: *wl_pointer, serial: u32, surface: *wl_surface) callconv(.c) void,
    motion: *const fn (data: ?*anyopaque, proxy: *wl_pointer, time: u32, surface_x: Fixed, surface_y: Fixed) callconv(.c) void,
    button: *const fn (data: ?*anyopaque, proxy: *wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void,
    axis: *const fn (data: ?*anyopaque, proxy: *wl_pointer, time: u32, axis: u32, value: Fixed) callconv(.c) void,
    frame: *const fn (data: ?*anyopaque, proxy: *wl_pointer) callconv(.c) void,
    axis_source: *const fn (data: ?*anyopaque, proxy: *wl_pointer, axis_source: u32) callconv(.c) void,
    axis_stop: *const fn (data: ?*anyopaque, proxy: *wl_pointer, time: u32, axis: u32) callconv(.c) void,
    axis_discrete: *const fn (data: ?*anyopaque, proxy: *wl_pointer, axis: u32, discrete: i32) callconv(.c) void,
    axis_value120: *const fn (data: ?*anyopaque, proxy: *wl_pointer, axis: u32, value120: i32) callconv(.c) void,
    axis_relative_direction: *const fn (data: ?*anyopaque, proxy: *wl_pointer, axis: u32, direction: u32) callconv(.c) void,
};

const wl_pointer_set_cursor_types: [4]?*const WlInterface = .{
    null,
    &wl_surface_interface,
    null,
    null,
};

const wl_pointer_requests = [_]WlMessage{
    .{ .name = "set_cursor", .signature = "u?oii", .types = &wl_pointer_set_cursor_types },
    .{ .name = "release", .signature = "", .types = null },
};

const wl_pointer_enter_types: [4]?*const WlInterface = .{
    null,
    &wl_surface_interface,
    null,
    null,
};

const wl_pointer_leave_types: [2]?*const WlInterface = .{
    null,
    &wl_surface_interface,
};

const wl_pointer_events = [_]WlMessage{
    .{ .name = "enter", .signature = "uoff", .types = &wl_pointer_enter_types },
    .{ .name = "leave", .signature = "uo", .types = &wl_pointer_leave_types },
    .{ .name = "motion", .signature = "uff", .types = null },
    .{ .name = "button", .signature = "uuuu", .types = null },
    .{ .name = "axis", .signature = "uuf", .types = null },
    .{ .name = "frame", .signature = "", .types = null },
    .{ .name = "axis_source", .signature = "u", .types = null },
    .{ .name = "axis_stop", .signature = "uu", .types = null },
    .{ .name = "axis_discrete", .signature = "ui", .types = null },
    .{ .name = "axis_value120", .signature = "ui", .types = null },
    .{ .name = "axis_relative_direction", .signature = "uu", .types = null },
};

pub const wl_pointer_interface = WlInterface{
    .name = "wl_pointer",
    .version = 10,
    .method_count = 2,
    .methods = &wl_pointer_requests,
    .event_count = 11,
    .events = &wl_pointer_events,
};

pub const wl_pointer = opaque {
    pub fn setCursor(self: *wl_pointer, serial: u32, surface: ?*wl_surface, hotspot_x: i32, hotspot_y: i32) void {
        var args: [4]WlArgument = undefined;
        args[0].u = serial;
        args[1].o = if (surface) |__p| @ptrCast(__p) else null;
        args[2].i = hotspot_x;
        args[3].i = hotspot_y;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_pointer_request.set_cursor, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn release(self: *wl_pointer) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_pointer_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_pointer, listener: *const wl_pointer_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_keyboard (v10) ----

pub const wl_keyboard_keymap_format = enum(u32) {
    no_keymap = 0,
    xkb_v1 = 1,
    _,
};

pub const wl_keyboard_key_state = enum(u32) {
    released = 0,
    pressed = 1,
    repeated = 2,
    _,
};

pub const wl_keyboard_request = struct {
    pub const release: u32 = 0;
};

pub const wl_keyboard_event = struct {
    pub const keymap: u32 = 0;
    pub const enter: u32 = 1;
    pub const leave: u32 = 2;
    pub const key: u32 = 3;
    pub const modifiers: u32 = 4;
    pub const repeat_info: u32 = 5;
};

pub const wl_keyboard_listener = extern struct {
    keymap: *const fn (data: ?*anyopaque, proxy: *wl_keyboard, format: u32, fd: std.posix.fd_t, size: u32) callconv(.c) void,
    enter: *const fn (data: ?*anyopaque, proxy: *wl_keyboard, serial: u32, surface: *wl_surface, keys: *WlArray) callconv(.c) void,
    leave: *const fn (data: ?*anyopaque, proxy: *wl_keyboard, serial: u32, surface: *wl_surface) callconv(.c) void,
    key: *const fn (data: ?*anyopaque, proxy: *wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void,
    modifiers: *const fn (data: ?*anyopaque, proxy: *wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void,
    repeat_info: *const fn (data: ?*anyopaque, proxy: *wl_keyboard, rate: i32, delay: i32) callconv(.c) void,
};

const wl_keyboard_requests = [_]WlMessage{
    .{ .name = "release", .signature = "", .types = null },
};

const wl_keyboard_enter_types: [3]?*const WlInterface = .{
    null,
    &wl_surface_interface,
    null,
};

const wl_keyboard_leave_types: [2]?*const WlInterface = .{
    null,
    &wl_surface_interface,
};

const wl_keyboard_events = [_]WlMessage{
    .{ .name = "keymap", .signature = "uhu", .types = null },
    .{ .name = "enter", .signature = "uoa", .types = &wl_keyboard_enter_types },
    .{ .name = "leave", .signature = "uo", .types = &wl_keyboard_leave_types },
    .{ .name = "key", .signature = "uuuu", .types = null },
    .{ .name = "modifiers", .signature = "uuuuu", .types = null },
    .{ .name = "repeat_info", .signature = "ii", .types = null },
};

pub const wl_keyboard_interface = WlInterface{
    .name = "wl_keyboard",
    .version = 10,
    .method_count = 1,
    .methods = &wl_keyboard_requests,
    .event_count = 6,
    .events = &wl_keyboard_events,
};

pub const wl_keyboard = opaque {
    pub fn release(self: *wl_keyboard) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_keyboard_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_keyboard, listener: *const wl_keyboard_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_touch (v10) ----

pub const wl_touch_request = struct {
    pub const release: u32 = 0;
};

pub const wl_touch_event = struct {
    pub const down: u32 = 0;
    pub const up: u32 = 1;
    pub const motion: u32 = 2;
    pub const frame: u32 = 3;
    pub const cancel: u32 = 4;
    pub const shape: u32 = 5;
    pub const orientation: u32 = 6;
};

pub const wl_touch_listener = extern struct {
    down: *const fn (data: ?*anyopaque, proxy: *wl_touch, serial: u32, time: u32, surface: *wl_surface, id: i32, x: Fixed, y: Fixed) callconv(.c) void,
    up: *const fn (data: ?*anyopaque, proxy: *wl_touch, serial: u32, time: u32, id: i32) callconv(.c) void,
    motion: *const fn (data: ?*anyopaque, proxy: *wl_touch, time: u32, id: i32, x: Fixed, y: Fixed) callconv(.c) void,
    frame: *const fn (data: ?*anyopaque, proxy: *wl_touch) callconv(.c) void,
    cancel: *const fn (data: ?*anyopaque, proxy: *wl_touch) callconv(.c) void,
    shape: *const fn (data: ?*anyopaque, proxy: *wl_touch, id: i32, major: Fixed, minor: Fixed) callconv(.c) void,
    orientation: *const fn (data: ?*anyopaque, proxy: *wl_touch, id: i32, orientation: Fixed) callconv(.c) void,
};

const wl_touch_requests = [_]WlMessage{
    .{ .name = "release", .signature = "", .types = null },
};

const wl_touch_down_types: [6]?*const WlInterface = .{
    null,
    null,
    &wl_surface_interface,
    null,
    null,
    null,
};

const wl_touch_events = [_]WlMessage{
    .{ .name = "down", .signature = "uuoiff", .types = &wl_touch_down_types },
    .{ .name = "up", .signature = "uui", .types = null },
    .{ .name = "motion", .signature = "uiff", .types = null },
    .{ .name = "frame", .signature = "", .types = null },
    .{ .name = "cancel", .signature = "", .types = null },
    .{ .name = "shape", .signature = "iff", .types = null },
    .{ .name = "orientation", .signature = "if", .types = null },
};

pub const wl_touch_interface = WlInterface{
    .name = "wl_touch",
    .version = 10,
    .method_count = 1,
    .methods = &wl_touch_requests,
    .event_count = 7,
    .events = &wl_touch_events,
};

pub const wl_touch = opaque {
    pub fn release(self: *wl_touch) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_touch_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_touch, listener: *const wl_touch_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_output (v4) ----

pub const wl_output_subpixel = enum(u32) {
    unknown = 0,
    none = 1,
    horizontal_rgb = 2,
    horizontal_bgr = 3,
    vertical_rgb = 4,
    vertical_bgr = 5,
    _,
};

pub const wl_output_transform = enum(u32) {
    normal = 0,
    _90 = 1,
    _180 = 2,
    _270 = 3,
    flipped = 4,
    flipped_90 = 5,
    flipped_180 = 6,
    flipped_270 = 7,
    _,
};

pub const wl_output_mode = enum(u32) {
    current = 1,
    preferred = 2,
    _,
};

pub const wl_output_request = struct {
    pub const release: u32 = 0;
};

pub const wl_output_event = struct {
    pub const geometry: u32 = 0;
    pub const mode: u32 = 1;
    pub const done: u32 = 2;
    pub const scale: u32 = 3;
    pub const name: u32 = 4;
    pub const description: u32 = 5;
};

pub const wl_output_listener = extern struct {
    geometry: *const fn (data: ?*anyopaque, proxy: *wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*:0]const u8, model: [*:0]const u8, transform: i32) callconv(.c) void,
    mode: *const fn (data: ?*anyopaque, proxy: *wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void,
    done: *const fn (data: ?*anyopaque, proxy: *wl_output) callconv(.c) void,
    scale: *const fn (data: ?*anyopaque, proxy: *wl_output, factor: i32) callconv(.c) void,
    name: *const fn (data: ?*anyopaque, proxy: *wl_output, name: [*:0]const u8) callconv(.c) void,
    description: *const fn (data: ?*anyopaque, proxy: *wl_output, description: [*:0]const u8) callconv(.c) void,
};

const wl_output_requests = [_]WlMessage{
    .{ .name = "release", .signature = "", .types = null },
};

const wl_output_events = [_]WlMessage{
    .{ .name = "geometry", .signature = "iiiiissi", .types = null },
    .{ .name = "mode", .signature = "uiii", .types = null },
    .{ .name = "done", .signature = "", .types = null },
    .{ .name = "scale", .signature = "i", .types = null },
    .{ .name = "name", .signature = "s", .types = null },
    .{ .name = "description", .signature = "s", .types = null },
};

pub const wl_output_interface = WlInterface{
    .name = "wl_output",
    .version = 4,
    .method_count = 1,
    .methods = &wl_output_requests,
    .event_count = 6,
    .events = &wl_output_events,
};

pub const wl_output = opaque {
    pub fn release(self: *wl_output) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_output_request.release, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn addListener(self: *wl_output, listener: *const wl_output_listener, data: ?*anyopaque) Error!void {
        if (lib_wayland.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {
            return error.ListenerAlreadySet;
        }
    }
};

// ---- wl_region (v7) ----

pub const wl_region_request = struct {
    pub const destroy: u32 = 0;
    pub const add: u32 = 1;
    pub const subtract: u32 = 2;
};

const wl_region_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "add", .signature = "iiii", .types = null },
    .{ .name = "subtract", .signature = "iiii", .types = null },
};

pub const wl_region_interface = WlInterface{
    .name = "wl_region",
    .version = 7,
    .method_count = 3,
    .methods = &wl_region_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_region = opaque {
    pub fn destroy(self: *wl_region) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_region_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn add(self: *wl_region, x: i32, y: i32, width: i32, height: i32) void {
        var args: [4]WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        args[2].i = width;
        args[3].i = height;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_region_request.add, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn subtract(self: *wl_region, x: i32, y: i32, width: i32, height: i32) void {
        var args: [4]WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        args[2].i = width;
        args[3].i = height;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_region_request.subtract, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }
};

// ---- wl_subcompositor (v1) ----

pub const wl_subcompositor_error = enum(u32) {
    bad_surface = 0,
    bad_parent = 1,
    _,
};

pub const wl_subcompositor_request = struct {
    pub const destroy: u32 = 0;
    pub const get_subsurface: u32 = 1;
};

const wl_subcompositor_get_subsurface_types: [3]?*const WlInterface = .{
    &wl_subsurface_interface,
    &wl_surface_interface,
    &wl_surface_interface,
};

const wl_subcompositor_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_subsurface", .signature = "noo", .types = &wl_subcompositor_get_subsurface_types },
};

pub const wl_subcompositor_interface = WlInterface{
    .name = "wl_subcompositor",
    .version = 1,
    .method_count = 2,
    .methods = &wl_subcompositor_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_subcompositor = opaque {
    pub fn destroy(self: *wl_subcompositor) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subcompositor_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn getSubsurface(self: *wl_subcompositor, surface: *wl_surface, parent: *wl_surface) Error!*wl_subsurface {
        var args: [3]WlArgument = undefined;
        args[0].n = 0;
        args[1].o = @ptrCast(surface);
        args[2].o = @ptrCast(parent);
        const _proxy = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subcompositor_request.get_subsurface, &wl_subsurface_interface, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args) orelse return error.ProxyMarshalFailed;
        return @ptrCast(_proxy);
    }
};

// ---- wl_subsurface (v1) ----

pub const wl_subsurface_error = enum(u32) {
    bad_surface = 0,
    _,
};

pub const wl_subsurface_request = struct {
    pub const destroy: u32 = 0;
    pub const set_position: u32 = 1;
    pub const place_above: u32 = 2;
    pub const place_below: u32 = 3;
    pub const set_sync: u32 = 4;
    pub const set_desync: u32 = 5;
};

const wl_subsurface_place_above_types: [1]?*const WlInterface = .{
    &wl_surface_interface,
};

const wl_subsurface_place_below_types: [1]?*const WlInterface = .{
    &wl_surface_interface,
};

const wl_subsurface_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_position", .signature = "ii", .types = null },
    .{ .name = "place_above", .signature = "o", .types = &wl_subsurface_place_above_types },
    .{ .name = "place_below", .signature = "o", .types = &wl_subsurface_place_below_types },
    .{ .name = "set_sync", .signature = "", .types = null },
    .{ .name = "set_desync", .signature = "", .types = null },
};

pub const wl_subsurface_interface = WlInterface{
    .name = "wl_subsurface",
    .version = 1,
    .method_count = 6,
    .methods = &wl_subsurface_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_subsurface = opaque {
    pub fn destroy(self: *wl_subsurface) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subsurface_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn setPosition(self: *wl_subsurface, x: i32, y: i32) void {
        var args: [2]WlArgument = undefined;
        args[0].i = x;
        args[1].i = y;
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subsurface_request.set_position, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn placeAbove(self: *wl_subsurface, sibling: *wl_surface) void {
        var args: [1]WlArgument = undefined;
        args[0].o = @ptrCast(sibling);
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subsurface_request.place_above, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn placeBelow(self: *wl_subsurface, sibling: *wl_surface) void {
        var args: [1]WlArgument = undefined;
        args[0].o = @ptrCast(sibling);
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subsurface_request.place_below, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }

    pub fn setSync(self: *wl_subsurface) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subsurface_request.set_sync, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }

    pub fn setDesync(self: *wl_subsurface) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_subsurface_request.set_desync, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, null);
    }
};

// ---- wl_fixes (v1) ----

pub const wl_fixes_request = struct {
    pub const destroy: u32 = 0;
    pub const destroy_registry: u32 = 1;
};

const wl_fixes_destroy_registry_types: [1]?*const WlInterface = .{
    &wl_registry_interface,
};

const wl_fixes_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "destroy_registry", .signature = "o", .types = &wl_fixes_destroy_registry_types },
};

pub const wl_fixes_interface = WlInterface{
    .name = "wl_fixes",
    .version = 1,
    .method_count = 2,
    .methods = &wl_fixes_requests,
    .event_count = 0,
    .events = null,
};

pub const wl_fixes = opaque {
    pub fn destroy(self: *wl_fixes) void {
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_fixes_request.destroy, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), WL_MARSHAL_FLAG_DESTROY, null);
    }

    pub fn destroyRegistry(self: *wl_fixes, registry: *wl_registry) void {
        var args: [1]WlArgument = undefined;
        args[0].o = @ptrCast(registry);
        _ = lib_wayland.wl_proxy_marshal_array_flags(@ptrCast(self), wl_fixes_request.destroy_registry, null, lib_wayland.wl_proxy_get_version(@ptrCast(self)), 0, &args);
    }
};
