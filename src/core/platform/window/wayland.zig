//! Wayland `Window` backend — placeholder for S2 step (e).
//!
//! Step (d) ships only the Win32 backend; the Wayland implementation
//! lands in step (e). This file currently returns
//! `error.UnsupportedPlatform` at runtime so Linux builds keep
//! compiling against the public `Window` interface. Replaced by the
//! real backend in the next commit.

const std = @import("std");
const window = @import("../window.zig");

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
};
