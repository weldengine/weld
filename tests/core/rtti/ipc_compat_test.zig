//! IPC schema_hash golden values.
//!
//! Pins the RTTI-derived `schema_hash` byte sequence for the five reference
//! messages (`ProtocolHello`, `SpawnEntity`, `ModifyComponent`, `Heartbeat`,
//! `LogMessage`), so a refactor of the RTTI layer surfaces a deliberate,
//! reviewable diff instead of a silent on-the-wire drift.
//!
//! The algorithm is `rtti.computeSchemaHash` = XxHash64(seed=0) over
//! `(typeName, [(field.name, kind, count, offset) for each field])`. It is NOT
//! byte-compatible with the Wyhash predecessor, and the divergence was taken as
//! a protocol version bump (`WELD_IPC_PROTOCOL_VERSION` 1 → 2) rather than as a
//! compatibility shim.
//!
//! Three surfaces fail this file when they move: `rtti.hash.computeSchemaHash`,
//! the layout of one of the five messages (field order, names, kinds, sizes),
//! and the engine composites in `rtti.type_info`. Update the golden values
//! deliberately, with the reason in the commit, and bump
//! `WELD_IPC_PROTOCOL_VERSION` if the change is visible on the wire.

const std = @import("std");
const weld_core = @import("weld_core");

const messages = weld_core.ipc.messages;

// Golden values, captured 2026-05-22 by a one-shot print block.

/// `rtti.computeSchemaHash(messages.ProtocolHello)` — locks the on-
/// the-wire schema_hash transmitted alongside the handshake.
const GOLDEN_PROTOCOL_HELLO: u64 = 0xe3e4deb249bb65c9;
/// Idem for `SpawnEntity`.
const GOLDEN_SPAWN_ENTITY: u64 = 0x8b8942e372a058e3;
/// Idem for `ModifyComponent`.
const GOLDEN_MODIFY_COMPONENT: u64 = 0x0a0ddc1bca8c2bb4;
/// Idem for `Heartbeat`.
const GOLDEN_HEARTBEAT: u64 = 0x9f3fedfefae6683b;
/// Idem for `LogMessage`.
const GOLDEN_LOG_MESSAGE: u64 = 0xa4b62ae89476bd45;

// -- Stability assertions --------------------------------------------

test "schema_hash golden value stable for ProtocolHello" {
    try std.testing.expectEqual(
        GOLDEN_PROTOCOL_HELLO,
        messages.schemaHash(messages.ProtocolHello),
    );
}

test "schema_hash golden value stable for SpawnEntity" {
    try std.testing.expectEqual(
        GOLDEN_SPAWN_ENTITY,
        messages.schemaHash(messages.SpawnEntity),
    );
}

test "schema_hash golden value stable for ModifyComponent" {
    try std.testing.expectEqual(
        GOLDEN_MODIFY_COMPONENT,
        messages.schemaHash(messages.ModifyComponent),
    );
}

test "schema_hash golden value stable for Heartbeat" {
    try std.testing.expectEqual(
        GOLDEN_HEARTBEAT,
        messages.schemaHash(messages.Heartbeat),
    );
}

test "schema_hash golden value stable for LogMessage" {
    try std.testing.expectEqual(
        GOLDEN_LOG_MESSAGE,
        messages.schemaHash(messages.LogMessage),
    );
}
