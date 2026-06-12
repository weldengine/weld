const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario. The cast is
/// idempotent (current is overwritten each tick), so any budget yields 4.0.
pub const config: driver.Config = .{ .ticks = 3 };

/// Diff-runner fixture: world snapshot at tick 0 (defaults: level 4,
/// current 0.0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health" },
        } },
    },
};

/// Diff-runner fixture: after the run, `current` holds `level as float`.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .float_ = 4.0 } },
                .{ .name = "level", .value = .{ .int_ = 4 } },
            } },
        } },
    },
};
