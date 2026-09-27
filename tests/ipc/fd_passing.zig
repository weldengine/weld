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

test "transmits an open fd via sendWithHandles and writes through it" {
    if (!is_posix) return error.SkipZigTest;

    const path: [:0]const u8 = "/tmp/weld-test-fdpass.sock";
    _ = unlink(path.ptr);
    defer _ = unlink(path.ptr);

    var pipe_fds: [2]c_int = .{ -1, -1 };
    if (pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = close(pipe_fds[0]);

    var listener = try transport.IpcSocket.listen(path);
    defer listener.close();
    var client = try transport.IpcSocket.connect(path);
    defer client.close();
    var server = try listener.accept();
    defer server.close();

    // SCM_RIGHTS needs a non-empty regular payload beside the fd.
    try client.sendWithHandles(&[_]u8{42}, &[_]transport.OsHandle{pipe_fds[1]});
    // The receiving end holds its own duplicate of this fd.
    _ = close(pipe_fds[1]);

    var recv_buf: [16]u8 = undefined;
    var recv_handles: [1]transport.OsHandle = .{transport.invalid_handle};
    const result = try server.recvWithHandles(&recv_buf, &recv_handles);
    try std.testing.expectEqual(@as(usize, 1), result.bytes);
    try std.testing.expectEqual(@as(u8, 42), recv_buf[0]);
    try std.testing.expectEqual(@as(usize, 1), result.handles);
    try std.testing.expect(recv_handles[0] >= 0);
    defer _ = close(recv_handles[0]);

    const payload = "weld-fd-roundtrip";
    const wn = write(recv_handles[0], payload.ptr, payload.len);
    try std.testing.expectEqual(@as(isize, payload.len), wn);

    var read_buf: [64]u8 = undefined;
    const rn = read(pipe_fds[0], &read_buf, read_buf.len);
    try std.testing.expectEqual(@as(isize, payload.len), rn);
    try std.testing.expectEqualSlices(u8, payload, read_buf[0..@intCast(rn)]);
}
