//! The state under stress is the libwayland loader's once-init and
//! `wayland.live_state`. The data-race check is the pre-push rerun under
//! ThreadSanitizer, `zig build test-tsan-wayland`.

const std = @import("std");
const test_env = @import("test_env");
const builtin = @import("builtin");
const weld = @import("weld_core");

const NUM_THREADS: u32 = 8;
// Each iteration round-trips with the compositor: this count must stay well
// inside the runner's per-test deadline on a headless one.
const ITERATIONS_PER_THREAD: u32 = 100;

const Ctx = struct {
    iterations: u32,
    err_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    gpa: std.mem.Allocator,
};

fn workerStress(ctx: *Ctx) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        var w = weld.platform.window.Window.create(ctx.gpa, .{}) catch {
            _ = ctx.err_count.fetchAdd(1, .release);
            return;
        };
        w.destroy();
    }
}

// Memory non-corruption under concurrent backend creation, not multi-backend
// coherence, which the "one Backend per process" invariant leaves out. The
// global non-atomic live_state var is raced between threads here, with no
// consequence on the tested pattern.
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

    for (&threads) |*t| t.join();

    var total_errs: u32 = 0;
    for (&ctxs) |*c| total_errs += c.err_count.load(.acquire);
    try std.testing.expectEqual(@as(u32, 0), total_errs);
}
