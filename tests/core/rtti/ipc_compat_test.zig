//! M0.2 / E2 — IPC schema_hash compatibility test.
//!
//! Guards the byte-for-byte compatibility of `messages.schemaHash`
//! across the dette D-S6-RTTI swap. Before the swap, `schemaHash`
//! uses `std.hash.Wyhash` directly on a stringified
//! `(typeName, fields)` key. After the swap, it delegates to the
//! RTTI subsystem (`rtti.computeSchemaHash`). The on-the-wire
//! `schema_hash` byte sequence MUST be identical for the 5 S6
//! message types listed below — otherwise the editor and runtime
//! drift apart at handshake time.
//!
//! Legacy values were captured against the Wyhash path *before* the
//! swap by a one-shot `std.debug.print` block (executed on this
//! branch at 2026-05-22 11:14 against commit 161fa14 — the captured
//! values are the output of `messages.schemaHash` when its body
//! still inlines `std.hash.Wyhash.hash(0, key)`). They are
//! hardcoded below so any future divergence is caught at test time,
//! not on the wire.

const std = @import("std");
const weld_core = @import("weld_core");

const messages = weld_core.ipc.messages;

// -- Hardcoded Wyhash legacy values (captured pre-swap, 2026-05-22) -

/// `std.hash.Wyhash.hash(0, key)` on the stringified key
/// `"<typeName>{field:Type;...}"` of `ProtocolHello`.
const LEGACY_PROTOCOL_HELLO: u64 = 0x5d540e38637b6308;
/// Same algorithm applied to `SpawnEntity`.
const LEGACY_SPAWN_ENTITY: u64 = 0xbfde47d0f5f18f23;
/// Same algorithm applied to `ModifyComponent`.
const LEGACY_MODIFY_COMPONENT: u64 = 0xa8a1fed74cf14369;
/// Same algorithm applied to `Heartbeat`.
const LEGACY_HEARTBEAT: u64 = 0x32e19d009703d8b1;
/// Same algorithm applied to `LogMessage`.
const LEGACY_LOG_MESSAGE: u64 = 0x7a828c2be968d129;

// -- Compat assertions ------------------------------------------------

test "schemaHash matches Wyhash legacy bytes for ProtocolHello" {
    try std.testing.expectEqual(
        LEGACY_PROTOCOL_HELLO,
        messages.schemaHash(messages.ProtocolHello),
    );
}

test "schemaHash matches Wyhash legacy bytes for SpawnEntity" {
    try std.testing.expectEqual(
        LEGACY_SPAWN_ENTITY,
        messages.schemaHash(messages.SpawnEntity),
    );
}

test "schemaHash matches Wyhash legacy bytes for ModifyComponent" {
    try std.testing.expectEqual(
        LEGACY_MODIFY_COMPONENT,
        messages.schemaHash(messages.ModifyComponent),
    );
}

test "schemaHash matches Wyhash legacy bytes for Heartbeat" {
    try std.testing.expectEqual(
        LEGACY_HEARTBEAT,
        messages.schemaHash(messages.Heartbeat),
    );
}

test "schemaHash matches Wyhash legacy bytes for LogMessage" {
    try std.testing.expectEqual(
        LEGACY_LOG_MESSAGE,
        messages.schemaHash(messages.LogMessage),
    );
}
