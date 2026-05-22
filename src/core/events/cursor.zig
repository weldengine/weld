//! M0.2 / E4 — event cursor.
//!
//! An `EventCursor` is a consumer's reading position in a typed
//! event queue. It tracks `last_read` (the next position to read)
//! and `epoch` (the queue's generation at subscribe time). Drains
//! bump the queue's epoch, so any cursor with a stale epoch is
//! considered invalidated — `poll` then returns
//! `error.CursorInvalidated` and the consumer must `subscribe`
//! again to obtain a fresh cursor.
//!
//! Cursors are POD — copy-by-value across function calls is the
//! expected pattern. The user owns the cursor storage; the bus
//! exposes typed `poll(cursor: *Cursor)` helpers that advance it.

const rtti = @import("../rtti/root.zig");

/// Identifier of the event type a cursor is bound to. Set at
/// `subscribe` time and re-checked on every `poll` to catch
/// cross-type misuse.
pub const TypeId = rtti.TypeId;

/// Independent reader handle on a typed event queue. POD by
/// design — copy-by-value is the canonical pattern. The bus
/// stamps `type_id` and `epoch` at subscribe; the holder advances
/// `last_read` through `poll`.
pub const EventCursor = struct {
    /// Type identity of the queue this cursor is bound to.
    type_id: TypeId,
    /// Monotonic counter of the next position to read. Always
    /// `<= queue.head`.
    last_read: usize,
    /// Queue epoch captured at subscribe time. A drain bumps the
    /// queue epoch; subsequent `poll` calls on a stale cursor
    /// return `error.CursorInvalidated`.
    epoch: u64,
};
