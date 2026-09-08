//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Public surface of the event subsystem — the single entry point. Producers `emit`,
//! consumers `subscribe` then `poll`; the scheduler drives `drainAtBoundary`.

const lifetime_mod = @import("lifetime.zig");
const cursor_mod = @import("cursor.zig");
const queue_mod = @import("queue.zig");
const bus_mod = @import("bus.zig");

/// Lifetime tag declarations.
pub const lifetime = lifetime_mod;
/// Reader cursor declaration.
pub const cursor = cursor_mod;
/// Per-type queue (`EventQueue(T)`) implementation.
pub const queue = queue_mod;
/// Heterogeneous bus.
pub const bus = bus_mod;

/// Drain cadence enum (`.tick` / `.phase` / `.frame`).
pub const Lifetime = lifetime_mod.Lifetime;
/// Independent reader handle into a typed queue.
pub const EventCursor = cursor_mod.EventCursor;
/// Per-type lock-free queue factory.
pub const EventQueue = queue_mod.EventQueue;
/// Heterogeneous bus of typed queues.
pub const EventBus = bus_mod.EventBus;
/// Error set surfaced by the bus's user-facing entry points.
pub const BusError = bus_mod.BusError;
/// Poll-time error subset (cursor invalidated by drain).
pub const PollError = queue_mod.PollError;
/// Per-drain drop warning threshold.
pub const DROPS_WARN_THRESHOLD = bus_mod.DROPS_WARN_THRESHOLD;

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Bumped on any breaking change to the frozen surface — a tracked migration.
pub const WELD_EVENTS_PROTOCOL_VERSION: u32 = 1;

comptime {
    // NOT dead code: this reference is what makes Zig analyse the sub-files, so their
    // inline `test` blocks are collected at all.
    _ = lifetime_mod;
    _ = cursor_mod;
    _ = queue_mod;
    _ = bus_mod;
}
