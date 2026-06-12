const driver = @import("diff_runner");

/// Diff-runner fixture: 4 ticks of the bare-binding match rule.
pub const config: driver.Config = .{ .ticks = 4 };

/// Diff-runner fixture: one Counter entity (value defaults to 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
};

/// Diff-runner fixture: `match value { n => n + 1 }` adds 1 per tick — the bound
/// `n` IS the scrutinee value, so 0 -> 4 after 4 ticks (byte-exact both backends).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 4 } },
            } },
        } },
    },
};
