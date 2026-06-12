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
/// Per tick: out += score(a=2, b=3) = 23 (binding proof); `order` = 32 —
/// the argument blocks ran in WRITTEN order (b's digit 3 first, then a's
/// digit 2; parameter order would read 23 — the 2026-06-10 evaluation-
/// order ruling); mixed += weigh(factor=2, offset=7) on V2{5,1} = 18.
/// Two ticks → out 46, mixed 36, order 32 (re-set each tick).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 46 } },
                .{ .name = "mixed", .value = .{ .int_ = 36 } },
                .{ .name = "order", .value = .{ .int_ = 32 } },
            } },
        } },
    },
};
