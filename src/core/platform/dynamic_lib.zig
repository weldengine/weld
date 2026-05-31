//! Dynamic library loader — `DynamicLib { open, lookup, close }`.
//!
//! Phase 0.3 / M0.3 deliverable. Documented in `engine-platform.md` §4
//! (Dynamic loader section) and the M0.3 brief.
//!
//! Consistent with `engine-c-bindings.md` §4.6 (dlopen-by-strategy pattern)
//! and `engine-c-bindings.md` §4.6.5 (per-module load lifecycle).
//! The bindgen generator will produce the Symbols structs on top of this
//! low-level layer — `DynamicLib` is the portable API used by the
//! generated bindings Phase 1+.
//!
//! Backends:
//!   - Win32  : `LoadLibraryW` + `GetProcAddress` + `FreeLibrary`
//!   - POSIX  : `dlopen` + `dlsym` + `dlclose`
//!
//! ## Path semantics
//!
//! Paths are passed as UTF-8 byte slices. On Win32 they are converted to
//! UTF-16 (`LoadLibraryW`); on POSIX they are passed null-terminated to
//! `dlopen`. The caller is responsible for picking an OS-appropriate path
//! (`opus-0.dll` vs `libopus.so.0` vs `libopus.0.dylib`) — `DynamicLib`
//! itself does not do soname mangling.
//!
//! The higher-level bindgen `dlopen` strategy adds the multi-version
//! fallback on top (cf. `engine-c-bindings.md` §4.6.1).

const std = @import("std");
const builtin = @import("builtin");

/// Errors surfaced by `DynamicLib.open` / `lookup` / `close`.
pub const Error = error{
    LibraryNotFound,
    SymbolNotFound,
    InvalidPath,
} || std.mem.Allocator.Error;

const win = struct {
    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.winapi) i32;
};

const posix = struct {
    extern "c" fn dlopen(filename: ?[*:0]const u8, flag: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
    extern "c" fn dlclose(handle: *anyopaque) c_int;
    // RTLD_NOW = resolve all symbols at open. RTLD_LOCAL keeps the lib
    // private to this handle. These values are stable across glibc, musl,
    // and macOS dyld.
    const RTLD_LAZY: c_int = 1;
    const RTLD_NOW: c_int = switch (builtin.os.tag) {
        .linux => 2,
        .macos => 2,
        else => 2,
    };
    const RTLD_LOCAL: c_int = 0;
};

/// Opaque OS-level dynamic library handle. Returned by `open`, consumed by
/// `lookup` and `close`.
pub const DynamicLib = struct {
    handle: *anyopaque,

    /// Open a shared library by path. Path is interpreted by the OS loader
    /// rules (PATH, LD_LIBRARY_PATH, dyld search, etc.). Returns
    /// `error.LibraryNotFound` if the loader cannot resolve.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) Error!DynamicLib {
        switch (builtin.os.tag) {
            .windows => {
                // Convert UTF-8 -> UTF-16 (LoadLibraryW). std.unicode helpers.
                const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidPath,
                };
                defer gpa.free(wide);
                const h = win.LoadLibraryW(wide.ptr) orelse return error.LibraryNotFound;
                return .{ .handle = h };
            },
            .linux, .macos => {
                const path_z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
                defer gpa.free(path_z);
                const h = posix.dlopen(path_z.ptr, posix.RTLD_NOW | posix.RTLD_LOCAL) orelse {
                    return error.LibraryNotFound;
                };
                return .{ .handle = h };
            },
            else => return error.LibraryNotFound,
        }
    }

    /// Resolve a symbol from the opened library. Returns the raw pointer;
    /// caller is responsible for `@ptrCast` to the appropriate function
    /// pointer type.
    pub fn lookup(self: DynamicLib, gpa: std.mem.Allocator, symbol: []const u8) Error!*const anyopaque {
        const symbol_z = gpa.dupeZ(u8, symbol) catch return error.OutOfMemory;
        defer gpa.free(symbol_z);
        switch (builtin.os.tag) {
            .windows => {
                const p = win.GetProcAddress(self.handle, symbol_z.ptr) orelse return error.SymbolNotFound;
                return p;
            },
            .linux, .macos => {
                const p = posix.dlsym(self.handle, symbol_z.ptr) orelse return error.SymbolNotFound;
                return @ptrCast(p);
            },
            else => return error.SymbolNotFound,
        }
    }

    /// Close the library. After this call `self.handle` is invalid.
    pub fn close(self: *DynamicLib) void {
        switch (builtin.os.tag) {
            .windows => _ = win.FreeLibrary(self.handle),
            .linux, .macos => _ = posix.dlclose(self.handle),
            else => {},
        }
        self.handle = undefined;
    }
};

test "dynamic_lib.DynamicLib: open + lookup + close on system library" {
    const gpa = std.testing.allocator;
    // Use libSystem on macOS, libc.so.6 on Linux, kernel32.dll on Win32.
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

    var lib = try DynamicLib.open(gpa, lib_path);
    defer lib.close();

    const ptr = try lib.lookup(gpa, sym);
    try std.testing.expect(@intFromPtr(ptr) != 0);
}

test "dynamic_lib.DynamicLib: open returns LibraryNotFound for missing lib" {
    const gpa = std.testing.allocator;
    const result = DynamicLib.open(gpa, "definitely_not_a_real_library_name_xyz123.so.999");
    try std.testing.expectError(error.LibraryNotFound, result);
}
