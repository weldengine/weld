//! Framing layer for the Weld editor↔runtime IPC.
//!
//! Each frame on the wire is laid out as:
//!
//! ```
//! ┌─────────────────── 16-byte header (extern struct) ──────────────┐
//! │ magic: u32        │ version: u16 │ msg_type: u16 │ seq_id: u32  │
//! │ payload_len: u32  │                                              │
//! ├──────────────────── payload (payload_len bytes) ────────────────┤
//! │ schema_hash: u64 │ extern struct bytes                          │
//! └──────────────────────────────────────────────────────────────────┘
//! ```
//!
//! The receiver validates the magic + version + msg_type + payload_len
//! before reading any further; any violation maps to a fatal
//! connection reset (cf. `engine-ipc.md` §8.3). The `schema_hash` is
//! validated when the body is decoded into a known message type.
//!
//! The encoder allocates a single contiguous slice that the transport
//! can hand to `send`/`write` directly. The decoder splits parsing in
//! two phases — header first (validates length bounds before any
//! allocation) — so the caller can stream the payload into a sized
//! buffer.

const std = @import("std");

const protocol = @import("protocol.zig");
const messages = @import("messages.zig");

/// 16-byte framing header. Little-endian on the wire (Weld is
/// little-endian only — see `protocol.zig` comptime guard).
pub const Header = extern struct {
    /// `protocol.MAGIC` (`'W' 'E' 'L' 'D'`). Any other value is a
    /// fatal `error.InvalidMagic` and the connection must be reset.
    magic: u32,
    /// `protocol.WELD_IPC_PROTOCOL_VERSION`. Mismatch is fatal.
    version: u16,
    /// `messages.MsgType` discriminant. Unknown values are fatal.
    msg_type: u16,
    /// Sequence id — assigned by the sender, echoed by transactional
    /// acks (cf. `engine-ipc.md` §3.4). Pure metadata at the framing
    /// layer; the connection-level dispatcher correlates command and
    /// reply.
    seq_id: u32,
    /// Bytes following the header (= `@sizeOf(u64)` schema_hash +
    /// `@sizeOf(T)` extern struct bytes). Bounded by
    /// `protocol.MAX_PAYLOAD_LEN`.
    payload_len: u32,
};

comptime {
    if (@sizeOf(Header) != 16) {
        @compileError(std.fmt.comptimePrint(
            "Header must be exactly 16 bytes, got {d}",
            .{@sizeOf(Header)},
        ));
    }
}

/// Errors raised by the framing layer. Every variant maps to a fatal
/// connection reset per `engine-ipc.md` §8.3 — there is no recovery
/// at the framing layer.
pub const Error = error{
    /// Header's `magic` field did not equal `protocol.MAGIC`.
    InvalidMagic,
    /// Header's `version` did not equal
    /// `protocol.WELD_IPC_PROTOCOL_VERSION`.
    ProtocolVersionMismatch,
    /// Header's `msg_type` is outside the declared `MsgType` range.
    UnknownMsgType,
    /// Header's `payload_len` exceeds `protocol.MAX_PAYLOAD_LEN`.
    PayloadTooLarge,
    /// Header's `payload_len` does not match the size of the
    /// declared message type (schema_hash + extern struct bytes).
    PayloadSizeMismatch,
    /// Payload's leading `schema_hash` does not match the expected
    /// hash for the declared message type. Indicates build version
    /// drift between editor and runtime.
    SchemaHashMismatch,
    /// Caller-supplied buffer is shorter than the announced bytes.
    UnexpectedEof,
};

/// Size of the schema_hash that precedes the extern struct bytes.
pub const SCHEMA_HASH_SIZE: usize = @sizeOf(u64);

/// Encoded frame length for a given message type `T`.
pub fn frameSizeOf(comptime T: type) usize {
    return @sizeOf(Header) + SCHEMA_HASH_SIZE + @sizeOf(T);
}

