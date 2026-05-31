//! M0.2 / E2 — IPC schema_hash golden values.
//!
//! Pins the RTTI-derived `schema_hash` byte sequence for the 5
//! reference S6 messages (`ProtocolHello`, `SpawnEntity`,
//! `ModifyComponent`, `Heartbeat`, `LogMessage`). The golden values
//! were captured against the M0.2 / E2 swap (commit `70ff605`
//! sequence) by a one-shot print block — the test enforces that any
//! future refactor of the RTTI layer surfaces a deliberate,
//! reviewable diff instead of a silent on-the-wire drift.
//!
//! The algorithm is `rtti.computeSchemaHash` = XxHash64(seed=0) on
//! `(typeName, [(field.name, kind, count, offset) for each field])`.
//! E2 §1 originally asked for byte-for-byte equivalence with the
//! Wyhash legacy bytes; voie 2 (protocol version bump,
//! `WELD_IPC_PROTOCOL_VERSION` 1 → 2) was retained — see brief
//! § Acted deviations E2. The legacy compat check has been retired
//! in favour of stable golden values that lock the new algorithm.
//!
//! Any change to one of the following surfaces will fail this file:
//!   - `rtti.hash.computeSchemaHash` (E1 algorithm),
//!   - the layout of one of the 5 reference messages (field order,
//!     names, kinds, sizes), or
//!   - the engine composites in `rtti.type_info`.
//! Update the golden values deliberately, with a brief commit
//! justification, and bump `WELD_IPC_PROTOCOL_VERSION` if the change
//! is on-the-wire visible.

const std = @import("std");
const weld_core = @import("weld_core");

const messages = weld_core.ipc.messages;

// -- Golden values (M0.2 / E2 swap, captured 2026-05-22 11:30) ------

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
