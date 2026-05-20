//! Windows backend for the Weld IPC transport. Uses a named pipe in
//! byte mode via `CreateNamedPipeA` / `ConnectNamedPipe` /
//! `CreateFileA` / `ReadFile` / `WriteFile` / `CloseHandle`. Out-of-
//! band handle passing (`sendWithHandles` / `recvWithHandles`)
//! returns `error.Unimplemented` in S6 per `engine-ipc.md` §4.7 +
//! S6 brief — the `DuplicateHandle`-based implementation lands in
//! Phase 3 when GPU shared framebuffers arrive.

const std = @import("std");
const builtin = @import("builtin");

const transport = @import("transport.zig");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("transport_windows.zig: Windows-only.");
    }
}

const Handle = *anyopaque;
const Bool = i32;
const Dword = u32;

const INVALID_HANDLE_VALUE: Handle = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const PIPE_ACCESS_DUPLEX: Dword = 0x00000003;
const PIPE_TYPE_BYTE: Dword = 0x00000000;
const PIPE_READMODE_BYTE: Dword = 0x00000000;
const PIPE_WAIT: Dword = 0x00000000;
const GENERIC_READ: Dword = 0x80000000;
const GENERIC_WRITE: Dword = 0x40000000;
const OPEN_EXISTING: Dword = 3;
const FILE_ATTRIBUTE_NORMAL: Dword = 0x80;
const PIPE_UNLIMITED_INSTANCES: Dword = 255;
const ERROR_PIPE_CONNECTED: Dword = 535;
const ERROR_BROKEN_PIPE: Dword = 109;

const sys = struct {
    extern "kernel32" fn CreateNamedPipeA(
        lpName: [*:0]const u8,
        dwOpenMode: Dword,
        dwPipeMode: Dword,
        nMaxInstances: Dword,
        nOutBufferSize: Dword,
        nInBufferSize: Dword,
        nDefaultTimeOut: Dword,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) Handle;

    extern "kernel32" fn ConnectNamedPipe(hNamedPipe: Handle, lpOverlapped: ?*anyopaque) callconv(.winapi) Bool;

    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: Dword,
        dwShareMode: Dword,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: Dword,
        dwFlagsAndAttributes: Dword,
        hTemplateFile: ?Handle,
    ) callconv(.winapi) Handle;

    extern "kernel32" fn ReadFile(
        hFile: Handle,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: Dword,
        lpNumberOfBytesRead: *Dword,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) Bool;

    extern "kernel32" fn WriteFile(
        hFile: Handle,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: Dword,
        lpNumberOfBytesWritten: *Dword,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) Bool;

    extern "kernel32" fn CloseHandle(hObject: Handle) callconv(.winapi) Bool;
    extern "kernel32" fn GetLastError() callconv(.winapi) Dword;
    extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: Handle) callconv(.winapi) Bool;
};

/// Picked up by `transport.zig`'s comptime backend dispatch — must
/// keep matching shape with `transport_posix.OsHandle` so call sites
/// can treat the alias as opaque.
pub const OsHandle = std.os.windows.HANDLE;
/// Sentinel for a closed / never-opened pipe; paired with the POSIX
/// `-1` equivalent through `transport.zig`'s `invalid_handle`
/// re-export.
pub const invalid_handle: OsHandle = INVALID_HANDLE_VALUE;

const Error = transport.Error;

