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
const keycode_mod = @import("../input/keycode.zig");

// evdev BTN_* codes used by wl_pointer.button event.
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
const BTN_SIDE: u32 = 0x113;
const BTN_EXTRA: u32 = 0x114;

// wl_keyboard.key_state values.
const KEY_STATE_RELEASED: u32 = 0;
const KEY_STATE_PRESSED: u32 = 1;

// wl_pointer.axis values.
const AXIS_VERTICAL_SCROLL: u32 = 0;
const AXIS_HORIZONTAL_SCROLL: u32 = 1;

// wl_pointer.button_state values.
const POINTER_BUTTON_RELEASED: u32 = 0;
const POINTER_BUTTON_PRESSED: u32 = 1;

/// Per-output tracking — one OutputEntry per `wl_output` global. Held in
/// the State `outputs` ArrayList as `*OutputEntry` so the listener struct
/// pointer stays stable across ArrayList growth.
const OutputEntry = struct {
    /// Backref so the listener callbacks can route back to State.
    state: *State,
    /// Registry name (used for hot-unplug correlation).
    registry_name: u32,
    /// Wayland proxy.
    proxy: *core.wl_output,
    /// Listener struct — Wayland keeps the address.
    listener: core.wl_output_listener,
    /// Cached monitor info accumulated from `geometry` / `mode` / `scale`
    /// / `name` events. Surfaced via `enumerateMonitors`.
    info: window.MonitorInfo,
    /// Whether the compositor delivered the initial `done` event so the
    /// cached info is considered finalized.
    initialized: bool = false,
};

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

    // ============================== M0.3 — input devices
    seat: ?*core.wl_seat = null,
    keyboard: ?*core.wl_keyboard = null,
    pointer: ?*core.wl_pointer = null,
    seat_listener: core.wl_seat_listener,
    keyboard_listener: core.wl_keyboard_listener,
    pointer_listener: core.wl_pointer_listener,

    // Mouse delta tracking — wl_pointer.motion delivers absolute surface
    // coordinates; we compute delta against the previous sample.
    last_pointer_x: f32 = 0,
    last_pointer_y: f32 = 0,
    pointer_in_window: bool = false,
    /// Surface the pointer currently entered (null when leave fired).
    pointer_focus: ?*core.wl_surface = null,
    /// Surface the keyboard currently has focus on.
    keyboard_focus: ?*core.wl_surface = null,

    // ============================== M0.3 — multi-monitor
    /// All `wl_output` globals advertised by the compositor. Owning —
    /// `deinit` frees each entry.
    outputs: std.ArrayList(*OutputEntry) = .empty,
    /// Monitor the surface currently lives on (set by
    /// `wl_surface.enter` / cleared by `wl_surface.leave`).
    current_output_id: ?u32 = null,
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
            .seat_listener = .{
                .capabilities = onSeatCapabilities,
                .name = onSeatName,
            },
            .keyboard_listener = .{
                .keymap = onKeyboardKeymap,
                .enter = onKeyboardEnter,
                .leave = onKeyboardLeave,
                .key = onKeyboardKey,
                .modifiers = onKeyboardModifiers,
                .repeat_info = onKeyboardRepeatInfo,
            },
            .pointer_listener = .{
                .enter = onPointerEnter,
                .leave = onPointerLeave,
                .motion = onPointerMotion,
                .button = onPointerButton,
                .axis = onPointerAxis,
                .frame = onPointerFrame,
                .axis_source = onPointerAxisSource,
                .axis_stop = onPointerAxisStop,
                .axis_discrete = onPointerAxisDiscrete,
                .axis_value120 = onPointerAxisValue120,
                .axis_relative_direction = onPointerAxisRelativeDirection,
            },
        };
        errdefer state.events.deinit(gpa);
        errdefer {
            for (state.outputs.items) |entry| gpa.destroy(entry);
            state.outputs.deinit(gpa);
        }

        // M0.3 — publish the active state so `enumerateMonitors` can
        // reach it without a backend-pointer parameter. Single-window
        // model — Phase 0+ multi-window upgrade tracked separately.
        live_state = state;
        errdefer live_state = null;

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

        // M0.3 — clear the live_state pointer before tearing down.
        if (live_state == s) live_state = null;

        // Release input device proxies (release request added in
        // wl_seat v5 + wl_keyboard / wl_pointer; safe to call on all
        // versions we bind, ≤ 7).
        if (s.keyboard) |kb| kb.release();
        if (s.pointer) |ptr| ptr.release();
        if (s.seat) |seat| seat.release();

        // Free output entries (each was heap-allocated in onRegistryGlobal).
        for (s.outputs.items) |entry| {
            entry.proxy.release();
            s.gpa.destroy(entry);
        }
        s.outputs.deinit(s.gpa);

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
    } else if (std.mem.eql(u8, iface_str, "wl_seat")) {
        // M0.3 — bind wl_seat at version ≤ 7 (we use keymap fd, repeat_info).
        const v = @min(version, 7);
        const proxy = registry.bind(name, &core.wl_seat_interface, v) catch return;
        state.seat = @ptrCast(@alignCast(proxy));
        state.seat.?.addListener(&state.seat_listener, state) catch {};
    } else if (std.mem.eql(u8, iface_str, "wl_output")) {
        // M0.3 — bind wl_output at version ≤ 4 (we use name event).
        const v = @min(version, 4);
        const proxy = registry.bind(name, &core.wl_output_interface, v) catch return;

        const entry = state.gpa.create(OutputEntry) catch return;
        entry.* = .{
            .state = state,
            .registry_name = name,
            .proxy = @ptrCast(@alignCast(proxy)),
            .listener = .{
                .geometry = onOutputGeometry,
                .mode = onOutputMode,
                .done = onOutputDone,
                .scale = onOutputScale,
                .name = onOutputName,
                .description = onOutputDescription,
            },
            .info = .{
                .id = @truncate(@intFromPtr(proxy)),
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
                .dpi_scale = 1.0,
            },
        };
        state.outputs.append(state.gpa, entry) catch {
            state.gpa.destroy(entry);
            return;
        };
        entry.proxy.addListener(&entry.listener, entry) catch {};
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
    _ = proxy;
    const state: *State = @ptrCast(@alignCast(data.?));
    const mon_id: u32 = @truncate(@intFromPtr(output));
    if (state.current_output_id != mon_id) {
        state.current_output_id = mon_id;
        state.events.append(state.gpa, .{ .monitor_changed = mon_id }) catch {};
    }
}

