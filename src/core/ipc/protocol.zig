//! FROZEN — see engine-phase-0-criteria.md C0.5

const std = @import("std");
const builtin = @import("builtin");

/// `"WELD"` as a u32; the header carries it LITTLE-endian, so the bytes read `DLEW`.
pub const MAGIC: u32 = 0x57454C44;

/// Wire-protocol version.
/// There is NO negotiation: a mismatch is a fatal rejection, never a downgrade.
pub const WELD_IPC_PROTOCOL_VERSION: u16 = 3;

/// `payload_len` ceiling; beyond it the frame is refused and the connection reset.
pub const MAX_PAYLOAD_LEN: u32 = 16 * 1024 * 1024;

/// Heartbeat period (editor → runtime). Matches `engine-ipc.md` §6.1.
pub const HEARTBEAT_PERIOD_NS: u64 = 1 * std.time.ns_per_s;

/// No `HeartbeatAck` inside this window and the editor declares the runtime dead.
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
