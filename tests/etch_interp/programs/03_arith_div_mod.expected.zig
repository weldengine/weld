const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 1 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Result" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Result", .fields = &[_]driver.FieldSpec{
                .{ .name = "quot", .value = .{ .int_ = 3 } },
                .{ .name = "rem", .value = .{ .int_ = 1 } },
            } },
        } },
    },
};
