//! S6 crash-recovery test (G4 + G5). Exercises both directions of
//! the abrupt-termination contract.
//!
//! G4 — runtime kill -9 → editor detects + restarts:
//!   The test process plays the editor (creates shm, listens),
//!   spawns the runtime binary, handshakes, then `SIGKILL`s the
//!   runtime. Two tests : detect latency < 100 ms, restart succeeds
//!   + first post-restart Echo round-trips OK.
//!
//! G5 — editor kill -9 → runtime detects + exits clean:
//!   Test plays the editor again, spawns the runtime, handshakes,
//!   then **abruptly closes the server-side socket** via
//!   `IpcServer.deinit` without sending a `Shutdown` message. This
//!   is a faithful simulation of a real editor `kill -9`: in both
//!   cases the kernel tears the editor's socket down, and the
//!   runtime sees an EOF on its next `recv`. The runtime's reader
//!   thread sets `read_failed`, the main loop observes the flag,
//!   `defer`s run, the process exits with code 0. Asserts the runtime
//!   exits within < 500 ms of the close (16 ms main-loop tick + scope
//!   teardown) and that `exit_code == 0`.
//!
//! POSIX (Linux + macOS) since M0.7 / E1. The SCM_RIGHTS fd-passing
//! pivot (`engine-ipc.md` §4.8) removes the cross-process
//! `shm_open(O_RDWR)` that returned `EACCES` on macOS BSD shm, so the
//! runtime now attaches the viewport via `ShmRegion.fromFd` on the
//! editor-passed descriptor — no attacher-side `shm_open`. These G4/G5
//! tests therefore run on macOS dev too (the brief's "macOS G4/G5
//! green via SCM_RIGHTS"). The authoritative CI verdict is still
//! produced on Linux + Windows; macOS is not in the CI matrix.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const transport = ipc.transport;
const platform_process = weld_core.platform.process;
const viewport = ipc.viewport;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

/// Editor-side shm fd handoff, mirroring `src/editor/main.zig`: after
/// the handshake the runtime blocks on `ShmRegionsHandoff` (M0.7 / E1,
/// `engine-ipc.md` §4.8), so every test that drives the real runtime
/// binary must hand off the viewport fd or the runtime never reaches
/// its loops.
fn sendViewportHandoff(server: *ipc.server.IpcServer, vp: *const viewport.ShmViewport) !void {
    var handoff = messages.ShmRegionsHandoff{
        .region_count = 1,
        .regions = std.mem.zeroes([messages.MAX_SHM_REGIONS]messages.ShmRegionDesc),
    };
    messages.writeFixedString(&handoff.regions[0].logical_name, "viewport_framebuffer");
    handoff.regions[0].size = viewport.regionSize(
        viewport.default_resolution.width,
        viewport.default_resolution.height,
    );
    try server.connection().sendMessageWithHandles(
        messages.ShmRegionsHandoff,
        0,
        &handoff,
        &[_]transport.OsHandle{vp.fd()},
    );
}

extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn shm_unlink(name: [*:0]const u8) i32;
extern "c" fn clock_gettime(clk_id: i32, tp: *timespec_t) c_int;
extern "c" fn nanosleep(req: *const timespec_t, rem: ?*timespec_t) c_int;
extern "c" fn getpid() i32;
const CLOCK_MONOTONIC: i32 = if (builtin.os.tag == .linux) 1 else 6;
const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };

