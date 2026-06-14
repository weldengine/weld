//! Crash-recovery + best-effort-replay tests (C0.4; brief E4). Drives
//! the real `weld-runtime` binary end-to-end. **Un-gated to Windows in
//! M0.7 / E4** (was POSIX-only): the per-OS differences are isolated in
//! `spawnAndHandshake` (POSIX hands the viewport fd off via SCM_RIGHTS;
//! Windows opens the named mapping by name, §2.2) and in the cleanup
//! helpers. Clock/sleep use cross-platform `std` (no POSIX externs).
//!
//!   - kill -9 runtime → editor detects EOF < 100 ms.
//!   - kill -9 → editor restarts + the first post-restart Echo round-trips.
//!   - editor close → runtime detects EOF + exits clean (code 0).
//!   - kill -9 + best-effort replay → after restart, the post-save
//!     pending commands replay < 500 ms aggregate (engine-ipc.md §7.2).
//!
//! Windows behaviour is validated on Guy's PC + CI; macOS dev exercises
//! the same paths thanks to the SCM_RIGHTS pivot (E1).

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const transport = ipc.transport;
const command_log = ipc.command_log;
const platform_process = weld_core.platform.process;
const platform_time = weld_core.platform.time;
const viewport = ipc.viewport;

const is_windows = builtin.os.tag == .windows;
const W = viewport.default_resolution.width;
const H = viewport.default_resolution.height;

extern "c" fn getpid() i32;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn shm_unlink(name: [*:0]const u8) i32;

/// Monotonic milliseconds via the cross-platform platform-time wrapper
/// (`QueryPerformanceCounter` / `clock_gettime`) — `std.time.milliTimestamp`
/// no longer exists in 0.16.
fn nowMs() i64 {
    return @intCast(platform_time.nowNanos() / std.time.ns_per_ms);
}

/// Cross-platform sleep via the platform-time wrapper (`Sleep` /
/// `nanosleep`); `std.Thread.sleep` is gone in 0.16. Needs an `io`.
fn sleepMs(io: std.Io, ms: u64) void {
    platform_time.sleepPrecise(io, ms * std.time.ns_per_ms) catch {};
}

/// The runtime binary path, relative to the project root (the cwd when
/// `zig build test` dispatches the test). `.exe` on Windows so
/// `CreateProcessW` resolves it.
const runtime_exe = if (is_windows) "zig-out/bin/weld-runtime.exe" else "zig-out/bin/weld-runtime";

/// POSIX shm name `/weld-shm-<tag>-<pid>` vs Windows session-local
/// `Local\weld-shm-<tag>-<pid>` (§2.2). Written into `buf`.
fn shmName(buf: []u8, tag: []const u8, pid: i32) ![]const u8 {
    return if (is_windows)
        std.fmt.bufPrintZ(buf, "Local\\weld-shm-{s}-{d}", .{ tag, pid })
    else
        std.fmt.bufPrintZ(buf, "/weld-shm-{s}-{d}", .{ tag, pid });
}

/// Best-effort removal of a POSIX socket file + shm region. No-op on
/// Windows (named pipes + named mappings are refcounted kernel objects
/// that vanish with their last handle).
fn cleanupPosix(socket_path: [:0]const u8, shm: [:0]const u8) void {
    if (comptime is_windows) return;
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm.ptr);
}

/// Editor-side viewport fd handoff (POSIX only) — mirrors
/// `src/editor/main.zig`. On Windows the runtime opens the mapping by
/// name, so no handoff is sent.
fn sendViewportHandoff(server: *ipc.server.IpcServer, vp: *const viewport.ShmViewport) !void {
    var handoff = messages.ShmRegionsHandoff{
        .region_count = 1,
        .regions = std.mem.zeroes([messages.MAX_SHM_REGIONS]messages.ShmRegionDesc),
    };
    messages.writeFixedString(&handoff.regions[0].logical_name, "viewport_framebuffer");
    handoff.regions[0].size = viewport.regionSize(W, H);
    try server.connection().sendMessageWithHandles(
        messages.ShmRegionsHandoff,
        0,
        &handoff,
        &[_]transport.OsHandle{vp.fd()},
    );
}

const Spawned = struct { vp: viewport.ShmViewport, proc: platform_process.Process };

