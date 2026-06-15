//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//! Frozen PlatformLayer window surface: `Window`, `Event`, `Desc`, `Error`,
//! `KeyCode` (re-export), `MouseButton`, `MonitorInfo`, `QueryError`,
//! `enumerateMonitors`, `currentMonitor`. EXCEPTION — `NativeHandles` /
//! `Window.nativeHandles` are FROZEN-but-transient (the Phase-0.4 GAL
//! absorbs surface creation; see the `NativeHandles` doc). The
//! `classAtom`/`classOpenCount` accessors are test-support diagnostics, not
//! part of the frozen contract. Covered by `WELD_PLATFORM_PROTOCOL_VERSION`
//! (and the input variants by `WELD_INPUT_PROTOCOL_VERSION`).
//!
//! Public `Window` interface for the S2 spike. Tier 0 from S2 onward —
//! the surface defined here (`create`, `destroy`, `close`, `resize` event
//! delivery, `dpi_changed` event delivery) is stable. Phase 0.3 extends
//! the same struct with input events + an X11 backend; existing call
//! sites do not change.
//!
//! Comptime dispatch picks the OS backend:
//!   - Windows  → `window/win32.zig`
//!   - Linux    → `window/wayland.zig`  (wired in S2 step e)
//!   - other    → `window/stub.zig`     (compiles, returns
//!                                       `error.UnsupportedPlatform` at
//!                                       runtime — keeps the rest of the
//!                                       engine buildable on macOS while
//!                                       S2 is in progress)
//!
//! S2 scoped this surface tight (windowing only). M0.3 then added the
//! input/focus/minimize-restore/multi-monitor surface that is now part of
//! the frozen contract: the `Event` union's key/mouse/focus/minimize/dpi
//! variants, plus `MonitorInfo` + `enumerateMonitors`/`currentMonitor`.

const std = @import("std");
const builtin = @import("builtin");
const keycode_mod = @import("input/keycode.zig");

const backend = switch (builtin.os.tag) {
    .windows => @import("window/win32.zig"),
    .linux => @import("window/wayland.zig"),
    else => @import("window/stub.zig"),
};

/// Re-export of the normalized `KeyCode` enum (cf. `input/keycode.zig`).
/// Available at `weld.platform.window.KeyCode` so consumers of `Event`
/// can pattern-match on the normalized identifier without a second import.
pub const KeyCode = keycode_mod.KeyCode;

/// Mouse button identifier surfaced by `Event.mouse_button`.
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    /// Side button "back" (forward-navigation in browsers).
    x1 = 3,
    /// Side button "forward".
    x2 = 4,
    _,
};

/// Static information about a connected display, returned by
/// `enumerateMonitors` and pointed at by `currentMonitor`.
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
    /// Human-readable monitor name (vendor + model on Win32 /
    /// connector name on Wayland). Null-terminated.
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
    /// User requested the window be closed (X button, Alt-F4, …).
    close,
    /// Client area resized — both fields are physical pixels (HiDPI-aware).
    resize: struct { width: u32, height: u32 },
    /// Scale factor changed (1.0 = 100%, 1.5 = 150%, 2.0 = 200%). Derived
    /// from per-monitor DPI on Win32; Wayland S2 only delivers integer
    /// values. The window has already been moved/resized to track the new
    /// monitor; the caller is expected to recreate the swapchain.
    dpi_changed: f32,

    // ============================ M0.3 additions ============================

    /// Physical key pressed. `code` is the normalized identifier (see
    /// `KeyCode`); `scancode` is the raw OS scan code for advanced
    /// applications that need exact hardware identity. `repeat` is true
    /// when the OS auto-repeats the key while held.
    key_down: struct { code: KeyCode, scancode: u16, repeat: bool },

    /// Physical key released.
    key_up: struct { code: KeyCode, scancode: u16 },

    /// Mouse cursor moved. `x` / `y` are client-area absolute coordinates
    /// in physical pixels; `dx` / `dy` are the per-frame delta accumulated
    /// from raw input (high-DPI mice send sub-pixel deltas — `dx` / `dy`
    /// are pre-rounded to integer pixels here).
    mouse_motion: struct { x: f32, y: f32, dx: f32, dy: f32 },

    /// Mouse button pressed or released at the current cursor position.
    mouse_button: struct { button: MouseButton, pressed: bool, x: f32, y: f32 },

    /// Mouse wheel scrolled. `dx` is horizontal (positive = right);
    /// `dy` is vertical (positive = up, standard convention).
    mouse_wheel: struct { dx: f32, dy: f32 },

    /// Window received keyboard focus.
    focus_gained,

    /// Window lost keyboard focus.
    focus_lost,

    /// Window was minimized (iconified).
    minimize,

    /// Window restored from minimize (or initially shown).
    restore,

    /// A gamepad was connected. `slot` is the 0–3 player index.
    gamepad_connected: u8,

    /// A gamepad was disconnected.
    gamepad_disconnected: u8,

    /// The window's primary monitor changed (dragged to a different
    /// display). `id` is the new monitor's `MonitorInfo.id`.
    monitor_changed: u32,

    /// Per-monitor DPI changed. Distinct from `dpi_changed` which only
    /// surfaces the process-global scale — this variant identifies the
    /// monitor that changed so multi-monitor apps can keep per-monitor
    /// state.
    dpi_changed_per_monitor: struct { monitor: u32, scale: f32 },
};

