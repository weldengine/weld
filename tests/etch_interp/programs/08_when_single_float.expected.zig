const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .float_ = 1.0 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "flag", .value = .{ .bool_ = false } },
            } },
        } },
    },
};
