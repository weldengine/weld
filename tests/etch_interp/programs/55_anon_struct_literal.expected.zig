const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. The anonymous struct literal `.{ … }` takes
/// its struct from its slot (`etch-resolver-types.md` §4.2): a let annotation,
/// `let q: Pt = .{ x: 40, y: 2 }`, and a struct-typed field of a struct,
/// `Box { p: .{ x: 7, y: 5 }, k: 30 }` (part1 §5.5).
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `AnonAcc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "AnonAcc" },
        } },
    },
};

/// After 1 tick: flat == 40 + 2 through the let annotation, nested ==
/// 7 + 5 + 30 through the field-value position.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "AnonAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "flat", .value = .{ .int_ = 42 } },
                .{ .name = "nested", .value = .{ .int_ = 42 } },
            } },
        } },
    },
};
