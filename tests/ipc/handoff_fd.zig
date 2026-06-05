//! M0.7 / E1 — shm attach via a received fd (`ShmRegion.fromFd`).
//!
//! Exercises the SCM_RIGHTS primary-attach pivot (`engine-ipc.md`
//! §4.8) at the `ShmRegion` level, one rung above the raw-socket fd
//! loopback of `tests/ipc/fd_passing.zig` (the S6 G7 test):
//!
//!   1. Side A (editor) creates a region with `ShmRegion.create` and
//!      keeps its fd via `ShmRegion.fd()`.
//!   2. A sends the fd to side B over an `AF_UNIX` socket via
//!      `sendWithHandles` (the bytes payload stands in for the
//!      `ShmRegionsHandoff` descriptor; the fd rides as ancillary
//!      data).
//!   3. Side B (runtime) maps the received fd with `ShmRegion.fromFd`
//!      — **no `shm_open`** — and writes a known pattern.
//!   4. Side A reads the same pattern back: both ends share the same
//!      physical pages.
//!
//! Because `fromFd` never calls `shm_open(O_RDWR)`, this runs
//! intra-process even on macOS — the whole point of the pivot is that
//! it sidesteps the BSD shm cross-process `EACCES` quirk that forces
//! the `tests/ipc/shm_cases/*` split. Green on Linux + macOS.
//!
//! Windows: `error.SkipZigTest` — the Windows CPU shm attach stays by
//! name (`open`), the fd-passing pivot is POSIX-only (§4.8). The
//! `ShmRegion.fromFd` Windows path is asserted to return
//! `error.Unimplemented` instead.
//!
//! External-resource discipline (engine-zig-conventions.md §13): a
//! 5 s `SO_RCVTIMEO` is installed on both endpoints so a lost cmsg
//! cannot hang the suite.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const shm = weld_core.ipc.shm;
const transport = weld_core.ipc.transport;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn close(fd: c_int) c_int;
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

test "shm attach via received fd" {
    if (!is_posix) return error.SkipZigTest;

    const region_size: usize = 4096;
    const region_name: []const u8 = "/weld-test-handoff";

    const sock_path: [:0]const u8 = "/tmp/weld-test-handoff.sock";
    _ = unlink(sock_path.ptr);
    defer _ = unlink(sock_path.ptr);

    // ---- Side A (editor): create the region, keep the fd. ----
    var region_a = try shm.ShmRegion.create(region_name, region_size);
    defer region_a.close();

    // Editor zeroes the region as it would before any handoff.
    @memset(region_a.bytes(), 0);

    var listener = try transport.IpcSocket.listen(sock_path);
    defer listener.close();
    var client = try transport.IpcSocket.connect(sock_path);
    defer client.close();
    var server = try listener.accept();
    defer server.close();
    installRecvTimeout(&server);
    installRecvTimeout(&client);

    // ---- Handoff: editor → runtime, fd in ancillary data. ----
    // The 1-byte payload stands in for the ShmRegionsHandoff frame;
    // SCM_RIGHTS requires at least one regular byte alongside the fd.
    try client.sendWithHandles(&[_]u8{1}, &[_]transport.OsHandle{region_a.fd()});

    var recv_buf: [16]u8 = undefined;
    var recv_handles: [1]transport.OsHandle = .{transport.invalid_handle};
    const result = try server.recvWithHandles(&recv_buf, &recv_handles);
    try std.testing.expectEqual(@as(usize, 1), result.bytes);
    try std.testing.expectEqual(@as(usize, 1), result.handles);
    try std.testing.expect(recv_handles[0] >= 0);

    // ---- Side B (runtime): map the received fd, NO shm_open. ----
    var region_b = try shm.ShmRegion.fromFd(recv_handles[0], region_size);
    defer region_b.close();

    // Runtime writes a known pattern into its mapping.
    const pattern = "weld-shm-handoff-roundtrip";
    @memcpy(region_b.bytes()[0..pattern.len], pattern);

    // ---- Side A reads the same physical pages back. ----
    try std.testing.expectEqualSlices(
        u8,
        pattern,
        region_a.bytes()[0..pattern.len],
    );

    // A trailing byte the runtime did not touch stays zero — proves we
    // mapped the same region, not a private copy.
    try std.testing.expectEqual(@as(u8, 0), region_a.bytes()[pattern.len]);
}

test "fromFd is unimplemented on Windows (attach stays by name)" {
    if (is_posix) return error.SkipZigTest;
    // The Windows CPU shm attach is by name (`open`); the fd-passing
    // pivot is POSIX-only (§4.8). `fromFd` must fail loudly.
    try std.testing.expectError(
        error.Unimplemented,
        shm.ShmRegion.fromFd(transport.invalid_handle, 4096),
    );
}
