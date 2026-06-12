const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0. D carries only Counter
/// (matches); E also carries Extra (excluded by the `not`).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "limit", .value = .{ .int_ = 20 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "limit", .value = .{ .int_ = 20 } },
            } },
            .{ .name = "Extra" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
/// D: 0 → 7 → 14 (the `value < limit` guard holds both ticks); E: untouched.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 14 } },
                .{ .name = "limit", .value = .{ .int_ = 20 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 0 } },
                .{ .name = "limit", .value = .{ .int_ = 20 } },
            } },
        } },
    },
};
