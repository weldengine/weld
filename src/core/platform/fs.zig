//! Filesystem helpers — VFS scheme resolver + `mmapFile`.
//!
//! Phase 0.3 / M0.3 deliverable. Documented in `engine-platform.md` §4
//! (FileSystem section) and the M0.3 brief.
//!
//! `std.Io.File` / `std.fs.Dir` are propagated as-is for low-level ops.
//! Weld adds two pieces:
//!
//!   - `Vfs` — decodes scheme-prefixed paths into absolute paths the OS
//!     loader / `std.fs` can consume. Schemes:
//!       * `assets://`  → `<project_root>/assets/`
//!       * `cache://`   → `<project_root>/.weld_cache/`
//!       * `user://`    → OS-standard user data dir for the project:
//!         - Win32 : `%APPDATA%/Weld/<project>/`
//!         - Linux : `$XDG_DATA_HOME/weld/<project>/` or fallback
//!                   `$HOME/.local/share/weld/<project>/`
//!         - macOS : `$HOME/Library/Application Support/Weld/<project>/`
//!
//!   - `mmapFile` — memory-maps a file read-only. Required by the cooked
//!     asset zero-copy loader; `std.Io` does not expose mmap directly.
//!     Backends: Win32 `CreateFileMapping` + `MapViewOfFile`, POSIX `mmap`.

const std = @import("std");
const builtin = @import("builtin");

/// Errors surfaced by `Vfs.resolve` / `mmapFile`.
pub const Error = error{
    UnknownScheme,
    EmptyPath,
    MissingEnv,
    MapFailed,
    OpenFailed,
} || std.mem.Allocator.Error;

/// Project-scoped VFS resolver. Construct once at startup with the
/// project root + project name; reuse `resolve()` for every lookup.
pub const Vfs = struct {
    gpa: std.mem.Allocator,
    /// Absolute path to the project root (where `weld.toml` lives).
    /// Owned by the Vfs — freed in `deinit`.
    project_root: []u8,
    /// Project name — used to scope the `user://` directory per project.
    /// Owned by the Vfs — freed in `deinit`.
    project_name: []u8,

    pub fn init(gpa: std.mem.Allocator, project_root: []const u8, project_name: []const u8) !Vfs {
        const root_dup = try gpa.dupe(u8, project_root);
        errdefer gpa.free(root_dup);
        const name_dup = try gpa.dupe(u8, project_name);
        return .{
            .gpa = gpa,
            .project_root = root_dup,
            .project_name = name_dup,
        };
    }

    pub fn deinit(self: *Vfs) void {
        self.gpa.free(self.project_root);
        self.gpa.free(self.project_name);
        self.* = undefined;
    }

    /// Resolve a VFS path (`scheme://rest`) to an absolute filesystem path.
    /// The returned slice is owned by the caller — free with `gpa.free`.
    ///
    /// Plain paths without a scheme are returned as-is (duped).
    pub fn resolve(self: *const Vfs, gpa: std.mem.Allocator, vfs_path: []const u8) Error![]u8 {
        if (vfs_path.len == 0) return error.EmptyPath;

        if (parseScheme(vfs_path)) |scheme| {
            const rest = vfs_path[scheme.len + 3 ..]; // skip "scheme://"
            if (std.mem.eql(u8, scheme, "assets")) {
                return joinAlloc(gpa, &.{ self.project_root, "assets", rest });
            }
            if (std.mem.eql(u8, scheme, "cache")) {
                return joinAlloc(gpa, &.{ self.project_root, ".weld_cache", rest });
            }
            if (std.mem.eql(u8, scheme, "user")) {
                const user_root = try resolveUserRoot(gpa, self.project_name);
                defer gpa.free(user_root);
                return joinAlloc(gpa, &.{ user_root, rest });
            }
            return error.UnknownScheme;
        }

        // No scheme — pass through.
        return gpa.dupe(u8, vfs_path);
    }
};

/// Detect the scheme prefix (`scheme://`). Returns the scheme name (no
/// `://`) or null if no scheme is present.
fn parseScheme(vfs_path: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, vfs_path, "://") orelse return null;
    return vfs_path[0..sep];
}

/// Read an env var via `getenv` (POSIX) or `GetEnvironmentVariableW`
/// (Win32). Returns null if absent. The returned slice is owned by the
/// caller and freed via `gpa.free`.
fn readEnv(gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const wide_name = std.unicode.utf8ToUtf16LeAllocZ(gpa, name) catch return null;
            defer gpa.free(wide_name);

            // Probe the required buffer size, then allocate + read.
            const needed = win_env.GetEnvironmentVariableW(wide_name.ptr, null, 0);
            if (needed == 0) return null;
            const wide_buf = try gpa.alloc(u16, needed);
            defer gpa.free(wide_buf);
            const got = win_env.GetEnvironmentVariableW(wide_name.ptr, wide_buf.ptr, @intCast(wide_buf.len));
            if (got == 0 or got >= wide_buf.len) return null;
            return try std.unicode.utf16LeToUtf8Alloc(gpa, wide_buf[0..got]);
        },
        .linux, .macos => {
            const name_z = try gpa.dupeZ(u8, name);
            defer gpa.free(name_z);
            const cstr = posix_env.getenv(name_z.ptr) orelse return null;
            return try gpa.dupe(u8, std.mem.span(cstr));
        },
        else => return null,
    }
}

