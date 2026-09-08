//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Every payload is an `extern struct` written byte-for-byte, preceded by an 8-byte
//! `schema_hash` that catches editor/runtime build drift. Fixed byte buffers stand
//! in for strings: a longer write is TRUNCATED and the reader stops at the first NUL.

const std = @import("std");
const rtti = @import("../rtti/root.zig");

/// Discriminator in the framing header; renumbering is a protocol-version bump.
pub const MsgType = enum(u16) {
    /// Runtime → Editor — handshake (first message after connect).
    protocol_hello = 1,
    /// Editor → Runtime — handshake response.
    protocol_hello_ack = 2,
    /// Editor → Runtime — transactional; the round-trip latency probe.
    echo = 3,
    /// Runtime → Editor — echoes the seq_id and payload of the Echo.
    echo_reply = 4,
    /// Editor → Runtime — transactional, requests entity creation.
    spawn_entity = 5,
    /// Runtime → Editor — confirms `SpawnEntity` with a synthetic id.
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
    /// Editor → Runtime — POSIX shm fd handoff; the fds ride as ancillary data.
    shm_regions_handoff = 14,
    /// Editor → Runtime — start simulation (fire-and-forget, §3.4).
    play = 15,
    /// Editor → Runtime — pause simulation (fire-and-forget).
    pause = 16,
    /// Editor → Runtime — stop simulation (fire-and-forget).
    stop = 17,
    /// Editor → Runtime — load a scene by path (fire-and-forget).
    load_scene = 18,
    /// Editor → Runtime — hot-reload a script by asset handle.
    hot_reload_script = 19,
    /// Editor → Runtime — save ONE scene by path; declared with NO wired handler.
    save_scene = 20,
    /// Editor → Runtime — transactional; the reply is `project_saved`, same `seq_id`.
    save_project = 21,
    /// Runtime → Editor — ack of `save_project` (same `seq_id`).
    project_saved = 22,
    /// Runtime → Editor — non-fatal, no ack; `CrashReport` is the fatal case.
    runtime_error = 23,

    /// True when the raw header `u16` maps to a declared variant.
    pub fn isKnown(raw: u16) bool {
        return switch (raw) {
            1...23 => true,
            else => false,
        };
    }
};

/// Bit positions for `ProtocolHello.capabilities`; bit 0 is locked to GPU_SHARED_FB.
pub const Capability = struct {
    pub const GPU_SHARED_FB: u32 = 1 << 0;
};

/// Severity for `LogMessage.level`; the numeric values are wire-stable.
pub const LogLevel = enum(u32) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
};

/// Severity for `RuntimeError.severity`; the numeric values are wire-stable.
pub const ErrorSeverity = enum(u32) {
    warning = 0,
    err = 1,
};

/// Runtime → Editor. First message of the handshake; the editor replies with an ack.
pub const ProtocolHello = extern struct {
    /// The runtime's build-time `WELD_IPC_PROTOCOL_VERSION`.
    protocol_version: u16,
    /// Explicit padding, always zero on the wire — removing it changes the layout.
    _pad0: u16 = 0,
    /// NUL-terminated engine version; the WIDTH is part of the wire schema.
    engine_version: [32]u8,
    build_hash: [16]u8,
    capabilities: u32,
};

/// Editor → Runtime. On `accepted == 0` the runtime logs `reason` and exits.
pub const ProtocolHelloAck = extern struct {
    /// 1 = accepted. `u8` and not `bool`, which is illegal in an `extern struct`.
    accepted: u8,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    /// NUL-terminated rejection reason. Empty when `accepted == 1`.
    reason: [128]u8,
};

/// Editor → Runtime. Transactional; the reply carries the same `seq_id` and payload.
pub const Echo = extern struct {
    payload: [64]u8,
};

/// Runtime → Editor. The `seq_id` rides the frame header, never the body.
pub const EchoReply = extern struct {
    payload: [64]u8,
};

/// Editor → Runtime. Transactional; `archetype_hint` is informational only.
pub const SpawnEntity = extern struct {
    archetype_hint: u32 = 0,
};

/// Runtime → Editor. Reply to `SpawnEntity`.
pub const EntityCreated = extern struct {
    entity: u64,
};

/// Editor → Runtime. Transactional.
pub const ModifyComponent = extern struct {
    entity: u64,
    component_type: u32,
    field_offset: u32,
    new_value: [40]u8,
};

/// Runtime → Editor. Reply to `ModifyComponent`; the `seq_id` is in the header.
pub const ModifyAck = extern struct {
    success: u8,
    _pad0: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
};

/// Editor → Runtime. Liveness probe, one per `HEARTBEAT_PERIOD_NS`.
pub const Heartbeat = extern struct {
    sent_at_us: u64,
};

/// Runtime → Editor. Echoes `sent_at_us` and stamps the local reception time.
pub const HeartbeatAck = extern struct {
    sent_at_us: u64,
    received_at_us: u64,
};

/// Editor → Runtime. The runtime MUST reply `ShutdownAck` or the editor times out.
pub const Shutdown = extern struct {
    _reserved: u8 = 0,
};

/// Runtime → Editor. Final message before clean exit.
pub const ShutdownAck = extern struct {
    _reserved: u8 = 0,
};

