const driver = @import("diff_runner");

/// An anonymous `.{ … }` resolved by the struct its slot expects
/// (`etch-resolver-types.md` §4.2): an argument of a fn and of a method, a
/// return, a tail, an assignment, elements of a fixed array and a fill, an
/// element write, if branches, match arms, a block's value, a field write and
/// a write to `self`.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `AnonPos`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "AnonPos" },
        } },
    },
};

/// After 1 tick: each position's value read back through the struct.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "AnonPos", .fields = &[_]driver.FieldSpec{
                .{ .name = "arg", .value = .{ .int_ = 1 } },
                .{ .name = "method_arg", .value = .{ .int_ = 12 } },
                .{ .name = "ret", .value = .{ .int_ = 3 } },
                .{ .name = "tail", .value = .{ .int_ = 4 } },
                .{ .name = "reassign", .value = .{ .int_ = 5 } },
                .{ .name = "fixed_elem", .value = .{ .int_ = 66 } },
                .{ .name = "elem_write", .value = .{ .int_ = 71 } },
                .{ .name = "if_value", .value = .{ .int_ = 8 } },
                .{ .name = "arm", .value = .{ .int_ = 9 } },
                .{ .name = "block", .value = .{ .int_ = 11 } },
                .{ .name = "fill", .value = .{ .int_ = 12 } },
                .{ .name = "field_write", .value = .{ .int_ = 14 } },
                .{ .name = "self_write", .value = .{ .int_ = 13 } },
            } },
        } },
    },
};
