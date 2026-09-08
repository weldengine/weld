//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Runtime side. Connects to the path the editor passed on argv, sends
//! `ProtocolHello`, and reads the ack — on `accepted == 0` the runtime must exit.

const std = @import("std");

const conn_mod = @import("connection.zig");
const framing = @import("framing.zig");
const messages = @import("messages.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// Re-exports `connection.Error` — closed set of IPC connection errors.
pub const Error = conn_mod.Error;

/// Holds the connected socket and the connection over it.
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

    /// `engine_version` and `build_hash` truncate silently past 31 and 15 bytes.
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

    /// Deserialises only — acting on `accepted == 0` is the caller's contract.
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
