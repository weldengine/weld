const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run.
/// Per tick: out += score(a=2, b=3) = 23; mixed += weigh(factor=2,
/// offset=7) on V2{5,1} = 5*2+1+7 = 18. Two ticks → 46 / 36.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 46 } },
                .{ .name = "mixed", .value = .{ .int_ = 36 } },
            } },
        } },
    },
};
