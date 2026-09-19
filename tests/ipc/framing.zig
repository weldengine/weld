//! Framing: the six failure modes and the happy path. Pure logic — no
//! syscalls, no threads, no shm — so every test runs in the same process and
//! the runner's own isolation suffices, with no external resource to clean up.

const std = @import("std");
const weld_core = @import("weld_core");

const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const protocol = ipc.protocol;

test "round-trips a framed message" {
    const gpa = std.testing.allocator;

    var echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    for (&echo.payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    const buf = try framing.encode(gpa, messages.Echo, 123, &echo);
    defer gpa.free(buf);

    const h = try framing.parseHeader(buf);
    try std.testing.expectEqual(@as(u32, protocol.MAGIC), h.magic);
    try std.testing.expectEqual(@as(u16, protocol.WELD_IPC_PROTOCOL_VERSION), h.version);
    try std.testing.expectEqual(@as(u32, 123), h.seq_id);

    const decoded = try framing.decode(messages.Echo, h, buf[@sizeOf(framing.Header)..]);
    try std.testing.expectEqualSlices(u8, &echo.payload, &decoded.payload);
}

test "rejects invalid magic" {
    var buf: [16]u8 = undefined;
    const fake = framing.Header{
        .magic = 0xAAAAAAAA,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        .payload_len = 0,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.InvalidMagic, framing.parseHeader(&buf));
}

test "rejects mismatched protocol version" {
    var buf: [16]u8 = undefined;
    const fake = framing.Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION + 1,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        .payload_len = 0,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.ProtocolVersionMismatch, framing.parseHeader(&buf));
}

test "rejects unknown msg_type" {
    var buf: [16]u8 = undefined;
    const fake = framing.Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = 4242,
        .seq_id = 0,
        .payload_len = 0,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.UnknownMsgType, framing.parseHeader(&buf));
}

test "rejects oversized payload" {
    var buf: [16]u8 = undefined;
    const fake = framing.Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        .payload_len = protocol.MAX_PAYLOAD_LEN + 1,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.PayloadTooLarge, framing.parseHeader(&buf));
}

test "rejects truncated payload" {
    const half_header = [_]u8{ 'W', 'E', 'L', 'D', 1, 0, 3, 0 };
    try std.testing.expectError(error.UnexpectedEof, framing.parseHeader(&half_header));
}
