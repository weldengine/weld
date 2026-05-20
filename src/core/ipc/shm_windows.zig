//! Windows backend for shared memory.
//!
//! `CreateFileMappingA(INVALID_HANDLE_VALUE, ...)` creates an
//! anonymous file mapping in the page file. `MapViewOfFile` projects
//! it into the process address space. The mapping handle is kept on
//! the `Backend` so `CloseHandle` can release it at `close()` time.
//!
//! Names start with `Local\` (session-local). The editor's PID is
//! appended by the caller to disambiguate concurrent Weld sessions.

const std = @import("std");
const builtin = @import("builtin");

const shm = @import("shm.zig");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("shm_windows.zig: Windows-only.");
    }
}

const Handle = *anyopaque;
const Bool = i32;
const Dword = u32;

const INVALID_HANDLE_VALUE: Handle = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const PAGE_READWRITE: Dword = 0x04;
const FILE_MAP_ALL_ACCESS: Dword = 0xF001F;

const sys = struct {
    extern "kernel32" fn CreateFileMappingA(
        hFile: Handle,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: Dword,
        dwMaximumSizeHigh: Dword,
        dwMaximumSizeLow: Dword,
        lpName: [*:0]const u8,
    ) callconv(.winapi) Handle;

    extern "kernel32" fn OpenFileMappingA(
        dwDesiredAccess: Dword,
        bInheritHandle: Bool,
        lpName: [*:0]const u8,
    ) callconv(.winapi) Handle;

    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: Handle,
        dwDesiredAccess: Dword,
        dwFileOffsetHigh: Dword,
        dwFileOffsetLow: Dword,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?*anyopaque;

    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *anyopaque) callconv(.winapi) Bool;
    extern "kernel32" fn CloseHandle(hObject: Handle) callconv(.winapi) Bool;
};

const Error = shm.Error;

/// Win32 `CreateFileMapping` + `MapViewOfFile` backend for the IPC
/// viewport shared memory segment. Embedded inside `shm.Segment.impl`
/// on Windows.
pub const Backend = struct {
    mapping: Handle,
    ptr: [*]align(std.heap.pageSize()) u8,
    size: usize,

    pub fn create(name: []const u8, size: usize) Error!Backend {
        var name_buf: [256]u8 = undefined;
        if (name.len + 1 > name_buf.len) return error.NameTooLong;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const name_z: [*:0]const u8 = @ptrCast(&name_buf[0]);

        const size_low: Dword = @truncate(size & 0xFFFFFFFF);
        const size_high: Dword = @truncate(size >> 32);

        const mapping = sys.CreateFileMappingA(
            INVALID_HANDLE_VALUE,
            null,
            PAGE_READWRITE,
            size_high,
            size_low,
            name_z,
        );
        if (@intFromPtr(mapping) == 0) return error.ShmCreateFailed;
        errdefer _ = sys.CloseHandle(mapping);

        const view = sys.MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size);
        if (view == null) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(view.?));
        return Backend{ .mapping = mapping, .ptr = ptr, .size = size };
    }

    pub fn open(name: []const u8, size: usize) Error!Backend {
        var name_buf: [256]u8 = undefined;
        if (name.len + 1 > name_buf.len) return error.NameTooLong;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const name_z: [*:0]const u8 = @ptrCast(&name_buf[0]);

        const mapping = sys.OpenFileMappingA(FILE_MAP_ALL_ACCESS, 0, name_z);
        if (@intFromPtr(mapping) == 0) return error.ShmOpenFailed;
        errdefer _ = sys.CloseHandle(mapping);

        const view = sys.MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size);
        if (view == null) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(view.?));
        return Backend{ .mapping = mapping, .ptr = ptr, .size = size };
    }

    pub fn close(self: *Backend, is_owner: bool) void {
        _ = is_owner; // Windows refcounts the mapping kernel object —
        // no `unlink` step distinct from the unmap+close pair.
        _ = sys.UnmapViewOfFile(@ptrCast(self.ptr));
        _ = sys.CloseHandle(self.mapping);
        self.mapping = INVALID_HANDLE_VALUE;
        self.size = 0;
    }
};
