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
//! The brief deliberately scopes this surface tight: no input handling,
//! no focus, no minimize/restore, no multi-monitor. Those land in 0.3.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .windows => @import("window/win32.zig"),
    .linux => @import("window/wayland.zig"),
    else => @import("window/stub.zig"),
};

pub const Desc = struct {
    title: [:0]const u8 = "Weld S2",
    width: u32 = 800,
    height: u32 = 600,
};

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
};

pub const Error = error{
    UnsupportedPlatform,
    BackendInitFailed,
    WindowCreateFailed,
} || std.mem.Allocator.Error;

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
};
