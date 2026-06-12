const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. `run` assigns `Acc.out = ("ab" + "cd").len()`
/// and `Acc.out2 = (prefix + "cd" + "e").len()` — exercises the M0.8
/// sub-slice-C tranche-1b string concat surface: a literal+literal concat, an
/// ident-lhs concat (string-ness propagated through a `let` binding), and a
/// nested (left-associated) concat. Interp side: `.add` intercept → per-body
/// `string_run` store; codegen side: `std.mem.concat(fa, ...)` in the tick's
/// frame arena, `fa` threaded as the conditional rule-fn param. The byte-exact
/// observable is the resulting POD scalars — strings cannot live in a POD
/// component, so the lengths route through component fields.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (both fields start at 0); the rule writes the
/// concat byte lengths into it.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: `Acc.out == 4` ("abcd") and `Acc.out2 == 5` ("abcde") —
/// identical in both backends.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 4 } },
                .{ .name = "out2", .value = .{ .int_ = 5 } },
            } },
        } },
    },
};
