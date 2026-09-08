//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Chase-Lev work-stealing deque (SPAA 2005) with the C11 orderings of Lê, Pop,
//! Cohen, Nardelli (PPoPP 2013). Owner pushes and pops at the BOTTOM, any number of
//! stealers take from the TOP; capacity must be a power of two.
//!
//! `top` is a monotonic 64-bit counter and is NEVER decremented — that, and not a
//! tag, is what makes ABA unreachable here, so narrowing it or reusing values
//! reintroduces the problem this design does not guard against.
//!
//! `@fence` was removed in Zig 0.16, so three sync points are `seq_cst` INSTEAD of a
//! standalone fence: the second `bottom` store in `pop`, the `top` load in `pop`, and
//! both loads in `steal`. Relaxing any of them to release/acquire is not equivalent.

const std = @import("std");

/// Chase-Lev deque over `T`; `CAPACITY` must be a power of two.
pub fn Deque(comptime T: type, comptime CAPACITY: usize) type {
    comptime {
        if (CAPACITY == 0 or (CAPACITY & (CAPACITY - 1)) != 0) {
            @compileError("Deque CAPACITY must be a power of two");
        }
    }
    return struct {
        const Self = @This();
        pub const capacity: usize = CAPACITY;
        const Mask: usize = CAPACITY - 1;

        /// `top` and `bottom` sit on separate cache lines — they are written by
        /// different threads on the hot path.
        top: std.atomic.Value(usize) align(64) = .init(0),
        bottom: std.atomic.Value(usize) align(64) = .init(0),
        buffer: [CAPACITY]T align(64) = undefined,

        pub const StealOutcome = union(enum) {
            empty,
            aborted,
            success: T,
        };

        pub fn init() Self {
            return .{};
        }

        /// OWNER ONLY. Push at the bottom; false when full.
        pub fn push(self: *Self, item: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b -% t >= CAPACITY) return false;
            self.buffer[b & Mask] = item;
            // `release` publishes the buffer write before the bottom advance.
            self.bottom.store(b + 1, .release);
            return true;
        }

        /// OWNER ONLY. Pop from the bottom (LIFO); null when empty.
        pub fn pop(self: *Self) ?T {
            const b_orig = self.bottom.load(.monotonic);
            if (b_orig == 0) return null;
            const b = b_orig - 1;
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);

            if (t > b) {
                // Empty — restore bottom.
                self.bottom.store(b + 1, .monotonic);
                return null;
            }

            const item = self.buffer[b & Mask];

            if (t == b) {
                // Single-item contention with stealers.
                const cas_failed = self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null;
                self.bottom.store(b + 1, .monotonic);
                if (cas_failed) return null;
            }
            return item;
        }

        /// Any thread. `.empty` when there is nothing, `.abort` on a lost race.
        pub fn steal(self: *Self) StealOutcome {
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.acquire);
            if (t >= b) return .empty;

            const item = self.buffer[t & Mask];
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                return .aborted;
            }
            return .{ .success = item };
        }

        pub fn approxLen(self: *const Self) usize {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            if (t >= b) return 0;
            return b - t;
        }
    };
}