/// Spawn the runtime against the caller-owned (stable) `server`, run the
/// handshake, and attach the viewport — POSIX handoff vs Windows by-name.
/// Returns the created viewport + child. `socket_path` / `shm_name` /
/// `snapshot_path` are caller-owned.
fn spawnAndHandshake(
    server: *ipc.server.IpcServer,
    gpa: std.mem.Allocator,
    socket_path: []const u8,
    shm_name: []const u8,
    snapshot_path: []const u8,
) !Spawned {
    var vp = try viewport.ShmViewport.create(shm_name, W, H);
    errdefer vp.close();

    try server.listen(socket_path);

    const pid = getpid();
    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    defer gpa.free(socket_arg);
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    defer gpa.free(shm_arg);
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{pid});
    defer gpa.free(pid_arg);
    const snap_arg = try std.fmt.allocPrint(gpa, "--snapshot={s}", .{snapshot_path});
    defer gpa.free(snap_arg);
    const argv = [_][]const u8{ runtime_exe, socket_arg, shm_arg, pid_arg, snap_arg };

    const proc = try platform_process.spawnProcess(gpa, runtime_exe, &argv);
    try server.acceptOne();

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    _ = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");
    if (comptime !is_windows) try sendViewportHandoff(server, &vp);

    return .{ .vp = vp, .proc = proc };
}

fn reap(io: std.Io, proc: *platform_process.Process) void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (platform_process.waitNonblock(proc) catch null) |_| return;
        sleepMs(io, 10);
    }
}

test "runtime kill -9 → editor detects EOF in <100ms" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pid = getpid();
    var sock_buf: [96]u8 = undefined;
    const socket_path = try ipc.transport.buildSocketPath(&sock_buf, "weld-crashtest");
    var shm_buf: [64]u8 = undefined;
    const shm = try shmName(&shm_buf, "crashtest", pid);
    var snap_buf: [64]u8 = undefined;
    const snap = try std.fmt.bufPrint(&snap_buf, "weld-snap-crashtest-{d}.bin", .{pid});
    cleanupPosix(socket_path, @ptrCast(shm));
    defer cleanupPosix(socket_path, @ptrCast(shm));

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    var sp = try spawnAndHandshake(&server, gpa, socket_path, shm, snap);
    defer sp.vp.close();

    sleepMs(io, 50); // let the runtime settle into its loops
    const t0 = nowMs();
    try platform_process.kill(&sp.proc);

    var scratch: [256]u8 = undefined;
    const detect_res = server.connection().recvFrame(&scratch);
    const detect_ms = nowMs() - t0;
    try std.testing.expect(detect_ms < 100);
    try std.testing.expectError(error.UnexpectedEof, detect_res);

    reap(io, &sp.proc);
}

test "runtime kill -9 → editor restarts + first post-restart Echo OK" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pid = getpid();
    var sock_buf: [96]u8 = undefined;
    const socket_path = try ipc.transport.buildSocketPath(&sock_buf, "weld-restart");
    var shm_buf: [64]u8 = undefined;
    const shm = try shmName(&shm_buf, "restart", pid);
    var snap_buf: [64]u8 = undefined;
    const snap = try std.fmt.bufPrint(&snap_buf, "weld-snap-restart-{d}.bin", .{pid});
    cleanupPosix(socket_path, @ptrCast(shm));
    defer cleanupPosix(socket_path, @ptrCast(shm));

    // First spawn + handshake + kill.
    var server = ipc.server.IpcServer.init(gpa);
    var sp1 = try spawnAndHandshake(&server, gpa, socket_path, shm, snap);
    try platform_process.kill(&sp1.proc);
    var scratch: [256]u8 = undefined;
    _ = server.connection().recvFrame(&scratch) catch {};
    sp1.vp.close();
    server.deinit();
    reap(io, &sp1.proc);

    // Second spawn + handshake + Echo round-trip.
    var server2 = ipc.server.IpcServer.init(gpa);
    defer server2.deinit();
    var sp2 = try spawnAndHandshake(&server2, gpa, socket_path, shm, snap);
    defer sp2.vp.close();

    var echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    for (&echo.payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    try server2.connection().sendMessage(messages.Echo, 0, &echo);
    var rep_buf: [framing.frameSizeOf(messages.EchoReply)]u8 = undefined;
    const reply = try server2.connection().recvMessage(messages.EchoReply, &rep_buf);
    try std.testing.expectEqualSlices(u8, &echo.payload, &reply.payload);

    const sd = messages.Shutdown{};
    try server2.connection().sendMessage(messages.Shutdown, 0, &sd);
    var sa_buf: [framing.frameSizeOf(messages.ShutdownAck)]u8 = undefined;
    _ = server2.connection().recvMessage(messages.ShutdownAck, &sa_buf) catch {};
    reap(io, &sp2.proc);
}

