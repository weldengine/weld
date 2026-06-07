const driver = @import("diff_runner");

/// Diff-runner fixture: one tick.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: a single entity with C (level = 2, flag = 0, out = 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "C" },
        } },
    },
};

/// Diff-runner fixture: the `lvl < 3` arm gives out = 20; category > 15 sets
/// flag = 1; level is untouched.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "C", .fields = &[_]driver.FieldSpec{
                .{ .name = "level", .value = .{ .int_ = 2 } },
                .{ .name = "flag", .value = .{ .int_ = 1 } },
                .{ .name = "out", .value = .{ .int_ = 20 } },
            } },
        } },
    },
};
