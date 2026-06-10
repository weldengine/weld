const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for this scenario.
pub const config: driver.Config = .{ .ticks = 2 };

/// Diff-runner fixture: world snapshot at tick 0. Four entities covering the
/// two-filter quadrants (D-S4-multifilter). The third entity is the
/// load-bearing case: it passes the LAST filter (armor == 10) and fails the
/// FIRST (current != 50) — under the pre-E3-D last-filter-wins overwrite,
/// BOTH backends wrongly incremented it (parity on wrong semantics), so only
/// this hand-written expected state exposes the bug.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 50 } },
            } },
            .{ .name = "Shield", .fields = &[_]driver.FieldSpec{
                .{ .name = "armor", .value = .{ .int_ = 10 } },
            } },
            .{ .name = "Marker" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 50 } },
            } },
            .{ .name = "Shield", .fields = &[_]driver.FieldSpec{
                .{ .name = "armor", .value = .{ .int_ = 7 } },
            } },
            .{ .name = "Marker" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 3 } },
            } },
            .{ .name = "Shield", .fields = &[_]driver.FieldSpec{
                .{ .name = "armor", .value = .{ .int_ = 10 } },
            } },
            .{ .name = "Marker" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 3 } },
            } },
            .{ .name = "Shield", .fields = &[_]driver.FieldSpec{
                .{ .name = "armor", .value = .{ .int_ = 7 } },
            } },
            .{ .name = "Marker" },
        } },
    },
};

/// Diff-runner fixture: expected world snapshot after the run. Only the
/// both-filters-pass entity accumulates.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "hits", .value = .{ .int_ = 2 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "hits", .value = .{ .int_ = 0 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "hits", .value = .{ .int_ = 0 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "hits", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
