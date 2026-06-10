const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-6 block-body
/// closure codegen AND the ratified return semantics (the E2 forward note):
/// a `return` inside a closure exits the CLOSURE — it becomes the call's
/// value — never the enclosing fn. `pick(7)` hits the internal `return 40`;
/// the rule body CONTINUES and writes 40 + 2. A leaking `returning` signal
/// would abort the rule body with out still 0.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `RetAcc` (out starts at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "RetAcc" },
        } },
    },
};

/// After 1 tick: out == pick(7) + 2 == 40 + 2 (the internal return exited
/// the closure only; the enclosing rule kept executing).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "RetAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 42 } },
            } },
        } },
    },
};