/// Encodes a single message into a freshly allocated buffer. Caller
/// owns the returned slice.
pub fn encode(
    gpa: std.mem.Allocator,
    comptime T: type,
    seq_id: u32,
    msg: *const T,
) std.mem.Allocator.Error![]u8 {
    const total = frameSizeOf(T);
    const buf = try gpa.alloc(u8, total);
    errdefer gpa.free(buf);

    const payload_len: u32 = @intCast(SCHEMA_HASH_SIZE + @sizeOf(T));
    const header = Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = @intFromEnum(messages.msgTypeOf(T)),
        .seq_id = seq_id,
        .payload_len = payload_len,
    };
    @memcpy(buf[0..@sizeOf(Header)], std.mem.asBytes(&header));

    const schema_hash: u64 = messages.schemaHash(T);
    @memcpy(
        buf[@sizeOf(Header) .. @sizeOf(Header) + SCHEMA_HASH_SIZE],
        std.mem.asBytes(&schema_hash),
    );

    const struct_offset = @sizeOf(Header) + SCHEMA_HASH_SIZE;
    @memcpy(buf[struct_offset..], std.mem.asBytes(msg));

    return buf;
}

/// Parses and validates a header from the first 16 bytes of `bytes`.
/// Returns `error.UnexpectedEof` when the caller gave less than 16
/// bytes; otherwise validates `magic`/`version`/`msg_type`/`payload_len`
/// against the protocol invariants.
pub fn parseHeader(bytes: []const u8) Error!Header {
    if (bytes.len < @sizeOf(Header)) return error.UnexpectedEof;
    var h: Header = undefined;
    @memcpy(std.mem.asBytes(&h), bytes[0..@sizeOf(Header)]);
    try validate(h);
    return h;
}

/// Standalone validator (used by `parseHeader` and by the transport
/// layer when the header was read piecewise).
pub fn validate(h: Header) Error!void {
    if (h.magic != protocol.MAGIC) return error.InvalidMagic;
    if (h.version != protocol.WELD_IPC_PROTOCOL_VERSION) return error.ProtocolVersionMismatch;
    if (!messages.MsgType.isKnown(h.msg_type)) return error.UnknownMsgType;
    if (h.payload_len > protocol.MAX_PAYLOAD_LEN) return error.PayloadTooLarge;
}

/// Decodes a typed message from the payload bytes that follow the
/// header. The schema_hash mismatch maps to fatal — runtime and
/// editor must agree on the message layout.
pub fn decode(
    comptime T: type,
    h: Header,
    payload: []const u8,
) Error!T {
    if (h.msg_type != @intFromEnum(messages.msgTypeOf(T))) {
        return error.UnknownMsgType;
    }
    const expected_payload_len: u32 = @intCast(SCHEMA_HASH_SIZE + @sizeOf(T));
    if (h.payload_len != expected_payload_len) return error.PayloadSizeMismatch;
    if (payload.len < expected_payload_len) return error.UnexpectedEof;

    var schema_hash: u64 = undefined;
    @memcpy(std.mem.asBytes(&schema_hash), payload[0..SCHEMA_HASH_SIZE]);
    if (schema_hash != messages.schemaHash(T)) return error.SchemaHashMismatch;

    var msg: T = undefined;
    @memcpy(
        std.mem.asBytes(&msg),
        payload[SCHEMA_HASH_SIZE .. SCHEMA_HASH_SIZE + @sizeOf(T)],
    );
    return msg;
}

// ---------------------------------------------------------------- tests --

test "header layout is exactly 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Header));
}