/// Runtime → Editor. Fire-and-forget: no ack is expected or sent.
pub const LogMessage = extern struct {
    level: u32,
    _pad0: u32 = 0,
    timestamp_us: u64,
    text: [256]u8,
};

/// NUL-terminated capacity of `ShmRegionDesc.logical_name`; the §4.1 names fit.
pub const SHM_LOGICAL_NAME_LEN: usize = 32;

/// Region ceiling per handoff — 8 keeps the frame at 328 payload bytes.
pub const MAX_SHM_REGIONS: usize = 8;

/// One region descriptor; the fd itself travels out-of-band via `SCM_RIGHTS`.
pub const ShmRegionDesc = extern struct {
    /// NUL-terminated logical role, e.g. `"viewport_framebuffer"`.
    logical_name: [SHM_LOGICAL_NAME_LEN]u8,
    /// Region size in bytes — the `mmap` length on the runtime side.
    size: u64,
};

/// Editor → Runtime, POSIX. Sent right after `ProtocolHelloAck` through
/// `sendWithHandles`: the fds ride in the SAME ORDER as `regions[0..region_count]`.
pub const ShmRegionsHandoff = extern struct {
    /// Valid entries in `regions`, and the ancillary fd count the receiver checks.
    region_count: u32,
    _pad0: u32 = 0,
    /// Fixed capacity; only the first `region_count` entries are meaningful.
    regions: [MAX_SHM_REGIONS]ShmRegionDesc,
};

/// Editor → Runtime. Start the simulation. Fire-and-forget — no ack.
pub const Play = extern struct {
    _reserved: u8 = 0,
};

/// Editor → Runtime. Pause the simulation. Fire-and-forget.
pub const Pause = extern struct {
    _reserved: u8 = 0,
};

/// Editor → Runtime. Stop the simulation. Fire-and-forget.
pub const Stop = extern struct {
    _reserved: u8 = 0,
};

/// Editor → Runtime. Load a scene by filesystem path. Fire-and-forget.
pub const LoadScene = extern struct {
    path: [256]u8,
};

/// Editor → Runtime. Hot-reload a script by its `AssetHandle` (a `u64`).
pub const HotReloadScript = extern struct {
    script_handle: u64,
};

/// Editor → Runtime. Save ONE scene by path; declared with NO wired handler.
pub const SaveScene = extern struct {
    path: [256]u8,
};

/// Editor → Runtime. Save the whole project. Transactional: the reply is
/// `ProjectSaved` with the same `seq_id`, which anchors `CommandLog.last_clean_line`.
pub const SaveProject = extern struct {
    _reserved: u8 = 0,
};

/// Runtime → Editor. Ack of `SaveProject`; `ok == 0` carries a `reason`.
pub const ProjectSaved = extern struct {
    /// 1 = saved. `u8` and not `bool`, which is illegal in an `extern struct`.
    ok: u8,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    /// NUL-terminated failure reason. Empty when `ok == 1`.
    reason: [128]u8,
};

/// Runtime → Editor. Non-fatal and recoverable, no ack. Distinct from
/// `CrashReport`, which is reserved for the fatal signal-and-stacktrace case.
pub const RuntimeError = extern struct {
    /// `ErrorSeverity` as `u32` — extern struct can't embed Zig enums.
    severity: u32,
    source: [64]u8,
    text: [256]u8,
};

/// The `MsgType` for a message struct, so no call site keeps the mapping by hand.
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
        Play => .play,
        Pause => .pause,
        Stop => .stop,
        LoadScene => .load_scene,
        HotReloadScript => .hot_reload_script,
        SaveScene => .save_scene,
        SaveProject => .save_project,
        ProjectSaved => .project_saved,
        RuntimeError => .runtime_error,
        else => @compileError("msgTypeOf: not a Weld IPC message type: " ++ @typeName(T)),
    };
}

/// Comptime schema hash, delegated to the RTTI subsystem.
/// `tests/core/rtti/ipc_compat_test.zig` guards five reference messages byte-for-byte.
pub fn schemaHash(comptime T: type) u64 {
    return rtti.computeSchemaHash(T);
}

/// Write a NUL-terminated string, TRUNCATING silently and zeroing the remainder.
pub fn writeFixedString(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
}

/// The slice up to the first NUL, or the whole buffer when there is none.
pub fn readFixedString(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

test "every message type is extern with non-zero size" {
    inline for (.{
        ProtocolHello,   ProtocolHelloAck,
        Echo,            EchoReply,
        SpawnEntity,     EntityCreated,
        ModifyComponent, ModifyAck,
        Heartbeat,       HeartbeatAck,
        Shutdown,        ShutdownAck,
        LogMessage,      ShmRegionsHandoff,
        Play,            Pause,
        Stop,            LoadScene,
        HotReloadScript, SaveScene,
        SaveProject,     ProjectSaved,
        RuntimeError,
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
    try std.testing.expect(MsgType.isKnown(14)); // shm_regions_handoff (M0.7 / E1)
    try std.testing.expect(MsgType.isKnown(23)); // runtime_error (M0.7 / E2)
    try std.testing.expect(!MsgType.isKnown(0));
    try std.testing.expect(!MsgType.isKnown(24));
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
        Play,            Pause,
        Stop,            LoadScene,
        HotReloadScript, SaveScene,
        SaveProject,     ProjectSaved,
        RuntimeError,
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
