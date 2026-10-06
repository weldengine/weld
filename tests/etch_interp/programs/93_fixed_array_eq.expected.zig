const driver = @import("diff_runner");

/// Two fixed arrays compared element by element (`etch-resolver-types.md`
/// §16.4): a copy and its source, after a write and after the write is undone;
/// a fill, float and bool elements, a float pair holding NaN against itself,
/// and an array whose type only the right-hand operand names.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `ArrEq`, every field 0.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "ArrEq" },
        } },
    },
};

/// After 1 tick: each comparison's spec answer, 1 for true.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "ArrEq", .fields = &[_]driver.FieldSpec{
                .{ .name = "same", .value = .{ .int_ = 1 } },
                .{ .name = "diff", .value = .{ .int_ = 0 } },
                .{ .name = "neq", .value = .{ .int_ = 1 } },
                .{ .name = "restored", .value = .{ .int_ = 1 } },
                .{ .name = "fill", .value = .{ .int_ = 1 } },
                .{ .name = "floats", .value = .{ .int_ = 1 } },
                .{ .name = "bools", .value = .{ .int_ = 1 } },
                .{ .name = "nan_self", .value = .{ .int_ = 0 } },
                .{ .name = "rhs_only", .value = .{ .int_ = 1 } },
            } },
        } },
    },
};
