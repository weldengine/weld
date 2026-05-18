//! S6 handshake tests — full `ProtocolHello` ↔ `ProtocolHelloAck`
//! round-trip via `IpcServer` + `IpcClient`, exercised in-process
//! with a dedicated thread for the runtime side (the server's
//! `acceptOne` is blocking).
//!
//! Each test installs a 5 s socket recv timeout on the server side
//! so a misbehaving handshake fails the test instead of hanging the
//! runner. The Unix socket file is cleaned up on every scope exit
//! via `defer forceUnlink`.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const messages = ipc.messages;
const protocol = ipc.protocol;
const framing = ipc.framing;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

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

fn forceUnlink(path: [:0]const u8) void {
    if (comptime !is_posix) return;
    _ = unlink(path.ptr);
}

fn installRecvTimeout(socket: *ipc.transport.IpcSocket) void {
    if (comptime !is_posix) return;
    var tv = timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = setsockopt(socket.impl.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(timeval));
}

const RuntimeArgs = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    capabilities: u32,
    accepted_out: *u8,
    /// Flipped to 1 by the parent thread once `IpcServer.listen` has
    /// returned. The runtime spins on this with a 10 ms sleep so a
    /// rapid `connect()` does not race against an unarmed listener
    /// (POSIX returns ECONNREFUSED on macOS when the listener has
    /// not transitioned to LISTEN yet).
    ready_flag: *std.atomic.Value(u8),
};

extern "c" fn nanosleep(req: *const timespec_t, rem: ?*timespec_t) c_int;
extern "c" fn clock_gettime(clk_id: i32, tp: *timespec_t) c_int;
const CLOCK_MONOTONIC: i32 = if (builtin.os.tag == .linux) 1 else 6;
const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };

fn nowMs() i64 {
    var ts = timespec_t{ .tv_sec = 0, .tv_nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divFloor(ts.tv_nsec, std.time.ns_per_ms);
}
fn spinSleepMs(ms: u64) void {
    var ts = timespec_t{
        .tv_sec = @intCast(ms / 1_000),
        .tv_nsec = @intCast((ms % 1_000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

fn runtimeThread(args: *RuntimeArgs) void {
    while (args.ready_flag.load(.acquire) == 0) spinSleepMs(5);
    var client = ipc.client.IpcClient.init(args.gpa);
    defer client.deinit();
    client.connect(args.path) catch return;
    installRecvTimeout(&client.socket.?);
    client.sendHello("0.0.7-S6", "deadbee", args.capabilities) catch return;

    var scratch: [framing.frameSizeOf(messages.ProtocolHelloAck)]u8 = undefined;
    const ack = client.recvHelloAck(&scratch) catch return;
    args.accepted_out.* = ack.accepted;
}

test "full handshake completes within 100 ms" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const path: [:0]const u8 = "/tmp/weld-test-handshake-ok.sock";
    forceUnlink(path);
    defer forceUnlink(path);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path);

    var accepted_out: u8 = 0xFF;
    var ready_flag = std.atomic.Value(u8).init(0);
    var args = RuntimeArgs{
        .gpa = gpa,
        .path = path,
        .capabilities = 0,
        .accepted_out = &accepted_out,
        .ready_flag = &ready_flag,
    };
    const runtime = try std.Thread.spawn(.{}, runtimeThread, .{&args});
    defer runtime.join();

    // Drop the starter pistol after the listener is armed. Without
    // this the client thread can hit `connect()` before the server
    // installs its socket — `ECONNREFUSED` on macOS.
    ready_flag.store(1, .release);

    const t0 = nowMs();
    try server.acceptOne();
    installRecvTimeout(&server.client.?);

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");
    const elapsed_ms = nowMs() - t0;

    try std.testing.expectEqual(@as(u16, protocol.WELD_IPC_PROTOCOL_VERSION), hello.protocol_version);
    try std.testing.expectEqualStrings("0.0.7-S6", messages.readFixedString(&hello.engine_version));
    try std.testing.expect(elapsed_ms < 100);
}

test "version mismatch produces explicit rejection" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const path: [:0]const u8 = "/tmp/weld-test-handshake-vermismatch.sock";
    forceUnlink(path);
    defer forceUnlink(path);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path);

    var accepted_out: u8 = 0xFF;
    var ready_flag = std.atomic.Value(u8).init(0);
    var args = RuntimeArgs{
        .gpa = gpa,
        .path = path,
        .capabilities = 0,
        .accepted_out = &accepted_out,
        .ready_flag = &ready_flag,
    };
    const runtime = try std.Thread.spawn(.{}, runtimeThread, .{&args});
    defer runtime.join();

    ready_flag.store(1, .release);

    try server.acceptOne();
    installRecvTimeout(&server.client.?);

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    var hello = try server.recvHello(&hello_buf);
    // Simulate a mismatch by overwriting the runtime-supplied
    // protocol version with a bogus future value. In a real
    // scenario the field would carry the bogus value on its own.
    hello.protocol_version +%= 7;
    if (ipc.server.IpcServer.validateHello(hello)) |_| {
        try std.testing.expect(false); // unreachable — validateHello should have failed
    } else |_| {
        try server.sendHelloAck(false, "protocol mismatch");
    }
}

test "GPU_SHARED_FB capability defaults to 0 in S6" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const path: [:0]const u8 = "/tmp/weld-test-handshake-cap.sock";
    forceUnlink(path);
    defer forceUnlink(path);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path);

    var accepted_out: u8 = 0xFF;
    var ready_flag = std.atomic.Value(u8).init(0);
    var args = RuntimeArgs{
        .gpa = gpa,
        .path = path,
        .capabilities = 0,
        .accepted_out = &accepted_out,
        .ready_flag = &ready_flag,
    };
    const runtime = try std.Thread.spawn(.{}, runtimeThread, .{&args});
    defer runtime.join();

    ready_flag.store(1, .release);

    try server.acceptOne();
    installRecvTimeout(&server.client.?);

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");

    try std.testing.expectEqual(@as(u32, 0), hello.capabilities);
    try std.testing.expect((hello.capabilities & messages.Capability.GPU_SHARED_FB) == 0);
}
