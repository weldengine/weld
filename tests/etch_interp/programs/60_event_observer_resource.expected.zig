const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 3 };

/// Diff-runner fixture: world snapshot at tick 0. The `Total` resource is
/// seeded by the program's own default (sum 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Out" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run — the complete
/// event vertical on the engraved drain contract (same-tick window, emit
/// order). Per event: sum' = sum * 2 + amount, NOT commutative, so the per-
/// tick fold over the emit order [5, 3] is sum -> 4*sum + 13 (the reversed
/// order would give 4*sum + 11, and a one-tick-late drain would shift
/// `read_back`): tick 1 -> 13, tick 2 -> 65, tick 3 -> 273.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Out", .fields = &[_]driver.FieldSpec{
                .{ .name = "v", .value = .{ .int_ = 273 } },
            } },
        } },
    },
    .resources = &[_]driver.ResourceCheck{
        .{ .name = "Total", .fields = &[_]driver.FieldSpec{
            .{ .name = "sum", .value = .{ .int_ = 273 } },
        } },
    },
};