/// Win32 named-pipe backend for `IpcSocket`. Embedded inside
/// `IpcSocket.impl` on Windows.
pub const Backend = struct {
    handle: Handle,
    /// Listener vs accepted-client distinction — only the listener
    /// instance was created by `CreateNamedPipeA`. An accepted
    /// client owns the listener's pipe instance after the handshake;
    /// the listener's `accept` consumes the original handle and
    /// creates a fresh pipe instance for the next would-be client
    /// (out of scope for S6 — only one connection is ever accepted).
    is_listener: bool = false,

    pub fn listen(path: []const u8) Error!Backend {
        var path_buf: [256]u8 = undefined;
        if (path.len + 1 > path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf[0]);

        const handle = sys.CreateNamedPipeA(
            path_z,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1, // S6: exactly one runtime client per editor
            64 * 1024,
            64 * 1024,
            0,
            null,
        );
        if (@intFromPtr(handle) == @intFromPtr(INVALID_HANDLE_VALUE)) {
            const code = sys.GetLastError();
            // Surface the Win32 last-error so callers (bench harness,
            // tests, the editor) can diagnose `BindFailed` without
            // guessing. 123 = ERROR_INVALID_NAME (path is not
            // `\\.\pipe\…`), 231 = ERROR_PIPE_BUSY, 5 =
            // ERROR_ACCESS_DENIED, 87 = ERROR_INVALID_PARAMETER.
            std.log.scoped(.ipc).err(
                "CreateNamedPipeA failed: path='{s}' GetLastError={d}",
                .{ path, code },
            );
            return error.BindFailed;
        }

        return Backend{ .handle = handle, .is_listener = true };
    }

    pub fn connect(path: []const u8) Error!Backend {
        var path_buf: [256]u8 = undefined;
        if (path.len + 1 > path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf[0]);

        const handle = sys.CreateFileA(
            path_z,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (@intFromPtr(handle) == @intFromPtr(INVALID_HANDLE_VALUE)) {
            const code = sys.GetLastError();
            // 2 = ERROR_FILE_NOT_FOUND (listener absent), 231 =
            // ERROR_PIPE_BUSY (all listener instances connected),
            // 5 = ERROR_ACCESS_DENIED.
            std.log.scoped(.ipc).err(
                "CreateFileA failed: path='{s}' GetLastError={d}",
                .{ path, code },
            );
            return error.ConnectionRefused;
        }

        return Backend{ .handle = handle, .is_listener = false };
    }

    pub fn accept(self: *Backend) Error!Backend {
        const ok = sys.ConnectNamedPipe(self.handle, null);
        // ERROR_PIPE_CONNECTED means the client raced ahead of our
        // listener — already connected, treat as success.
        if (ok == 0 and sys.GetLastError() != ERROR_PIPE_CONNECTED) {
            return error.ConnectionRefused;
        }
        // Transfer ownership of the pipe instance to the accepted
        // backend; the listener becomes inert.
        const accepted = Backend{ .handle = self.handle, .is_listener = false };
        self.handle = INVALID_HANDLE_VALUE;
        return accepted;
    }

    pub fn send(self: *Backend, bytes: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var written: Dword = 0;
            const chunk_len: Dword = @intCast(@min(bytes.len - offset, std.math.maxInt(Dword)));
            const ok = sys.WriteFile(self.handle, bytes.ptr + offset, chunk_len, &written, null);
            if (ok == 0) return error.BrokenPipe;
            if (written == 0) return error.BrokenPipe;
            offset += written;
        }
    }

    pub fn recv(self: *Backend, buffer: []u8) Error!usize {
        var read: Dword = 0;
        const chunk_len: Dword = @intCast(@min(buffer.len, std.math.maxInt(Dword)));
        const ok = sys.ReadFile(self.handle, buffer.ptr, chunk_len, &read, null);
        if (ok == 0) {
            if (sys.GetLastError() == ERROR_BROKEN_PIPE) return 0; // clean EOF
            return error.BrokenPipe;
        }
        return read;
    }

    pub fn sendWithHandles(
        self: *Backend,
        bytes: []const u8,
        handles: []const OsHandle,
    ) Error!void {
        _ = self;
        _ = bytes;
        _ = handles;
        // Phase 3 — see engine-ipc.md §4.7 and the S6 brief § Scope.
        return error.Unimplemented;
    }

    pub fn recvWithHandles(
        self: *Backend,
        buffer: []u8,
        handles_out: []OsHandle,
    ) Error!transport.RecvResult {
        _ = self;
        _ = buffer;
        _ = handles_out;
        // Phase 3 — see engine-ipc.md §4.7 and the S6 brief § Scope.
        return error.Unimplemented;
    }

    pub fn close(self: *Backend) void {
        if (@intFromPtr(self.handle) == @intFromPtr(INVALID_HANDLE_VALUE)) return;
        if (self.is_listener) _ = sys.DisconnectNamedPipe(self.handle);
        _ = sys.CloseHandle(self.handle);
        self.handle = INVALID_HANDLE_VALUE;
    }
};
