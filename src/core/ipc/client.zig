//! `IpcClient` — runtime-side wrapper around the IPC stack.
//!
//! Mirrors `IpcServer` but does not own a listening socket. The
//! runtime connects to the path the editor passed via argv,
//! handshakes by sending `ProtocolHello` and reading
//! `ProtocolHelloAck`, then either drives the IPC loop or exits
//! cleanly when the editor rejects.
//!
//! S6 lifecycle:
//!   1. `IpcClient.init(gpa)`
//!   2. `client.connect(socket_path)`
//!   3. `client.sendHello(engine_version, build_hash, capabilities)`
//!   4. `client.recvHelloAck(scratch)` — fatal on `accepted == 0`.
//!   5. `client.connection()` drives the rest of the S6 traffic.
//!   6. `client.deinit()` — closes the socket.

const std = @import("std");

const conn_mod = @import("connection.zig");
const framing = @import("framing.zig");
const messages = @import("messages.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// Re-exports `connection.Error` — closed set of IPC connection errors.
pub const Error = conn_mod.Error;

/// Editor-side IPC client — holds the connected socket + the
/// versioned connection state machine.
pub const IpcClient = struct {
    gpa: std.mem.Allocator,
    socket: ?transport.IpcSocket = null,
    conn: ?conn_mod.IpcConnection = null,

    pub fn init(gpa: std.mem.Allocator) IpcClient {
        return .{ .gpa = gpa };
    }

    pub fn connect(self: *IpcClient, path: []const u8) Error!void {
        if (self.socket != null) return error.AlreadyConnected;
        self.socket = try transport.IpcSocket.connect(path);
        self.conn = conn_mod.IpcConnection.init(self.gpa, &self.socket.?);
    }

    pub fn connection(self: *IpcClient) *conn_mod.IpcConnection {
        return &self.conn.?;
    }

    /// Send the opening `ProtocolHello`. `engine_version` and
    /// `build_hash` are written into the fixed-width buffers with
    /// silent truncation past 31 / 15 bytes.
    pub fn sendHello(
        self: *IpcClient,
        engine_version: []const u8,
        build_hash: []const u8,
        capabilities: u32,
    ) Error!void {
        var hello = messages.ProtocolHello{
            .protocol_version = protocol.WELD_IPC_PROTOCOL_VERSION,
            .engine_version = std.mem.zeroes([32]u8),
            .build_hash = std.mem.zeroes([16]u8),
            .capabilities = capabilities,
        };
        messages.writeFixedString(&hello.engine_version, engine_version);
        messages.writeFixedString(&hello.build_hash, build_hash);
        try self.connection().sendMessage(messages.ProtocolHello, 0, &hello);
    }

    /// Read the editor's `ProtocolHelloAck`. The runtime's contract
    /// is to log+exit on `accepted == 0`; this helper just deserialises
    /// the wire payload.
    pub fn recvHelloAck(
        self: *IpcClient,
        scratch: []u8,
    ) Error!messages.ProtocolHelloAck {
        return self.connection().recvMessage(messages.ProtocolHelloAck, scratch);
    }

    pub fn deinit(self: *IpcClient) void {
        if (self.socket) |*s| s.close();
        self.socket = null;
        self.conn = null;
    }
};
