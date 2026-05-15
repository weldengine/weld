const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 4 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score", .fields = &[_]driver.FieldSpec{
                .{ .name = "v", .value = .{ .int_ = 4 } },
            } },
        } },
    },
};
