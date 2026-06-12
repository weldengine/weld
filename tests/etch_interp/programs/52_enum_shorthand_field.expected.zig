const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-4 enum
/// shorthand in struct-literal field-value position (check mode,
/// resolver-types §4 + §3.5), including the part1 §10.2 canonical form:
///
/// - `Spec { hp: 7, faction: .blue }` resolves `.blue` against the
///   declared `Faction` field type (interp builds the enum value, codegen
///   emits the qualified `Faction.blue`).
/// - `throw Error { message: "io down", code: .io_fail }` — the §10.2
///   example compiles as written; the caught `err.code` matches 42.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `ShorthandAcc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "ShorthandAcc" },
        } },
    },
};

/// After 1 tick: spec_val == 7 + 200 (the `.blue` arm), err_val == 42
/// (the `.io_fail` shorthand round-trips through throw/catch).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "ShorthandAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "spec_val", .value = .{ .int_ = 207 } },
                .{ .name = "err_val", .value = .{ .int_ = 42 } },
            } },
        } },
    },
};
