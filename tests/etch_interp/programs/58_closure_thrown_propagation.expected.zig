const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-6 throwing
/// closure boundary: `thrown` PROPAGATES through the closure call —
/// contrary to `returning`, exactly like `callFn` — and lands in the
/// enclosing catch. Interp: the signal stays set across the closure call;
/// codegen: the closure's `call` fn rides its own hidden `__err` out-param
/// and the sanctioned let call site re-raises into the enclosing try.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `ThrowAcc` (out starts at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "ThrowAcc" },
        } },
    },
};

/// After 1 tick: risky(1) throws, `acc.out = v` is skipped, the catch arm
/// writes 42.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "ThrowAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 42 } },
            } },
        } },
    },
};