fn onSurfaceLeave(
    data: ?*anyopaque,
    proxy: *core.wl_surface,
    output: *core.wl_output,
) callconv(.c) void {
    _ = proxy;
    const state: *State = @ptrCast(@alignCast(data.?));
    const mon_id: u32 = @truncate(@intFromPtr(output));
    if (state.current_output_id == mon_id) {
        state.current_output_id = null;
    }
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

// ============================================================== M0.3 callbacks

// ----- wl_seat -----

fn onSeatCapabilities(
    data: ?*anyopaque,
    seat: *core.wl_seat,
    capabilities: u32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));
    const HAS_POINTER: u32 = 1;
    const HAS_KEYBOARD: u32 = 2;

    // Acquire keyboard if the seat advertises one and we don't have it yet.
    if ((capabilities & HAS_KEYBOARD) != 0 and state.keyboard == null) {
        const kb = seat.getKeyboard() catch return;
        state.keyboard = kb;
        kb.addListener(&state.keyboard_listener, state) catch {};
    } else if ((capabilities & HAS_KEYBOARD) == 0 and state.keyboard != null) {
        state.keyboard.?.release();
        state.keyboard = null;
    }

    if ((capabilities & HAS_POINTER) != 0 and state.pointer == null) {
        const ptr = seat.getPointer() catch return;
        state.pointer = ptr;
        ptr.addListener(&state.pointer_listener, state) catch {};
    } else if ((capabilities & HAS_POINTER) == 0 and state.pointer != null) {
        state.pointer.?.release();
        state.pointer = null;
    }
}

