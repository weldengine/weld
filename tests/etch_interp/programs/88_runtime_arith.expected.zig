const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: world snapshot at tick 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Pair" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Pair", .fields = &[_]driver.FieldSpec{
                .{ .name = "quot", .value = .{ .int_ = -3 } },
                .{ .name = "rem", .value = .{ .int_ = 2 } },
                .{ .name = "frem", .value = .{ .float_ = 1.5 } },
                .{ .name = "acc", .value = .{ .int_ = 93 } },
                .{ .name = "narrow", .value = .{ .int_ = -85 } },
                .{ .name = "whole", .value = .{ .int_ = 7 } },
            } },
        } },
    },
};
