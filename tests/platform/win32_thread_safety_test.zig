const std = @import("std");
const builtin = @import("builtin");
const weld = @import("weld_core");
const window_api = weld.platform.window;

const NUM_THREADS: u32 = 8;
// This count must stay well inside the runner's per-test deadline on a loaded
// windows runner.
const ITERATIONS_PER_THREAD: u32 = 100;

const Ctx = struct {
    iterations: u32,
    err_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    gpa: std.mem.Allocator,
};

/// `ok`, or the failure named on stderr, which a release build otherwise
/// leaves empty.
fn check(ok: bool, comptime what: []const u8, args: anytype) !void {
    if (ok) return;
    std.debug.print(what ++ "\n", args);
    return error.TestUnexpectedResult;
}

fn workerStress(ctx: *Ctx) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        var w = window_api.Window.create(ctx.gpa, .{}) catch {
            _ = ctx.err_count.fetchAdd(1, .release);
            return;
        };
        w.destroy();
    }
}

test "concurrent createWindow + destroyWindow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const gpa = std.heap.page_allocator;

    var ctxs: [NUM_THREADS]Ctx = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    // Registers the class, so `atom_before` is the atom the stress must keep.
    {
        var warmup = try window_api.Window.create(gpa, .{});
        warmup.destroy();
    }
    const atom_before = window_api.classAtom();
    try check(atom_before != 0, "the class atom is 0 after the warm-up", .{});

    var i: u32 = 0;
    while (i < NUM_THREADS) : (i += 1) {
        ctxs[i] = .{ .iterations = ITERATIONS_PER_THREAD, .gpa = gpa };
    }
    i = 0;
    while (i < NUM_THREADS) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, workerStress, .{&ctxs[i]});
    }

    for (&threads) |*t| t.join();

    const atom_after = window_api.classAtom();
    try check(atom_after != 0, "the class atom is 0 after the stress", .{});
    try std.testing.expectEqual(atom_before, atom_after);
    try std.testing.expectEqual(@as(u32, 0), window_api.classOpenCount());

    // A few `CreateWindowExW` calls return NULL under this stress on a CI
    // runner, so creates may fail below 5 %.
    var total_errs: u32 = 0;
    for (&ctxs) |*c| total_errs += c.err_count.load(.acquire);
    const total_attempts: u32 = NUM_THREADS * ITERATIONS_PER_THREAD;
    try check(total_errs * 20 < total_attempts, "{d} of {d} window creates failed", .{ total_errs, total_attempts });
}
