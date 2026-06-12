const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-8 anonymous
/// struct literal `.{ … }` (check mode, resolver-types §4 — the expected
/// type comes from the context) in its two wired positions:
///
/// - `let q: Pt = .{ x: 40, y: 2 }` — the let annotation supplies the type
///   (interp materializes a `Pt`, codegen emits the qualified `Pt{ … }`).
/// - `Box { p: .{ x: 7, y: 5 }, k: 30 }` — the declared struct field type
///   supplies it (the tranche-4 field-value propagation extended from the
///   bare enum variant to the whole literal), through a struct-typed STRUCT
///   field (part1 §5.5 nested POD structs).
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
