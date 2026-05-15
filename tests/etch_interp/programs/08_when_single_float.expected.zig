const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 2 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Score", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .float_ = 1.0 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "flag", .value = .{ .bool_ = false } },
            } },
        } },
    },
};
