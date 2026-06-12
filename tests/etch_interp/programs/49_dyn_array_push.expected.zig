const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-3 dynamic
/// array vertical — a `T[]` local on the frame arena (codegen) / per-body
/// collection store (interp):
///
/// - `let mut xs: int[] = [10, 20]` declares an annotated dynamic array
///   seeded from a non-empty literal.
/// - two `push` calls grow it (stdlib §13.2, mut receiver).
/// - `xs[0]` / `xs[2]` index reads, `xs.len()` count, and a `for v in xs`
///   sum read it back into the component.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: xs == [10, 20, 30, 40] in both backends, so `first == 10`,
/// `third == 30`, `count == 4`, `sum == 100`.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "first", .value = .{ .int_ = 10 } },
                .{ .name = "third", .value = .{ .int_ = 30 } },
                .{ .name = "count", .value = .{ .int_ = 4 } },
                .{ .name = "sum", .value = .{ .int_ = 100 } },
            } },
        } },
    },
};