fn nowMs() i64 {
    var ts = timespec_t{ .tv_sec = 0, .tv_nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divFloor(ts.tv_nsec, std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts = timespec_t{
        .tv_sec = @intCast(ms / 1_000),
        .tv_nsec = @intCast((ms % 1_000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

test "runtime kill -9 → editor detects EOF in <100ms" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const pid = getpid();
    var sock_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&sock_buf, "/tmp/weld-crashtest-{d}.sock", .{pid});
    var shm_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintZ(&shm_buf, "/weld-shm-crashtest-{d}", .{pid});
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm_name.ptr);
    defer _ = unlink(socket_path.ptr);
    defer _ = shm_unlink(shm_name.ptr);

    var vp = try viewport.ShmViewport.create(shm_name, viewport.default_resolution.width, viewport.default_resolution.height);
    defer vp.close();

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(socket_path);

    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    defer gpa.free(socket_arg);
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    defer gpa.free(shm_arg);
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{pid});
    defer gpa.free(pid_arg);
    const argv = [_][]const u8{ "zig-out/bin/weld-runtime", socket_arg, shm_arg, pid_arg };

    var proc = try platform_process.spawn_process(gpa, "zig-out/bin/weld-runtime", &argv);
    try server.acceptOne();

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    _ = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");
    try sendViewportHandoff(&server, &vp);

    // Sleep a beat to let the runtime settle, then kill.
    sleepMs(50);
    const t0 = nowMs();
    try platform_process.kill(&proc);

    // Detect EOF on the editor side by sending a probe message and
    // expecting `error.UnexpectedEof` from the next `recvFrame`.
    var scratch: [256]u8 = undefined;
    const detect_res = server.connection().recvFrame(&scratch);
    const detect_ms = nowMs() - t0;
    try std.testing.expect(detect_ms < 100);
    try std.testing.expectError(error.UnexpectedEof, detect_res);

    // Reap.
    var reap_attempts: usize = 0;
    while (reap_attempts < 50) : (reap_attempts += 1) {
        if (try platform_process.wait_nonblock(&proc)) |_| break;
        sleepMs(10);
    }
}

test "runtime kill -9 → editor restarts + first post-restart Echo OK" {
    if (!is_posix) return error.SkipZigTest;
    // Smoke-shape: the runtime is restarted by repeating the
    // spawn_process call; we verify the new connection delivers an
    // EchoReply for an Echo we send.
    const gpa = std.testing.allocator;
    const pid = getpid();
    var sock_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&sock_buf, "/tmp/weld-restart-{d}.sock", .{pid});
    var shm_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintZ(&shm_buf, "/weld-shm-restart-{d}", .{pid});
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm_name.ptr);
    defer _ = unlink(socket_path.ptr);
    defer _ = shm_unlink(shm_name.ptr);

    var vp = try viewport.ShmViewport.create(shm_name, viewport.default_resolution.width, viewport.default_resolution.height);
    defer vp.close();

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(socket_path);

    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    defer gpa.free(socket_arg);
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    defer gpa.free(shm_arg);
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{pid});
    defer gpa.free(pid_arg);
    const argv = [_][]const u8{ "zig-out/bin/weld-runtime", socket_arg, shm_arg, pid_arg };

    // First spawn + handshake + kill.
    var proc = try platform_process.spawn_process(gpa, "zig-out/bin/weld-runtime", &argv);
    try server.acceptOne();
    var hbuf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    _ = try server.recvHello(&hbuf);
    try server.sendHelloAck(true, "");
    try sendViewportHandoff(&server, &vp);
    try platform_process.kill(&proc);
    var scratch: [256]u8 = undefined;
    _ = server.connection().recvFrame(&scratch) catch {};
    // Tear down the first connection so we can accept the second.
    server.deinit();
    var reap_attempts: usize = 0;
    while (reap_attempts < 50) : (reap_attempts += 1) {
        if (try platform_process.wait_nonblock(&proc)) |_| break;
        sleepMs(10);
    }

    // Second spawn + handshake + Echo round-trip.
    server = ipc.server.IpcServer.init(gpa);
    try server.listen(socket_path);
    var proc2 = try platform_process.spawn_process(gpa, "zig-out/bin/weld-runtime", &argv);
    try server.acceptOne();
    _ = try server.recvHello(&hbuf);
    try server.sendHelloAck(true, "");
    try sendViewportHandoff(&server, &vp);

    var echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    for (&echo.payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    try server.connection().sendMessage(messages.Echo, 0, &echo);
    var rep_buf: [framing.frameSizeOf(messages.EchoReply)]u8 = undefined;
    const reply = try server.connection().recvMessage(messages.EchoReply, &rep_buf);
    try std.testing.expectEqualSlices(u8, &echo.payload, &reply.payload);

    // Graceful shutdown of the second runtime.
    const sd = messages.Shutdown{};
    try server.connection().sendMessage(messages.Shutdown, 0, &sd);
    var sa_buf: [framing.frameSizeOf(messages.ShutdownAck)]u8 = undefined;
    _ = try server.connection().recvMessage(messages.ShutdownAck, &sa_buf);
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (try platform_process.wait_nonblock(&proc2)) |_| break;
        sleepMs(10);
    }
}

test "editor close → runtime detects EOF + exits clean code 0" {
    if (!is_posix) return error.SkipZigTest;

    // G5 — see file header. The test process IS the editor. We
    // create the shm, listen, accept the runtime, handshake, then
    // call `server.deinit()` without sending `Shutdown` — the
    // kernel tears the socket down exactly the way it would after
    // an editor SIGKILL. The runtime's reader thread sees EOF on
    // its next recv, the main loop trips `read_failed`, the
    // process exits with code 0.

    const gpa = std.testing.allocator;
    const pid = getpid();
    var sock_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&sock_buf, "/tmp/weld-g5-{d}.sock", .{pid});
    var shm_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintZ(&shm_buf, "/weld-shm-g5-{d}", .{pid});
    _ = unlink(socket_path.ptr);
    _ = shm_unlink(shm_name.ptr);
    defer _ = unlink(socket_path.ptr);
    defer _ = shm_unlink(shm_name.ptr);

    var vp = try viewport.ShmViewport.create(shm_name, viewport.default_resolution.width, viewport.default_resolution.height);
    defer vp.close();

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(socket_path);

    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    defer gpa.free(socket_arg);
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    defer gpa.free(shm_arg);
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{pid});
    defer gpa.free(pid_arg);
    const argv = [_][]const u8{ "zig-out/bin/weld-runtime", socket_arg, shm_arg, pid_arg };

    var proc = try platform_process.spawn_process(gpa, "zig-out/bin/weld-runtime", &argv);
    try server.acceptOne();

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    _ = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");
    try sendViewportHandoff(&server, &vp);

    // Let the runtime settle into its main render + reader loops.
    sleepMs(50);

    // Simulate editor SIGKILL: abrupt server-side teardown, no
    // `Shutdown` message. Kernel sends FIN to the runtime end;
    // runtime sees `recv == 0` → `error.UnexpectedEof`.
    const t0 = nowMs();
    server.deinit();

    // Poll for runtime exit. Target wall-clock < 500 ms (16 ms
    // main-loop tick × small handful of iterations + scope
    // teardown). The brief's < 100 ms gate is for the detection
    // itself; the wider 500 ms here covers the runtime's full
    // exit path.
    var exit_code: ?i32 = null;
    var poll: usize = 0;
    while (poll < 100) : (poll += 1) {
        if (try platform_process.wait_nonblock(&proc)) |code| {
            exit_code = code;
            break;
        }
        sleepMs(10);
    }
    const exit_ms = nowMs() - t0;

    try std.testing.expect(exit_code != null);
    try std.testing.expectEqual(@as(i32, 0), exit_code.?);
    try std.testing.expect(exit_ms < 500);
}
