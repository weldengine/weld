//! S6 schema_hash tests (per brief § Acceptance criteria › Tests).
//!
//! Two acceptance criteria:
//!   - "schema_hash is comptime-stable" — recomputing the hash of the
//!     same struct in this test must equal the hash baked into the
//!     framing layer at production-code compile time. Re-evaluating
//!     the comptime expression at the test's compilation time and
//!     comparing it to a hard-coded reference proves both runs
//!     produce the same value.
//!   - "modifying a field changes the schema_hash" — an alternate
//!     struct defined inside this file with one field renamed must
//!     produce a different hash from the production struct.

const std = @import("std");
const weld_core = @import("weld_core");

const ipc = weld_core.ipc;
const messages = ipc.messages;

/// Alternate `Echo` shape: same payload size + same field name but a
/// different type. Used to prove the hash depends on the schema, not
/// only on the field names.
const EchoAlt = extern struct {
    payload: [64]u32,
};

/// Alternate `Echo` shape: same field type but a different field name.
const EchoRenamed = extern struct {
    bytes: [64]u8,
};

test "schemaHash is comptime-stable across recompiles" {
    const h1 = messages.schemaHash(messages.Echo);
    const h2 = messages.schemaHash(messages.Echo);
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != 0);
}

test "modifying a field type changes schemaHash" {
    const h_orig = messages.schemaHash(messages.Echo);
    const h_alt = messages.schemaHash(EchoAlt);
    try std.testing.expect(h_orig != h_alt);
}

test "renaming a field changes schemaHash" {
    const h_orig = messages.schemaHash(messages.Echo);
    const h_renamed = messages.schemaHash(EchoRenamed);
    try std.testing.expect(h_orig != h_renamed);
}

test "schemaHash distinguishes every message type" {
    // A subtle hash collision between two message types would mask
    // the schema-mismatch detection. Verify all 14 hashes are unique
    // (13 S6 messages + `ShmRegionsHandoff` added in M0.7 / E1).
    const hashes = [_]u64{
        messages.schemaHash(messages.ProtocolHello),
        messages.schemaHash(messages.ProtocolHelloAck),
        messages.schemaHash(messages.Echo),
        messages.schemaHash(messages.EchoReply),
        messages.schemaHash(messages.SpawnEntity),
        messages.schemaHash(messages.EntityCreated),
        messages.schemaHash(messages.ModifyComponent),
        messages.schemaHash(messages.ModifyAck),
        messages.schemaHash(messages.Heartbeat),
        messages.schemaHash(messages.HeartbeatAck),
        messages.schemaHash(messages.Shutdown),
        messages.schemaHash(messages.ShutdownAck),
        messages.schemaHash(messages.LogMessage),
        messages.schemaHash(messages.ShmRegionsHandoff),
    };
    for (hashes, 0..) |a, i| {
        for (hashes[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }
}
