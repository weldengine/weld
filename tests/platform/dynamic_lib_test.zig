//! Tests M0.3 — `DynamicLib.open` / `lookup` / `close` round-trip.
//!
//! Covers the acceptance test called out in the M0.3 brief:
//!   - "open + lookup + close on system library" — opens libc.so.6 /
//!     libSystem.B.dylib / kernel32.dll, looks up a well-known symbol,
//!     closes without crash.

const std = @import("std");
const weld = @import("weld_core");
const dlib = weld.platform.dynamic_lib;
const builtin = @import("builtin");

test "open + lookup + close on system library" {
    const gpa = std.testing.allocator;

    const lib_path = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "/usr/lib/libSystem.B.dylib",
        .windows => "kernel32.dll",
        else => return error.SkipZigTest,
    };

    const sym = switch (builtin.os.tag) {
        .linux, .macos => "memcpy",
        .windows => "GetTickCount",
        else => return error.SkipZigTest,
    };

    var lib = try dlib.DynamicLib.open(gpa, lib_path);
    defer lib.close();

    const ptr = try lib.lookup(gpa, sym);
    try std.testing.expect(@intFromPtr(ptr) != 0);
}

test "open returns LibraryNotFound for missing lib" {
    const gpa = std.testing.allocator;
    const result = dlib.DynamicLib.open(gpa, "weld_definitely_missing_lib_xyz.so.999");
    try std.testing.expectError(error.LibraryNotFound, result);
}

test "lookup returns SymbolNotFound for absent symbol" {
    const gpa = std.testing.allocator;
    const lib_path = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "/usr/lib/libSystem.B.dylib",
        .windows => "kernel32.dll",
        else => return error.SkipZigTest,
    };
    var lib = try dlib.DynamicLib.open(gpa, lib_path);
    defer lib.close();

    const result = lib.lookup(gpa, "weld_definitely_missing_symbol_xyz");
    try std.testing.expectError(error.SymbolNotFound, result);
}
