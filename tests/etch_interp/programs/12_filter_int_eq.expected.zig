const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 2 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 50 } },
            } },
            .{ .name = "Marker" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 100 } },
            } },
            .{ .name = "Marker" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "hits", .value = .{ .int_ = 2 } },
            } },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Marker", .fields = &[_]driver.FieldSpec{
                .{ .name = "hits", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
