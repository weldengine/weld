const driver = @import("diff_runner");

/// Diff-runner fixture: one tick of the string-match rule.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: one Counter entity (value defaults to 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
};

/// Diff-runner fixture: the expression arm "a" gives 1, the statement arm "a" adds 10.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 11 } },
            } },
        } },
    },
};
