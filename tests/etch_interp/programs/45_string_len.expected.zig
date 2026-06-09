const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. `run` assigns `Acc.out = "hello".len()` —
/// exercises the M0.8 sub-slice-C tranche-1 string surface: a string literal
/// (codegen `@as([]const u8, "hello")`, interp `string_id`) and the builtin
/// `.len()` (byte length) → `int`. The byte-exact observable is the resulting
/// POD scalar — strings cannot live in a POD component, so the length is routed
/// through a component field, confirming interp↔codegen agree on it.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (its `out` field starts at 0); the rule writes
/// the string length into it.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: `Acc.out == 5` — the byte length of `"hello"` — identical in
/// both backends.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 5 } },
            } },
        } },
    },
};
