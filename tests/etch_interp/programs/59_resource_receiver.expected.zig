const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 3 };

/// Diff-runner fixture: world snapshot at tick 0. The `Score` resource is
/// seeded by the program's own defaults (points 0, base 7).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Out" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run. Each tick
/// `bump` adds 2 through the mutable alias, then `mirror` reads the alias +
/// the direct form into the component: after 3 ticks points = 6, v = 6 + 7.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Out", .fields = &[_]driver.FieldSpec{
                .{ .name = "v", .value = .{ .int_ = 13 } },
            } },
        } },
    },
    .resources = &[_]driver.ResourceCheck{
        .{ .name = "Score", .fields = &[_]driver.FieldSpec{
            .{ .name = "points", .value = .{ .int_ = 6 } },
            .{ .name = "base", .value = .{ .int_ = 7 } },
        } },
    },
};
