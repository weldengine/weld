//! Which scheduler boundary drains a queue.
//!
//! `.tick` and `.frame` fire together while fixed-tick and render share a dispatch;
//! they stay distinct so the wiring can diverge without a format change.

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Drain cadence for an event queue.
pub const Lifetime = enum(u8) {
    /// Drained at the end of a fixed-tick boundary.
    tick,
    /// Drained between every ECS phase transition.
    phase,
    /// Drained at the end of a render frame.
    frame,
};
