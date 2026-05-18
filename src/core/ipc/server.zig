//! `IpcServer` — editor-side wrapper around the IPC stack.
//!
//! Owns the listening socket, accepts exactly one runtime client,
//! and then exposes an `IpcConnection` for the lifetime of the
//! editor↔runtime session. The handshake (`ProtocolHello` →
//! `ProtocolHelloAck`) is in the public API surface so the editor
//! main loop can short-circuit on version mismatches.
//!
//! S6 lifecycle:
//!   1. `IpcServer.init(gpa)`
//!   2. `server.listen(socket_path)` — binds and starts accepting.
//!   3. (editor spawns runtime via `platform.process.spawn_process`,
//!      passing the socket path + shm name + editor PID)
//!   4. `server.acceptOne()` — blocks until the runtime connects.
//!   5. `server.recvHello(...)` — reads `ProtocolHello` from the
//!      runtime, validates the protocol version.
//!   6. `server.sendHelloAck(accepted, reason)`.
//!   7. From here the editor uses `server.connection()` to send /
//!      receive any of the 13 message types.
//!   8. `server.deinit()` — closes the accepted client + listener
//!      + unlinks the socket path on POSIX.

const std = @import("std");

const conn_mod = @import("connection.zig");
const framing = @import("framing.zig");
const messages = @import("messages.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

pub const Error = conn_mod.Error;

pub const IpcServer = struct {
    gpa: std.mem.Allocator,
    listener: ?transport.IpcSocket = null,
    /// The accepted client socket. `null` until `acceptOne` returns.
    /// Owned — closed in `deinit`.
    client: ?transport.IpcSocket = null,
    conn: ?conn_mod.IpcConnection = null,

    pub fn init(gpa: std.mem.Allocator) IpcServer {
        return .{ .gpa = gpa };
    }

    /// Editor-side bind. Re-uses the transport layer's
    /// `IpcSocket.listen` which already unlinks stale POSIX socket
    /// files at `path` (see `transport_posix.zig`).
    pub fn listen(self: *IpcServer, path: []const u8) Error!void {
        if (self.listener != null) return error.AlreadyConnected;
        self.listener = try transport.IpcSocket.listen(path);
    }

    /// Block until the runtime connects, then store the client
    /// socket and the wrapping `IpcConnection`. Returns
    /// `error.ConnectionRefused` if `listen()` wasn't called yet
    /// (the listener pointer is the proxy for "ready to accept").
    pub fn acceptOne(self: *IpcServer) Error!void {
        if (self.listener == null) return error.ConnectionRefused;
        if (self.client != null) return error.AlreadyConnected;
        self.client = try self.listener.?.accept();
        self.conn = conn_mod.IpcConnection.init(self.gpa, &self.client.?);
    }

    /// Pointer to the live connection. Asserts the handshake has
    /// reached the post-accept state.
    pub fn connection(self: *IpcServer) *conn_mod.IpcConnection {
        return &self.conn.?;
    }

    /// Receive the runtime's `ProtocolHello`. Caller-supplied
    /// `scratch` must be at least `framing.frameSizeOf(ProtocolHello)`
    /// bytes.
    pub fn recvHello(
        self: *IpcServer,
        scratch: []u8,
    ) Error!messages.ProtocolHello {
        return self.connection().recvMessage(messages.ProtocolHello, scratch);
    }

    /// Send a `ProtocolHelloAck` to the runtime. `accepted == false`
    /// signals a fatal mismatch (the runtime is expected to log and
    /// exit). `reason` is copied into the fixed-width field.
    pub fn sendHelloAck(
        self: *IpcServer,
        accepted: bool,
        reason: []const u8,
    ) Error!void {
        var ack = messages.ProtocolHelloAck{
            .accepted = if (accepted) @as(u8, 1) else @as(u8, 0),
            .reason = std.mem.zeroes([128]u8),
        };
        messages.writeFixedString(&ack.reason, reason);
        try self.connection().sendMessage(messages.ProtocolHelloAck, 0, &ack);
    }

    /// Validates a received `ProtocolHello` against the
    /// editor-side `WELD_IPC_PROTOCOL_VERSION` constant. Returns
    /// `error.ProtocolVersionMismatch` on disagreement; the editor
    /// should then call `sendHelloAck(false, "...")` and tear the
    /// connection down.
    pub fn validateHello(hello: messages.ProtocolHello) Error!void {
        if (hello.protocol_version != protocol.WELD_IPC_PROTOCOL_VERSION) {
            return error.ProtocolVersionMismatch;
        }
    }

    pub fn deinit(self: *IpcServer) void {
        if (self.client) |*c| c.close();
        self.client = null;
        if (self.listener) |*l| l.close();
        self.listener = null;
        self.conn = null;
    }
};
