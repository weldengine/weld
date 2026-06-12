const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-6 capturing
/// closure codegen (part1 §5.6 capture transparente, resolver-types §8.2
/// value-by-copy): `factor` is snapshotted at closure CREATION (40), the
/// source binding is mutated afterwards (100), and the call sees the
/// snapshot — out = 2 + 40 = 42 in both backends. A by-ref capture would
/// yield 102; byte-exactness here proves the by-value point.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `CapAcc` (out starts at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "CapAcc" },
        } },
    },
};

/// After 1 tick: out == scale(2) == 2 + 40 (the creation-time snapshot of
/// `factor`, NOT the mutated 100).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "CapAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 42 } },
            } },
        } },
    },
};
