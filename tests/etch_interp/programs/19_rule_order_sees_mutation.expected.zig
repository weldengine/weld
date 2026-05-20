const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A" },
            .{ .name = "B" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{
            .components = &[_]driver.ComponentSpec{
                // Tick 1: rule_a → x=1; rule_b → y=x=1.
                // Tick 2: rule_a → x=2; rule_b → y=x=2.
                .{ .name = "A", .fields = &[_]driver.FieldSpec{
                    .{ .name = "x", .value = .{ .int_ = 2 } },
                } },
                .{ .name = "B", .fields = &[_]driver.FieldSpec{
                    .{ .name = "y", .value = .{ .int_ = 2 } },
                } },
            },
        },
    },
};
