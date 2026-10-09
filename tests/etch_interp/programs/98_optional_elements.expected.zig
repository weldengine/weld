const driver = @import("diff_runner");

/// Fixed arrays of optionals (`etch-grammar.md` §264, §267): elements read
/// through `??`, a fill of `none`, and elements written through an index, one
/// of them wrapped by its slot.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `OptElems`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "OptElems" },
        } },
    },
};

/// After 1 tick: each element, or the default its `??` gives.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "OptElems", .fields = &[_]driver.FieldSpec{
                .{ .name = "some_head", .value = .{ .int_ = 3 } },
                .{ .name = "none_tail", .value = .{ .int_ = 9 } },
                .{ .name = "fill_pick", .value = .{ .int_ = 4 } },
                .{ .name = "wrote", .value = .{ .int_ = 53 } },
            } },
        } },
    },
};
