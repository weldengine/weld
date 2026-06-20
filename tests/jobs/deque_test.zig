const std = @import("std");
const weld_core = @import("weld_core");
const watchdog = @import("test_watchdog");

const Deque = weld_core.jobs.deque.Deque;

test "owner push and pop are LIFO" {
    var deque = Deque(u32, 16).init();
    try std.testing.expect(deque.push(1));
    try std.testing.expect(deque.push(2));
    try std.testing.expect(deque.push(3));
    try std.testing.expectEqual(@as(?u32, 3), deque.pop());
    try std.testing.expectEqual(@as(?u32, 2), deque.pop());
    try std.testing.expectEqual(@as(?u32, 1), deque.pop());
    try std.testing.expectEqual(@as(?u32, null), deque.pop());
}

const StealCtx = struct {
    deque: *Deque(u32, 1024),
    consumed: *std.atomic.Value(u32),
    seen: []std.atomic.Value(u8),
    duplicate_seen: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),
};

fn stealerLoop(ctx: StealCtx) void {
    while (!ctx.stop.load(.acquire)) {
        switch (ctx.deque.steal()) {
            .success => |item| {
                _ = ctx.consumed.fetchAdd(1, .acq_rel);
                const idx: usize = @intCast(item);
                if (idx < ctx.seen.len) {
                    const prev = ctx.seen[idx].fetchAdd(1, .acq_rel);
                    if (prev != 0) ctx.duplicate_seen.store(true, .release);
                }
            },
            .empty, .aborted => {
                std.Thread.yield() catch {};
            },
        }
    }
}

test "concurrent steal: every element is consumed exactly once" {
    const io = std.testing.io;
    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "concurrent steal: every element is consumed exactly once");
    defer wd.disarm();

    const N: u32 = 4096;
    var deque = Deque(u32, 1024).init();
    var consumed: std.atomic.Value(u32) = .init(0);
    const seen = try std.testing.allocator.alloc(std.atomic.Value(u8), N);
    defer std.testing.allocator.free(seen);
    for (seen) |*s| s.* = .init(0);
    var duplicate_seen: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(false);

    const ctx: StealCtx = .{
        .deque = &deque,
        .consumed = &consumed,
        .seen = seen,
        .duplicate_seen = &duplicate_seen,
        .stop = &stop,
    };

    const stealer_count = 3;
    var stealers: [stealer_count]std.Thread = undefined;
    for (&stealers) |*t| {
        t.* = try std.Thread.spawn(.{}, stealerLoop, .{ctx});
    }

    var pushed: u32 = 0;
    while (pushed < N) {
        if (deque.push(pushed)) {
            pushed += 1;
        } else {
            // Backpressure — let stealers drain a bit.
            std.Thread.yield() catch {};
        }
    }

    // Wait until everything is consumed.
    while (consumed.load(.acquire) < N) {
        std.Thread.yield() catch {};
    }
    stop.store(true, .release);
    for (&stealers) |t| t.join();

    try std.testing.expectEqual(@as(u32, N), consumed.load(.acquire));
    try std.testing.expect(!duplicate_seen.load(.acquire));
    for (seen) |*s| {
        try std.testing.expectEqual(@as(u8, 1), s.load(.acquire));
    }
}
