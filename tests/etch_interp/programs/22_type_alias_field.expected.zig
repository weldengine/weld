const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget. `x` gains 2.5 per tick.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0 (default x = 0.0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Position" },
        } },
    },
};

/// Diff-runner fixture: after 2 ticks, x = 5.0 (the aliased f64 field).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Position", .fields = &[_]driver.FieldSpec{
                .{ .name = "x", .value = .{ .float_ = 5.0 } },
            } },
        } },
    },
};
