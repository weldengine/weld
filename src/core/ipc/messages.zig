//! Catalogue of the IPC messages, defined as `extern struct` POD per
//! `engine-ipc.md` §3.2 + brief § Scope. Every payload is written/read
//! byte-for-byte across the socket, preceded by an 8-byte
//! `schema_hash` that detects build-version drift between the editor
//! and the runtime.
//!
//! S6 shipped 13 message types; M0.7 / E1 adds `ShmRegionsHandoff`
//! (the POSIX fd handoff, §3.3 + §4.8). M0.7 / E2 extends the
//! catalogue further (`Play`/`Pause`/`Stop`, `LoadScene`,
//! `HotReloadScript`, `SaveScene`, `SaveProject`/`ProjectSaved`,
//! `RuntimeError`). The `WELD_IPC_PROTOCOL_VERSION` 2→3 bump covers
//! the whole M0.7 catalogue + attach-semantics change.
//!
//! The S6 brief acknowledges a triple count inconsistency in its own
//! text — the catalogue is described as "exactly 11 message types",
//! the tabular body lists 13 entries, and a closing footnote claims
//! 12. The implementation follows the table (the explicit list) which
//! is the exhaustive enumeration; the discrepancy is logged in the
//! brief's execution journal as a textual observation, not as a
//! design deviation.
//!
//! S6 keeps the message structs deliberately minimal — the runtime
//! stub increments a counter on `SpawnEntity` rather than wiring the
//! real ECS, and `ModifyComponent` is exercised only as a non-trivial
//! payload shape. The same `extern struct` layouts will survive into
//! Phase 0.6 where the real semantics land (cf. brief § Out-of-scope).
//!
//! NUL-terminated fixed-size byte buffers represent the few "string"
//! fields (`engine_version`, `build_hash`, `reason`, `text`). The
//! buffer length is part of the wire schema — a longer string is
//! truncated at write time; a shorter string is followed by zero
//! bytes that the receiver stops at the first NUL.

const std = @import("std");
const rtti = @import("../rtti/root.zig");

/// Message-type discriminator written in the framing header
/// (`framing.zig` `Header.msg_type: u16`). Discriminant values are
/// stable for a given `WELD_IPC_PROTOCOL_VERSION`; reordering or
/// renumbering is a breaking change that bumps the protocol version.
pub const MsgType = enum(u16) {
    /// Runtime → Editor — handshake (first message after connect).
    protocol_hello = 1,
    /// Editor → Runtime — handshake response.
    protocol_hello_ack = 2,
    /// Editor → Runtime — transactional, 64-byte random payload used
    /// to measure round-trip latency (G1/G2 of the brief).
    echo = 3,
    /// Runtime → Editor — echoes the seq_id and payload of the Echo.
    echo_reply = 4,
    /// Editor → Runtime — transactional, requests entity creation
    /// (S6 stub: increments a counter).
    spawn_entity = 5,
    /// Runtime → Editor — confirms `SpawnEntity` with a synthetic
    /// `entity` id.
    entity_created = 6,
    /// Editor → Runtime — transactional non-trivial payload exercise.
    modify_component = 7,
    /// Runtime → Editor — confirms `ModifyComponent`.
    modify_ack = 8,
    /// Editor → Runtime — periodic liveness probe.
    heartbeat = 9,
    /// Runtime → Editor — heartbeat reply with reception timestamp.
    heartbeat_ack = 10,
    /// Editor → Runtime — requests graceful termination.
    shutdown = 11,
    /// Runtime → Editor — confirms shutdown before exit.
    shutdown_ack = 12,
    /// Runtime → Editor — unidirectional log event (no ack).
    log_message = 13,
    /// Editor → Runtime — POSIX shm fd handoff (M0.7 / E1,
    /// `engine-ipc.md` §3.3 + §4.8). Sent right after the handshake
    /// via `sendWithHandles`; the fds ride as ancillary data.
    shm_regions_handoff = 14,

    /// Returns true when the raw `u16` from a frame header maps to a
    /// declared variant. Used by `framing.validate` to fail fast on
    /// unknown discriminants.
    pub fn isKnown(raw: u16) bool {
        return switch (raw) {
            1...14 => true,
            else => false,
        };
    }
};

