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
// M1.1.14 — the engine float environment (`ARCH-031` rule 5): the main thread
// is not born of a spawn, so it is installed here rather than by the job system.
const foundation = @import("foundation");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const protocol = ipc.protocol;
const transport = ipc.transport;
const viewport = ipc.viewport;
const snapshot = ipc.snapshot;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

const Args = struct {
    socket: []const u8 = "",
    shm: []const u8 = "",
    editor_pid: i64 = 0,
    frames: ?u64 = null,
    /// Path of the minimal scene snapshot (engine-ipc.md §7.1): written
    /// on `SaveProject`, reloaded on restart. Empty = no persistence.
    snapshot: []const u8 = "",
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init.Minimal) !Args {
    var args = Args{};
    // `Iterator.init` is a `@compileError` on Windows (no POSIX argv) —
    // the allocator variant parses the wide command line. `init.args`
    // (Juicy Main) is preserved; `deinit` frees the Windows buffer.
    var it = try std.process.Args.Iterator.initAllocator(init.args, gpa);
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
        } else if (std.mem.startsWith(u8, a, "--snapshot=")) {
            args.snapshot = try gpa.dupe(u8, a["--snapshot=".len..]);
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
    // M1.1.14 — the main thread is not born of a spawn, so it does not pass
    // through the job system's worker entry and receives the engine float
    // environment here instead (`ARCH-031` rule 5, `engine-platform.md` §4).
    // First statement, before anything can compute.
    foundation.math.float_env.install();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const args = try parseArgs(gpa, init);

    // Default I/O for the snapshot file ops. The runtime stays
    // `Init.Minimal` per convention (it will bind a custom Io on the job
    // system in Phase 1); a local `Threaded` covers M0.7. `page_allocator`
    // is threadsafe, satisfying Threaded's async-allocator contract, and
    // the `io` is safe to share with the reader thread.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    // Attach the viewport shm. POSIX: the editor passes the region fd
    // out-of-band (SCM_RIGHTS) in a `ShmRegionsHandoff` right after the
    // handshake — map it with `fromFd`, never cross-process `shm_open`
    // (engine-ipc.md §4.8). Windows: no fd-passing — `open` the named
    // mapping the editor created (§2.2), whose name arrived on argv.
    var vp = if (is_posix) blk: {
        var handoff_buf: [framing.frameSizeOf(messages.ShmRegionsHandoff)]u8 = undefined;
        var handoff_handles: [messages.MAX_SHM_REGIONS]transport.OsHandle = undefined;
        @memset(&handoff_handles, transport.invalid_handle);
        const hf = try client.connection().recvFrameWithHandles(&handoff_buf, &handoff_handles);
        const handoff = try framing.decode(messages.ShmRegionsHandoff, hf.header, hf.payload_bytes);
        // Validate §8.3 (count in range + strict fd/descriptor equality);
        // `acceptShmHandoff` closes every excess / unmapped region fd so a
        // malformed handoff cannot leak descriptors.
        const viewport_fd = try ipc.connection.acceptShmHandoff(&handoff, handoff_handles[0..hf.handles]);
        break :blk try viewport.ShmViewport.fromFd(viewport_fd, viewport.default_resolution.width, viewport.default_resolution.height);
    } else blk: {
        break :blk try viewport.ShmViewport.open(args.shm, viewport.default_resolution.width, viewport.default_resolution.height);
    };
    defer vp.close();

    // Reload point: if the editor's last SaveProject persisted a snapshot,
    // resume the mire from it (engine-ipc.md §7.2). Absent ⇒ start clean.
    var start_frame: u64 = 0;
    if (args.snapshot.len != 0) {
        if (snapshot.read(io, args.snapshot)) |snap| start_frame = snap.frame_id;
    }

    // Spawn the dedicated IPC reader thread per brief § Scope —
    // the main loop renders the mire at ~60 Hz while the reader
    // drains the socket and replies to transactional messages.
    var reader_state = ReaderState{
        .client = &client,
        .shutdown_requested = std.atomic.Value(u8).init(0),
        .read_failed = std.atomic.Value(u8).init(0),
        .play_state = std.atomic.Value(u8).init(play_playing),
        .io = io,
        .snapshot_path = args.snapshot,
    };
    const reader = try std.Thread.spawn(.{}, readerLoop, .{&reader_state});
    defer reader.join();

    var frame: u64 = start_frame; // mire animation parameter — advances only while playing
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
    /// I/O for the `SaveProject` snapshot write (shared with main).
    io: std.Io,
    /// Snapshot path, or empty to skip persistence.
    snapshot_path: []const u8,
};

fn readerLoop(state: *ReaderState) void {
    // `ARCH-031` rule 5 — a THREAD-CREATION site's body installs the float
    // environment. `main` installing it does not cover this thread: the state is
    // per-thread, and a reader that inherits the OS default is a second
    // arithmetic in the same process.
    foundation.math.float_env.install();

    // Sized to the largest frame the editor can send the runtime —
    // computed over the FULL incoming set (every editor→runtime type the
    // reader reads, whether or not it decodes it: `recvFrame` buffers the
    // whole frame before the switch). Runtime→editor types (RuntimeError,
    // the acks, …) are never received here and do not size this buffer.
    // Current max: LoadScene / SaveScene at 280 B (16 + 8 + 256). Relying
    // on @max(Echo, LoadScene) would silently undersize if a future
    // incoming message grew past 256 B — so enumerate them explicitly.
    const max_incoming_frame = comptime blk: {
        var m: usize = 0;
        for (.{
            messages.Heartbeat,       messages.Shutdown,
            messages.Echo,            messages.SpawnEntity,
            messages.ModifyComponent, messages.Play,
            messages.Pause,           messages.Stop,
            messages.LoadScene,       messages.HotReloadScript,
            messages.SaveScene,       messages.SaveProject,
        }) |T| {
            m = @max(m, framing.frameSizeOf(T));
        }
        break :blk m;
    };
    var scratch: [max_incoming_frame]u8 = undefined;
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
                // Transactional (§3.4): persist the minimal scene snapshot
                // (the replay reload point, §7.1) THEN reply `ProjectSaved`
                // with the same seq_id. The stub records the SaveProject
                // seq_id as the scene marker. A snapshot write failure is
                // surfaced via `ok = 0` so the editor does not advance its
                // clean line on a save that did not persist.
                var ok: u8 = 1;
                if (state.snapshot_path.len != 0) {
                    snapshot.write(state.io, state.snapshot_path, .{
                        .magic = 0,
                        .version = 0,
                        .frame_id = fr.header.seq_id,
                    }) catch {
                        ok = 0;
                    };
                }
                const ps = messages.ProjectSaved{ .ok = ok, .reason = std.mem.zeroes([128]u8) };
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
