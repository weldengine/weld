//! `IpcConnection` — symmetric wrapper around an `IpcSocket`, the
//! 16-byte framing header (`framing.Header`), and the comptime
//! schema-hashed message catalogue (`messages.MsgType`).
//!
//! Both the editor's `IpcServer` and the runtime's `IpcClient` hold
//! one of these once their handshake completes. The connection
//! exposes:
//!
//!   - `sendMessage(T, seq_id, *const T)` — encodes a `Header` +
//!     `schema_hash` + `extern struct` and writes the whole frame to
//!     the socket through the transport's `send`.
//!   - `recvFrame(buf)` — reads exactly one frame: 16-byte header +
//!     `payload_len` bytes into the caller's buffer. Validates the
//!     magic / version / msg_type / payload size and returns the
//!     header + a slice into `buf`.
//!   - `sendMessageWithHandles(T, seq_id, *const T, []OsHandle)` —
//!     POSIX-only out-of-band variant used for the viewport fd
//!     transfer + future Phase 3 GPU shared framebuffer handles.
//!
//! The connection does not own the socket: the caller passes a
//! `*IpcSocket` and remains responsible for closing it. This makes
//! the two-process handshake (`IpcServer.accept` + `IpcClient.connect`)
//! resilient to a crash on either end — closing the socket is the
//! only correct response to a fatal framing error.

const std = @import("std");

const framing = @import("framing.zig");
const messages = @import("messages.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// All errors a connection method can raise. Union of the transport
/// errors (socket I/O), framing errors (invalid header / schema
/// mismatch / truncated payload), and allocator errors (for the
/// encode-side scratch buffer).
pub const Error = transport.Error || framing.Error || std.mem.Allocator.Error;

/// One framed message after the header has been validated. `header`
/// is the decoded `framing.Header`; `payload_bytes` is a slice of
/// the caller-supplied receive buffer covering exactly
/// `header.payload_len` bytes (`schema_hash` + extern struct body).
pub const Frame = struct {
    header: framing.Header,
    payload_bytes: []const u8,
};

/// One IPC connection. `socket` is borrowed — the caller owns the
/// `IpcSocket` lifetime.
pub const IpcConnection = struct {
    socket: *transport.IpcSocket,
    gpa: std.mem.Allocator,
    /// Monotonic counter used to seed outgoing `seq_id`s when the
    /// caller does not pin one explicitly. Wraps freely at `u32`'s
    /// max — replay-detection lives at a higher layer.
    next_seq: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, socket: *transport.IpcSocket) IpcConnection {
        return .{ .socket = socket, .gpa = gpa };
    }

    /// Allocate and assign the next `seq_id`. Useful for callers
    /// that want the wire-side correlation key in their own state.
    pub fn nextSeqId(self: *IpcConnection) u32 {
        const s = self.next_seq;
        self.next_seq +%= 1;
        return s;
    }

    /// Encode `msg` into a framed buffer and write it to the socket.
    /// `seq_id == 0` is a sentinel meaning "auto-assign from
    /// `next_seq`".
    pub fn sendMessage(
        self: *IpcConnection,
        comptime T: type,
        seq_id: u32,
        msg: *const T,
    ) Error!void {
        const real_seq = if (seq_id == 0) self.nextSeqId() else seq_id;
        const frame_buf = try framing.encode(self.gpa, T, real_seq, msg);
        defer self.gpa.free(frame_buf);
        try self.socket.send(frame_buf);
    }

    /// Same as `sendMessage` but transmits an out-of-band handle
    /// vector via `sendmsg`/`SCM_RIGHTS` (POSIX). Returns
    /// `error.Unimplemented` on Windows in S6 per the brief.
    pub fn sendMessageWithHandles(
        self: *IpcConnection,
        comptime T: type,
        seq_id: u32,
        msg: *const T,
        handles: []const transport.OsHandle,
    ) Error!void {
        const real_seq = if (seq_id == 0) self.nextSeqId() else seq_id;
        const frame_buf = try framing.encode(self.gpa, T, real_seq, msg);
        defer self.gpa.free(frame_buf);
        try self.socket.sendWithHandles(frame_buf, handles);
    }

    /// Read exactly one frame into `buf`. `buf` must be at least
    /// `@sizeOf(framing.Header) + max payload` bytes; for
    /// fixed-size message types the caller can size it from
    /// `framing.frameSizeOf(T)`.
    ///
    /// Returns `error.UnexpectedEof` if the socket closes mid-
    /// frame. The connection is unusable after any error and the
    /// caller must close `socket` and reset (cf. `engine-ipc.md`
    /// §6.2).
    pub fn recvFrame(
        self: *IpcConnection,
        buf: []u8,
    ) Error!Frame {
        if (buf.len < @sizeOf(framing.Header)) return error.UnexpectedEof;

        // Read the header in full first — short reads on a stream
        // socket are normal, so we loop until 16 bytes are buffered.
        try readExact(self.socket, buf[0..@sizeOf(framing.Header)]);
        const header = try framing.parseHeader(buf[0..@sizeOf(framing.Header)]);

        const payload_len: usize = @intCast(header.payload_len);
        if (payload_len > buf.len - @sizeOf(framing.Header)) {
            return error.PayloadTooLarge;
        }
        try readExact(self.socket, buf[@sizeOf(framing.Header) .. @sizeOf(framing.Header) + payload_len]);

        return .{
            .header = header,
            .payload_bytes = buf[@sizeOf(framing.Header) .. @sizeOf(framing.Header) + payload_len],
        };
    }

    /// Convenience helper — receive a frame and decode it as `T` in
    /// one shot. The caller must size `scratch` to at least
    /// `framing.frameSizeOf(T)`. Returns `error.UnknownMsgType` if
    /// the wire frame's `msg_type` does not match `T`.
    pub fn recvMessage(
        self: *IpcConnection,
        comptime T: type,
        scratch: []u8,
    ) Error!T {
        const frame = try self.recvFrame(scratch);
        return framing.decode(T, frame.header, frame.payload_bytes);
    }
};

fn readExact(socket: *transport.IpcSocket, dst: []u8) transport.Error!void {
    var got: usize = 0;
    while (got < dst.len) {
        const n = try socket.recv(dst[got..]);
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }
}
