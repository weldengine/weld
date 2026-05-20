//! Stub `Window` backend for platforms outside the S2 scope (macOS, etc.).
//!
//! Compiles so the rest of the engine is still buildable on macOS while
//! S2 is in progress; every entry point returns `error.UnsupportedPlatform`
//! at runtime. Phase 4+ replaces this with a real Cocoa backend.

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
