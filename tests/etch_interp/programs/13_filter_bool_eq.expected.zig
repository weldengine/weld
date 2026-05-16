const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 1 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
            .{ .name = "Active", .fields = &[_]driver.FieldSpec{
                .{ .name = "flag", .value = .{ .bool_ = true } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
            .{ .name = "Active", .fields = &[_]driver.FieldSpec{
                .{ .name = "flag", .value = .{ .bool_ = false } },
            } },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 1 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
