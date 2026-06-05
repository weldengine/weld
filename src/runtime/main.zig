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
const transport = ipc.transport;
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

    // Send ProtocolHello and await the editor's acceptance.
    try client.sendHello("0.0.7-S6", "deadbee", 0);

    var ack_buf: [framing.frameSizeOf(messages.ProtocolHelloAck)]u8 = undefined;
    const ack = try client.recvHelloAck(&ack_buf);
    if (ack.accepted == 0) {
        const reason = messages.readFixedString(&ack.reason);
        std.debug.print("runtime stub: editor rejected handshake: {s}\n", .{reason});
        return error.HandshakeRejected;
    }

    // Receive the shm fd handoff (engine-ipc.md §4.8) and map the
    // viewport from the received fd — the primary cross-process attach.
    // The runtime never calls cross-process shm_open; `args.shm` is kept
    // for the Windows by-name path (E3) and unused here on POSIX.
    var handoff_buf: [framing.frameSizeOf(messages.ShmRegionsHandoff)]u8 = undefined;
    var handoff_handles: [messages.MAX_SHM_REGIONS]transport.OsHandle = undefined;
    @memset(&handoff_handles, transport.invalid_handle);
    const hf = try client.connection().recvFrameWithHandles(&handoff_buf, &handoff_handles);
    const handoff = try framing.decode(messages.ShmRegionsHandoff, hf.header, hf.payload_bytes);
    // Validate §8.3 (count in range + strict fd/descriptor equality) and
    // select the viewport fd. `acceptShmHandoff` closes every excess /
    // unmapped region fd, so a malformed handoff cannot leak descriptors.
    const viewport_fd = try ipc.connection.acceptShmHandoff(&handoff, handoff_handles[0..hf.handles]);
    var vp = try viewport.ShmViewport.fromFd(
        viewport_fd,
        viewport.default_resolution.width,
        viewport.default_resolution.height,
    );
    defer vp.close();

    // Spawn the dedicated IPC reader thread per brief § Scope —
    // the main loop renders the mire at ~60 Hz while the reader
    // drains the socket and replies to transactional messages.
    var reader_state = ReaderState{
        .client = &client,
        .shutdown_requested = std.atomic.Value(u8).init(0),
        .read_failed = std.atomic.Value(u8).init(0),
        .play_state = std.atomic.Value(u8).init(play_playing),
    };
    const reader = try std.Thread.spawn(.{}, readerLoop, .{&reader_state});
    defer reader.join();

    var frame: u64 = 0; // mire animation parameter — advances only while playing
    var iter: u64 = 0; // loop iterations — bounds the lifetime via --frames
    while (true) {
        if (args.frames) |max| {
            if (iter >= max) break;
        }
        if (reader_state.shutdown_requested.load(.acquire) != 0) break;
        if (reader_state.read_failed.load(.acquire) != 0) break;

        const slot = vp.nextWriteSlot();
        renderMire(&vp, slot, frame);
        vp.commit(slot);
        // Play/Pause/Stop gate the animation: advance the mire only while
        // playing; paused/stopped re-commit the held frame so the viewport
        // stays live (G6 visual) without animating.
        if (reader_state.play_state.load(.acquire) == play_playing) frame += 1;
        sleepMs(16); // ~60 Hz
        iter += 1;
    }
}

/// Play-state driven by the `Play` / `Pause` / `Stop` commands
/// (`engine-ipc.md` §3.3). Default `playing` so the S6 mire renders
/// immediately when no control command is sent (e.g. the crash-recovery
/// tests). The reader thread sets it; the render loop reads it to gate
/// the mire's frame advance.
const play_stopped: u8 = 0;
const play_playing: u8 = 1;
const play_paused: u8 = 2;

const ReaderState = struct {
    client: *ipc.client.IpcClient,
    shutdown_requested: std.atomic.Value(u8),
    read_failed: std.atomic.Value(u8),
    /// `play_stopped` / `play_playing` / `play_paused`.
    play_state: std.atomic.Value(u8),
};

fn readerLoop(state: *ReaderState) void {
    // Sized to the largest editor→runtime frame the reader decodes.
    // `LoadScene` / `SaveScene` (256-byte path) dominate; `RuntimeError`
    // is runtime→editor only, so it does not size this buffer.
    const max_frame_buf_size = comptime @max(
        framing.frameSizeOf(messages.Echo),
        framing.frameSizeOf(messages.LoadScene),
    );
    var scratch: [@as(usize, max_frame_buf_size) + 64]u8 = undefined;
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
            .play => state.play_state.store(play_playing, .release),
            .pause => state.play_state.store(play_paused, .release),
            .stop => state.play_state.store(play_stopped, .release),
            .load_scene => {
                const ls = framing.decode(messages.LoadScene, fr.header, fr.payload_bytes) catch return;
                const path = messages.readFixedString(&ls.path);
                if (path.len == 0) {
                    // Recoverable, non-transactional command failure → a
                    // non-fatal RuntimeError event (§3.3), not a protocol
                    // fatal. Surfaced for the editor's "Replay Errors" panel.
                    var re = messages.RuntimeError{
                        .severity = @intFromEnum(messages.ErrorSeverity.warning),
                        .source = std.mem.zeroes([64]u8),
                        .text = std.mem.zeroes([256]u8),
                    };
                    messages.writeFixedString(&re.source, "runtime");
                    messages.writeFixedString(&re.text, "load_scene: empty path");
                    state.client.connection().sendMessage(messages.RuntimeError, 0, &re) catch return;
                }
                // A non-empty path is accepted (the stub has no scene to load).
            },
            .hot_reload_script => {
                // Stub: decode to validate the frame. The real reload + the
                // ScriptHotReloadComplete event land with the script pipeline
                // (out of M0.7 scope).
                _ = framing.decode(messages.HotReloadScript, fr.header, fr.payload_bytes) catch return;
            },
            .save_project => {
                // Transactional (§3.4): reply `ProjectSaved` with the same
                // seq_id. The stub always succeeds; the minimal binary
                // snapshot is wired in E4.
                const ps = messages.ProjectSaved{ .ok = 1, .reason = std.mem.zeroes([128]u8) };
                state.client.connection().sendMessage(messages.ProjectSaved, fr.header.seq_id, &ps) catch return;
            },
            // `save_scene` (scene granularity) is declared with no wired
            // handler in M0.7 — it falls through to `else` and is ignored.
            else => {
                // Unilateral / unsupported types — ignore at the stub level.
            },
        }
    }
}
