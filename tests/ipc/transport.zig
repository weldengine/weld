//! S6 transport tests — exercises `IpcSocket.listen/connect/accept/
//! send/recv` on a real OS socket.
//!
//! Defense against the macOS hang the previous session diagnosed
//! (write 64 KB single-threaded on AF_UNIX SOCK_STREAM deadlocks
//! once the kernel send-buffer fills, since no reader drains it):
//!   - Large-payload tests spawn a reader thread that consumes bytes
//!     in parallel.
//!   - Every test installs a 5 s recv timeout on its server-side
//!     socket via the platform `SO_RCVTIMEO` socket option (POSIX).
//!     The timeout makes the test fail cleanly with
//!     `error.BrokenPipe` instead of hanging if the protocol misfires.
//!   - The listen socket and any unix socket file are unlinked on
//!     test scope exit (`defer`).
//!
//! Skipped on Windows: the named-pipe backend has different timeout
//! semantics (`PIPE_WAIT` vs `PIPE_NOWAIT` + `WaitNamedPipe`); the
//! Windows pathway lands in Phase 0.6 alongside the editor / runtime
//! Windows execution.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const transport = weld_core.ipc.transport;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn setsockopt(
    sockfd: c_int,
    level: c_int,
    optname: c_int,
    optval: *const anyopaque,
    optlen: u32,
) c_int;

extern "c" fn unlink(path: [*:0]const u8) c_int;

fn forceUnlink(path: [:0]const u8) void {
    _ = unlink(path.ptr);
}

const timeval = extern struct {
    tv_sec: i64,
    tv_usec: i32,
    _pad: i32 = 0,
};

const SOL_SOCKET: c_int = if (builtin.os.tag == .linux) 1 else 0xFFFF;
const SO_RCVTIMEO: c_int = if (builtin.os.tag == .linux) 20 else 0x1006;

/// Install a 5-second recv timeout on the underlying fd of an
/// `IpcSocket` (POSIX only). Catches the test-runner deadlock the
/// previous session burned 46 minutes on: any `recv()` that would
/// normally hang now fails with `EAGAIN`/`error.BrokenPipe` after 5 s.
fn installRecvTimeout(sock: *transport.IpcSocket) void {
    if (comptime !is_posix) return;
    const fd = sock.impl.fd;
    var tv = timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(timeval));
}

fn socketPath(comptime suffix: []const u8) [:0]const u8 {
    return "/tmp/weld-test-" ++ suffix ++ ".sock";
}

test "listen + connect + accept + small payload round-trip" {
    if (!is_posix) return error.SkipZigTest;

    const path = socketPath("xport-small");
    forceUnlink(path);
    defer forceUnlink(path);

    var listener = try transport.IpcSocket.listen(path);
    defer listener.close();

    var client = try transport.IpcSocket.connect(path);
    defer client.close();

    var server = try listener.accept();
    defer server.close();
    installRecvTimeout(&server);

    const payload = "hello-weld-ipc";
    try client.send(payload);

    var buf: [64]u8 = undefined;
    const n = try server.recv(&buf);
    try std.testing.expectEqual(payload.len, n);
    try std.testing.expectEqualSlices(u8, payload, buf[0..n]);
}

const PartialWriteCtx = struct {
    server: *transport.IpcSocket,
    expected_len: usize,
    received: usize = 0,
    last_err: ?anyerror = null,
};

fn drainOnce(ctx: *PartialWriteCtx) void {
    var buf: [4096]u8 = undefined;
    while (ctx.received < ctx.expected_len) {
        const n = ctx.server.recv(&buf) catch |e| {
            ctx.last_err = e;
            return;
        };
        if (n == 0) {
            ctx.last_err = error.UnexpectedEof;
            return;
        }
        for (buf[0..n]) |b| {
            if (b != 42) {
                ctx.last_err = error.UnexpectedByte;
                return;
            }
        }
        ctx.received += n;
    }
}

test "send loops over partial writes (64 KB, drained by reader thread)" {
    if (!is_posix) return error.SkipZigTest;

    const path = socketPath("xport-bigwrite");
    forceUnlink(path);
    defer forceUnlink(path);

    var listener = try transport.IpcSocket.listen(path);
    defer listener.close();

    var client = try transport.IpcSocket.connect(path);
    defer client.close();

    var server = try listener.accept();
    defer server.close();
    installRecvTimeout(&server);

    const big = [_]u8{42} ** 64_000;

    var ctx = PartialWriteCtx{ .server = &server, .expected_len = big.len };
    const reader = try std.Thread.spawn(.{}, drainOnce, .{&ctx});

    try client.send(&big);

    reader.join();
    if (ctx.last_err) |e| return e;
    try std.testing.expectEqual(big.len, ctx.received);
}

test "recv returns 0 on clean peer close (EOF)" {
    if (!is_posix) return error.SkipZigTest;

    const path = socketPath("xport-eof");
    forceUnlink(path);
    defer forceUnlink(path);

    var listener = try transport.IpcSocket.listen(path);
    defer listener.close();

    var client = try transport.IpcSocket.connect(path);
    var server = try listener.accept();
    defer server.close();
    installRecvTimeout(&server);

    client.close();

    var buf: [16]u8 = undefined;
    const n = try server.recv(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}