const win_env = struct {
    extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;
};

const posix_env = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

/// Resolve the OS-standard user data root for the project. Allocates;
/// caller frees.
fn resolveUserRoot(gpa: std.mem.Allocator, project_name: []const u8) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const appdata = (try readEnv(gpa, "APPDATA")) orelse return error.MissingEnv;
            defer gpa.free(appdata);
            return joinAlloc(gpa, &.{ appdata, "Weld", project_name });
        },
        .linux => {
            if (try readEnv(gpa, "XDG_DATA_HOME")) |xdg| {
                defer gpa.free(xdg);
                return joinAlloc(gpa, &.{ xdg, "weld", project_name });
            }
            const home = (try readEnv(gpa, "HOME")) orelse return error.MissingEnv;
            defer gpa.free(home);
            return joinAlloc(gpa, &.{ home, ".local", "share", "weld", project_name });
        },
        .macos => {
            const home = (try readEnv(gpa, "HOME")) orelse return error.MissingEnv;
            defer gpa.free(home);
            return joinAlloc(gpa, &.{ home, "Library", "Application Support", "Weld", project_name });
        },
        else => return error.MissingEnv,
    }
}

/// `std.fs.path.join` returns the path; we wrap it so callers can pass a
/// list of components in one shot. The result is owned by the caller.
fn joinAlloc(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(gpa, parts);
}

// ---------------------------------------------------------------- mmap --

/// A memory-mapped file region. `bytes` is valid until `close()` is called.
pub const Mmap = struct {
    bytes: []const u8,
    impl: switch (builtin.os.tag) {
        .windows => struct {
            file: *anyopaque, // HANDLE
            mapping: *anyopaque, // HANDLE
        },
        .linux, .macos => struct {
            fd: i32,
        },
        else => struct {},
    },

    /// Unmap and close. After this call `bytes` is invalid.
    pub fn close(self: *Mmap) void {
        switch (builtin.os.tag) {
            .windows => {
                _ = win_mmap.UnmapViewOfFile(self.bytes.ptr);
                _ = win_mmap.CloseHandle(self.impl.mapping);
                _ = win_mmap.CloseHandle(self.impl.file);
            },
            .linux, .macos => {
                _ = posix_mmap.munmap(@constCast(self.bytes.ptr), self.bytes.len);
                _ = posix_mmap.close(self.impl.fd);
            },
            else => {},
        }
        self.* = undefined;
    }
};

const win_mmap = struct {
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateFileMappingW(
        hFile: *anyopaque,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: *anyopaque,
        dwDesiredAccess: u32,
        dwFileOffsetHigh: u32,
        dwFileOffsetLow: u32,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetFileSizeEx(hFile: *anyopaque, lpFileSize: *i64) callconv(.winapi) i32;
    const GENERIC_READ: u32 = 0x80000000;
    const FILE_SHARE_READ: u32 = 0x00000001;
    const OPEN_EXISTING: u32 = 3;
    const PAGE_READONLY: u32 = 0x02;
    const FILE_MAP_READ: u32 = 0x0004;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const INVALID_HANDLE_VALUE: usize = std.math.maxInt(usize);
};

const posix_mmap = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    // lseek used as a portable file-size probe — avoids the per-OS
    // struct stat layout (Linux glibc vs musl vs macOS BSD differ).
    extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
    const O_RDONLY: c_int = 0;
    const PROT_READ: c_int = 1;
    const MAP_PRIVATE: c_int = 2;
    const MAP_FAILED: usize = std.math.maxInt(usize);
    const SEEK_SET: c_int = 0;
    const SEEK_END: c_int = 2;
};

