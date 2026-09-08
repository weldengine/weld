//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! `NativeHandles`, `Window.nativeHandles`, `classAtom` and `classOpenCount` sit
//! OUTSIDE that marker. The fallback backend refuses at RUNTIME, not at comptime.

const std = @import("std");
const builtin = @import("builtin");
const keycode_mod = @import("input/keycode.zig");

const backend = switch (builtin.os.tag) {
    .windows => @import("window/win32.zig"),
    .linux => @import("window/wayland.zig"),
    else => @import("window/stub.zig"),
};

/// Re-export of the normalized `KeyCode` enum.
pub const KeyCode = keycode_mod.KeyCode;

/// Mouse button identifier surfaced by `Event.mouse_button`.
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    /// "Back" — `x2` is "forward"; the pair follows Win32 XBUTTON1/XBUTTON2.
    x1 = 3,
    x2 = 4,
    _,
};

/// Static information about a connected display.
pub const MonitorInfo = struct {
    /// OS-stable monitor identifier — opaque to the caller.
    id: u32,
    /// Bounds of the monitor in virtual desktop coordinates.
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    /// HiDPI scale factor (1.0 = 100%, 1.5 = 150%, 2.0 = 200%).
    dpi_scale: f32,
    /// Human-readable monitor name, NUL-padded.
    name: [64]u8 = [_]u8{0} ** 64,
};

/// Creation descriptor for a `Window` — title and initial dimensions.
pub const Desc = struct {
    title: [:0]const u8 = "Weld S2",
    width: u32 = 800,
    height: u32 = 600,
};

/// Closed enum of window events surfaced by `pollEvent`.
pub const Event = union(enum) {
    close,
    /// Client area resized — both fields are physical pixels (HiDPI-aware).
    resize: struct { width: u32, height: u32 },
    /// Scale factor changed; 1.0 is 100 %.
    dpi_changed: f32,

    /// Physical key pressed; `code` is normalized, `scancode` is the raw OS one.
    key_down: struct { code: KeyCode, scancode: u16, repeat: bool },

    key_up: struct { code: KeyCode, scancode: u16 },

    /// Cursor moved. `x` / `y` are client-area absolute, `dx` / `dy` relative.
    mouse_motion: struct { x: f32, y: f32, dx: f32, dy: f32 },

    mouse_button: struct { button: MouseButton, pressed: bool, x: f32, y: f32 },

    /// Wheel scrolled; `dx` horizontal, positive right.
    mouse_wheel: struct { dx: f32, dy: f32 },

    focus_gained,

    focus_lost,

    minimize,

    restore,

    /// A gamepad was connected. `slot` is the 0–3 player index.
    gamepad_connected: u8,

    gamepad_disconnected: u8,

    monitor_changed: u32,

    /// Per-monitor DPI — DISTINCT from `dpi_changed`, which is the window's own.
    dpi_changed_per_monitor: struct { monitor: u32, scale: f32 },
};

/// Error set for `Window.create` / `Window.destroy`.
pub const Error = error{
    UnsupportedPlatform,
    BackendInitFailed,
    WindowCreateFailed,
} || std.mem.Allocator.Error;

/// Native OS handles the GPU layer needs to create a surface.
pub const NativeHandles = backend.NativeHandles;

/// Public window handle over the per-OS backend.
pub const Window = struct {
    impl: backend.Backend,

    pub fn create(gpa: std.mem.Allocator, desc: Desc) Error!Window {
        return .{ .impl = try backend.Backend.create(gpa, desc) };
    }

    pub fn destroy(self: *Window) void {
        self.impl.destroy();
    }

    /// Request a close. The caller must still drain events until the queue empties.
    pub fn close(self: *Window) void {
        self.impl.close();
    }

    pub fn pollEvent(self: *Window) ?Event {
        return self.impl.pollEvent();
    }

    pub fn nativeHandles(self: *const Window) NativeHandles {
        return self.impl.nativeHandles();
    }
};

/// The live Win32 class atom, or 0 on a backend that has none.
pub fn classAtom() u16 {
    return if (@hasDecl(backend, "classAtom")) backend.classAtom() else 0;
}

/// The live-window refcount, or 0 on a backend that has none.
pub fn classOpenCount() u32 {
    return if (@hasDecl(backend, "classOpenCount")) backend.classOpenCount() else 0;
}

/// Errors surfaced by the multi-monitor query API.
pub const QueryError = error{
    UnsupportedPlatform,
} || std.mem.Allocator.Error;

/// Enumerate connected monitors; the caller owns the returned slice.
pub fn enumerateMonitors(gpa: std.mem.Allocator) QueryError![]MonitorInfo {
    if (@hasDecl(backend, "enumerateMonitors")) return backend.enumerateMonitors(gpa);
    return error.UnsupportedPlatform;
}

/// Identifier of the monitor the window resides on.
pub fn currentMonitor(window: *const Window) ?u32 {
    if (@hasDecl(backend, "currentMonitor")) return backend.currentMonitor(&window.impl);
    return null;
}
