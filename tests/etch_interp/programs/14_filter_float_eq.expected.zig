const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 1 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .float_ = 10.0 } },
            } },
            .{ .name = "Counter" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .float_ = 5.0 } },
            } },
            .{ .name = "Counter" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "c", .value = .{ .int_ = 1 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "c", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
