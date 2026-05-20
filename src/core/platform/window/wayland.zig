//! Native Wayland `Window` backend for the S2 spike. Tier 0 from S2 onward.
//!
//! Implements the canonical xdg-shell boot sequence (cf. brief § Notes):
//!     create surface → get xdg_surface → get xdg_toplevel → commit
//!         → roundtrip → ack first xdg_surface.configure → ready
//!
//! All event callbacks are pure Zig functions with `callconv(.c)`. This
//! is the design hypothesis the brief asks us to validate; if the
//! compositor delivers a corrupt event queue, returns wrong values, or
//! triggers ABI errors, the documented fallback is to introduce a single
//! `wayland_callbacks.c` trampoline. So far the hypothesis holds.

const std = @import("std");
const builtin = @import("builtin");
const window = @import("../window.zig");
const core = @import("wayland_protocols/core.zig");
const xdg_shell = @import("wayland_protocols/xdg_shell.zig");
const xdg_decoration = @import("wayland_protocols/xdg_decoration.zig");

/// Heap-allocated backend state. Pointer is stable across moves of the
/// surrounding `Window`; required because Wayland holds raw pointers to
/// our listener structs and to the `data` parameter we pass to
/// `addListener`.
const State = struct {
    gpa: std.mem.Allocator,
    display: *core.wl_display,
    registry: *core.wl_registry,

    // Globals filled in by the registry listener during the boot roundtrip.
    compositor: ?*core.wl_compositor = null,
    xdg_wm_base: ?*xdg_shell.xdg_wm_base = null,
    decoration_manager: ?*xdg_decoration.zxdg_decoration_manager_v1 = null,

    surface: *core.wl_surface,
    xdg_surface_p: *xdg_shell.xdg_surface,
    xdg_toplevel_p: *xdg_shell.xdg_toplevel,
    decoration: ?*xdg_decoration.zxdg_toplevel_decoration_v1 = null,

    width: u32,
    height: u32,
    scale: i32 = 1,
    configured: bool = false,
    /// Last delivered scale, so `dpi_changed` does not fire on no-op ticks.
    last_scale: i32 = 1,

    events: std.ArrayList(window.Event),

    // Listener structs live in `State` so their addresses outlive the
    // local scope of `create`. Wayland keeps the pointer.
    registry_listener: core.wl_registry_listener,
    xdg_wm_base_listener: xdg_shell.xdg_wm_base_listener,
    surface_listener: core.wl_surface_listener,
    xdg_surface_listener: xdg_shell.xdg_surface_listener,
    xdg_toplevel_listener: xdg_shell.xdg_toplevel_listener,
};

/// Native Wayland handles needed by Vulkan to create a `VkSurfaceKHR`.
pub const NativeHandles = struct {
    display: *anyopaque,
    surface: *anyopaque,
};

