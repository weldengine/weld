const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-3 map
/// vertical — an int-keyed map local as an insertion-ordered pair list in
/// BOTH backends (the codegen mirrors the interpreter's store), so the
/// two-binding iteration order is byte-exact by construction:
///
/// - `let mut m = [1: 10, 2: 20]` infers `[int: int]` from the literal.
/// - `m.insert(3, 30)` appends; `m.insert(2, 25)` replaces in place
///   (last-write-wins, stdlib §14.2 — the `V?` return is out of subset,
///   statement use only).
/// - `for k, v in m` walks [1:10, 2:25, 3:30] in insertion order, summing
///   keys and values; `m.len()` is the entry count.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `MapAcc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "MapAcc" },
        } },
    },
};

/// After 1 tick: m == [1:10, 2:25, 3:30] in both backends, so `count == 3`,
/// `key_sum == 6`, `val_sum == 65`.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "MapAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "count", .value = .{ .int_ = 3 } },
                .{ .name = "key_sum", .value = .{ .int_ = 6 } },
                .{ .name = "val_sum", .value = .{ .int_ = 65 } },
            } },
        } },
    },
};
