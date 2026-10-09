const driver = @import("diff_runner");

/// A loop's `break` values typed by the slot the loop fills: a let, a value
/// under an if, after an inner loop and from a match, the elements of a fixed
/// array, a return, a tail and an argument.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `LoopPos`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "LoopPos" },
        } },
    },
};

/// After 1 tick: each position's value read back through the struct.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "LoopPos", .fields = &[_]driver.FieldSpec{
                .{ .name = "bound", .value = .{ .int_ = 1 } },
                .{ .name = "guarded", .value = .{ .int_ = 2 } },
                .{ .name = "after_inner", .value = .{ .int_ = 3 } },
                .{ .name = "arm", .value = .{ .int_ = 4 } },
                .{ .name = "elems", .value = .{ .int_ = 55 } },
                .{ .name = "ret", .value = .{ .int_ = 6 } },
                .{ .name = "tail", .value = .{ .int_ = 7 } },
                .{ .name = "arg", .value = .{ .int_ = 8 } },
            } },
        } },
    },
};
