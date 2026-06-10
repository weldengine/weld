const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0. Three entities probe the
/// general filter (`value * 2 < limit`): A passes, B passes once, C never.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 4 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 8 } },
                .{ .name = "limit", .value = .{ .int_ = 6 } },
            } },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
/// Tick 1: filter_general → A=1, B=5 (C: 16<6 fails); bare_cond (>4) →
/// B=105, C=108; resource_gated (+10 each) → A=11, B=115, C=118.
/// Tick 2: filter_general matches none; bare_cond → A=111, B=215, C=218;
/// resource_gated → A=121, B=225, C=228.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 121 } },
                .{ .name = "limit", .value = .{ .int_ = 10 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 225 } },
                .{ .name = "limit", .value = .{ .int_ = 10 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 228 } },
                .{ .name = "limit", .value = .{ .int_ = 6 } },
            } },
        } },
    },
    .resources = &[_]driver.ResourceCheck{
        .{ .name = "Config", .fields = &[_]driver.FieldSpec{
            .{ .name = "threshold", .value = .{ .int_ = 2 } },
            .{ .name = "enabled", .value = .{ .bool_ = true } },
        } },
    },
};
