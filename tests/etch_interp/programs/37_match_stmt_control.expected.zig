const driver = @import("diff_runner");

/// Diff-runner fixture: one tick.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: a single entity with the default Acc (out = 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// Diff-runner fixture: the `_` arm accumulates until the `5 => { break }` arm
/// fires → out = 0 + 1 + 2 + 3 + 4 = 10.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 10 } },
            } },
        } },
    },
};
