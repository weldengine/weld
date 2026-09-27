//! Writing 64 KB on one thread deadlocks once the kernel send buffer fills, so a
//! large payload is drained by a reader thread. POSIX only: the tests address
//! unix socket files.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const transport = weld_core.ipc.transport;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn unlink(path: [*:0]const u8) c_int;

fn forceUnlink(path: [:0]const u8) void {
    _ = unlink(path.ptr);
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

    client.close();

    var buf: [16]u8 = undefined;
    const n = try server.recv(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}
