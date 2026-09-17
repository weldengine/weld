const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. A triple-quote with a MULTI-LINE
/// interpolation. `{1 +\n      n}` spans two lines, its inner `n` indented 6;
/// those bytes are EXPRESSION source (consumed by the embedded-expr sub-parser),
/// NOT string literal — the §1.4 common-indent strip (4 spaces) dedents only the
/// literal segments, never the interpolation. With `n = 2` the value is
/// `"\nbefore 3 after\n"` (16 bytes). Routing `.len()` through a POD int confirms
/// interp↔codegen agree byte-exact on a multi-line interpolated + dedented
/// string — the edge a real dialogue can trigger.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (its `out` field starts at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: `Acc.out == 16` — `len("\nbefore 3 after\n")` — identical in
/// both backends.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 16 } },
            } },
        } },
    },
};
