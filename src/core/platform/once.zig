//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Once-init primitive — tri-state CAS on `std.atomic.Value(u32)`.
//!
//! Zig 0.16.0 has **no** `std.once` / `std.Thread.Once` primitive (verified
//! at M0.3 kick-off, 2026-05-25, via `@hasDecl(std, "once")` and
//! `@hasDecl(std.Thread, "Once")` — both return false). This module
//! implements the CAS-based fallback documented in the M0.3 brief.
//!
//! Used by three sites in the Phase 0 platform layer:
//!   - `window/win32.zig` : `class_atom` (RegisterClassExW), `dpi_awareness_set`
//!     (SetProcessDpiAwarenessContext).
//!   - `time.zig` : `timeBeginPeriod(1)` activation on Win32.
//!
//! ## State machine
//!
//! Three states encoded in a `std.atomic.Value(u32)`:
//!
//!   - `0` (not_started) : nobody has tried yet.
//!   - `1` (in_progress) : a thread is running the init function; others wait.
//!   - `2` (done)        : init completed; future calls return immediately.
//!
//! Transitions:
//!
//!   0 -> 1 : winner of the CAS, runs the init.
//!   1 -> 2 : winner sets DONE, wakes waiters.
//!   1 -> 0 : winner's init failed; releases so another thread can retry.
//!
//! ## Cancellation
//!
//! All waits use `futexWaitUncancelable` per `engine-zig-conventions.md` §11
//! (platform layer is intra-process — external cancellation has no meaning).
//!
//! ## API
//!
//! ```zig
//! var my_once: once.Once = .{};
//! try my_once.call(io, my_init_fn);
//! ```
//!
//! `init_fn` returns `anyerror!void`. On error, the state is reset to
//! `not_started` so the next caller may retry.

const std = @import("std");

/// Tri-state CAS once-init primitive. Initial state is `not_started`.
/// Place `.{}` to zero-initialize.
pub const Once = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(NOT_STARTED),

    pub const NOT_STARTED: u32 = 0;
    pub const IN_PROGRESS: u32 = 1;
    pub const DONE: u32 = 2;

    /// Run `init_fn` exactly once across all callers. Subsequent calls
    /// return immediately. If `init_fn` returns an error, the state is
    /// reset so the next caller may retry.
    ///
    /// `io` is used for the bounded `futexWaitUncancelable` path when
    /// another thread is mid-init. Pass the engine-level `std.Io`
    /// (typically `init.io` from Juicy Main).
    pub fn call(self: *Once, io: std.Io, init_fn: *const fn () anyerror!void) anyerror!void {
        while (true) {
            // Fast path: already done.
            const cur = self.state.load(.acquire);
            if (cur == DONE) return;
            if (cur == IN_PROGRESS) {
                // Another thread is mid-init. Park until they publish.
                io.futexWaitUncancelable(u32, &self.state.raw, IN_PROGRESS);
                continue;
            }
            // cur == NOT_STARTED — try to claim.
            if (self.state.cmpxchgStrong(NOT_STARTED, IN_PROGRESS, .acquire, .acquire)) |_| {
                // Lost the CAS — re-observe.
                continue;
            }

            // Won the CAS — we own the init.
            init_fn() catch |err| {
                self.state.store(NOT_STARTED, .release);
                io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
                return err;
            };
            self.state.store(DONE, .release);
            io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
            return;
        }
    }

    /// Same semantics as `call` but uses a bounded busy-yield loop on the
    /// IN_PROGRESS path instead of `futexWaitUncancelable`. Trade-off: no
    /// `io` parameter required, at the cost of a few hundred nanoseconds
    /// of CPU spin per concurrent loser of the CAS. Acceptable for paths
    /// whose contention window is bounded (window-class registration,
    /// SetProcessDpiAwarenessContext) — both complete in microseconds.
    ///
    /// The yield is implemented as `std.Thread.yield()` with a fallback
    /// `std.atomic.spinLoopHint()` if the OS scheduler doesn't honor
    /// yield (e.g. single-core boxes).
    pub fn callBusyYield(self: *Once, init_fn: *const fn () anyerror!void) anyerror!void {
        while (true) {
            const cur = self.state.load(.acquire);
            if (cur == DONE) return;
            if (cur == IN_PROGRESS) {
                std.Thread.yield() catch {
                    var k: u32 = 0;
                    while (k < 64) : (k += 1) std.atomic.spinLoopHint();
                };
                continue;
            }
            if (self.state.cmpxchgStrong(NOT_STARTED, IN_PROGRESS, .acquire, .acquire)) |_| {
                continue;
            }
            init_fn() catch |err| {
                self.state.store(NOT_STARTED, .release);
                return err;
            };
            self.state.store(DONE, .release);
            return;
        }
    }

    /// Reset to `not_started`. Caller MUST ensure no concurrent `call` is
    /// in flight. Intended for tests only.
    pub fn reset(self: *Once) void {
        self.state.store(NOT_STARTED, .release);
    }

    /// Returns true if init has completed successfully.
    pub fn isDone(self: *const Once) bool {
        return self.state.load(.acquire) == DONE;
    }
};

test "once.Once: single-threaded basic success" {
    const Closure = struct {
        var hits: u32 = 0;
        fn run() anyerror!void {
            hits += 1;
            return;
        }
    };
    Closure.hits = 0;
    var o: Once = .{};

    const io = std.testing.io;
    try o.call(io, Closure.run);
    try o.call(io, Closure.run);
    try o.call(io, Closure.run);

    try std.testing.expectEqual(@as(u32, 1), Closure.hits);
    try std.testing.expect(o.isDone());
}

test "once.Once: init error resets state for retry" {
    const Closure = struct {
        var attempts: u32 = 0;
        var fail_first: bool = true;
        fn run() anyerror!void {
            attempts += 1;
            if (fail_first) {
                fail_first = false;
                return error.SimulatedFailure;
            }
            return;
        }
    };
    Closure.attempts = 0;
    Closure.fail_first = true;
    var o: Once = .{};
    const io = std.testing.io;

    // First call fails.
    try std.testing.expectError(error.SimulatedFailure, o.call(io, Closure.run));
    try std.testing.expect(!o.isDone());

    // Second call succeeds and should call init again.
    try o.call(io, Closure.run);
    try std.testing.expect(o.isDone());
    try std.testing.expectEqual(@as(u32, 2), Closure.attempts);

    // Third call is a no-op.
    try o.call(io, Closure.run);
    try std.testing.expectEqual(@as(u32, 2), Closure.attempts);
}
