//! World tick counter — incremented once per frame by
//! `World.beginFrame`. Drives the M0.1 / E4 change-detection sidecars
//! (`added_tick[]`, `changed_tick[]`) and the `Changed<T>` query
//! filter's per-slot comparison against each query's `last_run_tick`.
//!
//! Wraparound. `Tick` is a `u32`, so the counter overflows after
//! ~4.29 G frames — ~2 years at 60 FPS. M0.1 brief Out-of-scope
//! explicitly defers wraparound handling beyond this TODO marker; an
//! eventual Phase 0+ milestone introduces a compaction pass that
//! subtracts a base from every recorded tick.

const std = @import("std");

/// Monotonic counter value type. Used for `World.current_tick`,
/// `Query.last_run_tick`, and the per-component sidecar columns.
pub const Tick = u32;

/// Initial `Tick` value used by a freshly constructed `World` and by
/// the default `Query.last_run_tick`. A query whose `last_run_tick`
/// has never been bumped from this default will see every entity as
/// "changed since the initial tick" once the world starts ticking.
pub const initial_tick: Tick = 0;

// TODO(phase 0+): handle Tick wraparound — `u32` rolls over after
// ~2 years at 60 FPS. M0.1 brief Out-of-scope leaves this to a
// follow-up milestone (the compaction subtracts a base from every
// `added_tick` / `changed_tick` / `last_run_tick` value, leaving
// relative ordering intact).
