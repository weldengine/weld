const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. `run` assigns `Acc.out = """…""".len()` where
/// the triple-quote body is `\n    line one\n    line two\n    ` — exercises
/// the M0.9 E2-A multiline string surface end-to-end: the lexer's
/// `multiline_string_literal` token, the parser's §1.4 common-indent strip
/// (the two content lines share a 4-space indent; the blank fence lines are
/// excluded → common indent 4), and the builtin `.len()`. The dedented value
/// is `"\nline one\nline two\n"` (19 bytes). The byte-exact observable is the
/// resulting POD scalar — strings cannot live in a POD component, so the
/// length is routed through a component field, confirming interp↔codegen agree
/// on the dedented multiline string.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (its `out` field starts at 0); the rule writes
/// the dedented triple-quote string length into it.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: `Acc.out == 19` — the byte length of `"\nline one\nline two\n"`
/// (the §1.4-dedented body) — identical in both backends.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 19 } },
            } },
        } },
    },
};
