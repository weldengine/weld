const driver = @import("diff_runner");

/// Each kind of index write, on a binding no copy shares: a dynamic and a
/// fixed array element, written and by a compound operator; a field and a
/// `mut self` method of an element; a map entry; two assignments whose
/// right-hand side writes their place first; an index evaluated once under a
/// compound operator; and a float element copied, from a fixed and a dynamic
/// array.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Writes`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Writes" },
        } },
    },
};

/// After 1 tick, each field holds its rule's spec value
/// (`etch-reference-part1.md` §7.9 for the last two).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Writes", .fields = &[_]driver.FieldSpec{
                .{ .name = "dyn", .value = .{ .int_ = 9 } },
                .{ .name = "dyn_compound", .value = .{ .int_ = 7 } },
                .{ .name = "fixed", .value = .{ .int_ = 1 } },
                .{ .name = "fixed_compound", .value = .{ .int_ = 8 } },
                .{ .name = "elem_field", .value = .{ .int_ = 2 } },
                .{ .name = "elem_method", .value = .{ .int_ = 2 } },
                .{ .name = "map", .value = .{ .int_ = 1120 } },
                .{ .name = "rhs_first", .value = .{ .int_ = 692 } },
                .{ .name = "compound_rhs_first", .value = .{ .int_ = 11 } },
                .{ .name = "index_once", .value = .{ .int_ = 173 } },
                .{ .name = "float_fixed", .value = .{ .float_ = 2.5 } },
                .{ .name = "float_dyn", .value = .{ .float_ = 2.5 } },
            } },
        } },
    },
};
