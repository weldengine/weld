const driver = @import("diff_runner");

/// Diff-runner fixture: one tick (the loop recomputes from 0 each tick).
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: tick 0 (default total = 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// Diff-runner fixture: 0 + 1 + 2 + 3 + 4 = 10 over the exclusive range 0..5.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "total", .value = .{ .int_ = 10 } },
            } },
        } },
    },
};
