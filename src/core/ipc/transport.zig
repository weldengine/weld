//! Transport interface for the Weld editor↔runtime IPC.
//!
//! Two channels share this surface: a Unix domain socket on Linux /
//! macOS (`transport_posix.zig`) and a named pipe in byte mode on
//! Windows (`transport_windows.zig`). The public API is identical
//! across backends — the comptime dispatch below picks the OS-specific
//! `Backend` at compile time. Refer to `engine-ipc.md` §2 for the
//! transport rationale and §4.7 for the Phase 3 GPU handle passing
//! that motivates the `sendWithHandles` surface (Windows backend
//! returns `error.Unimplemented` in S6 per the brief).
//!
//! Semantics:
//!   - `listen(path)` — editor side; binds and starts accepting.
//!   - `connect(path)` — runtime side; opens the channel.
//!   - `accept()` — editor side; blocks until the runtime connects.
//!   - `send(bytes)` / `recv(buffer)` — blocking I/O, byte-stream
//!     semantics on both backends (no framing — the framing layer
//!     above (`framing.zig`) is what gives messages their shape).
//!   - `sendWithHandles(bytes, handles)` /
//!     `recvWithHandles(buffer, handles)` — out-of-band handle
//!     transport per `engine-ipc.md` §2.3 + §4.7. POSIX uses
//!     `SCM_RIGHTS` cmsg ancillary data; Windows returns
//!     `error.Unimplemented` and the implementation lands in Phase 3
//!     when GPU shared framebuffers arrive.
//!   - `close()` — releases the socket / pipe.
//!
//! EOF detection: `recv` (and `recvWithHandles`) return 0 bytes when
//! the peer closes its end cleanly. Callers map that to crash /
//! shutdown detection per `engine-ipc.md` §6.2.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux, .macos => @import("transport_posix.zig"),
    .windows => @import("transport_windows.zig"),
    else => @compileError("Weld IPC transport: unsupported OS"),
};

/// OS-native handle type. `std.posix.fd_t` (i32) on Linux/macOS,
/// `std.os.windows.HANDLE` on Windows. Used by `sendWithHandles` /
/// `recvWithHandles` to transport file descriptors and NT handles
/// out-of-band (cf. `engine-ipc.md` §2.3).
pub const OsHandle = backend.OsHandle;

/// Sentinel marking an absent handle in a slot.
pub const invalid_handle: OsHandle = backend.invalid_handle;

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
    SocketCreationFailed,
    SystemResources,
    /// Windows: `sendWithHandles` / `recvWithHandles` are scoped to
    /// Phase 3 per `engine-ipc.md §4.7` + S6 brief. The named-pipe
    /// implementation lives in `transport_windows.zig` and returns
    /// this error so callers can opt-out gracefully.
    Unimplemented,
    UnexpectedEof,
} || std.posix.UnexpectedError || std.mem.Allocator.Error;

/// IPC socket — see file header for the lifecycle.
pub const IpcSocket = struct {
    impl: backend.Backend,

    /// Editor side. Binds to `path` and marks the socket as
    /// accepting. `path` is the Unix domain socket path on POSIX
    /// (e.g. `/tmp/weld-<pid>.sock`) or the named-pipe name on
    /// Windows (e.g. `\\.\pipe\weld-<pid>`).
    pub fn listen(path: []const u8) Error!IpcSocket {
        return .{ .impl = try backend.Backend.listen(path) };
    }

    /// Runtime side. Opens the channel created by `listen`.
    pub fn connect(path: []const u8) Error!IpcSocket {
        return .{ .impl = try backend.Backend.connect(path) };
    }

    /// Editor side. Blocks until the runtime connects, then returns
    /// a fresh `IpcSocket` for the accepted client. The listening
    /// socket itself is left in `self` for subsequent reconnects.
    pub fn accept(self: *IpcSocket) Error!IpcSocket {
        return .{ .impl = try self.impl.accept() };
    }

    /// Writes the entire slice. Loops over short writes
    /// transparently (POSIX `write` may return less than requested).
    pub fn send(self: *IpcSocket, bytes: []const u8) Error!void {
        return self.impl.send(bytes);
    }

    /// Reads up to `buffer.len` bytes. Returns the number actually
    /// read; a return of 0 means peer EOF (clean close) and the
    /// connection must be reset by the caller.
    pub fn recv(self: *IpcSocket, buffer: []u8) Error!usize {
        return self.impl.recv(buffer);
    }

    /// Out-of-band handle transport. `bytes` must be non-empty
    /// (POSIX requires at least one regular byte alongside any
    /// ancillary cmsg). On Windows: returns `error.Unimplemented`
    /// in S6 (cf. file header).
    pub fn sendWithHandles(
        self: *IpcSocket,
        bytes: []const u8,
        handles: []const OsHandle,
    ) Error!void {
        return self.impl.sendWithHandles(bytes, handles);
    }

    /// Out-of-band handle receive. `handles_out` receives up to its
    /// `len` slots; the actual count is returned in `RecvResult`.
    /// Windows S6: `error.Unimplemented`.
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

// Sanity at compile time — the comptime dispatch above must produce
// a backend with the expected surface. A signature drift surfaces as
// a compile error here rather than at the first call site.
comptime {
    _ = backend.Backend;
    _ = backend.OsHandle;
}
