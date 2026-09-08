//! FROZEN — see engine-phase-0-criteria.md C0.5. Every public entry below is.
//!
//! Bounded MPMC queue with cursor readers, on the Vyukov protocol. THE ORDERING IS
//! THE CORRECTNESS: capacity is a power of two, slot index is `pos & mask`, and each
//! slot's atomic `seq` starts at its own index. A producer at logical `pos` observes
//! `seq == pos`, CAS-claims `head`, writes, then publishes `seq = pos + 1` RELEASE; a
//! reader at `pos` observes `seq == pos + 1` ACQUIRE before it reads the payload.
//! Weaken either ordering and the race is invisible to every test here.

const std = @import("std");
const Lifetime = @import("lifetime.zig").Lifetime;
const cursor_mod = @import("cursor.zig");
const EventCursor = cursor_mod.EventCursor;

/// Raised by `poll` when a drain has invalidated the cursor's epoch.
pub const PollError = error{CursorInvalidated};

/// Per-type bounded queue. `cap` must be a power of two >= 2.
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

        /// Allocate a queue with `cap` slots; `cap` must be a power of two >= 2.
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

        /// Lock-free enqueue. Never blocks; DROPS THE OLDEST entry on saturation.
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

        /// Poll one event, or null when empty.
        ///
        /// A reader that fell outside the overwrite window is SNAPPED to the oldest
        /// still-present position and resumes there — skipped events are not counted.
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

        /// Reset to empty and bump `epoch`, which invalidates every live cursor.
        pub fn drain(self: *Self) void {
            // Every slot's `seq` returns to its own index, which is what the
            // producer's `seq == pos` test expects on the next pass.
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