/// Bit positions for `ProtocolHello.capabilities` per `engine-ipc.md`
/// §5.1. The brief locks `GPU_SHARED_FB` at bit 0 and the runtime
/// stub publishes the capability bitfield at zero in S6 — stabilising
/// the schema_hash of `ProtocolHello` for the Phase 3 introduction of
/// shared GPU framebuffers.
pub const Capability = struct {
    pub const GPU_SHARED_FB: u32 = 1 << 0;
};

/// Log severity transported by `LogMessage.level`. Numeric values are
/// stable across the protocol version.
pub const LogLevel = enum(u32) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
};

/// Runtime → Editor. First message of the handshake (cf.
/// `engine-ipc.md` §5.1). The editor replies with `ProtocolHelloAck`
/// to accept or reject.
pub const ProtocolHello = extern struct {
    /// Equal to `protocol.WELD_IPC_PROTOCOL_VERSION` at the runtime's
    /// build time.
    protocol_version: u16,
    /// Pads `protocol_version` up to the natural 4-byte alignment of
    /// the next field; always zero on the wire.
    _pad0: u16 = 0,
    /// NUL-terminated engine version string (e.g. `"0.0.6"`). Stable
    /// width keeps the struct extern-friendly.
    engine_version: [32]u8,
    /// NUL-terminated short git SHA of the runtime build.
    build_hash: [16]u8,
    /// Capability bitfield (cf. `Capability`). S6 publishes 0.
    capabilities: u32,
};

/// Editor → Runtime. Handshake response. `accepted == 1` ⇒
/// connection becomes ready; `accepted == 0` ⇒ runtime logs `reason`
/// and exits.
pub const ProtocolHelloAck = extern struct {
    /// 1 = accepted, 0 = rejected. Stored as `u8` because `bool` is
    /// not legal in `extern struct` in Zig 0.16.
    accepted: u8,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    /// NUL-terminated rejection reason. Empty when `accepted == 1`.
    reason: [128]u8,
};

/// Editor → Runtime. Transactional. The runtime replies with
/// `EchoReply` carrying the same `seq_id` and payload. The 64-byte
/// payload exists to make the RTT bench (G1/G2) measure a
/// non-trivial frame body.
pub const Echo = extern struct {
    payload: [64]u8,
};

/// Runtime → Editor. Echoes the seq_id of the originating `Echo`
/// (the seq_id is carried in the frame header, not in the body) and
/// the 64-byte payload byte-for-byte.
pub const EchoReply = extern struct {
    payload: [64]u8,
};

/// Editor → Runtime. Transactional. S6 stub: the runtime increments
/// a counter and replies with `EntityCreated`. The `archetype_hint`
/// field is informational only — kept so the struct is a non-zero-
/// sized extern struct and so Phase 0.6 can wire a real archetype
/// lookup without changing the schema_hash if the field is reused.
pub const SpawnEntity = extern struct {
    archetype_hint: u32 = 0,
};

/// Runtime → Editor. Reply to `SpawnEntity`. The `entity` field is a
/// synthetic counter in S6; Phase 0.6 will widen it to a generational
/// `EntityId` from `weld_core.ecs`.
pub const EntityCreated = extern struct {
    entity: u64,
};

/// Editor → Runtime. Transactional. Non-trivial payload exercise —
/// 56 bytes of mixed primitives + a fixed-width opaque value blob.
/// S6 runtime echoes back via `ModifyAck` with `success = 1`.
pub const ModifyComponent = extern struct {
    entity: u64,
    component_type: u32,
    field_offset: u32,
    new_value: [40]u8,
};

/// Runtime → Editor. Reply to `ModifyComponent`. The seq_id of the
/// originating command is carried in the frame header. `success` is
/// 1 in S6 (the runtime never rejects in stub mode).
pub const ModifyAck = extern struct {
    success: u8,
    _pad0: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
};

/// Editor → Runtime. Periodic liveness probe — emitted every
/// `HEARTBEAT_PERIOD_NS` (1 s). The runtime replies immediately with
/// `HeartbeatAck`.
pub const Heartbeat = extern struct {
    sent_at_us: u64,
};

