//! Protocol-level constants and invariants for the Weld editor↔runtime IPC.
//!
//! Wire format reference: `engine-ipc.md` §3.1 (framing) and §5
//! (handshake + versioning). The 32-bit `MAGIC` value spells the ASCII
//! sequence `'W'`, `'E'`, `'L'`, `'D'` in big-endian display order, but it is
//! transmitted byte-for-byte in little-endian on the wire (Weld is
//! little-endian only — see the `comptime` guard at the bottom of this
//! file).
//!
//! The `WELD_IPC_PROTOCOL_VERSION` integer is bumped on every breaking
//! protocol change. There is no negotiation — the editor and the runtime
//! are always shipped together; a mismatch is fatal and produces an
//! immediate `ProtocolHelloAck { accepted: false, reason: ... }` rejection.
//!
//! Endianness invariant: `engine-ipc.md` §3.2 mandates little-endian for
//! every primitive on the wire, and the brief's § Scope locks Weld to
//! little-endian targets for Phase −1 / 0 / 1 / 2. We assert this at
//! compile time so a hypothetical big-endian build fails loudly instead
//! of silently corrupting frames.

const std = @import("std");
const builtin = @import("builtin");

/// `"WELD"` interpreted as a 32-bit integer (`'W' << 24 | 'E' << 16 | 'L'
/// << 8 | 'D'`). Stored little-endian in every frame header.
pub const MAGIC: u32 = 0x57454C44;

/// Current protocol version. Bumped on any breaking change of the wire
/// format or message catalogue. Editor and runtime must agree exactly.
pub const WELD_IPC_PROTOCOL_VERSION: u16 = 1;

/// Maximum payload size in bytes (`payload_len` ceiling per
/// `engine-ipc.md` §3.1). Frames with `payload_len > MAX_PAYLOAD_LEN`
/// trigger `error.PayloadTooLarge` and reset the connection.
pub const MAX_PAYLOAD_LEN: u32 = 16 * 1024 * 1024;

/// Heartbeat period (editor → runtime). Matches `engine-ipc.md` §6.1.
pub const HEARTBEAT_PERIOD_NS: u64 = 1 * std.time.ns_per_s;

/// Heartbeat timeout — `engine-ipc.md` §6.1. Editor considers the runtime
/// crashed if no `HeartbeatAck` is received within this window.
pub const HEARTBEAT_TIMEOUT_NS: u64 = 3 * std.time.ns_per_s;

comptime {
    if (builtin.cpu.arch.endian() != .little) {
        @compileError("Weld IPC requires a little-endian target (see engine-ipc.md §3.2).");
    }
}

test "magic encodes WELD as ASCII bytes in little-endian" {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, MAGIC, .little);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'D', 'L', 'E', 'W' }, &bytes);
}

test "magic value is the literal 0x57454C44" {
    try std.testing.expectEqual(@as(u32, 0x57454C44), MAGIC);
}

test "protocol version is at least 1" {
    try std.testing.expect(WELD_IPC_PROTOCOL_VERSION >= 1);
}