/// Wayland implementation of the public `Window` interface. Owns the
/// connected `wl_display`, `wl_surface`, `xdg_surface`, `xdg_toplevel`.
pub const Backend = struct {
    state: *State,

    pub fn nativeHandles(self: *const Backend) NativeHandles {
        return .{
            .display = @ptrCast(self.state.display),
            .surface = @ptrCast(self.state.surface),
        };
    }

    pub fn create(gpa: std.mem.Allocator, desc: window.Desc) window.Error!Backend {
        // libwayland-client is loaded once per process; idempotent.
        core.loadLibWayland() catch return error.UnsupportedPlatform;
        const lib = &core.lib_wayland;

        const display = lib.wl_display_connect(null) orelse return error.BackendInitFailed;
        errdefer _ = lib.wl_display_disconnect(display);

        const state = try gpa.create(State);
        errdefer gpa.destroy(state);

        state.* = .{
            .gpa = gpa,
            .display = display,
            .registry = undefined,
            .surface = undefined,
            .xdg_surface_p = undefined,
            .xdg_toplevel_p = undefined,
            .width = desc.width,
            .height = desc.height,
            .events = .empty,
            .registry_listener = .{
                .global = onRegistryGlobal,
                .global_remove = onRegistryGlobalRemove,
            },
            .xdg_wm_base_listener = .{ .ping = onXdgWmBasePing },
            .surface_listener = .{
                .enter = onSurfaceEnter,
                .leave = onSurfaceLeave,
                .preferred_buffer_scale = onSurfacePreferredScale,
                .preferred_buffer_transform = onSurfacePreferredTransform,
            },
            .xdg_surface_listener = .{ .configure = onXdgSurfaceConfigure },
            .xdg_toplevel_listener = .{
                .configure = onXdgToplevelConfigure,
                .close = onXdgToplevelClose,
                .configure_bounds = onXdgToplevelConfigureBounds,
                .wm_capabilities = onXdgToplevelWmCapabilities,
            },
        };
        errdefer state.events.deinit(gpa);

        state.registry = display.getRegistry() catch return error.BackendInitFailed;
        state.registry.addListener(&state.registry_listener, state) catch return error.BackendInitFailed;

        // First roundtrip — pull the global advertisements from the server.
        if (lib.wl_display_roundtrip(display) < 0) return error.BackendInitFailed;
        if (state.compositor == null or state.xdg_wm_base == null) return error.BackendInitFailed;

        // Wire up surface chain.
        state.xdg_wm_base.?.addListener(&state.xdg_wm_base_listener, state) catch return error.BackendInitFailed;

        state.surface = state.compositor.?.createSurface() catch return error.BackendInitFailed;
        state.surface.addListener(&state.surface_listener, state) catch return error.BackendInitFailed;
        // Pin the buffer scale to 1.0 explicitly. Without this, on a HiDPI
        // monitor the compositor falls back to its own scale heuristic and
        // upscales our buffer (blurry output). `onSurfacePreferredScale`
        // updates this when the compositor sends a different value.
        state.surface.setBufferScale(1);

        state.xdg_surface_p = state.xdg_wm_base.?.getXdgSurface(state.surface) catch return error.BackendInitFailed;
        state.xdg_surface_p.addListener(&state.xdg_surface_listener, state) catch return error.BackendInitFailed;

        state.xdg_toplevel_p = state.xdg_surface_p.getToplevel() catch return error.BackendInitFailed;
        state.xdg_toplevel_p.addListener(&state.xdg_toplevel_listener, state) catch return error.BackendInitFailed;

        state.xdg_toplevel_p.setTitle(desc.title.ptr);
        state.xdg_toplevel_p.setAppId("io.weld.spike");

        // Server-side decorations are optional — KDE supports it, GNOME does
        // not. Without it, the compositor falls back to client-side
        // decorations (or none); the spike still runs.
        if (state.decoration_manager) |dm| {
            if (dm.getToplevelDecoration(state.xdg_toplevel_p)) |dec| {
                state.decoration = dec;
                dec.setMode(2); // server_side
            } else |_| {}
        }

        // Initial commit triggers the first xdg_surface.configure event.
        state.surface.commit();

        // Roundtrip until the compositor has sent + we have ack'd the
        // first configure. Most compositors deliver it in one round-trip;
        // we allow up to three before bailing.
        var rounds: u8 = 0;
        while (!state.configured and rounds < 3) : (rounds += 1) {
            if (lib.wl_display_roundtrip(display) < 0) return error.BackendInitFailed;
        }
        if (!state.configured) return error.BackendInitFailed;

        return .{ .state = state };
    }

    pub fn destroy(self: *Backend) void {
        const s = self.state;
        const lib = &core.lib_wayland;

        if (s.decoration) |dec| dec.destroy();
        s.xdg_toplevel_p.destroy();
        s.xdg_surface_p.destroy();
        s.surface.destroy();
        if (s.decoration_manager) |dm| dm.destroy();
        if (s.xdg_wm_base) |xwb| xwb.destroy();
        if (s.compositor) |c| {
            // wl_compositor v4 does not have a destructor request — older
            // compositors crash if we send `release` (added in v6). Use
            // the libwayland-level proxy_destroy, which always works.
            lib.wl_proxy_destroy(@ptrCast(c));
        }
        lib.wl_proxy_destroy(@ptrCast(s.registry));
        _ = lib.wl_display_flush(s.display);
        _ = lib.wl_display_disconnect(s.display);

        s.events.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    pub fn close(self: *Backend) void {
        self.state.events.append(self.state.gpa, .close) catch {};
    }

    pub fn pollEvent(self: *Backend) ?window.Event {
        if (self.state.events.items.len == 0) {
            pumpNonBlocking(self.state.display);
        }
        if (self.state.events.items.len == 0) return null;
        return self.state.events.orderedRemove(0);
    }
};

/// Non-blocking event pump using the libwayland `prepare_read` sequence
/// so the spike's render loop never blocks waiting on the compositor.
fn pumpNonBlocking(display: *core.wl_display) void {
    const lib = &core.lib_wayland;
    while (lib.wl_display_prepare_read(display) != 0) {
        _ = lib.wl_display_dispatch_pending(display);
    }
    _ = lib.wl_display_flush(display);

    var pfd = [_]std.posix.pollfd{
        .{
            .fd = lib.wl_display_get_fd(display),
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const ready = std.posix.poll(&pfd, 0) catch 0;
    if (ready > 0) {
        _ = lib.wl_display_read_events(display);
    } else {
        lib.wl_display_cancel_read(display);
    }
    _ = lib.wl_display_dispatch_pending(display);
}

// ============================================================== Callbacks

fn onRegistryGlobal(
    data: ?*anyopaque,
    registry: *core.wl_registry,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));
    const iface_str = std.mem.span(interface);
    if (std.mem.eql(u8, iface_str, "wl_compositor")) {
        const v = @min(version, 4);
        const proxy = registry.bind(name, &core.wl_compositor_interface, v) catch return;
        state.compositor = @ptrCast(@alignCast(proxy));
    } else if (std.mem.eql(u8, iface_str, "xdg_wm_base")) {
        const v = @min(version, 4);
        const proxy = registry.bind(name, &xdg_shell.xdg_wm_base_interface, v) catch return;
        state.xdg_wm_base = @ptrCast(@alignCast(proxy));
    } else if (std.mem.eql(u8, iface_str, "zxdg_decoration_manager_v1")) {
        const v = @min(version, 1);
        const proxy = registry.bind(name, &xdg_decoration.zxdg_decoration_manager_v1_interface, v) catch return;
        state.decoration_manager = @ptrCast(@alignCast(proxy));
    }
}

fn onRegistryGlobalRemove(
    data: ?*anyopaque,
    registry: *core.wl_registry,
    name: u32,
) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
    // S2 does not handle hot-unplug of compositors / decoration managers.
}