/// Runtime → Editor. Echoes the `Heartbeat.sent_at_us` and stamps
/// the local reception time in microseconds.
pub const HeartbeatAck = extern struct {
    sent_at_us: u64,
    received_at_us: u64,
};

/// Editor → Runtime. Requests a graceful termination. The runtime
/// must reply with `ShutdownAck` before exiting (otherwise the
/// editor reports a timeout).
pub const Shutdown = extern struct {
    _reserved: u8 = 0,
};

/// Runtime → Editor. Final message before clean exit.
pub const ShutdownAck = extern struct {
    _reserved: u8 = 0,
};

/// Runtime → Editor. Fire-and-forget event. Covers `LogMessage`,
/// the only unidirectional event in S6 (no ack expected).
pub const LogMessage = extern struct {
    level: u32,
    _pad0: u32 = 0,
    timestamp_us: u64,
    /// NUL-terminated UTF-8 text. Longer messages are truncated at
    /// the sender.
    text: [256]u8,
};

/// NUL-terminated capacity for a `ShmRegionDesc.logical_name`.
/// `"viewport_framebuffer"` (20 bytes) is the longest name M0.7 hands
/// off; 32 leaves headroom for the §4.1 names (`debug_overlays`,
/// `profiler_samples`, `selection_snapshot`, `log_stream`).
pub const SHM_LOGICAL_NAME_LEN: usize = 32;

/// Maximum shm regions carried by one `ShmRegionsHandoff`. M0.7 hands
/// off only `viewport_framebuffer`; the §4.1 catalogue tops out at 5
/// regions. 8 is comfortable headroom and keeps the frame small
/// (`8 × 40 + 8 = 328` payload bytes).
pub const MAX_SHM_REGIONS: usize = 8;

/// One shm-region descriptor inside a `ShmRegionsHandoff`
/// (`engine-ipc.md` §3.3). The fd travels out-of-band via
/// `SCM_RIGHTS`; this struct carries only the logical name and size so
/// the runtime can pair each received fd with its role and `mmap` the
/// right length via `ShmRegion.fromFd`.
pub const ShmRegionDesc = extern struct {
    /// NUL-terminated logical role, e.g. `"viewport_framebuffer"`.
    logical_name: [SHM_LOGICAL_NAME_LEN]u8,
    /// Region size in bytes — the `mmap` length on the runtime side.
    size: u64,
};

/// Editor → Runtime, POSIX (M0.7 / E1). Hands the runtime the file
/// descriptors of the shm regions the editor created
/// (`engine-ipc.md` §4.8 + §3.3). Sent immediately after
/// `ProtocolHelloAck` through `IpcSocket.sendWithHandles`: the fds
/// ride as `SCM_RIGHTS` ancillary data in the same order as
/// `regions[0..region_count]`. The runtime maps each via
/// `ShmRegion.fromFd` and **never** calls cross-process `shm_open`.
/// The receiver validates that the ancillary fd count equals
/// `region_count` (`engine-ipc.md` §8.3).
pub const ShmRegionsHandoff = extern struct {
    /// Number of valid entries in `regions` (and of fds in the
    /// ancillary data). `1` in M0.7 (`viewport_framebuffer` only).
    region_count: u32,
    _pad0: u32 = 0,
    /// Fixed-capacity descriptor table; only the first `region_count`
    /// entries are meaningful. Fixed size keeps the frame an
    /// `extern struct` POD like every other catalogue message.
    regions: [MAX_SHM_REGIONS]ShmRegionDesc,
};

/// Returns the `MsgType` discriminator for a given message struct.
/// Used by callers to fill the framing header without manually
/// keeping the type↔enum mapping in sync at each call site.
pub fn msgTypeOf(comptime T: type) MsgType {
    return switch (T) {
        ProtocolHello => .protocol_hello,
        ProtocolHelloAck => .protocol_hello_ack,
        Echo => .echo,
        EchoReply => .echo_reply,
        SpawnEntity => .spawn_entity,
        EntityCreated => .entity_created,
        ModifyComponent => .modify_component,
        ModifyAck => .modify_ack,
        Heartbeat => .heartbeat,
        HeartbeatAck => .heartbeat_ack,
        Shutdown => .shutdown,
        ShutdownAck => .shutdown_ack,
        LogMessage => .log_message,
        ShmRegionsHandoff => .shm_regions_handoff,
        else => @compileError("msgTypeOf: not a Weld IPC message type: " ++ @typeName(T)),
    };
}

