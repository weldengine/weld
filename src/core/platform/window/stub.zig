//! Stub `Window` backend for platforms outside the Phase 0 scope.
//!
//! Phase 0.3 / M0.3 acts the abandoned X11 backend definitively — Weld
//! Linux = Wayland natif uniquement Phase 0+ (cf. `engine-phase-0-plan.md`
//! M0.3, debt D-S2-x11 closed as abandoned; `engine-phase-0-criteria.md`
//! §C0.7 patched). Fedora 44 + Ubuntu 26.04 ship Wayland-only sessions
//! by default; XWayland covers legacy X11 clients but Weld has a native
//! Wayland backend since S2. No X11 backend will be implemented unless
//! Phase 2/3 surfaces a concrete external requirement.
//!
//! Darwin / macOS lands in Phase 2 via Cocoa + Metal. Until then, this
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
