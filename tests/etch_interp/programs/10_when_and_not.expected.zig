const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: world snapshot at tick 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A" },
            .{ .name = "Frozen" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A", .fields = &[_]driver.FieldSpec{
                .{ .name = "x", .value = .{ .int_ = 1 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A", .fields = &[_]driver.FieldSpec{
                .{ .name = "x", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
