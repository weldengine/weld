const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. `run` assigns `Acc.out = msg.len()` where
/// `msg = "hi {who}, n={n + 1}!"` and `Acc.out2 = "{1.5}|{true}|\{x}".len()`
/// — exercises the M0.8 sub-slice-C tranche-1c interpolation surface: a
/// string-typed embedded ident (`{s}`), an embedded arithmetic expression
/// (`{d}` on int), a float literal (`{d}` on f64, `@as`-pinned in the
/// codegen), a bool (true/false text), and the `\{` escape (a literal `{x}`
/// segment). Interp formats pieces into the per-body string store; codegen
/// emits one `std.fmt.allocPrint(fa, ...)` in the tick's frame arena — same
/// `std.fmt` specs on identically-typed values, byte-exact. The observables
/// are the resulting byte lengths routed through POD component fields.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (both fields start at 0); the rule writes the
/// interpolated strings' byte lengths into it.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: `Acc.out == 13` ("hi weld, n=8!") and `Acc.out2 == 12`
/// ("1.5|true|{x}") — identical in both backends.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 13 } },
                .{ .name = "out2", .value = .{ .int_ = 12 } },
            } },
        } },
    },
};
