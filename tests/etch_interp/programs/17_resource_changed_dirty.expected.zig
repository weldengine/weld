const driver = @import("diff_runner");

pub const config: driver.Config = .{ .ticks = 2 };

pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
    .resources = &[_]driver.ResourceInit{
        .{ .name = "Event", .dirty = true },
    },
};

pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{
            .components = &[_]driver.ComponentSpec{
                .{
                    .name = "Counter",
                    .fields = &[_]driver.FieldSpec{
                        // Tick 1: resource is dirty → rule fires → value=1.
                        // Tick 2: tickBoundary cleared dirty after tick 1 → rule skips.
                        .{ .name = "value", .value = .{ .int_ = 1 } },
                    },
                },
            },
        },
    },
};
