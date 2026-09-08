//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! The connection BORROWS its socket: the caller owns and closes it, and closing it
//! is the only correct response to a framing error — nothing here survives one.

const std = @import("std");

const framing = @import("framing.zig");
const messages = @import("messages.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const command_log = @import("command_log.zig");

/// Union of the transport, framing and allocator error sets.
pub const Error = transport.Error || framing.Error || std.mem.Allocator.Error;

/// A validated frame; `payload_bytes` is a SLICE INTO the caller's receive buffer.
pub const Frame = struct {
    header: framing.Header,
    payload_bytes: []const u8,
};

/// A frame plus its handle count; the order matches the sender's handle order.
pub const FrameWithHandles = struct {
    header: framing.Header,
    payload_bytes: []const u8,
    handles: usize,
};

/// One IPC connection over a borrowed socket.
pub const IpcConnection = struct {
    socket: *transport.IpcSocket,
    gpa: std.mem.Allocator,
    /// Wraps freely at `u32` max — replay detection belongs to a higher layer.
    next_seq: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, socket: *transport.IpcSocket) IpcConnection {
        return .{ .socket = socket, .gpa = gpa };
    }

    /// Take the next `seq_id`, for a caller keeping the correlation key itself.
    pub fn nextSeqId(self: *IpcConnection) u32 {
        const s = self.next_seq;
        self.next_seq +%= 1;
        return s;
    }

    /// Encode and write one frame. `seq_id == 0` is the auto-assign SENTINEL.
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

    /// As `sendMessage`, with an `SCM_RIGHTS` handle vector; Windows refuses.
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

    /// Read exactly one frame; size `buf` from `framing.frameSizeOf(T)`.
    pub fn recvFrame(
        self: *IpcConnection,
        buf: []u8,
    ) Error!Frame {
        if (buf.len < @sizeOf(framing.Header)) return error.UnexpectedEof;

        // Short reads are NORMAL on a stream socket, so loop for the 16 header bytes.
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

    /// One frame plus the sender's out-of-band fds, which the kernel delivers with
    /// the FIRST chunk. Size `buf` to exactly one frame or the first read steals the
    /// next frame's bytes. Windows refuses.
    pub fn recvFrameWithHandles(
        self: *IpcConnection,
        buf: []u8,
        handles_out: []transport.OsHandle,
    ) Error!FrameWithHandles {
        if (buf.len < @sizeOf(framing.Header)) return error.UnexpectedEof;

        const first = try self.socket.recvWithHandles(buf, handles_out);
        if (first.bytes == 0) return error.UnexpectedEof;
        var got: usize = first.bytes;

        // The fds already rode in with `first`, so a plain `recv` top-up is correct.
        while (got < @sizeOf(framing.Header)) {
            const n = try self.socket.recv(buf[got..]);
            if (n == 0) return error.UnexpectedEof;
            got += n;
        }
        const header = try framing.parseHeader(buf[0..@sizeOf(framing.Header)]);

        const payload_len: usize = @intCast(header.payload_len);
        const total = @sizeOf(framing.Header) + payload_len;
        if (total > buf.len) return error.PayloadTooLarge;
        while (got < total) {
            const n = try self.socket.recv(buf[got..]);
            if (n == 0) return error.UnexpectedEof;
            got += n;
        }

        return .{
            .header = header,
            .payload_bytes = buf[@sizeOf(framing.Header)..total],
            .handles = first.handles,
        };
    }

    /// Receive and decode in one shot; a `msg_type` mismatch is `UnknownMsgType`.
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

/// Raised by `acceptShmHandoff` when a `ShmRegionsHandoff` is malformed.
pub const HandoffError = error{InvalidHandoff};

/// Validate a handoff against the fds actually delivered and return the viewport's.
/// On ANY violation every received fd is closed, so a malformed handoff cannot leak
/// descriptors; on success only `regions[0]` survives and the caller OWNS it.
pub fn acceptShmHandoff(
    handoff: *const messages.ShmRegionsHandoff,
    handles: []const transport.OsHandle,
) HandoffError!transport.OsHandle {
    const region_count: usize = handoff.region_count;
    if (region_count == 0 or
        region_count > messages.MAX_SHM_REGIONS or
        handles.len != region_count)
    {
        for (handles) |h| transport.closeHandle(h);
        return error.InvalidHandoff;
    }
    for (handles[1..]) |h| transport.closeHandle(h);
    return handles[0];
}

/// Outcome of a `replayCommands` pass.
pub const ReplayResult = struct {
    /// Commands successfully re-sent and acked.
    replayed: usize,
    /// False when a nack, timeout or desync stopped the pass early.
    complete: bool,
};

/// Best-effort replay after a crash: re-send each pending frame VERBATIM and await
/// the ack carrying the same `seq_id`. Never raises — a nack, timeout or desync ends
/// the pass with `complete = false`. STRICTLY SERIAL, and that is the contract:
/// pipelining it lets a replayed `seq_id` coexist with a freshly-minted one.
pub fn replayCommands(
    conn: *IpcConnection,
    log: *command_log.CommandLog,
    scratch: []u8,
    now_us: u64,
) ReplayResult {
    var it = log.replaySince();
    var replayed: usize = 0;
    while (it.next()) |entry| {
        const seq = entry.seq_id;
        // Synchronous drain: block on THIS command's ack before the next send.
        conn.socket.send(entry.frameBytes()) catch return .{ .replayed = replayed, .complete = false };
        const frame = conn.recvFrame(scratch) catch return .{ .replayed = replayed, .complete = false };
        if (frame.header.seq_id != seq) return .{ .replayed = replayed, .complete = false };
        log.markAcked(seq, now_us);
        replayed += 1;
    }
    return .{ .replayed = replayed, .complete = true };
}
