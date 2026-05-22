//! M0.2 / E4 — event lifetime tags.
//!
//! A queue's lifetime determines which scheduler boundary drains it:
//!   - `.tick`  — drained at the end of a fixed-tick boundary.
//!   - `.phase` — drained at every ECS phase transition.
//!   - `.frame` — drained at the end of a render frame.
//!
//! In Phase 0, fixed-tick and render share a single dispatch, so
//! `.tick` and `.frame` fire simultaneously. The lifetime enum is
//! still kept distinct so the wiring is ready to diverge in Phase
//! 0.4+ (when render hands off to its own pipeline).

/// Drain cadence for an event queue.
pub const Lifetime = enum(u8) {
    /// Drained at the end of a fixed-tick boundary.
    tick,
    /// Drained between every ECS phase transition (PreUpdate →
    /// FixedUpdate → Update → PostUpdate → LateUpdate → PreRender).
    phase,
    /// Drained at the end of a render frame.
    frame,
};