test "editor close → runtime detects EOF + exits clean code 0" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pid = getpid();
    var sock_buf: [96]u8 = undefined;
    const socket_path = try ipc.transport.buildSocketPath(&sock_buf, "weld-g5");
    var shm_buf: [64]u8 = undefined;
    const shm = try shmName(&shm_buf, "g5", pid);
    var snap_buf: [64]u8 = undefined;
    const snap = try std.fmt.bufPrint(&snap_buf, "weld-snap-g5-{d}.bin", .{pid});
    cleanupPosix(socket_path, @ptrCast(shm));
    defer cleanupPosix(socket_path, @ptrCast(shm));

    var server = ipc.server.IpcServer.init(gpa);
    var sp = try spawnAndHandshake(&server, gpa, socket_path, shm, snap);
    defer sp.vp.close();

    sleepMs(io, 50);
    // Simulate editor SIGKILL: abrupt server teardown, no Shutdown. The
    // runtime sees EOF on its next recv and exits 0.
    const t0 = nowMs();
    server.deinit();

    var exit_code: ?i32 = null;
    var poll: usize = 0;
    while (poll < 200) : (poll += 1) {
        if (try platform_process.waitNonblock(&sp.proc)) |code| {
            exit_code = code;
            break;
        }
        sleepMs(io, 10);
    }
    const exit_ms = nowMs() - t0;
    try std.testing.expect(exit_code != null);
    try std.testing.expectEqual(@as(i32, 0), exit_code.?);
    try std.testing.expect(exit_ms < 500);
}

test "kill -9 + best-effort replay of post-save commands" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pid = getpid();
    var sock_buf: [96]u8 = undefined;
    const socket_path = try ipc.transport.buildSocketPath(&sock_buf, "weld-replay");
    var shm_buf: [64]u8 = undefined;
    const shm = try shmName(&shm_buf, "replay", pid);
    var snap_buf: [64]u8 = undefined;
    const snap = try std.fmt.bufPrint(&snap_buf, "weld-snap-replay-{d}.bin", .{pid});
    cleanupPosix(socket_path, @ptrCast(shm));
    defer cleanupPosix(socket_path, @ptrCast(shm));
    // SaveProject persists this snapshot; remove it on the way out so the
    // marker file does not leak into the work tree (cross-platform via io).
    defer std.Io.Dir.cwd().deleteFile(io, snap) catch {};

    var log = try command_log.CommandLog.init(gpa);
    defer log.deinit();

    var scratch: [256]u8 = undefined;

    // ---- First session: establish a clean line, then queue pending
    // post-save commands, then crash. ----
    {
        var server = ipc.server.IpcServer.init(gpa);
        var sp = try spawnAndHandshake(&server, gpa, socket_path, shm, snap);

        // SaveProject → ProjectSaved: the runtime writes the snapshot;
        // the clean line advances on the ack.
        const save = messages.SaveProject{};
        try server.connection().sendMessage(messages.SaveProject, 100, &save);
        const saved = try server.connection().recvMessage(messages.ProjectSaved, &scratch);
        try std.testing.expectEqual(@as(u8, 1), saved.ok);
        log.markCleanLine();

        // Queue 3 post-save transactional commands, logging each frame
        // but NOT reading their acks — they stay pending for replay.
        var seq: u32 = 101;
        while (seq <= 103) : (seq += 1) {
            const cmd = messages.SpawnEntity{ .archetype_hint = seq };
            const frame = try framing.encode(gpa, messages.SpawnEntity, seq, &cmd);
            defer gpa.free(frame);
            try server.connection().socket.send(frame);
            try log.append(seq, @intFromEnum(messages.MsgType.spawn_entity), frame, 0);
        }

        // Crash the runtime, then drain any buffered acks until EOF —
        // detection must be < 100 ms.
        const t0 = nowMs();
        try platform_process.kill(&sp.proc);
        while (true) {
            _ = server.connection().recvFrame(&scratch) catch break; // EOF/broken
        }
        try std.testing.expect(nowMs() - t0 < 100);

        sp.vp.close();
        server.deinit();
        reap(io, &sp.proc);
    }

    // 3 commands appended after the clean line, none acked.
    var pending: usize = 0;
    var it = log.replaySince();
    while (it.next()) |_| pending += 1;
    try std.testing.expectEqual(@as(usize, 3), pending);

    // ---- Restart + replay. The fresh runtime reloads from the snapshot
    // and re-acks the replayed commands. ----
    {
        var server = ipc.server.IpcServer.init(gpa);
        defer server.deinit();
        var sp = try spawnAndHandshake(&server, gpa, socket_path, shm, snap);
        defer sp.vp.close();

        const t0 = nowMs();
        const result = ipc.connection.replayCommands(server.connection(), &log, &scratch, 0);
        const replay_ms = nowMs() - t0;

        try std.testing.expect(result.complete);
        try std.testing.expectEqual(@as(usize, 3), result.replayed);
        try std.testing.expect(replay_ms < 500); // aggregate budget

        const sd = messages.Shutdown{};
        try server.connection().sendMessage(messages.Shutdown, 0, &sd);
        var sa_buf: [framing.frameSizeOf(messages.ShutdownAck)]u8 = undefined;
        _ = server.connection().recvMessage(messages.ShutdownAck, &sa_buf) catch {};
        reap(io, &sp.proc);
    }
}
