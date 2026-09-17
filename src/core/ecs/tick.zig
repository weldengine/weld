//! World tick counter — incremented once per frame by `World.beginFrame`.
//! Drives the change-detection sidecars (`added_tick[]`, `changed_tick[]`) and
//! the `Changed<T>` filter's comparison against each query's `last_run_tick`.

const std = @import("std");

/// Monotonic counter value type.
pub const Tick = u32;

/// Initial `Tick` of a fresh `World` and default `Query.last_run_tick`. A query
/// still at this value sees every entity as changed once the world ticks.
pub const initial_tick: Tick = 0;

// TODO(Tick wraparound compaction): `u32` rolls over after about two years at 60
// FPS. The compaction subtracts a base from every `added_tick` / `changed_tick` /
// `last_run_tick` value, leaving relative ordering intact.