/// Comptime schema hash for a message type. Delegates to the Tier 0
/// RTTI subsystem (`rtti.computeSchemaHash`) — the swap of the
/// dette D-S6-RTTI (M0.2 / E2). Call sites are unchanged.
///
/// Pre-swap, the body inlined `std.hash.Wyhash.hash(0, key)` on a
/// stringified `(typeName, fields)` key. The RTTI subsystem hashes
/// `(typeName, [(field.name, kind, count, offset) for each field])`
/// with `XxHash64(seed=0)` — a structurally different algorithm.
/// Byte-for-byte equivalence is enforced by
/// `tests/core/rtti/ipc_compat_test.zig`, which guards the 5
/// reference S6 messages (`ProtocolHello`, `SpawnEntity`,
/// `ModifyComponent`, `Heartbeat`, `LogMessage`).
pub fn schemaHash(comptime T: type) u64 {
    return rtti.computeSchemaHash(T);
}

/// Writes a NUL-terminated string into a fixed-width buffer. Truncates
/// silently if `text` is longer than `buf.len - 1`. Leftover bytes are
/// zeroed so the wire image is deterministic.
pub fn writeFixedString(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
}

/// Returns the slice up to the first NUL byte in a fixed-width
/// buffer, or the full buffer when no NUL is present.
pub fn readFixedString(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

// ---------------------------------------------------------------- tests --

test "every message type is extern with non-zero size" {
    inline for (.{
        ProtocolHello,   ProtocolHelloAck,
        Echo,            EchoReply,
        SpawnEntity,     EntityCreated,
        ModifyComponent, ModifyAck,
        Heartbeat,       HeartbeatAck,
        Shutdown,        ShutdownAck,
        LogMessage,      ShmRegionsHandoff,
    }) |T| {
        try std.testing.expect(@sizeOf(T) > 0);
    }
}

test "msgTypeOf maps every message to its discriminator" {
    try std.testing.expectEqual(MsgType.protocol_hello, msgTypeOf(ProtocolHello));
    try std.testing.expectEqual(MsgType.heartbeat_ack, msgTypeOf(HeartbeatAck));
    try std.testing.expectEqual(MsgType.log_message, msgTypeOf(LogMessage));
}

test "MsgType.isKnown rejects out-of-range values" {
    try std.testing.expect(MsgType.isKnown(1));
    try std.testing.expect(MsgType.isKnown(13));
    try std.testing.expect(MsgType.isKnown(14)); // shm_regions_handoff (M0.7 / E1)
    try std.testing.expect(!MsgType.isKnown(0));
    try std.testing.expect(!MsgType.isKnown(15));
    try std.testing.expect(!MsgType.isKnown(65535));
}

test "schemaHash is non-zero for every message type" {
    inline for (.{
        ProtocolHello,   ProtocolHelloAck,
        Echo,            EchoReply,
        SpawnEntity,     EntityCreated,
        ModifyComponent, ModifyAck,
        Heartbeat,       HeartbeatAck,
        Shutdown,        ShutdownAck,
        LogMessage,      ShmRegionsHandoff,
    }) |T| {
        try std.testing.expect(schemaHash(T) != 0);
    }
}

test "writeFixedString truncates and NUL-pads correctly" {
    var buf: [8]u8 = undefined;
    writeFixedString(&buf, "hi");
    try std.testing.expectEqualSlices(u8, "hi\x00\x00\x00\x00\x00\x00", &buf);

    writeFixedString(&buf, "0123456789");
    try std.testing.expectEqualSlices(u8, "0123456\x00", &buf);
}

test "readFixedString trims at first NUL" {
    const buf = [_]u8{ 'h', 'i', 0, 'x', 'y' };
    try std.testing.expectEqualSlices(u8, "hi", readFixedString(&buf));

    const full = [_]u8{ 'a', 'b', 'c' };
    try std.testing.expectEqualSlices(u8, "abc", readFixedString(&full));
}

test "Capability.GPU_SHARED_FB is bit 0" {
    try std.testing.expectEqual(@as(u32, 1), Capability.GPU_SHARED_FB);
}
