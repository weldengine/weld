//! Chase-Lev work-stealing deque (Chase & Lev, SPAA 2005), with the C11
//! memory orderings refined by Lê, Pop, Cohen, Nardelli (PPoPP 2013).
//!
//! Owner thread pushes/pops at the BOTTOM (LIFO). Any number of stealer
//! threads steal from the TOP. The buffer is a fixed-size circular array
//! whose capacity must be a power of two; indexing is via `index & MASK`.
//!
//! ## ABA mitigation
//!
//! `top` is a 64-bit monotonically-increasing counter — never decremented.
//! Stealers `cmpxchg(top, t, t+1)` will only succeed for the exact value of
//! `top` they read at the start of the steal; since `top` never wraps in any
//! realistic lifetime (2^64 steals is hardware-bounded out of reach), ABA on
//! the counter itself is not possible. The buffer slots are reused as the
//! deque circles, but every slot read happens-before its consuming
//! `cmpxchg(top)`, and the slot won't be overwritten by the owner until
//! `top` has advanced past it (Chase-Lev correctness invariant). For S1 with
//! capacity 1024 and ~135 chunks per worker, the deque is never near full,
//! so this invariant holds with margin.
//!
//! `@fence` was removed in Zig 0.16 (cf. release notes); we promote the
//! crucial sync points (the second `bottom` store in `pop`, the `top` load
//! in `pop`, and both loads in `steal`) to `seq_cst` instead of using a
//! standalone fence — equivalent under the C11 memory model.

const std = @import("std");

/// Generic Chase-Lev work-stealing deque factory. Returns a struct
/// holding `CAPACITY` slots of `T` plus the `top`/`bottom` atomics
/// used by the worker (owner) and the thieves (stealers). `CAPACITY`
/// must be a power of two.
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

        /// `top` and `bottom` are placed on their own cache lines to avoid
        /// false sharing between the owner and stealers.
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

        /// Owner-only. Push at the bottom. Returns `false` when the deque is
        /// full — the caller decides whether to spin, drop, or yield.
        pub fn push(self: *Self, item: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b -% t >= CAPACITY) return false;
            self.buffer[b & Mask] = item;
            // `release` publishes the buffer write before the bottom advance.
            self.bottom.store(b + 1, .release);
            return true;
        }

        /// Owner-only. Pop from the bottom (LIFO). Returns `null` when the
        /// deque is empty or when the owner lost a race against a stealer
        /// for the last remaining item.
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

        /// Stealer. Any thread. Returns `.empty` when the deque has no work,
        /// `.aborted` when another stealer/owner won the race, or `.success`
        /// with the stolen item.
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
