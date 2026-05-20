const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
    .resources = &[_]driver.ResourceInit{
        .{ .name = "Event", .dirty = true },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{
            .components = &[_]driver.ComponentSpec{
                .{
                    .name = "Counter",
                    .fields = &[_]driver.FieldSpec{
                        // Tick 1: resource is dirty → rule fires → value=1.
                        // Tick 2: tickBoundary cleared dirty after tick 1 → rule skips.
                        .{ .name = "value", .value = .{ .int_ = 1 } },
                    },
                },
            },
        },
    },
};
