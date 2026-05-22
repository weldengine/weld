//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
//!
//! Public surface of the M0.2 / E4 event subsystem.
//!
//! Heterogeneous bus of typed MPMC ring-buffer queues. Producers
//! call `emit(T, event)`; consumers `subscribe(T)` to obtain a
//! cursor, then `poll(T, &cursor)` repeatedly. The scheduler
//! drives lifetime drains via `drainAtBoundary(lt)`.
//!
//! Module convention follows `src/core/ecs/root.zig`,
//! `src/core/rtti/root.zig`, `src/core/resources/root.zig` —
//! single canonical entry point, no parallel `src/core/events.zig`.

const lifetime_mod = @import("lifetime.zig");
const cursor_mod = @import("cursor.zig");
const queue_mod = @import("queue.zig");
const bus_mod = @import("bus.zig");

// -- Sub-module aliases ------------------------------------------------

/// Lifetime tag declarations.
pub const lifetime = lifetime_mod;
/// Reader cursor declaration.
pub const cursor = cursor_mod;
/// Per-type queue (`EventQueue(T)`) implementation.
pub const queue = queue_mod;
/// Heterogeneous bus.
pub const bus = bus_mod;

// -- Flat type surface -------------------------------------------------

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

comptime {
    // Lazy analysis guard — force eager analysis of every
    // events sub-file so inline tests are picked up by
    // `zig build test`.
    _ = lifetime_mod;
    _ = cursor_mod;
    _ = queue_mod;
    _ = bus_mod;
}