test "encode then parseHeader round-trips for ProtocolHello" {
    const gpa = std.testing.allocator;
    var hello = messages.ProtocolHello{
        .protocol_version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .engine_version = std.mem.zeroes([32]u8),
        .build_hash = std.mem.zeroes([16]u8),
        .capabilities = 0,
    };
    messages.writeFixedString(&hello.engine_version, "0.0.6");
    messages.writeFixedString(&hello.build_hash, "deadbee");

    const buf = try encode(gpa, messages.ProtocolHello, 42, &hello);
    defer gpa.free(buf);

    const h = try parseHeader(buf);
    try std.testing.expectEqual(@as(u32, protocol.MAGIC), h.magic);
    try std.testing.expectEqual(@as(u16, protocol.WELD_IPC_PROTOCOL_VERSION), h.version);
    try std.testing.expectEqual(@as(u16, @intFromEnum(messages.MsgType.protocol_hello)), h.msg_type);
    try std.testing.expectEqual(@as(u32, 42), h.seq_id);
    try std.testing.expectEqual(@as(u32, SCHEMA_HASH_SIZE + @sizeOf(messages.ProtocolHello)), h.payload_len);

    const decoded = try decode(messages.ProtocolHello, h, buf[@sizeOf(Header)..]);
    try std.testing.expectEqualStrings("0.0.6", messages.readFixedString(&decoded.engine_version));
    try std.testing.expectEqualStrings("deadbee", messages.readFixedString(&decoded.build_hash));
}

test "parseHeader rejects invalid magic" {
    var buf: [16]u8 = undefined;
    const fake = Header{
        .magic = 0xDEADBEEF,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        .payload_len = 0,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.InvalidMagic, parseHeader(&buf));
}

test "parseHeader rejects mismatched protocol version" {
    var buf: [16]u8 = undefined;
    const fake = Header{
        .magic = protocol.MAGIC,
        .version = 99,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        .payload_len = 0,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.ProtocolVersionMismatch, parseHeader(&buf));
}

test "parseHeader rejects unknown msg_type" {
    var buf: [16]u8 = undefined;
    const fake = Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = 9999,
        .seq_id = 0,
        .payload_len = 0,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.UnknownMsgType, parseHeader(&buf));
}

test "parseHeader rejects oversized payload" {
    var buf: [16]u8 = undefined;
    const fake = Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        .payload_len = protocol.MAX_PAYLOAD_LEN + 1,
    };
    @memcpy(&buf, std.mem.asBytes(&fake));
    try std.testing.expectError(error.PayloadTooLarge, parseHeader(&buf));
}

test "parseHeader rejects truncated buffer" {
    const truncated = [_]u8{ 'W', 'E', 'L' };
    try std.testing.expectError(error.UnexpectedEof, parseHeader(&truncated));
}

test "decode catches schema_hash mismatch" {
    const gpa = std.testing.allocator;
    const echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    const buf = try encode(gpa, messages.Echo, 7, &echo);
    defer gpa.free(buf);

    // Corrupt the schema_hash bytes.
    buf[@sizeOf(Header)] ^= 0xFF;

    const h = try parseHeader(buf);
    try std.testing.expectError(
        error.SchemaHashMismatch,
        decode(messages.Echo, h, buf[@sizeOf(Header)..]),
    );
}

test "decode rejects payload_size mismatch" {
    const h = Header{
        .magic = protocol.MAGIC,
        .version = protocol.WELD_IPC_PROTOCOL_VERSION,
        .msg_type = @intFromEnum(messages.MsgType.echo),
        .seq_id = 0,
        // Pretend the payload is bigger than `Echo` actually is.
        .payload_len = SCHEMA_HASH_SIZE + @sizeOf(messages.Echo) + 1,
    };
    try validate(h);
    var dummy_payload: [256]u8 = undefined;
    try std.testing.expectError(
        error.PayloadSizeMismatch,
        decode(messages.Echo, h, &dummy_payload),
    );
}

test "decode rejects msg_type mismatch with the requested struct" {
    const gpa = std.testing.allocator;
    const echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    const buf = try encode(gpa, messages.Echo, 1, &echo);
    defer gpa.free(buf);

    const h = try parseHeader(buf);
    try std.testing.expectError(
        error.UnknownMsgType,
        decode(messages.SpawnEntity, h, buf[@sizeOf(Header)..]),
    );
}
