//! Stub `Window` backend for platforms outside the supported set.
//!
//! The X11 backend is abandoned: on Linux, Weld is Wayland-native only. Fedora 44
//! and Ubuntu 26.04 ship Wayland-only sessions by default, XWayland covers legacy
//! X11 clients, and Weld has a native Wayland backend. No X11 backend will be
//! implemented unless a concrete external requirement appears
//! (`engine-phase-0-criteria.md` §C0.7).
//!
//! Darwin / macOS would land via Cocoa + Metal. Until then, this
//! stub returns `error.UnsupportedPlatform` on macOS so the rest of the
//! engine remains buildable for tools/headless CI passes.

const std = @import("std");
const window = @import("../window.zig");

/// Empty native-handle shape — the stub backend has no Vulkan surface.
pub const NativeHandles = struct {};

/// Stub window backend used on unsupported OSes; every method returns
/// `error.UnsupportedPlatform`.
pub const Backend = struct {
    pub fn create(gpa: std.mem.Allocator, desc: window.Desc) window.Error!Backend {
        _ = gpa;
        _ = desc;
        return error.UnsupportedPlatform;
    }

    pub fn destroy(self: *Backend) void {
        _ = self;
    }

    pub fn close(self: *Backend) void {
        _ = self;
    }

    pub fn pollEvent(self: *Backend) ?window.Event {
        _ = self;
        return null;
    }

    pub fn nativeHandles(self: *const Backend) NativeHandles {
        _ = self;
        return .{};
    }
};