/// Memory-map a file read-only. The returned `Mmap.bytes` is a slice over
/// the kernel mapping — zero-copy. Call `close()` to release.
///
/// Returns `error.OpenFailed` if the path cannot be opened (does not exist
/// or permission denied). Returns `error.MapFailed` if mmap itself fails
/// (rare — usually only on huge files where address space exhausts).
pub fn mmapFile(gpa: std.mem.Allocator, path: []const u8) Error!Mmap {
    switch (builtin.os.tag) {
        .windows => {
            const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch return error.OutOfMemory;
            defer gpa.free(wide);
            const file = win_mmap.CreateFileW(
                wide.ptr,
                win_mmap.GENERIC_READ,
                win_mmap.FILE_SHARE_READ,
                null,
                win_mmap.OPEN_EXISTING,
                win_mmap.FILE_ATTRIBUTE_NORMAL,
                null,
            ) orelse return error.OpenFailed;
            errdefer _ = win_mmap.CloseHandle(file);

            var size: i64 = 0;
            if (win_mmap.GetFileSizeEx(file, &size) == 0) return error.OpenFailed;

            // Map the whole file. `dwMaximumSizeHigh/Low` = 0 means "use
            // the file's actual size", saving us a 32/64-bit split.
            const mapping = win_mmap.CreateFileMappingW(
                file,
                null,
                win_mmap.PAGE_READONLY,
                0,
                0,
                null,
            ) orelse return error.MapFailed;
            errdefer _ = win_mmap.CloseHandle(mapping);

            const base = win_mmap.MapViewOfFile(
                mapping,
                win_mmap.FILE_MAP_READ,
                0,
                0,
                0,
            ) orelse return error.MapFailed;
            errdefer _ = win_mmap.UnmapViewOfFile(base);

            const bytes_ptr: [*]const u8 = @ptrCast(base);
            return .{
                .bytes = bytes_ptr[0..@intCast(size)],
                .impl = .{ .file = file, .mapping = mapping },
            };
        },
        .linux, .macos => {
            const path_z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
            defer gpa.free(path_z);

            const fd = posix_mmap.open(path_z.ptr, posix_mmap.O_RDONLY, 0);
            if (fd < 0) return error.OpenFailed;
            errdefer _ = posix_mmap.close(fd);

            // Probe file size via lseek-to-end (portable — avoids the
            // per-libc struct stat layout). Rewind afterwards so the
            // mmap offset is consistent.
            const size_i = posix_mmap.lseek(fd, 0, posix_mmap.SEEK_END);
            if (size_i < 0) return error.OpenFailed;
            _ = posix_mmap.lseek(fd, 0, posix_mmap.SEEK_SET);
            const size: usize = @intCast(size_i);
            if (size == 0) {
                // Empty file — mmap returns EINVAL. Return a zero-length
                // valid mapping.
                _ = posix_mmap.close(fd);
                return .{
                    .bytes = &.{},
                    .impl = .{ .fd = -1 },
                };
            }

            const base = posix_mmap.mmap(
                null,
                size,
                posix_mmap.PROT_READ,
                posix_mmap.MAP_PRIVATE,
                fd,
                0,
            ) orelse return error.MapFailed;
            if (@intFromPtr(base) == posix_mmap.MAP_FAILED) return error.MapFailed;

            const bytes_ptr: [*]const u8 = @ptrCast(base);
            return .{
                .bytes = bytes_ptr[0..size],
                .impl = .{ .fd = fd },
            };
        },
        else => return error.OpenFailed,
    }
}

// ----------------------------------------------------------- inline tests --

test "fs.parseScheme: detects scheme prefix" {
    try std.testing.expectEqualStrings("assets", parseScheme("assets://foo/bar").?);
    try std.testing.expectEqualStrings("cache", parseScheme("cache://x.bin").?);
    try std.testing.expectEqualStrings("user", parseScheme("user://saves/save0.json").?);
    try std.testing.expect(parseScheme("plain/path/no/scheme") == null);
    try std.testing.expect(parseScheme("relative.txt") == null);
}

test "fs.Vfs.resolve: assets:// joins project_root + 'assets' + rest" {
    const gpa = std.testing.allocator;
    var vfs = try Vfs.init(gpa, "/proj/root", "my-game");
    defer vfs.deinit();

    const resolved = try vfs.resolve(gpa, "assets://characters/hero.gltf");
    defer gpa.free(resolved);

    try std.testing.expect(std.mem.endsWith(u8, resolved, "characters/hero.gltf") or
        std.mem.endsWith(u8, resolved, "characters\\hero.gltf")); // win path sep tolerance
    try std.testing.expect(std.mem.indexOf(u8, resolved, "/proj/root") != null or
        std.mem.indexOf(u8, resolved, "\\proj\\root") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "assets") != null);
}

test "fs.Vfs.resolve: cache:// joins project_root + '.weld_cache' + rest" {
    const gpa = std.testing.allocator;
    var vfs = try Vfs.init(gpa, "/proj/root", "my-game");
    defer vfs.deinit();

    const resolved = try vfs.resolve(gpa, "cache://shaders/blit.spv");
    defer gpa.free(resolved);

    try std.testing.expect(std.mem.indexOf(u8, resolved, ".weld_cache") != null);
}

test "fs.Vfs.resolve: unknown scheme returns error" {
    const gpa = std.testing.allocator;
    var vfs = try Vfs.init(gpa, "/proj/root", "my-game");
    defer vfs.deinit();

    try std.testing.expectError(error.UnknownScheme, vfs.resolve(gpa, "ftp://nowhere"));
}

test "fs.Vfs.resolve: plain path passes through" {
    const gpa = std.testing.allocator;
    var vfs = try Vfs.init(gpa, "/proj/root", "my-game");
    defer vfs.deinit();

    const resolved = try vfs.resolve(gpa, "just/a/path.txt");
    defer gpa.free(resolved);

    try std.testing.expectEqualStrings("just/a/path.txt", resolved);
}
