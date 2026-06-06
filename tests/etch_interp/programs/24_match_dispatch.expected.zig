const driver = @import("diff_runner");

/// Diff-runner fixture: a single tick is enough — the match is idempotent.
pub const config: driver.Config = .{ .ticks = 1 };

/// Diff-runner fixture: tick 0 (defaults: sel = 1, out = 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "C" },
        } },
    },
};

/// Diff-runner fixture: sel = 1 selects the `1 => 200` arm, so out = 200.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "C", .fields = &[_]driver.FieldSpec{
                .{ .name = "sel", .value = .{ .int_ = 1 } },
                .{ .name = "out", .value = .{ .int_ = 200 } },
            } },
        } },
    },
};
