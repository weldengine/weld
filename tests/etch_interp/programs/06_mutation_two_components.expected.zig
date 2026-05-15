const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 3 };

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
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "A", .fields = &[_]driver.FieldSpec{
                .{ .name = "x", .value = .{ .int_ = 3 } },
            } },
            .{ .name = "B", .fields = &[_]driver.FieldSpec{
                .{ .name = "y", .value = .{ .int_ = -3 } },
            } },
        } },
    },
};
