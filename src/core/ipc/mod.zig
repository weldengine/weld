//! Public surface of the `weld_core.ipc` module — Tier 0 endpoint for
//! the editor↔runtime IPC specified in `engine-ipc.md`. The IPC is a
//! single integration point that lives entirely in `weld_core` (cf.
//! `engine-spec.md` §3.1). Both the editor binary (`src/editor/`) and
//! the runtime binary (`src/runtime/`) consume this module via the
//! `IpcServer` / `IpcClient` wrappers.
//!
//! S6 status — the protocol, messages and framing primitives below
//! are wired; the transport (`transport*`), shared memory
//! (`shm*`/`viewport`), and connection wrappers (`server`/`client`)
//! land in follow-up commits within the same milestone.

const protocol_mod = @import("protocol.zig");
const messages_mod = @import("messages.zig");
const framing_mod = @import("framing.zig");

/// Constants and invariants (magic, protocol version, payload bound,
/// heartbeat timing, little-endian guard).
pub const protocol = protocol_mod;

/// 13 `extern struct` message types + `MsgType` discriminator +
/// `schemaHash` + `Capability` bitflag constants.
pub const messages = messages_mod;

/// 16-byte header + `encode` / `parseHeader` / `validate` / `decode`
/// + the `Error` set raised by all framing-layer failures.
pub const framing = framing_mod;
