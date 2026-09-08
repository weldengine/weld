//! A consumer's reading position in a typed event queue.
//!
//! A drain bumps the queue's epoch, so a cursor held across one is INVALIDATED and
//! `poll` fails until the consumer subscribes again.

const rtti = @import("../rtti/root.zig");

/// The event type a cursor is bound to, re-checked on every `poll`.
pub const TypeId = rtti.TypeId;

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Independent reader handle on a typed queue. POD: copy-by-value is the pattern.
pub const EventCursor = struct {
    /// Type identity of the queue this cursor is bound to.
    type_id: TypeId,
    /// Next position to read. Always `<= queue.head`.
    last_read: usize,
    /// Queue epoch at subscribe time; a drain bumps it and invalidates this cursor.
    epoch: u64,
};
