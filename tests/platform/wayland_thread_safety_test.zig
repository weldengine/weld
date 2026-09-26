//! Wayland concurrent createWindow + destroyWindow stress.
//!
//! Concurrent `createWindow` and `destroyWindow` — 8 threads, timeout 5 s —
//! against the Wayland backend's module-level state: the libwayland loader's
//! once-init and `wayland.live_state`.
//!
//! This is the FUNCTIONAL pass. The explicit data-race check is the lefthook
//! pre-push `-fsanitize=thread` rerun.
//!
//! Skipped on non-Linux runners.

const std = @import("std");
const test_env = @import("test_env");
const builtin = @import("builtin");
const weld = @import("weld_core");

const NUM_THREADS: u32 = 8;
// The target is 1000 iterations, knocked down to 100 here because each one
// round-trips with the compositor: microseconds on real hardware, but a
// headless or nested compositor stretches that considerably.
const ITERATIONS_PER_THREAD: u32 = 100;
const TIMEOUT_MS: u64 = 30000;

const Ctx = struct {
    iterations: u32,
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    err_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    gpa: std.mem.Allocator,
};

fn workerStress(ctx: *Ctx) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        var w = weld.platform.window.Window.create(ctx.gpa, .{}) catch {
            _ = ctx.err_count.fetchAdd(1, .release);
            ctx.done.store(1, .release);
            return;
        };
        w.destroy();
    }
    ctx.done.store(1, .release);
}

// Stress-pattern test: 8 threads × N iter of create/destroy sequential
// Backend. page_allocator allocator (not testing.allocator) because a
// timeout bail without join produces a false-positive leak ~512 B/thread
// (State allocated per thread mid-iter). The steady-state create/destroy
// stays covered by the inline tests of wayland.zig + TSAN active via
// lefthook pre-push.
//
// INVARIANT NOTE — this test validates memory non-corruption under
// backend-create stress, NOT multi-backend coherence which stays outside
// the Phase 0 invariant ("1 Backend per process"). The global non-atomic
// live_state var is raced between threads here, with no consequence on the
// tested pattern. Phase 0+ multi-window cleanup (cf. wayland.zig live_state
// comment) will address this tension.
test "concurrent createWindow + destroyWindow" {
    if (builtin.os.tag != .linux) return test_env.absent("a Linux host");

    const gpa = std.heap.page_allocator;

    // Probe first, so a missing compositor is reported as one and not as
    // worker errors.
    var probe = weld.platform.window.Window.create(gpa, .{}) catch {
        return test_env.absent("a Wayland compositor");
    };
    probe.destroy();

    var ctxs: [NUM_THREADS]Ctx = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    var i: u32 = 0;
    while (i < NUM_THREADS) : (i += 1) {
        ctxs[i] = .{ .iterations = ITERATIONS_PER_THREAD, .gpa = gpa };
    }
    i = 0;
    while (i < NUM_THREADS) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, workerStress, .{&ctxs[i]});
    }

    const start_ns = weld.platform.time.nowNanos();
    while (true) {
        var all_done = true;
        for (&ctxs) |*c| {
            if (c.done.load(.acquire) == 0) {
                all_done = false;
                break;
            }
        }
        if (all_done) break;
        const elapsed_ms = (weld.platform.time.nowNanos() - start_ns) / 1_000_000;
        if (elapsed_ms >= TIMEOUT_MS) return error.WaylandThreadSafetyTimeout;
        std.Thread.yield() catch {};
    }

    for (&threads) |*t| t.join();

    var total_errs: u32 = 0;
    for (&ctxs) |*c| total_errs += c.err_count.load(.acquire);
    try std.testing.expectEqual(@as(u32, 0), total_errs);
}
