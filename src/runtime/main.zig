//! Weld runtime stub — the spawned-by-editor process side of the
//! S6 editor↔runtime IPC.
//!
//! Argv contract (set by `src/editor/main.zig`):
//!   argv[0] = binary path
//!   argv[1] = `--socket=<path>`
//!   argv[2] = `--shm=<name>`
//!   argv[3] = `--editor-pid=<pid>`
//!   argv[4] = (optional) `--frames=<N>` to bound the lifetime
//!             (default: run until editor closes the socket).
//!
//! S6 behaviour:
//!   - Parses argv, connects to the editor's listening socket,
//!     attaches the viewport shm.
//!   - Sends `ProtocolHello { protocol_version, "0.0.7-S6",
//!     "deadbee", capabilities: 0 }` and awaits `ProtocolHelloAck`.
//!     Logs and exits non-zero on rejection.
//!   - Drives a 60 Hz mire (CPU-side color gradient with frame-
//!     counter modulation) into the shm viewport's double-buffer.
//!   - Replies to `Heartbeat` immediately with `HeartbeatAck`.
//!   - On `Shutdown` from the editor, replies with `ShutdownAck`
//!     and exits cleanly.
//!   - On socket EOF (editor crashed), exits cleanly with code 0.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const protocol = ipc.protocol;
const viewport = ipc.viewport;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

const Args = struct {
    socket: []const u8 = "",
    shm: []const u8 = "",
    editor_pid: i64 = 0,
    frames: ?u64 = null,
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init.Minimal) !Args {
    var args = Args{};
    var it = std.process.Args.Iterator.init(init.args);
    defer it.deinit();
    _ = it.skip(); // argv[0] (binary path)

    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "--socket=")) {
            args.socket = try gpa.dupe(u8, a["--socket=".len..]);
        } else if (std.mem.startsWith(u8, a, "--shm=")) {
            args.shm = try gpa.dupe(u8, a["--shm=".len..]);
        } else if (std.mem.startsWith(u8, a, "--editor-pid=")) {
            args.editor_pid = try std.fmt.parseInt(i64, a["--editor-pid=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--frames=")) {
            args.frames = try std.fmt.parseInt(u64, a["--frames=".len..], 10);
        }
    }
    if (args.socket.len == 0) return error.MissingSocketArg;
    if (args.shm.len == 0) return error.MissingShmArg;
    return args;
}

fn renderMire(vp: *viewport.ShmViewport, slot: u32, frame: u64) void {
    const sb = vp.slotBytes(slot);
    const width = vp.width;
    const height = vp.height;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const i: usize = (@as(usize, y) * width + x) * 4;
            sb[i + 0] = @intCast((x +% @as(u32, @truncate(frame))) & 0xFF);
            sb[i + 1] = @intCast((y +% @as(u32, @truncate(frame >> 1))) & 0xFF);
            sb[i + 2] = @intCast(((x +% y) +% @as(u32, @truncate(frame >> 2))) & 0xFF);
            sb[i + 3] = 0xFF;
        }
    }
}

const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn nanosleep(req: *const timespec_t, rem: ?*timespec_t) c_int;
fn sleepMs(ms: u64) void {
    var ts = timespec_t{
        .tv_sec = @intCast(ms / 1_000),
        .tv_nsec = @intCast((ms % 1_000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (!is_posix) {
        std.debug.print("runtime stub: Windows path not implemented in S6 (cf. brief)\n", .{});
        return error.Unimplemented;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const args = try parseArgs(gpa, init);

    var client = ipc.client.IpcClient.init(gpa);
    defer client.deinit();
    try client.connect(args.socket);

    // Attach the viewport shm region the editor created.
    var vp = try viewport.ShmViewport.open(args.shm, viewport.default_resolution.width, viewport.default_resolution.height);
    defer vp.close();

    // Send ProtocolHello.
    try client.sendHello("0.0.7-S6", "deadbee", 0);

    var ack_buf: [framing.frameSizeOf(messages.ProtocolHelloAck)]u8 = undefined;
    const ack = try client.recvHelloAck(&ack_buf);
    if (ack.accepted == 0) {
        const reason = messages.readFixedString(&ack.reason);
        std.debug.print("runtime stub: editor rejected handshake: {s}\n", .{reason});
        return error.HandshakeRejected;
    }

    // Spawn the dedicated IPC reader thread per brief § Scope —
    // the main loop renders the mire at ~60 Hz while the reader
    // drains the socket and replies to transactional messages.
    var reader_state = ReaderState{ .client = &client, .shutdown_requested = std.atomic.Value(u8).init(0), .read_failed = std.atomic.Value(u8).init(0) };
    const reader = try std.Thread.spawn(.{}, readerLoop, .{&reader_state});
    defer reader.join();

    var frame: u64 = 0;
    while (true) {
        if (args.frames) |max| {
            if (frame >= max) break;
        }
        if (reader_state.shutdown_requested.load(.acquire) != 0) break;
        if (reader_state.read_failed.load(.acquire) != 0) break;

        const slot = vp.nextWriteSlot();
        renderMire(&vp, slot, frame);
        vp.commit(slot);
        sleepMs(16); // ~60 Hz
        frame += 1;
    }
}

const ReaderState = struct {
    client: *ipc.client.IpcClient,
    shutdown_requested: std.atomic.Value(u8),
    read_failed: std.atomic.Value(u8),
};

fn readerLoop(state: *ReaderState) void {
    const max_frame_buf_size = comptime @max(
        @max(framing.frameSizeOf(messages.Heartbeat), framing.frameSizeOf(messages.Shutdown)),
        framing.frameSizeOf(messages.Echo),
    );
    var scratch: [@as(usize, max_frame_buf_size) + 256]u8 = undefined;
    while (true) {
        const fr = state.client.connection().recvFrame(&scratch) catch {
            state.read_failed.store(1, .release);
            return;
        };
        const mt: messages.MsgType = @enumFromInt(fr.header.msg_type);
        switch (mt) {
            .heartbeat => {
                const hb = framing.decode(messages.Heartbeat, fr.header, fr.payload_bytes) catch return;
                const ack_msg = messages.HeartbeatAck{
                    .sent_at_us = hb.sent_at_us,
                    .received_at_us = hb.sent_at_us,
                };
                state.client.connection().sendMessage(messages.HeartbeatAck, fr.header.seq_id, &ack_msg) catch return;
            },
            .shutdown => {
                const ack = messages.ShutdownAck{};
                state.client.connection().sendMessage(messages.ShutdownAck, fr.header.seq_id, &ack) catch {};
                state.shutdown_requested.store(1, .release);
                return;
            },
            .echo => {
                const ec = framing.decode(messages.Echo, fr.header, fr.payload_bytes) catch return;
                const reply = messages.EchoReply{ .payload = ec.payload };
                state.client.connection().sendMessage(messages.EchoReply, fr.header.seq_id, &reply) catch return;
            },
            .spawn_entity => {
                const created = messages.EntityCreated{ .entity = fr.header.seq_id };
                state.client.connection().sendMessage(messages.EntityCreated, fr.header.seq_id, &created) catch return;
            },
            .modify_component => {
                const ack = messages.ModifyAck{ .success = 1 };
                state.client.connection().sendMessage(messages.ModifyAck, fr.header.seq_id, &ack) catch return;
            },
            else => {
                // Unilateral / unsupported types — ignore at the stub level.
            },
        }
    }
}