fn onXdgWmBasePing(
    data: ?*anyopaque,
    base: *xdg_shell.xdg_wm_base,
    serial: u32,
) callconv(.c) void {
    _ = data;
    base.pong(serial);
}

fn onXdgSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surface_p: *xdg_shell.xdg_surface,
    serial: u32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));
    xdg_surface_p.ackConfigure(serial);
    state.configured = true;
}

fn onXdgToplevelConfigure(
    data: ?*anyopaque,
    proxy: *xdg_shell.xdg_toplevel,
    width: i32,
    height: i32,
    states: *core.WlArray,
) callconv(.c) void {
    _ = proxy;
    _ = states;
    const state: *State = @ptrCast(@alignCast(data.?));
    if (width > 0 and height > 0) {
        const new_w: u32 = @intCast(width);
        const new_h: u32 = @intCast(height);
        if (new_w != state.width or new_h != state.height) {
            state.width = new_w;
            state.height = new_h;
            state.events.append(state.gpa, .{ .resize = .{ .width = new_w, .height = new_h } }) catch {};
        }
    }
}

fn onXdgToplevelClose(
    data: ?*anyopaque,
    proxy: *xdg_shell.xdg_toplevel,
) callconv(.c) void {
    _ = proxy;
    const state: *State = @ptrCast(@alignCast(data.?));
    state.events.append(state.gpa, .close) catch {};
}

fn onXdgToplevelConfigureBounds(
    data: ?*anyopaque,
    proxy: *xdg_shell.xdg_toplevel,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = width;
    _ = height;
}

fn onXdgToplevelWmCapabilities(
    data: ?*anyopaque,
    proxy: *xdg_shell.xdg_toplevel,
    capabilities: *core.WlArray,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = capabilities;
}

fn onSurfaceEnter(
    data: ?*anyopaque,
    proxy: *core.wl_surface,
    output: *core.wl_output,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = output;
}

fn onSurfaceLeave(
    data: ?*anyopaque,
    proxy: *core.wl_surface,
    output: *core.wl_output,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = output;
}

fn onSurfacePreferredScale(
    data: ?*anyopaque,
    proxy: *core.wl_surface,
    factor: i32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));
    if (factor > 0 and factor != state.last_scale) {
        state.last_scale = factor;
        state.scale = factor;
        const scale_f: f32 = @floatFromInt(factor);
        state.events.append(state.gpa, .{ .dpi_changed = scale_f }) catch {};
        // Acknowledge the new scale to the compositor so subsequent buffer
        // attaches are interpreted at the right physical resolution.
        proxy.setBufferScale(factor);
        proxy.commit();
    }
}

fn onSurfacePreferredTransform(
    data: ?*anyopaque,
    proxy: *core.wl_surface,
    transform: u32,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = transform;
}
