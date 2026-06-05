//! M0.7 / E2 — extended message-catalogue tests (brief § Acceptance
//! criteria › Tests). Two layers:
//!
//!   1. Pure framing round-trips (`encode` → `decode` parity) for every
//!      message added in M0.7 — portable, no runtime, validates the
//!      wire format + schema_hash of each new type.
//!   2. End-to-end handler behaviour against the real `weld-runtime`
//!      binary (POSIX-gated, like `crash_recovery.zig`; the SCM_RIGHTS
//!      pivot makes the cross-process attach work on macOS too):
//!      `SaveProject` → `ProjectSaved` (same seq_id), `LoadScene` with
//!      an empty path → `RuntimeError` event, and `Play`/`Pause`/`Stop`
//!      accepted without desync (an `Echo` after them still round-trips).
//!
//! External-resource discipline (engine-zig-conventions.md §13): the
//! accepted socket gets a 5 s `SO_RCVTIMEO` so a missing reply fails the
//! test instead of hanging the suite.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const transport = ipc.transport;
const viewport = ipc.viewport;
const platform_process = weld_core.platform.process;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

// ----------------------------------------------- pure framing round-trips --

/// Encode a message, parse its header, decode it back, and assert the
/// bytes survive the round-trip. Exercises the wire format + schema_hash
/// for `T`.
fn roundTrip(comptime T: type, msg: T) !void {
    const gpa = std.testing.allocator;
    const buf = try framing.encode(gpa, T, 123, &msg);
    defer gpa.free(buf);

    const header = try framing.parseHeader(buf);
    try std.testing.expectEqual(@as(u16, @intFromEnum(messages.msgTypeOf(T))), header.msg_type);
    try std.testing.expectEqual(@as(u32, 123), header.seq_id);

    const decoded = try framing.decode(T, header, buf[@sizeOf(framing.Header)..]);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&msg), std.mem.asBytes(&decoded));
}

test "catalogue messages round-trip through encode/decode" {
    try roundTrip(messages.Play, .{});
    try roundTrip(messages.Pause, .{});
    try roundTrip(messages.Stop, .{});
    try roundTrip(messages.SaveProject, .{});
    try roundTrip(messages.SaveScene, .{ .path = std.mem.zeroes([256]u8) });
    try roundTrip(messages.HotReloadScript, .{ .script_handle = 0xDEADBEEF_CAFEBABE });

    var load = messages.LoadScene{ .path = std.mem.zeroes([256]u8) };
    messages.writeFixedString(&load.path, "scenes/level1.scene.etch");
    try roundTrip(messages.LoadScene, load);

    var saved = messages.ProjectSaved{ .ok = 1, .reason = std.mem.zeroes([128]u8) };
    messages.writeFixedString(&saved.reason, "");
    try roundTrip(messages.ProjectSaved, saved);

    var err = messages.RuntimeError{
        .severity = @intFromEnum(messages.ErrorSeverity.warning),
        .source = std.mem.zeroes([64]u8),
        .text = std.mem.zeroes([256]u8),
    };
    messages.writeFixedString(&err.source, "runtime");
    messages.writeFixedString(&err.text, "load_scene: empty path");
    try roundTrip(messages.RuntimeError, err);
}

// --------------------------------------------------- end-to-end fixtures --

extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn shm_unlink(name: [*:0]const u8) i32;
extern "c" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn nanosleep(req: *const timespec_t, rem: ?*timespec_t) c_int;
extern "c" fn getpid() i32;

const timeval = extern struct { tv_sec: i64, tv_usec: i32, _pad: i32 = 0 };
const SOL_SOCKET: c_int = if (builtin.os.tag == .linux) 1 else 0xFFFF;
const SO_RCVTIMEO: c_int = if (builtin.os.tag == .linux) 20 else 0x1006;

fn sleepMs(ms: u64) void {
    var ts = timespec_t{ .tv_sec = @intCast(ms / 1000), .tv_nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&ts, null);
}

/// The viewport + child process produced by `spawnRuntime`. The
/// `IpcServer` is **not** returned — it is caller-owned and stable, so
/// its internal `conn.socket` pointer (set by `acceptOne` to
/// `&server.client.?`) survives. `ShmViewport` / `Process` have no
/// self-references, so returning them by value is safe.
const Spawned = struct {
    vp: viewport.ShmViewport,
    proc: platform_process.Process,
};

/// Spawn `weld-runtime`, run the handshake, and hand off the viewport fd
/// (mirroring `src/editor/main.zig`), driving the caller-owned `server`.
/// The caller owns the `socket_path` / `shm_name` buffers and unlinks
/// them, and must call `teardown` + `server.deinit()`.
fn spawnRuntime(
    server: *ipc.server.IpcServer,
    gpa: std.mem.Allocator,
    socket_path: [:0]const u8,
    shm_name: [:0]const u8,
) !Spawned {
    var vp = try viewport.ShmViewport.create(shm_name, viewport.default_resolution.width, viewport.default_resolution.height);
    errdefer vp.close();

    try server.listen(socket_path);

    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    defer gpa.free(socket_arg);
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    defer gpa.free(shm_arg);
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{getpid()});
    defer gpa.free(pid_arg);
    const argv = [_][]const u8{ "zig-out/bin/weld-runtime", socket_arg, shm_arg, pid_arg };

    const proc = try platform_process.spawn_process(gpa, "zig-out/bin/weld-runtime", &argv);
    try server.acceptOne();

    // 5 s recv timeout on the accepted socket (engine-zig-conventions §13).
    var tv = timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = setsockopt(server.client.?.impl.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(timeval));

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    _ = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");

    // Viewport fd handoff (engine-ipc.md §4.8).
    var handoff = messages.ShmRegionsHandoff{ .region_count = 1, .regions = std.mem.zeroes([messages.MAX_SHM_REGIONS]messages.ShmRegionDesc) };
    messages.writeFixedString(&handoff.regions[0].logical_name, "viewport_framebuffer");
    handoff.regions[0].size = viewport.regionSize(viewport.default_resolution.width, viewport.default_resolution.height);
    try server.connection().sendMessageWithHandles(messages.ShmRegionsHandoff, 0, &handoff, &[_]transport.OsHandle{vp.fd()});

    return .{ .vp = vp, .proc = proc };
}