fn onSeatName(data: ?*anyopaque, seat: *core.wl_seat, name: [*:0]const u8) callconv(.c) void {
    _ = .{ data, seat, name };
}

// ----- wl_keyboard -----

fn onKeyboardKeymap(
    data: ?*anyopaque,
    proxy: *core.wl_keyboard,
    format: u32,
    fd: std.posix.fd_t,
    size: u32,
) callconv(.c) void {
    _ = .{ data, proxy, format, size };
    // Close the fd — M0.3 does not parse XKB keymaps (layout-aware text input
    // is Phase 1+, cf. brief § Out-of-scope). The keymap fd must still be
    // closed to avoid leaking it.
    _ = std.c.close(fd);
}

fn onKeyboardEnter(
    data: ?*anyopaque,
    proxy: *core.wl_keyboard,
    serial: u32,
    surface: *core.wl_surface,
    keys: *core.WlArray,
) callconv(.c) void {
    _ = .{ proxy, serial, keys };
    const state: *State = @ptrCast(@alignCast(data.?));
    state.keyboard_focus = surface;
    state.events.append(state.gpa, .focus_gained) catch {};
}

fn onKeyboardLeave(
    data: ?*anyopaque,
    proxy: *core.wl_keyboard,
    serial: u32,
    surface: *core.wl_surface,
) callconv(.c) void {
    _ = .{ proxy, serial, surface };
    const state: *State = @ptrCast(@alignCast(data.?));
    state.keyboard_focus = null;
    state.events.append(state.gpa, .focus_lost) catch {};
}

fn onKeyboardKey(
    data: ?*anyopaque,
    proxy: *core.wl_keyboard,
    serial: u32,
    time: u32,
    key: u32,
    key_state: u32,
) callconv(.c) void {
    _ = .{ proxy, serial, time };
    const state: *State = @ptrCast(@alignCast(data.?));
    const code = keycode_mod.mapFromEvdevCode(key);
    if (key_state == KEY_STATE_PRESSED) {
        state.events.append(state.gpa, .{ .key_down = .{
            .code = code,
            .scancode = @intCast(key & 0xFFFF),
            .repeat = false,
        } }) catch {};
    } else {
        state.events.append(state.gpa, .{ .key_up = .{
            .code = code,
            .scancode = @intCast(key & 0xFFFF),
        } }) catch {};
    }
}

fn onKeyboardModifiers(
    data: ?*anyopaque,
    proxy: *core.wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = .{ data, proxy, serial, mods_depressed, mods_latched, mods_locked, group };
    // M0.3 does not surface modifier-state events — gameplay can read the
    // pressed bitset directly. Phase 1+ Input Tier 1 may consume modifiers
    // for chorded actions.
}

fn onKeyboardRepeatInfo(
    data: ?*anyopaque,
    proxy: *core.wl_keyboard,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = .{ data, proxy, rate, delay };
}

// ----- wl_pointer -----

fn onPointerEnter(
    data: ?*anyopaque,
    proxy: *core.wl_pointer,
    serial: u32,
    surface: *core.wl_surface,
    surface_x: core.Fixed,
    surface_y: core.Fixed,
) callconv(.c) void {
    _ = .{ proxy, serial };
    const state: *State = @ptrCast(@alignCast(data.?));
    state.pointer_focus = surface;
    state.last_pointer_x = @floatCast(surface_x.toDouble());
    state.last_pointer_y = @floatCast(surface_y.toDouble());
    state.pointer_in_window = true;
}

fn onPointerLeave(
    data: ?*anyopaque,
    proxy: *core.wl_pointer,
    serial: u32,
    surface: *core.wl_surface,
) callconv(.c) void {
    _ = .{ proxy, serial, surface };
    const state: *State = @ptrCast(@alignCast(data.?));
    state.pointer_focus = null;
    state.pointer_in_window = false;
}

