const driver = @import("diff_runner");

/// Bindings no later statement reads, in rule, fn, method and closure bodies,
/// blocks, branches, loops, match arms and try and catch bodies: each value is
/// still evaluated, and the program runs in both engines.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Unused`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Unused" },
        } },
    },
};

/// After 1 tick, each field holds its rule's value.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Unused", .fields = &[_]driver.FieldSpec{
                .{ .name = "popped", .value = .{ .int_ = 2 } },
                .{ .name = "copy", .value = .{ .int_ = 6 } },
                .{ .name = "agg", .value = .{ .int_ = 9 } },
                .{ .name = "block", .value = .{ .int_ = 12 } },
                .{ .name = "shadow", .value = .{ .int_ = 1 } },
                .{ .name = "loops", .value = .{ .int_ = 11 } },
                .{ .name = "mapfor", .value = .{ .int_ = 2 } },
                .{ .name = "arm", .value = .{ .int_ = 20 } },
                .{ .name = "thrown", .value = .{ .int_ = 1 } },
                .{ .name = "caught", .value = .{ .int_ = 1 } },
                .{ .name = "safe", .value = .{ .int_ = 1 } },
                .{ .name = "closure_throw", .value = .{ .int_ = 1 } },
                .{ .name = "fn_tail", .value = .{ .int_ = 7 } },
                .{ .name = "method_tail", .value = .{ .int_ = 11 } },
                .{ .name = "closure_tail", .value = .{ .int_ = 9 } },
                .{ .name = "closure_read", .value = .{ .int_ = 11 } },
                .{ .name = "some_read", .value = .{ .int_ = 5 } },
                .{ .name = "map_read", .value = .{ .int_ = 20 } },
                .{ .name = "write_only", .value = .{ .int_ = 1 } },
                .{ .name = "walk", .value = .{ .int_ = 1 } },
            } },
        } },
    },
};
