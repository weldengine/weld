//! Each test closes its server and releases the runtime thread before joining
//! it, so a failure before the ack ends the thread's wait and is reported
//! instead of hanging the join.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const messages = ipc.messages;
const protocol = ipc.protocol;
const framing = ipc.framing;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn unlink(path: [*:0]const u8) c_int;

fn forceUnlink(path: [:0]const u8) void {
    if (comptime !is_posix) return;
    _ = unlink(path.ptr);
}

const RuntimeArgs = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    capabilities: u32,
    accepted_out: *u8,
    /// Set once the server listens: a `connect()` before that is refused.
    ready_flag: *std.atomic.Value(u8),
};

extern "c" fn nanosleep(req: *const timespec_t, rem: ?*timespec_t) c_int;
const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };

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
    client.sendHello("0.0.7-S6", "deadbee", args.capabilities) catch return;

    var scratch: [framing.frameSizeOf(messages.ProtocolHelloAck)]u8 = undefined;
    const ack = client.recvHelloAck(&scratch) catch return;
    args.accepted_out.* = ack.accepted;
}

test "full handshake completes" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const path: [:0]const u8 = "/tmp/weld-test-handshake-ok.sock";
    forceUnlink(path);
    defer forceUnlink(path);

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
    defer ready_flag.store(1, .release);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path);

    ready_flag.store(1, .release);

    try server.acceptOne();

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");

    try std.testing.expectEqual(@as(u16, protocol.WELD_IPC_PROTOCOL_VERSION), hello.protocol_version);
    try std.testing.expectEqualStrings("0.0.7-S6", messages.readFixedString(&hello.engine_version));
}

test "version mismatch produces explicit rejection" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const path: [:0]const u8 = "/tmp/weld-test-handshake-vermismatch.sock";
    forceUnlink(path);
    defer forceUnlink(path);

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
    defer ready_flag.store(1, .release);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path);

    ready_flag.store(1, .release);

    try server.acceptOne();

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    var hello = try server.recvHello(&hello_buf);
    hello.protocol_version +%= 7;
    if (ipc.server.IpcServer.validateHello(hello)) |_| {
        try std.testing.expect(false);
    } else |_| {
        try server.sendHelloAck(false, "protocol mismatch");
    }
}

test "GPU_SHARED_FB capability defaults to 0" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const path: [:0]const u8 = "/tmp/weld-test-handshake-cap.sock";
    forceUnlink(path);
    defer forceUnlink(path);

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
    defer ready_flag.store(1, .release);

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path);

    ready_flag.store(1, .release);

    try server.acceptOne();

    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    try server.sendHelloAck(true, "");

    try std.testing.expectEqual(@as(u32, 0), hello.capabilities);
    try std.testing.expect((hello.capabilities & messages.Capability.GPU_SHARED_FB) == 0);
}