fn onPointerMotion(
    data: ?*anyopaque,
    proxy: *core.wl_pointer,
    time: u32,
    surface_x: core.Fixed,
    surface_y: core.Fixed,
) callconv(.c) void {
    _ = .{ proxy, time };
    const state: *State = @ptrCast(@alignCast(data.?));
    const x: f32 = @floatCast(surface_x.toDouble());
    const y: f32 = @floatCast(surface_y.toDouble());
    const dx: f32 = if (state.pointer_in_window) x - state.last_pointer_x else 0;
    const dy: f32 = if (state.pointer_in_window) y - state.last_pointer_y else 0;
    state.last_pointer_x = x;
    state.last_pointer_y = y;
    state.pointer_in_window = true;
    state.events.append(state.gpa, .{ .mouse_motion = .{
        .x = x,
        .y = y,
        .dx = dx,
        .dy = dy,
    } }) catch {};
}

fn onPointerButton(
    data: ?*anyopaque,
    proxy: *core.wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    button_state: u32,
) callconv(.c) void {
    _ = .{ proxy, serial, time };
    const state: *State = @ptrCast(@alignCast(data.?));
    const mb: window.MouseButton = switch (button) {
        BTN_LEFT => .left,
        BTN_RIGHT => .right,
        BTN_MIDDLE => .middle,
        BTN_SIDE => .x1,
        BTN_EXTRA => .x2,
        else => @enumFromInt(@as(u8, @truncate(button & 0xFF))),
    };
    state.events.append(state.gpa, .{ .mouse_button = .{
        .button = mb,
        .pressed = button_state == POINTER_BUTTON_PRESSED,
        .x = state.last_pointer_x,
        .y = state.last_pointer_y,
    } }) catch {};
}

fn onPointerAxis(
    data: ?*anyopaque,
    proxy: *core.wl_pointer,
    time: u32,
    axis: u32,
    value: core.Fixed,
) callconv(.c) void {
    _ = .{ proxy, time };
    const state: *State = @ptrCast(@alignCast(data.?));
    const v: f32 = @floatCast(value.toDouble());
    // Wayland positive vertical = scroll down; Weld convention positive
    // dy = scroll up → flip sign for vertical.
    const evt: window.Event = if (axis == AXIS_VERTICAL_SCROLL)
        .{ .mouse_wheel = .{ .dx = 0, .dy = -v / 10.0 } }
    else
        .{ .mouse_wheel = .{ .dx = v / 10.0, .dy = 0 } };
    state.events.append(state.gpa, evt) catch {};
}

fn onPointerFrame(data: ?*anyopaque, proxy: *core.wl_pointer) callconv(.c) void {
    _ = .{ data, proxy };
}

fn onPointerAxisSource(data: ?*anyopaque, proxy: *core.wl_pointer, axis_source: u32) callconv(.c) void {
    _ = .{ data, proxy, axis_source };
}

fn onPointerAxisStop(data: ?*anyopaque, proxy: *core.wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = .{ data, proxy, time, axis };
}

fn onPointerAxisDiscrete(data: ?*anyopaque, proxy: *core.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    _ = .{ data, proxy, axis, discrete };
}

fn onPointerAxisValue120(data: ?*anyopaque, proxy: *core.wl_pointer, axis: u32, value120: i32) callconv(.c) void {
    _ = .{ data, proxy, axis, value120 };
}

fn onPointerAxisRelativeDirection(data: ?*anyopaque, proxy: *core.wl_pointer, axis: u32, direction: u32) callconv(.c) void {
    _ = .{ data, proxy, axis, direction };
}

// ----- wl_output -----

fn onOutputGeometry(
    data: ?*anyopaque,
    proxy: *core.wl_output,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    make: [*:0]const u8,
    model: [*:0]const u8,
    transform: i32,
) callconv(.c) void {
    _ = .{ proxy, physical_width, physical_height, subpixel, transform };
    const entry: *OutputEntry = @ptrCast(@alignCast(data.?));
    entry.info.x = x;
    entry.info.y = y;

    // Build a "make model" name into MonitorInfo.name (truncated to 63 + NUL).
    var w: usize = 0;
    const make_slice = std.mem.span(make);
    var i: usize = 0;
    while (i < make_slice.len and w + 1 < entry.info.name.len) : (i += 1) {
        entry.info.name[w] = make_slice[i];
        w += 1;
    }
    if (w + 1 < entry.info.name.len) {
        entry.info.name[w] = ' ';
        w += 1;
    }
    const model_slice = std.mem.span(model);
    i = 0;
    while (i < model_slice.len and w + 1 < entry.info.name.len) : (i += 1) {
        entry.info.name[w] = model_slice[i];
        w += 1;
    }
    entry.info.name[w] = 0;
}

