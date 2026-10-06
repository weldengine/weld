const driver = @import("diff_runner");

/// A copy of a dynamic array, a map, a set and a slice, each written after
/// it is taken; a `for` over a collection its body writes; an element
/// written after a copy; a copy of a fixed array of structs; an argument
/// aliasing a `mut self` receiver; `self = v`; a collection rebound; and a
/// collection copied in a fn, which has no arena (`etch-reference-part1.md`
/// §5.2, §8.3).
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Copies`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Copies" },
        } },
    },
};

/// After 1 tick, each field holds its rule's spec value.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Copies", .fields = &[_]driver.FieldSpec{
                .{ .name = "dyn_push", .value = .{ .int_ = 33 } },
                .{ .name = "dyn_last", .value = .{ .int_ = 30099 } },
                .{ .name = "dyn_pop", .value = .{ .int_ = 2021 } },
                .{ .name = "map_copy", .value = .{ .int_ = 1210 } },
                .{ .name = "map_copy2", .value = .{ .int_ = 11 } },
                .{ .name = "set_copy", .value = .{ .int_ = 230 } },
                .{ .name = "slice", .value = .{ .int_ = 22 } },
                .{ .name = "for_dyn", .value = .{ .int_ = 6100 } },
                .{ .name = "for_fixed", .value = .{ .int_ = 6100 } },
                .{ .name = "for_map", .value = .{ .int_ = 30 } },
                .{ .name = "for_pop", .value = .{ .int_ = 60 } },
                .{ .name = "idx_copy", .value = .{ .int_ = 51 } },
                .{ .name = "fixed_struct", .value = .{ .int_ = 153 } },
                .{ .name = "absorb", .value = .{ .int_ = 12 } },
                .{ .name = "absorb_big", .value = .{ .int_ = 12 } },
                .{ .name = "self_assign", .value = .{ .int_ = 7 } },
                .{ .name = "rebind", .value = .{ .int_ = 22 } },
                .{ .name = "fn_empty", .value = .{ .int_ = 1 } },
            } },
        } },
    },
};
