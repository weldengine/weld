//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Editor side. Accepts exactly ONE runtime client. The handshake is public so the
//! editor loop can short-circuit a version mismatch instead of running blind.

const std = @import("std");

const conn_mod = @import("connection.zig");
const framing = @import("framing.zig");
const messages = @import("messages.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// Re-exports `connection.Error` — closed set of IPC connection errors.
pub const Error = conn_mod.Error;

/// Owns the listener, the accepted client socket, and the connection over it.
pub const IpcServer = struct {
    gpa: std.mem.Allocator,
    listener: ?transport.IpcSocket = null,
    /// `null` until `acceptOne` returns. OWNED — closed in `deinit`.
    client: ?transport.IpcSocket = null,
    conn: ?conn_mod.IpcConnection = null,

    pub fn init(gpa: std.mem.Allocator) IpcServer {
        return .{ .gpa = gpa };
    }

    /// Binds; the transport already unlinks a stale POSIX socket file at `path`.
    pub fn listen(self: *IpcServer, path: []const u8) Error!void {
        if (self.listener != null) return error.AlreadyConnected;
        self.listener = try transport.IpcSocket.listen(path);
    }

    /// Blocks until the runtime connects; the listener pointer is the readiness proxy.
    pub fn acceptOne(self: *IpcServer) Error!void {
        if (self.listener == null) return error.ConnectionRefused;
        if (self.client != null) return error.AlreadyConnected;
        self.client = try self.listener.?.accept();
        self.conn = conn_mod.IpcConnection.init(self.gpa, &self.client.?);
    }

    /// Asserts the post-accept state — never call it before `acceptOne`.
    pub fn connection(self: *IpcServer) *conn_mod.IpcConnection {
        return &self.conn.?;
    }

    /// `scratch` must hold `framing.frameSizeOf(ProtocolHello)` bytes.
    pub fn recvHello(
        self: *IpcServer,
        scratch: []u8,
    ) Error!messages.ProtocolHello {
        return self.connection().recvMessage(messages.ProtocolHello, scratch);
    }

    /// `accepted == false` is fatal for the runtime; `reason` is copied, then truncated.
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

    /// On mismatch the editor owes a `sendHelloAck(false, …)` before tearing down.
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
