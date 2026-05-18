//! S6 fd-passing test (G7) — verifies that the editor side can
//! transfer an opened file descriptor to the runtime side via
//! `IpcSocket.sendWithHandles` (SCM_RIGHTS ancillary data) and that
//! the runtime can write into the received fd, with the editor
//! observing the written bytes through its own end.
//!
//! On macOS the chosen fd is the read+write end of a pipe (`pipe(2)`),
//! since `memfd_create` is Linux-specific. The pipe is a clean
//! POSIX primitive supported on every Weld POSIX target, keeps the
//! test self-contained (no temp files), and exercises the same
//! cmsg path as `memfd_create`.
//!
//! Windows: `skipNow` per the S6 brief — Windows handle passing
//! (`DuplicateHandle`) lands in Phase 3 alongside the GPU shared
//! framebuffer (`engine-ipc.md` §4.7).

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const transport = weld_core.ipc.transport;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;

extern "c" fn setsockopt(
    sockfd: c_int,
    level: c_int,
    optname: c_int,
    optval: *const anyopaque,
    optlen: u32,
) c_int;

const timeval = extern struct {
    tv_sec: i64,
    tv_usec: i32,
    _pad: i32 = 0,
};

const SOL_SOCKET: c_int = if (builtin.os.tag == .linux) 1 else 0xFFFF;
const SO_RCVTIMEO: c_int = if (builtin.os.tag == .linux) 20 else 0x1006;

fn installRecvTimeout(sock: *transport.IpcSocket) void {
    if (comptime !is_posix) return;
    var tv = timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = setsockopt(sock.impl.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(timeval));
}

test "transmits an open fd via sendWithHandles and writes through it" {
    if (!is_posix) return error.SkipZigTest;

    const path: [:0]const u8 = "/tmp/weld-test-fdpass.sock";
    _ = unlink(path.ptr);
    defer _ = unlink(path.ptr);

    // Editor side: open a pipe whose write end will be transferred
    // to the runtime side, and whose read end stays local.
    var pipe_fds: [2]c_int = .{ -1, -1 };
    if (pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = close(pipe_fds[0]);
    // pipe_fds[1] is closed via the transfer + local close below.

    var listener = try transport.IpcSocket.listen(path);
    defer listener.close();
    var client = try transport.IpcSocket.connect(path);
    defer client.close();
    var server = try listener.accept();
    defer server.close();
    installRecvTimeout(&server);
    installRecvTimeout(&client);

    // Editor sends the pipe write fd to the runtime via SCM_RIGHTS.
    // SCM_RIGHTS requires a non-empty regular payload to ride along.
    try client.sendWithHandles(&[_]u8{42}, &[_]transport.OsHandle{pipe_fds[1]});
    // The editor's own copy is no longer needed; the runtime side
    // received its own duplicated fd referencing the same pipe.
    _ = close(pipe_fds[1]);

    var recv_buf: [16]u8 = undefined;
    var recv_handles: [1]transport.OsHandle = .{transport.invalid_handle};
    const result = try server.recvWithHandles(&recv_buf, &recv_handles);
    try std.testing.expectEqual(@as(usize, 1), result.bytes);
    try std.testing.expectEqual(@as(u8, 42), recv_buf[0]);
    try std.testing.expectEqual(@as(usize, 1), result.handles);
    try std.testing.expect(recv_handles[0] >= 0);
    defer _ = close(recv_handles[0]);

    // Runtime writes a known byte sequence into the received fd.
    const payload = "weld-fd-roundtrip";
    const wn = write(recv_handles[0], payload.ptr, payload.len);
    try std.testing.expectEqual(@as(isize, payload.len), wn);

    // Editor reads from its end of the pipe and asserts.
    var read_buf: [64]u8 = undefined;
    const rn = read(pipe_fds[0], &read_buf, read_buf.len);
    try std.testing.expectEqual(@as(isize, payload.len), rn);
    try std.testing.expectEqualSlices(u8, payload, read_buf[0..@intCast(rn)]);
}
