const driver = @import("diff_runner");

/// Diff-runner fixture: one tick.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: a single entity with C (sel = 1, out = 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "C" },
        } },
    },
};

/// Diff-runner fixture: the `1 =>` block arm yields base * 2 = 20.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "C", .fields = &[_]driver.FieldSpec{
                .{ .name = "sel", .value = .{ .int_ = 1 } },
                .{ .name = "out", .value = .{ .int_ = 20 } },
            } },
        } },
    },
};
