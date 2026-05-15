const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 2 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A" },
            .{ .name = "B" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{
            .components = &[_]driver.ComponentSpec{
                // Tick 1: rule_b → y=x=0; rule_a → x=1.
                // Tick 2: rule_b → y=x=1; rule_a → x=2.
                .{ .name = "A", .fields = &[_]driver.FieldSpec{
                    .{ .name = "x", .value = .{ .int_ = 2 } },
                } },
                .{ .name = "B", .fields = &[_]driver.FieldSpec{
                    .{ .name = "y", .value = .{ .int_ = 1 } },
                } },
            },
        },
    },
};
