const driver = @import("diff_runner");

/// A copy of each kind of value, read and never written: a fixed array, an
/// anonymous struct literal, a struct field, a chained struct field, a fn
/// result, a method result, a closure, an optional, `self` in a `mut self`
/// method, a closure that throws; and a dynamic array, a map and a set bound
/// by `let` to a literal.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Copies`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Copies" },
        } },
    },
};

/// After 1 tick: each field holds the value its rule read from a copy.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Copies", .fields = &[_]driver.FieldSpec{
                .{ .name = "arr", .value = .{ .int_ = 3 } },
                .{ .name = "anon", .value = .{ .int_ = 4 } },
                .{ .name = "nested", .value = .{ .int_ = 5 } },
                .{ .name = "chained", .value = .{ .int_ = 6 } },
                .{ .name = "call", .value = .{ .int_ = 7 } },
                .{ .name = "method", .value = .{ .int_ = 8 } },
                .{ .name = "closure", .value = .{ .int_ = 9 } },
                .{ .name = "opt", .value = .{ .int_ = 10 } },
                .{ .name = "self_copy", .value = .{ .int_ = 11 } },
                .{ .name = "seeded_arr", .value = .{ .int_ = 13 } },
                .{ .name = "seeded_map", .value = .{ .int_ = 14 } },
                .{ .name = "seeded_set", .value = .{ .int_ = 15 } },
                .{ .name = "throwing_closure", .value = .{ .int_ = 16 } },
            } },
        } },
    },
};
