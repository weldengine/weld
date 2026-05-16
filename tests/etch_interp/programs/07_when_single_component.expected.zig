const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 3 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Tag" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 3 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Tag", .fields = &[_]driver.FieldSpec{
                .{ .name = "present", .value = .{ .bool_ = true } },
            } },
        } },
    },
};
