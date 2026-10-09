const driver = @import("diff_runner");

/// A method call's arguments evaluated before its receiver's place
/// (`etch-reference-part1.md` §7.9): a `mut self` method on a binding, a field
/// and an element the arguments rebind, by position and by name, `self = v`
/// through a field, `push` and a map's and a set's `insert` on a collection the
/// arguments rebind, an element whose index the arguments change, a `self`
/// method through a binding and through a field, and a set lookup on what they
/// rebind; and a receiver that is a call's result, evaluated before the
/// arguments.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Order`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Order" },
        } },
    },
};

/// After 1 tick, each field holds its rule's spec value.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Order", .fields = &[_]driver.FieldSpec{
                .{ .name = "binding", .value = .{ .int_ = 16 } },
                .{ .name = "field", .value = .{ .int_ = 16 } },
                .{ .name = "element", .value = .{ .int_ = 16 } },
                .{ .name = "named", .value = .{ .int_ = 16 } },
                .{ .name = "self_field", .value = .{ .int_ = 7 } },
                .{ .name = "pushed", .value = .{ .int_ = 29 } },
                .{ .name = "inserted", .value = .{ .int_ = 2520 } },
                .{ .name = "set_inserted", .value = .{ .int_ = 21 } },
                .{ .name = "chain", .value = .{ .int_ = 1212 } },
                .{ .name = "index", .value = .{ .int_ = 133 } },
                .{ .name = "by_value", .value = .{ .int_ = 52 } },
                .{ .name = "set_lookup", .value = .{ .int_ = 1 } },
                .{ .name = "field_value", .value = .{ .int_ = 52 } },
                .{ .name = "typed_arg", .value = .{ .int_ = 13 } },
            } },
        } },
    },
};
