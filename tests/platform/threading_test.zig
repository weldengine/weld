const std = @import("std");
const weld = @import("weld_core");
const threading = weld.platform.threading;
const builtin = @import("builtin");

test "setAffinity + setPriority on spawned thread" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const Ctx = struct {
        go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn run(self: *@This()) void {
            while (!self.go.load(.acquire)) std.Thread.yield() catch {};
            self.done.store(1, .release);
        }
    };

    var ctx: Ctx = .{};
    {
        var t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
        defer t.join();
        // Both calls need a live thread, so it runs on only once they are done.
        defer ctx.go.store(true, .release);

        // Pin to core 0 — always exists. macOS no-ops.
        try threading.setAffinity(t, 0);
        // `.high` fails on POSIX without `CAP_SYS_NICE`.
        try threading.setPriority(t, .normal);
    }
    try std.testing.expectEqual(@as(u32, 1), ctx.done.load(.acquire));
}