/// Error set for `Window.create` / `Window.destroy`.
pub const Error = error{
    UnsupportedPlatform,
    BackendInitFailed,
    WindowCreateFailed,
} || std.mem.Allocator.Error;

/// Native OS-level handles needed by the GPU layer to create a
/// `VkSurfaceKHR`. Layout per OS — Windows wants `(HINSTANCE, HWND)`,
/// Wayland wants `(*wl_display, *wl_surface)`, and the stub backend
/// returns an empty struct.
///
/// Not part of the long-term Tier 0 surface — the Phase 0.4 GAL absorbs
/// surface creation behind a backend-agnostic API. Its consumer is the
/// render GAL's Vulkan surface creation
/// (`src/modules/render/gal/vulkan/surface.zig`). FROZEN-but-transient:
/// slated for Phase-0.4 GAL re-evaluation, not a permanent contract.
pub const NativeHandles = backend.NativeHandles;

/// Public Window handle — five-method front-end above the per-OS
/// backend (`create`, `destroy`, `close`, `pollEvent`,
/// `nativeHandles`).
pub const Window = struct {
    impl: backend.Backend,

    pub fn create(gpa: std.mem.Allocator, desc: Desc) Error!Window {
        return .{ .impl = try backend.Backend.create(gpa, desc) };
    }

    pub fn destroy(self: *Window) void {
        self.impl.destroy();
    }

    /// Programmatic close request. The caller should still drain
    /// `pollEvent` until it returns null and then call `destroy`.
    pub fn close(self: *Window) void {
        self.impl.close();
    }

    /// Pull the next pending event, or `null` if the queue is drained.
    /// Internally pumps the OS event loop on each call.
    pub fn pollEvent(self: *Window) ?Event {
        return self.impl.pollEvent();
    }

    /// Transient S2 escape hatch — see `NativeHandles` doc above.
    pub fn nativeHandles(self: *const Window) NativeHandles {
        return self.impl.nativeHandles();
    }
};

// M0.3 — diagnostics surfaced for the Win32 thread safety stress test
// (`tests/platform/win32_thread_safety_test.zig`). On non-Windows
// backends both accessors return 0 — the test skips with
// `error.SkipZigTest` so the values are never observed there.

/// Returns the live class atom registered with the Win32 window manager.
/// On non-Windows builds, returns 0 (no class atom concept). Used by
/// the thread-safety stress test to confirm stability across 8×1000 cycles.
pub fn classAtom() u16 {
    return if (@hasDecl(backend, "classAtom")) backend.classAtom() else 0;
}

/// Returns the current live-window refcount. Phase 0.3 Win32 backend
/// keeps the class registered for process lifetime; `class_open_count`
/// goes back to 0 once all windows have been destroyed. Used by the
/// thread-safety stress test to assert balanced create/destroy.
pub fn classOpenCount() u32 {
    return if (@hasDecl(backend, "classOpenCount")) backend.classOpenCount() else 0;
}

// =============================================================== Multi-monitor

/// Errors surfaced by the multi-monitor query API.
pub const QueryError = error{
    UnsupportedPlatform,
} || std.mem.Allocator.Error;

/// Enumerate all connected monitors. Caller owns the returned slice and
/// must `gpa.free` it. The list is ordered as the OS reports it (Win32
/// `EnumDisplayMonitors`, Wayland `wl_registry` globals).
pub fn enumerateMonitors(gpa: std.mem.Allocator) QueryError![]MonitorInfo {
    if (@hasDecl(backend, "enumerateMonitors")) return backend.enumerateMonitors(gpa);
    return error.UnsupportedPlatform;
}

/// Identifier of the monitor the window currently resides on. Returns
/// null if the window has not yet been mapped to a monitor (Wayland
/// before the first `wl_surface.enter` event) or if the backend cannot
/// determine it.
pub fn currentMonitor(window: *const Window) ?u32 {
    if (@hasDecl(backend, "currentMonitor")) return backend.currentMonitor(&window.impl);
    return null;
}
