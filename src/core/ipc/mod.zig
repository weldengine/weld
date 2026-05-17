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

/// Constants and invariants (magic, protocol version, payload bound,
/// heartbeat timing, little-endian guard).
pub const protocol = @import("protocol.zig");

/// 13 `extern struct` message types + `MsgType` discriminator +
/// `schemaHash` + `Capability` bitflag constants.
pub const messages = @import("messages.zig");

/// 16-byte header + `encode` / `parseHeader` / `validate` / `decode`
/// + the `Error` set raised by all framing-layer failures.
pub const framing = @import("framing.zig");

/// `IpcSocket` interface with OS-specific backends: AF_UNIX socket on
/// Linux/macOS (with `SCM_RIGHTS` cmsg for fd passing), named pipe on
/// Windows. `sendWithHandles` / `recvWithHandles` are POSIX-only in
/// S6 (Windows returns `error.Unimplemented` per `engine-ipc.md` §4.7
/// + brief § Scope).
pub const transport = @import("transport.zig");

/// `ShmRegion` interface with OS-specific backends: POSIX `shm_open`
/// + `mmap` on Linux/macOS, `CreateFileMapping` + `MapViewOfFile` on
/// Windows. Used to back the viewport double-buffer (cf.
/// `viewport.zig`).
pub const shm = @import("shm.zig");

/// `ShmViewport` double-buffer over a `ShmRegion` — runtime writes
/// 1280×720 RGBA8 frames, editor reads + blits via Vulkan. Atomic
/// `last_complete` / `writer_slot` / `reader_slot` triplet drives
/// lock-free producer/consumer with no tearing per
/// `engine-ipc.md` §4.2 (slot count narrowed to 2 in S6).
pub const viewport = @import("viewport.zig");

// Force eager analysis of every sub-file so inline tests are picked
// up by `zig build test`. Lazy semantic analysis in Zig 0.16 would
// otherwise skip files whose declarations are not transitively
// referenced from the test binary's root — and `test` blocks are
// not "references" in that sense.
comptime {
    _ = protocol;
    _ = messages;
    _ = framing;
    _ = transport;
    _ = shm;
    _ = viewport;
}
