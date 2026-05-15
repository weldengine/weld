const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 5 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{
            .components = &[_]driver.ComponentSpec{
                .{
                    .name = "Counter",
                    .fields = &[_]driver.FieldSpec{
                        // Resource was never marked dirty in the sidecar; the
                        // `changed` rule never fires.
                        .{ .name = "value", .value = .{ .int_ = 0 } },
                    },
                },
            },
        },
    },
};