fn onOutputMode(
    data: ?*anyopaque,
    proxy: *core.wl_output,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = .{ proxy, refresh };
    const entry: *OutputEntry = @ptrCast(@alignCast(data.?));
    // Bit 0 of flags = current. Only record the active mode.
    if ((flags & 0x01) != 0 and width > 0 and height > 0) {
        entry.info.width = @intCast(width);
        entry.info.height = @intCast(height);
    }
}

fn onOutputDone(data: ?*anyopaque, proxy: *core.wl_output) callconv(.c) void {
    _ = proxy;
    const entry: *OutputEntry = @ptrCast(@alignCast(data.?));
    entry.initialized = true;
}

fn onOutputScale(data: ?*anyopaque, proxy: *core.wl_output, factor: i32) callconv(.c) void {
    _ = proxy;
    const entry: *OutputEntry = @ptrCast(@alignCast(data.?));
    if (factor > 0) {
        const scale_f: f32 = @floatFromInt(factor);
        entry.info.dpi_scale = scale_f;
        if (entry.state.current_output_id == entry.info.id) {
            entry.state.events.append(entry.state.gpa, .{ .dpi_changed_per_monitor = .{
                .monitor = entry.info.id,
                .scale = scale_f,
            } }) catch {};
        }
    }
}

fn onOutputName(data: ?*anyopaque, proxy: *core.wl_output, name: [*:0]const u8) callconv(.c) void {
    _ = .{ data, proxy, name };
    // We already populate `name` from geometry's make+model; skip the
    // wl_output.name event (which delivers a connector name like "DP-1").
}

fn onOutputDescription(data: ?*anyopaque, proxy: *core.wl_output, description: [*:0]const u8) callconv(.c) void {
    _ = .{ data, proxy, description };
}

// ============================================================== M0.3 queries

/// Wayland implementation of `enumerateMonitors`. Returns a snapshot of
/// the cached `wl_output` table. Caller owns the slice.
pub fn enumerateMonitors(gpa: std.mem.Allocator) std.mem.Allocator.Error![]window.MonitorInfo {
    // The Wayland backend keeps the State on the heap; we need a way to
    // reach it from a free function. Phase 0.3 limitation: only the
    // most-recently-created window's State is queried (single-window
    // model — multi-window comes later). We approximate by reading from
    // the first Backend's State; the public API is hooked through
    // `window.zig` which calls into this function without a window
    // reference, so we have no choice but to return an empty list until
    // a more general design (a module-level singleton or a backend
    // parameter through the public API) is wired in.
    //
    // For M0.3 acceptance, the test creates a window then queries —
    // `currentMonitor(window)` is the supported path; `enumerateMonitors`
    // returns the snapshot iff we can hook a live State. We return an
    // empty slice when no live State is available.
    if (live_state) |state| {
        var list = try std.ArrayList(window.MonitorInfo).initCapacity(gpa, state.outputs.items.len);
        errdefer list.deinit(gpa);
        for (state.outputs.items) |entry| {
            try list.append(gpa, entry.info);
        }
        return list.toOwnedSlice(gpa);
    }
    return gpa.alloc(window.MonitorInfo, 0);
}

/// Wayland implementation of `currentMonitor`. Returns the id of the
/// `wl_output` the surface is currently mapped on (from
/// `wl_surface.enter`).
pub fn currentMonitor(backend_ptr: *const Backend) ?u32 {
    return backend_ptr.state.current_output_id;
}

// Best-effort live-state pointer for the free-function `enumerateMonitors`
// dispatched from `window.zig`. Set in `create` after State allocation,
// cleared in `destroy`. Single-window model — Phase 0+ multi-window
// support will replace this with a proper module-level registry.
var live_state: ?*State = null;
