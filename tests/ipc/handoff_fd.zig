//! `ShmRegion.fromFd` calls no `shm_open`, so these tests run in one process on
//! macOS too, unlike `tests/ipc/shm_cases/`.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const shm = weld_core.ipc.shm;
const transport = weld_core.ipc.transport;
const connection = weld_core.ipc.connection;
const messages = weld_core.ipc.messages;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int) c_int;

/// `F_GETFD` — same value (1) on Linux and macOS. `fcntl(fd, F_GETFD)`
/// returns -1 (EBADF) for a closed fd, ≥ 0 for an open one.
const F_GETFD: c_int = 1;

/// True if `fd` is still an open descriptor in this process.
fn fdOpen(fd: transport.OsHandle) bool {
    return fcntl(fd, F_GETFD) != -1;
}

test "shm attach via received fd" {
    if (!is_posix) return error.SkipZigTest;

    const region_size: usize = 4096;
    const region_name: []const u8 = "/weld-test-handoff";

    const sock_path: [:0]const u8 = "/tmp/weld-test-handoff.sock";
    _ = unlink(sock_path.ptr);
    defer _ = unlink(sock_path.ptr);

    var region_a = try shm.ShmRegion.create(region_name, region_size);
    defer region_a.close();

    @memset(region_a.bytes(), 0);

    var listener = try transport.IpcSocket.listen(sock_path);
    defer listener.close();
    var client = try transport.IpcSocket.connect(sock_path);
    defer client.close();
    var server = try listener.accept();
    defer server.close();

    // The 1-byte payload stands in for the ShmRegionsHandoff frame;
    // SCM_RIGHTS requires at least one regular byte alongside the fd.
    try client.sendWithHandles(&[_]u8{1}, &[_]transport.OsHandle{region_a.fd()});

    var recv_buf: [16]u8 = undefined;
    var recv_handles: [1]transport.OsHandle = .{transport.invalid_handle};
    const result = try server.recvWithHandles(&recv_buf, &recv_handles);
    try std.testing.expectEqual(@as(usize, 1), result.bytes);
    try std.testing.expectEqual(@as(usize, 1), result.handles);
    try std.testing.expect(recv_handles[0] >= 0);

    var region_b = try shm.ShmRegion.fromFd(recv_handles[0], region_size);
    defer region_b.close();

    const pattern = "weld-shm-handoff-roundtrip";
    @memcpy(region_b.bytes()[0..pattern.len], pattern);

    try std.testing.expectEqualSlices(
        u8,
        pattern,
        region_a.bytes()[0..pattern.len],
    );

    try std.testing.expectEqual(@as(u8, 0), region_a.bytes()[pattern.len]);
}

test "fromFd is unimplemented on Windows (attach stays by name)" {
    if (is_posix) return error.SkipZigTest;
    try std.testing.expectError(
        error.Unimplemented,
        shm.ShmRegion.fromFd(transport.invalid_handle, 4096),
    );
}

fn zeroRegions() [messages.MAX_SHM_REGIONS]messages.ShmRegionDesc {
    return std.mem.zeroes([messages.MAX_SHM_REGIONS]messages.ShmRegionDesc);
}

test "acceptShmHandoff rejects fd/region_count mismatch and closes every fd" {
    if (!is_posix) return error.SkipZigTest;

    const fd0 = dup(2);
    const fd1 = dup(2);
    try std.testing.expect(fd0 >= 0 and fd1 >= 0);

    const handoff = messages.ShmRegionsHandoff{ .region_count = 1, .regions = zeroRegions() };
    const handles = [_]transport.OsHandle{ fd0, fd1 };
    try std.testing.expectError(
        error.InvalidHandoff,
        connection.acceptShmHandoff(&handoff, &handles),
    );

    try std.testing.expect(!fdOpen(fd0));
    try std.testing.expect(!fdOpen(fd1));
}

test "acceptShmHandoff rejects region_count above MAX_SHM_REGIONS" {
    if (!is_posix) return error.SkipZigTest;

    const fd0 = dup(2);
    try std.testing.expect(fd0 >= 0);

    const handoff = messages.ShmRegionsHandoff{
        .region_count = @as(u32, @intCast(messages.MAX_SHM_REGIONS)) + 1,
        .regions = zeroRegions(),
    };
    const handles = [_]transport.OsHandle{fd0};
    try std.testing.expectError(
        error.InvalidHandoff,
        connection.acceptShmHandoff(&handoff, &handles),
    );
    try std.testing.expect(!fdOpen(fd0));
}

test "acceptShmHandoff returns the viewport fd and closes unmapped region fds" {
    if (!is_posix) return error.SkipZigTest;

    const fd0 = dup(2);
    const fd1 = dup(2);
    try std.testing.expect(fd0 >= 0 and fd1 >= 0);

    const handoff = messages.ShmRegionsHandoff{ .region_count = 2, .regions = zeroRegions() };
    const handles = [_]transport.OsHandle{ fd0, fd1 };
    const viewport_fd = try connection.acceptShmHandoff(&handoff, &handles);

    try std.testing.expectEqual(fd0, viewport_fd);
    try std.testing.expect(fdOpen(fd0));
    try std.testing.expect(!fdOpen(fd1));
    _ = close(fd0); // the caller owns the returned fd
}
