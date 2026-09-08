//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! BYTE-STREAM on both backends: `recv` carries no message boundary, and the shape
//! comes from `framing.zig` above. A Unix socket on POSIX, a named pipe on Windows.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux, .macos => @import("transport_posix.zig"),
    .windows => @import("transport_windows.zig"),
    else => @compileError("Weld IPC transport: unsupported OS"),
};

/// OS-native handle type, transported out-of-band by `sendWithHandles`.
pub const OsHandle = backend.OsHandle;

/// Sentinel marking an absent handle in a slot.
pub const invalid_handle: OsHandle = backend.invalid_handle;

/// Close one OS handle. An fd received through `recvWithHandles` and NOT retained
/// must come here, or a malformed handoff leaks descriptors.
pub fn closeHandle(h: OsHandle) void {
    backend.closeHandle(h);
}

/// Result returned by `recvWithHandles`.
pub const RecvResult = struct {
    bytes: usize,
    handles: usize,
};

/// Errors raised by the transport layer.
pub const Error = error{
    AddressInUse,
    AlreadyConnected,
    BindFailed,
    BrokenPipe,
    ConnectionRefused,
    ConnectionResetByPeer,
    FileNotFound,
    HandleTransferUnsupported,
    InvalidPath,
    ListenFailed,
    NameTooLong,
    PermissionDenied,
    /// The post-`bind` `chmod(path, 0600)` failed, so `listen` refuses to start.
    SocketPermissionFailed,
    /// An accepted peer runs under another UID — THE local-IPC boundary.
    PeerCredentialMismatch,
    SocketCreationFailed,
    SystemResources,
    /// Windows: `sendWithHandles` / `recvWithHandles` have no implementation.
    Unimplemented,
    UnexpectedEof,
} || std.posix.UnexpectedError || std.mem.Allocator.Error;

/// IPC socket — see file header for the lifecycle.
pub const IpcSocket = struct {
    impl: backend.Backend,

    /// Editor side. `path` is a Unix socket path on POSIX, a pipe name on Windows.
    pub fn listen(path: []const u8) Error!IpcSocket {
        return .{ .impl = try backend.Backend.listen(path) };
    }

    /// Runtime side. Opens the channel created by `listen`.
    pub fn connect(path: []const u8) Error!IpcSocket {
        return .{ .impl = try backend.Backend.connect(path) };
    }

    /// Editor side. The LISTENING socket stays in `self` — do not close it.
    pub fn accept(self: *IpcSocket) Error!IpcSocket {
        return .{ .impl = try self.impl.accept() };
    }

    /// Writes the ENTIRE slice, looping over short writes.
    pub fn send(self: *IpcSocket, bytes: []const u8) Error!void {
        return self.impl.send(bytes);
    }

    /// Reads up to `buffer.len`; a return of 0 is the peer's clean EOF.
    pub fn recv(self: *IpcSocket, buffer: []u8) Error!usize {
        return self.impl.recv(buffer);
    }

    /// `bytes` must be NON-EMPTY: POSIX needs one regular byte alongside a cmsg.
    pub fn sendWithHandles(
        self: *IpcSocket,
        bytes: []const u8,
        handles: []const OsHandle,
    ) Error!void {
        return self.impl.sendWithHandles(bytes, handles);
    }

    pub fn recvWithHandles(
        self: *IpcSocket,
        buffer: []u8,
        handles_out: []OsHandle,
    ) Error!RecvResult {
        return self.impl.recvWithHandles(buffer, handles_out);
    }

    pub fn close(self: *IpcSocket) void {
        self.impl.close();
    }
};

/// `/tmp/<name>.sock` on POSIX, `\\.\pipe\<name>` on Windows, written into `buf`.
pub fn buildSocketPath(buf: []u8, name: []const u8) ![:0]const u8 {
    const prefix = switch (builtin.os.tag) {
        .linux, .macos => "/tmp/",
        .windows => "\\\\.\\pipe\\",
        else => return error.UnsupportedHostPlatform,
    };
    const suffix = switch (builtin.os.tag) {
        .linux, .macos => ".sock",
        .windows => "",
        else => "",
    };
    const total = prefix.len + name.len + suffix.len;
    if (total + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + name.len], name);
    @memcpy(buf[prefix.len + name.len .. total], suffix);
    buf[total] = 0;
    return buf[0..total :0];
}

// A backend signature drift surfaces here instead of at the first call site.
comptime {
    _ = backend.Backend;
    _ = backend.OsHandle;
}
