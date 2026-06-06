const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget. `value` gains 1 per tick after the
/// (always-true) assert guard.
pub const config: driver.Config = .{ .ticks = 3 };

/// Diff-runner fixture: world snapshot at tick 0 (default value = 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
};

/// Diff-runner fixture: after 3 ticks the assert never trips and value = 3.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 3 } },
            } },
        } },
    },
};
