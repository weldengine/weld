//! World tick counter, bumped once per frame by `World.beginFrame`. `Tick` is a
//! `u32` and WRAPS after ~2 years at 60 FPS; nothing handles that yet.

const std = @import("std");

/// Monotonic counter value type.
pub const Tick = u32;

/// A query still at this default sees every entity as changed on the first run.
pub const initial_tick: Tick = 0;
