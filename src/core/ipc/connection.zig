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
const command_log = @import("command_log.zig");

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

/// A frame received alongside out-of-band OS handles
/// (`recvFrameWithHandles`). `handles` is the number of descriptors
/// written into the caller's `handles_out` slot vector — the order
/// matches the sender's `sendMessageWithHandles` handle order.
pub const FrameWithHandles = struct {
    header: framing.Header,
    payload_bytes: []const u8,
    handles: usize,
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

    /// Receive one frame together with the out-of-band OS handles the
    /// sender attached via `sendMessageWithHandles` (POSIX
    /// `SCM_RIGHTS`). The ancillary fds are delivered by the kernel
    /// with the first byte chunk; this reads that chunk via
    /// `recvWithHandles` (capturing the handles), then tops up any
    /// short read with plain `recv` to complete the frame — the
    /// handles have already arrived. Used for `ShmRegionsHandoff`
    /// (`engine-ipc.md` §4.8). `buf` should be sized to exactly
    /// `framing.frameSizeOf(T)` so the first read cannot pull bytes of
    /// a following frame. Returns `error.Unimplemented` on Windows
    /// (the named-pipe backend has no `recvWithHandles` in M0.7).
    pub fn recvFrameWithHandles(
        self: *IpcConnection,
        buf: []u8,
        handles_out: []transport.OsHandle,
    ) Error!FrameWithHandles {
        if (buf.len < @sizeOf(framing.Header)) return error.UnexpectedEof;

        const first = try self.socket.recvWithHandles(buf, handles_out);
        if (first.bytes == 0) return error.UnexpectedEof;
        var got: usize = first.bytes;

        // Top up the header if the first chunk was short — the fds
        // already rode in with `first`, so plain `recv` is correct here.
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

/// Raised by `acceptShmHandoff` when a `ShmRegionsHandoff` is malformed.
pub const HandoffError = error{InvalidHandoff};

/// Validate a decoded `ShmRegionsHandoff` against the fds delivered
/// out-of-band and select the viewport fd to map (`engine-ipc.md`
/// §8.3). `handles` is the populated prefix of the receiver's handle
/// vector (i.e. `handoff_handles[0..recv_result.handles]`).
///
/// Rules (any violation ⇒ `error.InvalidHandoff`):
///   - `region_count` is in `[1, MAX_SHM_REGIONS]`;
///   - the fd count equals `region_count` exactly.
///
/// On a violation, **every** received fd is closed before returning so
/// a malformed handoff cannot leak descriptors into the runtime. On
/// success, M0.7 maps only `regions[0]` (`viewport_framebuffer`); the
/// fds of any further declared regions are closed here, and the
/// viewport fd (`handles[0]`, now owned by the caller) is returned.
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
    // Map only the viewport (regions[0]); close every other region fd so
    // a multi-region handoff cannot leak descriptors into the runtime.
    for (handles[1..]) |h| transport.closeHandle(h);
    return handles[0];
}

/// Outcome of a `replayCommands` pass.
pub const ReplayResult = struct {
    /// Commands successfully re-sent and acked.
    replayed: usize,
    /// True when every pending command replayed; false when a nack /
    /// timeout / desync stopped the pass early (§7.2).
    complete: bool,
};

/// Best-effort replay after a crash + restart (`engine-ipc.md` §7.2,
/// `engine-tools-editor.md` §2.7.4). For each command in `log` since the
/// last clean line still pending, re-send its frame verbatim over `conn`
/// and await a reply carrying the same `seq_id`; on a match, mark it
/// acked and continue. The first nack, timeout, or desync stops the pass
/// hard — no idempotence is attempted (§7.3). The caller arms the
/// per-command timeout via a socket recv timeout (`SO_RCVTIMEO` on
/// POSIX); a recv error (timeout / EOF) ends the pass. `scratch` must
/// hold one full reply frame. Never raises — failures end the pass with
/// `complete = false`.
///
/// **Invariant — `seq_id` safety (§3.4).** This pass is *synchronous* and
/// drains each replayed command fully — `send` → `recvFrame` of the ack
/// carrying the same `seq_id` → `markAcked` — before advancing to the next
/// entry, and the caller (the editor) MUST NOT resume emitting new commands
/// until this function returns. That strict serialization is what
/// guarantees a replayed `seq_id` can never coexist with a freshly-issued
/// one in the editor's `seq_id`→callback map: each replayed id is retired
/// (acked) one at a time, before any new id is minted. Making the replay
/// asynchronous, or pipelining it (issuing the next frame before the prior
/// ack lands, or overlapping it with normal traffic), would BREAK this
/// guarantee and reopen the collision window. Keep it strictly serial.
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
        // Re-send the original frame byte-for-byte (same seq_id). `seq`
        // is captured before any mutation; `entry` is not read after the
        // `markAcked` below (forward-only iteration, no revisit).
        // Synchronous drain: block on THIS command's ack before the next
        // send — never pipeline (see the seq_id-safety invariant above).
        conn.socket.send(entry.frameBytes()) catch return .{ .replayed = replayed, .complete = false };
        const frame = conn.recvFrame(scratch) catch return .{ .replayed = replayed, .complete = false };
        if (frame.header.seq_id != seq) return .{ .replayed = replayed, .complete = false };
        log.markAcked(seq, now_us);
        replayed += 1;
    }
    return .{ .replayed = replayed, .complete = true };
}
