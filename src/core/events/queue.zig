//! M0.2 / E4 — bounded MPMC event queue with cursor-style readers.
//!
//! Implements the Vyukov bounded MPMC pattern adapted for
//! broadcast (cursor) readers:
//!
//!   - Power-of-two capacity, slot index = `pos & mask`.
//!   - Each slot carries an atomic `seq` initialised to its
//!     index. A producer that wants to write at logical position
//!     `pos` first observes `seq == pos`; on success it CAS-claims
//!     `head pos → pos+1`, writes the payload, then publishes
//!     `slot.seq = pos+1` (release). A reader that wants to read
//!     position `pos` observes `seq == pos+1` (acquire) before
//!     reading the payload.
//!
//! Saturation policy: when the producer observes `seq < pos`
//! (slot still holds an older event that no consumer has caught
//! up to), it drops the oldest by overwriting the slot and bumps
//! `drops_since_last_drain`. Producers never block.
//!
//! Readers: every cursor tracks its own `last_read`. There is no
//! shared dequeue position. If a reader falls behind the
//! producers' overwrite window, `poll` snaps the cursor to the
//! oldest still-present position (`head - cap`) and resumes from
//! there. The reader sees "skip" events — there is no separate
//! counter exposed to the cursor.
//!
//! Drain bumps `epoch` and resets `head` + every slot's `seq` to
//! its index. Cursors with a stale `epoch` get
//! `error.CursorInvalidated` from `poll`.

const std = @import("std");
const Lifetime = @import("lifetime.zig").Lifetime;
const cursor_mod = @import("cursor.zig");
const EventCursor = cursor_mod.EventCursor;

/// Surfaced by `poll` when the cursor's `epoch` no longer matches
/// the queue's current epoch (drain happened in the interim).
pub const PollError = error{CursorInvalidated};

/// Returns the typed `EventQueue` for `T`. POD `T` only —
/// `enqueue` copies the value into the slot and `poll` returns
/// a value by copy, no allocation involved.
pub fn EventQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            seq: std.atomic.Value(usize),
            payload: T = undefined,
        };

        slots: []Slot,
        mask: usize,
        cap: usize,
        head: std.atomic.Value(usize),
        drops_since_last_drain: std.atomic.Value(u64),
        epoch: std.atomic.Value(u64),
        lifetime: Lifetime,

        /// Allocate a queue with `cap` slots (must be a
        /// power of two, `>= 2`). The queue is heap-allocated so
        /// the bus can hold it through a stable pointer.
        pub fn init(gpa: std.mem.Allocator, cap: usize, lifetime: Lifetime) !*Self {
            std.debug.assert(cap >= 2 and (cap & (cap - 1)) == 0);
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const slots = try gpa.alloc(Slot, cap);
            errdefer gpa.free(slots);
            for (slots, 0..) |*slot, i| {
                slot.* = .{
                    .seq = std.atomic.Value(usize).init(i),
                    .payload = undefined,
                };
            }
            self.* = .{
                .slots = slots,
                .mask = cap - 1,
                .cap = cap,
                .head = std.atomic.Value(usize).init(0),
                .drops_since_last_drain = std.atomic.Value(u64).init(0),
                .epoch = std.atomic.Value(u64).init(0),
                .lifetime = lifetime,
            };
            return self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.slots);
            gpa.destroy(self);
        }

        /// Lock-free enqueue. Never blocks; drops the oldest entry
        /// (and bumps `drops_since_last_drain`) when the queue is
        /// saturated.
        pub fn enqueue(self: *Self, event: T) void {
            while (true) {
                const pos = self.head.load(.monotonic);
                const slot = &self.slots[pos & self.mask];
                const seq = slot.seq.load(.acquire);

                if (seq == pos) {
                    // Slot is empty for this position — try to claim.
                    if (self.head.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic) == null) {
                        slot.payload = event;
                        slot.seq.store(pos + 1, .release);
                        return;
                    }
                    // CAS lost — another producer claimed; retry.
                } else if (seq < pos) {
                    // Slot still holds an older entry the readers
                    // never caught up to. Drop-oldest semantic: claim
                    // the position and overwrite, counting as a drop.
                    if (self.head.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic) == null) {
                        _ = self.drops_since_last_drain.fetchAdd(1, .monotonic);
                        slot.payload = event;
                        slot.seq.store(pos + 1, .release);
                        return;
                    }
                } else {
                    // seq > pos — another producer is ahead;
                    // its head bump just hasn't propagated yet. Spin.
                    std.atomic.spinLoopHint();
                }
            }
        }

        /// Poll one event for `cursor`. Returns:
        ///   - `null` when there is nothing new to read.
        ///   - `error.CursorInvalidated` when the cursor's epoch is
        ///     stale (a drain happened since `subscribe`).
        ///   - The payload (and advances `cursor.last_read`)
        ///     otherwise.
        ///
        /// When the cursor has fallen behind the overwrite window,
        /// `poll` snaps `cursor.last_read` to `head - cap` and
        /// resumes from there — silently skipping any overwritten
        /// events.
        pub fn poll(self: *Self, cursor: *EventCursor) PollError!?T {
            const cur_epoch = self.epoch.load(.acquire);
            if (cursor.epoch != cur_epoch) return error.CursorInvalidated;

            while (true) {
                const head_now = self.head.load(.acquire);
                if (cursor.last_read >= head_now) return null;

                const slot = &self.slots[cursor.last_read & self.mask];
                const seq = slot.seq.load(.acquire);
                const expected = cursor.last_read + 1;

                if (seq == expected) {
                    const payload = slot.payload;
                    cursor.last_read += 1;
                    return payload;
                } else if (seq > expected) {
                    // Cursor was overrun. Snap to the oldest still
                    // present and retry.
                    cursor.last_read = if (head_now > self.cap) head_now - self.cap else 0;
                } else {
                    // seq < expected — a producer claimed this slot
                    // but has not yet published. Caller should
                    // retry later.
                    return null;
                }
            }
        }

        /// Reset the queue to its empty state and bump `epoch`.
        /// Cursors carrying the previous epoch will fail their next
        /// `poll` with `error.CursorInvalidated`.
        ///
        /// `drops_since_last_drain` is NOT reset here — the caller
        /// (the bus's `drainAtBoundary`) reads it first to drive
        /// the warning log, then calls `resetDropsSinceLastDrain`.
        pub fn drain(self: *Self) void {
            // No allocation; reset head + every slot's seq to its
            // initial value. Drain happens between scheduler
            // phases when no systems are running concurrently, so
            // monotonic ordering is sufficient.
            self.head.store(0, .monotonic);
            for (self.slots, 0..) |*slot, i| {
                slot.seq.store(i, .monotonic);
            }
            _ = self.epoch.fetchAdd(1, .release);
        }

        pub fn dropsSinceLastDrain(self: *const Self) u64 {
            return self.drops_since_last_drain.load(.monotonic);
        }

        pub fn resetDropsSinceLastDrain(self: *Self) void {
            self.drops_since_last_drain.store(0, .monotonic);
        }

        pub fn currentEpoch(self: *const Self) u64 {
            return self.epoch.load(.acquire);
        }

        pub fn currentHead(self: *const Self) usize {
            return self.head.load(.acquire);
        }
    };
}