/// Graceful teardown: `Shutdown` → `ShutdownAck` → reap the runtime.
fn teardown(server: *ipc.server.IpcServer, proc: *platform_process.Process) void {
    const sd = messages.Shutdown{};
    server.connection().sendMessage(messages.Shutdown, 0, &sd) catch {};
    var sa_buf: [framing.frameSizeOf(messages.ShutdownAck)]u8 = undefined;
    _ = server.connection().recvMessage(messages.ShutdownAck, &sa_buf) catch {};
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (platform_process.wait_nonblock(proc) catch null) |_| break;
        sleepMs(10);
    }
}

test "SaveProject is acked by ProjectSaved with the same seq_id" {
    if (!is_posix) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const pid = getpid();
    var sock_buf: [64]u8 = undefined;
    var shm_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&sock_buf, "/tmp/weld-cat-save-{d}.sock", .{pid});
    const shm_name = try std.fmt.bufPrintZ(&shm_buf, "/weld-shm-cat-save-{d}", .{pid});
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm_name.ptr);
    defer _ = unlink(socket_path.ptr);
    defer _ = shm_unlink(shm_name.ptr);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    var sp = try spawnRuntime(&server, gpa, socket_path, shm_name);
    defer sp.vp.close();
    defer teardown(&server, &sp.proc);

    const seq: u32 = 4242;
    const save = messages.SaveProject{};
    try server.connection().sendMessage(messages.SaveProject, seq, &save);

    var buf: [framing.frameSizeOf(messages.ProjectSaved)]u8 = undefined;
    const frame = try server.connection().recvFrame(&buf);
    try std.testing.expectEqual(@as(u16, @intFromEnum(messages.MsgType.project_saved)), frame.header.msg_type);
    try std.testing.expectEqual(seq, frame.header.seq_id);
    const ack = try framing.decode(messages.ProjectSaved, frame.header, frame.payload_bytes);
    try std.testing.expectEqual(@as(u8, 1), ack.ok);
}

test "LoadScene with an empty path yields a RuntimeError event" {
    if (!is_posix) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const pid = getpid();
    var sock_buf: [64]u8 = undefined;
    var shm_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&sock_buf, "/tmp/weld-cat-load-{d}.sock", .{pid});
    const shm_name = try std.fmt.bufPrintZ(&shm_buf, "/weld-shm-cat-load-{d}", .{pid});
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm_name.ptr);
    defer _ = unlink(socket_path.ptr);
    defer _ = shm_unlink(shm_name.ptr);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    var sp = try spawnRuntime(&server, gpa, socket_path, shm_name);
    defer sp.vp.close();
    defer teardown(&server, &sp.proc);

    const load = messages.LoadScene{ .path = std.mem.zeroes([256]u8) }; // empty path
    try server.connection().sendMessage(messages.LoadScene, 0, &load);

    var buf: [framing.frameSizeOf(messages.RuntimeError)]u8 = undefined;
    const frame = try server.connection().recvFrame(&buf);
    try std.testing.expectEqual(@as(u16, @intFromEnum(messages.MsgType.runtime_error)), frame.header.msg_type);
    const re = try framing.decode(messages.RuntimeError, frame.header, frame.payload_bytes);
    try std.testing.expectEqual(@as(u32, @intFromEnum(messages.ErrorSeverity.warning)), re.severity);
    try std.testing.expectEqualStrings("runtime", messages.readFixedString(&re.source));
}

test "Play/Pause/Stop are accepted without desync" {
    if (!is_posix) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const pid = getpid();
    var sock_buf: [64]u8 = undefined;
    var shm_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&sock_buf, "/tmp/weld-cat-play-{d}.sock", .{pid});
    const shm_name = try std.fmt.bufPrintZ(&shm_buf, "/weld-shm-cat-play-{d}", .{pid});
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm_name.ptr);
    defer _ = unlink(socket_path.ptr);
    defer _ = shm_unlink(shm_name.ptr);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    var sp = try spawnRuntime(&server, gpa, socket_path, shm_name);
    defer sp.vp.close();
    defer teardown(&server, &sp.proc);

    // Fire-and-forget control messages — no ack expected.
    const pause = messages.Pause{};
    try server.connection().sendMessage(messages.Pause, 0, &pause);
    const play = messages.Play{};
    try server.connection().sendMessage(messages.Play, 0, &play);
    const stop = messages.Stop{};
    try server.connection().sendMessage(messages.Stop, 0, &stop);

    // An Echo after the control burst must still round-trip — proves the
    // runtime consumed the three frames without losing socket sync.
    var echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    for (&echo.payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    try server.connection().sendMessage(messages.Echo, 7, &echo);

    var buf: [framing.frameSizeOf(messages.EchoReply)]u8 = undefined;
    const reply = try server.connection().recvMessage(messages.EchoReply, &buf);
    try std.testing.expectEqualSlices(u8, &echo.payload, &reply.payload);
}
