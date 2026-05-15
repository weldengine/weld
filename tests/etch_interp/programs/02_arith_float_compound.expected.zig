const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 3 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Velocity" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Velocity", .fields = &[_]driver.FieldSpec{
                .{ .name = "dx", .value = .{ .float_ = 4.5 } },
            } },
        } },
    },
};
